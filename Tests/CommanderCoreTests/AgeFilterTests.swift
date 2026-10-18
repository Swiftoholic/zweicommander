import Foundation
import CommanderCore

extension CoreTests {
    private var ageReference: Date { Date(timeIntervalSince1970:1_700_000_000) }
    @discardableResult private func agedFile(_ path: String,seconds: Double,text: String = "match") throws -> URL {
        let url = try file(path,text)
        try FileManager.default.setAttributes([.modificationDate:ageReference.addingTimeInterval(-seconds)],ofItemAtPath:url.path);return url
    }
    private func ageFilter(minimum: TransferAgeLimit? = nil,maximum: TransferAgeLimit? = nil) -> TransferFilter {
        var value = TransferFilter();value.modifiedAge = TransferAgeRange(minimum:minimum,maximum:maximum);return value
    }
    func testAgeUnitsParsingAndOverflowAreExact() throws {
        XCTAssertEqual(try TransferAgeLimit.parse(" ",unit:.days),nil)
        for (unit,count) in [(TransferAgeUnit.minutes,Int64(60)),(.hours,3600),(.days,86400),(.weeks,604800)] {
            XCTAssertEqual(try TransferAgeLimit.parse(" 1 ",unit:unit)?.seconds(),count)
        }
        XCTAssertEqual(try TransferAgeLimit(36500,unit:.days).seconds(),3_153_600_000)
        XCTAssertEqual(try TransferAgeLimit.parse("0",unit:.weeks)?.seconds(),0)
        for text in ["-1","+1","1.5","1,5","1e3","∞","٩","9223372036854775808",String(repeating:"0",count:21)] { XCTAssertThrowsError(try TransferAgeLimit.parse(text,unit:.days)) }
        XCTAssertThrowsError(try TransferAgeLimit(Int64.max,unit:.weeks).seconds())
        XCTAssertThrowsError(try TransferAgeLimit(36501,unit:.days).seconds())
    }
    func testAgeValidationRejectsMixedModesAndReversedUnits() throws {
        XCTAssertThrowsError(try ageFilter().validate())
        XCTAssertThrowsError(try ageFilter(minimum:.init(25,unit:.hours),maximum:.init(1,unit:.days)).validate())
        XCTAssertThrowsError(try ageFilter(minimum:.init(-1,unit:.minutes)).validate())
        var mixed = ageFilter(maximum:.init(1,unit:.weeks));mixed.modifiedFrom = ageReference
        XCTAssertThrowsError(try mixed.validate());mixed.modifiedFrom = nil;mixed.modifiedBefore = ageReference
        XCTAssertThrowsError(try mixed.validate())
        try ageFilter(minimum:.init(24,unit:.hours),maximum:.init(1,unit:.days)).validate()
        let source = try agedFile("a.txt",seconds:3600),target = try folder("target")
        XCTAssertThrowsError(try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:ageFilter(maximum:.init(7,unit:.days)),referenceDate:Date(timeIntervalSinceReferenceDate:.infinity)))
        XCTAssertTrue(try relativeObjects(target).isEmpty)
    }
    func testAgeRangeIncludesBothBoundariesAndExcludesFuture() throws {
        let source = try folder("tree"),target = try folder("target")
        for seconds in [-1,0,3599,3600,604800,604801] { try agedFile("tree/t\(seconds).txt",seconds:Double(seconds)) }
        let filter = ageFilter(minimum:.init(1,unit:.hours),maximum:.init(1,unit:.weeks))
        let plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter,referenceDate:ageReference)
        XCTAssertEqual(plannedObjects(plan).filter { $0.kind == .file }.map { $0.source.lastPathComponent }.sorted(),["t3600.txt","t604800.txt"])
        XCTAssertEqual(plan.ageReference,ageReference);XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty)
        XCTAssertEqual(try relativeObjects(target),["tree","tree/t3600.txt","tree/t604800.txt"])
    }
    func testAgeOneSidedRangesAndZeroUseNoFutureDates() throws {
        let source = try folder("tree"),target = try folder("target")
        for (name,seconds) in [("future",-60.0),("now",0),("recent",3600),("old",864000)] { try agedFile("tree/"+name,seconds:seconds) }
        func names(_ filter: TransferFilter) throws -> Set<String> {
            let plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter,referenceDate:ageReference)
            return Set(plannedObjects(plan).filter { $0.kind == .file }.map { $0.source.lastPathComponent })
        }
        XCTAssertEqual(try names(ageFilter(maximum:.init(1,unit:.days))),["now","recent"])
        XCTAssertEqual(try names(ageFilter(minimum:.init(1,unit:.days))),["old"])
        XCTAssertEqual(try names(ageFilter(maximum:.init(0,unit:.minutes))),["now"])
        XCTAssertEqual(try names(ageFilter(minimum:.init(0,unit:.minutes))),["now","recent","old"])
    }
    func testAgeReferenceIsFrozenForEveryRootAndExecution() throws {
        let a = try agedFile("a.txt",seconds:60),b = try agedFile("b.txt",seconds:120),target = try folder("target")
        let filter = ageFilter(maximum:.init(1,unit:.days))
        let plan = try TransferPlanner.prepare([a,b],to:target,kind:.copy,policy:.stop,filter:filter,referenceDate:ageReference)
        let selection = plan.selecting(Set(plan.entries.map(\.id)))
        XCTAssertEqual(selection.ageReference,ageReference);XCTAssertEqual(selection.entries.count,2)
        // The real wall clock is deliberately years later than the preview reference.
        XCTAssertTrue(TransferPlanner.execute(selection).errors.isEmpty)
        XCTAssertEqual(try relativeObjects(target),["a.txt","b.txt"])
    }
    func testAgeFreshPlansRecalculateWhileEmptyPlansKeepTheirReference() throws {
        let source = try agedFile("one.txt",seconds:23*3600),target = try folder("target"),filter = ageFilter(maximum:.init(1,unit:.days))
        let first = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter,referenceDate:ageReference)
        let later = ageReference.addingTimeInterval(2*3600)
        let second = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter,referenceDate:later)
        XCTAssertEqual(first.entries.count,1);XCTAssertTrue(second.entries.isEmpty);XCTAssertEqual(second.ageReference,later)
        XCTAssertTrue(TransferPlanner.execute(first).errors.isEmpty)
    }
    func testAgeCombinesWithNamesSizeSubtreesAndLinkExclusion() throws {
        let source = try folder("tree"),target = try folder("target")
        for (name,text) in [("good.txt","keep"),("small.txt","x"),("wrong.bin","keep"),("Cache/hidden.txt","keep")] { try agedFile("tree/"+name,seconds:3600,text:text) }
        let outside = try agedFile("outside/target.txt",seconds:3600,text:"outside")
        try FileManager.default.createSymbolicLink(at:source.appendingPathComponent("alias.txt"),withDestinationURL:outside)
        var filter = ageFilter(maximum:.init(1,unit:.days));filter.include = "*.txt";filter.minimumSize = 2;filter.excludedFolders = "Cache";filter.keepEmptyFolders = false
        let plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter,referenceDate:ageReference)
        XCTAssertEqual(plan.bytes,4);XCTAssertEqual(plan.entries[0].linkCount,0)
        XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty);XCTAssertEqual(try relativeObjects(target),["tree","tree/good.txt"])
        XCTAssertEqual(try read(outside),"outside")
    }
    func testAgeSourceEnteringRangeInvalidatesBeforeAnyPublication() throws {
        let first = try agedFile("a.txt",seconds:3600),source = try folder("tree"),excluded = try agedFile("tree/old.txt",seconds:3*86400),target = try folder("target")
        let plan = try TransferPlanner.prepare([first,source],to:target,kind:.copy,policy:.stop,filter:ageFilter(maximum:.init(1,unit:.days)),referenceDate:ageReference)
        try FileManager.default.setAttributes([.modificationDate:ageReference.addingTimeInterval(-3600)],ofItemAtPath:excluded.path)
        XCTAssertFalse(TransferPlanner.execute(plan).errors.isEmpty);XCTAssertTrue(try relativeObjects(target).isEmpty)
    }
    func testAgeMergeKeepsReferenceAndRequiresRealConflictDecision() throws {
        let source = try folder("tree"),target = try folder("target")
        try agedFile("tree/same.txt",seconds:3600,text:"new");try file("target/tree/same.txt","old");try file("target/tree/extra.txt","extra")
        let original = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:ageFilter(maximum:.init(1,unit:.days)),mergeFolders:true,referenceDate:ageReference)
        let action = original.merge!.actions.first { $0.conflict }!,resolved = try original.resolving(action.id,with:.keepBoth)
        XCTAssertEqual(resolved.ageReference,ageReference);XCTAssertEqual(original.merge?.unresolvedCount,1)
        XCTAssertTrue(TransferPlanner.execute(resolved).errors.isEmpty)
        XCTAssertEqual(try read(target.appendingPathComponent("tree/same.txt")),"old");XCTAssertEqual(try read(target.appendingPathComponent("tree/same (2).txt")),"new")
        XCTAssertEqual(try read(target.appendingPathComponent("tree/extra.txt")),"extra")
    }
    func testAgeStructureSuspendsRulesAndFilteredMovesRemainRejected() throws {
        let source = try folder("tree"),target = try folder("target");try folder("tree/empty");try agedFile("tree/a.txt",seconds:3600)
        var filter = ageFilter(maximum:.init(0,unit:.minutes));filter.structureOnly = true
        let plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter,referenceDate:ageReference)
        XCTAssertTrue(plan.ageReference == nil);XCTAssertEqual(plan.bytes,0);XCTAssertEqual(plannedObjects(plan).count,2)
        XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty)
        filter.structureOnly = false
        XCTAssertThrowsError(try TransferPlanner.prepare([source],to:target,kind:.move,policy:.stop,filter:filter,referenceDate:ageReference))
        XCTAssertTrue(FileSystem.exists(source.appendingPathComponent("a.txt")))
    }
    func testAgeProfilesUseVersionTwoAndPreserveLegacyRecords() throws {
        var library = CopyProfileLibrary();let legacy = try library.save(name:"Fest",filter:.init(),policy:.stop,mergeFolders:false)
        let oldData = try library.encoded();XCTAssertEqual((try JSONSerialization.jsonObject(with:oldData) as! [String:Any])["version"] as? Int,1)
        let filter = ageFilter(minimum:.init(1,unit:.hours),maximum:.init(1,unit:.weeks)),id = try library.save(name:"Dynamisch",filter:filter,policy:.skip,mergeFolders:true)
        let data = try library.encoded();var json = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        XCTAssertEqual(json["version"] as? Int,2);let loaded = try CopyProfileLibrary(data:data)
        XCTAssertEqual(loaded.profile(id)?.filter,filter);XCTAssertEqual(loaded.profile(legacy),try CopyProfileLibrary(data:oldData).profile(legacy))
        json["version"] = 1;XCTAssertThrowsError(try CopyProfileLibrary(data:JSONSerialization.data(withJSONObject:json)))
        try library.remove(id);XCTAssertEqual((try JSONSerialization.jsonObject(with:library.encoded()) as! [String:Any])["version"] as? Int,1)
        XCTAssertEqual(try CopyProfileLibrary(data:oldData).profile(legacy)?.filter.modifiedAge,nil)
    }
    func testAgeJournalRestoresRelativeRuleAndNewPlansUseNewTime() throws {
        let source = try agedFile("one.txt",seconds:23*3600),target = try folder("target"),directory = root.appendingPathComponent("journal")
        let filter = ageFilter(maximum:.init(1,unit:.days)),plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter,referenceDate:ageReference)
        var journal: TransferJournal? = try TransferJournal(directory:directory)
        let snapshot = WorkSnapshot.waiting(title:"Relatives Alter",items:plan.initialItems)
        try journal!.stage(TransferIntent(plan),snapshot:snapshot)
        let data = try Data(contentsOf:journal!.file);var json = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        XCTAssertEqual(json["version"] as? Int,2);XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("ageReference"))
        journal = nil;journal = try TransferJournal(directory:directory)
        let entry = journal!.entry(snapshot.id)!;XCTAssertEqual(entry.restoredSnapshot.state,.review);XCTAssertEqual(entry.intent.filter,filter)
        let fresh = try TransferPlanner.prepare(entry.intent.sources,to:entry.intent.destination,kind:entry.intent.kind,policy:entry.intent.policy,filter:entry.intent.filter,referenceDate:ageReference.addingTimeInterval(2*3600))
        XCTAssertTrue(fresh.entries.isEmpty);XCTAssertTrue(try relativeObjects(target).isEmpty)
        journal = nil;json["version"] = 1;let bad = try JSONSerialization.data(withJSONObject:json)
        try bad.write(to:directory.appendingPathComponent("journal.json"))
        XCTAssertThrowsError(try TransferJournal(directory:directory));XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("journal.json")),bad)
    }
}
