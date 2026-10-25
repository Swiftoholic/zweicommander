import Foundation
import Darwin

public enum ViewerEncoding:String,CaseIterable {
    case automatic,utf8,utf16LE,utf16BE,windows1252,latin1
    public var title:String {
        switch self { case .automatic:return "Automatisch (BOM / UTF-8)";case .utf8:return "UTF-8";case .utf16LE:return "UTF-16 Little Endian";case .utf16BE:return "UTF-16 Big Endian";case .windows1252:return "Windows-1252";case .latin1:return "ISO Latin-1" }
    }
    func decode(_ data:Data) -> (String,Bool) {
        switch self {
        case .automatic,.utf8:return (String(decoding:data,as:UTF8.self),String(data:data,encoding:.utf8) == nil)
        case .utf16LE,.utf16BE:
            let bytes = Array(data),little = self == .utf16LE
            let units = stride(from:0,to:bytes.count-1,by:2).map { little ? UInt16(bytes[$0]) | UInt16(bytes[$0+1]) << 8 : UInt16(bytes[$0]) << 8 | UInt16(bytes[$0+1]) }
            let value = String(decoding:units,as:UTF16.self),valid = String(data:data,encoding:little ? .utf16LittleEndian : .utf16BigEndian) != nil
            return (value+((bytes.count%2 == 1) ? "�" : ""),!valid || bytes.count%2 == 1)
        case .latin1,.windows1252:
            let cp:[UInt32] = [0x20AC,0x81,0x201A,0x192,0x201E,0x2026,0x2020,0x2021,0x2C6,0x2030,0x160,0x2039,0x152,0x8D,0x17D,0x8F,0x90,0x2018,0x2019,0x201C,0x201D,0x2022,0x2013,0x2014,0x2DC,0x2122,0x161,0x203A,0x153,0x9D,0x17E,0x178]
            return (String(String.UnicodeScalarView(data.map { UnicodeScalar(self == .windows1252 && (0x80...0x9F).contains($0) ? cp[Int($0)-0x80] : UInt32($0))! })),false)
        }
    }
    func encode(_ text:String) throws -> Data {
        let encoding:String.Encoding
        switch self { case .automatic:throw CommanderError.message("Vor der Textsuche bitte die Dateikodierung bestimmen.");case .utf8:encoding = .utf8;case .utf16LE:encoding = .utf16LittleEndian;case .utf16BE:encoding = .utf16BigEndian;case .windows1252:encoding = .windowsCP1252;case .latin1:encoding = .isoLatin1 }
        guard let data = text.data(using:encoding,allowLossyConversion:false) else { throw CommanderError.message("Der Suchtext ist in dieser Kodierung nicht darstellbar.") };return data
    }
}

public struct ViewerByteWindow {
    public let data:Data,offset:Int64,fileSize:Int64
    public var end:Int64 { offset+Int64(data.count) }
}
public struct ViewerTextWindow {
    public let bytes:ViewerByteWindow,encoding:ViewerEncoding,text:String,hadDecodingErrors:Bool
    let content:Data,contentOffset:Int64
    public func range(for match:ViewerMatch) -> NSRange? {
        let lower = max(0,match.offset-contentOffset),upper = min(Int64(content.count),match.offset-contentOffset+Int64(match.length))
        guard upper > lower else { return nil }
        let prefix = encoding.decode(content.prefix(Int(lower))).0,body = encoding.decode(content[Int(lower)..<Int(upper)]).0
        return NSRange(location:(prefix as NSString).length,length:(body as NSString).length)
    }
}
public struct ViewerNeedle {
    public static let maximumBytes = 16*1024
    public let data:Data
    let alignment:Int64
    private init(bytes:Data,alignment:Int64) throws {
        guard !bytes.isEmpty,bytes.count <= Self.maximumBytes else { throw CommanderError.message("Suchmuster: 1 bis 16.384 Bytes verwenden.") };data = bytes;self.alignment = alignment
    }
    public init(bytes:Data) throws { try self.init(bytes:bytes,alignment:1) }
    public init(text:String,encoding:ViewerEncoding) throws { try self.init(bytes:encoding.encode(text),alignment:encoding == .utf16LE || encoding == .utf16BE ? 2 : 1) }
    public init(hex:String) throws {
        guard hex.utf8.count <= Self.maximumBytes*4 else { throw CommanderError.message("Das Hex-Suchmuster ist zu lang.") }
        let compact = hex.filter { !$0.isWhitespace }
        guard !compact.isEmpty,compact.count%2 == 0 else { throw CommanderError.message("Hexsuche benötigt vollständige Bytepaare, z. B. 48 65 6C 6C 6F.") }
        var data = Data();var cursor = compact.startIndex
        while cursor < compact.endIndex {
            let end = compact.index(cursor,offsetBy:2)
            guard let byte = UInt8(compact[cursor..<end],radix:16) else { throw CommanderError.message("Hexsuche erlaubt nur 0–9, A–F und Leerzeichen.") }
            data.append(byte);cursor = end
        }
        try self.init(bytes:data)
    }
}
public struct ViewerMatch:Equatable {
    public let offset:Int64,length:Int,wrapped:Bool
}
public enum ViewerSearchDirection { case forward,backward }

/// An immutable file identity with bounded reads. No reader follows a final link or opens a special file.
public final class ViewerFile:@unchecked Sendable {
    public static let maximumWindowBytes = 256*1024
    public let url:URL,size:Int64,modified:Date
    let descriptor:Int32,version:RenameVersion
    public init(_ url:URL) throws {
        guard url.isFileURL else { throw CommanderError.message("Die Vorschau benötigt eine lokale Datei.") }
        let path = url.standardizedFileURL,expected = try RenameVersion.read(path)
        guard expected.isRegularFile else { throw CommanderError.message("Text-, Hex- und Binärvorschau benötigen eine reguläre Datei ohne Verknüpfung.") }
        let fd = open(path.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
        guard fd >= 0 else { throw CommanderError.message("Die Datei kann nicht sicher geöffnet werden.") }
        var info = stat()
        guard fstat(fd,&info) == 0,RenameVersion(info) == expected else { close(fd);throw CommanderError.message("Die Datei wurde beim Öffnen verändert.") }
        self.url = path;size = expected.size;modified = expected.modified;descriptor = fd;version = expected
    }
    deinit { close(descriptor) }
    public func validate() throws {
        var info = stat()
        guard fstat(descriptor,&info) == 0,RenameVersion(info) == version,(try? RenameVersion.read(url)) == version else { throw CommanderError.message("Die Datei wurde verändert, verschoben oder ersetzt. Mit ⌘R neu laden.") }
    }
    func duplicatedHandle() throws -> FileHandle {
        try validate();let fd = dup(descriptor)
        guard fd >= 0 else { throw CommanderError.message("Die Datei kann nicht gelesen werden.") };return FileHandle(fileDescriptor:fd,closeOnDealloc:true)
    }
    public func read(offset:Int64,length:Int,token:CancellationToken = .init()) throws -> ViewerByteWindow {
        try token.check();try validate()
        guard offset >= 0,offset <= size,length >= 0,length <= Self.maximumWindowBytes else { throw CommanderError.message("Ungültiger Vorschauausschnitt oder Byteoffset.") }
        let count = min(length,Int(clamping:size-offset));var bytes = [UInt8](repeating:0,count:count),done = 0
        while done < count {
            try token.check()
            let amount = bytes.withUnsafeMutableBytes { pread(descriptor,$0.baseAddress!.advanced(by:done),min(64*1024,count-done),off_t(offset+Int64(done))) }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw CommanderError.message("Die Datei konnte nicht vollständig gelesen werden.") };done += amount
        }
        try token.check();try validate();return ViewerByteWindow(data:Data(bytes),offset:offset,fileSize:size)
    }
    public func resolvedEncoding(_ choice:ViewerEncoding,token:CancellationToken = .init()) throws -> ViewerEncoding {
        guard choice == .automatic else { return choice }
        let prefix = try read(offset:0,length:4,token:token).data
        if prefix.starts(with:[0xFF,0xFE]) { return .utf16LE };if prefix.starts(with:[0xFE,0xFF]) { return .utf16BE };return .utf8
    }
    public func textWindow(offset:Int64,length:Int,encoding choice:ViewerEncoding = .automatic,token:CancellationToken = .init()) throws -> ViewerTextWindow {
        guard length > 0,length <= Self.maximumWindowBytes-8,offset >= 0,offset <= size else { throw CommanderError.message("Ungültiger Textausschnitt.") }
        let encoding = try resolvedEncoding(choice,token:token),base = max(0,offset-4)
        let raw = try read(offset:base,length:min(Self.maximumWindowBytes,length+8),token:token),buffer = Array(raw.data)
        var start = Int(offset-base),end = min(buffer.count,start+length)
        if encoding == .utf8 {
            while start > 0,start < buffer.count,buffer[start]&0xC0 == 0x80 { start -= 1 }
            if end < buffer.count { while end > start,buffer[end]&0xC0 == 0x80 { end -= 1 } }
            if end == start { end = min(buffer.count,start+1);while end < buffer.count,buffer[end]&0xC0 == 0x80 { end += 1 } }
        } else if encoding == .utf16LE || encoding == .utf16BE {
            start -= Int((base+Int64(start))%2);end -= Int((base+Int64(end))%2)
            func unit(_ index:Int) -> UInt16? { guard index >= 0,index+1 < buffer.count else { return nil };return encoding == .utf16LE ? UInt16(buffer[index]) | UInt16(buffer[index+1]) << 8 : UInt16(buffer[index]) << 8 | UInt16(buffer[index+1]) }
            if let first = unit(start),first >= 0xDC00,first <= 0xDFFF,let previous = unit(start-2),previous >= 0xD800,previous <= 0xDBFF { start -= 2 }
            if let last = unit(end-2),last >= 0xD800,last <= 0xDBFF,let next = unit(end),next >= 0xDC00,next <= 0xDFFF { end -= 2 }
            if end <= start { end = min(buffer.count,start+2);if let first = unit(start),first >= 0xD800,first <= 0xDBFF { end = min(buffer.count,start+4) } }
            if base+Int64(end) == size-1 { end += 1 }
        }
        start = min(start,buffer.count);end = max(start,min(end,buffer.count))
        let actual = Data(buffer[start..<end]),position = base+Int64(start),window = ViewerByteWindow(data:actual,offset:position,fileSize:size)
        var bom = 0
        if position == 0 { if encoding == .utf8,actual.starts(with:[0xEF,0xBB,0xBF]) { bom = 3 };if (encoding == .utf16LE || encoding == .utf16BE),(actual.starts(with:[0xFF,0xFE]) || actual.starts(with:[0xFE,0xFF])) { bom = 2 } }
        let content = Data(actual.dropFirst(bom)),decoded = encoding.decode(content)
        return ViewerTextWindow(bytes:window,encoding:encoding,text:decoded.0,hadDecodingErrors:decoded.1,content:content,contentOffset:position+Int64(bom))
    }
    /// Exact byte search with fixed memory. Text needles use the explicitly resolved encoding.
    public func find(_ needle:ViewerNeedle,from offset:Int64,direction:ViewerSearchDirection = .forward,wrap:Bool = true,token:CancellationToken = .init(),progress:(Int64,Int64)->Void = { _,_ in }) throws -> ViewerMatch? {
        try token.check();try validate();guard offset >= 0,offset <= size else { throw CommanderError.message("Ungültiger Suchbeginn.") }
        let count = Int64(needle.data.count),lastStart = max(0,size-count+1),pivot = min(offset,lastStart)
        guard count <= size else { progress(size,size);try token.check();try validate();return nil }
        let ranges:[Range<Int64>] = direction == .forward ? [pivot..<lastStart,0..<pivot] : [0..<pivot,pivot..<lastStart]
        let pattern = Array(direction == .forward ? needle.data : Data(needle.data.reversed()))
        var prefix = [Int](repeating:0,count:pattern.count),matched = 0
        if pattern.count > 1 { for index in 1..<pattern.count { while matched > 0 && pattern[index] != pattern[matched] { matched = prefix[matched-1] };if pattern[index] == pattern[matched] { matched += 1 };prefix[index] = matched } }
        var scanned:Int64 = 0;let total = ranges.prefix(wrap ? 2 : 1).reduce(Int64(0)) { $0+($1.isEmpty ? 0 : $1.upperBound-$1.lowerBound+count-1) }
        for (phase,range) in ranges.prefix(wrap ? 2 : 1).enumerated() where !range.isEmpty {
            var cursor = direction == .forward ? range.lowerBound : range.upperBound+count-1;matched = 0
            while direction == .forward ? cursor < range.upperBound+count-1 : cursor > range.lowerBound {
                try token.check();let start = direction == .forward ? cursor : max(range.lowerBound,cursor-64*1024),end = direction == .forward ? min(range.upperBound+count-1,cursor+64*1024) : cursor
                let data = Array(try read(offset:start,length:Int(end-start),token:token).data)
                let positions = direction == .forward ? Array(data.indices) : Array(data.indices.reversed())
                for index in positions {
                    if index%4096 == 0 { try token.check() }
                    let byte = data[index]
                    while matched > 0 && byte != pattern[matched] { matched = prefix[matched-1] }
                    if byte == pattern[matched] { matched += 1 }
                    if matched == pattern.count {
                        let found = direction == .forward ? start+Int64(index)-count+1 : start+Int64(index)
                        if range.contains(found),found%needle.alignment == 0 { progress(scanned+Int64(data.count),total);try token.check();try validate();return ViewerMatch(offset:found,length:pattern.count,wrapped:phase > 0) }
                        matched = prefix[matched-1]
                    }
                }
                scanned += end-start;progress(scanned,total);cursor = direction == .forward ? end : start
            }
        }
        progress(total,total);try token.check();try validate();return nil
    }
}
