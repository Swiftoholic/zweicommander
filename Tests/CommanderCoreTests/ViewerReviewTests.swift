import Foundation
import CommanderCore

extension CoreTests {
    func testViewerDisplayedSearchPreservesBackwardOverlappingHits() throws {
        XCTAssertEqual(try ViewerTextSearch.find(in:"ababa",text:"aba",from:0,wrap:false)?.range,NSRange(location:0,length:3))
        XCTAssertEqual(try ViewerTextSearch.find(in:"ababa",text:"aba",from:1,wrap:false)?.range,NSRange(location:2,length:3))
        XCTAssertEqual(try ViewerTextSearch.find(in:"ababa",text:"aba",from:2,direction:.backward,wrap:false)?.range,NSRange(location:0,length:3))
        XCTAssertEqual(try ViewerTextSearch.find(in:"ababa",text:"aba",from:0,direction:.backward,wrap:false),nil)
        let wrapped = try ViewerTextSearch.find(in:"ababa",text:"aba",from:0,direction:.backward)
        XCTAssertEqual(wrapped?.range,NSRange(location:2,length:3));XCTAssertEqual(wrapped?.wrapped,true)
    }
    func testViewerDisplayedSearchUsesUnicodePositionsAndRejectsInvalidRequests() throws {
        let text = "😀ababa終"
        XCTAssertEqual(try ViewerTextSearch.find(in:text,text:"aba",from:4,direction:.backward,wrap:false)?.range,NSRange(location:2,length:3))
        XCTAssertEqual(try ViewerTextSearch.find(in:text,text:"missing",from:0),nil)
        XCTAssertThrowsError(try ViewerTextSearch.find(in:text,text:"",from:0));XCTAssertThrowsError(try ViewerTextSearch.find(in:text,text:"a",from:-1))
        XCTAssertThrowsError(try ViewerTextSearch.find(in:String(repeating:"a",count:256*1024+1),text:"a",from:0))
        let token = CancellationToken();token.cancel()
        do { _ = try ViewerTextSearch.find(in:text,text:"aba",from:0,token:token);XCTAssertTrue(false,"Expected cancellation") }
        catch CommanderError.cancelled {} catch { XCTAssertTrue(false,"Cancellation must not become a search error") }
    }
    func testViewerInspectorCancellationPrecedesFileOpening() throws {
        let token = CancellationToken();token.cancel()
        do { _ = try BinaryInspector.describe(root.appendingPathComponent("unavailable"),token:token);XCTAssertTrue(false,"Expected cancellation") }
        catch CommanderError.cancelled {} catch { XCTAssertTrue(false,"A cancelled inspection must not open its source") }
    }
    func testViewerInspectorResourceReadCancellationPropagates() throws {
        let resourceSize = 1024*1024,rawOffset = 0x400,pe = 0x80,optional = pe+24,section = optional+240
        var data = Data(repeating:0,count:rawOffset+resourceSize)
        func put(_ offset:Int,_ value:UInt64,_ count:Int) { for index in 0..<count { data[offset+index] = UInt8(truncatingIfNeeded:value >> (index*8)) } }
        put(0,0x5A4D,2);put(0x3C,UInt64(pe),4);put(pe,0x4550,4);put(pe+4,0x8664,2);put(pe+6,1,2);put(pe+20,240,2);put(optional,0x20B,2)
        put(optional+112+16,0x1000,4);put(optional+112+20,UInt64(resourceSize),4)
        put(section+8,UInt64(resourceSize),4);put(section+12,0x1000,4);put(section+16,UInt64(resourceSize),4);put(section+20,UInt64(rawOffset),4)
        let url = root.appendingPathComponent("large-resource.exe");try data.write(to:url)
        let token = CancellationToken();var last:Int64 = 0
        do {
            _ = try BinaryInspector.describe(url,token:token,progress:{ last = $0;if $0 > 256*1024 { token.cancel() } })
            XCTAssertTrue(false,"Resource cancellation must propagate")
        } catch CommanderError.cancelled {} catch { XCTAssertTrue(false,"Cancellation must not become a partial-resource report") }
        XCTAssertTrue(last > 256*1024);XCTAssertTrue(last <= 320*1024)
        XCTAssertEqual(try Data(contentsOf:url),data)
    }
    func testViewerVersionResourceParserHonorsEarlyCancellation() throws {
        let token = CancellationToken();token.cancel()
        do { _ = try BinaryInspector.versionStrings(Data(),token:token);XCTAssertTrue(false,"Expected cancellation") }
        catch CommanderError.cancelled {} catch { XCTAssertTrue(false,"Cancellation must be checked before parsing malformed bytes") }
    }
}
