import Foundation

public enum FileDiffMode:String,CaseIterable { case automatic,text,binary
    public var title:String { switch self { case .automatic:return "Automatisch";case .text:return "Text";case .binary:return "Binär nach Byteposition" } }
}
public enum FileDiffEncoding:String,CaseIterable { case automatic,utf8,utf16LE,utf16BE,windows1252,latin1
    public var title:String { switch self { case .automatic:return "Automatisch (UTF-8 / UTF-16 mit BOM)";case .utf8:return "UTF-8";case .utf16LE:return "UTF-16 Little Endian";case .utf16BE:return "UTF-16 Big Endian";case .windows1252:return "Windows-1252";case .latin1:return "ISO Latin-1" } }
}
public struct FileDiffOptions:Equatable {
    public var mode:FileDiffMode = .automatic,encoding:FileDiffEncoding = .automatic
    public var ignoreCase = false,ignoreWhitespace = false,ignoreLineEndings = true
    public init() {}
}
public struct FileDiffLimits {
    public let maximumBytes:Int,maximumLines:Int,maximumLineBytes:Int,maximumRows:Int,maximumWork:Int,maximumTraceCells:Int
    public init(maximumBytes:Int = 16*1024*1024,maximumLines:Int = 100_000,maximumLineBytes:Int = 256*1024,maximumRows:Int = 200_000,maximumWork:Int = 8_000_000,maximumTraceCells:Int = 2_000_000) {
        self.maximumBytes = maximumBytes;self.maximumLines = maximumLines;self.maximumLineBytes = maximumLineBytes;self.maximumRows = maximumRows;self.maximumWork = maximumWork;self.maximumTraceCells = maximumTraceCells
    }
    func validate() throws {
        guard (0...16*1024*1024).contains(maximumBytes),(1...100_000).contains(maximumLines),(1...256*1024).contains(maximumLineBytes),
              (1...200_000).contains(maximumRows),(1...8_000_000).contains(maximumWork),(1...2_000_000).contains(maximumTraceCells) else {
            throw CommanderError.message("Ungültige Grenzen für den Dateivergleich.")
        }
    }
}
public enum FileDiffKind:String { case equal,added,removed,changed
    public var title:String { switch self { case .equal:return "Gleich";case .added:return "Nur rechts";case .removed:return "Nur links";case .changed:return "Geändert" } }
}
/// Text positions are one-based line numbers; binary positions are zero-based byte offsets.
/// A binary row describes the entire aligned range and includes a bounded, labelled byte preview.
public struct FileDiffRow:Identifiable {
    public let id:Int,kind:FileDiffKind,leftPosition:Int?,rightPosition:Int?,leftLength:Int,rightLength:Int,leftText:String?,rightText:String?
    public let leftEnding:String?,rightEnding:String?
}
public struct FileDiffSource {
    public let url:URL,bytes:Int64,modified:Date
    let version:RenameVersion
    init(_ source:DiffFileSource) { url = source.url;version = source.version;bytes = Int64(version.size);modified = version.modified }
    public func validate() throws {
        guard try RenameVersion.read(url) == version else { throw CommanderError.message("Datei wurde seit dem Vergleich verändert: "+url.lastPathComponent) }
    }
}
public struct FileDiffResult {
    public let left:FileDiffSource,right:FileDiffSource,mode:FileDiffMode,options:FileDiffOptions,rows:[FileDiffRow]
    public let byteIdentical:Bool,leftLineCount:Int?,rightLineCount:Int?,differentBytes:Int?
    public var isEqual:Bool { rows.allSatisfy { $0.kind == .equal } }
    public var differenceStarts:[Int] { rows.indices.filter { rows[$0].kind != .equal && ($0 == 0 || rows[$0-1].kind == .equal) } }
    public var changedRows:Int { rows.filter { $0.kind == .changed }.count }
    public var addedRows:Int { rows.filter { $0.kind == .added }.count }
    public var removedRows:Int { rows.filter { $0.kind == .removed }.count }
    public func validateSources() throws { try left.validate();try right.validate() }
}
public enum FileDiffStage { case readingLeft,readingRight,comparing,finished
    public var title:String { switch self { case .readingLeft:return "Lese linke Datei …";case .readingRight:return "Lese rechte Datei …";case .comparing:return "Vergleiche Inhalte …";case .finished:return "Vergleich abgeschlossen" } }
}
public struct FileDiffProgress {
    public let stage:FileDiffStage,completedBytes:Int64,totalBytes:Int64
}

public enum FileDiffService {
    public static func compare(_ left:URL,_ right:URL,options:FileDiffOptions = .init(),limits:FileDiffLimits = .init(),token:CancellationToken = .init(),progress:(FileDiffProgress)->Void = {_ in}) throws -> FileDiffResult {
        try token.check();try limits.validate()
        let a = try DiffFileSource(left,limit:limits.maximumBytes),b = try DiffFileSource(right,limit:limits.maximumBytes)
        let total = Int64(a.version.size+b.version.size)
        let leftData = try a.read(token:token) { progress(.init(stage:.readingLeft,completedBytes:Int64($0),totalBytes:total)) }
        let rightData = try b.read(token:token) { progress(.init(stage:.readingRight,completedBytes:Int64(leftData.count+$0),totalBytes:total)) }
        try token.check();progress(.init(stage:.comparing,completedBytes:total,totalBytes:total));try token.check()
        let leftText = options.mode == .binary ? nil : decode(leftData,as:options.encoding),rightText = options.mode == .binary ? nil : decode(rightData,as:options.encoding)
        let actual:FileDiffMode = options.mode == .automatic ? (leftText != nil && rightText != nil ? .text : .binary) : options.mode
        let rows:[FileDiffRow],leftCount:Int?,rightCount:Int?,differentBytes:Int?
        if actual == .text {
            guard let leftText,let rightText else { throw CommanderError.message("Mindestens eine Datei ist mit der gewählten Kodierung kein gültiger Text. Kodierung ändern oder Binär wählen.") }
            let leftLines = try DiffTextLine.split(leftText,options:options,limits:limits,token:token),rightLines = try DiffTextLine.split(rightText,options:options,limits:limits,token:token)
            rows = try DiffTextAlgorithm.compare(leftLines,rightLines,limits:limits,token:token);leftCount = leftLines.count;rightCount = rightLines.count;differentBytes = nil
        } else {
            let result = try binary(leftData,rightData,limits:limits,token:token);rows = result.0;differentBytes = result.1;leftCount = nil;rightCount = nil
        }
        try token.check();try a.validate();try b.validate()
        let result = FileDiffResult(left:FileDiffSource(a),right:FileDiffSource(b),mode:actual,options:options,rows:rows,byteIdentical:leftData == rightData,leftLineCount:leftCount,rightLineCount:rightCount,differentBytes:differentBytes)
        progress(.init(stage:.finished,completedBytes:total,totalBytes:total));try token.check();try result.validateSources();return result
    }
    private static func decode(_ data:Data,as encoding:FileDiffEncoding) -> String? {
        var bytes = data,kind: String.Encoding
        switch encoding {
        case .automatic:
            if bytes.starts(with:[0xFF,0xFE]) { bytes.removeFirst(2);kind = .utf16LittleEndian }
            else if bytes.starts(with:[0xFE,0xFF]) { bytes.removeFirst(2);kind = .utf16BigEndian }
            else { if bytes.starts(with:[0xEF,0xBB,0xBF]) { bytes.removeFirst(3) };kind = .utf8 }
        case .utf8:if bytes.starts(with:[0xEF,0xBB,0xBF]) { bytes.removeFirst(3) };kind = .utf8
        case .utf16LE:guard !bytes.starts(with:[0xFE,0xFF]) else { return nil };if bytes.starts(with:[0xFF,0xFE]) { bytes.removeFirst(2) };kind = .utf16LittleEndian
        case .utf16BE:guard !bytes.starts(with:[0xFF,0xFE]) else { return nil };if bytes.starts(with:[0xFE,0xFF]) { bytes.removeFirst(2) };kind = .utf16BigEndian
        case .windows1252:kind = .windowsCP1252
        case .latin1:kind = .isoLatin1
        }
        if [.utf16LittleEndian,.utf16BigEndian].contains(kind),bytes.count % 2 != 0 { return nil }
        guard let text = String(data:bytes,encoding:kind),!text.unicodeScalars.contains(where:{$0.value == 0}) else { return nil };return text
    }
    private static func binary(_ a:Data,_ b:Data,limits:FileDiffLimits,token:CancellationToken) throws -> ([FileDiffRow],Int) {
        let left = [UInt8](a),right = [UInt8](b),count = max(a.count,b.count)
        var rows:[FileDiffRow] = [],start = 0,previous:FileDiffKind?,differences = 0
        func append(_ end:Int,_ kind:FileDiffKind) throws {
            guard rows.count < limits.maximumRows else { throw CommanderError.message("Zu viele Binärbereiche für die vollständige Ansicht. Die Ergebnisgrenze wurde erreicht; es wird kein Teilvergleich angezeigt.") }
            let l = max(0,min(end,left.count)-start),r = max(0,min(end,right.count)-start)
            func preview(_ values:[UInt8],_ length:Int) -> String? {
                guard length > 0 else { return nil };let amount = min(32,length),hex = values[start..<start+amount].map { String(format:"%02X",$0) }.joined(separator:" ")
                return hex+(length > amount ? " … [\(length) Bytes im Bereich]" : "")
            }
            rows.append(.init(id:rows.count,kind:kind,leftPosition:l > 0 ? start : nil,rightPosition:r > 0 ? start : nil,leftLength:l,rightLength:r,leftText:preview(left,l),rightText:preview(right,r),leftEnding:nil,rightEnding:nil))
        }
        for offset in 0..<count {
            if offset % 4096 == 0 { try token.check() }
            let kind:FileDiffKind = offset >= left.count ? .added : offset >= right.count ? .removed : left[offset] == right[offset] ? .equal : .changed
            if kind != .equal { differences += 1 }
            if let old = previous,old != kind { try append(offset,old);start = offset };previous = kind
        }
        if let previous { try append(count,previous) };try token.check();return (rows,differences)
    }
}
