import Foundation

public enum BinaryInspector {
    public static func describe(_ url: URL) throws -> String? {
        let reader = try ViewerFile(url),result = try describe(reader)
        try reader.validate();return result
    }
    private static func describe(_ reader:ViewerFile) throws -> String? {
        let file = try reader.duplicatedHandle();defer { try? file.close() }
        let header = BinaryBytes(try reader.read(offset:0,length:256*1024).data)
        guard header.count >= 4 else { return nil }
        if header.bytes.prefix(2) == [0x4d,0x5a] { return try portableExecutable(header, file: file, fileSize:reader.size) }
        let magic = try header.number(0, count: 4, bigEndian: true)
        if [0xcafebabe,0xcafebabf,0xbebafeca,0xbfbafeca].contains(magic) {
            let big = magic == 0xcafebabe || magic == 0xcafebabf
            let wide = magic == 0xcafebabf || magic == 0xbfbafeca
            let count = Int(try header.number(4, count: 4, bigEndian: big))
            guard (1...64).contains(count) else { throw CommanderError.message("Ungültiger Mach-O-Architekturkopf.") }
            var names: [String] = []
            for i in 0..<count { names.append(cpu(try header.number(8+i*(wide ? 32 : 20), count: 4, bigEndian: big))) }
            return "Format: Mach-O Universal\nArchitekturen: "+names.joined(separator: ", ")
        }
        if [0xfeedface,0xfeedfacf,0xcefaedfe,0xcffaedfe].contains(magic) {
            let big = magic == 0xfeedface || magic == 0xfeedfacf
            let architecture = cpu(try header.number(4, count: 4, bigEndian: big))
            let fileType = try header.number(12, count: 4, bigEndian: big)
            let kind = [2: "Programm", 6: "Dynamische Bibliothek", 8: "Bundle"][Int(fileType)] ?? "Typ \(fileType)"
            return "Format: Mach-O\nArchitektur: \(architecture)\nArt: \(kind)"
        }
        return nil
    }
    private static func cpu(_ type: UInt64) -> String {
        [7: "x86", 12: "ARM", 0x01000007: "x86_64", 0x0100000c: "arm64", 18: "PowerPC", 0x01000012: "PowerPC 64"][type] ?? String(format: "CPU 0x%08llX", type)
    }
    private struct Section { let name: String; let rva: Int; let virtualSize: Int; let offset: Int; let size: Int }
    private static func portableExecutable(_ h: BinaryBytes, file: FileHandle, fileSize: Int64) throws -> String {
        let pe = Int(try h.number(0x3c, count: 4))
        guard pe >= 0x40, pe+24 <= h.count else { throw CommanderError.message("PE-Kopf liegt außerhalb des sicheren Lesebereichs.") }
        guard try h.number(pe, count: 4) == 0x4550 else { return "Format: MZ/DOS (kein PE-Kopf)" }
        let machine = try h.number(pe+4, count: 2)
        let architecture = [0x14c: "x86 (32 Bit)", 0x8664: "x86_64 (64 Bit)", 0xaa64: "ARM64", 0x1c4: "ARM"][Int(machine)] ?? String(format: "0x%04llX", machine)
        let count = Int(try h.number(pe+6, count: 2)), optionalSize = Int(try h.number(pe+20, count: 2))
        guard count <= 96, pe+24+optionalSize+count*40 <= h.count else { throw CommanderError.message("Ungültige PE-Sektionstabelle.") }
        let flags = try h.number(pe+22, count: 2)
        var lines = ["Format: Windows PE", "Architektur: \(architecture)", "Art: \(flags & 0x2000 != 0 ? "DLL/Plug-in" : "Programm")"]
        var sections: [Section] = []
        for i in 0..<count {
            let offset = pe+24+optionalSize+i*40
            let name = String(bytes: h.bytes[offset..<offset+8].prefix(while: { $0 != 0 }), encoding: .ascii) ?? "?"
            sections.append(Section(name: name, rva: Int(try h.number(offset+12, count: 4)), virtualSize: Int(try h.number(offset+8, count: 4)), offset: Int(try h.number(offset+20, count: 4)), size: Int(try h.number(offset+16, count: 4))))
        }
        lines.append("Sektionen: "+sections.map(\.name).joined(separator: ", "))
        func diskOffset(_ rva: Int, length: Int) -> Int? {
            guard let s = sections.first(where: { rva >= $0.rva && rva-$0.rva < $0.size }), length >= 0, rva-s.rva <= s.size-length else { return nil }
            let position = s.offset+rva-s.rva
            return position >= 0 && Int64(position)+Int64(length) <= fileSize ? position : nil
        }
        // VERSIONINFO is a data resource; inspecting it never loads or executes the Windows image.
        do {
            let magic = try h.number(pe+24, count: 2), directoryStart = pe+24+(magic == 0x20b ? 112 : 96)
            guard optionalSize >= directoryStart-(pe+24)+24 else { return lines.joined(separator: "\n") }
            let resourceRVA = Int(try h.number(directoryStart+16, count: 4)), resourceSize = Int(try h.number(directoryStart+20, count: 4))
            guard resourceRVA != 0, resourceSize >= 16, resourceSize <= 16*1024*1024, let start = diskOffset(resourceRVA, length: resourceSize) else { return lines.joined(separator: "\n") }
            try file.seek(toOffset: UInt64(start))
            let resource = BinaryBytes(try file.read(upToCount: resourceSize) ?? Data())
            func entries(_ offset: Int) throws -> [(UInt64,UInt64)] {
                let n = Int(try resource.number(offset+12, count: 2) + resource.number(offset+14, count: 2))
                guard n <= 4096 else { throw CommanderError.message("Zu viele PE-Ressourceneinträge.") }
                return try (0..<n).map { i in (try resource.number(offset+16+i*8, count: 4), try resource.number(offset+20+i*8, count: 4)) }
            }
            guard let versionType = try entries(0).first(where: { $0.0 == 16 }), versionType.1 & 0x80000000 != 0 else { return lines.joined(separator: "\n") }
            let versionNames = try entries(Int(versionType.1 & 0x7fffffff))
            var metadata: [String:String] = [:]
            for (_, nameValue) in versionNames.prefix(16) where nameValue & 0x80000000 != 0 {
                for (_, leafValue) in try entries(Int(nameValue & 0x7fffffff)).prefix(16) where leafValue & 0x80000000 == 0 {
                    let leaf = Int(leafValue)
                    let dataRVA = Int(try resource.number(leaf, count: 4)), length = Int(try resource.number(leaf+4, count: 4))
                    guard length > 0, length <= 1024*1024, let position = diskOffset(dataRVA, length: length) else { continue }
                    try file.seek(toOffset: UInt64(position))
                    let values = try versionStrings(try file.read(upToCount: length) ?? Data())
                    metadata.merge(values, uniquingKeysWith: { first,_ in first })
                }
            }
            for (key,title) in [("ProductName","Produkt"),("FileDescription","Beschreibung"),("FileVersion","Dateiversion"),("ProductVersion","Produktversion"),("CompanyName","Hersteller"),("OriginalFilename","Originalname") ] {
                if let value = metadata[key], !value.isEmpty { lines.append(title+": "+value) }
            }
        } catch { lines.append("Versionsressource konnte nicht vollständig gelesen werden.") }
        return lines.joined(separator: "\n")
    }
    public static func versionStrings(_ data: Data) throws -> [String:String] {
        let b = BinaryBytes(data)
        var result: [String:String] = [:], visited = 0
        let wanted: Set<String> = ["ProductName","FileDescription","FileVersion","ProductVersion","CompanyName","OriginalFilename"]
        func aligned(_ value: Int) -> Int { (value+3) & ~3 }
        func block(_ offset: Int, limit: Int, depth: Int) throws {
            visited += 1
            guard depth <= 8, visited <= 2000 else { throw CommanderError.message("Ungültige Versionsressource.") }
            let length = Int(try b.number(offset, count: 2)), valueLength = Int(try b.number(offset+2, count: 2)), type = try b.number(offset+4, count: 2)
            guard length >= 6, offset+length <= limit else { throw CommanderError.message("Abgeschnittene Versionsressource.") }
            let end = offset+length
            var cursor = offset+6, keyBytes: [UInt8] = []
            while cursor+2 <= end {
                let character = try b.number(cursor, count: 2); cursor += 2
                if character == 0 { break }
                guard keyBytes.count <= 512 else { throw CommanderError.message("Zu langer Metadatenschlüssel.") }
                keyBytes += [UInt8(character & 255), UInt8(character >> 8)]
            }
            let key = String(bytes: keyBytes, encoding: .utf16LittleEndian) ?? ""
            cursor = aligned(cursor)
            let valueBytes = valueLength * (type == 1 ? 2 : 1)
            guard cursor+valueBytes <= end || valueBytes == 0 else { throw CommanderError.message("Ungültige Metadatenlänge.") }
            if wanted.contains(key), type == 1, cursor+valueBytes <= end {
                let value = String(bytes: b.bytes[cursor..<cursor+valueBytes], encoding: .utf16LittleEndian) ?? ""
                result[key] = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(1024))
            }
            cursor = aligned(cursor+valueBytes)
            while cursor+6 <= end {
                let childLength = Int(try b.number(cursor, count: 2))
                guard childLength >= 6 else { break }
                try block(cursor, limit: end, depth: depth+1)
                cursor = aligned(cursor+childLength)
            }
        }
        try block(0, limit: data.count, depth: 0)
        return result
    }
}

private struct BinaryBytes {
    let bytes: [UInt8]
    var count: Int { bytes.count }
    init(_ data: Data) { bytes = Array(data) }
    func number(_ offset: Int, count length: Int, bigEndian: Bool = false) throws -> UInt64 {
        guard offset >= 0, length <= 8, offset <= count-length else { throw CommanderError.message("Abgeschnittener Binärkopf.") }
        var value: UInt64 = 0
        for i in 0..<length { value |= UInt64(bytes[offset+i]) << ((bigEndian ? length-i-1 : i)*8) }
        return value
    }
}
