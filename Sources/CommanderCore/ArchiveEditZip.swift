import Foundation
import Darwin

/// Refuse opaque ZIP comments/extras rather than silently losing them during a format rewrite.
enum ArchiveEditZip {
    static func bytes(_ fd:Int32,_ offset:Int64,_ count:Int) throws -> [UInt8] {
        guard offset >= 0,count >= 0,count <= 128*1024 else { throw CommanderError.message("Ungültige ZIP-Struktur.") }
        var result = [UInt8](repeating:0,count:count),done = 0
        while done < count {
            let n = result.withUnsafeMutableBytes { pread(fd,$0.baseAddress!.advanced(by:done),count-done,off_t(offset)+off_t(done)) }
            guard n > 0 else { throw CommanderError.message("Unvollständige ZIP-Struktur.") };done += n
        };return result
    }
    static func u16(_ data:[UInt8],_ index:Int) -> Int { Int(data[index]) | Int(data[index+1]) << 8 }
    static func u32(_ data:[UInt8],_ index:Int) -> UInt64 { UInt64(u16(data,index)) | UInt64(u16(data,index+2)) << 16 }
    static func u64(_ data:[UInt8],_ index:Int) -> UInt64 { u32(data,index) | u32(data,index+4) << 32 }
    static func extras(_ values:[UInt8],central:Bool,zip64Length:Int) throws -> [Int:[UInt8]] {
        var index = 0,result:[Int:[UInt8]] = [:]
        while index < values.count {
            guard values.count-index >= 4 else { throw CommanderError.message("Ungültiges ZIP-Zusatzfeld.") }
            let type = u16(values,index),length = u16(values,index+2);index += 4
            guard length <= values.count-index,[0x0001,0x5455,0x7875].contains(type),result[type] == nil else { throw CommanderError.message("Dieses ZIP enthält zusätzliche Metadaten, die beim Bearbeiten nicht unverändert erhalten werden können.") }
            let payload = Array(values[index..<index+length])
            switch type {
            case 0x0001:guard length == zip64Length,zip64Length > 0 else { throw CommanderError.message("ZIP64-Zusatzdaten enthalten nicht zuordenbare Felder.") }
            case 0x5455:
                guard let flags = payload.first,flags & 0xF8 == 0 else { throw CommanderError.message("Nicht unterstützte ZIP-Zeitstempelflags.") }
                let fields = central ? Int(flags & 1) : (0..<3).filter { flags & (1 << $0) != 0 }.count
                guard length == 1+4*fields else { throw CommanderError.message("ZIP-Zeitstempelfelder enthalten zusätzliche oder unvollständige Daten.") }
            case 0x7875:
                guard length >= 3,payload[0] == 1,(1...8).contains(Int(payload[1])),2+Int(payload[1]) < length else { throw CommanderError.message("Nicht unterstützte ZIP-UID-/GID-Felder.") }
                let uid = Int(payload[1]),gid = Int(payload[2+uid])
                guard (1...8).contains(gid),length == 3+uid+gid,uid < 8 || payload[1+uid] & 0x80 == 0,gid < 8 || payload[length-1] & 0x80 == 0 else { throw CommanderError.message("ZIP-UID-/GID-Felder enthalten zusätzliche oder nicht unterstützte Daten.") }
            default:break
            }
            result[type] = payload;index += length
        };return result
    }
    static func validate(_ fd:Int32,size:Int64,token:CancellationToken) throws {
        guard size >= 22 else { throw CommanderError.message("Unvollständiges ZIP-Archiv.") }
        let first = try bytes(fd,0,4)
        guard u32(first,0) == 0x04034B50 || u32(first,0) == 0x06054B50 else { throw CommanderError.message("ZIP-Dateien mit vorgeschalteten Programmen oder Zusatzdaten werden nicht bearbeitet.") }
        let tailSize = Int(min(size,65_557)),tail = try bytes(fd,size-Int64(tailSize),tailSize)
        guard let end = stride(from:tail.count-22,through:0,by:-1).first(where:{ u32(tail,$0) == 0x06054B50 && $0+22+u16(tail,$0+20) == tail.count }) else { throw CommanderError.message("ZIP-Abschluss fehlt oder zusätzliche Daten sind angehängt.") }
        guard u16(tail,end+20) == 0,u16(tail,end+4) == 0,u16(tail,end+6) == 0,u16(tail,end+8) == u16(tail,end+10) else { throw CommanderError.message("ZIP-Kommentare und mehrteilige Archive bleiben unverändert; Bearbeitung ist dafür nicht verfügbar.") }
        var count = UInt64(u16(tail,end+10)),length = u32(tail,end+12),start = u32(tail,end+16)
        if count == 0xFFFF || length == 0xFFFFFFFF || start == 0xFFFFFFFF {
            let endOffset = size-Int64(tailSize)+Int64(end)
            guard endOffset >= 20 else { throw CommanderError.message("ZIP64-Abschluss fehlt.") }
            let locator = try bytes(fd,endOffset-20,20)
            guard u32(locator,0) == 0x07064B50,u32(locator,4) == 0,u32(locator,16) == 1,u64(locator,8) <= UInt64(Int64.max) else { throw CommanderError.message("Mehrteiliges oder ungültiges ZIP64-Archiv.") }
            let record = try bytes(fd,Int64(u64(locator,8)),56)
            guard u32(record,0) == 0x06064B50,u64(record,4) == 44,u32(record,16) == 0,u32(record,20) == 0,u64(record,24) == u64(record,32) else { throw CommanderError.message("Nicht unterstützte ZIP64-Metadaten.") }
            count = u64(record,32);length = u64(record,40);start = u64(record,48)
        }
        guard count <= UInt64(ArchiveEditPlan.maximumEntries),count == 0 || size >= 46,start <= UInt64(size),length <= UInt64(size)-start else { throw CommanderError.message("ZIP-Verzeichnis überschreitet die Bearbeitungsgrenze.") }
        var position = start
        for _ in 0..<count {
            try token.check()
            guard position <= UInt64(size)-46 else { throw CommanderError.message("ZIP-Verzeichnis ist unvollständig.") }
            let header = try bytes(fd,Int64(position),46)
            guard u32(header,0) == 0x02014B50,u16(header,8) & 0x2041 == 0,u16(header,34) == 0,u16(header,32) == 0,u32(header,38) & 7 == 0 else { throw CommanderError.message("ZIP-Verschlüsselung, Eintragskommentare, DOS-Sonderattribute oder mehrteilige Daten können nicht unverändert bearbeitet werden.") }
            guard [0,8].contains(u16(header,10)) else { throw CommanderError.message("ZIP-Bearbeitung unterstützt gespeicherte und Deflate-komprimierte Einträge.") }
            let name = u16(header,28),extra = u16(header,30),recordLength = UInt64(46+name+extra)
            guard recordLength <= start+length-position else { throw CommanderError.message("ZIP-Verzeichnis ist inkonsistent.") }
            let required = (u32(header,24) == 0xFFFFFFFF ? 8 : 0)+(u32(header,20) == 0xFFFFFFFF ? 8 : 0)+(u32(header,42) == 0xFFFFFFFF ? 8 : 0)
            let fields = try extras(bytes(fd,Int64(position)+Int64(46+name),extra),central:true,zip64Length:required)
            guard required == 0 || fields[1] != nil else { throw CommanderError.message("Erforderliche ZIP64-Felder fehlen.") }
            var local = u32(header,42)
            if local == 0xFFFFFFFF {
                let offset = (u32(header,24) == 0xFFFFFFFF ? 8 : 0)+(u32(header,20) == 0xFFFFFFFF ? 8 : 0)
                guard let zip64 = fields[1],zip64.count >= offset+8 else { throw CommanderError.message("ZIP64-Dateiposition fehlt.") };local = u64(zip64,offset)
            }
            guard local <= UInt64(size)-30 else { throw CommanderError.message("ZIP-Dateikopf liegt außerhalb des Archivs.") }
            let localHeader = try bytes(fd,Int64(local),30)
            guard u32(localHeader,0) == 0x04034B50,u16(localHeader,6) & 0x2041 == 0,u16(localHeader,8) == u16(header,10) else { throw CommanderError.message("Verschlüsselter oder ungültiger ZIP-Dateikopf.") }
            let localRequired = (u32(localHeader,22) == 0xFFFFFFFF ? 8 : 0)+(u32(localHeader,18) == 0xFFFFFFFF ? 8 : 0)
            let localFields = try extras(bytes(fd,Int64(local)+Int64(30+u16(localHeader,26)),u16(localHeader,28)),central:false,zip64Length:localRequired)
            guard localRequired == 0 || localFields[1] != nil else { throw CommanderError.message("Erforderliche lokale ZIP64-Felder fehlen.") }
            position += recordLength
        }
        guard position == start+length else { throw CommanderError.message("Zusätzliche ZIP-Verzeichniseigenschaften können nicht unverändert erhalten werden.") }
    }
}
