import Foundation
import Darwin
import CommanderCore

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock();defer { lock.unlock() };return storage }
    func set(_ value: Value) { lock.lock();storage = value;lock.unlock() }
    func update(_ body: (inout Value) -> Void) { lock.lock();body(&storage);lock.unlock() }
}
extension CoreTests {
    func waitUntil(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(3)
        while !condition() && Date() < end { Thread.sleep(forTimeInterval:0.002) }
        return condition()
    }
    func largeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating:0x8b,count:32*1024*1024).write(to:url);return url
    }
    func testNativeCopyProgressAndMetadata() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest")
        let date = Date(timeIntervalSince1970:1_700_000_000)
        try FileManager.default.setAttributes([.posixPermissions:0o640,.modificationDate:date],ofItemAtPath:source.path)
        let attribute = Array("native metadata".utf8)
        XCTAssertEqual(attribute.withUnsafeBytes { setxattr(source.path,"com.zweicommander.test",$0.baseAddress,$0.count,0,0) },0)
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        var partial = false,last: TransferProgress?
        let report = TransferPlanner.execute(plan) { p in
            if p.bytes > 0 && p.bytes < plan.bytes { partial = true };last = p
        }
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertTrue(partial)
        let target = dest.appendingPathComponent("large.bin")
        XCTAssertEqual(try Checksums.hash(source),try Checksums.hash(target))
        XCTAssertEqual(try FileEntry(url:target).permissions & 0o777,0o640)
        XCTAssertEqual(try FileEntry(url:target).modified,date)
        var read = [UInt8](repeating:0,count:100)
        let count = getxattr(target.path,"com.zweicommander.test",&read,read.count,0,0)
        XCTAssertEqual(Array(read.prefix(max(0,count))),attribute)
        XCTAssertEqual(last?.bytes,plan.bytes);XCTAssertEqual(last?.items[0].state,.completed)
    }
    func testPauseResumeInsideCopy() throws { try pausedCopy(cancel:false) }
    func testCancelPausedCopyKeepsPreviousDestination() throws { try pausedCopy(cancel:true) }
    func pausedCopy(cancel: Bool) throws {
        let source = try largeFile("large.bin"),dest = try folder("dest")
        if cancel { try file("dest/large.bin","old target") }
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:cancel ? .replace : .stop)
        let token = CancellationToken(),paused = DispatchSemaphore(value:0),done = DispatchSemaphore(value:0)
        let report = LockedValue<OperationReport?>(nil),once = LockedValue(false)
        let transferred = LockedValue<Int64>(0)
        DispatchQueue.global().async {
            report.set(TransferPlanner.execute(plan,token:token) { p in
                transferred.set(p.bytes)
                if p.bytes > 0 && p.bytes < plan.bytes && !once.value { once.set(true);token.pause();paused.signal() }
            });done.signal()
        }
        var finished = false
        defer { if !finished { token.cancel();_ = done.wait(timeout:.now()+5) } }
        XCTAssertEqual(paused.wait(timeout:.now()+5),.success)
        XCTAssertTrue(waitUntil { token.isWaitingForResume })
        let atPause = transferred.value;Thread.sleep(forTimeInterval:0.05)
        XCTAssertEqual(transferred.value,atPause)
        let target = dest.appendingPathComponent("large.bin")
        if cancel { XCTAssertEqual(try read(target),"old target");token.cancel() }
        else { XCTAssertFalse(FileSystem.exists(target));token.resume() }
        finished = done.wait(timeout:.now()+5) == .success;XCTAssertTrue(finished)
        if cancel {
            XCTAssertEqual(try read(target),"old target");XCTAssertTrue(!(report.value?.errors.isEmpty ?? true))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:dest.path).contains { $0.hasPrefix(".zweicommander-") })
        } else { XCTAssertTrue(report.value?.errors.isEmpty ?? false);XCTAssertEqual(try Checksums.hash(source),try Checksums.hash(target)) }
    }
    func testPlanRejectsStaleSourcesBeforeAnyCopy() throws {
        let a = try file("a","a"),z = try file("z","z"),dest = try folder("dest")
        let plan = try TransferPlanner.prepare([a,z],to:dest,kind:.copy,policy:.stop)
        try "changed".write(to:z,atomically:true,encoding:.utf8)
        let report = TransferPlanner.execute(plan)
        XCTAssertFalse(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("a")))
    }
    func testPlanRejectsNestedSourceMutation() throws {
        let tree = try folder("tree");let child = try file("tree/data","old");let dest = try folder("dest")
        let plan = try TransferPlanner.prepare([tree],to:dest,kind:.copy,policy:.stop)
        let handle = try FileHandle(forWritingTo:child);try handle.write(contentsOf:Data("changed in place".utf8));try handle.close()
        let report = TransferPlanner.execute(plan)
        XCTAssertFalse(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("tree")))
    }
    func testPlanRejectsChangedDestinationAndReplacedParent() throws {
        let source = try file("data","new"),dest = try folder("dest");let target = try file("dest/data","old")
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.replace)
        try "user change".write(to:target,atomically:true,encoding:.utf8)
        XCTAssertFalse(TransferPlanner.execute(plan).errors.isEmpty);XCTAssertEqual(try read(target),"user change")
        let next = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.replace)
        try FileManager.default.moveItem(at:dest,to:root.appendingPathComponent("previous-dest"));_ = try folder("dest")
        XCTAssertFalse(TransferPlanner.execute(next).errors.isEmpty);XCTAssertFalse(FileSystem.exists(target))
    }
    func testCopyRejectsTargetMutationWhileCopying() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest"),target = try file("dest/large.bin","old")
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.replace)
        var changed = false
        let report = TransferPlanner.execute(plan) { p in
            if p.bytes > 0 && !changed { changed = true;try? "concurrent user edit".write(to:target,atomically:true,encoding:.utf8) }
        }
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(target),"concurrent user edit")
    }
    func testCopyRejectsSourceMutationWhileCopying() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest")
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        var changed = false
        let report = TransferPlanner.execute(plan) { p in
            if p.bytes > 0 && !changed {
                changed = true
                if let handle = try? FileHandle(forWritingTo:source) { _ = try? handle.seekToEnd();try? handle.write(contentsOf:Data([1]));try? handle.close() }
            }
        }
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("large.bin")))
    }
    func testPlanSelectionAndSkipStates() throws {
        let a = try file("a","a"),b = try file("b","b"),c = try file("c","c"),dest = try folder("dest")
        try file("dest/a","keep")
        let all = try TransferPlanner.prepare([a,b,c],to:dest,kind:.copy,policy:.skip)
        let plan = all.selecting(Set(all.entries.filter { $0.source != c }.map(\.id)))
        var last: TransferProgress?
        let report = TransferPlanner.execute(plan) { last = $0 }
        XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(report.skipped,[a]);XCTAssertEqual(report.completed.count,1)
        XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("c")));XCTAssertEqual(try read(dest.appendingPathComponent("a")),"keep")
        XCTAssertEqual(last?.items.map(\.state),[.skipped,.completed]);XCTAssertEqual(last?.bytes,1)
    }
    func testNativeDirectoryCopyPreservesLinksAndReadOnlyMode() throws {
        let source = try folder("tree"),dest = try folder("dest");try file("tree/data","payload");try file("outside","private")
        let link = source.appendingPathComponent("link");try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:"../outside")
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:source.path)
        let target = dest.appendingPathComponent("tree")
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:source.path);try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:target.path) }
        let report = TransferPlanner.execute(try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop))
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(try read(target.appendingPathComponent("data")),"payload")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:target.appendingPathComponent("link").path),"../outside")
        XCTAssertEqual(try FileEntry(url:target).permissions & 0o777,0o555)
    }
    func testMovePlanDoesNotInventByteProgress() throws {
        let source = try file("a","data"),dest = try folder("dest")
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.move,policy:.stop)
        var last: TransferProgress?
        let report = TransferPlanner.execute(plan) { last = $0 }
        XCTAssertTrue(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(source));XCTAssertFalse(last?.measuredBytes ?? true)
        XCTAssertEqual(last?.fraction,nil);XCTAssertFalse(last?.items[0].isByteTracked ?? true)
    }
    func testSchedulerReordersAndRemovesOnlyWaitingWork() throws {
        let scheduler = WorkScheduler(),group = DispatchGroup(),order = LockedValue<[String]>([])
        var ids: [UUID] = []
        for title in ["a","b","c"] {
            group.enter()
            ids.append(scheduler.enqueue(title,start:false,body:{ _,_ in order.update { $0.append(title) } },completion:{ _ in group.leave() }))
        }
        scheduler.remove(ids[1]);scheduler.move(ids[2],by:-1)
        XCTAssertTrue(scheduler.isHeld);XCTAssertEqual(order.value,[])
        scheduler.start();XCTAssertEqual(group.wait(timeout:.now()+5),.success)
        XCTAssertEqual(order.value,["c","a"]);XCTAssertEqual(scheduler.snapshots.first { $0.id == ids[1] }?.state,.cancelled)
    }
    func testSchedulerPauseCancelAndResumeNext() throws {
        let scheduler = WorkScheduler(),entered = DispatchSemaphore(value:0),gate = DispatchSemaphore(value:0),firstDone = DispatchSemaphore(value:0),nextDone = DispatchSemaphore(value:0)
        let nextRan = LockedValue(false)
        let first = scheduler.enqueue("first",start:false,body:{ token,_ in entered.signal();_ = gate.wait(timeout:.now()+5);try token.check() },completion:{ _ in firstDone.signal() })
        scheduler.enqueue("next",start:false,body:{ _,_ in nextRan.set(true) },completion:{ _ in nextDone.signal() })
        scheduler.start();XCTAssertEqual(entered.wait(timeout:.now()+5),.success)
        scheduler.pause();gate.signal()
        XCTAssertTrue(waitUntil { scheduler.snapshots.first { $0.id == first }?.state == .paused })
        scheduler.cancel();XCTAssertEqual(firstDone.wait(timeout:.now()+5),.success)
        XCTAssertFalse(nextRan.value);scheduler.resume();XCTAssertEqual(nextDone.wait(timeout:.now()+5),.success)
        XCTAssertTrue(nextRan.value);XCTAssertEqual(scheduler.snapshots.first { $0.id == first }?.state,.cancelled)
    }
    func testSchedulerFailureContinuesAndClearsHistory() throws {
        let scheduler = WorkScheduler(),group = DispatchGroup()
        group.enter();scheduler.enqueue("failure",start:false,body:{ _,_ in throw CommanderError.message("fixture error") },completion:{ _ in group.leave() })
        group.enter();scheduler.enqueue("next",start:false,body:{ _,_ in },completion:{ _ in group.leave() })
        scheduler.start();XCTAssertEqual(group.wait(timeout:.now()+5),.success)
        XCTAssertEqual(scheduler.snapshots.map(\.state),[.failed,.completed]);scheduler.clearFinished();XCTAssertTrue(scheduler.snapshots.isEmpty)
    }
}
