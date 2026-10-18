import Foundation
import CommanderCore

extension CoreTests {
    func testTransferSizeUnitsAndExactBoundaries() throws {
        XCTAssertEqual(try TransferSize.parse(" "),nil);XCTAssertEqual(try TransferSize.parse("0"),0)
        for (text,count) in [("1 KB",Int64(1000)),("1 KiB",1024),("1,5 MB",1_500_000),("1.5 mib",1_572_864),("0.001 KB",1),("2 GiB",2_147_483_648),("1 TiB",1_099_511_627_776),(String(Int64.max),Int64.max)] { XCTAssertEqual(try TransferSize.parse(text),count,text) }
        for text in ["-1","0.1 B","1e3","1,000,000 B","NaN","∞","1 XB","9223372036854775808 B","999999999999999999999999999999 TB",String(Int64.max)+" KiB"] { XCTAssertThrowsError(try TransferSize.parse(text)) }
    }
    func testTransferFilterOldSchemaAndMetadataRoundTrip() throws {
        var value = TransferFilter();value.minimumSize = 1;value.maximumSize = 99;value.modifiedFrom = Date(timeIntervalSince1970:1000);value.modifiedBefore = Date(timeIntervalSince1970:2000)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(TransferFilter.self,from:data),value)
        var old = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        for key in ["minimumSize","maximumSize","modifiedFrom","modifiedBefore"] { old.removeValue(forKey:key) }
        XCTAssertEqual(try JSONDecoder().decode(TransferFilter.self,from:JSONSerialization.data(withJSONObject:old)),TransferFilter())
    }
    func testCopySizeBoundsIncludeBothEndsAndEmptyFiles() throws {
        let source = try folder("tree"),target = try folder("target")
        for size in [0,4,5,7,10,11] { try file("tree/\(size).txt",String(repeating:"x",count:size)) }
        var filter = TransferFilter();filter.minimumSize = 5;filter.maximumSize = 10
        let plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(plannedObjects(plan).filter { $0.kind == .file }.map { $0.source.lastPathComponent }.sorted(),["10.txt","5.txt","7.txt"])
        XCTAssertEqual(plan.bytes,22);XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty)
        XCTAssertEqual(try relativeObjects(target),["tree","tree/5.txt","tree/7.txt","tree/10.txt"])
        filter.minimumSize = 0;filter.maximumSize = 0
        let zero = try TransferPlanner.prepare([source],to:root.appendingPathComponent("target"),kind:.copy,policy:.skip,filter:filter)
        XCTAssertEqual(zero.entries[0].fileCount,1);XCTAssertEqual(zero.bytes,0)
    }
    func testCopyDateBoundsUseInclusiveStartAndExclusiveEnd() throws {
        let source = try folder("tree"),target = try folder("target")
        for second in [9,10,19,20] {
            let url = try file("tree/\(second).txt")
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000+Double(second))],ofItemAtPath:url.path)
        }
        var filter = TransferFilter();filter.modifiedFrom = Date(timeIntervalSince1970:1_700_000_010);filter.modifiedBefore = Date(timeIntervalSince1970:1_700_000_020)
        let plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(plannedObjects(plan).filter { $0.kind == .file }.map { $0.source.lastPathComponent },["10.txt","19.txt"])
        XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty)
        XCTAssertEqual(try relativeObjects(target),["tree","tree/10.txt","tree/19.txt"])
    }
    func testMetadataFiltersCombineWithNamesAndMergeDecisions() throws {
        let source = try folder("tree"),target = try folder("target")
        for (name,size) in [("keep.txt",8),("small.txt",2),("large.txt",20),("skip.txt",8),("other.bin",8)] {
            let url = try file("tree/"+name,String(repeating:"n",count:size))
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000)],ofItemAtPath:url.path)
        }
        try file("target/tree/keep.txt","old");try file("target/tree/small.txt","untouched");try file("target/tree/extra.txt","extra")
        var filter = TransferFilter();filter.include = "*.txt";filter.exclude = "skip*";filter.minimumSize = 5;filter.maximumSize = 10;filter.modifiedFrom = Date(timeIntervalSince1970:1_699_999_999)
        let plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.keepBoth,filter:filter,mergeFolders:true)
        XCTAssertEqual(plan.merge?.actions.filter(\.conflict).count,1);XCTAssertEqual(plan.bytes,8)
        let report = TransferPlanner.execute(plan)
        XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try read(target.appendingPathComponent("tree/keep (2).txt")),"nnnnnnnn")
        XCTAssertEqual(try read(target.appendingPathComponent("tree/keep.txt")),"old");XCTAssertEqual(try read(target.appendingPathComponent("tree/small.txt")),"untouched")
        XCTAssertEqual(try read(target.appendingPathComponent("tree/extra.txt")),"extra")
        XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("tree/large.txt")))
    }
    func testMetadataFiltersExcludeLinksWithoutCopyingTheirTargets() throws {
        let source = try folder("tree"),target = try folder("target");try file("outside/private.txt","outside")
        try file("tree/regular.txt","inside")
        try FileManager.default.createSymbolicLink(at:source.appendingPathComponent("alias.txt"),withDestinationURL:root.appendingPathComponent("outside"))
        var filter = TransferFilter();filter.minimumSize = 0
        let plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(plan.entries[0].linkCount,0);XCTAssertEqual(plan.entries[0].fileCount,1)
        XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty)
        XCTAssertEqual(try relativeObjects(target),["tree","tree/regular.txt"])
        XCTAssertEqual(try read(root.appendingPathComponent("outside/private.txt")),"outside")
    }
    func testInvalidMetadataBoundsBlockBeforeAnyCopy() throws {
        let source = try file("a.txt"),target = try folder("target")
        var filter = TransferFilter()
        filter.minimumSize = -1;XCTAssertThrowsError(try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter))
        filter.minimumSize = 10;filter.maximumSize = 5;XCTAssertThrowsError(try filter.validate())
        filter.minimumSize = nil;filter.maximumSize = nil;filter.modifiedFrom = Date(timeIntervalSince1970:20);filter.modifiedBefore = Date(timeIntervalSince1970:20);XCTAssertThrowsError(try filter.validate())
        filter.modifiedBefore = Date(timeIntervalSince1970:10);XCTAssertThrowsError(try filter.validate())
        filter.modifiedBefore = nil;filter.modifiedFrom = Date(timeIntervalSinceReferenceDate:.infinity);XCTAssertThrowsError(try filter.validate())
        XCTAssertTrue(try relativeObjects(target).isEmpty)
    }
    func testStructureCopyIgnoresFileMetadataConditions() throws {
        let source = try folder("tree"),target = try folder("target");try folder("tree/empty");try file("tree/one.txt")
        var filter = TransferFilter();filter.structureOnly = true;filter.minimumSize = 999;filter.maximumSize = -1;filter.modifiedFrom = Date.distantFuture
        let plan = try TransferPlanner.prepare([source],to:target,kind:.copy,policy:.stop,filter:filter)
        XCTAssertEqual(plan.bytes,0);XCTAssertEqual(plannedObjects(plan).map(\.kind),[.directory,.directory])
        XCTAssertTrue(TransferPlanner.execute(plan).errors.isEmpty);XCTAssertEqual(try relativeObjects(target),["tree","tree/empty"])
    }
    func testMetadataPlanRejectsExcludedFileEnteringRange() throws {
        let first = try file("a.txt","first"),source = try folder("tree"),target = try folder("target"),excluded = try file("tree/late.txt","later")
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:100)],ofItemAtPath:excluded.path)
        var filter = TransferFilter();filter.modifiedFrom = Date(timeIntervalSince1970:200)
        let plan = try TransferPlanner.prepare([first,source],to:target,kind:.copy,policy:.stop,filter:filter)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:300)],ofItemAtPath:excluded.path)
        XCTAssertFalse(TransferPlanner.execute(plan).errors.isEmpty);XCTAssertTrue(try relativeObjects(target).isEmpty)
        var move = TransferFilter();move.maximumSize = 100
        XCTAssertThrowsError(try TransferPlanner.prepare([first],to:target,kind:.move,policy:.stop,filter:move))
        XCTAssertEqual(try read(first),"first")
    }
    func testCopyProfilesRoundTripDropsUnknownPathFields() throws {
        var library = CopyProfileLibrary(),filter = TransferFilter();filter.include = "*.txt";filter.minimumSize = 5;filter.modifiedFrom = Date(timeIntervalSince1970:1000)
        let id = try library.save(name:"Dokumente",filter:filter,policy:.keepBoth,mergeFolders:true)
        XCTAssertEqual(try CopyProfileLibrary(data:library.encoded()),library)
        var json = try JSONSerialization.jsonObject(with:library.encoded()) as! [String:Any]
        var rows = json["profiles"] as! [[String:Any]];rows[0]["source"] = "SYNTHETIC_PATH_NOT_STORED";rows[0]["destination"] = "SYNTHETIC_PATH_NOT_STORED";rows[0]["individualDecisions"] = ["old":"replace"];json["profiles"] = rows
        let loaded = try CopyProfileLibrary(data:JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(loaded.profile(id)?.filter,filter);XCTAssertEqual(loaded.profile(id)?.policy,.keepBoth);XCTAssertTrue(loaded.profile(id)?.mergeFolders ?? false)
        let text = String(decoding:try loaded.encoded(),as:UTF8.self)
        XCTAssertFalse(text.contains("SYNTHETIC_PATH_NOT_STORED"));XCTAssertFalse(text.contains("individualDecisions"))
    }
    func testCopyProfileNamesNormalizeAndRejectDuplicatesWithoutMutation() throws {
        var library = CopyProfileLibrary();try library.save(name:"  Café  ",filter:.init(),policy:.stop,mergeFolders:false)
        let original = library
        XCTAssertEqual(library.profiles[0].name,"Café")
        for name in ["CAFE\u{301}","",String(repeating:"a",count:81),"two\nlines"] { XCTAssertThrowsError(try library.save(name:name,filter:.init(),policy:.stop,mergeFolders:false)) }
        XCTAssertEqual(library,original)
    }
    func testCopyProfileUpdatingKeepsIdentityAndOtherRecords() throws {
        var library = CopyProfileLibrary();let first = try library.save(name:"Alpha",filter:.init(),policy:.stop,mergeFolders:false)
        let other = try library.save(name:"Beta",filter:.init(),policy:.skip,mergeFolders:true),old = library
        var filter = TransferFilter();filter.include = "*.md"
        XCTAssertEqual(try library.save(name:"Gamma",filter:filter,policy:.replace,mergeFolders:true,replacing:first),first)
        XCTAssertEqual(library.profiles.count,2);XCTAssertEqual(library.profile(other),old.profile(other));XCTAssertEqual(old.profile(first)?.name,"Alpha")
        let removed = try library.remove(first);XCTAssertEqual(removed.filter,filter);XCTAssertEqual(library.profiles.count,1)
        let stable = library
        XCTAssertThrowsError(try library.save(name:"Gone",filter:.init(),policy:.stop,mergeFolders:false,replacing:first))
        XCTAssertThrowsError(try library.remove(first));XCTAssertEqual(library,stable)
    }
    func testCopyProfileCapacityAndInvalidFilterKeepExistingData() throws {
        var library = CopyProfileLibrary()
        for index in 0..<50 { try library.save(name:"Profil \(index)",filter:.init(),policy:.stop,mergeFolders:false) }
        let original = library
        XCTAssertThrowsError(try library.save(name:"Too many",filter:.init(),policy:.stop,mergeFolders:false));XCTAssertEqual(library,original)
        var invalid = TransferFilter();invalid.regularExpressions = true;invalid.include = "["
        XCTAssertThrowsError(try library.save(name:"Invalid",filter:invalid,policy:.stop,mergeFolders:false,replacing:library.profiles[0].id));XCTAssertEqual(library,original)
        let id = library.profiles[0].id
        try library.save(name:"Updated",filter:.init(),policy:.skip,mergeFolders:false,replacing:id)
        XCTAssertEqual(library.profiles.count,50);XCTAssertEqual(library.profile(id)?.policy,.skip)
    }
    func testCopyProfileCorruptUnknownAndDuplicateDocumentsAreRejected() throws {
        XCTAssertThrowsError(try CopyProfileLibrary(data:Data("broken".utf8)))
        XCTAssertThrowsError(try CopyProfileLibrary(data:Data(repeating:32,count:1_048_577)))
        XCTAssertThrowsError(try CopyProfileLibrary(data:Data("{\"version\":99,\"profiles\":[]}".utf8)))
        var library = CopyProfileLibrary();try library.save(name:"One",filter:.init(),policy:.stop,mergeFolders:false)
        var json = try JSONSerialization.jsonObject(with:library.encoded()) as! [String:Any]
        let row = (json["profiles"] as! [[String:Any]])[0];var second = row;second["name"] = "Two";json["profiles"] = [row,second]
        XCTAssertThrowsError(try CopyProfileLibrary(data:JSONSerialization.data(withJSONObject:json)))
    }
}
