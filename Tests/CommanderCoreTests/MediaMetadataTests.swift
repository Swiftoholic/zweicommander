import Foundation
import CommanderCore
import ImageIO
import CoreGraphics
import Darwin

private func mediaInteger(_ number:UInt64,_ bytes:Int,little:Bool = false) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded:number >> ((little ? $0 : bytes-1-$0)*8)) }) }
private func mediaSynch(_ number:Int) -> Data { Data((0..<4).map { UInt8((number >> ((3-$0)*7)) & 127) }) }
private func mediaAtom(_ type:String,_ data:Data) -> Data { mediaInteger(UInt64(data.count+8),4)+(type.data(using:.isoLatin1)!)+data }
private func mediaID3(_ fields:[(String,Data)],version:UInt8 = 4) -> Data {
    let body = fields.reduce(into:Data()) { result,pair in result.append(Data(pair.0.utf8));result.append(version == 4 ? mediaSynch(pair.1.count) : mediaInteger(UInt64(pair.1.count),4));result.append(Data([0,0]));result.append(pair.1) }
    return Data([0x49,0x44,0x33,version,0,0])+mediaSynch(body.count)+body+Data(repeating:0,count:32)
}
private func mediaWAV(format:UInt64 = 1) -> Data {
    let fmt = mediaInteger(format,2,little:true)+mediaInteger(1,2,little:true)+mediaInteger(8000,4,little:true)+mediaInteger(16000,4,little:true)+mediaInteger(2,2,little:true)+mediaInteger(16,2,little:true)
    func chunk(_ name:String,_ value:Data) -> Data { Data(name.utf8)+mediaInteger(UInt64(value.count),4,little:true)+value+(value.count%2 == 1 ? Data([0]) : Data()) }
    let info = chunk("LIST",Data("INFO".utf8)+chunk("INAM",Data("Wellenname\0".utf8)))
    let body = Data("WAVE".utf8)+chunk("fmt ",fmt)+info+chunk("data",Data(repeating:0,count:32000))
    return Data("RIFF".utf8)+mediaInteger(UInt64(body.count),4,little:true)+body
}
private func mediaMovie(rotated:Bool = false,scale:UInt64 = 1000) -> Data {
    var mvhd = Data(repeating:0,count:12);mvhd.append(mediaInteger(scale,4));mvhd.append(mediaInteger(12500,4))
    var tkhd = Data(repeating:0,count:84)
    func replace(_ offset:Int,_ value:UInt64) { tkhd.replaceSubrange(offset..<(offset+4),with:mediaInteger(value,4)) }
    replace(40,rotated ? 0 : 65536);replace(44,rotated ? 65536 : 0);replace(52,rotated ? 0xFFFF0000 : 0);replace(56,rotated ? 0 : 65536);replace(72,0x40000000);replace(76,1920*65536);replace(80,1080*65536)
    let title = mediaAtom("©nam",mediaAtom("data",mediaInteger(1,4)+Data(repeating:0,count:4)+Data("Kleiner Film".utf8)))
    let track = mediaAtom("trkn",mediaAtom("data",Data(repeating:0,count:10)+mediaInteger(3,2)+Data(repeating:0,count:4)))
    return mediaAtom("ftyp",Data("isom0000".utf8))+mediaAtom("moov",mediaAtom("mvhd",mvhd)+mediaAtom("trak",mediaAtom("tkhd",tkhd))+mediaAtom("udta",mediaAtom("meta",Data(repeating:0,count:4)+mediaAtom("ilst",title+track))))
}

extension CoreTests {
    private func mediaFile(_ name:String,_ data:Data) throws -> URL { let url = root.appendingPathComponent(name);try data.write(to:url);return url }
    private func mediaImage(_ name:String = "Bild.jpg",exif:Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name),pixels = Data(repeating:180,count:3*2*4)
        let provider = CGDataProvider(data:pixels as CFData)!,image = CGImage(width:3,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:12,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let writer = CGImageDestinationCreateWithURL(url as CFURL,name.hasSuffix("png") ? "public.png" as CFString : "public.jpeg" as CFString,1,nil)!
        let properties:[CFString:Any] = exif ? [kCGImagePropertyExifDictionary:[kCGImagePropertyExifDateTimeOriginal:"2024:02:29 14:15:16"],kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFMake:"Testkamera",kCGImagePropertyTIFFModel:"Modell 2",kCGImagePropertyTIFFArtist:"Fotograf"]] : [:]
        CGImageDestinationAddImage(writer,image,properties as CFDictionary);guard CGImageDestinationFinalize(writer) else { throw CommanderError.message("Künstliches Testbild nicht erstellt.") };return url
    }
    func testMediaPNGDimensionsAndMissingTags() throws { let value = try MediaMetadataReader.read(mediaImage("Bild.png"));XCTAssertEqual(value.width,3);XCTAssertEqual(value.height,2);XCTAssertEqual(value.duration,nil);XCTAssertEqual(value.title,nil) }
    func testMediaJPEGEXIFAndCamera() throws { let value = try MediaMetadataReader.read(mediaImage(exif:true));XCTAssertEqual(value.width,3);XCTAssertEqual(value.year,2024);XCTAssertNotNil(value.taken);XCTAssertEqual(value.artist,"Fotograf");XCTAssertTrue(value.camera?.contains("Modell 2") == true) }
    func testMediaID3UTF8FieldsAndDeclaredDuration() throws {
        let fields = [("TIT2","Titel 😀"),("TPE1","Artist"),("TALB","Album"),("TDRC","2025-05-01"),("TRCK","4/12"),("TLEN","123456")].map { ($0.0,Data([3])+Data($0.1.utf8)) }
        let value = try MediaMetadataReader.read(mediaFile("Musik.mp3",mediaID3(fields)));XCTAssertEqual(value.title,"Titel 😀");XCTAssertEqual(value.artist,"Artist");XCTAssertEqual(value.album,"Album");XCTAssertEqual(value.year,2025);XCTAssertEqual(value.track,4);XCTAssertEqual(value.duration,123.456)
    }
    func testMediaID3UTF16AndVersion3() throws { let bytes = Data([1,0xFF,0xFE])+"Grüße".data(using:.utf16LittleEndian)!;let value = try MediaMetadataReader.read(mediaFile("UTF16.mp3",mediaID3([("TIT2",bytes)],version:3)));XCTAssertEqual(value.title,"Grüße") }
    func testMediaID3v1AndNoInventedDuration() throws {
        var bytes = Data(repeating:0,count:256);bytes.replaceSubrange(128..<131,with:Data("TAG".utf8));bytes.replaceSubrange(131..<135,with:Data("Lied".utf8));bytes[253] = 0;bytes[254] = 2
        let value = try MediaMetadataReader.read(mediaFile("Alt.mp3",bytes));XCTAssertEqual(value.title,"Lied");XCTAssertEqual(value.track,2);XCTAssertEqual(value.duration,nil)
    }
    func testMediaID3InvalidSynchsafeSizeRejected() throws { var bytes = mediaID3([]);bytes[6] = 0x80;XCTAssertThrowsError(try MediaMetadataReader.read(mediaFile("Ungueltig.mp3",bytes))) }
    func testMediaID3TruncatedFrameRejected() throws { var bytes = mediaID3([("TIT2",Data([3])+Data("Text".utf8))]);bytes[17] = 100;XCTAssertThrowsError(try MediaMetadataReader.read(mediaFile("Kurz.mp3",bytes))) }
    func testMediaID3InvalidUTF8IsUnavailable() throws { let value = try MediaMetadataReader.read(mediaFile("Fehler.mp3",mediaID3([("TIT2",Data([3,0xFF,0xFF]))])));XCTAssertEqual(value.title,nil) }
    func testMediaID3CompressedTextIsNotMisread() throws { var bytes = mediaID3([("TIT2",Data([3])+Data("Text".utf8))]);bytes[19] = 8;let value = try MediaMetadataReader.read(mediaFile("Komprimiert.mp3",bytes));XCTAssertEqual(value.title,nil);XCTAssertFalse(value.notes.isEmpty);bytes[19] = 0x80;XCTAssertEqual(try MediaMetadataReader.read(mediaFile("ReservierterRahmen.mp3",bytes)).title,nil) }
    func testMediaWAVDurationAndInfo() throws { let value = try MediaMetadataReader.read(mediaFile("Ton.wav",mediaWAV()));XCTAssertEqual(value.duration,2);XCTAssertEqual(value.title,"Wellenname") }
    func testMediaWAVUnsupportedCodecHasNoInventedDuration() throws { let value = try MediaMetadataReader.read(mediaFile("Codec.wav",mediaWAV(format:17)));XCTAssertEqual(value.duration,nil) }
    func testMediaWAVOutOfBoundsChunkRejected() throws { var bytes = mediaWAV();bytes.replaceSubrange(16..<20,with:Data(repeating:0xFF,count:4));XCTAssertThrowsError(try MediaMetadataReader.read(mediaFile("Defekt.wav",bytes))) }
    func testMediaMP4DurationDimensionsAndITunesTags() throws { let value = try MediaMetadataReader.read(mediaFile("Film.mp4",mediaMovie()));XCTAssertEqual(value.duration,12.5);XCTAssertEqual(value.width,1920);XCTAssertEqual(value.height,1080);XCTAssertEqual(value.title,"Kleiner Film");XCTAssertEqual(value.track,3) }
    func testMediaMP4RotatedDimensions() throws { let value = try MediaMetadataReader.read(mediaFile("Hochkant.mov",mediaMovie(rotated:true)));XCTAssertEqual(value.width,1080);XCTAssertEqual(value.height,1920) }
    func testMediaMP4ZeroTimescaleLeavesDurationUnavailable() throws { let value = try MediaMetadataReader.read(mediaFile("Skala.mp4",mediaMovie(scale:0)));XCTAssertEqual(value.duration,nil) }
    func testMediaMP4OverflowAtomRejected() throws { let bytes = mediaInteger(1,4)+Data("moov".utf8)+mediaInteger(UInt64.max,8);XCTAssertThrowsError(try MediaMetadataReader.read(mediaFile("Overflow.mp4",bytes))) }
    func testMediaMP4SparsePayloadIsSkipped() throws {
        let url = root.appendingPathComponent("Gross.mp4"),movie = mediaMovie(),movieOffset:Int64 = 8*1024*1024*1024
        let fd = open(url.path,O_RDWR|O_CREAT|O_EXCL,0o600);guard fd >= 0 else { throw CommanderError.message("Testdatei nicht angelegt.") };defer { close(fd) }
        let mdat = mediaInteger(1,4)+Data("mdat".utf8)+mediaInteger(UInt64(movieOffset),8)
        _ = mdat.withUnsafeBytes { pwrite(fd,$0.baseAddress!,mdat.count,0) };XCTAssertEqual(ftruncate(fd,movieOffset+Int64(movie.count)),0);_ = movie.withUnsafeBytes { pwrite(fd,$0.baseAddress!,movie.count,off_t(movieOffset)) }
        let value = try MediaMetadataReader.read(url);XCTAssertEqual(value.width,1920);XCTAssertEqual(value.duration,12.5)
    }
    func testMediaLinksDirectoriesAndSpecialFilesRefused() throws {
        let file = try mediaFile("Ton.wav",mediaWAV()),link = root.appendingPathComponent("Link.wav");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertThrowsError(try MediaMetadataReader.read(link));XCTAssertThrowsError(try MediaMetadataReader.read(root));let fifo = root.appendingPathComponent("Pipe.wav");XCTAssertEqual(mkfifo(fifo.path,0o600),0);XCTAssertThrowsError(try MediaMetadataReader.read(fifo))
    }
    func testMediaCancellationDuringBoundedRead() throws { let file = try mediaImage(),token = CancellationToken();XCTAssertThrowsError(try MediaMetadataReader.read(file,token:token,progress:{ _,_ in token.cancel() }));XCTAssertTrue(token.isCancelled) }
    func testMediaSourceChangeDuringReadRefused() throws { let url = try mediaFile("Geaendert.mp4",mediaMovie());var changed = false;XCTAssertThrowsError(try MediaMetadataReader.read(url,progress:{ _,_ in if !changed { changed = true;try? Data("changed".utf8).write(to:url) } }));XCTAssertTrue(changed) }
    func testMediaIdentityTracksSameSizeChangedContent() throws { let url = try mediaFile("Identitaet.mp3",mediaID3([("TIT2",Data([3])+Data("Alt".utf8))])),before = try MediaMetadataIdentity(url),date = try FileManager.default.attributesOfItem(atPath:url.path)[.modificationDate] as! Date;usleep(10_000);try mediaID3([("TIT2",Data([3])+Data("Neu".utf8))]).write(to:url);try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:url.path);XCTAssertFalse(before == (try MediaMetadataIdentity(url))) }
    func testMediaBoundedTextAndFilenameComponents() throws { let text = "e"+String(repeating:"\u{0301}",count:100_000);XCTAssertTrue((MediaMetadata.boundedText(text)?.utf8.count ?? 0) <= 512);XCTAssertEqual(try MediaMetadata.filenameComponent("../Titel:/Neu\\Name"),"-Titel--Neu-Name");XCTAssertThrowsError(try MediaMetadata.filenameComponent("..."));XCTAssertTrue((MediaMetadata.boundedText(String(repeating:"\u{0344}",count:1000))?.utf8.count ?? 0) <= 512) }
    func testMediaRenameUsesRequestedTokensAndSanitizes() throws { let url = try mediaFile("Lied.mp3",mediaID3([("TIT2",Data([3])+Data("Titel/Neu".utf8)),("TPE1",Data([3])+Data("Artist".utf8)),("TRCK",Data([3])+Data("2/10".utf8))]));var rule = RenameRule();rule.pattern = "{artist}-{track}-{title}";let rows = try RenameEngine.plan([url],rule:rule);XCTAssertEqual(rows.rows.first?.targetName,"Artist-2-Titel-Neu.mp3");XCTAssertTrue(rows.canApply);XCTAssertEqual(try MediaMetadataReader.read(url).title,"Titel/Neu") }
    func testMediaMissingRenameFieldIsRowError() throws { let url = try mediaFile("Ohne.wav",mediaWAV());var rule = RenameRule();rule.pattern = "{album}";let preview = try RenameEngine.plan([url],rule:rule);XCTAssertEqual(preview.errorCount,1);XCTAssertFalse(preview.canApply) }
    func testMediaOriginalImageRenameTokensRemainCompatible() throws { let url = try mediaImage(exif:true);var rule = RenameRule();rule.pattern = "{taken}-{width}x{height}";rule.dateFormat = "yyyyMMdd";let preview = try RenameEngine.plan([url],rule:rule);XCTAssertEqual(preview.rows.first?.targetName,"20240229-3x2.jpg") }
    func testMediaProfilesVersionedOnlyForNewTokens() throws { var library = RenameProfileLibrary(),rule = RenameRule();_ = try library.save(name:"Alt",rule:rule);let legacy = try library.encoded();XCTAssertEqual((try JSONSerialization.jsonObject(with:legacy) as! [String:Any])["version"] as? Int,1);XCTAssertEqual(try RenameProfileLibrary(data:legacy),library);rule.pattern = "{artist}-{title}";_ = try library.save(name:"Medien",rule:rule);let extended = try library.encoded();XCTAssertEqual((try JSONSerialization.jsonObject(with:extended) as! [String:Any])["version"] as? Int,2);XCTAssertEqual(try RenameProfileLibrary(data:extended),library);var json = try JSONSerialization.jsonObject(with:extended) as! [String:Any];json["version"] = 1;XCTAssertThrowsError(try RenameProfileLibrary(data:JSONSerialization.data(withJSONObject:json)));json["version"] = 3;XCTAssertThrowsError(try RenameProfileLibrary(data:JSONSerialization.data(withJSONObject:json))) }
    func testMediaEscapedTokenDoesNotUpgradeProfile() throws { var rule = RenameRule(),library = RenameProfileLibrary();rule.pattern = "{{artist}}-{name}";_ = try library.save(name:"Klammern",rule:rule);XCTAssertEqual((try JSONSerialization.jsonObject(with:library.encoded()) as! [String:Any])["version"] as? Int,1) }
    func testMediaLegacyColumnsAndExtendedColumnsValidate() throws { var legacy = FolderViewSettings(columns:FolderViewSettings.baseColumnIDs.sorted().map { ViewColumn(id:$0,width:100,hidden:$0 != "name") });try legacy.validate();legacy.sortKey = MediaMetadataField.duration.rawValue;try legacy.validate();legacy.columns?.append(ViewColumn(id:"mediaDuration",width:120,hidden:false));try legacy.validate();legacy.columns?.append(ViewColumn(id:"mediaDuration",width:120,hidden:false));XCTAssertThrowsError(try legacy.validate()) }
    func testMediaNumericSortingHasMissingLastWithoutFileIO() throws { let a = try mediaFile("A.wav",mediaWAV()),b = try mediaFile("B.wav",mediaWAV());let first = try FileEntry(url:a),second = try FileEntry(url:b);var ma = try MediaMetadataReader.read(a),mb = try MediaMetadataReader.read(b);ma.duration = 20;mb.duration = 3;try FileManager.default.removeItem(at:a);try FileManager.default.removeItem(at:b);XCTAssertEqual(FileSystem.sorted([first,second],key:"mediaDuration",media:[first.id:ma,second.id:mb]).map(\.name),["B.wav","A.wav"]);XCTAssertEqual(FileSystem.sorted([first,second],key:"mediaDuration",ascending:false,media:[second.id:mb]).map(\.name),["B.wav","A.wav"]) }
    func testMediaUnsupportedTypesAndInvalidBudgets() throws { let url = try file("Leer.txt","");XCTAssertThrowsError(try MediaMetadataReader.read(url));XCTAssertThrowsError(try MediaMetadataReader.read(url,timeout:0));XCTAssertThrowsError(try MediaMetadataReader.read(url,timeout:.nan)) }
    func testMediaAtomCountBudgetBoundsManyEmptyAtoms() throws { let bytes = (0..<22_000).reduce(into:mediaMovie()) { data,_ in data.append(mediaAtom("free",Data())) };do { _ = try MediaMetadataReader.read(mediaFile("Viele.mp4",bytes));XCTAssertTrue(false,"Strukturbudget wurde nicht durchgesetzt") } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("budget")) } }
    func testMediaID3FooterUsesSizeExcludingFooter() throws {
        var bytes = mediaID3([("TIT2",Data([3])+Data("Footer".utf8))]);bytes[5] = 0x10
        let size = bytes[6..<10].reduce(0) { ($0<<7)|Int($1) },footer = Data("3DI".utf8)+bytes.subdata(in:3..<10)
        bytes.insert(contentsOf:footer,at:10+size);let value = try MediaMetadataReader.read(mediaFile("Footer.mp3",bytes));XCTAssertEqual(value.title,"Footer")
        bytes[10+size] = 0;XCTAssertThrowsError(try MediaMetadataReader.read(mediaFile("FooterFehler.mp3",bytes)))
    }
    func testMediaID3Version3ReservedFooterFlagRefused() throws { var bytes = mediaID3([("TIT2",Data([0])+Data("Text".utf8))],version:3);bytes[5] = 0x10;XCTAssertThrowsError(try MediaMetadataReader.read(mediaFile("Reserviert.mp3",bytes))) }
    func testMediaID3UndersizedExtendedHeaderRefused() throws { var bytes = Data([0x49,0x44,0x33,4,0,0x40])+mediaSynch(5);bytes.append(mediaSynch(5));bytes.append(1);XCTAssertThrowsError(try MediaMetadataReader.read(mediaFile("ErweiterterKopf.mp3",bytes))) }
    func testMediaMP4UnknownZeroDurationIsUnavailable() throws { var bytes = mediaMovie();let position = bytes.range(of:Data("mvhd".utf8))!.upperBound+16;bytes.replaceSubrange(position..<(position+4),with:Data(repeating:0,count:4));let value = try MediaMetadataReader.read(mediaFile("UnbekannteDauer.mp4",bytes));XCTAssertEqual(value.duration,nil) }
    func testMediaForeignFileURLHostsAreNotLocalSurrogates() throws { let file = try mediaFile("Ton.wav",mediaWAV());var components = URLComponents(url:file,resolvingAgainstBaseURL:false)!;components.host = "foreign.invalid";XCTAssertThrowsError(try MediaMetadataReader.read(components.url!));components.host = "localhost";XCTAssertEqual(try MediaMetadataReader.read(components.url!).duration,2) }
    func testMediaLongUTF8TagKeepsValidBoundedPrefix() throws { let bytes = mediaID3([("TIT2",Data([3])+Data(String(repeating:"😀",count:10_000).utf8))]);let value = try MediaMetadataReader.read(mediaFile("LangerTitel.mp3",bytes));XCTAssertNotNil(value.title);XCTAssertTrue((value.title?.utf8.count ?? 0) <= 512);XCTAssertFalse(value.title?.contains("�") == true) }
    func testMediaGarbageWithMP3ExtensionIsNotEmptyMetadata() throws { XCTAssertThrowsError(try MediaMetadataReader.read(mediaFile("Falsch.mp3",Data(repeating:0,count:300)))) }

}
