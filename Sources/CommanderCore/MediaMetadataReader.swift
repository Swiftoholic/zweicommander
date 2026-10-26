import Foundation
import ImageIO

final class MediaReadContext {
    let file:ViewerFile,token:CancellationToken,deadline:TimeInterval
    let progress:((Int64,Int64)->Void)?
    var readBytes = 0,steps = 0
    init(_ url:URL,token:CancellationToken,seconds:Double,progress:((Int64,Int64)->Void)?) throws { self.progress = progress;self.token = token;try token.check();file = try ViewerFile(url);deadline = ProcessInfo.processInfo.systemUptime+seconds }
    func check() throws { try token.check();guard ProcessInfo.processInfo.systemUptime <= deadline,steps < 20_000 else { throw CommanderError.message("Die begrenzte Metadatenprüfung hat ihr Zeit-/Strukturbudget erreicht.") };steps += 1 }
    func read(_ offset:Int64,_ count:Int) throws -> Data {
        try check();guard offset >= 0,count >= 0,offset <= file.size,Int64(count) <= file.size-offset,readBytes <= 8*1024*1024-count else { throw CommanderError.message("Ungültiger oder zu großer Metadatenbereich.") }
        let data = try file.read(offset:offset,length:count,token:token).data;readBytes += count;progress?(Int64(readBytes),file.size);return data
    }
    func imageData() throws -> Data {
        guard file.size <= 64*1024*1024 else { throw CommanderError.message("Bildmetadaten sind auf Dateien bis 64 MiB begrenzt.") }
        var result = Data();result.reserveCapacity(Int(file.size));var offset:Int64 = 0
        while offset < file.size { try check();let count = min(64*1024,Int(file.size-offset));result.append(try file.read(offset:offset,length:count,token:token).data);offset += Int64(count);progress?(offset,file.size) };return result
    }
}

public enum MediaMetadataReader {
    public static let supportedExtensions:Set<String> = ["png","jpg","jpeg","jpe","tif","tiff","heic","heif","gif","bmp","webp","jp2","ico","dng","mp3","wav","wave","mp4","m4a","m4v","mov"]
    public static let help = "Lokale Bild-/EXIF-Daten bis 64 MiB; ID3v2.3/v2.4 und v1, RIFF/WAV, MP4/M4A/MOV-Containerdaten. MP3-Dauer nur mit TLEN-Tag. Höchstens 8 MiB Headerdaten und 20.000 Strukturschritte, Budgetprüfungen zwischen Abschnitten (2 Sekunden); der einzelne ImageIO-Property-Aufruf ist nicht unterbrechbar. Unbekannte oder fehlende Felder bleiben leer. Keine Medienwiedergabe."
    public static func read(_ url:URL,token:CancellationToken = .init(),timeout:Double = 2,progress:((Int64,Int64)->Void)? = nil) throws -> MediaMetadata {
        guard timeout.isFinite,timeout > 0,timeout <= 10 else { throw CommanderError.message("Ungültiges Metadaten-Zeitbudget.") }
        let identity = try MediaMetadataIdentity(url),context = try MediaReadContext(url,token:token,seconds:timeout,progress:progress)
        var result = MediaMetadata(identity:identity)
        let ext = url.pathExtension.lowercased(),head = try context.read(0,min(12,Int(clamping:context.file.size)))
        if head.starts(with:Data("ID3".utf8)) || ext == "mp3" { result.format = "ID3 / MPEG Audio";try readID3(context,into:&result) }
        else if head.count >= 12,head.prefix(4) == Data("RIFF".utf8),head.suffix(4) == Data("WAVE".utf8) { result.format = "RIFF / WAVE";try readWAV(context,into:&result) }
        else if ["mp4","m4a","m4v","mov"].contains(ext) { result.format = "ISO-BMFF / QuickTime";try readMP4(context,into:&result) }
        else if supportedExtensions.contains(ext) {
            let data = try context.imageData();try context.check()
            guard let image = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),let properties = CGImageSourceCopyPropertiesAtIndex(image,0,[kCGImageSourceShouldCache:false] as CFDictionary) as? [CFString:Any] else { throw CommanderError.message("Kein lesbarer unterstützter Bildkopf.") }
            result.format = (CGImageSourceGetType(image) as String?) ?? "Bild"
            if let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,width.doubleValue > 0,height.doubleValue > 0,width.doubleValue <= 1_000_000,height.doubleValue <= 1_000_000 { result.width = width.intValue;result.height = height.intValue }
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString:Any],tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString:Any]
            result.title = (tiff?[kCGImagePropertyTIFFImageDescription] as? String).flatMap { MediaMetadata.boundedText($0) }
            result.artist = (tiff?[kCGImagePropertyTIFFArtist] as? String).flatMap { MediaMetadata.boundedText($0) }
            let make = (tiff?[kCGImagePropertyTIFFMake] as? String).flatMap { MediaMetadata.boundedText($0) },model = (tiff?[kCGImagePropertyTIFFModel] as? String).flatMap { MediaMetadata.boundedText($0) }
            result.camera = MediaMetadata.boundedText([make,model].compactMap { $0 }.joined(separator:" "))
            if let value = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
                let parser = DateFormatter();parser.locale = Locale(identifier:"en_US_POSIX");parser.calendar = Calendar(identifier:.gregorian);parser.timeZone = TimeZone(secondsFromGMT:0);parser.dateFormat = "yyyy:MM:dd HH:mm:ss";parser.isLenient = false
                if let date = parser.date(from:value),parser.string(from:date) == value { result.taken = date;result.year = Int(value.prefix(4)) }
            }
            result.notes.append("EXIF-Aufnahmezeit ohne Zeitzonenumrechnung; Bildabmessungen aus dem Dateikopf.")
        } else { throw CommanderError.message("Für diesen Dateityp ist kein begrenzter Medienleser vorhanden.") }
        try context.check();try context.file.validate()
        guard try MediaMetadataIdentity(url) == identity else { throw CommanderError.message("Die Mediendatei wurde während der Prüfung verändert.") }
        return result
    }
}

extension Data {
    func mediaBE(_ start:Int,_ count:Int) -> UInt64? { guard start >= 0,count >= 0,count <= 8,start <= self.count-count else { return nil };return self[start..<(start+count)].reduce(0) { ($0<<8)|UInt64($1) } }
    func mediaLE(_ start:Int,_ count:Int) -> UInt64? { guard start >= 0,count >= 0,count <= 8,start <= self.count-count else { return nil };return self[start..<(start+count)].reversed().reduce(0) { ($0<<8)|UInt64($1) } }
    func mediaLatin(_ start:Int,_ count:Int) -> String? { guard start >= 0,count >= 0,start <= self.count-count else { return nil };return String(data:self.subdata(in:start..<(start+count)),encoding:.isoLatin1) }
}
