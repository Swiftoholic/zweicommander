import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    private func diffPair(_ left:String,_ right:String,options:FileDiffOptions = .init(),limits:FileDiffLimits = .init()) throws -> FileDiffResult {
        let a = try file("left.txt",left),b = try file("right.txt",right)
        return try FileDiffService.compare(a,b,options:options,limits:limits)
    }
    func testFileDiffEqualTextAndEmptyFiles() throws {
        let empty = try diffPair("","");XCTAssertTrue(empty.isEqual);XCTAssertTrue(empty.byteIdentical);XCTAssertEqual(empty.rows.count,0)
        let result = try diffPair("eins\nzwei\n","eins\nzwei\n")
        XCTAssertEqual(result.mode,.text);XCTAssertEqual(result.leftLineCount,2);XCTAssertEqual(result.rows.map(\.kind),[.equal,.equal]);XCTAssertTrue(result.differenceStarts.isEmpty)
    }
    func testFileDiffMixedInsertRemoveAndReplaceKeepsPositions() throws {
        let a = "gleich\nalt\nbleibt\nentfernt\nEnde\n",b = "vorne\ngleich\nneu\nbleibt\nEnde\nhinten\n",result = try diffPair(a,b)
        XCTAssertFalse(result.isEqual);XCTAssertEqual(result.rows.compactMap(\.leftPosition),[1,2,3,4,5]);XCTAssertEqual(result.rows.compactMap(\.rightPosition),[1,2,3,4,5,6])
        XCTAssertEqual(result.rows.compactMap { row in row.leftText.map { $0+(row.leftEnding ?? "") } }.joined(),a)
        XCTAssertEqual(result.rows.compactMap { row in row.rightText.map { $0+(row.rightEnding ?? "") } }.joined(),b)
        XCTAssertEqual(result.changedRows,1);XCTAssertEqual(result.addedRows,2);XCTAssertEqual(result.removedRows,1);XCTAssertEqual(result.differenceStarts.count,4)
    }
    func testFileDiffSmallScriptsHaveOptimalEditCost() throws {
        var seed:UInt64 = 71
        func next(_ max:Int) -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1;return Int((seed >> 32) % UInt64(max)) }
        for _ in 0..<80 {
            let a = (0..<next(8)).map { _ in String(next(4)) },b = (0..<next(8)).map { _ in String(next(4)) }
            var lengths = Array(repeating:Array(repeating:0,count:b.count+1),count:a.count+1)
            for x in a.indices { for y in b.indices { lengths[x+1][y+1] = a[x] == b[y] ? lengths[x][y]+1 : max(lengths[x][y+1],lengths[x+1][y]) } }
            let result = try diffPair(a.map{$0+"\n"}.joined(),b.map{$0+"\n"}.joined())
            XCTAssertEqual(2*result.changedRows+result.addedRows+result.removedRows,a.count+b.count-2*lengths[a.count][b.count])
            XCTAssertEqual(result.rows.compactMap(\.leftText),a);XCTAssertEqual(result.rows.compactMap(\.rightText),b)
        }
    }
    func testFileDiffUnicodeAndCaseWhitespaceRules() throws {
        let strict = try diffPair("Äpfel 👩🏽‍💻\nWien\n","äpfel 👩🏽‍💻 \nw i e n\n");XCTAssertFalse(strict.isEqual)
        var options = FileDiffOptions();options.ignoreCase = true;options.ignoreWhitespace = true
        let relaxed = try diffPair("Äpfel 👩🏽‍💻\nWien\n","äpfel 👩🏽‍💻 \nw i e n\n",options:options)
        XCTAssertTrue(relaxed.isEqual);XCTAssertFalse(relaxed.byteIdentical);XCTAssertEqual(relaxed.rows[0].leftText,"Äpfel 👩🏽‍💻")
    }
    func testFileDiffLineEndingsAndFinalNewlineAreExplicit() throws {
        var options = FileDiffOptions();options.ignoreLineEndings = false
        let result = try diffPair("eins\r\nzwei\rende","eins\nzwei\nende\n",options:options)
        XCTAssertEqual(result.changedRows,3);XCTAssertEqual(result.rows.map(\.leftEnding),["\r\n","\r",""]);XCTAssertEqual(result.rows.map(\.rightEnding),["\n","\n","\n"])
        options.ignoreLineEndings = true;XCTAssertTrue(try diffPair("eins\r\nzwei\rende","eins\nzwei\nende\n",options:options).isEqual)
        XCTAssertEqual(try diffPair("\n","").removedRows,1)
    }
    func testFileDiffDetectsUTF16BOMAndExplicitLegacyEncoding() throws {
        let left = try file("a.txt",""),right = try file("b.txt","Grüße\n")
        var utf16 = Data([0xFF,0xFE]);utf16.append("Grüße\n".data(using:.utf16LittleEndian)!);try utf16.write(to:left)
        let auto = try FileDiffService.compare(left,right);XCTAssertEqual(auto.mode,.text);XCTAssertTrue(auto.isEqual);XCTAssertFalse(auto.byteIdentical)
        try "Grüße\n".data(using:.windowsCP1252)!.write(to:left);try "GRÜSSE\n".data(using:.windowsCP1252)!.write(to:right)
        var options = FileDiffOptions();options.mode = .text;options.encoding = .windows1252;options.ignoreCase = true
        XCTAssertTrue(try FileDiffService.compare(left,right,options:options).isEqual)
    }
    func testFileDiffUTF8BOMAndEmptyBOMAreTextMetadata() throws {
        let a = try file("a.txt",""),b = try file("b.txt","")
        try Data([0xEF,0xBB,0xBF]).write(to:a)
        let result = try FileDiffService.compare(a,b);XCTAssertTrue(result.isEqual);XCTAssertEqual(result.leftLineCount,0);XCTAssertFalse(result.byteIdentical)
    }
    func testFileDiffMalformedUTF16AndWrongEndianNeverBecomeEqualText() throws {
        let a = try file("a.txt",""),b = try file("b.txt",""),samples:[[UInt8]] = [[0xFF,0xFE,0,0xD8],[0xFF,0xFE,0,0xDC],[0xFE,0xFF,0xD8,0]]
        var options = FileDiffOptions();options.mode = .text
        for bytes in samples {
            try Data(bytes).write(to:a);try Data(bytes).write(to:b)
            XCTAssertThrowsError(try FileDiffService.compare(a,b,options:options));XCTAssertEqual(try FileDiffService.compare(a,b).mode,.binary)
        }
        try Data([0xFE,0xFF,0,0x41]).write(to:a);try Data([0xFE,0xFF,0,0x41]).write(to:b);options.encoding = .utf16LE
        XCTAssertThrowsError(try FileDiffService.compare(a,b,options:options))
    }
    func testFileDiffInvalidTextFallsBackOnlyInAutomaticMode() throws {
        let a = try file("a.bin",""),b = try file("b.bin","");try Data([0,0xFF,1]).write(to:a);try Data([0,0xFF,2]).write(to:b)
        let result = try FileDiffService.compare(a,b);XCTAssertEqual(result.mode,.binary);XCTAssertEqual(result.differentBytes,1)
        var text = FileDiffOptions();text.mode = .text;XCTAssertThrowsError(try FileDiffService.compare(a,b,options:text))
        text.encoding = .utf16LE;try Data([0xFF,0xFE,1]).write(to:a);XCTAssertThrowsError(try FileDiffService.compare(a,b,options:text))
    }
    func testFileDiffBinaryRangesIncludeExactOffsetsAndTailCounts() throws {
        let a = try file("a.bin",""),b = try file("b.bin","");try Data([1,2,3,4]).write(to:a);try Data([1,9,8,4,5,6]).write(to:b)
        var options = FileDiffOptions();options.mode = .binary
        let result = try FileDiffService.compare(a,b,options:options)
        XCTAssertEqual(result.rows.map(\.kind),[.equal,.changed,.equal,.added]);XCTAssertEqual(result.rows.compactMap(\.leftPosition),[0,1,3]);XCTAssertEqual(result.rows.compactMap(\.rightPosition),[0,1,3,4])
        XCTAssertEqual(result.rows.map(\.leftLength),[1,2,1,0]);XCTAssertEqual(result.rows.map(\.rightLength),[1,2,1,2]);XCTAssertEqual(result.differentBytes,4)
        XCTAssertEqual(result.rows[1].leftText,"02 03");XCTAssertEqual(result.rows[1].rightText,"09 08")
    }
    func testFileDiffBinaryWholeRangePreviewIsLabelledAndComplete() throws {
        let a = try file("a.bin",""),b = try file("b.bin","");try Data(repeating:1,count:4096).write(to:a);try Data(repeating:2,count:4096).write(to:b)
        var options = FileDiffOptions();options.mode = .binary;let result = try FileDiffService.compare(a,b,options:options)
        XCTAssertEqual(result.rows.count,1);XCTAssertEqual(result.rows[0].leftLength,4096);XCTAssertTrue(result.rows[0].leftText!.contains("4096 Bytes im Bereich"));XCTAssertEqual(result.differentBytes,4096)
    }
    func testFileDiffRefusesLinksDirectoriesPipesAndRemoteAddresses() throws {
        let a = try file("a.txt","safe"),b = try file("b.txt","safe"),link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:a)
        XCTAssertThrowsError(try FileDiffService.compare(link,b));XCTAssertThrowsError(try FileDiffService.compare(root,b));XCTAssertThrowsError(try FileDiffService.compare(URL(string:"sftp://example.invalid/a")!,b))
        let pipe = root.appendingPathComponent("pipe");XCTAssertEqual(mkfifo(pipe.path,0o600),0);XCTAssertThrowsError(try FileDiffService.compare(pipe,b))
        XCTAssertEqual(try read(a),"safe")
    }
    func testFileDiffByteLineAndRowLimitsRejectWholeResult() throws {
        XCTAssertThrowsError(try diffPair("long", "text",limits:.init(maximumBytes:3)))
        XCTAssertThrowsError(try diffPair("a\nb\nc\n", "a\nb\nc\n",limits:.init(maximumLines:2)))
        XCTAssertThrowsError(try diffPair("12345", "12345",limits:.init(maximumLineBytes:4)))
        XCTAssertThrowsError(try diffPair("a\nb\n", "a\nb\n",limits:.init(maximumRows:1)))
        XCTAssertThrowsError(try diffPair("", "",limits:.init(maximumBytes:17*1024*1024)))
    }
    func testFileDiffComplexityAndTraceBudgetsAreEnforced() throws {
        let a = (0..<20).map { "left-\($0)\n" }.joined(),b = (0..<20).map { "right-\($0)\n" }.joined()
        XCTAssertThrowsError(try diffPair(a,b,limits:.init(maximumWork:10)))
        XCTAssertThrowsError(try diffPair(a,b,limits:.init(maximumTraceCells:9)))
    }
    func testFileDiffCancellationBeforeReadAndDuringAnalysis() throws {
        let a = try file("a.txt","one\ntwo\n"),b = try file("b.txt","one\nother\n"),before = CancellationToken();before.cancel()
        XCTAssertThrowsError(try FileDiffService.compare(a,b,token:before))
        let token = CancellationToken();var observed = false
        XCTAssertThrowsError(try FileDiffService.compare(a,b,token:token,progress:{ if $0.stage == .comparing { observed = true;token.cancel() } }))
        XCTAssertTrue(observed);XCTAssertEqual(try read(a),"one\ntwo\n");XCTAssertEqual(try read(b),"one\nother\n")
    }
    func testFileDiffChangedOpenSourceNeverReturnsAResult() throws {
        let a = try file("a.txt","one\n"),b = try file("b.txt","two\n");var changed = false
        XCTAssertThrowsError(try FileDiffService.compare(a,b,progress:{ value in
            if value.stage == .readingLeft && !changed { changed = true;try? Data("external edit\n".utf8).write(to:a) }
        }));XCTAssertTrue(changed);XCTAssertEqual(try read(a),"external edit\n")
    }
    func testFileDiffReplacementAndSameSizeRestoredDateInvalidateSnapshot() throws {
        let a = try file("a.txt","same"),b = try file("b.txt","same"),result = try FileDiffService.compare(a,b)
        let date = try FileManager.default.attributesOfItem(atPath:a.path)[.modificationDate] as! Date
        try Data("edit".utf8).write(to:a);try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:a.path)
        XCTAssertThrowsError(try result.validateSources())
        let next = try FileDiffService.compare(a,b);try Data("edit".utf8).write(to:a,options:.atomic);XCTAssertThrowsError(try next.validateSources())
    }
    func testFileDiffRevalidatesBothSourcesAfterTheLastProgressCallback() throws {
        let a = try file("a.txt","one"),b = try file("b.txt","two");var replaced = false
        XCTAssertThrowsError(try FileDiffService.compare(a,b,progress:{ if $0.stage == .finished { replaced = true;try? Data("new".utf8).write(to:a,options:.atomic) } }));XCTAssertTrue(replaced)
    }
    func testFileDiffSameFileIsAllowedAndDoesNotWrite() throws {
        let a = try file("a.txt","same 👋\n"),before = try Data(contentsOf:a)
        let result = try FileDiffService.compare(a,a);XCTAssertTrue(result.isEqual);XCTAssertTrue(result.byteIdentical);XCTAssertEqual(try Data(contentsOf:a),before);try result.validateSources()
    }
}
