import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    private func mirror(_ options:CompareOptions = .init(),_ direction:SyncDirection = .leftToRight,skipping:Set<String> = []) throws -> FolderMirrorPlan {
        try FolderMirrorPlan.prepare(CompareService.compare(folder("left"),folder("right"),options:options),direction:direction,skipping:skipping)
    }
    private func mirrorHistory() throws -> TransferHistory { try TransferHistory(journal:TransferJournal(directory:root.appendingPathComponent("mirror-history"))) }
    func testMirrorPlansBothDirectionsWithoutMutating() throws {
        let left = try file("left/left.txt","left"),right = try file("right/right.txt","right");try file("left/shared.txt","new");try file("right/shared.txt","old")
        let ltr = try mirror(),rtl = try mirror(.init(),.rightToLeft)
        XCTAssertEqual(Set(ltr.copies.steps.map(\.path)),Set(["left.txt","shared.txt"]));XCTAssertEqual(ltr.removals.map(\.path),["right.txt"])
        XCTAssertEqual(Set(rtl.copies.steps.map(\.path)),Set(["right.txt","shared.txt"]));XCTAssertEqual(rtl.removals.map(\.path),["left.txt"])
        XCTAssertEqual(try read(left),"left");XCTAssertEqual(try read(right),"right");XCTAssertTrue(ltr.initialItems.allSatisfy { $0.state == .waiting })
        XCTAssertThrowsError(try mirror(.init(),.skip));XCTAssertThrowsError(try mirror(skipping:["unknown"]))
    }
    func testMirrorPreservesWholeRemovedTreeAndSupportsDirectoryUndo() throws {
        try folder("left");try file("right/Extra/sub/a.txt","alpha");try file("right/Extra/b.txt","beta");try folder("right/Extra/empty")
        let plan = try mirror();XCTAssertEqual(plan.removals.count,1);XCTAssertEqual(plan.removals[0].members.count,5)
        let report = FolderMirrorEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(report.undo.count,1)
        XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/Extra")));XCTAssertEqual(try read(plan.removals[0].stored.appendingPathComponent("sub/a.txt")),"alpha")
        XCTAssertEqual(FileOperations.undo(report.undo),[]);XCTAssertEqual(try read(root.appendingPathComponent("right/Extra/b.txt")),"beta");XCTAssertTrue(FileSystem.isDirectory(root.appendingPathComponent("right/Extra/empty")))
    }
    func testMirrorFiltersKeepHiddenExcludedAndUnselectedObjects() throws {
        try folder("left");try file("right/Extra/a.txt","remove");try file("right/Extra/keep.bin","keep");try file("right/Cache/private.txt","cache");try file("right/.secret.txt","hidden")
        var options = CompareOptions();options.include = "*.txt";options.excludedFolders = "Cache";options.showHidden = false
        let plan = try mirror(options);XCTAssertEqual(plan.removals.map(\.path),["Extra/a.txt"]);XCTAssertTrue(plan.retained.contains { $0.path == "Extra" })
        let report = FolderMirrorEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"))
        XCTAssertEqual(try read(root.appendingPathComponent("right/Extra/keep.bin")),"keep");XCTAssertEqual(try read(root.appendingPathComponent("right/Cache/private.txt")),"cache");XCTAssertEqual(try read(root.appendingPathComponent("right/.secret.txt")),"hidden")
        XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/Extra/a.txt")))
    }
    func testMirrorNonrecursivePlanRetainsUnknownChildren() throws {
        try folder("left");try file("right/Deep/a.txt","keep");try folder("right/Empty")
        var options = CompareOptions();options.recursive = false
        let plan = try mirror(options);XCTAssertEqual(plan.removals.map(\.path),["Empty"]);XCTAssertTrue(plan.retained.contains { $0.path == "Deep" })
        XCTAssertTrue(FolderMirrorEngine.execute(plan).errors.isEmpty);XCTAssertEqual(try read(root.appendingPathComponent("right/Deep/a.txt")),"keep")
    }
    func testMirrorBlocksLinksSpecialFilesAndConflictingDescendants() throws {
        try file("left/Object","source");try file("right/Object/deep/child.txt","keep");let outside = try file("outside/secret.txt","outside");let right = try folder("right")
        try FileManager.default.createSymbolicLink(at:right.appendingPathComponent("Alias"),withDestinationURL:outside);XCTAssertEqual(mkfifo(right.appendingPathComponent("Pipe").path,0o600),0);try file("right/Extra.txt","remove")
        let plan = try mirror();XCTAssertEqual(plan.removals.map(\.path),["Extra.txt"]);XCTAssertTrue(plan.retained.contains { $0.path == "Alias" },plan.retained.map(\.path).joined(separator:","));XCTAssertTrue(plan.retained.contains { $0.path == "Object/deep/child.txt" },plan.retained.map(\.path).joined(separator:","))
        XCTAssertTrue(FolderMirrorEngine.execute(plan).errors.isEmpty);XCTAssertEqual(try read(outside),"outside");XCTAssertTrue(FileSystem.isSymlink(right.appendingPathComponent("Alias")));XCTAssertEqual(try read(right.appendingPathComponent("Object/deep/child.txt")),"keep")
    }
    func testMirrorSkippingChildRetainsItsAncestorsAndOtherChoices() throws {
        try folder("left");try file("right/Extra/a.txt","keep");try file("right/Extra/b.txt","remove")
        let plan = try mirror(skipping:["Extra/a.txt"]);XCTAssertEqual(plan.removals.map(\.path),["Extra/b.txt"]);XCTAssertTrue(plan.retained.contains { $0.path == "Extra" })
        XCTAssertTrue(FolderMirrorEngine.execute(plan).errors.isEmpty);XCTAssertEqual(try read(root.appendingPathComponent("right/Extra/a.txt")),"keep");XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/Extra/b.txt")))
    }
    func testMirrorSkippingWholeBranchPreservesEveryDescendant() throws {
        try folder("left");try file("right/Extra/sub/a.txt","keep");let plan = try mirror(skipping:["Extra"])
        XCTAssertTrue(plan.removals.isEmpty);XCTAssertTrue(FolderMirrorEngine.execute(plan).errors.isEmpty);XCTAssertEqual(try read(root.appendingPathComponent("right/Extra/sub/a.txt")),"keep")
    }
    func testMirrorStaleRootStopsBeforeCopyingOrRemoving() throws {
        try file("left/new.txt","source");try file("right/Extra.txt","keep");let plan = try mirror();try file("right/unreviewed.txt","foreign")
        let report = FolderMirrorEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.undo.isEmpty);XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/new.txt")));XCTAssertEqual(try read(root.appendingPathComponent("right/Extra.txt")),"keep")
    }
    func testMirrorSameSizeTargetMutationRejectsRemoval() throws {
        try folder("left");let extra = try file("right/Extra.txt","old!");let plan = try mirror(),date = try FileEntry(url:extra).modified
        try Data("new!".utf8).write(to:extra);try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:extra.path)
        let report = FolderMirrorEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(extra),"new!");XCTAssertTrue(report.undo.isEmpty)
    }
    func testMirrorNewDescendantRejectsWholePlanBeforeCopying() throws {
        try file("left/New.txt","source");try file("right/Extra/old.txt","old");let plan = try mirror();try file("right/Extra/new.txt","foreign")
        let report = FolderMirrorEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.undo.isEmpty);XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/New.txt")));XCTAssertEqual(try read(root.appendingPathComponent("right/Extra/new.txt")),"foreign")
    }
    func testMirrorNewSourceCounterpartStopsRemovalAfterSuccessfulCopies() throws {
        try file("left/New.txt","copy first");let extra = try file("right/Extra.txt","keep");let plan = try mirror();var injected = false,copiedFirst = false
        let report = FolderMirrorEngine.execute(plan,progress:{ value in
            if value.detail.hasPrefix("Entfernen mit Sicherung"),!injected { injected = true;copiedFirst = (try? self.read(self.root.appendingPathComponent("right/New.txt"))) == "copy first";try! Data("appeared".utf8).write(to:self.root.appendingPathComponent("left/Extra.txt")) }
        })
        XCTAssertTrue(injected);XCTAssertTrue(copiedFirst);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(extra),"keep");XCTAssertEqual(try read(root.appendingPathComponent("left/Extra.txt")),"appeared")
    }
    func testMirrorCancellationDuringCopyNeverRemovesExtraTargets() throws {
        let large = try file("left/Large.bin","");try Data(repeating:0x24,count:8*1024*1024).write(to:large);let extra = try file("right/Extra.txt","keep"),plan = try mirror(),token = CancellationToken();var progressed = false
        let report = FolderMirrorEngine.execute(plan,token:token,progress:{ value in if value.bytes > 0 && value.bytes < value.totalBytes { progressed = true;token.cancel() } })
        XCTAssertTrue(progressed);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(extra),"keep");XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/Large.bin")));XCTAssertTrue(report.undo.isEmpty)
    }
    func testMirrorCancellationKeepsCompletedRemovalRecoverable() throws {
        try folder("left");try file("right/a.txt","a");try file("right/b.txt","b");let plan = try mirror(),token = CancellationToken();var cancelled = false
        let report = FolderMirrorEngine.execute(plan,token:token,progress:{ value in if value.items.contains(where:{$0.state == .completed}),!cancelled { cancelled = true;token.cancel() } })
        XCTAssertTrue(cancelled);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.undo.count,1);XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/a.txt")));XCTAssertEqual(try read(root.appendingPathComponent("right/b.txt")),"b")
        XCTAssertEqual(FileOperations.undo(report.undo),[]);XCTAssertEqual(try read(root.appendingPathComponent("right/a.txt")),"a")
    }
    func testMirrorParentSwapBeforeRemovalPreservesMovedAndForeignData() throws {
        try folder("left/Common");try file("right/Common/Extra.txt","keep");try file("outside/sentinel.txt","foreign");let plan = try mirror(),parent = root.appendingPathComponent("right/Common"),moved = root.appendingPathComponent("moved"),outside = root.appendingPathComponent("outside");var injected = false;var last:TransferProgress?
        let report = FolderMirrorEngine.execute(plan,progress:{ value in last = value;if value.detail.hasPrefix("Entfernen mit Sicherung"),!injected { injected = true;try! FileManager.default.moveItem(at:parent,to:moved);try! FileManager.default.createSymbolicLink(at:parent,withDestinationURL:outside) } })
        XCTAssertTrue(injected);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.undo.isEmpty);XCTAssertEqual(try read(moved.appendingPathComponent("Extra.txt")),"keep");XCTAssertEqual(try read(outside.appendingPathComponent("sentinel.txt")),"foreign")
        XCTAssertTrue(last?.items.allSatisfy { $0.state != .running && $0.state != .waiting } == true)
    }
    func testMirrorRootMovedDuringCopyCannotPublishOutsideReviewedRoot() throws {
        let large = try file("left/Large.bin","");try Data(repeating:0x24,count:4*1024*1024).write(to:large);try file("right/Extra.txt","keep");let plan = try mirror(),target = root.appendingPathComponent("right"),moved = root.appendingPathComponent("moved"),outside = try folder("outside");var injected = false
        let report = FolderMirrorEngine.execute(plan,progress:{ value in if value.bytes > 0,!injected { injected = true;try! FileManager.default.moveItem(at:target,to:moved);try! FileManager.default.createSymbolicLink(at:target,withDestinationURL:outside) } })
        XCTAssertTrue(injected);XCTAssertFalse(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(outside.appendingPathComponent("Large.bin")));XCTAssertFalse(FileSystem.exists(moved.appendingPathComponent("Large.bin")));XCTAssertEqual(try read(moved.appendingPathComponent("Extra.txt")),"keep")
    }
    func testMirrorUndoRefusesNewOccupantAndKeepsStoredData() throws {
        try folder("left");let original = try file("right/Extra.txt","old"),plan = try mirror(),report = FolderMirrorEngine.execute(plan)
        XCTAssertTrue(report.errors.isEmpty);try Data("foreign".utf8).write(to:original)
        XCTAssertEqual(FileOperations.undo(report.undo).count,1);XCTAssertEqual(try read(original),"foreign");XCTAssertEqual(try read(plan.removals[0].stored),"old")
    }
    func testMirrorChangedStoredFileRefusesUndoEvenWithRestoredDate() throws {
        try folder("left");try file("right/Extra.txt","old!");let plan = try mirror(),report = FolderMirrorEngine.execute(plan),stored = plan.removals[0].stored,date = try FileEntry(url:stored).modified
        XCTAssertTrue(report.errors.isEmpty);try Data("new!".utf8).write(to:stored);try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:stored.path)
        XCTAssertEqual(FileOperations.undo(report.undo).count,1);XCTAssertEqual(try read(stored),"new!");XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/Extra.txt")))
    }
    func testMirrorChangedStoredDescendantRefusesDirectoryUndo() throws {
        try folder("left");try file("right/Extra/sub/a.txt","old!");let plan = try mirror(),report = FolderMirrorEngine.execute(plan),stored = plan.removals[0].stored
        XCTAssertTrue(report.errors.isEmpty);try Data("new!".utf8).write(to:stored.appendingPathComponent("sub/a.txt"))
        XCTAssertEqual(FileOperations.undo(report.undo).count,1);XCTAssertEqual(try read(stored.appendingPathComponent("sub/a.txt")),"new!");XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/Extra")))
    }
    func testMirrorDurableReceiptsSurviveReopenAndDeduplicate() throws {
        try folder("left");try file("right/Extra/sub/a.txt","old");let plan = try mirror(),path = root.appendingPathComponent("mirror-history/history.json")
        do { let history = try mirrorHistory(),report = FolderMirrorEngine.execute(plan,history:history);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));let before = try Data(contentsOf:path);try history.captureBackups(report.undo);XCTAssertEqual(try Data(contentsOf:path),before) }
        let history = try mirrorHistory(),items = history.inspect();XCTAssertEqual(items.count,1);XCTAssertTrue(items.first?.available == true);XCTAssertTrue(items.first?.note.contains("Entfernungssicherung") == true)
        XCTAssertEqual((try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])?["version"] as? Int,2)
        try history.restore(history.planRestore(items[0].id));XCTAssertEqual(try read(root.appendingPathComponent("right/Extra/sub/a.txt")),"old");XCTAssertTrue(history.inspect().isEmpty)
    }
    func testMirrorHistoryV1ReadIsPreservedAndPromotesOnlyForRemoval() throws {
        try file("source/a.txt","new");try file("dest/a.txt","old");let path = root.appendingPathComponent("mirror-history/history.json")
        do { let history = try mirrorHistory(),report = FileOperations.transfer([root.appendingPathComponent("source/a.txt")],to:root.appendingPathComponent("dest"),kind:.copy,policy:.replace);try history.captureBackups(report.undo) }
        let before = try Data(contentsOf:path);XCTAssertEqual((try JSONSerialization.jsonObject(with:before) as? [String:Any])?["version"] as? Int,1)
        do { let history = try mirrorHistory();XCTAssertEqual(history.inspect().count,1);XCTAssertEqual(try Data(contentsOf:path),before) }
        try folder("left");try file("right/Extra.txt","remove")
        do { let history = try mirrorHistory(),report = FolderMirrorEngine.execute(try mirror(),history:history);XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(history.inspect().count,2) }
        XCTAssertEqual((try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])?["version"] as? Int,2)
    }
    func testMirrorHistoryRejectsMislabeledReceiptsAndFutureVersions() throws {
        try folder("left");try file("right/Extra.txt","remove");let path = root.appendingPathComponent("mirror-history/history.json")
        do { let history = try mirrorHistory();XCTAssertTrue(FolderMirrorEngine.execute(try mirror(),history:history).errors.isEmpty) }
        let valid = try Data(contentsOf:path);var object = try JSONSerialization.jsonObject(with:valid) as! [String:Any]
        for version in [1,3] { object["version"] = version;let foreign = try JSONSerialization.data(withJSONObject:object,options:.sortedKeys);try foreign.write(to:path);XCTAssertThrowsError(try mirrorHistory());XCTAssertEqual(try Data(contentsOf:path),foreign) }
        try valid.write(to:path);XCTAssertEqual(try mirrorHistory().inspect().count,1)
    }
    func testMirrorHistoryFailureBeforeRemovalPreservesEveryTarget() throws {
        try folder("left");let original = try file("right/Extra.txt","keep"),plan = try mirror(),history = try mirrorHistory(),path = root.appendingPathComponent("mirror-history/history.json"),foreign = Data("foreign history".utf8);try foreign.write(to:path)
        let report = FolderMirrorEngine.execute(plan,history:history);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.undo.isEmpty);XCTAssertEqual(try read(original),"keep");XCTAssertEqual(try Data(contentsOf:path),foreign)
    }
    func testMirrorHistoryFailureAfterRemovalRetainsCompletedReceipt() throws {
        try folder("left");try file("right/a.txt","a");try file("right/b.txt","b");let plan = try mirror(),history = try mirrorHistory(),path = root.appendingPathComponent("mirror-history/history.json"),foreign = Data("foreign history".utf8);var injected = false
        let report = FolderMirrorEngine.execute(plan,history:history,progress:{ value in if value.items.first?.state == .completed,!injected { injected = true;try! foreign.write(to:path) } })
        XCTAssertTrue(injected);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.undo.count,1);XCTAssertEqual(try Data(contentsOf:path),foreign);XCTAssertEqual(try read(root.appendingPathComponent("right/b.txt")),"b")
        XCTAssertEqual(FileOperations.undo(report.undo),[]);XCTAssertEqual(try read(root.appendingPathComponent("right/a.txt")),"a")
    }
    func testMirrorRecoveryRefusesChangedBackupAndNewOriginalOccupant() throws {
        try folder("left");try file("right/Extra/sub/a.txt","old");let plan = try mirror(),history = try mirrorHistory(),report = FolderMirrorEngine.execute(plan,history:history);XCTAssertTrue(report.errors.isEmpty)
        let item = history.inspect()[0];try Data("foreign".utf8).write(to:root.appendingPathComponent("right/Extra"));XCTAssertThrowsError(try history.planRestore(item.id));XCTAssertEqual(try read(root.appendingPathComponent("right/Extra")),"foreign")
        try FileManager.default.removeItem(at:root.appendingPathComponent("right/Extra"));try Data("changed".utf8).write(to:item.stored.appendingPathComponent("sub/a.txt"));XCTAssertFalse(history.inspect()[0].available);XCTAssertThrowsError(try history.planRestore(item.id));XCTAssertThrowsError(try history.discard(item.id));XCTAssertEqual(try read(item.stored.appendingPathComponent("sub/a.txt")),"changed")
    }
    func testMirrorProgressIncludesBothPhasesAndAllItemsFinish() throws {
        try file("left/New.txt","source");try file("right/Extra.txt","old");let plan = try mirror();var last:TransferProgress?
        let report = FolderMirrorEngine.execute(plan,progress:{ last = $0 });XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(last?.items.count,2);XCTAssertTrue(last?.items.allSatisfy { $0.state == .completed } == true);XCTAssertEqual(last?.fraction,1);XCTAssertEqual(last?.bytes,6);XCTAssertEqual(last?.totalBytes,6)
    }
    func testMirrorLinksAndReservedFilesDoNotHideFollowingRealSubtrees() throws {
        let outside = try folder("outside");try file("outside/private.txt","outside");let left = try folder("left")
        try FileManager.default.createSymbolicLink(at:left.appendingPathComponent("Alias"),withDestinationURL:outside)
        try file("left/.zweicommander-backup-existing","reserved");try file("left/Visible/sub/a.txt","copy");try folder("right")
        let plan = try mirror();XCTAssertTrue(plan.copies.steps.contains { $0.path == "Visible/sub/a.txt" });XCTAssertFalse(plan.copies.steps.contains { $0.path.contains("Alias/") || $0.path.contains(".zweicommander-") })
        let report = FolderMirrorEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(try read(root.appendingPathComponent("right/Visible/sub/a.txt")),"copy");XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/Alias/private.txt")));XCTAssertEqual(try read(outside.appendingPathComponent("private.txt")),"outside")
    }
    func testMirrorExistingBackupsRetainParentButNotUnrelatedCompleteSubtrees() throws {
        try folder("left");try file("right/Extra/.zweicommander-backup-existing","reserved");try file("right/Extra/Visible/sub/a.txt","remove")
        let plan = try mirror();XCTAssertEqual(plan.removals.map(\.path),["Extra/Visible"]);XCTAssertTrue(plan.retained.contains { $0.path == "Extra" })
        let report = FolderMirrorEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(try read(root.appendingPathComponent("right/Extra/.zweicommander-backup-existing")),"reserved");XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/Extra/Visible")))
        XCTAssertEqual(FileOperations.undo(report.undo),[]);XCTAssertEqual(try read(root.appendingPathComponent("right/Extra/Visible/sub/a.txt")),"remove")
    }
    func testMirrorFinderHiddenSourceCounterpartsNeverAuthorizeRemovals() throws {
        let sourceFile = try file("left/VisibleName.txt","source"),sourceFolder = try folder("left/Folder");try file("left/Folder/a.txt","source child");try file("right/VisibleName.txt","target");try file("right/Folder/a.txt","target child")
        XCTAssertEqual(chflags(sourceFile.path,UInt32(UF_HIDDEN)),0);XCTAssertEqual(chflags(sourceFolder.path,UInt32(UF_HIDDEN)),0)
        XCTAssertTrue(try sourceFile.resourceValues(forKeys:[.isHiddenKey]).isHidden == true);XCTAssertTrue(try sourceFolder.resourceValues(forKeys:[.isHiddenKey]).isHidden == true)
        var options = CompareOptions();options.showHidden = false
        let plan = try mirror(options);XCTAssertTrue(plan.copies.steps.isEmpty);XCTAssertTrue(plan.removals.isEmpty);XCTAssertEqual(Set(plan.retained.map(\.path)),Set(["VisibleName.txt","Folder","Folder/a.txt"]))
        XCTAssertTrue(FolderMirrorEngine.execute(plan).errors.isEmpty);XCTAssertEqual(try read(root.appendingPathComponent("right/VisibleName.txt")),"target");XCTAssertEqual(try read(root.appendingPathComponent("right/Folder/a.txt")),"target child")
    }
    private func mirrorMovedParentDuringProgress(nested:Bool,final:Bool) throws {
        try folder(nested ? "left/Common" : "left");let path = nested ? "Common/Extra/data.txt" : "Extra/data.txt";try file("right/"+path,"retained data")
        let plan = try mirror(),history = try mirrorHistory(),parent = root.appendingPathComponent(nested ? "right/Common" : "right"),moved = root.appendingPathComponent("Moved"),outside = try folder("outside"),name = plan.removals[0].stored.lastPathComponent;var injected = false
        let report = FolderMirrorEngine.execute(plan,history:history,progress:{ value in
            guard !injected,value.items.contains(where:{$0.state == .completed}),!final || value.detail.hasPrefix("Spiegelung abgeschlossen") else { return }
            injected = true;try! FileManager.default.moveItem(at:parent,to:moved);try! FileManager.default.createSymbolicLink(at:parent,withDestinationURL:outside);try! Data("foreign".utf8).write(to:outside.appendingPathComponent(name))
        })
        XCTAssertTrue(injected);XCTAssertFalse(report.errors.isEmpty,"A parent moved inside the synchronous progress callback must be reported before execute returns.")
        guard let step = report.undo.first else { throw CommanderError.message("Entfernungsbeleg fehlt.") }
        let expectedStored = moved.appendingPathComponent(name),expectedOriginal = moved.appendingPathComponent("Extra")
        XCTAssertEqual(step.current.path,expectedStored.path);XCTAssertEqual(step.original?.path,expectedOriginal.path)
        XCTAssertEqual(report.completed.first?.path,expectedOriginal.path);XCTAssertEqual(try read(expectedStored.appendingPathComponent("data.txt")),"retained data")
        let items = history.inspect();XCTAssertEqual(items.count,1);XCTAssertTrue(items.first?.available == true);XCTAssertEqual(items.first?.stored.path,expectedStored.path)
        let before = try Data(contentsOf:root.appendingPathComponent("mirror-history/history.json"));try history.captureBackups(report.undo);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("mirror-history/history.json")),before)
        XCTAssertEqual(FileOperations.undo(report.undo),[]);XCTAssertEqual(try read(expectedOriginal.appendingPathComponent("data.txt")),"retained data");XCTAssertEqual(try read(outside.appendingPathComponent(name)),"foreign")
    }
    func testMirrorRebasesRootMovedByCompletedProgress() throws { try mirrorMovedParentDuringProgress(nested:false,final:false) }
    func testMirrorRebasesParentMovedByCompletedProgress() throws { try mirrorMovedParentDuringProgress(nested:true,final:false) }
    func testMirrorRebasesRootMovedByFinalProgress() throws { try mirrorMovedParentDuringProgress(nested:false,final:true) }
    func testMirrorParentHandleReservationFailurePrecedesAllMutations() throws {
        try file("left/New.txt","source")
        for index in 0..<80 { try folder("left/Folder\(index)");try file("right/Folder\(index)/extra.txt","keep") }
        let plan = try mirror();XCTAssertEqual(plan.removals.count,80)
        var old = rlimit();guard getrlimit(RLIMIT_NOFILE,&old) == 0 else { throw CommanderError.message("Dateihandle-Grenze nicht lesbar.") }
        var limited = old;limited.rlim_cur = min(old.rlim_cur,64)
        guard setrlimit(RLIMIT_NOFILE,&limited) == 0 else { throw CommanderError.message("Private Testprozess-Grenze nicht setzbar.") }
        defer { var restore = old;_ = setrlimit(RLIMIT_NOFILE,&restore) }
        let report = FolderMirrorEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.undo.isEmpty);XCTAssertTrue(report.completed.isEmpty);XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("right/New.txt")))
        for index in 0..<80 { XCTAssertEqual(try read(root.appendingPathComponent("right/Folder\(index)/extra.txt")),"keep") }
    }
    func testMirrorFinalProgressCanRebaseAnEarlierCompletedParent() throws {
        try folder("left/A");try folder("left/B");try file("right/A/Extra.txt","a");try file("right/B/Extra.txt","b")
        let plan = try mirror(),history = try mirrorHistory(),moved = root.appendingPathComponent("Moved"),old = root.appendingPathComponent("right/A"),outside = try folder("outside"),first = plan.removals.first(where:{$0.path == "A/Extra.txt"})!;var injected = false
        let report = FolderMirrorEngine.execute(plan,history:history,progress:{ value in
            guard !injected,value.detail.hasPrefix("Spiegelung abgeschlossen") else { return };injected = true;try! FileManager.default.moveItem(at:old,to:moved);try! FileManager.default.createSymbolicLink(at:old,withDestinationURL:outside);try! Data("foreign".utf8).write(to:outside.appendingPathComponent(first.stored.lastPathComponent))
        })
        XCTAssertTrue(injected);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.undo.count,2)
        let rebased = report.undo.first(where:{$0.current.lastPathComponent == first.stored.lastPathComponent})
        XCTAssertEqual(rebased?.current.path,moved.appendingPathComponent(first.stored.lastPathComponent).path);XCTAssertEqual(rebased?.original?.path,moved.appendingPathComponent("Extra.txt").path)
        XCTAssertEqual(history.inspect().count,2);XCTAssertTrue(history.inspect().allSatisfy(\.available))
        let path = root.appendingPathComponent("mirror-history/history.json"),before = try Data(contentsOf:path);try history.captureBackups(report.undo);XCTAssertEqual(try Data(contentsOf:path),before)
        XCTAssertEqual(FileOperations.undo(report.undo),[]);XCTAssertEqual(try read(moved.appendingPathComponent("Extra.txt")),"a");XCTAssertEqual(try read(root.appendingPathComponent("right/B/Extra.txt")),"b");XCTAssertEqual(try read(outside.appendingPathComponent(first.stored.lastPathComponent)),"foreign")
    }
}
