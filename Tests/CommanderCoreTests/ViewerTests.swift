import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    func testViewerBoundedWindowsAndEmptyFiles() throws {
        let url = try file("sample","0123456789"),reader = try ViewerFile(url)
        XCTAssertEqual(reader.size,10);XCTAssertEqual(try reader.read(offset:3,length:4).data,Data("3456".utf8))
        XCTAssertEqual(try reader.read(offset:8,length:4).data,Data("89".utf8));XCTAssertEqual(try reader.read(offset:10,length:4).data.count,0)
        XCTAssertThrowsError(try reader.read(offset:-1,length:3));XCTAssertThrowsError(try reader.read(offset:11,length:3));XCTAssertThrowsError(try reader.read(offset:0,length:ViewerFile.maximumWindowBytes+1))
        let empty = try ViewerFile(file("empty",""));XCTAssertEqual(try empty.textWindow(offset:0,length:100).text,"")
        XCTAssertEqual(try empty.find(ViewerNeedle(hex:"00"),from:0),nil)
    }
    func testViewerUTF8WindowsKeepSplitCharactersIntact() throws {
        let text = "ab😀ö終cd",url = try file("utf8",text),reader = try ViewerFile(url)
        for offset in 2...5 {
            let page = try reader.textWindow(offset:Int64(offset),length:1,encoding:.utf8)
            XCTAssertEqual(page.text,"😀");XCTAssertEqual(page.bytes.offset,2);XCTAssertFalse(page.hadDecodingErrors)
        }
        let second = try reader.textWindow(offset:7,length:1,encoding:.utf8);XCTAssertEqual(second.text,"ö");XCTAssertEqual(second.bytes.offset,6)
        let page = try reader.textWindow(offset:0,length:4,encoding:.utf8);XCTAssertEqual(page.text,"ab");XCTAssertEqual(page.bytes.end,2)
    }
    func testViewerUTF16WindowsRespectEndianSurrogatesAndBOM() throws {
        for (encoding,foundation,bom) in [(ViewerEncoding.utf16LE,String.Encoding.utf16LittleEndian,Data([0xFF,0xFE])),(.utf16BE,.utf16BigEndian,Data([0xFE,0xFF]))] {
            let url = root.appendingPathComponent(encoding.rawValue);try (bom+"a😀b".data(using:foundation)!).write(to:url)
            let reader = try ViewerFile(url);XCTAssertEqual(try reader.resolvedEncoding(.automatic),encoding)
            XCTAssertEqual(try reader.textWindow(offset:0,length:100).text,"a😀b")
            for offset in [4,5,6,7] { let page = try reader.textWindow(offset:Int64(offset),length:1);XCTAssertEqual(page.text,"😀");XCTAssertEqual(page.bytes.offset,4);XCTAssertFalse(page.hadDecodingErrors) }
        }
    }
    func testViewerMalformedTextIsExplicitAndLegacyDecodingIsAvailable() throws {
        let url = root.appendingPathComponent("bytes");try Data([0x80,0xE4,0xFF]).write(to:url);let reader = try ViewerFile(url)
        XCTAssertTrue(try reader.textWindow(offset:0,length:100,encoding:.utf8).hadDecodingErrors)
        XCTAssertEqual(try reader.textWindow(offset:0,length:100,encoding:.windows1252).text,"€äÿ")
        XCTAssertEqual(try reader.textWindow(offset:0,length:100,encoding:.latin1).text,"\u{80}äÿ")
        let odd = root.appendingPathComponent("odd");try Data([0xFF,0xFE,0x41]).write(to:odd)
        XCTAssertTrue(try ViewerFile(odd).textWindow(offset:0,length:100).hadDecodingErrors)
    }
    func testViewerHexNeedlesRejectInvalidOrUnboundedInput() throws {
        XCTAssertEqual(try ViewerNeedle(hex:"48 65\n6c\t6C 6f").data,Data("Hello".utf8))
        for text in ["","1","FF0","GG","0xAA","AA?B"] { XCTAssertThrowsError(try ViewerNeedle(hex:text)) }
        XCTAssertThrowsError(try ViewerNeedle(bytes:Data(repeating:0,count:ViewerNeedle.maximumBytes+1)))
        XCTAssertThrowsError(try ViewerNeedle(text:"",encoding:.utf8));XCTAssertThrowsError(try ViewerNeedle(text:"😀",encoding:.windows1252))
    }
    func testViewerForwardSearchCrossesReadAndDisplayBoundaries() throws {
        let url = try file("large",String(repeating:"a",count:65_533)+"needle"+String(repeating:"z",count:70_000)),reader = try ViewerFile(url),needle = try ViewerNeedle(text:"needle",encoding:.utf8)
        let match = try reader.find(needle,from:0,wrap:false);XCTAssertEqual(match?.offset,65_533);XCTAssertEqual(match?.length,6)
        let text = try reader.textWindow(offset:match!.offset,length:32);XCTAssertTrue(text.text.hasPrefix("needle"));XCTAssertEqual(try reader.find(needle,from:65_534,wrap:false),nil)
    }
    func testViewerBackwardSearchCrossesReadBoundaries() throws {
        let url = try file("backward",String(repeating:"a",count:70_000)+"needle"+String(repeating:"z",count:65_533)),reader = try ViewerFile(url),needle = try ViewerNeedle(hex:"6E 65 65 64 6C 65")
        XCTAssertEqual(try reader.find(needle,from:reader.size,direction:.backward,wrap:false)?.offset,70_000)
        XCTAssertEqual(try reader.find(needle,from:70_000,direction:.backward,wrap:false),nil)
    }
    func testViewerSearchWrapAndOverlappingMatchesAreConsistent() throws {
        let reader = try ViewerFile(file("overlap","ababa-----aba")),needle = try ViewerNeedle(text:"aba",encoding:.utf8)
        XCTAssertEqual(try reader.find(needle,from:1,wrap:false)?.offset,2)
        XCTAssertEqual(try reader.find(needle,from:2,direction:.backward,wrap:false)?.offset,0)
        let next = try reader.find(needle,from:11);XCTAssertEqual(next?.offset,0);XCTAssertEqual(next?.wrapped,true)
        let previous = try reader.find(needle,from:0,direction:.backward);XCTAssertEqual(previous?.offset,10);XCTAssertEqual(previous?.wrapped,true)
        XCTAssertEqual(try reader.find(needle,from:0,direction:.backward,wrap:false),nil)
    }
    func testViewerSearchRespectsSelectedTextEncodingAndBytePositions() throws {
        let url = root.appendingPathComponent("utf16");try (Data([0xFF,0xFE])+"α😀終α".data(using:.utf16LittleEndian)!).write(to:url)
        let reader = try ViewerFile(url),encoding = try reader.resolvedEncoding(.automatic),needle = try ViewerNeedle(text:"😀終",encoding:encoding)
        XCTAssertEqual(try reader.find(needle,from:0)?.offset,4)
        let page = try reader.textWindow(offset:0,length:100),match = try reader.find(needle,from:0)!
        XCTAssertEqual(page.range(for:match),NSRange(location:1,length:3))
    }
    func testViewerTextHighlightUsesUTF16RangesWithoutLosingUnicode() throws {
        let reader = try ViewerFile(file("text","a😀b終c")),match = try reader.find(ViewerNeedle(text:"b終",encoding:.utf8),from:0)!
        let page = try reader.textWindow(offset:0,length:100);XCTAssertEqual(page.range(for:match),NSRange(location:3,length:2))
        let last = try reader.textWindow(offset:9,length:10);XCTAssertEqual(last.range(for:match),nil)
    }
    func testViewerReadsAndSearchesHonorEarlyCancellation() throws {
        let reader = try ViewerFile(file("cancel","contents")),token = CancellationToken();token.cancel()
        XCTAssertThrowsError(try reader.read(offset:0,length:5,token:token));XCTAssertThrowsError(try reader.textWindow(offset:0,length:5,token:token))
        XCTAssertThrowsError(try reader.find(ViewerNeedle(hex:"63"),from:0,token:token))
    }
    func testViewerStreamingSearchCanCancelBetweenChunks() throws {
        let reader = try ViewerFile(file("large",String(repeating:"x",count:300_000))),token = CancellationToken();var updates = 0
        XCTAssertThrowsError(try reader.find(ViewerNeedle(text:"missing",encoding:.utf8),from:0,token:token,progress:{ _,_ in updates += 1;token.cancel() }))
        XCTAssertEqual(updates,1)
    }
    func testViewerRejectsInPlaceEditsEvenWithRestoredModificationDate() throws {
        let url = try file("source","original"),reader = try ViewerFile(url),date = try FileManager.default.attributesOfItem(atPath:url.path)[.modificationDate] as! Date
        let handle = try FileHandle(forWritingTo:url);try handle.write(contentsOf:Data("changed!".utf8));try handle.close();try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:url.path)
        XCTAssertThrowsError(try reader.read(offset:0,length:5));XCTAssertThrowsError(try reader.find(ViewerNeedle(hex:"00"),from:0))
    }
    func testViewerRejectsReplacedAndRenamedSources() throws {
        let url = try file("source","old"),reader = try ViewerFile(url),saved = root.appendingPathComponent("saved")
        try FileManager.default.moveItem(at:url,to:saved);XCTAssertThrowsError(try reader.read(offset:0,length:3))
        try file("source","new");XCTAssertThrowsError(try reader.validate());XCTAssertEqual(try ViewerFile(url).read(offset:0,length:3).data,Data("new".utf8))
    }
    func testViewerRefusesLinksDirectoriesAndFIFOsWithoutBlocking() throws {
        let regular = try file("regular","data"),link = root.appendingPathComponent("link"),fifo = root.appendingPathComponent("pipe")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:regular);XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        for url in [link,fifo,root!] { XCTAssertThrowsError(try ViewerFile(url));XCTAssertThrowsError(try BinaryInspector.describe(url)) }
    }
    func testViewerSearchValidatesAfterProgressCallbacks() throws {
        let url = try file("race","needle followed by data"),reader = try ViewerFile(url)
        XCTAssertThrowsError(try reader.find(ViewerNeedle(text:"needle",encoding:.utf8),from:0,progress:{ _,_ in try? Data("changed".utf8).write(to:url) }))
        let source = try file("cancel-found","needle"),other = try ViewerFile(source),token = CancellationToken()
        XCTAssertThrowsError(try other.find(ViewerNeedle(text:"needle",encoding:.utf8),from:0,token:token,progress:{ _,_ in token.cancel() }))
    }
    func testViewerLongRepeatedNeedleFindsWithoutQuadraticScanning() throws {
        let needle = String(repeating:"a",count:8_000)+"b",reader = try ViewerFile(file("repeated",String(repeating:"a",count:140_000)+"b"))
        XCTAssertEqual(try reader.find(ViewerNeedle(text:needle,encoding:.utf8),from:0,wrap:false)?.offset,132_000)
        XCTAssertEqual(try reader.find(ViewerNeedle(text:needle,encoding:.utf8),from:reader.size,direction:.backward,wrap:false)?.offset,132_000)
    }
    func testViewerBinaryWindowOffsetsRemainAbsolute() throws {
        let url = root.appendingPathComponent("large");try Data((0..<150_000).map { UInt8($0%251) }).write(to:url)
        let reader = try ViewerFile(url),page = try reader.read(offset:100_000,length:4096)
        XCTAssertEqual(page.offset,100_000);XCTAssertEqual(page.end,104_096);XCTAssertEqual(page.fileSize,150_000);XCTAssertEqual(page.data.first,UInt8(100_000%251))
    }
    func testViewerByteDisplayShowsAbsoluteOffsetsAndCrossLineHighlights() throws {
        let url = root.appendingPathComponent("binary");try Data(0...200).write(to:url)
        let reader = try ViewerFile(url),window = try reader.read(offset:100,length:32),display = try ViewerByteDisplay(window),match = try reader.find(ViewerNeedle(bytes:Data(115...119)),from:0)!
        XCTAssertTrue(display.text.hasPrefix("000000000064  64 65"));let range = display.range(for:match)!
        let highlighted = (display.text as NSString).substring(with:range);XCTAssertTrue(highlighted.contains("73"));XCTAssertTrue(highlighted.contains("\n"));XCTAssertTrue(highlighted.hasSuffix("77"))
        let binary = try ViewerByteDisplay(window,binary:true);XCTAssertTrue(binary.text.contains("01100100"));XCTAssertNotNil(binary.range(for:match))
    }
    func testViewerByteDisplayEnforcesSmallPagesAndCancellation() throws {
        let reader = try ViewerFile(file("large",String(repeating:"a",count:20_000))),large = try reader.read(offset:0,length:16*1024+1)
        XCTAssertThrowsError(try ViewerByteDisplay(large));XCTAssertThrowsError(try ViewerByteDisplay(large,binary:true))
        let match = try reader.find(ViewerNeedle(bytes:Data(repeating:0x61,count:5000)),from:0)!,display = try ViewerByteDisplay(reader.read(offset:0,length:4096))
        XCTAssertNotNil(display.range(for:match));XCTAssertTrue(display.range(for:match)!.length <= display.text.utf16.count)
        let token = CancellationToken();token.cancel();XCTAssertThrowsError(try ViewerByteDisplay(reader.read(offset:0,length:1),token:token))
    }
    func testViewerTextSearchKeepsUTF16CodeUnitAlignment() throws {
        let url = root.appendingPathComponent("alignment");try Data([0x00,0x41,0x00,0x42,0x41,0x00]).write(to:url)
        let reader = try ViewerFile(url),text = try ViewerNeedle(text:"A",encoding:.utf16LE),hex = try ViewerNeedle(hex:"41 00")
        XCTAssertEqual(try reader.find(text,from:0,wrap:false)?.offset,4)
        XCTAssertEqual(try reader.find(text,from:4,direction:.backward,wrap:false),nil)
        XCTAssertEqual(try reader.find(hex,from:0,wrap:false)?.offset,1)
    }
}
