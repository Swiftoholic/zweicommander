import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    func plannedObjects(_ plan: TransferPlan) -> [PlannedObject] {
        plan.entries.flatMap { entry in (0..<entry.objectCount).compactMap { entry.object(at:$0) } }
    }
    func relativeObjects(_ directory: URL) throws -> Set<String> {
        var result: Set<String> = []
        try FileSystem.walk(directory) { result.insert(try FileSystem.relativePath(of:$0,inside:directory)) }
        return result
    }
    func testCopyFilterMasksExcludeUnicodeAndExtensionlessNames() throws {
        let source = try folder("tree"),dest = try folder("dest")
        for name in ["Bericht.TXT","café.md","a1.txt","a2.txt","README","literal[1].txt","other.bin"] { try file("tree/"+name) }
        var filter = TransferFilter();filter.include = "*.txt; cafe\u{301}.md; README";filter.exclude = "a?.txt;literal[1].txt"
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(Set(plannedObjects(plan).filter { $0.kind == .file }.map { $0.source.lastPathComponent }),["Bericht.TXT","café.md","README"])
        filter.include = "*.*";filter.exclude = ""
        let all = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(all.entries[0].fileCount,7)
    }
    func testCopyFilterRegularExpressionsAndInvalidInputs() throws {
        let source = try folder("tree"),dest = try folder("dest")
        for name in ["note-01.txt","note-02.txt","note-03.md","other.txt"] { try file("tree/"+name) }
        var filter = TransferFilter();filter.regularExpressions = true;filter.include = "^note-[0-9]+\\.txt$";filter.exclude = "02"
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(plannedObjects(plan).filter { $0.kind == .file }.map { $0.source.lastPathComponent },["note-01.txt"])
        filter.include = "[";XCTAssertThrowsError(try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter))
        filter.regularExpressions = false;filter.include = "sub/*.txt";XCTAssertThrowsError(try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter))
        filter.include = String(repeating:"x",count:4097);XCTAssertThrowsError(try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter))
        filter.include = Array(repeating:"*.txt",count:129).joined(separator:";");XCTAssertThrowsError(try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter))
        XCTAssertTrue(try relativeObjects(dest).isEmpty)
    }
    func testFilteredCopyMatchesPreviewAndByteCountExactly() throws {
        let source = try folder("tree"),dest = try folder("dest")
        try file("tree/docs/alpha.txt","text");try file("tree/docs/beta.tmp","tmp");try file("tree/docs/nested/keep.MD","md")
        try file("tree/cache/secret.txt","secret");try file("tree/README","read");try folder("tree/empty");try file("tree/tmpOnly/file.tmp","tmp")
        let top = try file("rootfile.md","top"),skip = try file("skip.md","skip")
        var filter = TransferFilter();filter.include = "*.txt;*.md";filter.exclude = "skip*";filter.excludedFolders = "cache";filter.keepEmptyFolders = false
        let plan = try TransferPlanner.prepare([source,top,skip],to:dest,kind:.copy,policy:.stop,filter:filter)
        let expected: Set<String> = ["tree","tree/docs","tree/docs/alpha.txt","tree/docs/nested","tree/docs/nested/keep.MD","rootfile.md"]
        XCTAssertEqual(Set(plannedObjects(plan).map(\.relativePath)),expected);XCTAssertEqual(plan.bytes,9)
        var last: TransferProgress?
        let report = TransferPlanner.execute(plan) { last = $0 }
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(try relativeObjects(dest),expected)
        XCTAssertEqual(last?.bytes,9);XCTAssertEqual(last?.totalBytes,9);XCTAssertEqual(last?.fraction,1)
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/docs/alpha.txt")),"text")
        XCTAssertEqual(try read(source.appendingPathComponent("cache/secret.txt")),"secret");XCTAssertEqual(try read(skip),"skip")
    }
    func testCopyFilterKeepsOrPrunesEmptyOutputFolders() throws {
        let source = try folder("tree"),dest = try folder("dest");try folder("tree/empty/deep");try file("tree/filtered/no.bin")
        var filter = TransferFilter();filter.include = "*.txt"
        let keep = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(Set(plannedObjects(keep).map(\.relativePath)),["tree","tree/empty","tree/empty/deep","tree/filtered"])
        filter.keepEmptyFolders = false
        let prune = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter)
        XCTAssertTrue(prune.entries.isEmpty);XCTAssertTrue(TransferPlanner.execute(prune).errors.isEmpty)
        XCTAssertTrue(try relativeObjects(dest).isEmpty)
        XCTAssertTrue(TransferPlanner.execute(keep).errors.isEmpty)
        XCTAssertEqual(try relativeObjects(dest),Set(plannedObjects(keep).map(\.relativePath)))
    }
    func testCopyFilterCanLimitToDirectChildren() throws {
        let source = try folder("tree"),dest = try folder("dest");try file("tree/top.txt");try file("tree/deep/nested.txt");try folder("tree/empty")
        var filter = TransferFilter();filter.recursive = false;filter.excludedFolders = "ignored/path"
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(Set(plannedObjects(plan).map(\.relativePath)),["tree","tree/top.txt"])
        XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty);XCTAssertEqual(try relativeObjects(dest),["tree","tree/top.txt"])
    }
    func testCopyFilterPrunesExcludedSubtreesBeforeReadingTheirContents() throws {
        let source = try folder("cache"),dest = try folder("dest")
        try file("cache/keep.txt");try file("cache/cache/hidden.txt");try folder("cache/cache/build")
        let pipe = source.appendingPathComponent("cache/build/pipe.txt")
        XCTAssertEqual(mkfifo(pipe.path,0o600),0)
        var filter = TransferFilter();filter.excludedFolders = "CACHE"
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter)
        // A selected root remains selected; the rule applies only to its descendants.
        XCTAssertEqual(Set(plannedObjects(plan).map(\.relativePath)),["cache","cache/keep.txt"])
        filter.excludedFolders = "";XCTAssertThrowsError(try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter))
        XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty)
        XCTAssertTrue(FileSystem.exists(pipe));XCTAssertEqual(try relativeObjects(dest),["cache","cache/keep.txt"])
    }
    func testStructureOnlyCopiesFoldersAndNoLinksOrFileData() throws {
        let source = try folder("tree"),dest = try folder("dest");try file("tree/a/data.txt");try folder("tree/a/empty");try file("outside","secret")
        try FileManager.default.createSymbolicLink(atPath:source.appendingPathComponent("external").path,withDestinationPath:"../outside")
        var filter = TransferFilter();filter.structureOnly = true;filter.keepEmptyFolders = false;filter.regularExpressions = true;filter.include = "["
        let plan = try TransferPlanner.prepare([source,root.appendingPathComponent("outside")],to:dest,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(plan.bytes,0);XCTAssertTrue(plannedObjects(plan).allSatisfy { $0.kind == .directory })
        XCTAssertEqual(Set(plannedObjects(plan).map(\.relativePath)),["tree","tree/a","tree/a/empty"])
        XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty)
        XCTAssertEqual(try relativeObjects(dest),["tree","tree/a","tree/a/empty"]);XCTAssertEqual(try read(root.appendingPathComponent("outside")),"secret")
    }
    func testCopyFilterTreatsSymbolicLinksAsLinksWithoutTraversal() throws {
        let source = try folder("tree"),dest = try folder("dest");try file("outside/private.txt","private")
        try FileManager.default.createSymbolicLink(atPath:source.appendingPathComponent("alias.txt").path,withDestinationPath:"../outside")
        var filter = TransferFilter();filter.include = "*.txt"
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(plan.entries[0].fileCount,0);XCTAssertEqual(plan.entries[0].linkCount,1);XCTAssertEqual(plan.bytes,0)
        XCTAssertEqual(plannedObjects(plan).filter { $0.kind == .symbolicLink }.map(\.relativePath),["tree/alias.txt"])
        XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:dest.appendingPathComponent("tree/alias.txt").path),"../outside")
        XCTAssertEqual(try read(root.appendingPathComponent("outside/private.txt")),"private")
    }
    func testFilteredPlanRejectsChangedOrNewMatchingFilesBeforeAnyCopy() throws {
        let first = try file("a.txt","first"),source = try folder("tree"),dest = try folder("dest");let child = try file("tree/data.txt","old")
        var filter = TransferFilter();filter.include = "*.txt";filter.keepEmptyFolders = false
        let plan = try TransferPlanner.prepare([first,source],to:dest,kind:.copy,policy:.stop,filter:filter)
        try "changed file".write(to:child,atomically:true,encoding:.utf8)
        XCTAssertFalse(TransferPlanner.execute(plan).errors.isEmpty);XCTAssertTrue(try relativeObjects(dest).isEmpty)
        let next = try TransferPlanner.prepare([first,source],to:dest,kind:.copy,policy:.stop,filter:filter)
        try file("tree/new.txt")
        XCTAssertFalse(TransferPlanner.execute(next).errors.isEmpty);XCTAssertTrue(try relativeObjects(dest).isEmpty)
    }
    func testCopyFilterNoMatchesAndEmptySelectionHaveDistinctResults() throws {
        let source = try file("skip.bin"),dest = try folder("dest")
        var filter = TransferFilter();filter.include = "*.txt"
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop,filter:filter)
        XCTAssertTrue(plan.entries.isEmpty);XCTAssertTrue(plan.initialItems.isEmpty);XCTAssertEqual(plan.bytes,0)
        XCTAssertThrowsError(try TransferPlanner.prepare([],to:dest,kind:.copy,policy:.stop,filter:filter))
        XCTAssertTrue(try relativeObjects(dest).isEmpty)
    }
    func testFilteredMoveStructureOnlyIsRejectedWithoutChangingSourceOrTarget() throws {
        let source = try folder("tree"),dest = try folder("dest");let file = try self.file("tree/keep.txt","original")
        var filter = TransferFilter();filter.include = "*.txt";filter.structureOnly = true
        XCTAssertThrowsError(try TransferPlanner.prepare([source],to:dest,kind:.move,policy:.stop,filter:filter))
        XCTAssertEqual(try read(file),"original");XCTAssertTrue(try relativeObjects(dest).isEmpty)
    }
    func testFilteredCopyCancellationRetainsExistingTargetAndExcludedFiles() throws {
        let source = try folder("tree"),dest = try folder("dest");let large = try largeFile("tree/large.bin");try file("tree/leave.txt","untouched")
        try file("dest/tree/old.txt","previous")
        var filter = TransferFilter();filter.include = "*.bin";filter.keepEmptyFolders = false
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.replace,filter:filter),token = CancellationToken()
        let report = TransferPlanner.execute(plan,token:token) { if $0.bytes > 0 { token.cancel() } }
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(dest.appendingPathComponent("tree/old.txt")),"previous")
        XCTAssertEqual(try relativeObjects(dest),["tree","tree/old.txt"])
        XCTAssertTrue(FileSystem.exists(large));XCTAssertEqual(try read(source.appendingPathComponent("leave.txt")),"untouched")
    }
    func testFilteredFolderReplacementKeepsPreviousFolderAsBackup() throws {
        let source = try folder("tree"),dest = try folder("dest")
        try file("tree/keep.txt","new");try file("tree/leave.bin","excluded source")
        try file("dest/tree/old.bin","previous target");try file("dest/tree/keep.txt","old text")
        var filter = TransferFilter();filter.include = "*.txt";filter.keepEmptyFolders = false
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.replace,filter:filter)
        let report = TransferPlanner.execute(plan)
        XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try read(dest.appendingPathComponent("tree/keep.txt")),"new")
        XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("tree/old.bin")))
        if let backup = report.undo.first?.backup {
            XCTAssertEqual(try read(backup.appendingPathComponent("old.bin")),"previous target")
            XCTAssertEqual(try read(backup.appendingPathComponent("keep.txt")),"old text")
        } else { XCTAssertTrue(false,"Previous destination folder backup is missing") }
        XCTAssertEqual(try read(source.appendingPathComponent("leave.bin")),"excluded source")
    }
}
