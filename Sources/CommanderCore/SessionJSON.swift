import Foundation

/// A bounded JSON tree keeps opaque scalar tokens exact, including future numbers
/// that the current typed settings model cannot represent without rounding.
public indirect enum SessionJSON: Equatable {
    case object([String:SessionJSON]),array([SessionJSON]),scalar(Data)
    public static let maximumBytes = 4*1024*1024
    public static func parse(_ data:Data) throws -> SessionJSON {
        guard data.count <= maximumBytes else { throw failure("Die Sitzung ist größer als 4 MiB.") }
        var scanner = Scanner(bytes:Array(data));let result = try scanner.value(0);scanner.space()
        guard scanner.index == scanner.bytes.count else { throw failure("Die Sitzung enthält zusätzliche Daten.") };return result
    }
    public func encoded() throws -> Data {
        var data = Data();try append(to:&data);return data
    }
    public var fields:[String:SessionJSON]? { if case .object(let value) = self { return value };return nil }
    public var elements:[SessionJSON]? { if case .array(let value) = self { return value };return nil }
    public var isNull:Bool { self == .scalar(Data("null".utf8)) }
    public func decoded<T:Decodable>(_ type:T.Type) throws -> T { try JSONDecoder().decode(type,from:encoded()) }
    private func append(to data:inout Data) throws {
        switch self {
        case .scalar(let value):data.append(value)
        case .array(let values):
            data.append(91)
            for (index,value) in values.enumerated() { if index > 0 { data.append(44) };try value.append(to:&data) }
            data.append(93)
        case .object(let values):
            data.append(123)
            for (index,key) in values.keys.sorted().enumerated() {
                if index > 0 { data.append(44) };data.append(try JSONEncoder().encode(key));data.append(58);try values[key]!.append(to:&data)
            }
            data.append(125)
        }
        guard data.count <= Self.maximumBytes else { throw Self.failure("Die Sitzung ist größer als 4 MiB.") }
    }
    private static func failure(_ detail:String) -> CommanderError { .message(detail+" Der bisherige Sitzungsstand bleibt erhalten.") }
    private struct Scanner {
        let bytes:[UInt8];var index = 0,nodes = 0
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte:UInt8) -> Bool { guard index < bytes.count,bytes[index] == byte else { return false };index += 1;return true }
        mutating func value(_ depth:Int) throws -> SessionJSON {
            nodes += 1;guard depth <= 64,nodes <= 300_000 else { throw SessionJSON.failure("Die Sitzung ist zu tief verschachtelt oder enthält zu viele Werte.") };space()
            guard index < bytes.count else { throw malformed() }
            if take(123) {
                var fields:[String:SessionJSON] = [:];space();if take(125) { return .object(fields) }
                while true {
                    space();let raw = try string(),key = try JSONDecoder().decode(String.self,from:raw)
                    guard fields[key] == nil else { throw SessionJSON.failure("Die Sitzung enthält doppelte JSON-Schlüssel.") };space();guard take(58) else { throw malformed() }
                    fields[key] = try value(depth+1);space();if take(125) { return .object(fields) };guard take(44) else { throw malformed() }
                }
            }
            if take(91) {
                var values:[SessionJSON] = [];space();if take(93) { return .array(values) }
                while true { values.append(try value(depth+1));space();if take(93) { return .array(values) };guard take(44) else { throw malformed() } }
            }
            if bytes[index] == 34 { return .scalar(try string()) }
            let start = index
            for word in ["true","false","null"] where bytes[index] == word.utf8.first {
                for byte in word.utf8 { guard take(byte) else { throw malformed() } };return .scalar(Data(bytes[start..<index]))
            }
            _ = take(45)
            if take(48) { } else { guard index < bytes.count,(49...57).contains(bytes[index]) else { throw malformed() };digits() }
            if take(46) { guard index < bytes.count,(48...57).contains(bytes[index]) else { throw malformed() };digits() }
            if take(101) || take(69) { _ = take(43) || take(45);guard index < bytes.count,(48...57).contains(bytes[index]) else { throw malformed() };digits() }
            return .scalar(Data(bytes[start..<index]))
        }
        mutating func digits() { while index < bytes.count,(48...57).contains(bytes[index]) { index += 1 } }
        mutating func string() throws -> Data {
            guard take(34) else { throw malformed() };let start = index-1
            while index < bytes.count {
                let byte = bytes[index];index += 1
                if byte == 34 { let raw = Data(bytes[start..<index]);_ = try JSONDecoder().decode(String.self,from:raw);return raw }
                if byte == 92 { guard index < bytes.count else { throw malformed() };index += 1 }
                else if byte < 32 { throw malformed() }
            }
            throw malformed()
        }
        func malformed() -> CommanderError { SessionJSON.failure("Die Sitzung enthält kein vollständiges gültiges JSON.") }
    }
}

/// Retention belongs to a tab identity, never its current array index or path.
public struct SessionFieldPreservation {
    private let original:[String:SessionJSON],baseline:[String:SessionJSON],known:Set<String>
    public let protectedFields:Set<String>
    public var hasUnrecognizedData:Bool { containsUnrecognizedData() }
    public func containsUnrecognizedData(ignoring:Set<String> = []) -> Bool {
        original.contains { !ignoring.contains($0.key) && (protectedFields.contains($0.key) || !known.contains($0.key) || Self.hasExtra($0.value,baseline[$0.key])) }
    }
    public func containsUnrecognizedData(in field:String) -> Bool {
        original[field].map { protectedFields.contains(field) || Self.hasExtra($0,baseline[field]) } ?? false
    }
    public init(original:SessionJSON,baseline:SessionJSON,knownFields:Set<String>) throws {
        guard let source = original.fields,let typed = baseline.fields else { throw CommanderError.message("Ein Sitzungsobjekt wird benötigt.") }
        self.original = source;self.baseline = typed;known = knownFields
        protectedFields = Set(source.keys.filter { knownFields.contains($0) && !source[$0]!.isNull && typed[$0] == nil })
    }
    public func merged(with current:SessionJSON,explicitlyReplacing:Set<String> = [],forceReplacing:Set<String> = []) throws -> SessionJSON {
        guard var result = current.fields else { throw CommanderError.message("Ein Sitzungsobjekt wird benötigt.") }
        for (key,value) in original where !forceReplacing.contains(key) {
            if !known.contains(key) || (protectedFields.contains(key) && !explicitlyReplacing.contains(key)) { result[key] = value;continue }
            if protectedFields.contains(key),explicitlyReplacing.contains(key) { continue }
            if result[key] == baseline[key] { result[key] = value }
            else if let next = result[key] { result[key] = Self.merge(value,baseline[key],next) }
        }
        return .object(result)
    }
    /// Recover one explicitly replaced option without rolling back unrelated
    /// user edits, e.g. a pre-import view on a tab whose lock has since changed.
    public func restoringFields(_ fields:Set<String>,from previous:SessionFieldPreservation) throws -> Self {
        var source = original,typed = baseline
        for key in fields { source[key] = previous.original[key];typed[key] = previous.baseline[key] }
        return try Self(original:.object(source),baseline:.object(typed),knownFields:known)
    }
    private static func merge(_ original:SessionJSON,_ baseline:SessionJSON?,_ current:SessionJSON) -> SessionJSON {
        if baseline == current { return original }
        if let old = original.fields,let typed = baseline?.fields,var next = current.fields {
            for (key,value) in old {
                if typed[key] == nil { if next[key] == nil { next[key] = value };continue }
                if let current = next[key] { next[key] = merge(value,typed[key],current) }
            }
            return .object(next)
        }
        if let old = original.elements,let typed = baseline?.elements,let next = current.elements {
            // Column reordering must keep opaque metadata attached to its column ID.
            func identity(_ value:SessionJSON) -> String? { value.fields?["id"].flatMap { try? $0.decoded(String.self) } }
            let oldIDs = old.compactMap(identity),typedIDs = typed.compactMap(identity),nextIDs = next.compactMap(identity)
            if oldIDs.count == old.count,typedIDs.count == typed.count,nextIDs.count == next.count,Set(oldIDs).count == old.count,Set(typedIDs).count == typed.count,Set(nextIDs).count == next.count {
                let oldMap = Dictionary(uniqueKeysWithValues:zip(oldIDs,old)),typedMap = Dictionary(uniqueKeysWithValues:zip(typedIDs,typed))
                return .array(zip(nextIDs,next).map { id,value in oldMap[id].map { merge($0,typedMap[id],value) } ?? value })
            }
            if old.count == typed.count,typed.count == next.count { return .array(next.indices.map { merge(old[$0],typed[$0],next[$0]) }) }
        }
        return current
    }
    private static func hasExtra(_ original:SessionJSON,_ baseline:SessionJSON?) -> Bool {
        if let old = original.fields { guard let typed = baseline?.fields else { return !original.isNull };return old.contains { typed[$0.key] == nil || hasExtra($0.value,typed[$0.key]) } }
        if let old = original.elements,let typed = baseline?.elements,old.count == typed.count { return zip(old,typed).contains { hasExtra($0,$1) } }
        return false
    }
}
