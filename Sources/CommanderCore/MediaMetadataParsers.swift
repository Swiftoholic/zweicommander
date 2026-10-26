import Foundation

extension MediaMetadataReader {
    static func synchsafe(_ data:Data,_ start:Int) throws -> Int {
        guard start >= 0,start <= data.count-4,data[start..<(start+4)].allSatisfy({ $0 < 128 }) else { throw CommanderError.message("Ungültige synchsafe ID3-Größe.") }
        return data[start..<(start+4)].reduce(0) { ($0<<7)|Int($1) }
    }
    static func decodedText(_ data:Data,encoding:String.Encoding,truncated:Bool) -> String? {
        var value = data
        for _ in 0...(truncated ? 3 : 0) { if let text = String(data:value,encoding:encoding) { return text };if !value.isEmpty { value.removeLast() } }
        return nil
    }
    static func tagText(_ data:Data,truncated:Bool = false) -> String? {
        guard let encoding = data.first,data.count > 1 else { return nil };var body = data.subdata(in:1..<data.count)
        let result:String?
        switch encoding {
        case 0:result = String(data:body,encoding:.isoLatin1)
        case 1:
            guard body.count >= 2,body.starts(with:[0xFF,0xFE]) || body.starts(with:[0xFE,0xFF]) else { return nil }
            if body.count%2 != 0 { body.removeLast() };result = decodedText(body,encoding:.utf16,truncated:truncated)
        case 2:if body.count%2 != 0 { body.removeLast() };result = decodedText(body,encoding:.utf16BigEndian,truncated:truncated)
        case 3:result = decodedText(body,encoding:.utf8,truncated:truncated)
        default:return nil
        }
        return result.flatMap { MediaMetadata.boundedText($0.components(separatedBy:"\0").first ?? "") }
    }
    static func applyTag(_ id:String,_ value:String?,to result:inout MediaMetadata) {
        guard let value else { return }
        switch id {
        case "TIT2","INAM","©nam":result.title = value
        case "TPE1","IART","©ART","aART":result.artist = value
        case "TALB","IPRD","©alb":result.album = value
        case "TYER","TDRC","ICRD","©day":if let year = Int(value.prefix(4)),(1...9999).contains(year) { result.year = year }
        case "TRCK","ITRK":if let track = Int(value.split(separator:"/").first ?? ""),(1...100_000).contains(track) { result.track = track }
        case "TLEN":if let value = Double(value),value.isFinite,value > 0,value <= 1_000_000_000_000 { result.duration = value/1000;result.addNote("Dauer aus dem ID3-TLEN-Tag, ohne Audioscan.") }
        default:break
        }
    }
    static func readID3(_ c:MediaReadContext,into result:inout MediaMetadata) throws {
        var foundTag = false
        if c.file.size >= 128 {
            let tail = try c.read(c.file.size-128,128)
            if tail.starts(with:Data("TAG".utf8)) {
                foundTag = true
                func text(_ start:Int,_ count:Int) -> String? { tail.mediaLatin(start,count).flatMap { MediaMetadata.boundedText($0.components(separatedBy:"\0").first ?? "") } }
                result.title = text(3,30);result.artist = text(33,30);result.album = text(63,30)
                if let year = text(93,4).flatMap(Int.init),(1...9999).contains(year) { result.year = year }
                if tail[125] == 0,tail[126] > 0 { result.track = Int(tail[126]) }
            }
        }
        let header = try c.read(0,min(10,Int(clamping:c.file.size)))
        guard header.starts(with:Data("ID3".utf8)) else {
            let mpeg = header.count >= 4 && header[0] == 0xFF && header[1] & 0xE0 == 0xE0 && header[1] & 0x18 != 8 && header[1] & 6 != 0 && header[2] >> 4 > 0 && header[2] >> 4 < 15 && header[2] & 12 != 12
            guard foundTag || mpeg else { throw CommanderError.message("Kein unterstützter ID3- oder MPEG-Audiokopf gefunden.") };return
        }
        guard header.count == 10 else { throw CommanderError.message("Unvollständiger ID3-Kopf.") }
        let version = header[3],flags = header[5]
        guard [3,4].contains(version),header[4] != 0xFF,flags & 0x80 == 0,flags & (version == 3 ? 0x1F : 0x0F) == 0 else { throw CommanderError.message("Nur gewöhnliche ID3v2.3/v2.4-Tags ohne Unsynchronisation werden gelesen.") }
        let size = try synchsafe(header,6),end = Int64(size)+10
        guard end <= c.file.size else { throw CommanderError.message("ID3-Tag reicht über das Dateiende hinaus.") }
        // ID3v2.4 section 3.1: the tag size excludes its header and optional footer.
        if version == 4,flags & 0x10 != 0 {
            guard end+10 <= c.file.size else { throw CommanderError.message("ID3-Footer fehlt.") }
            let footer = try c.read(end,10)
            guard footer.starts(with:Data("3DI".utf8)),footer.subdata(in:3..<10) == header.subdata(in:3..<10) else { throw CommanderError.message("ID3-Footer widerspricht dem Kopf.") }
        }
        var offset:Int64 = 10
        if flags & 0x40 != 0 {
            let bytes = try c.read(offset,4),length = version == 4 ? try synchsafe(bytes,0) : Int(bytes.mediaBE(0,4)!) + 4
            guard length >= (version == 4 ? 6 : 10),Int64(length) <= end-offset else { throw CommanderError.message("Ungültiger erweiterter ID3-Kopf.") };offset += Int64(length)
        }
        while offset+10 <= end {
            let frame = try c.read(offset,10);if frame[0] == 0 { break }
            guard let id = String(data:frame.prefix(4),encoding:.ascii),id.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { throw CommanderError.message("Ungültiger ID3-Rahmenname.") }
            let count = version == 4 ? try synchsafe(frame,4) : Int(frame.mediaBE(4,4)!)
            guard count > 0,Int64(count) <= end-offset-10 else { throw CommanderError.message("Ungültige ID3-Rahmenlänge.") }
            // Compressed, encrypted, grouped or unsynchronised frames have no plain text payload.
            if ["TIT2","TPE1","TALB","TYER","TDRC","TRCK","TLEN"].contains(id) {
                let unsupported = frame[9] != 0 || frame[8] & (version == 4 ? 0x8F : 0x1F) != 0
                if unsupported { result.addNote("Ein codierter ID3-Textwert ist nicht verfügbar.") }
                else { applyTag(id,tagText(try c.read(offset+10,min(count,4096)),truncated:count > 4096),to:&result) }
            }
            offset += Int64(count)+10
        }
    }
    static func readWAV(_ c:MediaReadContext,into result:inout MediaMetadata) throws {
        let header = try c.read(0,12);let declared = Int64(header.mediaLE(4,4)!)+8
        guard declared <= c.file.size,declared >= 12 else { throw CommanderError.message("Ungültige RIFF-Größe.") }
        var offset:Int64 = 12,rate:Double?,audioBytes:UInt64?
        while offset+8 <= declared {
            let head = try c.read(offset,8),id = head.mediaLatin(0,4)!,length = Int64(head.mediaLE(4,4)!),body = offset+8
            guard length <= declared-body else { throw CommanderError.message("RIFF-Block reicht über das Dateiende hinaus.") }
            if id == "fmt ",length >= 16 {
                let fmt = try c.read(body,16),format = fmt.mediaLE(0,2)!,channels = fmt.mediaLE(2,2)!,sampleRate = fmt.mediaLE(4,4)!,byteRate = fmt.mediaLE(8,4)!,blockAlign = fmt.mediaLE(12,2)!,bits = fmt.mediaLE(14,2)!
                if [1,3].contains(format),channels > 0,channels <= 64,sampleRate > 0,byteRate > 0,blockAlign > 0,bits > 0,bits <= 64,byteRate == sampleRate*blockAlign,blockAlign == channels*((bits+7)/8) { rate = Double(byteRate) }
            } else if id == "data" { audioBytes = UInt64(length) }
            else if id == "LIST",length >= 4 {
                let kind = try c.read(body,4)
                if kind == Data("INFO".utf8) {
                    var sub = body+4
                    while sub+8 <= body+length {
                        let info = try c.read(sub,8),name = info.mediaLatin(0,4)!,count = Int64(info.mediaLE(4,4)!)
                        guard count <= body+length-sub-8 else { throw CommanderError.message("Ungültiges RIFF-Textfeld.") }
                        if ["INAM","IART","IPRD","ICRD","ITRK"].contains(name) {
                            let data = try c.read(sub+8,Int(min(count,4096))),text = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1)
                            applyTag(name,text.flatMap { MediaMetadata.boundedText($0.components(separatedBy:"\0").first ?? "") },to:&result)
                        }
                        sub += 8+count+(count%2)
                    }
                }
            }
            offset = body+length+(length%2)
        }
        if let rate,let audioBytes { result.duration = Double(audioBytes)/rate }
    }
    struct Atom { let type:String,body:Int64,end:Int64 }
    static func atom(_ c:MediaReadContext,_ offset:Int64,_ end:Int64) throws -> Atom {
        guard end-offset >= 8 else { throw CommanderError.message("Unvollständiger Medien-Atomkopf.") };let header = try c.read(offset,8)
        var length = header.mediaBE(0,4)!,head:Int64 = 8
        if length == 1 { guard end-offset >= 16 else { throw CommanderError.message("Unvollständige 64-Bit-Atomlänge.") };length = try c.read(offset+8,8).mediaBE(0,8)!;head = 16 }
        if length == 0 { length = UInt64(end-offset) }
        guard length >= UInt64(head),length <= UInt64(end-offset),length <= UInt64(Int64.max) else { throw CommanderError.message("Ungültige Medien-Atomlänge.") }
        return Atom(type:header.mediaLatin(4,4)!,body:offset+head,end:offset+Int64(length))
    }
    static func readMP4(_ c:MediaReadContext,into result:inout MediaMetadata) throws {
        var foundMovie = false
        func duration(_ atom:Atom) throws {
            let data = try c.read(atom.body,Int(min(atom.end-atom.body,32)));guard let version = data.first else { return }
            let scaleOffset = version == 0 ? 12 : 20,durationOffset = version == 0 ? 16 : 24,count = version == 0 ? 4 : 8
            guard version <= 1,let scale = data.mediaBE(scaleOffset,4),let units = data.mediaBE(durationOffset,count),scale > 0,units != (count == 4 ? UInt64(UInt32.max) : UInt64.max) else { return }
            let value = Double(units)/Double(scale);if value.isFinite,value > 0,value <= 1_000_000_000 { result.duration = value }
        }
        func dimensions(_ atom:Atom) throws {
            let size = atom.end-atom.body;guard size >= 84 else { return };let data = try c.read(atom.end-44,44)
            guard let w = data.mediaBE(36,4),let h = data.mediaBE(40,4),w > 0,h > 0,w%65536 == 0,h%65536 == 0,w/65536 <= 1_000_000,h/65536 <= 1_000_000 else { return }
            var width = Int(w/65536),height = Int(h/65536)
            if data.mediaBE(0,4) == 0,data.mediaBE(16,4) == 0,let b = data.mediaBE(4,4),let d = data.mediaBE(12,4),b != 0,d != 0 { swap(&width,&height) }
            if width*(height) > (result.width ?? 0)*(result.height ?? 0) { result.width = width;result.height = height }
        }
        func walk(_ start:Int64,_ end:Int64,_ depth:Int,_ parent:String) throws {
            guard depth <= 8 else { throw CommanderError.message("Medien-Atomstruktur ist zu tief verschachtelt.") };var offset = start
            while offset < end {
                let box = try atom(c,offset,end)
                if box.type == "moov" { foundMovie = true }
                if box.type == "mvhd" { try duration(box) }
                else if box.type == "tkhd" { try dimensions(box) }
                else if parent == "ilst" {
                    var child = box.body
                    while child < box.end {
                        let value = try atom(c,child,box.end)
                        if value.type == "data",value.end-value.body >= 8 {
                            let prefix = try c.read(value.body,8),type = prefix.mediaBE(0,4)! & 0xFFFFFF
                            if box.type == "trkn",value.end-value.body >= 12 { let bytes = try c.read(value.body+8,4);let number = bytes.mediaBE(2,2)!;if number > 0 { result.track = Int(number) } }
                            else if ["©nam","©ART","aART","©alb","©day"].contains(box.type),[1,2].contains(type) {
                                let bytes = try c.read(value.body+8,Int(min(value.end-value.body-8,4096))),encoding:String.Encoding = type == 2 ? .utf16BigEndian : .utf8
                                applyTag(box.type,decodedText(bytes,encoding:encoding,truncated:value.end-value.body-8 > 4096).flatMap { MediaMetadata.boundedText($0) },to:&result)
                            }
                        }
                        child = value.end
                    }
                } else if ["moov","trak","mdia","udta","ilst"].contains(box.type) { try walk(box.body,box.end,depth+1,box.type) }
                else if box.type == "meta" { guard box.end-box.body >= 4 else { throw CommanderError.message("Unvollständiger Medien-Metadatenkopf.") };try walk(box.body+4,box.end,depth+1,"meta") }
                else if box.type == "cmov" { throw CommanderError.message("Komprimierte QuickTime-Kopfdaten werden nicht gelesen.") }
                offset = box.end
            }
        }
        try walk(0,c.file.size,0,"");guard foundMovie else { throw CommanderError.message("Kein unterstützter MP4-/MOV-Filmkopf gefunden.") }
        result.addNote("Dauer und Auflösung aus Containerköpfen; keine vollständige Codec- oder Medienprüfung.")
    }
}
