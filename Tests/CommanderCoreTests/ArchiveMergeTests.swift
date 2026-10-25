import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    private func mergeArchive(_ files:[String:String],folders:[String] = []) throws -> ArchiveCatalog {
        let source = try folder("incoming")
        for (name,text) in files { try file("incoming/"+name,text);try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000)],ofItemAtPath:source.appendingPathComponent(name).path) }
        for name in folders { try folder("incoming/"+name) }
        let archive = root.appendingPathComponent("bundle.zip");try ArchiveService.pack([source],to:archive);return try ArchiveCatalog.read(archive)
    }
    private func mergePlan(_ catalog:ArchiveCatalog,_ destination:URL,policy:ArchiveConflictPolicy = .review) throws -> ArchiveMergePlan {
        try ArchiveMergePlan(catalog:catalog,to:destination,selection:catalog.contents(of:"incoming").map(\.path),relativeTo:"incoming",policy:policy)
    }
    private func noArchiveStages(_ directory:URL) throws -> Bool { try !FileManager.default.contentsOfDirectory(atPath:directory.path).contains { $0.hasPrefix(".zweicommander-extract-") } }
    func testArchiveMergePreviewFreezesConflictsWithoutWriting() throws {
        let catalog = try mergeArchive(["a.txt":"new","Dir/new.txt":"nested"]),target = try folder("target/Dir").deletingLastPathComponent()
        try file("target/a.txt","old");try file("target/Dir/keep.txt","keep")
        let before = try FileManager.default.contentsOfDirectory(atPath:target.path),plan = try mergePlan(catalog,target)
        XCTAssertEqual(plan.unresolvedCount,1);XCTAssertEqual(plan.conflictCount,1);XCTAssertEqual(plan.action(for:"a.txt")?.targetInfo?.bytes,3)
        XCTAssertEqual(plan.description(of:plan.action(for:"Dir")!),"Ordner beibehalten");XCTAssertEqual(before,try FileManager.default.contentsOfDirectory(atPath:target.path))
        let report = ArchiveService.extract(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"old");XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("Dir/new.txt")))
    }
    func testArchiveMergeMixedDecisionsAndRecoverableBackups() throws {
        let catalog = try mergeArchive(["a.txt":"new-a","b.txt":"new-b","c.txt":"new-c","d.txt":"new-d"]),target = try folder("target")
        for name in ["a","b","c","d"] { try file("target/"+name+".txt","old-"+name) };try file("target/extra.txt","keep")
        var plan = try mergePlan(catalog,target)
        plan = try plan.resolving("a.txt",with:.skip).resolving("b.txt",with:.keepBoth).resolving("c.txt",with:.replace).resolving("d.txt",with:.rename("manual.txt"))
        XCTAssertEqual(plan.unresolvedCount,0);let report = ArchiveService.extract(plan)
        XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"old-a");XCTAssertEqual(try read(target.appendingPathComponent("b.txt")),"old-b")
        XCTAssertEqual(try read(target.appendingPathComponent("b (2).txt")),"new-b");XCTAssertEqual(try read(target.appendingPathComponent("c.txt")),"new-c")
        XCTAssertEqual(try read(target.appendingPathComponent("d.txt")),"old-d");XCTAssertEqual(try read(target.appendingPathComponent("manual.txt")),"new-d");XCTAssertEqual(try read(target.appendingPathComponent("extra.txt")),"keep")
        let saved = report.undo.first { $0.backup != nil }!;XCTAssertEqual(try read(saved.backup!),"old-c");XCTAssertEqual(saved.backup?.deletingLastPathComponent(),saved.current.deletingLastPathComponent())
        let history = try TransferHistory(journal:TransferJournal(directory:root.appendingPathComponent("journal")));try history.captureBackups(report.undo)
        XCTAssertEqual(history.inspect().filter(\.available).count,1);try history.restore(history.planRestore(history.inspect()[0].id));XCTAssertEqual(try read(target.appendingPathComponent("c.txt")),"old-c")
        XCTAssertTrue(try noArchiveStages(target))
    }
    func testArchiveMergePoliciesRespectDatesAndExplicitOverrides() throws {
        let catalog = try mergeArchive(["older.txt":"new","newer.txt":"new","same.txt":"new"]),target = try folder("target")
        for (name,date) in [("older",1_699_999_900.0),("newer",1_700_000_100.0),("same",1_700_000_000.0)] { let f = try file("target/"+name+".txt","old");try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:date)],ofItemAtPath:f.path) }
        var plan = try mergePlan(catalog,target,policy:.replaceOlder)
        XCTAssertEqual(plan.action(for:"older.txt")?.decision,.replace);XCTAssertEqual(plan.action(for:"newer.txt")?.decision,.skip);XCTAssertEqual(plan.action(for:"same.txt")?.decision,.skip)
        plan = try plan.resolving("newer.txt",with:.replace);let report = ArchiveService.extract(plan);XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(try read(target.appendingPathComponent("older.txt")),"new");XCTAssertEqual(try read(target.appendingPathComponent("newer.txt")),"new");XCTAssertEqual(try read(target.appendingPathComponent("same.txt")),"old")
    }
    func testArchiveMergeTypeConflictsCanRenameWholeSubtreeWithoutFollowingLinks() throws {
        let catalog = try mergeArchive(["Dir/child.txt":"new"]),target = try folder("target"),outside = try folder("outside")
        try file("outside/keep.txt","keep");try FileManager.default.createSymbolicLink(at:target.appendingPathComponent("Dir"),withDestinationURL:outside)
        var plan = try mergePlan(catalog,target);XCTAssertEqual(plan.unresolvedCount,1);XCTAssertThrowsError(try plan.resolving("Dir",with:.replace))
        plan = try plan.resolving("Dir",with:.rename("Other"));XCTAssertEqual(plan.targetPath(for:plan.action(for:"Dir/child.txt")!),"Other/child.txt")
        let report = ArchiveService.extract(plan);XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("Other/child.txt")),"new")
        XCTAssertTrue(FileSystem.isSymlink(target.appendingPathComponent("Dir")));XCTAssertFalse(FileSystem.exists(outside.appendingPathComponent("child.txt")));XCTAssertEqual(try read(outside.appendingPathComponent("keep.txt")),"keep")
    }
    func testArchiveMergeFileDirectoryConflictKeepBothAndSkipSubtrees() throws {
        let catalog = try mergeArchive(["item.txt":"new","Dir/child.txt":"new"]),target = try folder("target/item.txt").deletingLastPathComponent()
        try file("target/item.txt/keep","keep");try file("target/Dir","existing file")
        var plan = try mergePlan(catalog,target);XCTAssertEqual(plan.unresolvedCount,2);XCTAssertThrowsError(try plan.resolving("item.txt",with:.replace))
        plan = try plan.resolving("item.txt",with:.keepBoth).resolving("Dir",with:.skip)
        let report = ArchiveService.extract(plan);XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("item (2).txt")),"new");XCTAssertEqual(try read(target.appendingPathComponent("Dir")),"existing file")
        XCTAssertEqual(plan.skippedCount,2);XCTAssertEqual(try read(target.appendingPathComponent("item.txt/keep")),"keep")
    }
    func testArchiveMergeChangedTargetAndOccupiedRenameBlockBeforeWrites() throws {
        let catalog = try mergeArchive(["a.txt":"new","b.txt":"new"]),target = try folder("target");try file("target/a.txt","old")
        let plan = try mergePlan(catalog,target,policy:.replace);try file("target/a.txt","changed")
        XCTAssertFalse(ArchiveService.extract(plan).errors.isEmpty);XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("b.txt")))
        let renamed = try mergePlan(catalog,target,policy:.keepBoth);try file("target/a (2).txt","taken")
        XCTAssertFalse(ArchiveService.extract(renamed).errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("a (2).txt")),"taken");XCTAssertTrue(try noArchiveStages(target))
    }
    func testArchiveMergeCancellationDuringReadLeavesOriginalTree() throws {
        let catalog = try mergeArchive(["a.txt":String(repeating:"a",count:300_000)]),target = try folder("target");try file("target/a.txt","old")
        let plan = try mergePlan(catalog,target,policy:.replace),token = CancellationToken()
        let report = ArchiveService.extract(plan,token:token,progress:{ if $0.bytes > 0 { token.cancel() } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"old");XCTAssertTrue(try noArchiveStages(target))
    }
    func testArchiveMergeCancellationAfterPublicationRestoresPriorFiles() throws {
        let catalog = try mergeArchive(["a.txt":"new-a","b.txt":"new-b"]),target = try folder("target");try file("target/a.txt","old-a");try file("target/keep.txt","keep")
        let token = CancellationToken(),plan = try mergePlan(catalog,target,policy:.replace)
        let report = ArchiveService.extract(plan,token:token,progress:{ if $0.items.contains(where:{$0.state == .completed && $0.totalBytes > 0}) { token.cancel() } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"old-a");XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("b.txt")));XCTAssertEqual(try read(target.appendingPathComponent("keep.txt")),"keep")
        XCTAssertTrue(report.undo.isEmpty);XCTAssertTrue(try noArchiveStages(target))
    }
    func testArchiveMergeConcurrentFileAfterBackupIsPreservedWithRecovery() throws {
        let catalog = try mergeArchive(["a.txt":"new"]),target = try folder("target");try file("target/a.txt","old");let plan = try mergePlan(catalog,target,policy:.replace)
        var changed = false
        let report = ArchiveService.extract(plan,progress:{ if !changed && $0.detail.hasPrefix("Sichere bisherigen") { changed = true;try? Data("concurrent".utf8).write(to:target.appendingPathComponent("a.txt")) } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"concurrent");XCTAssertEqual(try read(report.undo.first!.backup!),"old")
        XCTAssertFalse(FileOperations.undo(report.undo).isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"concurrent")
    }
    func testArchiveMergeLaterEditsSurviveCancellationAndRetainBackup() throws {
        let catalog = try mergeArchive(["a.txt":"new-a","b.txt":"new-b"]),target = try folder("target");try file("target/a.txt","old")
        let token = CancellationToken(),plan = try mergePlan(catalog,target,policy:.replace);var changed = false
        let report = ArchiveService.extract(plan,token:token,progress:{ if !changed && $0.items.contains(where:{$0.state == .completed && $0.totalBytes > 0}) { changed = true;try? Data("edited after publication".utf8).write(to:target.appendingPathComponent("a.txt"));token.cancel() } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"edited after publication");XCTAssertEqual(try read(report.undo.first!.backup!),"old");XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("b.txt")))
    }
    func testArchiveMergeNewConcurrentTargetIsNeverRemoved() throws {
        let catalog = try mergeArchive(["a.txt":"new"]),target = try folder("target"),plan = try mergePlan(catalog,target);var changed = false
        let report = ArchiveService.extract(plan,progress:{ if !changed && $0.detail == "Übernehme · a.txt" { changed = true;try? Data("concurrent".utf8).write(to:target.appendingPathComponent("a.txt")) } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"concurrent");XCTAssertTrue(try noArchiveStages(target))
    }
    func testArchiveMergeRootAndDescendantReplacementCannotRedirectWrites() throws {
        let catalog = try mergeArchive(["Dir/new.txt":"new"]),target = try folder("target/Dir").deletingLastPathComponent(),outside = try folder("outside"),saved = root.appendingPathComponent("saved")
        let plan = try mergePlan(catalog,target);var changed = false
        let report = ArchiveService.extract(plan,progress:{ if !changed && $0.detail.hasPrefix("Entpacke") { changed = true;try? FileManager.default.moveItem(at:target,to:saved);try? FileManager.default.createSymbolicLink(at:target,withDestinationURL:outside) } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(outside.appendingPathComponent("Dir/new.txt")));XCTAssertFalse(FileSystem.exists(saved.appendingPathComponent("Dir/new.txt")));XCTAssertTrue(try noArchiveStages(saved))
        XCTAssertThrowsError(try mergePlan(catalog,target))
    }
    func testArchiveMergeChangedNestedParentIsNeverTraversed() throws {
        let catalog = try mergeArchive(["Dir/new.txt":"new"]),target = try folder("target/Dir").deletingLastPathComponent(),outside = try folder("outside"),saved = target.appendingPathComponent("saved")
        let plan = try mergePlan(catalog,target);var changed = false
        let report = ArchiveService.extract(plan,progress:{ if !changed && $0.detail == "Übernehme · Dir/new.txt" { changed = true;try? FileManager.default.moveItem(at:target.appendingPathComponent("Dir"),to:saved);try? FileManager.default.createSymbolicLink(at:target.appendingPathComponent("Dir"),withDestinationURL:outside) } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(outside.appendingPathComponent("new.txt")));XCTAssertFalse(FileSystem.exists(saved.appendingPathComponent("new.txt")))
    }
    func testArchiveMergeChangedArchiveNeverPublishes() throws {
        let catalog = try mergeArchive(["a.txt":"new"]),target = try folder("target"),plan = try mergePlan(catalog,target);var changed = false
        let report = ArchiveService.extract(plan,progress:{ if !changed && $0.detail.hasPrefix("Entpacke") { changed = true;try? Data("changed archive".utf8).write(to:catalog.source) } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("a.txt")));XCTAssertTrue(try noArchiveStages(target))
    }
    func testArchiveMergeFrozenAlternatesReserveOtherIncomingNames() throws {
        let catalog = try mergeArchive(["a.txt":"new-a","a (2).txt":"incoming-second"]),target = try folder("target");try file("target/a.txt","old")
        let plan = try mergePlan(catalog,target,policy:.keepBoth);XCTAssertEqual(plan.targetPath(for:plan.action(for:"a.txt")!),"a (3).txt")
        let report = ArchiveService.extract(plan);XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("a (2).txt")),"incoming-second");XCTAssertEqual(try read(target.appendingPathComponent("a (3).txt")),"new-a")
    }
    func testArchiveMergeRenameRejectsTraversalReservedAndExistingNames() throws {
        let catalog = try mergeArchive(["a.txt":"new","b.txt":"new"]),target = try folder("target");try file("target/a.txt","old");try file("target/taken","keep")
        let plan = try mergePlan(catalog,target)
        for name in ["../escape","/outside","..","b.txt","taken","A.TXT",""] { XCTAssertThrowsError(try plan.resolving("a.txt",with:.rename(name))) }
        XCTAssertThrowsError(try plan.resolving("b.txt",with:.replace));XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"old")
    }
    func testArchiveMergeIndividualDeepFileCreatesOnlyRequiredParents() throws {
        let catalog = try mergeArchive(["Dir/Sub/a.txt":"new","other.txt":"skip"]),target = try folder("target")
        let plan = try ArchiveMergePlan(catalog:catalog,to:target,selection:["incoming/Dir/Sub/a.txt"],relativeTo:"incoming")
        XCTAssertEqual(Set(plan.rows.map(\.path)),["Dir","Dir/Sub","Dir/Sub/a.txt"])
        let report = ArchiveService.extract(plan);XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("Dir/Sub/a.txt")),"new");XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("other.txt")))
    }
    func testArchiveMergeKeepsExistingPermissionsAndEmptyDirectories() throws {
        let catalog = try mergeArchive(["Dir/a.txt":"new"],folders:["Empty"]),target = try folder("target/Dir").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions:0o750],ofItemAtPath:target.appendingPathComponent("Dir").path)
        let report = ArchiveService.extract(try mergePlan(catalog,target));XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:target.appendingPathComponent("Dir").path)[.posixPermissions] as? NSNumber)?.intValue,0o750);XCTAssertTrue(FileSystem.isDirectory(target.appendingPathComponent("Empty")))
    }
    func testArchiveMergeAllSkippedNeedsNoPayloadAndReportsSkippedItems() throws {
        let catalog = try mergeArchive(["a.txt":"new"]),target = try folder("target");try file("target/a.txt","old")
        let plan = try mergePlan(catalog,target,policy:.skip);var snapshot:TransferProgress?
        let report = ArchiveService.extract(plan,password:"unused",progress:{snapshot=$0})
        XCTAssertTrue(report.errors.isEmpty);XCTAssertTrue(report.completed.isEmpty);XCTAssertEqual(report.skipped.count,1);XCTAssertEqual(snapshot?.fraction,1);XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"old");XCTAssertTrue(try noArchiveStages(target))
    }
    func testArchiveMergeLongNamesProduceValidFrozenAlternates() throws {
        let name = String(repeating:"a",count:247)+".txt",catalog = try mergeArchive([name:"new"]),target = try folder("target");try file("target/"+name,"old")
        let plan = try mergePlan(catalog,target,policy:.keepBoth),other = plan.targetPath(for:plan.actions[0]);XCTAssertTrue(other.utf8.count <= 255);XCTAssertTrue(other.hasSuffix(" (2).txt"))
        let report = ArchiveService.extract(plan);XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent(other)),"new")
    }
    func testArchiveMergeProtectsTheSourceArchiveFromReplacement() throws {
        let incoming = try folder("incoming"),target = try folder("target");try file("incoming/bundle.zip","member contents")
        let source = target.appendingPathComponent("bundle.zip");try ArchiveService.pack([incoming],to:source);let original = try Data(contentsOf:source),catalog = try ArchiveCatalog.read(source)
        let plan = try mergePlan(catalog,target,policy:.replace);XCTAssertEqual(plan.unresolvedCount,1);XCTAssertThrowsError(try plan.resolving("bundle.zip",with:.replace))
        let report = ArchiveService.extract(try plan.resolving("bundle.zip",with:.keepBoth));XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try Data(contentsOf:source),original)
        XCTAssertEqual(try read(target.appendingPathComponent("bundle (2).zip")),"member contents")
    }
    func testArchiveMergeRulesResetCustomNamesToTheFrozenSuggestion() throws {
        let catalog = try mergeArchive(["a.txt":"new"]),target = try folder("target");try file("target/a.txt","old")
        let custom = try mergePlan(catalog,target).resolving("a.txt",with:.rename("custom.txt"))
        XCTAssertEqual(custom.targetPath(for:custom.actions[0]),"custom.txt")
        let automatic = custom.applying(.keepBoth);XCTAssertEqual(automatic.targetPath(for:automatic.actions[0]),"a (2).txt")
        let reviewed = automatic.applying(.review);XCTAssertEqual(reviewed.unresolvedCount,1)
    }
    func testArchiveMergeSpecialTargetIsNeverOpenedOrReplaced() throws {
        let catalog = try mergeArchive(["pipe.txt":"new"]),target = try folder("target"),pipe = target.appendingPathComponent("pipe.txt")
        XCTAssertEqual(mkfifo(pipe.path,0o600),0);let plan = try mergePlan(catalog,target,policy:.replace)
        XCTAssertEqual(plan.unresolvedCount,1);XCTAssertThrowsError(try plan.resolving("pipe.txt",with:.replace))
        let report = ArchiveService.extract(try plan.resolving("pipe.txt",with:.keepBoth));XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("pipe (2).txt")),"new")
        XCTAssertTrue(FileSystem.exists(pipe))
    }
    func testArchiveMergeUnrelatedTargetChangesRemainAllowed() throws {
        let catalog = try mergeArchive(["a.txt":"new"]),target = try folder("target"),plan = try mergePlan(catalog,target)
        try file("target/unrelated.txt","keep");let report = ArchiveService.extract(plan)
        XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("unrelated.txt")),"keep");XCTAssertEqual(try read(target.appendingPathComponent("a.txt")),"new")
    }
    func testArchiveMergeRollbackRemovesOnlyItsOwnNewFolders() throws {
        let catalog = try mergeArchive(["Dir/a.txt":"new"],folders:["Empty"]),target = try folder("target"),plan = try mergePlan(catalog,target),token = CancellationToken()
        let report = ArchiveService.extract(plan,token:token,progress:{ if $0.items.contains(where:{$0.state == .completed && $0.totalBytes > 0}) { token.cancel() } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("Dir")));XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("Empty")));XCTAssertTrue(try noArchiveStages(target))
    }
    func testArchiveMergeLateForeignChildrenAreNotDeletedByRollback() throws {
        let catalog = try mergeArchive(["Dir/a.txt":"new"]),target = try folder("target"),plan = try mergePlan(catalog,target),token = CancellationToken();var added = false
        let report = ArchiveService.extract(plan,token:token,progress:{ if !added && $0.items.contains(where:{$0.state == .completed && $0.totalBytes > 0}) { added = true;try? Data("foreign".utf8).write(to:target.appendingPathComponent("Dir/keep.txt"));token.cancel() } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("Dir/keep.txt")),"foreign");XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("Dir/a.txt")))
    }
}
