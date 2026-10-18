import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    func testSearchMultipleMasksExclusionsAndFolderPruning() throws {
        try file("project/keep.TXT");try file("project/notes.md");try file("project/skip.txt")
        try file("project/Cache42/unread.txt");try file("project/.git/config.txt");try file("project/raw.bin")
        var options = SearchOptions();options.name = "*.txt;*.md";options.excludedNames = "skip*";options.excludedFolders = "Cache*;.git";options.showHidden = true
        let report = try SearchService.search(root,options:options)
        XCTAssertEqual(Set(report.urls.map(\.lastPathComponent)),Set(["keep.TXT","notes.md"]))
        XCTAssertEqual(report.scanned,7);XCTAssertTrue(report.warnings.isEmpty)
    }
    func testSearchNonrecursiveTypesAndSymbolicLinks() throws {
        let outside = try folder("outside");try file("outside/secret.txt");let base = try folder("base")
        try file("base/direct.txt");try file("base/deep/nested.txt")
        try FileManager.default.createSymbolicLink(at:base.appendingPathComponent("link"),withDestinationURL:outside)
        var options = SearchOptions();options.recursive = false
        let direct = try SearchService.search(base,options:options)
        XCTAssertEqual(Set(direct.urls.map(\.lastPathComponent)),Set(["direct.txt","deep","link"]))
        options.kind = .folders;XCTAssertEqual(try SearchService.search(base,options:options).urls.map(\.lastPathComponent),["deep"])
        options.kind = .files;options.recursive = true
        XCTAssertEqual(Set(try SearchService.search(base,options:options).urls.map(\.lastPathComponent)),Set(["direct.txt","nested.txt","link"]))
        options.content = "example";XCTAssertFalse(try SearchService.search(base,options:options).urls.contains { $0.lastPathComponent == "link" })
    }
    func testSearchMetadataBoundsAndLinkExclusion() throws {
        let first = try file("a.txt","abc"),last = try file("b.txt","abcd");try file("short.txt","a")
        for (url,time) in [(first,1000.0),(last,2000.0)] { try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:time)],ofItemAtPath:url.path) }
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("alias.txt"),withDestinationURL:first)
        var options = SearchOptions();options.minimumSize = 3;options.maximumSize = 4;options.modifiedAfter = Date(timeIntervalSince1970:1000);options.modifiedBefore = Date(timeIntervalSince1970:2000)
        XCTAssertEqual(try SearchService.search(root,options:options).urls.map(\.lastPathComponent),["a.txt"])
        options.modifiedAfter = nil;options.modifiedBefore = nil;options.maximumSize = 3
        XCTAssertEqual(try SearchService.search(root,options:options).urls.map(\.lastPathComponent),["a.txt"])
    }
    func testSearchRelativeAgeSnapshotAndFutureExclusion() throws {
        let now = Date()
        for (name,days) in [("old.txt",9.0),("match.txt",3.0),("new.txt",0.1),("future.txt",-2.0)] {
            let url = try file(name);try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(-days*86400)],ofItemAtPath:url.path)
        }
        var options = SearchOptions();options.modifiedAge = TransferAgeRange(minimum:.init(1,unit:.days),maximum:.init(7,unit:.days))
        XCTAssertEqual(try SearchService.search(root,options:options).urls.map(\.lastPathComponent),["match.txt"])
    }
    func testSearchLiteralCaseWholeWordsAndSnippets() throws {
        try file("one.txt","Apfelbaum ÄPFEL _Äpfel Äpfel_ Äpfel! prefix literal.* suffix")
        var options = SearchOptions();options.content = "äpfel";options.wholeWords = true
        let report = try SearchService.search(root,options:options)
        XCTAssertEqual(report.urls.count,1);XCTAssertTrue(report.hits[0].snippet.contains("ÄPFEL"))
        options.caseSensitive = true;XCTAssertTrue(try SearchService.search(root,options:options).urls.isEmpty)
        options.content = "literal.*";XCTAssertEqual(try SearchService.search(root,options:options).urls.count,1)
        options.content = "Apfel";XCTAssertTrue(try SearchService.search(root,options:options).urls.isEmpty)
        options.wholeWords = false;XCTAssertEqual(try SearchService.search(root,options:options).urls.count,1)
    }
    func testSearchUTF16AndExplicitLegacyEncoding() throws {
        let text = "Grüße aus Wien"
        for (name,encoding) in [("bom.txt",String.Encoding.utf16),("le.txt",.utf16LittleEndian),("be.txt",.utf16BigEndian),("cp.txt",.windowsCP1252)] {
            try text.data(using:encoding)!.write(to:root.appendingPathComponent(name))
        }
        var options = SearchOptions();options.content = "Grüße"
        XCTAssertEqual(try SearchService.search(root,options:options).urls.map(\.lastPathComponent),["bom.txt"])
        for (name,encoding) in [("le.txt",SearchEncoding.utf16LE),("be.txt",.utf16BE),("cp.txt",.windows1252)] {
            options.name = name;options.encoding = encoding
            XCTAssertEqual(try SearchService.search(root,options:options).urls.count,1)
        }
    }
    func testSearchBinaryAndOversizeInputsStayUnchanged() throws {
        let binary = root.appendingPathComponent("binary.txt");try Data([0,1,2]+Array("needle".utf8)).write(to:binary)
        let big = root.appendingPathComponent("large.txt");FileManager.default.createFile(atPath:big.path,contents:nil)
        let handle = try FileHandle(forWritingTo:big);try handle.truncate(atOffset:33*1024*1024);try handle.close()
        var options = SearchOptions();options.content = "needle";options.encoding = .windows1252
        let report = try SearchService.search(root,options:options)
        XCTAssertTrue(report.urls.isEmpty);XCTAssertEqual(report.warningCount,1);XCTAssertTrue(report.warnings[0].contains("32 MiB"))
        XCTAssertEqual(try Data(contentsOf:binary),Data([0,1,2]+Array("needle".utf8)));XCTAssertEqual(try FileEntry(url:big).size,Int64(33*1024*1024))
    }
    func testSearchStreamingCancellationRetainsExactlyDeliveredResults() throws {
        for i in 0..<300 { try file("\(i).txt") }
        var delivered: [SearchHit] = [],updates: [Int] = [];let token = CancellationToken()
        let report = try SearchService.search(root,options:SearchOptions(),token:token,onUpdate:{ update in
            delivered += update.hits;updates.append(update.scanned);if !delivered.isEmpty { token.cancel() }
        })
        XCTAssertTrue(report.cancelled);XCTAssertFalse(report.limitReached);XCTAssertEqual(report.hits,delivered)
        XCTAssertTrue(report.hits.count > 0 && report.hits.count < 300)
        XCTAssertEqual(updates,updates.sorted());XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).count,300)
    }
    func testSearchPrecancelledAndNoMatchesHaveDifferentReports() throws {
        try file("a.txt");let token = CancellationToken();token.cancel()
        let cancelled = try SearchService.search(root,options:SearchOptions(),token:token)
        XCTAssertTrue(cancelled.cancelled);XCTAssertEqual(cancelled.scanned,0)
        var options = SearchOptions();options.name = "*.missing"
        let empty = try SearchService.search(root,options:options);XCTAssertFalse(empty.cancelled);XCTAssertTrue(empty.hits.isEmpty);XCTAssertEqual(empty.scanned,1)
    }
    func testSearchResultLimitIncludesArchiveMembers() throws {
        let source = try folder("source");for i in 0..<8 { try file("source/\(i).txt") }
        let search = try folder("search");try ArchiveService.pack([source],to:search.appendingPathComponent("bundle.zip"))
        var options = SearchOptions();options.name = "*.txt";options.searchArchives = true;options.resultLimit = 3
        let report = try SearchService.search(search,options:options)
        XCTAssertTrue(report.limitReached);XCTAssertEqual(report.hits.count,3);XCTAssertEqual(report.archiveMatches.count,3);XCTAssertTrue(report.urls.isEmpty)
        XCTAssertTrue(report.hits.allSatisfy { $0.url.lastPathComponent == "bundle.zip" && $0.member != nil })
    }
    func testSearchArchiveFoldersHiddenAndExcludedNames() throws {
        let source = try folder("source");try file("source/keep.txt");try file("source/.secret.txt");try file("source/Cache/off.txt");try file("source/skip.txt")
        let search = try folder("search");try ArchiveService.pack([source],to:search.appendingPathComponent("bundle.zip"))
        var options = SearchOptions();options.name = "*.txt";options.searchArchives = true;options.excludedNames = "skip*";options.excludedFolders = "Cache"
        let report = try SearchService.search(search,options:options)
        XCTAssertEqual(report.hits.map(\.name),["keep.txt"])
        options.showHidden = true;XCTAssertEqual(Set(try SearchService.search(search,options:options).hits.map(\.name)),Set(["keep.txt",".secret.txt"]))
        options.excludedNames = "*.zip";XCTAssertTrue(try SearchService.search(search,options:options).hits.isEmpty)
        options.excludedNames = "";options.recursive = false;XCTAssertTrue(try SearchService.search(search,options:options).hits.isEmpty)
        options.recursive = true;options.kind = .folders;options.name = "*"
        XCTAssertFalse(try SearchService.search(search,options:options).hits.contains { $0.name == "Cache" })
        options.kind = .folders;options.name = "*";options.excludedFolders = ""
        XCTAssertTrue(try SearchService.search(search,options:options).hits.allSatisfy(\.isDirectory))
    }
    func testSearchArchiveContentAndDatesRequireSeparateMode() throws {
        var options = SearchOptions();options.searchArchives = true;options.content = "text";XCTAssertThrowsError(try options.validate())
        options.content = "";options.modifiedAfter = Date();XCTAssertThrowsError(try options.validate())
        options.modifiedAfter = nil;options.modifiedAge = TransferAgeRange(maximum:.init(7,unit:.days));XCTAssertThrowsError(try options.validate())
    }
    func testSearchBadArchivesWarnAndContinueWithoutInventedPaths() throws {
        try file("broken.zip","not an archive");try file("good.txt")
        var options = SearchOptions();options.name = "*.txt";options.searchArchives = true
        let report = try SearchService.search(root,options:options)
        XCTAssertEqual(report.urls.map(\.lastPathComponent),["good.txt"]);XCTAssertEqual(report.warningCount,1);XCTAssertTrue(report.archiveMatches.isEmpty)
    }
    func testSearchWarningStorageIsBounded() throws {
        for i in 0..<205 { try file("\(i).zip","broken archive") }
        var options = SearchOptions();options.searchArchives = true;options.name = "*.missing"
        let report = try SearchService.search(root,options:options)
        XCTAssertEqual(report.warningCount,205);XCTAssertEqual(report.warnings.count,200);XCTAssertTrue(report.hits.isEmpty)
    }
    func testSearchValidationRejectsInvalidRulesBeforeTraversal() throws {
        var options = SearchOptions();options.regex = true;options.name = "[";XCTAssertThrowsError(try options.validate())
        options = SearchOptions();options.minimumSize = -1;XCTAssertThrowsError(try options.validate())
        options.minimumSize = 8;options.maximumSize = 7;XCTAssertThrowsError(try options.validate())
        options = SearchOptions();options.excludedFolders = "a/b";XCTAssertThrowsError(try options.validate())
        options = SearchOptions();options.resultLimit = 0;XCTAssertThrowsError(try options.validate())
        options.resultLimit = 50001;XCTAssertThrowsError(try options.validate())
        options = SearchOptions();options.content = String(repeating:"x",count:4097);XCTAssertThrowsError(try options.validate())
        options = SearchOptions();options.kind = .folders;options.maximumSize = 100;XCTAssertThrowsError(try options.validate())
        options = SearchOptions();options.kind = .folders;options.content = "text";XCTAssertThrowsError(try options.validate())
        XCTAssertThrowsError(try SearchService.search(root.appendingPathComponent("missing"),options:SearchOptions()))
    }
    func testSearchProfilesRoundTripRulesAndNoLocations() throws {
        var options = SearchOptions();options.name = "*.txt;*.md";options.excludedFolders = "Cache";options.content = "Grüße";options.encoding = .utf16LE
        options.modifiedAge = TransferAgeRange(maximum:.init(3,unit:.weeks))
        var library = SearchProfileLibrary();let id = try library.save(name:"  Dokumente  ",options:options)
        let encoded = try library.encoded(),decoded = try SearchProfileLibrary(data:encoded)
        XCTAssertEqual(decoded.profile(id)?.options,options);XCTAssertEqual(decoded.profile(id)?.name,"Dokumente")
        XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains(root.path));XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains("hits"))
        options.content = "";_ = try library.save(name:"Dokumente",options:options,replacing:id)
        XCTAssertEqual(library.profiles.count,1);try library.remove(id);XCTAssertTrue(library.profiles.isEmpty);XCTAssertThrowsError(try library.remove(id))
    }
    func testSearchProfileLimitsDuplicateNamesAndDamagedData() throws {
        var library = SearchProfileLibrary();try library.save(name:"Äpfel",options:SearchOptions())
        XCTAssertThrowsError(try library.save(name:"ÄPFEL",options:SearchOptions()));XCTAssertThrowsError(try library.save(name:"\n",options:SearchOptions()))
        for index in 1..<50 { try library.save(name:"Profil \(index)",options:SearchOptions()) }
        XCTAssertThrowsError(try library.save(name:"Zu viel",options:SearchOptions()))
        XCTAssertThrowsError(try SearchProfileLibrary(data:Data("{broken".utf8)))
        XCTAssertThrowsError(try SearchProfileLibrary(data:Data("{\"version\":2,\"profiles\":[]}".utf8)))
        XCTAssertThrowsError(try SearchProfileLibrary(data:Data(repeating:0,count:1_048_577)))
        XCTAssertThrowsError(try library.save(name:"Missing",options:SearchOptions(),replacing:UUID()))
    }
}
