import Foundation
import Darwin
import CArchive
import CommanderCore

extension CoreTests {
    private func editFixture(_ format:ArchiveFormat = .zip) throws -> URL {
        let directory = try folder("Content/Docs")
        try file("Content/Docs/Keep.txt","keep\nUnicode Grüße 😀")
        try file("Content/Docs/Old.txt","rename this")
        try file("Content/Docs/Remove.txt","remove this")
        let archive = root.appendingPathComponent("Original."+format.fileExtension)
        try ArchiveService.pack([directory],to:archive,tarGzip:format == .tarGzip,sevenZip:format == .sevenZip)
        return archive
    }
    private func contents(_ archive:URL) throws -> [String:Data] { let files = Set(try ArchiveCatalog.read(archive).members.filter { $0.isRegularFile }.map(\.path));return Dictionary(uniqueKeysWithValues:try ArchiveService.readMembers(archive,matching:files.contains)) }
    private func editTemporaryFiles(_ folder:URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath:folder.path).filter { $0.hasPrefix(".zweicommander-archive-edit-") } }
    func testArchiveEditThreeFormatsPreserveContentsAndBackup() throws {
        for format in ArchiveFormat.allCases {
            let archive = try editFixture(format),before = try Data(contentsOf:archive),added = try file("Added/Extra.txt","added bytes")
            let plan = try ArchiveEditPlan(source:archive,renames:["Docs/Old.txt":"Docs/Renamed.txt"],removals:["Docs/Remove.txt"],additions:[ArchiveEditAddition(source:added,path:"New/Extra.txt")])
            XCTAssertEqual(plan.format,format);XCTAssertEqual(plan.rows.filter { $0.action == .remove }.count,1)
            let report = ArchiveEditEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:" · "));XCTAssertEqual(report.undo.count,1)
            let after = try contents(archive)
            XCTAssertEqual(after["Docs/Keep.txt"],Data("keep\nUnicode Grüße 😀".utf8));XCTAssertEqual(after["Docs/Renamed.txt"],Data("rename this".utf8))
            XCTAssertEqual(after["New/Extra.txt"],Data("added bytes".utf8));XCTAssertTrue(after["Docs/Remove.txt"] == nil);XCTAssertTrue(after["Docs/Old.txt"] == nil)
            if let backup = report.undo.first?.backup { XCTAssertEqual(try Data(contentsOf:backup),before) }
            XCTAssertTrue(try editTemporaryFiles(root).isEmpty)
            try FileManager.default.removeItem(at:archive)
        }
    }
    func testArchiveEditNoChangesNeverReplacesOriginal() throws {
        let archive = try editFixture(),before = try Data(contentsOf:archive),plan = try ArchiveEditPlan(source:archive)
        XCTAssertFalse(plan.hasChanges);XCTAssertTrue(plan.rows.allSatisfy{$0.action == .keep})
        XCTAssertFalse(ArchiveEditEngine.execute(plan).errors.isEmpty);XCTAssertEqual(try Data(contentsOf:archive),before)
    }
    func testArchiveEditDirectoryRenameChildOverrideAndRemoval() throws {
        let archive = try editFixture(),plan = try ArchiveEditPlan(source:archive,renames:["Docs":"Manual","Docs/Old.txt":"Manual/Specific.txt"],removals:["Docs/Remove.txt"])
        let report = ArchiveEditEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:" · "))
        let output = try contents(archive);XCTAssertEqual(Set(output.keys),Set(["Manual/Keep.txt","Manual/Specific.txt"]))
    }
    func testArchiveEditNameSwapHasNoIntermediateCollision() throws {
        let archive = try editFixture(),plan = try ArchiveEditPlan(source:archive,renames:["Docs/Keep.txt":"Docs/Old.txt","Docs/Old.txt":"Docs/Keep.txt"])
        XCTAssertTrue(ArchiveEditEngine.execute(plan).errors.isEmpty)
        let output = try contents(archive);XCTAssertEqual(output["Docs/Keep.txt"],Data("rename this".utf8));XCTAssertEqual(output["Docs/Old.txt"],Data("keep\nUnicode Grüße 😀".utf8))
    }
    func testArchiveEditFolderAdditionMergesDirectoryOnly() throws {
        let archive = try editFixture(),directory = try folder("Added/Docs");try file("Added/Docs/New.txt","new");try file("Added/Docs/.Hidden","hidden")
        let plan = try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:directory,path:"Docs")])
        XCTAssertEqual(plan.rows.filter{$0.path == "Docs" && $0.action != .remove}.count,1)
        let report = ArchiveEditEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:" · "))
        let output = try contents(archive);XCTAssertEqual(output["Docs/New.txt"],Data("new".utf8));XCTAssertEqual(output["Docs/.Hidden"],Data("hidden".utf8))
    }
    func testArchiveEditCollisionsAndFileParentsAreRejected() throws {
        let archive = try editFixture(),added = try file("Added/Other.txt")
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,renames:["Docs/Old.txt":"Docs/keep.txt"]))
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,renames:["Docs/Old.txt":"Docs/Keep.txt/child"]))
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:added,path:"Docs/Keep.txt")]))
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,renames:["Missing":"Other"]))
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,renames:["Docs":"Docs/Child"]))
    }
    func testArchiveEditCanReplaceExplicitlyRemovedMember() throws {
        let archive = try editFixture(),added = try file("Added/Other.txt","replacement")
        let plan = try ArchiveEditPlan(source:archive,removals:["Docs/Keep.txt"],additions:[ArchiveEditAddition(source:added,path:"Docs/Keep.txt")])
        XCTAssertTrue(ArchiveEditEngine.execute(plan).errors.isEmpty)
        XCTAssertEqual(try contents(archive)["Docs/Keep.txt"],Data("replacement".utf8))
    }
    func testArchiveEditUnsafePathsAndRemoteInputsAreRejected() throws {
        let archive = try editFixture(),added = try file("Added/Other.txt")
        for path in ["", "../outside", "/absolute", "C:/drive", "a\\b", "a//b", "a/./b", "a\0b"] {
            XCTAssertThrowsError(try ArchiveEditPlan(source:archive,renames:["Docs/Old.txt":path]))
            XCTAssertThrowsError(try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:added,path:path)]))
        }
        XCTAssertThrowsError(try ArchiveEditPlan(source:URL(string:"file://foreign.invalid/a.zip")!))
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:URL(string:"ftp://example.invalid/file")!,path:"Other")]))
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:archive,path:"Self.zip")]))
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:archive.deletingLastPathComponent(),path:"Containing")]))
    }
    func testArchiveEditRejectsLinksAndSpecialAdditions() throws {
        let archive = try editFixture(),added = try file("Added/Other.txt"),link = root.appendingPathComponent("Link.txt"),fifo = root.appendingPathComponent("Pipe")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:added);XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:link,path:"Link")]))
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:fifo,path:"Pipe")]))
        let archiveLink = root.appendingPathComponent("Link.zip");try FileManager.default.createSymbolicLink(at:archiveLink,withDestinationURL:archive)
        XCTAssertThrowsError(try ArchiveEditPlan(source:archiveLink))
    }
    func testArchiveEditChangedArchiveAndAddedSourceBlockExecution() throws {
        let archive = try editFixture(),added = try file("Added/Other.txt","first"),plan = try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:added,path:"Other")])
        try Data("later".utf8).write(to:added);let before = try Data(contentsOf:archive)
        XCTAssertFalse(ArchiveEditEngine.execute(plan).errors.isEmpty);XCTAssertEqual(try Data(contentsOf:archive),before)
        let other = try ArchiveEditPlan(source:archive,removals:["Docs/Old.txt"])
        try Data("foreign archive bytes".utf8).write(to:archive)
        XCTAssertFalse(ArchiveEditEngine.execute(other).errors.isEmpty);XCTAssertEqual(try Data(contentsOf:archive),Data("foreign archive bytes".utf8))
        XCTAssertTrue(try editTemporaryFiles(root).isEmpty)
    }
    func testArchiveEditParentReplacementCannotWriteOutsideReviewedRoot() throws {
        let parent = try folder("Parent"),archive = parent.appendingPathComponent("Original.zip"),input = try file("Input.txt")
        try ArchiveService.pack([input],to:archive);let plan = try ArchiveEditPlan(source:archive,renames:["Input.txt":"Changed.txt"])
        let moved = root.appendingPathComponent("Moved"),outside = try folder("Outside"),foreign = try file("Outside/Original.zip","outside")
        try FileManager.default.moveItem(at:parent,to:moved);try FileManager.default.createSymbolicLink(at:parent,withDestinationURL:outside)
        XCTAssertFalse(ArchiveEditEngine.execute(plan).errors.isEmpty);XCTAssertEqual(try read(foreign),"outside");XCTAssertTrue(try editTemporaryFiles(outside).isEmpty)
    }
    func testArchiveEditAddedParentReplacementIsRejected() throws {
        let archive = try editFixture(),added = try file("Added/Other.txt","first"),plan = try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:added,path:"Other")]),before = try Data(contentsOf:archive)
        let moved = root.appendingPathComponent("Moved"),outside = try folder("Outside");try file("Outside/Other.txt","outside")
        try FileManager.default.moveItem(at:added.deletingLastPathComponent(),to:moved);try FileManager.default.createSymbolicLink(at:added.deletingLastPathComponent(),withDestinationURL:outside)
        XCTAssertFalse(ArchiveEditEngine.execute(plan).errors.isEmpty);XCTAssertEqual(try Data(contentsOf:archive),before)
    }
    func testArchiveEditCancellationBeforeAndDuringRewritePreservesOriginal() throws {
        let archive = try editFixture(),before = try Data(contentsOf:archive),plan = try ArchiveEditPlan(source:archive,removals:["Docs/Old.txt"]),early = CancellationToken();early.cancel()
        XCTAssertFalse(ArchiveEditEngine.execute(plan,token:early).errors.isEmpty)
        for phase in ["Schreibe ·", "Prüfe Inhalt ·", "Übernehme geprüftes"] {
            let token = CancellationToken();let report = ArchiveEditEngine.execute(plan,token:token,progress:{ if $0.hasPrefix(phase) { token.cancel() } })
            XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try Data(contentsOf:archive),before);XCTAssertTrue(try editTemporaryFiles(root).isEmpty)
        }
    }
    func testArchiveEditLateForeignWriteIsNotOverwritten() throws {
        let archive = try editFixture(),plan = try ArchiveEditPlan(source:archive,removals:["Docs/Old.txt"])
        let foreign = Data("later foreign data".utf8)
        let report = ArchiveEditEngine.execute(plan,progress:{ if $0.hasPrefix("Übernehme geprüftes") { try? foreign.write(to:archive) } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try Data(contentsOf:archive),foreign);XCTAssertTrue(try editTemporaryFiles(root).isEmpty)
    }
    func testArchiveEditByteBudgetRejectsWorkBeforeMutation() throws {
        let archive = try editFixture(),before = try Data(contentsOf:archive)
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,maximumBytes:2))
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,removals:["Docs"],maximumBytes:2))
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,compressionLevel:10));XCTAssertEqual(try Data(contentsOf:archive),before)
    }
    func testArchiveEditZeroMemberResultIsValidZip() throws {
        let archive = try editFixture(),plan = try ArchiveEditPlan(source:archive,removals:["Docs"])
        let report = ArchiveEditEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:" · "));XCTAssertTrue(try ArchiveCatalog.read(archive).members.isEmpty)
    }
    func testArchiveEditUndoRestoresExactOriginalAndRejectsChangedResult() throws {
        let archive = try editFixture(),before = try Data(contentsOf:archive),plan = try ArchiveEditPlan(source:archive,removals:["Docs/Old.txt"]),report = ArchiveEditEngine.execute(plan)
        XCTAssertTrue(report.errors.isEmpty);XCTAssertTrue(FileOperations.undo(report.undo).isEmpty);XCTAssertEqual(try Data(contentsOf:archive),before)
        let second = ArchiveEditEngine.execute(try ArchiveEditPlan(source:archive,removals:["Docs/Old.txt"]))
        try Data("foreign".utf8).write(to:archive);XCTAssertFalse(FileOperations.undo(second.undo).isEmpty);XCTAssertEqual(try read(archive),"foreign")
        if let backup = second.undo.first?.backup { XCTAssertEqual(try Data(contentsOf:backup),before) }
    }
    func testArchiveEditZipCommentsAndUnrepresentedExtrasAreRejected() throws {
        let archive = try editFixture();var bytes = try Data(contentsOf:archive)
        bytes[bytes.count-2] = 4;bytes[bytes.count-1] = 0;bytes.append(Data("note".utf8));try bytes.write(to:archive)
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive));XCTAssertEqual(try Data(contentsOf:archive),bytes)
    }
    func testArchiveEditMismatchedAndUnsupportedFormatsAreRejected() throws {
        let archive = try editFixture(),renamed = root.appendingPathComponent("Wrong.7z");try FileManager.default.copyItem(at:archive,to:renamed)
        XCTAssertThrowsError(try ArchiveEditPlan(source:renamed))
        let raw = root.appendingPathComponent("Plain.tar"),input = try file("Input.txt");try ArchiveService.pack([input],to:raw)
        XCTAssertThrowsError(try ArchiveEditPlan(source:raw))
    }
    func testArchiveEditEncryptedZipIsRefusedWithoutRewriting() throws {
        let input = try file("Secret.txt","synthetic secret"),archive = root.appendingPathComponent("Encrypted.zip"),process = Process()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/zip");process.arguments = ["-j","-q","-P","synthetic-only",archive.path,input.path];try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        let before = try Data(contentsOf:archive);XCTAssertThrowsError(try ArchiveEditPlan(source:archive));XCTAssertEqual(try Data(contentsOf:archive),before)
    }
}

extension CoreTests {
    private func editCRC(_ bytes:[UInt8]) -> UInt32 {
        var crc:UInt32 = 0xFFFFFFFF
        for byte in bytes { crc ^= UInt32(byte);for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1)^0xEDB88320 } };return crc^0xFFFFFFFF
    }
    private func editLittle(_ number:UInt64,_ count:Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded:number >> (8*$0)) } }
    private func editTiny7z(property:UInt8,value:[UInt8]) throws -> URL {
        let name = [UInt8(0)]+Array("Empty.txt\0".utf16).flatMap { editLittle(UInt64($0),2) }
        let header:[UInt8] = [1,5,1,14,1,128,15,1,128,17,UInt8(name.count)]+name+[property,UInt8(value.count)]+value+[0,0]
        let start = editLittle(0,8)+editLittle(UInt64(header.count),8)+editLittle(UInt64(editCRC(header)),4)
        let bytes:[UInt8] = [0x37,0x7A,0xBC,0xAF,0x27,0x1C,0,3]+editLittle(UInt64(editCRC(start)),4)+start+header
        let url = root.appendingPathComponent("Extra.7z");try Data(bytes).write(to:url);return url
    }
    func testArchiveEditSevenZipOpaqueCommentCannotBeDropped() throws {
        let archive = try editTiny7z(property:22,value:[0,110,111,116,101]),before = try Data(contentsOf:archive)
        XCTAssertEqual(try ArchiveCatalog.read(archive).members.first?.path,"Empty.txt")
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,removals:["Empty.txt"]))
        XCTAssertEqual(try Data(contentsOf:archive),before)
    }
    func testArchiveEditSevenZipOpaqueFileAttributesCannotBeDropped() throws {
        let archive = try editTiny7z(property:21,value:[1,0,2,0,0,0]),before = try Data(contentsOf:archive)
        XCTAssertEqual(try ArchiveCatalog.read(archive).members.count,1)
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,removals:["Empty.txt"]));XCTAssertEqual(try Data(contentsOf:archive),before)
    }
    func testArchiveEditSevenZipEncodedHeaderMemoryIsBounded() throws {
        let archive = try editFixture(.sevenZip);var bytes = [UInt8](try Data(contentsOf:archive))
        let offset = bytes[12..<20].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8*$1.offset) },start = 32+Int(offset)
        let signature:[UInt8] = [0x23,3,1,1,5,0x5D]
        let positions = (start..<(bytes.count-signature.count-4)).filter { Array(bytes[$0..<$0+signature.count]) == signature }
        XCTAssertEqual(positions.count,1)
        if let position = positions.first {
            bytes.replaceSubrange(position+6..<position+10,with:[0,0,0,0x40])
            bytes.replaceSubrange(28..<32,with:editLittle(UInt64(editCRC(Array(bytes[start...]))),4))
            bytes.replaceSubrange(8..<12,with:editLittle(UInt64(editCRC(Array(bytes[12..<32]))),4))
            try Data(bytes).write(to:archive);XCTAssertThrowsError(try ArchiveEditPlan(source:archive));XCTAssertEqual(try Data(contentsOf:archive),Data(bytes))
        }
    }
    func testArchiveEditZipUnknownLocalExtraIsRefused() throws {
        let archive = try editFixture();var data = [UInt8](try Data(contentsOf:archive))
        let name = Int(data[26]) | Int(data[27])<<8,extra = Int(data[28]) | Int(data[29])<<8
        XCTAssertTrue(extra >= 4)
        if extra >= 4 { data[30+name] = 0x34;data[31+name] = 0x12;try Data(data).write(to:archive) }
        XCTAssertEqual(try ArchiveCatalog.read(archive).members.count,4)
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive));XCTAssertEqual(try Data(contentsOf:archive),Data(data))
    }
    private func editPaxArchive(key:String) throws -> URL {
        func tarHeader(_ name:String,_ type:UInt8,_ size:Int) -> [UInt8] {
            var bytes = [UInt8](repeating:0,count:512)
            func put(_ value:String,_ start:Int,_ count:Int) { for (index,byte) in value.utf8.prefix(count).enumerated() { bytes[start+index] = byte } }
            put(name,0,100);put("0000644\0",100,8);put("0000000\0",108,8);put("0000000\0",116,8)
            put(String(format:"%011o",size)+"\0",124,12);put("00000000000\0",136,12);put("        ",148,8);bytes[156] = type;put("ustar\0",257,6);put("00",263,2)
            let sum = bytes.reduce(0) { $0+Int($1) };put(String(format:"%06o",sum)+"\0 ",148,8);return bytes
        }
        let record = " "+key+"=note\n";var length = record.utf8.count+1
        while length != String(length).utf8.count+record.utf8.count { length = String(length).utf8.count+record.utf8.count }
        let payload = Array((String(length)+record).utf8)
        let tar = tarHeader("PaxHeader",120,payload.count)+payload+Array(repeating:UInt8(0),count:(512-payload.count%512)%512)+tarHeader("Empty.txt",48,0)+Array(repeating:UInt8(0),count:1024)
        let plain = root.appendingPathComponent("Input.tar"),archive = root.appendingPathComponent("Pax.tar.gz");try Data(tar).write(to:plain)
        let process = Process(),pipe = Pipe();process.executableURL = URL(fileURLWithPath:"/usr/bin/gzip");process.arguments = ["-n","-c",plain.path];process.standardOutput = pipe;try process.run();let compressed = pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0);try compressed.write(to:archive);return archive
    }
    func testArchiveEditTarUnknownPaxMetadataIsRefused() throws {
        let archive = try editPaxArchive(key:"comment"),before = try Data(contentsOf:archive)
        XCTAssertEqual(try ArchiveCatalog.read(archive).members.count,1)
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,removals:["Empty.txt"]));XCTAssertEqual(try Data(contentsOf:archive),before)
    }
    func testArchiveEditTarKnownPaxPathsRoundTrip() throws {
        let archive = try editPaxArchive(key:"path")
        let catalog = try ArchiveCatalog.read(archive);XCTAssertEqual(catalog.members.first?.path,"note")
        let plan = try ArchiveEditPlan(source:archive,renames:["note":"Renamed.txt"]),report = ArchiveEditEngine.execute(plan)
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:" · "));XCTAssertEqual(try ArchiveCatalog.read(archive).members.first?.path,"Renamed.txt")
    }
}

extension CoreTests {
    func testArchiveEditSameInodeStageMutationNeverPublishes() throws {
        let archive = try editFixture(),before = try Data(contentsOf:archive),plan = try ArchiveEditPlan(source:archive,removals:["Docs/Old.txt"])
        var injected = false
        let report = ArchiveEditEngine.execute(plan,progress:{ text in
            if text.hasPrefix("Übernehme geprüftes"),let stage = try? FileManager.default.contentsOfDirectory(at:archive.deletingLastPathComponent(),includingPropertiesForKeys:nil).first(where:{$0.lastPathComponent.hasPrefix(".zweicommander-archive-edit-")}) {
                // FileHandle truncates the already-owned inode, rather than atomically replacing it.
                if let handle = try? FileHandle(forWritingTo:stage) { try? handle.seek(toOffset:0);try? handle.write(contentsOf:Data("tampered".utf8));try? handle.close();injected = true }
            }
        })
        XCTAssertTrue(injected);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.undo.isEmpty)
        XCTAssertEqual(try Data(contentsOf:archive),before);XCTAssertTrue(try editTemporaryFiles(root).isEmpty)
    }
    func testArchiveEditPostPublicationChangeRetainsRecoveryReceipt() throws {
        let archive = try editFixture(),before = try Data(contentsOf:archive),plan = try ArchiveEditPlan(source:archive,removals:["Docs/Old.txt"]),foreign = Data("subsequent foreign content".utf8)
        let report = ArchiveEditEngine.execute(plan,progress:{ if $0 == "Prüfe übernommenes Archiv" { try? foreign.write(to:archive) } })
        XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.undo.count,1)
        if let backup = report.undo.first?.backup { XCTAssertEqual(try Data(contentsOf:backup),before) }
        XCTAssertFalse(FileOperations.undo(report.undo).isEmpty);XCTAssertEqual(try Data(contentsOf:archive),foreign)
    }
    func testArchiveEditTenThousandSiblingSourcesStayLinear() throws {
        let archive = try editFixture(),directory = try folder("Many")
        for index in 0..<10_000 { try FileManager.default.createDirectory(at:directory.appendingPathComponent("Dir\(index)"),withIntermediateDirectories:false) }
        var before = rusage(),after = rusage();_ = getrusage(RUSAGE_SELF,&before)
        let plan = try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:directory,path:"Many")])
        try plan.validate();_ = getrusage(RUSAGE_SELF,&after)
        XCTAssertEqual(plan.rows.filter{$0.action == .add}.count,10_001)
        // Darwin reports max RSS in bytes. The old copied sibling maps needed gigabytes here.
        XCTAssertTrue(after.ru_maxrss-before.ru_maxrss < 192*1024*1024,"Sibling inventory exceeded a linear memory budget")
    }
    func testArchiveEditRejectsDeepAdditionDuringTraversal() throws {
        let archive = try editFixture(),before = try Data(contentsOf:archive),directory = try folder("Deep")
        var child = directory
        for _ in 0..<120 { child.appendPathComponent("d");try FileManager.default.createDirectory(at:child,withIntermediateDirectories:false) }
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive,additions:[ArchiveEditAddition(source:directory,path:"Deep")]))
        XCTAssertEqual(try Data(contentsOf:archive),before)
    }
    func testArchiveEditPlainSevenZipMainDictionaryIsBoundedBeforeDecoding() throws {
        // A plain next header advertises one main LZMA2 stream with a 1 GiB dictionary.
        let packed:[UInt8] = [1,0,3,115,97,102,101,0]
        let name:[UInt8] = [0]+Array("File.txt\0".utf16).flatMap { editLittle(UInt64($0),2) }
        func fixture(_ dictionary:UInt8) -> Data {
            let streams:[UInt8] = [6,0,1,9,8,0,7,11,1,0,1,0x21,0x21,1,dictionary,12,4,0,8,0,0]
            let header:[UInt8] = [1,4]+streams+[5,1,17,UInt8(name.count)]+name+[0,0]
            let start = editLittle(UInt64(packed.count),8)+editLittle(UInt64(header.count),8)+editLittle(UInt64(editCRC(header)),4)
            return Data([UInt8](arrayLiteral:0x37,0x7A,0xBC,0xAF,0x27,0x1C,0,3)+editLittle(UInt64(editCRC(start)),4)+start+packed+header)
        }
        let data = fixture(36),archive = root.appendingPathComponent("MainDictionary.7z");try data.write(to:archive)
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive));XCTAssertEqual(try Data(contentsOf:archive),data)
        // The identical independently encoded main stream is readable with a supported dictionary.
        try fixture(0).write(to:archive)
        let supported = try ArchiveEditPlan(source:archive)
        XCTAssertEqual(supported.rows.first?.path,"File.txt");XCTAssertEqual(supported.rows.first?.member.size,4)

    }
    private func editZipWithExtra(_ extra:[UInt8]) throws -> URL {
        let name = Array("Input.txt".utf8),body = Array("safe".utf8),crc = UInt64(editCRC(body))
        let local:[UInt8] = [0x50,0x4B,3,4]+editLittle(20,2)+Array(repeating:0,count:8)+editLittle(crc,4)+editLittle(UInt64(body.count),4)+editLittle(UInt64(body.count),4)+editLittle(UInt64(name.count),2)+editLittle(UInt64(extra.count),2)+name+extra+body
        let central:[UInt8] = [0x50,0x4B,1,2]+editLittle(0x0314,2)+editLittle(20,2)+Array(repeating:0,count:8)+editLittle(crc,4)+editLittle(UInt64(body.count),4)+editLittle(UInt64(body.count),4)+editLittle(UInt64(name.count),2)+Array(repeating:0,count:8)+editLittle(UInt64(0o100644)<<16,4)+editLittle(0,4)+name
        let end:[UInt8] = [0x50,0x4B,5,6]+Array(repeating:0,count:4)+editLittle(1,2)+editLittle(1,2)+editLittle(UInt64(central.count),4)+editLittle(UInt64(local.count),4)+[0,0]
        let archive = root.appendingPathComponent("Extra.zip");try Data(local+central+end).write(to:archive);return archive
    }
    func testArchiveEditKnownZipTimestampExtraCannotHideOpaqueTail() throws {
        let extra:[UInt8] = [0x55,0x54,17,0,7,0,0xF1,0x53,0x65,1,0xF1,0x53,0x65,2,0xF1,0x53,0x65,0x4B,0x45,0x45,0x50]
        let archive = try editZipWithExtra(extra),before = try Data(contentsOf:archive)
        XCTAssertEqual(try ArchiveCatalog.read(archive).members.first?.path,"Input.txt")
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive));XCTAssertEqual(try Data(contentsOf:archive),before)
    }
    func testArchiveEditKnownZipUidExtraCannotHideOpaqueTail() throws {
        let extra:[UInt8] = [0x75,0x78,9,0,1,1,0,1,0,0x4B,0x45,0x45,0x50]
        let archive = try editZipWithExtra(extra),before = try Data(contentsOf:archive)
        XCTAssertEqual(try ArchiveCatalog.read(archive).members.first?.path,"Input.txt")
        XCTAssertThrowsError(try ArchiveEditPlan(source:archive));XCTAssertEqual(try Data(contentsOf:archive),before)
    }
}

extension CoreTests {
    func testArchiveEditMutationDuringVerificationCannotAcquireFreshSeal() throws {
        let first = try file("Input/First.txt","ALPHA_PAYLOAD_TO_EDIT_1234"),second = try file("Input/Second.txt","BETA_PAYLOAD_TO_KEEP_6789"),archive = root.appendingPathComponent("DuringVerify.zip")
        try ArchiveService.pack([first,second],to:archive,compressionLevel:0)
        let original = try Data(contentsOf:archive)
        let plan = try ArchiveEditPlan(source:archive,renames:["First.txt":"Renamed.txt"],compressionLevel:0)
        var checked:[String] = [],injected = false,sameInode = false
        let report = ArchiveEditEngine.execute(plan,progress:{ text in
            guard text.hasPrefix("Prüfe Inhalt · ") else { return }
            checked.append(String(text.dropFirst("Prüfe Inhalt · ".count)))
            guard checked.count == 2,let stage = try? FileManager.default.contentsOfDirectory(at:archive.deletingLastPathComponent(),includingPropertiesForKeys:nil).first(where:{$0.lastPathComponent.hasPrefix(".zweicommander-archive-edit-")}),let data = try? Data(contentsOf:stage) else { return }
            let payload = Data((checked[0] == "Renamed.txt" ? "ALPHA_PAYLOAD_TO_EDIT_1234" : "BETA_PAYLOAD_TO_KEEP_6789").utf8)
            guard let range = data.range(of:payload),let handle = try? FileHandle(forWritingTo:stage) else { return }
            var before = stat(),after = stat();guard lstat(stage.path,&before) == 0 else { try? handle.close();return }
            do { try handle.seek(toOffset:UInt64(range.lowerBound));try handle.write(contentsOf:Data([0x58]));try handle.close();injected = true } catch { try? handle.close() }
            sameInode = lstat(stage.path,&after) == 0 && before.st_ino == after.st_ino && before.st_dev == after.st_dev
        })
        XCTAssertEqual(checked.count,2);XCTAssertTrue(injected);XCTAssertTrue(sameInode)
        XCTAssertFalse(report.errors.isEmpty,"A changed, previously verified payload must not receive a new trusted seal")
        XCTAssertEqual(try Data(contentsOf:archive),original);XCTAssertTrue(report.undo.isEmpty)
        XCTAssertTrue(try editTemporaryFiles(root).isEmpty)
    }
}

extension CoreTests {
    func testArchiveEditMetadataIsFinalBeforeVerificationSnapshot() throws {
        let input = try file("Input.txt","payload"),archive = root.appendingPathComponent("Metadata.zip"),date = Date(timeIntervalSince1970:1_600_000_000)
        try ArchiveService.pack([input],to:archive)
        try FileManager.default.setAttributes([.modificationDate:date,.posixPermissions:0o640],ofItemAtPath:archive.path)
        let plan = try ArchiveEditPlan(source:archive,renames:["Input.txt":"Renamed.txt"]);var metadataReady = false
        let report = ArchiveEditEngine.execute(plan,progress:{ text in
            guard text == "Prüfe vollständige Inhalte und Metadaten",let stage = try? FileManager.default.contentsOfDirectory(at:archive.deletingLastPathComponent(),includingPropertiesForKeys:nil).first(where:{$0.lastPathComponent.hasPrefix(".zweicommander-archive-edit-")}),let attributes = try? FileManager.default.attributesOfItem(atPath:stage.path) else { return }
            metadataReady = attributes[.modificationDate] as? Date == date && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640
        })
        XCTAssertTrue(metadataReady,"Own metadata changes must precede the frozen verification snapshot")
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:" · "))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:archive.path)[.modificationDate] as? Date,date)
    }
    func testArchiveEditPostPublicationParentMoveRetainsAccessibleRecovery() throws {
        let input = try file("Input.txt","payload")
        for (index,phase) in ["Prüfe übernommenes Archiv","Archivänderungen übernommen · Original gesichert"].enumerated() {
            let parent = try folder("Case\(index)/Parent"),moved = root.appendingPathComponent("Case\(index)/Moved"),outside = try folder("Case\(index)/Outside"),archive = parent.appendingPathComponent("Original.zip")
            let foreign = try file("Case\(index)/Outside/Original.zip","outside archive"),sentinel = try file("Case\(index)/Outside/Sentinel.txt","outside sentinel")
            try ArchiveService.pack([input],to:archive);let before = try Data(contentsOf:archive),plan = try ArchiveEditPlan(source:archive,renames:["Input.txt":"Renamed.txt"]);var injected = false
            let report = ArchiveEditEngine.execute(plan,progress:{ text in
                guard text == phase,!injected else { return }
                do { try FileManager.default.moveItem(at:parent,to:moved);try FileManager.default.createSymbolicLink(at:parent,withDestinationURL:outside);injected = true } catch { }
            })
            XCTAssertTrue(injected);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.undo.count,1)
            let current = moved.appendingPathComponent("Original.zip")
            XCTAssertEqual(report.completed.map { FileSystem.canonical($0).path },[FileSystem.canonical(current).path])
            if let step = report.undo.first,let backup = step.backup {
                XCTAssertEqual(FileSystem.canonical(step.current).path,FileSystem.canonical(current).path)
                XCTAssertEqual(FileSystem.canonical(backup.deletingLastPathComponent()).path,FileSystem.canonical(moved).path)
                XCTAssertEqual(try Data(contentsOf:backup),before)
                let history = try TransferHistory(journal:TransferJournal(directory:root.appendingPathComponent("Case\(index)/History")))
                try history.captureBackups(report.undo);let items = history.inspect();XCTAssertEqual(items.count,1);XCTAssertTrue(items.first?.available == true)
                if let item = items.first {
                    XCTAssertEqual(FileSystem.canonical(item.original).path,FileSystem.canonical(current).path)
                    try history.restore(history.planRestore(item.id));XCTAssertEqual(try Data(contentsOf:current),before)
                }
            }
            XCTAssertEqual(try read(foreign),"outside archive");XCTAssertEqual(try read(sentinel),"outside sentinel")
        }
    }
}
