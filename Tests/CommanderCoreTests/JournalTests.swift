import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    private func journalPlan(_ kind: TransferKind = .copy) throws -> TransferPlan {
        let source = try file("source/Grüße.txt","unverändert"),target = try folder("target")
        return try TransferPlanner.prepare([source],to:target,kind:kind,policy:.stop)
    }
    private func stage(_ plan: TransferPlan,in journal: TransferJournal) throws -> WorkSnapshot {
        let value = WorkSnapshot.waiting(title:"Kopieren → Ziel",items:plan.initialItems)
        try journal.stage(TransferIntent(plan),snapshot:value);return value
    }
    func testJournalRestoresIntentWithoutExecutingOrLosingRules() throws {
        let source = try folder("source/Projekt"),target = try folder("target")
        try file("source/Projekt/a.txt","abcd");try file("source/Projekt/a.bin","abc")
        var filter = TransferFilter();filter.include = "*.txt";filter.minimumSize = 2;filter.keepEmptyFolders = false
        let plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.keepBoth,filter:filter,mergeFolders:true)
        let directory = root.appendingPathComponent("journal")
        var journal: TransferJournal? = try TransferJournal(directory:directory)
        let value = try stage(plan,in:journal!);journal = nil
        let reopened = try TransferJournal(directory:directory),entry = reopened.entry(value.id)!
        XCTAssertEqual(entry.intent.sources.map(\.path),[source.path]);XCTAssertEqual(entry.intent.destination.path,target.path)
        XCTAssertEqual(entry.intent.filter,filter);XCTAssertEqual(entry.intent.policy,.keepBoth);XCTAssertTrue(entry.intent.mergeFolders)
        XCTAssertEqual(entry.restoredSnapshot.state,.review);XCTAssertFalse(entry.restoredSnapshot.isPending)
        XCTAssertTrue(try FileSystem.list(target,showHidden:true).isEmpty);XCTAssertEqual(try read(source.appendingPathComponent("a.txt")),"abcd")
    }
    func testJournalUnfinishedStatesRequireReviewAndKeepLastReportedBytes() throws {
        let plan = try journalPlan(),journal = try TransferJournal(directory:root.appendingPathComponent("journal"))
        for state in [WorkState.waiting,.running,.pausing,.paused] {
            var value = try stage(plan,in:journal);value.state = state;value.transferredBytes = 3;value.fraction = 0.2;value.items[0].state = .running;value.items[0].bytes = 3
            try journal.synchronize([value])
            let entry = journal.entry(value.id)!
            XCTAssertEqual(entry.snapshot.state,state);XCTAssertEqual(entry.restoredSnapshot.state,.review)
            XCTAssertEqual(entry.restoredSnapshot.transferredBytes,3);XCTAssertEqual(entry.restoredSnapshot.items[0].bytes,3)
        }
    }
    func testJournalCompletedFailedAndCancelledHistorySurvivesRestart() throws {
        let plan = try journalPlan(),directory = root.appendingPathComponent("journal")
        var journal: TransferJournal? = try TransferJournal(directory:directory)
        for state in [WorkState.completed,.failed,.cancelled] {
            var value = try stage(plan,in:journal!);value.state = state;value.detail = "Ergebnis";try journal!.synchronize([value])
        }
        journal = nil
        let reopened = try TransferJournal(directory:directory)
        XCTAssertEqual(Set(reopened.entries.map { $0.restoredSnapshot.state.rawValue }),Set(["completed","failed","cancelled"]))
        XCTAssertTrue(reopened.entries.allSatisfy { $0.restoredSnapshot.isFinished })
    }
    func testJournalUsesPrivatePermissionsAndExclusiveLifetimeLock() throws {
        let plan = try journalPlan(),directory = root.appendingPathComponent("journal")
        var journal: TransferJournal? = try TransferJournal(directory:directory);_ = try stage(plan,in:journal!)
        let attributes = try FileManager.default.attributesOfItem(atPath:directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o700)
        for name in ["journal.json",".journal.lock"] {
            let attributes = try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent(name).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
        }
        XCTAssertThrowsError(try TransferJournal(directory:directory));journal = nil
        XCTAssertEqual(try TransferJournal(directory:directory).entries.count,1)
    }
    func testJournalCorruptAndUnknownDocumentsStayUntouched() throws {
        for (index,text) in ["{broken","{\"version\":99,\"entries\":[]}","{\"version\":1}"].enumerated() {
            let directory = try folder("journal-\(index)"),file = directory.appendingPathComponent("journal.json"),data = Data(text.utf8)
            try data.write(to:file);XCTAssertThrowsError(try TransferJournal(directory:directory))
            XCTAssertEqual(try Data(contentsOf:file),data)
        }
    }
    func testJournalRejectsSymlinkAndHardlinkDataFiles() throws {
        let outside = try file("outside.json","{\"version\":1,\"entries\":[]}")
        for hardlink in [false,true] {
            let directory = try folder(hardlink ? "hard" : "link"),target = directory.appendingPathComponent("journal.json")
            if hardlink { try FileManager.default.linkItem(at:outside,to:target) }
            else { try FileManager.default.createSymbolicLink(at:target,withDestinationURL:outside) }
            XCTAssertThrowsError(try TransferJournal(directory:directory))
            XCTAssertEqual(try read(outside),"{\"version\":1,\"entries\":[]}")
        }
    }
    func testJournalRejectsLinkedDirectoryAndLockFile() throws {
        let outside = try folder("outside"),alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:outside)
        XCTAssertThrowsError(try TransferJournal(directory:alias))
        XCTAssertTrue(try FileSystem.list(outside,showHidden:true).isEmpty)
        let directory = try folder("journal"),lock = directory.appendingPathComponent(".journal.lock"),data = try file("outside-lock","keep")
        try FileManager.default.createSymbolicLink(at:lock,withDestinationURL:data)
        XCTAssertThrowsError(try TransferJournal(directory:directory));XCTAssertEqual(try read(data),"keep")
    }
    func testJournalRefusesExternalChangesBeforeWriting() throws {
        let plan = try journalPlan(),journal = try TransferJournal(directory:root.appendingPathComponent("journal"))
        let value = try stage(plan,in:journal),changed = Data("external edit".utf8)
        try changed.write(to:journal.file,options:.atomic)
        XCTAssertThrowsError(try journal.remove([value.id]));XCTAssertEqual(try Data(contentsOf:journal.file),changed)
        XCTAssertNotNil(journal.entry(value.id))
    }
    func testJournalRefusesReplacedDirectoryWithoutWritingOutside() throws {
        let plan = try journalPlan(),directory = root.appendingPathComponent("journal"),journal = try TransferJournal(directory:directory)
        let value = try stage(plan,in:journal),before = try Data(contentsOf:journal.file),moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at:directory,to:moved)
        let outside = try folder("outside");try FileManager.default.createSymbolicLink(at:directory,withDestinationURL:outside)
        XCTAssertThrowsError(try journal.remove([value.id]))
        XCTAssertTrue(try FileSystem.list(outside,showHidden:true).isEmpty)
        XCTAssertEqual(try Data(contentsOf:moved.appendingPathComponent("journal.json")),before)
    }
    func testJournalDoesNotRecreateExternallyRemovedFileOrReplacedLock() throws {
        let plan = try journalPlan(),journal = try TransferJournal(directory:root.appendingPathComponent("journal"))
        let value = try stage(plan,in:journal)
        try FileManager.default.removeItem(at:journal.file)
        XCTAssertThrowsError(try journal.remove([value.id]));XCTAssertFalse(FileSystem.exists(journal.file))
        let lock = journal.directory.appendingPathComponent(".journal.lock")
        try FileManager.default.removeItem(at:lock);try Data("new lock".utf8).write(to:lock)
        XCTAssertThrowsError(try journal.stage(TransferIntent(plan),snapshot:.waiting(title:"other")))
        XCTAssertFalse(FileSystem.exists(journal.file))
    }
    func testJournalReorderRemoveAndReplacementPersistAtomically() throws {
        let plan = try journalPlan(),journal = try TransferJournal(directory:root.appendingPathComponent("journal"))
        let first = try stage(plan,in:journal),second = try stage(plan,in:journal),third = try stage(plan,in:journal)
        try journal.synchronize([third,first,second]);XCTAssertEqual(journal.entries.map(\.id),[third.id,first.id,second.id])
        try journal.remove([second.id]);XCTAssertEqual(journal.entries.map(\.id),[third.id,first.id])
        let replacement = WorkSnapshot.waiting(title:"Neuer Plan",items:plan.initialItems)
        try journal.stage(TransferIntent(plan),snapshot:replacement,replacing:first.id)
        XCTAssertEqual(journal.entries.map(\.id),[third.id,replacement.id]);XCTAssertTrue(journal.entry(first.id) == nil)
        let before = try Data(contentsOf:journal.file)
        XCTAssertThrowsError(try journal.stage(TransferIntent(plan),snapshot:.waiting(title:"not inserted"),replacing:UUID()))
        XCTAssertEqual(try Data(contentsOf:journal.file),before)
    }
    func testJournalBoundsItemExcerptButKeepsAggregateProgress() throws {
        let target = try folder("target"),sources = try (0..<205).map { try file("source/f\($0).txt","abc") }
        let plan = try TransferPlanner.prepare(sources,to:target,kind:.copy,policy:.stop),journal = try TransferJournal(directory:root.appendingPathComponent("journal"))
        var value = try stage(plan,in:journal);value.state = .running;value.transferredBytes = 300;value.fraction = 0.4
        try journal.synchronize([value]);let entry = journal.entry(value.id)!
        XCTAssertEqual(entry.snapshot.items.count,200);XCTAssertEqual(entry.itemCount,205)
        XCTAssertEqual(entry.snapshot.transferredBytes,300);XCTAssertEqual(entry.snapshot.totalBytes,615)
        XCTAssertEqual(entry.intent.sources.count,205)
    }
    func testJournalRejectsUnsafeIntentAndInvalidProgressWithoutMutation() throws {
        let plan = try journalPlan(),directory = root.appendingPathComponent("journal")
        var journal: TransferJournal? = try TransferJournal(directory:directory);let value = try stage(plan,in:journal!)
        let before = try Data(contentsOf:journal!.file)
        var invalid = WorkSnapshot.waiting(title:"invalid");invalid.fraction = -1
        XCTAssertThrowsError(try journal!.stage(TransferIntent(plan),snapshot:invalid))
        XCTAssertEqual(try Data(contentsOf:journal!.file),before)
        journal = nil
        var json = try JSONSerialization.jsonObject(with:before) as! [String:Any]
        var entries = json["entries"] as! [[String:Any]],intent = entries[0]["intent"] as! [String:Any]
        intent["destination"] = "https://example.com/out";entries[0]["intent"] = intent;json["entries"] = entries
        let corrupt = try JSONSerialization.data(withJSONObject:json);try corrupt.write(to:directory.appendingPathComponent("journal.json"))
        XCTAssertThrowsError(try TransferJournal(directory:directory))
        XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("journal.json")),corrupt)
        XCTAssertFalse(FileSystem.exists(plan.destination.appendingPathComponent(value.items[0].source.lastPathComponent)))
    }
    func testJournalCapacityDoesNotEvictUnfinishedEntries() throws {
        let plan = try journalPlan(),directory = root.appendingPathComponent("journal")
        var journal: TransferJournal? = try TransferJournal(directory:directory)
        _ = try stage(plan,in:journal!)
        var json = try JSONSerialization.jsonObject(with:Data(contentsOf:journal!.file)) as! [String:Any]
        let first = (json["entries"] as! [[String:Any]])[0]
        json["entries"] = (0..<TransferJournal.maximumEntries).map { _ -> [String:Any] in
            var entry = first,snapshot = entry["snapshot"] as! [String:Any]
            snapshot["id"] = UUID().uuidString;entry["snapshot"] = snapshot;return entry
        }
        journal = nil
        let data = try JSONSerialization.data(withJSONObject:json),file = directory.appendingPathComponent("journal.json")
        try data.write(to:file)
        journal = try TransferJournal(directory:directory)
        let ids = journal!.entries.map(\.id)
        XCTAssertThrowsError(try stage(plan,in:journal!))
        XCTAssertEqual(journal!.entries.map(\.id),ids);XCTAssertEqual(try Data(contentsOf:file),data)
        let replacement = WorkSnapshot.waiting(title:"reviewed",items:plan.initialItems)
        try journal!.stage(TransferIntent(plan),snapshot:replacement,replacing:ids[0])
        XCTAssertEqual(journal!.entries.count,TransferJournal.maximumEntries)
        XCTAssertEqual(journal!.entries.first?.id,replacement.id)
        XCTAssertEqual(Array(journal!.entries.map(\.id).dropFirst()),Array(ids.dropFirst()))
    }
    func testJournalFreshPlanSeesChangesAndMissingMoveSourceDoesNotExecute() throws {
        let plan = try journalPlan(.move),journal = try TransferJournal(directory:root.appendingPathComponent("journal"))
        let value = try stage(plan,in:journal),source = plan.entries[0].source
        try Data("changed after planning".utf8).write(to:source)
        let intent = journal.entry(value.id)!.intent
        let fresh = try TransferPlanner.prepare(intent.sources,to:intent.destination,kind:intent.kind,policy:intent.policy)
        XCTAssertTrue(fresh.bytes > plan.bytes);XCTAssertFalse(FileSystem.exists(fresh.entries[0].target))
        try FileManager.default.removeItem(at:source)
        XCTAssertEqual(journal.entry(value.id)?.restoredSnapshot.state,.review)
        XCTAssertThrowsError(try TransferPlanner.prepare(intent.sources,to:intent.destination,kind:intent.kind,policy:intent.policy))
        XCTAssertTrue(try FileSystem.list(plan.destination,showHidden:true).isEmpty)
    }
    func testJournalRestoredMergeRequiresIndividualDecisionsAgain() throws {
        let source = try folder("source/Projekt"),target = try folder("target")
        try file("source/Projekt/same.txt","new");try file("target/Projekt/same.txt","old")
        var plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,mergeFolders:true)
        let action = plan.merge!.actions.first { $0.conflict }!
        plan = try plan.resolving(action.id,with:.replace)
        let journal = try TransferJournal(directory:root.appendingPathComponent("journal")),value = try stage(plan,in:journal),intent = journal.entry(value.id)!.intent
        let fresh = try TransferPlanner.prepare(intent.sources,to:intent.destination,kind:intent.kind,policy:intent.policy,filter:intent.filter,mergeFolders:intent.mergeFolders)
        XCTAssertEqual(fresh.merge?.unresolvedCount,1);XCTAssertEqual(try read(target.appendingPathComponent("Projekt/same.txt")),"old")
    }
    func testSchedulerRestoredWorkCannotStartOrDisappearWithFinishedHistory() throws {
        let scheduler = WorkScheduler(),review = WorkSnapshot.waiting(title:"stored")
        var completed = WorkSnapshot.waiting(title:"done");completed.state = .completed
        scheduler.restore([review,completed]);scheduler.start(review.id)
        XCTAssertEqual(scheduler.snapshots.first?.state,.review);XCTAssertFalse(scheduler.snapshots.first!.isPending)
        XCTAssertEqual(scheduler.clearFinished(),[completed.id]);XCTAssertEqual(scheduler.snapshots.map(\.id),[review.id])
        scheduler.remove(review.id);XCTAssertEqual(scheduler.snapshots.first?.state,.cancelled)
        XCTAssertEqual(scheduler.clearFinished(),[review.id]);XCTAssertTrue(scheduler.snapshots.isEmpty)
    }
    func testLaterSelectionObjectReportsItsFirstPartialBytes() throws {
        let first = try file("a.txt","first"),large = try largeFile("z.bin"),target = try folder("target")
        let plan = try TransferPlanner.prepare([first,large],to:target,kind:.copy,policy:.stop)
        var partial = false
        let report = TransferPlanner.execute(plan) { value in
            if let item = value.items.last,item.state == .running,item.bytes > 0,item.bytes < item.totalBytes { partial = true }
        }
        XCTAssertTrue(report.errors.isEmpty);XCTAssertTrue(partial,"Each selection object needs an initial partial-byte report")
        XCTAssertEqual(try Checksums.hash(large),try Checksums.hash(target.appendingPathComponent("z.bin")))
    }
}
