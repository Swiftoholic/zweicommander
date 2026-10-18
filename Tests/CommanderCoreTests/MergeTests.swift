import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    func mergePlan(_ sources: [URL],_ dest: URL,policy: ConflictPolicy = .stop,filter: TransferFilter = .init()) throws -> TransferPlan {
        try TransferPlanner.prepare(sources,to:dest,kind:.copy,policy:policy,filter:filter,mergeFolders:true)
    }
    func resolve(_ plan: TransferPlan,_ name: String,_ decision: MergeDecision) throws -> TransferPlan {
        guard let action = plan.merge?.actions.first(where:{$0.source.lastPathComponent == name && $0.conflict}) else { throw CommanderError.message("Missing test conflict: "+name) }
        return try plan.resolving(action.id,with:decision)
    }
    func testMergePreservesExtraDestinationFilesAndDirectoryPermissions() throws {
        let source = try folder("tree"),dest = try folder("dest"),existing = try folder("dest/tree")
        try file("tree/new.txt","new");try file("tree/sub/child.txt","child");try file("dest/tree/extra.txt","keep")
        try FileManager.default.setAttributes([.posixPermissions:0o750],ofItemAtPath:existing.path)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:source.path)
        let plan = try mergePlan([source],dest),report = TransferPlanner.execute(plan)
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"))
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/extra.txt")),"keep")
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/sub/child.txt")),"child")
        XCTAssertEqual(try FileEntry(url:existing).permissions & 0o777,0o750)
        XCTAssertEqual(plan.merge?.unresolvedCount,0)
    }
    func testUnresolvedMergeConflictPreventsEveryDestinationChange() throws {
        let first = try file("a.txt","first"),source = try folder("tree"),dest = try folder("dest")
        try file("tree/conflict.txt","new");try file("dest/tree/conflict.txt","old")
        let before = try relativeObjects(dest),plan = try mergePlan([first,source],dest)
        XCTAssertEqual(plan.merge?.unresolvedCount,1);XCTAssertFalse(TransferPlanner.execute(plan).errors.isEmpty)
        XCTAssertEqual(try relativeObjects(dest),before);XCTAssertEqual(try read(dest.appendingPathComponent("tree/conflict.txt")),"old")
    }
    func testMergeIndividualSkipKeepBothAndReplaceWithBackup() throws {
        let source = try folder("tree"),dest = try folder("dest")
        for name in ["skip.txt","both.txt","replace.txt"] { try file("tree/"+name,"new "+name);try file("dest/tree/"+name,"old "+name) }
        let initial = try mergePlan([source],dest)
        var plan = try resolve(initial,"skip.txt",.skip);plan = try resolve(plan,"both.txt",.keepBoth);plan = try resolve(plan,"replace.txt",.replace)
        XCTAssertEqual(initial.merge?.unresolvedCount,3);XCTAssertEqual(plan.merge?.unresolvedCount,0)
        var last: TransferProgress?;let report = TransferPlanner.execute(plan) { last = $0 }
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"))
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/skip.txt")),"old skip.txt")
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/both.txt")),"old both.txt")
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/both (2).txt")),"new both.txt")
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/replace.txt")),"new replace.txt")
        if let backup = report.undo.first(where:{$0.current.lastPathComponent == "replace.txt"})?.backup { XCTAssertEqual(try read(backup),"old replace.txt") }
        else { XCTAssertTrue(false,"replacement backup missing") }
        XCTAssertEqual(last?.bytes,plan.bytes);XCTAssertEqual(last?.totalBytes,plan.bytes);XCTAssertEqual(last?.fraction,1)
        XCTAssertEqual(last?.items.filter { $0.state == .skipped }.count,1)
    }
    func testMergeSkipPolicyAndFilterPreserveUnselectedContents() throws {
        let source = try folder("tree"),dest = try folder("dest")
        try file("tree/a.txt","new");try file("tree/b.txt","add");try file("tree/ignored.bin","excluded")
        try file("dest/tree/a.txt","old");try file("dest/tree/extra.bin","keep")
        var filter = TransferFilter();filter.include = "*.txt";filter.keepEmptyFolders = false
        let plan = try mergePlan([source],dest,policy:.skip,filter:filter),report = TransferPlanner.execute(plan)
        XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(plan.bytes,3)
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/a.txt")),"old")
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/extra.bin")),"keep")
        XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("tree/ignored.bin")))
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/b.txt")),"add")
    }
    func testMergeTypeConflictsMustBeSkippedWithoutTraversingLinks() throws {
        let source = try folder("tree"),dest = try folder("dest"),outside = try folder("outside")
        try file("tree/blocked/new.txt","new");try file("outside/private.txt","private");try folder("dest/tree")
        try FileManager.default.createSymbolicLink(at:dest.appendingPathComponent("tree/blocked"),withDestinationURL:outside)
        let plan = try mergePlan([source],dest,policy:.replace)
        guard let action = plan.merge?.actions.first(where:{$0.source.lastPathComponent == "blocked"}) else { throw CommanderError.message("Missing directory conflict") }
        XCTAssertEqual(action.allowedDecisions,[.pending,.skip]);XCTAssertThrowsError(try plan.resolving(action.id,with:.replace))
        XCTAssertFalse(TransferPlanner.execute(plan).errors.isEmpty)
        let skipped = try plan.resolving(action.id,with:.skip);let report = TransferPlanner.execute(skipped)
        XCTAssertTrue(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(outside.appendingPathComponent("new.txt")))
        XCTAssertEqual(try read(outside.appendingPathComponent("private.txt")),"private")
        XCTAssertTrue(FileSystem.isSymlink(dest.appendingPathComponent("tree/blocked")))
    }
    func testMergeRejectsChangedTargetsBeforeFirstPublication() throws {
        let first = try file("a.txt","first"),source = try folder("tree"),dest = try folder("dest"),target = try file("dest/tree/file.txt","old")
        try file("tree/file.txt","new");let plan = try mergePlan([first,source],dest,policy:.replace)
        try "concurrent edit".write(to:target,atomically:true,encoding:.utf8)
        XCTAssertFalse(TransferPlanner.execute(plan).errors.isEmpty)
        XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("a.txt")));XCTAssertEqual(try read(target),"concurrent edit")
    }
    func testMergeRejectsOccupiedAlternateNameWithoutChoosingAnother() throws {
        let source = try file("same.txt","new"),dest = try folder("dest");try file("dest/same.txt","old")
        let plan = try mergePlan([source],dest,policy:.keepBoth)
        try file("dest/same (2).txt","concurrent")
        XCTAssertFalse(TransferPlanner.execute(plan).errors.isEmpty)
        XCTAssertEqual(try relativeObjects(dest),["same.txt","same (2).txt"])
        XCTAssertEqual(try read(dest.appendingPathComponent("same (2).txt")),"concurrent")
    }
    func testMergeRejectsChangedSourceAndReplacedTargetDirectory() throws {
        let source = try folder("tree"),dest = try folder("dest");let child = try file("tree/data.txt","old");try folder("dest/tree")
        let first = try mergePlan([source],dest)
        try "changed".write(to:child,atomically:true,encoding:.utf8)
        XCTAssertFalse(TransferPlanner.execute(first).errors.isEmpty)
        let next = try mergePlan([source],dest)
        try FileManager.default.moveItem(at:dest.appendingPathComponent("tree"),to:dest.appendingPathComponent("previous"));try folder("dest/tree")
        XCTAssertFalse(TransferPlanner.execute(next).errors.isEmpty);XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("tree/data.txt")))
    }
    func testMergeRejectsParentLinkReplacementDuringNativeCopy() throws {
        let source = try folder("tree"),dest = try folder("dest"),outside = try folder("outside");_ = try largeFile("tree/large.bin")
        try folder("dest/tree");var changed = false
        let plan = try mergePlan([source],dest)
        let report = TransferPlanner.execute(plan) { p in
            if p.bytes > 0 && !changed {
                changed = true
                try? FileManager.default.moveItem(at:dest.appendingPathComponent("tree"),to:dest.appendingPathComponent("moved"))
                try? FileManager.default.createSymbolicLink(at:dest.appendingPathComponent("tree"),withDestinationURL:outside)
            }
        }
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty)
        XCTAssertTrue(try relativeObjects(outside).isEmpty);XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("moved/large.bin")))
    }
    func testMergeRejectsTargetEditsDuringCopyWithoutOverwritingThem() throws {
        let source = try folder("tree"),dest = try folder("dest");_ = try largeFile("tree/large.bin");let target = try file("dest/tree/large.bin","old")
        let plan = try mergePlan([source],dest,policy:.replace);var changed = false
        let report = TransferPlanner.execute(plan) { p in
            if p.bytes > 0 && !changed { changed = true;try? "user edit".write(to:target,atomically:true,encoding:.utf8) }
        }
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(target),"user edit")
    }
    func testMergeCancellationKeepsCompletedFilesAndCurrentOldTarget() throws {
        let source = try folder("tree"),dest = try folder("dest");try file("tree/a.txt","first");_ = try largeFile("tree/z.bin");try file("dest/tree/z.bin","old")
        let plan = try mergePlan([source],dest,policy:.replace),token = CancellationToken()
        let report = TransferPlanner.execute(plan,token:token) { p in if p.items.contains(where:{$0.source.lastPathComponent == "z.bin" && $0.state == .running && $0.bytes > 0}) { token.cancel() } }
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(dest.appendingPathComponent("tree/a.txt")),"first")
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/z.bin")),"old")
        XCTAssertFalse(try relativeObjects(dest).contains { $0.contains(".zweicommander-transfer-") })
    }
    func testMergeNewDirectoriesPreserveReadOnlyModeAndAttributes() throws {
        let source = try folder("tree"),dest = try folder("dest");try file("tree/sub/file.txt","data")
        let date = Date(timeIntervalSince1970:1_650_000_000)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:source.path);try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:dest.appendingPathComponent("tree").path) }
        let data = Array("folder attribute".utf8)
        XCTAssertEqual(data.withUnsafeBytes { setxattr(source.path,"com.zweicommander.test",$0.baseAddress,$0.count,0,0) },0)
        try FileManager.default.setAttributes([.posixPermissions:0o555,.modificationDate:date],ofItemAtPath:source.path)
        let report = TransferPlanner.execute(try mergePlan([source],dest))
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"))
        let target = dest.appendingPathComponent("tree")
        XCTAssertEqual(try FileEntry(url:target).permissions & 0o777,0o555);XCTAssertEqual(try FileEntry(url:target).modified,date)
        var read = [UInt8](repeating:0,count:100)
        let count = getxattr(target.path,"com.zweicommander.test",&read,read.count,0,0);XCTAssertEqual(Array(read.prefix(max(0,count))),data)
    }
    func testMergeUndoRestoresReplacedFilesAndPreservesExtras() throws {
        let source = try folder("tree"),dest = try folder("dest");try file("tree/replace.txt","new");try file("tree/new.txt","new file")
        try file("dest/tree/replace.txt","old");try file("dest/tree/extra.txt","extra")
        let report = TransferPlanner.execute(try mergePlan([source],dest,policy:.replace))
        XCTAssertTrue(report.errors.isEmpty);XCTAssertTrue(FileOperations.undo(report.undo).isEmpty)
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/replace.txt")),"old")
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/extra.txt")),"extra");XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("tree/new.txt")))
    }
    func testMergeSelectionRemovesUnselectedConflictsAndDuplicateNamesFail() throws {
        let a = try file("one/file.txt","a"),b = try file("two/file.txt","b"),dest = try folder("dest")
        XCTAssertThrowsError(try mergePlan([a,b],dest))
        let c = try file("c.txt","c"),z = try file("z.txt","z");try file("dest/z.txt","old")
        let all = try mergePlan([c,z],dest)
        let selected = all.selecting(Set(all.entries.filter { $0.source == c }.map(\.id)))
        XCTAssertEqual(selected.merge?.unresolvedCount,0);XCTAssertEqual(selected.initialItems.count,1)
        XCTAssertTrue(TransferPlanner.execute(selected).errors.isEmpty);XCTAssertEqual(try read(dest.appendingPathComponent("z.txt")),"old")
    }
    func testMergeUnrelatedDestinationEditsArePreservedAndMovesRejected() throws {
        let source = try folder("tree"),dest = try folder("dest");try file("tree/data.txt","new");try folder("dest/tree")
        let plan = try mergePlan([source],dest)
        try file("dest/tree/unrelated.txt","extra")
        XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty);XCTAssertEqual(try read(dest.appendingPathComponent("tree/unrelated.txt")),"extra")
        XCTAssertThrowsError(try TransferPlanner.prepare([source],to:dest,kind:.move,policy:.stop,mergeFolders:true))
        XCTAssertThrowsError(try mergePlan([source],root,policy:.keepBoth))
    }
}
