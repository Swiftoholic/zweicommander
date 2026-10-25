import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    func testAdvancedSearchCanonicalRootsDeduplicateOverlapsAndAliases() throws {
        let parent = try folder("A"),child = try folder("A/Deep");try file("A/top.txt","top");try file("A/Deep/inside.txt","inside")
        let alias = root.appendingPathComponent("alias");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:parent)
        var options = SearchOptions();options.kind = .files
        XCTAssertEqual(try SearchService.searchRoots([child,alias,parent,parent],options:options),[FileSystem.canonical(parent)])
        let report = try SearchService.search([child,alias,parent],options:options)
        XCTAssertEqual(Set(report.hits.map(\.name)),["top.txt","inside.txt"]);XCTAssertEqual(Set(report.hits.map(\.id)).count,report.hits.count)
    }
    func testAdvancedSearchBoundedOverlapsKeepDeeperExplicitRoots() throws {
        let parent = try folder("A"),child = try folder("A/Deep");try file("A/top.txt","top");try file("A/Deep/inside.txt","inside");try file("A/Deep/Lower/not.txt","deep")
        var options = SearchOptions();options.kind = .files;options.maximumDepth = 0
        let report = try SearchService.search([parent,child,parent],options:options)
        XCTAssertEqual(Set(report.hits.map(\.name)),["top.txt","inside.txt"]);XCTAssertEqual(report.hits.count,2)
        options.maximumDepth = nil;options.recursive = false
        XCTAssertEqual(Set(try SearchService.search([child,parent],options:options).hits.map(\.name)),["top.txt","inside.txt"])
    }
    func testAdvancedSearchExplicitRootsInsidePrunedFoldersAreRetained() throws {
        let parent = try folder("A"),cache = try folder("A/Cache"),hidden = try folder("A/.Hidden")
        try file("A/visible.txt","v");try file("A/Cache/cached.txt","c");try file("A/.Hidden/hidden.txt","h")
        var options = SearchOptions();options.kind = .files;options.excludedFolders = "Cache"
        XCTAssertEqual(try SearchService.searchRoots([parent,cache,hidden],options:options).count,3)
        let report = try SearchService.search([parent,cache,hidden],options:options)
        XCTAssertEqual(Set(report.hits.map(\.name)),["visible.txt","cached.txt","hidden.txt"])
        XCTAssertEqual(report.hits.count,3)
    }
    func testAdvancedSearchDuplicateDirectoriesStillApplyPruningRules() throws {
        let parent = try folder("A"),explicit = try folder("A/B")
        try file("A/B/Cache/secret.txt","excluded");try file("A/B/Allowed/visible.txt","included")
        var options = SearchOptions();options.kind = .files;options.maximumDepth = 1;options.excludedFolders = "Cache"
        let report = try SearchService.search([parent,explicit],options:options)
        XCTAssertEqual(report.hits.map(\.name),["visible.txt"])
        XCTAssertFalse(report.hits.contains { $0.name == "secret.txt" });XCTAssertEqual(report.hits.count,1)
    }
    func testAdvancedSearchSnippetsBoundBytesAcrossGiantCombiningGraphemes() throws {
        let marks = String(repeating:"\u{0301}",count:300_000)
        try file("A/before.txt","X"+marks+" needle tail")
        try file("A/after.txt","needle X"+marks+" tail")
        var options = SearchOptions();options.kind = .files;options.content = "needle"
        let report = try SearchService.search(root.appendingPathComponent("A"),options:options)
        XCTAssertEqual(report.hits.count,2)
        for hit in report.hits {
            XCTAssertTrue(hit.snippet.utf8.count <= 1024);XCTAssertTrue(hit.snippet.utf16.count <= 1024)
            XCTAssertTrue(hit.snippet.contains("needle"))
            XCTAssertTrue(hit.snippet.unicodeScalars.contains(UnicodeScalar(0x2026)!))
            XCTAssertFalse(hit.snippet.unicodeScalars.contains(UnicodeScalar(0xFFFD)!))
        }
    }
    func testAdvancedSearchRootValidationPrecedesTraversal() throws {
        let valid = try folder("Valid");try file("Valid/file.txt","text");var updates = 0
        XCTAssertThrowsError(try SearchService.search([valid,root.appendingPathComponent("Missing")],options:SearchOptions(),onUpdate:{_ in updates += 1}))
        XCTAssertEqual(updates,0);XCTAssertThrowsError(try SearchService.search([],options:SearchOptions()))
        XCTAssertThrowsError(try SearchService.search([URL(string:"https://example.invalid/")!],options:SearchOptions()))
        XCTAssertThrowsError(try SearchService.search(Array(repeating:valid,count:101),options:SearchOptions()))
    }
    func testAdvancedSearchDepthCountsFolderLevelsPerRoot() throws {
        try file("A/zero.txt","0");try file("A/One/one.txt","1");try file("A/One/Two/two.txt","2")
        var options = SearchOptions();options.kind = .files;options.maximumDepth = 0
        let base = root.appendingPathComponent("A")
        XCTAssertEqual(try SearchService.search(base,options:options).hits.map(\.name),["zero.txt"])
        options.maximumDepth = 1;XCTAssertEqual(Set(try SearchService.search(base,options:options).hits.map(\.name)),["zero.txt","one.txt"])
        options.maximumDepth = 2;XCTAssertEqual(try SearchService.search(base,options:options).hits.count,3)
    }
    func testAdvancedSearchRegexMatchesUnicodeAndCaseRules() throws {
        try file("A/yes.txt","Grüße 42 aus Wien\n");try file("A/no.txt","Grüße ohne Zahl")
        var options = SearchOptions();options.contentMode = .regularExpression;options.content = "grüße\\s+\\d+";options.kind = .files
        let base = root.appendingPathComponent("A"),report = try SearchService.search(base,options:options)
        XCTAssertEqual(report.hits.map(\.name),["yes.txt"]);XCTAssertTrue(report.hits[0].snippet.contains("Grüße 42"))
        options.caseSensitive = true;XCTAssertTrue(try SearchService.search(base,options:options).hits.isEmpty)
    }
    func testAdvancedSearchRegexReadsSelectedUTF16Encoding() throws {
        let url = try file("A/utf16.txt","");try "Äpfel 73".data(using:.utf16LittleEndian)!.write(to:url)
        var options = SearchOptions();options.contentMode = .regularExpression;options.content = "Äpfel \\d+";options.encoding = .utf16LE
        XCTAssertEqual(try SearchService.search(root.appendingPathComponent("A"),options:options).hits.map(\.name),["utf16.txt"])
    }
    func testAdvancedSearchNegatedTextIncludesOnlyExaminedText() throws {
        try file("A/yes.txt","the needle");try file("A/no.txt","haystack");try file("A/empty.txt","")
        let binary = try file("A/binary.bin","");try Data([0,1,2,3]).write(to:binary)
        var options = SearchOptions();options.content = "needle";options.contentNegated = true
        let report = try SearchService.search(root.appendingPathComponent("A"),options:options)
        XCTAssertEqual(Set(report.hits.map(\.name)),["no.txt","empty.txt"]);XCTAssertTrue(report.hits.allSatisfy { $0.snippet.contains("nicht enthalten") })
        options.contentMode = .regularExpression;options.content = "n.e+dle"
        XCTAssertEqual(Set(try SearchService.search(root.appendingPathComponent("A"),options:options).hits.map(\.name)),["no.txt","empty.txt"])
    }
    func testAdvancedSearchNegatedLiteralRespectsWholeWords() throws {
        try file("A/word.txt","a cat sat");try file("A/partial.txt","a catalogue")
        var options = SearchOptions();options.content = "cat";options.contentNegated = true;options.wholeWords = true
        XCTAssertEqual(try SearchService.search(root.appendingPathComponent("A"),options:options).hits.map(\.name),["partial.txt"])
    }
    func testAdvancedSearchHexFindsZeroBytesAcrossReadBoundary() throws {
        let file = try file("A/bytes.bin","");var bytes = Data(repeating:0x11,count:65_535);bytes.append(contentsOf:[0xAA,0,0xFF,0x02]);bytes.append(Data(repeating:0x22,count:80_000));try bytes.write(to:file)
        var options = SearchOptions();options.contentMode = .hex;options.content = "AA 00 ff 02"
        let report = try SearchService.search(root.appendingPathComponent("A"),options:options)
        XCTAssertEqual(report.hits.map(\.name),["bytes.bin"]);XCTAssertTrue(report.hits[0].snippet.contains("65535"))
        options.content = "AA00FF02";XCTAssertEqual(try SearchService.search(root.appendingPathComponent("A"),options:options).hits.count,1)
    }
    func testAdvancedSearchHexNegationChecksEntireCandidate() throws {
        let present = try file("A/present.bin","");var bytes = Data(repeating:0,count:130_000);bytes.append(contentsOf:[0xAB,0xCD]);try bytes.write(to:present)
        let absent = try file("A/absent.bin","");try Data([0,1,2]).write(to:absent);try file("A/empty.bin","")
        var options = SearchOptions();options.contentMode = .hex;options.content = "AB CD";options.contentNegated = true
        XCTAssertEqual(Set(try SearchService.search(root.appendingPathComponent("A"),options:options).hits.map(\.name)),["absent.bin","empty.bin"])
    }
    func testAdvancedSearchGlobalLimitAndBatchesSpanAllRoots() throws {
        let first = try folder("A"),second = try folder("B");for name in ["a.txt","b.txt"] { try file("A/"+name,"first");try file("B/"+name,"second") }
        var options = SearchOptions();options.kind = .files;options.resultLimit = 3;var updates:[SearchHit] = []
        let report = try SearchService.search([second,first],options:options,onUpdate:{ updates += $0.hits })
        XCTAssertEqual(report.hits.count,3);XCTAssertTrue(report.limitReached);XCTAssertEqual(Set(updates.map(\.id)),Set(report.hits.map(\.id)));XCTAssertEqual(updates.count,3)
    }
    func testAdvancedSearchCancellationStopsBeforeFollowingRoots() throws {
        let first = try folder("A"),second = try folder("B");for index in 0..<60 { try file("A/\(index).txt","a");try file("B/\(index).txt","b") }
        let token = CancellationToken();var options = SearchOptions();options.kind = .files
        let report = try SearchService.search([first,second],options:options,token:token,onUpdate:{ if !$0.hits.isEmpty { token.cancel() } })
        XCTAssertTrue(report.cancelled);XCTAssertFalse(report.hits.isEmpty);XCTAssertTrue(report.hits.count < 60);XCTAssertFalse(report.hits.contains { FileSystem.isInside($0.url,second) })
    }
    func testAdvancedSearchRegexProgressInterruptsPathologicalBacktracking() throws {
        try file("A/pathological.txt",String(repeating:"a",count:60_000)+"!")
        var options = SearchOptions();options.contentMode = .regularExpression;options.content = "(a+)+$";let started = Date()
        let report = try SearchService.search(root.appendingPathComponent("A"),options:options)
        XCTAssertTrue(Date().timeIntervalSince(started) < 3);XCTAssertTrue(report.hits.isEmpty);XCTAssertEqual(report.warningCount,1);XCTAssertTrue(report.warnings[0].contains("Rechenzeit"))
    }
    func testAdvancedSearchRegexMatchingCanBeCancelledInsideICU() throws {
        try file("A/pathological.txt",String(repeating:"a",count:60_000)+"!")
        var options = SearchOptions();options.contentMode = .regularExpression;options.content = "(a+)+$";let token = CancellationToken(),started = Date()
        DispatchQueue.global().asyncAfter(deadline:.now()+0.015) { token.cancel() }
        let report = try SearchService.search(root.appendingPathComponent("A"),options:options,token:token)
        XCTAssertTrue(report.cancelled);XCTAssertTrue(report.hits.isEmpty);XCTAssertTrue(Date().timeIntervalSince(started) < 3)
    }
    func testAdvancedSearchRegexLimitNeverCreatesNegatedFalseHits() throws {
        try file("A/large.txt",String(repeating:"a",count:1_048_577))
        var options = SearchOptions();options.contentMode = .regularExpression;options.content = "missing";options.contentNegated = true
        let report = try SearchService.search(root.appendingPathComponent("A"),options:options)
        XCTAssertTrue(report.hits.isEmpty);XCTAssertEqual(report.warningCount,1)
    }
    func testAdvancedSearchChangedCandidateIsRejectedBeforeReading() throws {
        let file = try file("A/changed.txt","before");var options = SearchOptions();options.content = "after";var changed = false
        let report = try SearchService.search(root.appendingPathComponent("A"),options:options,onUpdate:{ if !changed && $0.scanned > 0 { changed = true;try? Data("after".utf8).write(to:file) } })
        XCTAssertTrue(changed);XCTAssertTrue(report.hits.isEmpty);XCTAssertEqual(report.warningCount,1);XCTAssertEqual(try read(file),"after")
    }
    func testAdvancedSearchNeverOpensLinkedOrSpecialContentCandidates() throws {
        let outside = try file("outside.txt","needle");try folder("A")
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("A/link.txt"),withDestinationURL:outside)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("A/pipe").path,0o600),0)
        var options = SearchOptions();options.content = "needle";options.contentNegated = true
        XCTAssertTrue(try SearchService.search(root.appendingPathComponent("A"),options:options).hits.isEmpty)
    }
    func testAdvancedSearchProfilesReadLegacyAndRoundTripVersionTwoRules() throws {
        let old = Data("{\"version\":1,\"profiles\":[{\"id\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\",\"name\":\"Legacy\",\"options\":{\"name\":\"*.txt\"}}]}".utf8)
        let legacy = try SearchProfileLibrary(data:old);XCTAssertEqual(legacy.profiles[0].options.contentMode,.literal);XCTAssertTrue(legacy.profiles[0].options.maximumDepth == nil)
        var options = SearchOptions();options.contentMode = .regularExpression;options.content = "a+";options.maximumDepth = 3;options.contentNegated = true
        var library = SearchProfileLibrary();try library.save(name:"Advanced",options:options);let data = try library.encoded()
        let object = try JSONSerialization.jsonObject(with:data) as! [String:Any];XCTAssertEqual(object["version"] as? Int,2)
        XCTAssertEqual(try SearchProfileLibrary(data:data).profiles[0].options,options);XCTAssertFalse(String(decoding:data,as:UTF8.self).contains(root.path))
    }
    func testAdvancedSearchProfilesRejectRulesMislabeledAsLegacy() throws {
        var options = SearchOptions();options.content = "test";options.contentNegated = true
        var library = SearchProfileLibrary();try library.save(name:"Advanced",options:options)
        var object = try JSONSerialization.jsonObject(with:library.encoded()) as! [String:Any];object["version"] = 1
        XCTAssertThrowsError(try SearchProfileLibrary(data:JSONSerialization.data(withJSONObject:object)))
        object["version"] = 2;XCTAssertEqual(try SearchProfileLibrary(data:JSONSerialization.data(withJSONObject:object)).profiles.count,1)
    }
    func testAdvancedSearchRejectsAmbiguousOrUnsupportedRuleCombinations() throws {
        var options = SearchOptions();options.contentMode = .hex
        for text in ["","A","GG","00 ??","0xFF"] { options.content = text;XCTAssertThrowsError(try options.validate()) }
        options.content = "00 FF";options.searchOfficeDocuments = true;XCTAssertThrowsError(try options.validate())
        options.searchOfficeDocuments = false;options.encoding = .utf8;XCTAssertThrowsError(try options.validate())
        options.encoding = .automatic;options.wholeWords = true;XCTAssertThrowsError(try options.validate())
        options = SearchOptions();options.contentMode = .regularExpression;options.content = "[";XCTAssertThrowsError(try options.validate())
        options.content = "test";options.wholeWords = true;XCTAssertThrowsError(try options.validate())
        options = SearchOptions();options.contentNegated = true;XCTAssertThrowsError(try options.validate())
        options = SearchOptions();options.maximumDepth = -1;XCTAssertThrowsError(try options.validate());options.maximumDepth = 1001;XCTAssertThrowsError(try options.validate())
    }
}
