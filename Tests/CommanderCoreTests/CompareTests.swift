import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    func pairComparison(_ options: CompareOptions = .init()) throws -> FolderComparison { try CompareService.compare(folder("left"),folder("right"),options:options) }
    func syncPlan(_ strategy: SyncStrategy = .leftToRight) throws -> FolderSyncPlan { let comparison = try pairComparison();return try comparison.plan(comparison.suggestions(strategy)) }
    func testComparisonModesAndInclusiveTimeTolerance() throws {
        let a = try file("left/a.txt","abcd"),b = try file("right/a.txt","wxyz")
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1000)],ofItemAtPath:a.path)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1001)],ofItemAtPath:b.path)
        XCTAssertEqual(try pairComparison().first?.state,.different)
        var options = CompareOptions();options.mode = .sizeAndDate;options.timeTolerance = 1
        XCTAssertEqual(try pairComparison(options).first?.state,.equal)
        options.timeTolerance = 0;XCTAssertEqual(try pairComparison(options).first?.state,.different)
        options.mode = .sizeOnly;XCTAssertEqual(try pairComparison(options).first?.state,.equal)
        try file("right/a.txt","longer");XCTAssertEqual(try pairComparison(options).first?.state,.different)
    }
    func testComparisonContentIgnoresDatesForIdenticalBytes() throws {
        let a = try file("left/a","same"),b = try file("right/a","same")
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:100)],ofItemAtPath:a.path)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:900)],ofItemAtPath:b.path)
        XCTAssertEqual(try pairComparison().first?.state,.equal)
    }
    func testComparisonFiltersPruneAndPreserveStructure() throws {
        try file("left/keep.TXT");try file("left/sub/notes.md");try file("left/skip.txt");try file("left/Cache42/skip.txt");try file("left/.secret.txt");try file("left/.zweicommander-hidden/keep.txt");try file("left/unselected.bin")
        var options = CompareOptions();options.include = "*.txt;*.md";options.exclude = "skip*";options.excludedFolders = "Cache*";options.showHidden = false
        XCTAssertEqual(Set(try pairComparison(options).map(\.relativePath)),Set(["keep.TXT","sub","sub/notes.md"]))
        options.recursive = false;XCTAssertEqual(Set(try pairComparison(options).map(\.relativePath)),Set(["keep.TXT","sub"]))
    }
    func testComparisonBlocksLinksSpecialFilesAndConflictDescendants() throws {
        try file("left/object","file");try file("right/object/deep/a","child");try file("outside/secret","external")
        let left = try folder("left");try FileManager.default.createSymbolicLink(at:left.appendingPathComponent("alias"),withDestinationURL:root.appendingPathComponent("outside"))
        XCTAssertEqual(mkfifo(left.appendingPathComponent("pipe").path,0o600),0)
        let comparison = try pairComparison()
        XCTAssertEqual(comparison.first { $0.id == "object" }?.state,.typeConflict)
        XCTAssertEqual(comparison.first { $0.id == "object/deep/a" }?.state,.blocked)
        XCTAssertEqual(comparison.first { $0.id == "alias" }?.state,.link)
        XCTAssertEqual(comparison.first { $0.id == "pipe" }?.state,.special)
        XCTAssertFalse(comparison.contains { $0.id.contains("secret") })
        var filtered = CompareOptions();filtered.include = "*.txt"
        XCTAssertEqual(try pairComparison(filtered).first { $0.id == "object" }?.state,.typeConflict)
        XCTAssertTrue(try comparison.plan(comparison.suggestions(.leftToRight)).steps.isEmpty)
        XCTAssertThrowsError(try comparison.plan(["object/deep/a":.rightToLeft]))
    }
    func testComparisonCaseAndUnicodeAmbiguityBlocksWholeBranch() throws {
        try file("left/Folder/Grüße.txt");try file("right/folder/Grüße.txt")
        let comparison = try pairComparison();XCTAssertTrue(comparison.allSatisfy { $0.state == .ambiguous })
        XCTAssertTrue(try comparison.plan(comparison.suggestions(.missingBoth)).steps.isEmpty)
        XCTAssertThrowsError(try comparison.plan(["Folder/Grüße.txt":.leftToRight]))
    }
    func testComparisonRejectsInvalidRootsAndOptions() throws {
        let left = try folder("left"),right = try folder("right"),nested = try folder("left/nested")
        XCTAssertThrowsError(try CompareService.compare(left,left));XCTAssertThrowsError(try CompareService.compare(left,nested));XCTAssertThrowsError(try CompareService.compare(URL(string:"https://example.com")!,right))
        XCTAssertThrowsError(try CompareService.compare(left,root.appendingPathComponent("missing")))
        var options = CompareOptions();options.timeTolerance = -1;XCTAssertThrowsError(try options.validate())
        options.timeTolerance = 3601;XCTAssertThrowsError(try options.validate());options.timeTolerance = 1;options.excludedFolders = "a/b";XCTAssertThrowsError(try options.validate())
    }
    func testComparisonRejectsMutationDuringScan() throws {
        let a = try file("left/a.txt","abcd");try file("right/a.txt","abcd");let before = try FileEntry(url:a).modified
        let left = try folder("left"),right = try folder("right");var changed = false
        XCTAssertThrowsError(try CompareService.compare(left,right,progress:{ detail in
            if detail.hasPrefix("Vergleiche") && !changed { changed = true;try! Data("wxyz".utf8).write(to:a);try! FileManager.default.setAttributes([.modificationDate:before],ofItemAtPath:a.path) }
        }))
        XCTAssertTrue(changed);XCTAssertEqual(try read(a),"wxyz")
    }
    func testComparisonPresetsDistinguishUndecidedAndSkipped() throws {
        try file("left/left.txt");try file("right/right.txt");let a = try file("left/both","aaaa"),b = try file("right/both","bbbb")
        for url in [a,b] { try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1000)],ofItemAtPath:url.path) }
        let comparison = try pairComparison(),newer = comparison.suggestions(.newerBoth)
        XCTAssertEqual(newer["both"],.pending);XCTAssertEqual(newer["left.txt"],.leftToRight);XCTAssertEqual(newer["right.txt"],.rightToLeft)
        XCTAssertThrowsError(try comparison.plan(newer));XCTAssertEqual(comparison.suggestions(.missingBoth)["both"],.skip)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1005)],ofItemAtPath:a.path)
        XCTAssertEqual(try pairComparison().suggestions(.newerBoth)["both"],.leftToRight)
    }
    func testSyncSelectedFilesCreateOnlyRequiredParents() throws {
        try file("left/branch/deep/keep.txt","keep");try file("left/branch/off.txt","off");try folder("left/empty");try folder("right")
        let comparison = try pairComparison(),plan = try comparison.plan(["branch/deep/keep.txt":.leftToRight])
        XCTAssertEqual(plan.steps.map(\.path),["branch","branch/deep","branch/deep/keep.txt"])
        let report = FolderSyncEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"))
        XCTAssertEqual(try read(root.appendingPathComponent("right/branch/deep/keep.txt")),"keep");XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/branch/off.txt")));XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/empty")))
    }
    func testSyncMixedDirectionsBackupsExtrasAndUndo() throws {
        try file("left/new-left.txt","left");try file("right/new-right.txt","right");try file("left/shared","new");try file("right/shared","old");try file("right/extra","keep")
        let comparison = try pairComparison(),plan = try comparison.plan(["new-left.txt":.leftToRight,"new-right.txt":.rightToLeft,"shared":.leftToRight])
        let report = FolderSyncEngine.execute(plan)
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(report.undo.count,3)
        XCTAssertEqual(try read(root.appendingPathComponent("right/shared")),"new");XCTAssertEqual(try read(root.appendingPathComponent("left/new-right.txt")),"right");XCTAssertEqual(try read(root.appendingPathComponent("right/extra")),"keep")
        let backup = report.undo.first { $0.current.lastPathComponent == "shared" }!.backup!
        XCTAssertEqual(try read(backup),"old");XCTAssertEqual(FileOperations.undo(report.undo),[]);XCTAssertEqual(try read(root.appendingPathComponent("right/shared")),"old")
        XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/new-left.txt")))
    }
    func testSyncStaleSourceCtimeRejectsEntirePlan() throws {
        try file("left/a","a");let z = try file("left/z","zzzz");try folder("right");let plan = try syncPlan(),date = try FileEntry(url:z).modified
        try Data("xxxx".utf8).write(to:z);try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:z.path)
        let report = FolderSyncEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.completed.isEmpty);XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/a")))
    }
    func testSyncStaleTargetCtimeRejectsBeforeAnyMutation() throws {
        try file("left/a","a");try file("left/z","new!");let z = try file("right/z","old!");let plan = try syncPlan(),date = try FileEntry(url:z).modified
        try Data("edit".utf8).write(to:z);try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:z.path)
        let report = FolderSyncEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.completed.isEmpty);XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/a")));XCTAssertEqual(try read(z),"edit")
    }
    func testSyncReplacedRootsAndParentsNeverFollowLinks() throws {
        try file("left/sub/a","new");try folder("right/sub");let plan = try syncPlan()
        try FileManager.default.moveItem(at:root.appendingPathComponent("right/sub"),to:root.appendingPathComponent("right/original"))
        let outside = try folder("outside");try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("right/sub"),withDestinationURL:outside)
        let report = FolderSyncEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.completed.isEmpty);XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:outside.path).isEmpty)
        try FileManager.default.moveItem(at:root.appendingPathComponent("left"),to:root.appendingPathComponent("left-old"));try folder("left")
        XCTAssertFalse(FolderSyncEngine.execute(plan).errors.isEmpty)
    }
    func testSyncNewTargetAndAliasAreNeverOverwritten() throws {
        try file("left/Readme.txt","new");try folder("right");let plan = try syncPlan();let existing = try file("right/README.TXT","external")
        let report = FolderSyncEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(existing),"external")
    }
    func syncLargePlan(existing: Bool = true) throws -> FolderSyncPlan {
        try folder("left/sub");try folder("right/sub")
        let url = root.appendingPathComponent("left/sub/data.bin");try Data(repeating:65,count:16*1024*1024).write(to:url)
        if existing { try file("right/sub/data.bin","previous") }
        return try syncPlan()
    }
    func testSyncContentMutationDuringCopyKeepsOldTarget() throws {
        let plan = try syncLargePlan(),source = root.appendingPathComponent("left/sub/data.bin"),date = try FileEntry(url:source).modified;var changed = false
        let report = FolderSyncEngine.execute(plan) { progress in
            if progress.bytes > 0 && !changed { changed = true;let file = try! FileHandle(forWritingTo:source);try! file.write(contentsOf:Data("EDIT".utf8));try! file.close();try! FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:source.path) }
        }
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(root.appendingPathComponent("right/sub/data.bin")),"previous")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("right/sub").path).contains { $0.hasPrefix(".zweicommander-") })
    }
    func testSyncTargetAppearingDuringCopyIsPreserved() throws {
        let plan = try syncLargePlan(existing:false);var changed = false
        let report = FolderSyncEngine.execute(plan) { progress in
            if progress.bytes > 0 && !changed { changed = true;try! self.file("right/sub/data.bin","external") }
        }
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(root.appendingPathComponent("right/sub/data.bin")),"external")
    }
    func testSyncParentRelocationDuringCopyKeepsBothLocations() throws {
        let plan = try syncLargePlan();var changed = false
        let report = FolderSyncEngine.execute(plan) { progress in
            if progress.bytes > 0 && !changed {
                changed = true;try! FileManager.default.moveItem(at:self.root.appendingPathComponent("right/sub"),to:self.root.appendingPathComponent("right/moved"));try! self.file("right/sub/data.bin","foreign")
            }
        }
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(root.appendingPathComponent("right/sub/data.bin")),"foreign");XCTAssertEqual(try read(root.appendingPathComponent("right/moved/data.bin")),"previous")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("right/moved").path).contains { $0.hasPrefix(".zweicommander-sync-") })
    }
    func testSyncForeignReplacementOfStagingIsNeverRemoved() throws {
        let plan = try syncLargePlan();var changed = false;var foreign: URL?
        let report = FolderSyncEngine.execute(plan) { progress in
            if progress.bytes > 0 && !changed {
                changed = true;let parent = self.root.appendingPathComponent("right/sub")
                let path = try! FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil).first { $0.lastPathComponent.hasPrefix(".zweicommander-sync-") }!
                try! FileManager.default.moveItem(at:path,to:parent.appendingPathComponent("held-copy"));try! Data("foreign".utf8).write(to:path);foreign = path
            }
        }
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(foreign!),"foreign");XCTAssertEqual(try read(root.appendingPathComponent("right/sub/data.bin")),"previous")
        XCTAssertEqual(try FileEntry(url:root.appendingPathComponent("right/sub/held-copy")).size,Int64(16*1024*1024))
    }
    func testSyncCancelDuringCopyPreservesExistingTarget() throws {
        let plan = try syncLargePlan(),token = CancellationToken();var sawBytes = false
        let report = FolderSyncEngine.execute(plan,token:token) { progress in if progress.bytes > 0 && !sawBytes { sawBytes = true;token.cancel() } }
        XCTAssertTrue(sawBytes);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(root.appendingPathComponent("right/sub/data.bin")),"previous")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("right/sub").path).contains { $0.hasPrefix(".zweicommander-sync-") })
    }
    func testSyncCancelAfterCompletedFileKeepsPartialResult() throws {
        try file("left/a","first");try file("left/z","second");try folder("right");let plan = try syncPlan(),token = CancellationToken()
        let report = FolderSyncEngine.execute(plan,token:token) { progress in if progress.items.first?.state == .completed { token.cancel() } }
        XCTAssertEqual(report.undo.count,1);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(root.appendingPathComponent("right/a")),"first");XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/z")))
    }
    func testSyncPauseResumeWithByteProgressAndMetadata() throws {
        let plan = try syncLargePlan(existing:false),source = root.appendingPathComponent("left/sub/data.bin"),target = root.appendingPathComponent("right/sub/data.bin")
        let token = CancellationToken(),paused = DispatchSemaphore(value:0),done = DispatchSemaphore(value:0),report = CompareLocked<OperationReport?>(nil),once = CompareLocked(false)
        DispatchQueue.global().async { report.set(FolderSyncEngine.execute(plan,token:token) { progress in if progress.bytes > 0 && progress.bytes < plan.bytes && !once.value { once.set(true);token.pause();paused.signal() } });done.signal() }
        var finished = false;defer { if !finished { token.cancel();_ = done.wait(timeout:.now()+5) } }
        XCTAssertEqual(paused.wait(timeout:.now()+5),.success);XCTAssertTrue(waitUntil { token.isWaitingForResume });XCTAssertFalse(FileSystem.exists(target));token.resume()
        finished = done.wait(timeout:.now()+5) == .success;XCTAssertTrue(finished);XCTAssertTrue(report.value?.errors.isEmpty ?? false)
        XCTAssertEqual(try Checksums.hash(source),try Checksums.hash(target));XCTAssertEqual(try FileEntry(url:source).modified,try FileEntry(url:target).modified)
    }
    func testSyncDirectoriesPermissionsAndNoopPlan() throws {
        let directory = try folder("left/empty");try FileManager.default.setAttributes([.posixPermissions:0o750],ofItemAtPath:directory.path);try folder("right")
        let plan = try syncPlan(),report = FolderSyncEngine.execute(plan)
        XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try FileEntry(url:root.appendingPathComponent("right/empty")).permissions & 0o777,0o750)
        let comparison = try pairComparison();XCTAssertTrue(try comparison.plan([:]).steps.isEmpty);XCTAssertTrue(try comparison.plan(comparison.suggestions(.leftToRight)).steps.isEmpty)
    }
    func testSyncPlanRejectsUnknownAndInvalidDirections() throws {
        try file("left/a");let comparison = try pairComparison()
        XCTAssertThrowsError(try comparison.plan(["missing":.leftToRight]));XCTAssertThrowsError(try comparison.plan(["a":.rightToLeft]));XCTAssertThrowsError(try comparison.plan(["a":.pending]))
        let token = CancellationToken();token.cancel();let plan = try comparison.plan(["a":.leftToRight]);let report = FolderSyncEngine.execute(plan,token:token)
        XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.completed.isEmpty)
    }
    func testComparisonProfilesRoundTripAndValidateLimits() throws {
        var options = CompareOptions();options.mode = .sizeAndDate;options.strategy = .newerBoth;options.timeTolerance = 2;options.exclude = "*.tmp";options.excludedFolders = ".git;Cache*";options.showHidden = false
        var library = CompareProfileLibrary();let id = try library.save(name:"  Projekt  ",options:options),data = try library.encoded(),copy = try CompareProfileLibrary(data:data)
        XCTAssertEqual(copy.profile(id)?.options,options);XCTAssertEqual(copy.profile(id)?.name,"Projekt");XCTAssertFalse(String(decoding:data,as:UTF8.self).contains(root.path));XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("steps"))
        XCTAssertThrowsError(try library.save(name:"PROJEKT",options:options));XCTAssertThrowsError(try library.save(name:"\n",options:options))
        _ = try library.save(name:"Projekt",options:CompareOptions(),replacing:id);XCTAssertEqual(library.profiles.count,1)
        for i in 1..<50 { try library.save(name:"Profile \(i)",options:options) };XCTAssertThrowsError(try library.save(name:"Overflow",options:options))
        try library.remove(id);XCTAssertThrowsError(try library.remove(id));XCTAssertThrowsError(try library.save(name:"Missing",options:options,replacing:UUID()))
        XCTAssertThrowsError(try CompareProfileLibrary(data:Data("{broken".utf8)));XCTAssertThrowsError(try CompareProfileLibrary(data:Data("{\"version\":2,\"profiles\":[]}".utf8)));XCTAssertThrowsError(try CompareProfileLibrary(data:Data(repeating:0,count:1_048_577)))
    }
}

private final class CompareLocked<T>: @unchecked Sendable {
    private let lock = NSLock();private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock();defer { lock.unlock() };return stored }
    func set(_ value: T) { lock.lock();stored = value;lock.unlock() }
}
