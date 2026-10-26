import Foundation
import Darwin
import CArchive

/// Validate metadata that libarchive's generic member model cannot expose.
enum ArchiveEditHeaders {
    static let maximumHeader = 16*1024*1024
    static func read(_ fd:Int32,offset:Int64,count:Int) throws -> [UInt8] {
        guard count >= 0,count <= maximumHeader,offset >= 0 else { throw error() }
        var value:[UInt8] = [];value.reserveCapacity(count);var done = 0
        while done < count {
            let count = min(128*1024,count-done)
            do { value += try ArchiveEditZip.bytes(fd,offset+Int64(done),count) } catch { throw Self.error() };done += count
        };return value
    }
    static func error() -> CommanderError { .message("Zusätzliche oder nicht prüfbare Archiv-Kopfdaten können beim Bearbeiten nicht unverändert erhalten werden.") }
    struct Cursor {
        let data:[UInt8];var index = 0
        var ended:Bool { index == data.count }
        mutating func byte() throws -> UInt8 { guard index < data.count else { throw ArchiveEditHeaders.error() };defer { index += 1 };return data[index] }
        mutating func take(_ count:Int) throws -> [UInt8] { guard count >= 0,count <= data.count-index else { throw ArchiveEditHeaders.error() };defer { index += count };return Array(data[index..<index+count]) }
        mutating func number(_ maximum:UInt64 = UInt64.max) throws -> UInt64 {
            let first = try byte();var mask:UInt8 = 0x80,result:UInt64 = 0
            for count in 0..<8 {
                if first & mask == 0 { result |= UInt64(first & (mask-1)) << (8*count);guard result <= maximum else { throw ArchiveEditHeaders.error() };return result }
                result |= UInt64(try byte()) << (8*count);mask >>= 1
            };guard result <= maximum else { throw ArchiveEditHeaders.error() };return result
        }
        mutating func defined(_ count:Int) throws -> [Bool] {
            let all = try byte();guard all == 0 || all == 1,count <= 100_000 else { throw ArchiveEditHeaders.error() }
            if all == 1 { return Array(repeating:true,count:count) };let bits = try take((count+7)/8)
            return (0..<count).map { bits[$0/8] & (0x80 >> ($0%8)) != 0 }
        }
        mutating func crcs(_ count:Int) throws -> [Bool] { let flags = try defined(count);_ = try take(flags.filter{$0}.count*4);return flags }
    }
    struct Streams {
        let packPosition:UInt64,packedSizes:[UInt64],unpackedSizes:[UInt64],coders:[([UInt8],[UInt8])],positionRange:Range<Int>
        let hasSubstreams:Bool,substreamCounts:[Int],groups:[[([UInt8],[UInt8])]]
    }
    static func streams(_ cursor:inout Cursor,token:CancellationToken) throws -> Streams {
        var id = try cursor.byte(),position:UInt64 = 0,packed:[UInt64] = [],outputs:[Int] = [],unpacked:[UInt64] = [],folderCrcs:[Bool] = [],methods:[([UInt8],[UInt8])] = [],groups:[[([UInt8],[UInt8])]] = [],positionRange = 0..<0
        if id == 6 {
            let start = cursor.index;position = try cursor.number();positionRange = start..<cursor.index
            let count = Int(try cursor.number(100_000));guard try cursor.byte() == 9 else { throw error() }
            for _ in 0..<count { try token.check();packed.append(try cursor.number()) }
            id = try cursor.byte();if id == 10 { _ = try cursor.crcs(count);id = try cursor.byte() };guard id == 0 else { throw error() };id = try cursor.byte()
        }
        if id == 7 {
            guard try cursor.byte() == 11 else { throw error() };let count = Int(try cursor.number(100_000));guard try cursor.byte() == 0 else { throw error() }
            for _ in 0..<count {
                try token.check();let coders = Int(try cursor.number(16));guard coders > 0 else { throw error() };var inputs = 0,output = 0,group:[([UInt8],[UInt8])] = []
                for _ in 0..<coders {
                    let flags = try cursor.byte(),length = Int(flags & 15);guard flags & 0xC0 == 0,length > 0,length <= 8 else { throw error() }
                    let method = try cursor.take(length),complex = flags & 0x10 != 0
                    inputs += complex ? Int(try cursor.number(64)) : 1;output += complex ? Int(try cursor.number(64)) : 1
                    let properties = flags & 0x20 != 0 ? try cursor.take(Int(cursor.number(1024))) : []
                    methods.append((method,properties));group.append((method,properties))
                }
                guard output > 0,inputs >= output else { throw error() }
                for _ in 0..<(output-1) { _ = try cursor.number(UInt64(inputs-1));_ = try cursor.number(UInt64(output-1)) }
                let packedCount = inputs-(output-1);if packedCount > 1 { for _ in 0..<packedCount { _ = try cursor.number(UInt64(inputs-1)) } };outputs.append(output);groups.append(group)
            }
            guard try cursor.byte() == 12 else { throw error() }
            for count in outputs { try token.check();for _ in 0..<count { unpacked.append(try cursor.number()) } }
            id = try cursor.byte();if id == 10 { folderCrcs = try cursor.crcs(outputs.count);id = try cursor.byte() } else { folderCrcs = Array(repeating:false,count:outputs.count) };guard id == 0 else { throw error() };id = try cursor.byte()
        }
        let hasSubstreams = id == 8;var substreamCounts = Array(repeating:1,count:outputs.count)
        if hasSubstreams {
            var counts = Array(repeating:1,count:outputs.count);id = try cursor.byte()
            if id == 13 { for index in counts.indices { counts[index] = Int(try cursor.number(100_000)) };id = try cursor.byte() }
            guard counts.reduce(0,+) <= 100_000 else { throw error() }
            substreamCounts = counts
            if id == 9 { for count in counts where count > 1 { for _ in 0..<(count-1) { _ = try cursor.number() } };id = try cursor.byte() }
            if id == 10 { let digestCount = counts.indices.reduce(0) { $0+(counts[$1] == 1 && folderCrcs[$1] ? 0 : counts[$1]) };_ = try cursor.crcs(digestCount);id = try cursor.byte() };guard id == 0 else { throw error() };id = try cursor.byte()
        }
        guard id == 0 else { throw error() };return Streams(packPosition:position,packedSizes:packed,unpackedSizes:unpacked,coders:methods,positionRange:positionRange,hasSubstreams:hasSubstreams,substreamCounts:substreamCounts,groups:groups)
    }
    static func validateCoders(_ info:Streams,maximumBytes:UInt64,token:CancellationToken) throws {
        guard info.unpackedSizes.allSatisfy({$0 <= maximumBytes}) else { throw error() }
        for group in info.groups {
            try token.check();var memory:UInt64 = 0
            for (method,properties) in group {
                let dictionary:UInt64
                if method == [3,1,1] { guard properties.count == 5,properties[0] <= 224 else { throw error() };dictionary = max(4096,ArchiveEditZip.u32(properties,1)) }
                else if method == [0x21] { guard properties.count == 1,properties[0] <= 28 else { throw error() };dictionary = UInt64(2 | Int(properties[0] & 1)) << (Int(properties[0])/2+11) }
                else if method == [0] { guard properties.isEmpty else { throw error() };dictionary = 0 }
                else if method == [3] { guard properties.count == 1 else { throw error() };dictionary = 0 }
                else if method == [3,3,1,3] { guard properties.isEmpty || properties.count == 4 else { throw error() };dictionary = 0 }
                else { throw error() }
                memory += dictionary;guard memory <= 64*1024*1024 else { throw error() }
            }
        }
    }
    static func crc(_ bytes:[UInt8]) -> UInt32 {
        var value:UInt32 = 0xFFFFFFFF
        for byte in bytes { value ^= UInt32(byte);for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1)^0xEDB88320 } };return value^0xFFFFFFFF
    }
    static func little(_ value:UInt64,_ count:Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded:value >> (8*$0)) } }
    static func number(_ value:UInt64) -> [UInt8] {
        for count in 0..<8 where value < (UInt64(1) << (7*(count+1))) {
            let first = UInt8(truncatingIfNeeded:value >> (8*count)) | UInt8(truncatingIfNeeded:0xFF << (8-count))
            return [first]+little(value,count)
        };return [255]+little(value,8)
    }
    static func sevenZip(_ file:ArchiveEditFile,maximumBytes:Int64,token:CancellationToken) throws {
        let prefix = try read(file.fd,offset:0,count:32),size = UInt64(file.version.size)
        guard Array(prefix.prefix(6)) == [0x37,0x7A,0xBC,0xAF,0x27,0x1C],prefix[6] == 0,prefix[7] <= 4 else { throw error() }
        let offset = ArchiveEditZip.u64(prefix,12),length = ArchiveEditZip.u64(prefix,20)
        guard size >= 32,offset <= size-32,length <= UInt64(maximumHeader),length == size-32-offset else { throw error() }
        let header = try read(file.fd,offset:Int64(offset+32),count:Int(length))
        guard header.first == 23 else { try plainSevenZip(header,maximumBytes:maximumBytes,token:token);return }
        var cursor = Cursor(data:header,index:1);let info = try streams(&cursor,token:token)
        guard cursor.ended,info.packedSizes.count == 1,info.unpackedSizes.count == 1,info.substreamCounts == [1],info.unpackedSizes[0] <= UInt64(maximumHeader),info.coders.count == 1,info.packedSizes[0] <= UInt64(maximumHeader),info.packPosition <= size-32,info.packedSizes[0] <= size-32-info.packPosition else { throw error() }
        try validateCoders(info,maximumBytes:UInt64(maximumHeader),token:token)
        let (method,properties) = info.coders[0]
        if method == [3,1,1] { guard properties.count == 5,ArchiveEditZip.u32(properties,1) <= 64*1024*1024 else { throw error() } }
        else if method == [0x21] { guard properties.count == 1,properties[0] <= 28 else { throw error() } }
        else { guard method == [0],properties.isEmpty else { throw error() } }
        // Wrap the encoded header stream as one synthetic 7z member, so the system decoder can
        // expose it without private decoder APIs, external tools, or a second codec dependency.
        var streams = Array(header.dropFirst());let range = (info.positionRange.lowerBound-1)..<(info.positionRange.upperBound-1);streams.replaceSubrange(range,with:[0]);if !info.hasSubstreams { streams.insert(contentsOf:[8,0],at:streams.count-1) }
        let encodedName:[UInt8] = Array("Header.bin\0".utf16).flatMap { little(UInt64($0),2) },name = [UInt8(0)]+encodedName
        let plain = [UInt8(1),4]+streams+[5,1,17]+number(UInt64(name.count))+name+[0,0]
        let packed = try read(file.fd,offset:Int64(32+info.packPosition),count:Int(info.packedSizes[0]))
        let start = little(UInt64(packed.count),8)+little(UInt64(plain.count),8)+little(UInt64(crc(plain)),4)
        let wrapper = Array(prefix.prefix(8))+little(UInt64(crc(start)),4)+start+packed+plain
        let decoded:[UInt8] = try wrapper.withUnsafeBytes { memory in
            guard let reader = archive_read_new() else { throw error() };defer { archive_read_free(reader) }
            archive_read_support_filter_all(reader);archive_read_support_format_all(reader)
            guard archive_read_open_memory(reader,memory.baseAddress,memory.count) == 0 else { throw error() };var entry:OpaquePointer?
            guard archive_read_next_header(reader,&entry) == 0 else { throw error() }
            var bytes:[UInt8] = [],buffer = [UInt8](repeating:0,count:64*1024)
            while true { try token.check();let count = archive_read_data(reader,&buffer,buffer.count);if count == 0 { break };guard count > 0,bytes.count+count <= maximumHeader else { throw error() };bytes += buffer.prefix(count) }
            guard bytes.count == Int(info.unpackedSizes[0]) else { throw error() };return bytes
        }
        try plainSevenZip(decoded,maximumBytes:maximumBytes,token:token)
    }
    static func plainSevenZip(_ bytes:[UInt8],maximumBytes:Int64,token:CancellationToken) throws {
        var cursor = Cursor(data:bytes);guard try cursor.byte() == 1 else { throw error() };var id = try cursor.byte()
        if id == 2 { guard try cursor.byte() == 0 else { throw error() };id = try cursor.byte() }
        guard id != 3 else { throw error() }
        if id == 4 { let info = try streams(&cursor,token:token);try validateCoders(info,maximumBytes:UInt64(maximumBytes),token:token);id = try cursor.byte() }
        if id == 0 { guard cursor.ended else { throw error() };return }
        guard id == 5 else { throw error() };let count = Int(try cursor.number(100_000));var properties:[UInt8:[UInt8]] = [:]
        while true { try token.check();let property = try cursor.byte();if property == 0 { break };let size = Int(try cursor.number(UInt64(maximumHeader)));guard properties[property] == nil else { throw error() };properties[property] = try cursor.take(size) }
        let empty = properties[14].map { values in (0..<count).filter { $0/8 < values.count && values[$0/8] & (0x80 >> ($0%8)) != 0 }.count } ?? 0
        for (property,value) in properties {
            var field = Cursor(data:value)
            switch property {
            case 14:guard value.count == (count+7)/8 else { throw error() };continue
            case 15:guard value.count == (empty+7)/8 else { throw error() };continue
            case 17:
                guard try field.byte() == 0 else { throw error() };let names = try field.take(value.count-1);guard names.count % 2 == 0,names.enumerated().filter({$0.offset % 2 == 0 && $0.element == 0 && names[$0.offset+1] == 0}).count == count else { throw error() }
            case 18,19,20,21:
                let present = try field.defined(count);guard try field.byte() == 0 else { throw error() }
                for _ in present.filter({$0}) {
                    let bytes = try field.take(property == 21 ? 4 : 8)
                    if property == 21 { guard ArchiveEditZip.u32(bytes,0) & 0xFFFF & ~UInt64(0x80B0) == 0 else { throw error() } }
                }
            case 25:guard value.allSatisfy({$0 == 0}) else { throw error() };continue
            default:throw error()
            }
            guard field.ended else { throw error() }
        }
        guard try cursor.byte() == 0,cursor.ended else { throw error() }
    }
    static func tarGzip(_ file:ArchiveEditFile,maximumBytes:Int64,token:CancellationToken) throws {
        let prefix = try ArchiveEditHeaders.read(file.fd,offset:0,count:10)
        guard Array(prefix.prefix(3)) == [0x1F,0x8B,8],prefix[3] & 0xFE == 0 else { throw error() }
        guard lseek(file.fd,0,SEEK_SET) == 0,let reader = archive_read_new() else { throw error() };defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader);archive_read_support_format_raw(reader)
        guard archive_read_open_fd(reader,file.fd,128*1024) == 0 else { throw error() };var entry:OpaquePointer?
        guard archive_read_next_header(reader,&entry) == 0 else { throw error() }
        func read(_ length:Int) throws -> [UInt8] {
            var bytes = [UInt8](repeating:0,count:length),done = 0
            while done < length { try token.check();let count = bytes.withUnsafeMutableBytes { archive_read_data(reader,$0.baseAddress!.advanced(by:done),length-done) };guard count > 0 else { throw error() };done += count };return bytes
        }
        func number(_ bytes:[UInt8]) throws -> Int64 {
            if bytes[0] & 0x80 != 0 { guard bytes[0] & 0x40 == 0 else { throw error() };var total:Int64 = Int64(bytes[0]&0x7F);for byte in bytes.dropFirst() { let product = total.multipliedReportingOverflow(by:256);let sum = product.partialValue.addingReportingOverflow(Int64(byte));guard !product.overflow,!sum.overflow else { throw error() };total = sum.partialValue };return total }
            let text = String(bytes:bytes.prefix(while:{$0 != 0}),encoding:.ascii)?.trimmingCharacters(in:.whitespaces) ?? "";guard let value = Int64(text.isEmpty ? "0" : text,radix:8),value >= 0 else { throw error() };return value
        }
        var total:Int64 = 0,records = 0,pendingSize:Int64?
        while true {
            try token.check();let header = try read(512)
            if header.allSatisfy({$0 == 0}) {
                guard try read(512).allSatisfy({$0 == 0}) else { throw error() };var padding = [UInt8](repeating:0,count:64*1024),count = 0
                while true { try token.check();let n = archive_read_data(reader,&padding,padding.count);if n == 0 { return };guard n > 0,padding.prefix(n).allSatisfy({$0 == 0}),count+n <= 1024*1024 else { throw error() };count += n }
            }
            records += 1;guard records <= 200_000 else { throw error() }
            let expected = try number(Array(header[148..<156])),sum = header.enumerated().reduce(Int64(0)) { $0+Int64((148..<156).contains($1.offset) ? 32 : $1.element) };guard expected == sum else { throw error() }
            guard Array(header[257..<265]) == Array("ustar\0".utf8)+[48,48],try number(Array(header[329..<337])) == 0,try number(Array(header[337..<345])) == 0 else { throw error() }
            let type = header[156];guard [UInt8(0),48,53,120,103,76].contains(type) else { throw error() }
            var size = try number(Array(header[124..<136]))
            if type == 120 || type == 103 || type == 76 {
                guard size <= 1024*1024 else { throw error() };let payload = try read(Int(size))
                if type == 76 { guard payload.count <= 16_385,String(bytes:payload.prefix(while:{$0 != 0}),encoding:.utf8) != nil else { throw error() } }
                else {
                    var position = 0
                    while position < payload.count {
                        guard let space = payload[position...].firstIndex(of:32),space-position <= 8,let length = Int(String(bytes:payload[position..<space],encoding:.ascii) ?? ""),length > space-position+2,length <= payload.count-position,payload[position+length-1] == 10,let record = String(bytes:payload[space+1..<position+length-1],encoding:.utf8),let equals = record.firstIndex(of:"=") else { throw error() }
                        let key = String(record[..<equals]),value = String(record[record.index(after:equals)...])
                        guard ["path","size","mtime","atime","ctime","uid","gid","uname","gname","SCHILY.mode","SCHILY.birthtime","LIBARCHIVE.creationtime"].contains(key) else { throw error() }
                        guard !value.contains("\0") else { throw error() }
                        if ["size","uid","gid"].contains(key) { guard !value.isEmpty,value.utf8.allSatisfy({(48...57).contains($0)}),let number = Int64(value),number >= 0 else { throw error() } }
                        if ["mtime","atime","ctime","SCHILY.birthtime","LIBARCHIVE.creationtime"].contains(key) {
                            let parts = value.split(separator:".",omittingEmptySubsequences:false)
                            guard (1...2).contains(parts.count),Int64(parts[0]) != nil else { throw error() }
                            if parts.count == 2 { guard (1...9).contains(parts[1].utf8.count),parts[1].utf8.allSatisfy({(48...57).contains($0)}) else { throw error() } }
                        }
                        if key == "SCHILY.mode" { guard !value.isEmpty,value.utf8.allSatisfy({(48...55).contains($0)}),let mode = UInt32(value,radix:8),mode <= 0o177777 else { throw error() } }
                        if key == "size" { guard type != 103,let value = Int64(value),value >= 0 else { throw error() };pendingSize = value };position += length
                    }
                }
            } else {
                if let pendingSize { size = pendingSize };pendingSize = nil
                let sum = total.addingReportingOverflow(size);guard !sum.overflow,sum.partialValue <= maximumBytes else { throw error() };total = sum.partialValue
                var remaining = size;while remaining > 0 { _ = try read(Int(min(remaining,64*1024)));remaining -= min(remaining,64*1024) }
            }
            let padding = Int((512-size%512)%512);if padding > 0 { guard try read(padding).allSatisfy({$0 == 0}) else { throw error() } }
        }
    }
}
