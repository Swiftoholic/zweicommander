import Foundation

/// JSONSerialization keeps the last duplicate key; settings imports must reject ambiguity.
public enum SettingsBackupJSON {
    public static func object(_ data:Data,maximumBytes:Int = SettingsBackupDocument.maximumBytes) throws -> [String:Any] {
        guard data.count <= maximumBytes else { throw CommanderError.message("Die Einstellungsdatei überschreitet die Größenbegrenzung.") }
        var scanner = Scanner(bytes:Array(data));try scanner.value(depth:0);scanner.space()
        guard scanner.index == scanner.bytes.count,let value = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw CommanderError.message("Die Einstellungsdatei enthält kein eindeutiges JSON-Objekt.") };return value
    }
    /// Every supplied field must survive the typed codec. Optional absent fields stay absent.
    public static func rejectUnknownFields(original:Any,encoded:Any) throws {
        if let source = original as? [String:Any] {
            guard let target = encoded as? [String:Any],Set(source.keys).isSubset(of:Set(target.keys)) else { throw CommanderError.message("Die Einstellungsdatei enthält unbekannte oder nicht unterstützte Felder.") }
            for (key,value) in source { try rejectUnknownFields(original:value,encoded:target[key]!) }
        } else if let source = original as? [Any] {
            guard let target = encoded as? [Any],source.count == target.count else { throw CommanderError.message("Die Einstellungsdatei enthält nicht unterstützte Einträge.") }
            for (value,next) in zip(source,target) { try rejectUnknownFields(original:value,encoded:next) }
        }
    }
    private struct Scanner {
        let bytes:[UInt8];var index = 0,nodes = 0
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func value(depth:Int) throws {
            nodes += 1;guard depth <= 64,nodes <= 300_000 else { throw CommanderError.message("Die Einstellungsdatei ist zu tief verschachtelt oder enthält zu viele Werte.") };space()
            guard index < bytes.count else { throw malformed() }
            switch bytes[index] {
            case 123:
                index += 1;space();var keys = Set<String>()
                if consume(125) { return }
                while true {
                    space();let key = try string();guard keys.insert(key).inserted else { throw CommanderError.message("Die Einstellungsdatei enthält einen doppelten JSON-Schlüssel.") };space();guard consume(58) else { throw malformed() }
                    try value(depth:depth+1);space();if consume(125) { break };guard consume(44) else { throw malformed() }
                }
            case 91:
                index += 1;space();if consume(93) { return };while true { try value(depth:depth+1);space();if consume(93) { break };guard consume(44) else { throw malformed() } }
            case 34:_ = try string()
            case 116:try literal("true")
            case 102:try literal("false")
            case 110:try literal("null")
            default:
                let start = index
                while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw malformed() }
                let raw = Data(bytes[start..<index]);guard let number = try JSONSerialization.jsonObject(with:raw,options:.fragmentsAllowed) as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite else { throw malformed() }
            }
        }
        mutating func string() throws -> String {
            guard index < bytes.count,bytes[index] == 34 else { throw malformed() };let start = index;index += 1
            while index < bytes.count {
                let byte = bytes[index];index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self,from:Data(bytes[start..<index])) }
                if byte == 92 { guard index < bytes.count else { throw malformed() };index += 1 }
                else if byte < 32 { throw malformed() }
            }
            throw malformed()
        }
        mutating func literal(_ text:String) throws { for byte in text.utf8 { guard consume(byte) else { throw malformed() } } }
        mutating func consume(_ byte:UInt8) -> Bool { guard index < bytes.count,bytes[index] == byte else { return false };index += 1;return true }
        func malformed() -> CommanderError { .message("Die Einstellungsdatei ist kein vollständiges gültiges JSON.") }
    }
}
