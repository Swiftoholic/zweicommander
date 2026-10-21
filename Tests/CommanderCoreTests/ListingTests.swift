import Foundation
import CommanderCore

extension CoreTests {
    func testListingBatchesPreserveMetadataAndHiddenRules() throws {
        let directory = try folder("items")
        for index in 0..<320 { try file("items/File \(index).txt","payload") }
        try file("items/.hidden");try folder("items/Folder")
        try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("Link"),withDestinationURL:directory.appendingPathComponent("Folder"))
        var batches: [[FileEntry]] = []
        let entries = try FileSystem.list(directory,showHidden:false,onBatch:{ batches.append($0) })
        XCTAssertEqual(entries.count,322);XCTAssertEqual(batches.first?.count,100)
        XCTAssertEqual(batches.flatMap { $0 },entries)
        for entry in entries { XCTAssertEqual(entry,try FileEntry(url:entry.url)) }
        XCTAssertFalse(entries.contains { $0.name == ".hidden" })
        XCTAssertEqual(try FileSystem.list(directory,showHidden:true).count,323)
    }
    func testListingCancellationStopsAfterPublishedBatch() throws {
        let directory = try folder("items"),token = CancellationToken()
        for index in 0..<300 { try file("items/\(index).txt") }
        var received = 0
        XCTAssertThrowsError(try FileSystem.list(directory,showHidden:true,token:token,onBatch:{ received += $0.count;token.cancel() }))
        XCTAssertEqual(received,100)
        let cancelled = CancellationToken();cancelled.cancel()
        XCTAssertThrowsError(try FileSystem.list(directory,showHidden:true,token:cancelled))
        XCTAssertThrowsError(try FileSystem.list(directory.appendingPathComponent("missing"),showHidden:true))
    }
    func testEditedSingleNameRetainsOriginalVersionAndLiteralText() throws {
        let source = try file("first.txt","keep"),snapshot = RenameItem(source:source,target:source)
        let literal = try snapshot.renaming(to:"Grüße {name}.txt")
        XCTAssertEqual(literal.target.lastPathComponent,"Grüße {name}.txt")
        try RenameEngine.apply([literal]);XCTAssertEqual(try read(literal.target),"keep")
        try RenameEngine.apply(RenameEngine.reversed([literal]));XCTAssertEqual(try read(source),"keep")
        let stale = RenameItem(source:source,target:source)
        try Data("changed".utf8).write(to:source)
        XCTAssertThrowsError(try RenameEngine.apply([stale.renaming(to:"next.txt")]))
        XCTAssertEqual(try read(source),"changed")
        XCTAssertThrowsError(try stale.renaming(to:"../escape.txt"))
        XCTAssertThrowsError(try stale.renaming(to:""))
    }
}
