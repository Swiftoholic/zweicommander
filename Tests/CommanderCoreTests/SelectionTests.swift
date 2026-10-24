import Foundation
import CommanderCore

extension CoreTests {
    private func selectionEntries() throws -> [FileEntry] {
        try [file("Plan.TXT"),file("Plan.md"),file("Grüße.pdf"),file("Readme"),folder("Plan.backup")].map { try FileEntry(url:$0) }
    }
    func testSelectionWildcardUnionAndCase() throws {
        let entries = try selectionEntries(),rule = try SelectionRule("*.txt; *.PDF")
        XCTAssertEqual(Set(rule.matching(entries).map(\.lastPathComponent)),["Plan.TXT","Grüße.pdf"])
        XCTAssertEqual(try SelectionRule("grüße").matching(entries).count,1)
    }
    func testSelectionRegexKeepsSemicolonsLiteral() throws {
        let first = try file("A;B.txt"),second = try file("AB.txt"),entries = try [first,second].map { try FileEntry(url:$0) }
        XCTAssertEqual(try SelectionRule("^a;b\\.txt$",regex:true).matching(entries),[first])
    }
    func testSelectionWildcardsMatchCompleteNamesIncludingNewlines() throws {
        let first = try file("line\nbreak.txt"),second = try file("name.txt\n"),entries = try [first,second].map { try FileEntry(url:$0) }
        XCTAssertEqual(try SelectionRule("*.txt").matching(entries),[first])
        XCTAssertEqual(try SelectionRule("line?break.txt").matching(entries),[first])
        XCTAssertFalse(try NameFilter("*.txt").matches("name.txt\n"))
    }
    func testSelectionKindsAndEmptyPattern() throws {
        let entries = try selectionEntries()
        XCTAssertEqual(try SelectionRule("",folders:false).matching(entries).count,4)
        XCTAssertEqual(try SelectionRule("*",files:false).matching(entries).count,1)
        XCTAssertEqual(try SelectionRule("no match").matching(entries),[])
    }
    func testSelectionInvalidOptionsAndPatternLimit() throws {
        XCTAssertThrowsError(try SelectionRule("[",regex:true))
        XCTAssertThrowsError(try SelectionRule("*",files:false,folders:false))
        XCTAssertThrowsError(try SelectionRule(String(repeating:"ä",count:2049)))
        XCTAssertNotNil(try SelectionRule(String(repeating:"a",count:4096)))
    }
    func testSelectionAllModesExcludeOutsideUniverse() throws {
        let urls = (0..<4).map { root.appendingPathComponent(String($0)) },universe = Set(urls.prefix(3)),current:Set<URL> = [urls[0],urls[1],urls[3]],matches:Set<URL> = [urls[1],urls[2],urls[3]]
        XCTAssertEqual(SelectionCombine.replace.apply(current:current,matches:matches,universe:universe),[urls[1],urls[2]])
        XCTAssertEqual(SelectionCombine.add.apply(current:current,matches:matches,universe:universe),universe)
        XCTAssertEqual(SelectionCombine.remove.apply(current:current,matches:matches,universe:universe),[urls[0]])
        XCTAssertEqual(SelectionCombine.intersect.apply(current:current,matches:matches,universe:universe),[urls[1]])
    }
    func testSelectionSameStemFoldsUnicodeAndKeepsKindsSeparate() throws {
        let a = try FileEntry(url:file("Résumé.txt")),b = try FileEntry(url:file("Re\u{301}sume\u{301}.PDF")),c = try FileEntry(url:folder("Résumé")),d = try FileEntry(url:file("Resume.md"))
        XCTAssertEqual(SelectionNames.sameStem(as:a,in:[a,b,c,d]),[a.url,b.url])
        XCTAssertEqual(SelectionNames.sameStem(as:c,in:[a,b,c,d]),[c.url])
    }
    func testSelectionSameExtensionAndExtensionlessFiles() throws {
        let entries = try selectionEntries(),other = try FileEntry(url:file("Other.txt")),plain = try FileEntry(url:file("LICENSE"))
        XCTAssertEqual(SelectionNames.sameExtension(as:entries[0],in:entries+[other]),[entries[0].url,other.url])
        XCTAssertEqual(SelectionNames.sameExtension(as:entries[3],in:entries+[plain]),[entries[3].url,plain.url])
        XCTAssertEqual(SelectionNames.sameExtension(as:entries[4],in:entries),[])
    }
    func testSelectionCopyNamesAndStemsPreserveOrder() throws {
        let entries = try selectionEntries()
        XCTAssertEqual(try SelectionCopyFormat.names.render(entries),"Plan.TXT\nPlan.md\nGrüße.pdf\nReadme\nPlan.backup")
        XCTAssertEqual(try SelectionCopyFormat.stems.render(entries),"Plan\nPlan\nGrüße\nReadme\nPlan.backup")
        XCTAssertEqual(try SelectionCopyFormat.names.render([]),"")
    }
    func testSelectionShellArgumentsRoundTripWithoutExecution() throws {
        let names = ["space name.txt","it's.txt","$HOME.txt","line\nbreak.txt","$(touch PWNED).txt","semi;colon.txt"],entries = try names.map { try FileEntry(url:file($0)) }
        let arguments = try SelectionCopyFormat.shellArguments.render(entries)
        let script = "set -- "+arguments+"; printf '%s\\0' \"$@\""
        let output = try ProcessRunner.run("/bin/zsh",arguments:["-f","-c",script],directory:root)
        XCTAssertEqual(output.split(separator:"\0",omittingEmptySubsequences:true).map(String.init),entries.map { $0.url.path })
        XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("PWNED")))
    }
    func testSelectionCopyRemoteAddressesExcludeSecrets() throws {
        let entry = FileEntry(remote:RemoteEntry(name:"Grüße.txt",isDirectory:false),address:URL(string:"sftp://user:secret@example.invalid:2222/Gr%C3%BC%C3%9Fe.txt?token=hidden#hidden")!)
        let expected = "sftp://example.invalid:2222/Gr%C3%BC%C3%9Fe.txt"
        XCTAssertEqual(try SelectionCopyFormat.paths.render([entry]),expected)
        XCTAssertEqual(try SelectionCopyFormat.urls.render([entry]),expected)
        XCTAssertFalse(try SelectionCopyFormat.table.render([entry]).contains("secret"))
        XCTAssertThrowsError(try SelectionCopyFormat.shellArguments.render([entry]))
    }
    func testSelectionCopyLocalPathsAndEncodedURLs() throws {
        let entry = try FileEntry(url:file("Grüße #1.txt"))
        XCTAssertEqual(try SelectionCopyFormat.paths.render([entry]),entry.url.path)
        XCTAssertEqual(try SelectionCopyFormat.urls.render([entry]),entry.url.absoluteString)
        XCTAssertTrue(try SelectionCopyFormat.urls.render([entry]).contains("%23"))
    }
    func testSelectionTableEscapesControlCharactersAndMissingMetadata() throws {
        let entry = FileEntry(remote:RemoteEntry(name:"a\tline\nb\\c\r",isDirectory:false,size:42),address:URL(string:"ftp://example.invalid/a%09line%0Ab%5Cc%0D")!)
        let rows = try SelectionCopyFormat.table.render([entry]).components(separatedBy:"\n")
        XCTAssertEqual(rows.count,2)
        let cells = rows[1].components(separatedBy:"\t")
        XCTAssertEqual(cells.count,5);XCTAssertEqual(cells[0],"a\\tline\\nb\\\\c\\r");XCTAssertEqual(cells[1],"42");XCTAssertEqual(cells[2],"")
        let directory = FileEntry(remote:RemoteEntry(name:"Ordner",isDirectory:true,size:1024,modified:Date(timeIntervalSince1970:0)),address:URL(string:"ftp://example.invalid/Ordner")!)
        let fields = try SelectionCopyFormat.table.render([directory]).components(separatedBy:"\n")[1].components(separatedBy:"\t")
        XCTAssertEqual(fields[1],"");XCTAssertEqual(fields[2],"1970-01-01T00:00:00Z")
    }
    func testSelectionDocumentRoundTripLocalRemoteAndEmpty() throws {
        let urls = [root.appendingPathComponent("Grüße\nund Leerzeichen.txt"),URL(string:"sftp://example.invalid:2222/Ordner/Bild.png")!]
        let encoded = try SelectionDocument(urls).encoded(),decoded = try SelectionDocument.decode(encoded)
        XCTAssertEqual(decoded.urls,urls);XCTAssertEqual(decoded.schemaVersion,1)
        XCTAssertEqual(try SelectionDocument.decode(SelectionDocument([]).encoded()).urls,[])
    }
    func testSelectionDocumentRejectsCredentialsAndForeignFileHosts() throws {
        for address in ["ftp://user@example.invalid/path","sftp://user:password@example.invalid/path","file://other.invalid/path","file://localhost:123/path","ftp://example.invalid/path?token=secret","sftp://example.invalid/path#secret"] {
            XCTAssertThrowsError(try SelectionDocument([URL(string:address)!]))
        }
    }
    func testSelectionDocumentRejectsRelativeSchemesPortsAndNUL() throws {
        for address in ["relative/path","https://example.invalid/path","sftp://example.invalid:0/path","ftp://example.invalid:65536/path","file:///tmp/a%00b","ftp://example.invalid/a%00b","ftp:///path"] {
            XCTAssertThrowsError(try SelectionDocument([URL(string:address)!]))
        }
    }
    func testSelectionDocumentLimitsVersionAndDuplicates() throws {
        let url = root.appendingPathComponent("a")
        XCTAssertThrowsError(try SelectionDocument([url,url]))
        XCTAssertThrowsError(try SelectionDocument((0...SelectionDocument.maximumItems).map { root.appendingPathComponent(String($0)) }))
        XCTAssertThrowsError(try SelectionDocument.decode(Data(repeating:32,count:SelectionDocument.maximumBytes+1)))
        XCTAssertThrowsError(try SelectionDocument.decode(Data("{\"schemaVersion\":2,\"paths\":[]}".utf8)))
        XCTAssertThrowsError(try SelectionDocument.decode(Data("{\"schemaVersion\":1,\"paths\":[\"file:///tmp/a%00b\"]}".utf8)))
    }
    func testSelectionDocumentEncodingByteLimitAndNoFileAccess() throws {
        let urls = (0..<40).map { root.appendingPathComponent(String($0)+String(repeating:"x",count:60_000)) }
        let document = try SelectionDocument(urls)
        XCTAssertThrowsError(try document.encoded())
        let missing = root.appendingPathComponent("missing"),link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:missing)
        let decoded = try SelectionDocument.decode(SelectionDocument([link,missing]).encoded())
        XCTAssertEqual(decoded.urls,[link,missing]);XCTAssertFalse(FileSystem.exists(missing))
        XCTAssertTrue(FileSystem.isSymlink(link))
    }
}
