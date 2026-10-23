import Foundation
import Darwin
import CommanderCore

func runRecoveryChildIfRequested() {
    let args = CommandLine.arguments
    guard args.count == 3,args[1] == "--recovery-crash-child" else { return }
    do {
        let root = URL(fileURLWithPath:args[2]),journal = try TransferJournal(directory:URL(fileURLWithPath:args[2]).appendingPathComponent("history"))
        let history = try TransferHistory(journal:journal)
        let plan = try TransferPlanner.prepare([root.appendingPathComponent("large.bin")],to:root.appendingPathComponent("dest"),kind:.copy,policy:.stop)
        _ = TransferPlanner.execute(plan,history:history,progress:{ value in if value.bytes > 0 && value.bytes < value.totalBytes { _exit(81) } })
    } catch { _exit(82) }
    _exit(83)
}

func runFilteredMoveChildIfRequested() {
    let args = CommandLine.arguments
    guard args.count == 3,args[1] == "--filtered-crash-child" else { return }
    do {
        let root = URL(fileURLWithPath:args[2]),journal = try TransferJournal(directory:URL(fileURLWithPath:args[2]).appendingPathComponent("history"))
        let history = try TransferHistory(journal:journal)
        var filter = TransferFilter();filter.include = "*.txt"
        let plan = try TransferPlanner.prepare([root.appendingPathComponent("tree")],to:root.appendingPathComponent("dest"),kind:.move,policy:.stop,filter:filter)
        _ = TransferPlanner.execute(plan,history:history,progress:{ if $0.detail.hasPrefix("Entferne geprüfte Quelle") { _exit(84) } })
    } catch { _exit(85) }
    _exit(86)
}

extension CoreTests {
    func testDiscardUsesTrashAndPreservesSourceAndCurrentTarget() throws {
        let history = try recoveryHistory(),(source,target,item) = try backupFixture(history),stamp = try FileStamp(item.stored)
        guard let trashed = try history.discard(item.id) else { throw CommanderError.message("Papierkorbziel fehlt.") }
        defer { if (try? FileStamp(trashed)) == stamp { try? FileManager.default.removeItem(at:trashed) } }
        XCTAssertEqual(try read(trashed),"old");XCTAssertEqual(try FileStamp(trashed),stamp)
        XCTAssertEqual(try read(source),"new");XCTAssertEqual(try read(target),"new");XCTAssertTrue(history.inspect().isEmpty)
    }
    func testResumeRejectsPrefixModifiedDuringTheResumedWrite() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest"),history = try recoveryHistory()
        let item = try interrupted(source,dest,history);var changed = false
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        let report = TransferPlanner.execute(plan,history:history,progress:{ value in
            if value.detail.hasPrefix("Fortsetzen"),value.bytes > item.bytes,!changed {
                changed = true
                if let handle = try? FileHandle(forWritingTo:item.stored) { try? handle.write(contentsOf:Data([0x14]));try? handle.close() }
            }
        })
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty);XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("large.bin")))
    }
    func testBackupExternalCatalogEditBlocksRestoringIntoAbsentTarget() throws {
        let history = try recoveryHistory(),(_,target,item) = try backupFixture(history)
        try FileManager.default.removeItem(at:target);let plan = try history.planRestore(item.id)
        let path = root.appendingPathComponent("history/history.json")
        var data = try Data(contentsOf:path);data.append(0x20);try data.write(to:path)
        XCTAssertThrowsError(try history.restore(plan));XCTAssertEqual(try read(item.stored),"old");XCTAssertFalse(FileSystem.exists(target))
    }
    func testFilteredMoveCrashBeforeSourceRemovalKeepsRecoverableSource() throws {
        try file("tree/a.txt","move data");let dest = try folder("dest")
        let child = Process();child.executableURL = coreTestExecutable;child.arguments = ["--filtered-crash-child",root.path];child.standardOutput = FileHandle.nullDevice;child.standardError = FileHandle.nullDevice
        try child.run();child.waitUntilExit();XCTAssertEqual(child.terminationStatus,84)
        let history = try recoveryHistory()
        guard let item = history.inspect().first(where: { $0.kind == .backup }) else { throw CommanderError.message("Unterbrochene Quelle ist nicht wiederherstellbar.") }
        XCTAssertEqual(try read(item.stored),"move data");XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("tree/a.txt")))
        try history.restore(history.planRestore(item.id))
        XCTAssertEqual(try read(root.appendingPathComponent("tree/a.txt")),"move data");XCTAssertEqual(try read(dest.appendingPathComponent("tree/a.txt")),"move data")
    }
    func testFilteredMoveRefusesDestinationEditedAfterPublication() throws {
        let source = try folder("tree"),dest = try folder("dest");let original = try file("tree/a.txt","source")
        let target = dest.appendingPathComponent("tree/a.txt");var edited = false
        var filter = TransferFilter();filter.include = "*.txt"
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.move,policy:.stop,filter:filter)
        let report = TransferPlanner.execute(plan,validateExecution:{
            if FileSystem.exists(target),!edited { edited = true;try Data("external".utf8).write(to:target) }
        },progress:{ _ in })
        XCTAssertTrue(edited);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try read(original),"source");XCTAssertEqual(try read(target),"external")
    }
    private func recoveryHistory() throws -> TransferHistory { try TransferHistory(journal:TransferJournal(directory:root.appendingPathComponent("history"))) }
    @discardableResult private func interrupted(_ source: URL,_ dest: URL,_ history: TransferHistory,policy: ConflictPolicy = .stop,stopAfter: Int64 = 0) throws -> RecoveryItem {
        let token = CancellationToken(),plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:policy)
        let report = TransferPlanner.execute(plan,token:token,history:history,progress:{ if $0.bytes > stopAfter && $0.bytes < $0.totalBytes { token.cancel() } })
        XCTAssertFalse(report.errors.isEmpty)
        guard let item = history.inspect().first(where: { $0.kind == .partial }) else { throw CommanderError.message("Teilkopie fehlt (\(plan.entries.count) Auswahlobjekte, \(plan.bytes) Bytes, \(plan.entries.reduce(0) { $0+$1.linkCount }) Links): "+report.errors.joined(separator:"\n")) }
        XCTAssertTrue(item.bytes > 0 && item.bytes < item.totalBytes);return item
    }
    func testResumeFileAfterReopeningPrivateStorage() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest")
        try FileManager.default.setAttributes([.posixPermissions:0o640],ofItemAtPath:source.path)
        var offset: Int64 = 0
        do { let history = try recoveryHistory();offset = try interrupted(source,dest,history).bytes }
        let history = try recoveryHistory(),plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        var sawVerification = false
        let report = TransferPlanner.execute(plan,history:history,progress:{ if $0.detail.hasPrefix("Prüfe Teilkopie") { sawVerification = true } })
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(report.reusedBytes,offset);XCTAssertTrue(sawVerification)
        XCTAssertEqual(try Checksums.hash(source),try Checksums.hash(dest.appendingPathComponent("large.bin")))
        XCTAssertEqual(try FileEntry(url:dest.appendingPathComponent("large.bin")).permissions & 0o777,0o640)
        XCTAssertTrue(history.inspect().isEmpty)
    }
    func testResumeAfterActualAbruptProcessExit() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest")
        let child = Process();child.executableURL = coreTestExecutable;child.arguments = ["--recovery-crash-child",root.path]
        let output = Pipe();child.standardOutput = output;child.standardError = output
        try child.run();child.waitUntilExit();XCTAssertEqual(child.terminationStatus,81)
        let diagnostic = String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
        let history = try recoveryHistory()
        guard let item = history.inspect().first else { throw CommanderError.message("Abbruchprozess \(child.terminationStatus), keine Teilkopie: "+diagnostic) }
        XCTAssertTrue(item.bytes > 0 && item.bytes < item.totalBytes);XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("large.bin")))
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        let report = TransferPlanner.execute(plan,history:history)
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(report.reusedBytes,item.bytes)
        XCTAssertEqual(try Checksums.hash(source),try Checksums.hash(dest.appendingPathComponent("large.bin")))
    }
    func testResumeFolderReusesCompletedAndPartialFiles() throws {
        let source = try folder("tree"),dest = try folder("dest");try file("tree/a.txt","completed");_ = try largeFile("tree/z.bin")
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:source.path);try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:dest.appendingPathComponent("tree").path) }
        let history = try recoveryHistory(),item = try interrupted(source,dest,history,stopAfter:9)
        let original = try FileStamp(item.stored.appendingPathComponent("a.txt"))
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        let report = TransferPlanner.execute(plan,history:history)
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertTrue(report.reusedBytes >= item.bytes)
        XCTAssertEqual(try FileStamp(dest.appendingPathComponent("tree/a.txt")),original)
        XCTAssertEqual(try Checksums.hash(source.appendingPathComponent("z.bin")),try Checksums.hash(dest.appendingPathComponent("tree/z.bin")))
        XCTAssertEqual(try FileEntry(url:dest.appendingPathComponent("tree")).permissions & 0o777,0o555)
        XCTAssertTrue(history.inspect().isEmpty)
    }
    func testResumeRejectsSourceEditEvenWithRestoredModificationDate() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest"),history = try recoveryHistory()
        let item = try interrupted(source,dest,history),date = try FileEntry(url:source).modified
        let handle = try FileHandle(forWritingTo:source);try handle.write(contentsOf:Data([0x01]));try handle.close()
        try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:source.path)
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        XCTAssertFalse(TransferPlanner.execute(plan,history:history).errors.isEmpty)
        XCTAssertTrue(FileSystem.exists(item.stored));XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("large.bin")))
    }
    func testResumeRefusesTamperedPrefixWithoutOverwritingIt() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest"),history = try recoveryHistory()
        let item = try interrupted(source,dest,history)
        let handle = try FileHandle(forWritingTo:item.stored);try handle.write(contentsOf:Data([0x22]));try handle.close()
        let before = try Checksums.hash(item.stored),plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        let report = TransferPlanner.execute(plan,history:history)
        XCTAssertTrue(report.errors.contains { $0.contains("stimmt nicht") });XCTAssertEqual(try Checksums.hash(item.stored),before)
        XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("large.bin")))
    }
    func testResumeRejectsHardLinkedPartial() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest"),history = try recoveryHistory()
        let item = try interrupted(source,dest,history),alias = root.appendingPathComponent("foreign.bin")
        try FileManager.default.linkItem(at:item.stored,to:alias)
        let before = try Checksums.hash(alias),plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        XCTAssertFalse(TransferPlanner.execute(plan,history:history).errors.isEmpty);XCTAssertEqual(try Checksums.hash(alias),before)
        XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("large.bin")))
    }
    func testResumeRejectsReplacedParentAndSymlinkStage() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest"),history = try recoveryHistory()
        let item = try interrupted(source,dest,history)
        try FileManager.default.moveItem(at:dest,to:root.appendingPathComponent("original-dest"));try folder("dest")
        try FileManager.default.createSymbolicLink(at:item.stored,withDestinationURL:source)
        let before = try Checksums.hash(source),plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        XCTAssertFalse(TransferPlanner.execute(plan,history:history).errors.isEmpty);XCTAssertEqual(try Checksums.hash(source),before)
        XCTAssertTrue(FileSystem.isSymlink(item.stored));XCTAssertFalse(history.inspect().first!.available)
    }
    func testResumeCanCancelDuringPrefixVerification() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest"),history = try recoveryHistory()
        let item = try interrupted(source,dest,history),token = CancellationToken(),before = try Checksums.hash(item.stored)
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop)
        let report = TransferPlanner.execute(plan,token:token,history:history,progress:{ if $0.detail.hasPrefix("Prüfe Teilkopie") { token.cancel() } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try Checksums.hash(item.stored),before)
        XCTAssertFalse(FileSystem.exists(dest.appendingPathComponent("large.bin")))
    }
    func testResumePreservesConflictingTargetUntilPublication() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest"),target = try file("dest/large.bin","previous"),history = try recoveryHistory()
        _ = try interrupted(source,dest,history,policy:.replace);XCTAssertEqual(try read(target),"previous")
        let skip = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.skip)
        XCTAssertEqual(TransferPlanner.execute(skip,history:history).skipped,[source]);XCTAssertEqual(try read(target),"previous")
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.replace)
        let report = TransferPlanner.execute(plan,history:history)
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertTrue(report.reusedBytes > 0)
        XCTAssertEqual(history.inspect().filter { $0.kind == .backup }.count,1)
        XCTAssertEqual(try read(history.inspect().first!.stored),"previous")
    }
    private func backupFixture(_ history: TransferHistory) throws -> (URL,URL,RecoveryItem) {
        let source = try file("source/a.txt","new"),dest = try folder("dest"),target = try file("dest/a.txt","old")
        let report = TransferPlanner.execute(try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.replace),history:history)
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));try history.captureBackups(report.undo)
        XCTAssertEqual(history.inspect().count,1)
        return (source,target,history.inspect().first!)
    }
    func testBackupRestoreAfterRestartPreservesCurrentVersionAsNewBackup() throws {
        var id: UUID!,target: URL!
        do { let history = try recoveryHistory();let (_,url,item) = try backupFixture(history);id = item.id;target = url }
        let history = try recoveryHistory(),plan = try history.planRestore(id)
        XCTAssertTrue(plan.replacesExisting);try history.restore(plan)
        XCTAssertEqual(try read(target),"old");XCTAssertEqual(history.inspect().count,1)
        XCTAssertEqual(try read(history.inspect().first!.stored),"new")
        try history.restore(history.planRestore(history.inspect().first!.id));XCTAssertEqual(try read(target),"new")
    }
    func testBackupRestoreRefusesStaleTargetAndChangedBackup() throws {
        let history = try recoveryHistory(),(_,target,item) = try backupFixture(history),plan = try history.planRestore(item.id)
        try Data("user edit".utf8).write(to:target)
        XCTAssertThrowsError(try history.restore(plan));XCTAssertEqual(try read(target),"user edit");XCTAssertEqual(try read(item.stored),"old")
        try Data("changed backup".utf8).write(to:item.stored)
        XCTAssertThrowsError(try history.planRestore(item.id));XCTAssertThrowsError(try history.discard(item.id))
        try history.forgetUnavailable(item.id);XCTAssertEqual(try read(item.stored),"changed backup")
    }
    func testBackupFolderRestorationRetainsCurrentFolderTree() throws {
        let source = try folder("source/tree"),dest = try folder("dest"),history = try recoveryHistory()
        try file("source/tree/new.txt","new");try file("dest/tree/old.txt","old")
        let report = TransferPlanner.execute(try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.replace),history:history)
        XCTAssertTrue(report.errors.isEmpty);let item = history.inspect().first!
        try history.restore(history.planRestore(item.id))
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/old.txt")),"old")
        XCTAssertEqual(try read(history.inspect().first!.stored.appendingPathComponent("new.txt")),"new")
    }
    func testHistoryExternalEditsBlockBeforeAnyDataCopy() throws {
        let source = try largeFile("large.bin"),dest = try folder("dest"),history = try recoveryHistory()
        let path = root.appendingPathComponent("history/history.json"),foreign = Data("outside".utf8)
        try foreign.write(to:path)
        let report = TransferPlanner.execute(try TransferPlanner.prepare([source],to:dest,kind:.copy,policy:.stop),history:history)
        XCTAssertFalse(report.errors.isEmpty);XCTAssertNotNil(history.persistenceError);XCTAssertEqual(try Data(contentsOf:path),foreign);XCTAssertTrue(try FileSystem.list(dest,showHidden:true).isEmpty)
    }
    func testHistoryDamagedDocumentIsNeverReplaced() throws {
        do { _ = try recoveryHistory() }
        let path = root.appendingPathComponent("history/history.json"),foreign = Data("{invalid".utf8)
        try foreign.write(to:path);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        XCTAssertThrowsError(try recoveryHistory());XCTAssertEqual(try Data(contentsOf:path),foreign)
    }
    func testUnavailableRecoveryEntryCanBeForgottenWithoutDeletingData() throws {
        let history = try recoveryHistory(),(_,_,item) = try backupFixture(history)
        let elsewhere = root.appendingPathComponent("offline")
        try FileManager.default.moveItem(at:item.stored.deletingLastPathComponent(),to:elsewhere)
        try history.forgetUnavailable(item.id)
        XCTAssertTrue(history.inspect().isEmpty);XCTAssertEqual(try read(elsewhere.appendingPathComponent(item.stored.lastPathComponent)),"old")
    }
    func testFilteredMovePreservesExcludedFilesAndSupportsSessionUndo() throws {
        let source = try folder("tree"),dest = try folder("dest")
        let a = try file("tree/sub/a.txt","alpha"),b = try file("tree/sub/b.tmp","excluded");try file("tree/cache/x.txt","cache")
        var filter = TransferFilter();filter.include = "*.txt";filter.excludedFolders = "cache";filter.keepEmptyFolders = false
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.move,policy:.stop,filter:filter)
        let report = TransferPlanner.execute(plan,history:try recoveryHistory())
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertFalse(FileSystem.exists(a));XCTAssertEqual(try read(b),"excluded")
        XCTAssertEqual(try read(source.appendingPathComponent("cache/x.txt")),"cache");XCTAssertTrue(FileSystem.isDirectory(source.appendingPathComponent("sub")))
        XCTAssertEqual(try read(dest.appendingPathComponent("tree/sub/a.txt")),"alpha")
        XCTAssertTrue(FileOperations.undo(report.undo).isEmpty);XCTAssertEqual(try read(a),"alpha");XCTAssertEqual(try read(b),"excluded")
    }
    func testFilteredMoveConflictsAndStalePlanNeverRemoveSource() throws {
        let source = try file("a.txt","source"),dest = try folder("dest"),target = try file("dest/a.txt","old")
        var filter = TransferFilter();filter.include = "*.txt"
        let skip = try TransferPlanner.prepare([source],to:dest,kind:.move,policy:.skip,filter:filter)
        XCTAssertEqual(TransferPlanner.execute(skip).skipped,[source]);XCTAssertEqual(try read(source),"source");XCTAssertEqual(try read(target),"old")
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.move,policy:.replace,filter:filter)
        try Data("changed".utf8).write(to:source)
        XCTAssertFalse(TransferPlanner.execute(plan).errors.isEmpty);XCTAssertEqual(try read(source),"changed");XCTAssertEqual(try read(target),"old")
    }
    func testFilteredMoveCancellationRetainsAllSourcesAndPreviousTarget() throws {
        let source = try folder("tree"),dest = try folder("dest");_ = try largeFile("tree/large.bin");try file("tree/leave.txt","leave");try file("dest/tree/old.txt","old")
        var filter = TransferFilter();filter.include = "*.bin";filter.keepEmptyFolders = false
        let token = CancellationToken(),plan = try TransferPlanner.prepare([source],to:dest,kind:.move,policy:.replace,filter:filter)
        let report = TransferPlanner.execute(plan,token:token,history:try recoveryHistory(),progress:{ if $0.bytes > 0 { token.cancel() } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(FileSystem.exists(source.appendingPathComponent("large.bin")))
        XCTAssertEqual(try read(source.appendingPathComponent("leave.txt")),"leave");XCTAssertEqual(try read(dest.appendingPathComponent("tree/old.txt")),"old")
    }
    func testFilteredMoveRulesPersistAsJournalVersionThree() throws {
        let source = try file("a.txt","data"),dest = try folder("dest")
        var filter = TransferFilter();filter.include = "*.txt";filter.minimumSize = 1
        let plan = try TransferPlanner.prepare([source],to:dest,kind:.move,policy:.stop,filter:filter)
        do { let journal = try TransferJournal(directory:root.appendingPathComponent("journal"));try journal.stage(TransferIntent(plan),snapshot:.waiting(title:"Verschieben",items:plan.initialItems)) }
        let journal = try TransferJournal(directory:root.appendingPathComponent("journal"))
        XCTAssertEqual(journal.entries.first!.intent.filter,filter);XCTAssertEqual(journal.entries.first!.intent.kind,.move)
        let document = try JSONSerialization.jsonObject(with:Data(contentsOf:journal.file)) as! [String:Any]
        XCTAssertEqual(document["version"] as? Int,3)
        filter.structureOnly = true;XCTAssertThrowsError(try TransferPlanner.prepare([source],to:dest,kind:.move,policy:.stop,filter:filter))
    }
}
