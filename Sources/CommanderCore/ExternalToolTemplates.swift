import Foundation

enum ExternalToolTemplate {
    enum Part { case literal(String), variable(String) }
    static let scalars:Set<String> = ["active","inactive","focused","file","name","stem","ext"]
    static let lists:Set<String> = ["selection","names"]
    static func parse(_ text:String,allowLists:Bool) throws -> [Part] {
        guard !text.contains("\0"),text.utf8.count <= 8192 else { throw CommanderError.message("Ein Werkzeugargument ist zu lang oder enthält ein Nullzeichen.") }
        var parts:[Part] = [],literal = "",index = text.startIndex
        func flush() { if !literal.isEmpty { parts.append(.literal(literal));literal = "" } }
        while index < text.endIndex {
            let character = text[index],next = text.index(after:index)
            if character == "{" {
                if next < text.endIndex,text[next] == "{" { literal += "{";index = text.index(after:next);continue }
                flush();guard let end = text[next...].firstIndex(of:"}") else { throw CommanderError.message("Eine schließende Klammer im Werkzeugargument fehlt.") }
                let name = String(text[next..<end])
                guard scalars.contains(name) || allowLists && lists.contains(name) && text == "{"+name+"}" else {
                    throw CommanderError.message("Unbekannter Platzhalter oder Auswahlliste innerhalb eines Arguments: {"+name+"}")
                }
                parts.append(.variable(name));index = text.index(after:end);continue
            }
            if character == "}" {
                guard next < text.endIndex,text[next] == "}" else { throw CommanderError.message("Einzelne schließende Klammer im Werkzeugargument. Für eine Klammer }} verwenden.") }
                literal += "}";index = text.index(after:next);continue
            }
            literal.append(character);index = next
        }
        flush();return parts
    }
    static func expand(_ text:String,values:[String:String],lists:[String:[String]],allowLists:Bool) throws -> [String] {
        let parts = try parse(text,allowLists:allowLists)
        if parts.count == 1,case .variable(let name) = parts[0],Self.lists.contains(name) {
            guard let values = lists[name] else { throw CommanderError.message("Die Dateiauswahl ist für {"+name+"} nicht verfügbar.") };return values
        }
        var output = ""
        for part in parts {
            switch part {
            case .literal(let text):output += text
            case .variable(let name):guard let value = values[name] else { throw CommanderError.message("{\(name)} ist für die aktuelle lokale Auswahl nicht verfügbar.") };output += value
            }
            guard output.utf8.count <= 131_072 else { throw CommanderError.message("Ein expandiertes Werkzeugargument ist zu lang.") }
        }
        return [output]
    }
}

public enum ExternalToolArgumentLines {
    /// Each line is one argv element. Only these escapes are interpreted, never shell syntax.
    public static func decode(_ text:String) throws -> [String] {
        guard text.utf8.count <= 524_288,!text.contains("\0") else { throw CommanderError.message("Zu viele Werkzeugargumente.") }
        if text.isEmpty { return [] }
        let lines = text.components(separatedBy:"\n");guard lines.count <= 128 else { throw CommanderError.message("Höchstens 128 Argumente sind möglich.") }
        return try lines.map { line in
            if line == "\\e" { return "" }
            var result = "",escape = false
            for character in line {
                if escape {
                    switch character { case "n":result += "\n";case "r":result += "\r";case "t":result += "\t";case "\\":result += "\\";default:throw CommanderError.message("Ungültige Argumentmaskierung. Erlaubt sind \\n, \\r, \\t, \\\\ und eine Zeile \\e für ein leeres Argument.") };escape = false
                } else if character == "\\" { escape = true } else { result.append(character) }
            }
            guard !escape else { throw CommanderError.message("Ein Backslash am Argumentende muss als \\\\ geschrieben werden.") };return result
        }
    }
    public static func encode(_ arguments:[String]) -> String {
        arguments.map { value in
            if value.isEmpty { return "\\e" }
            return value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"\t",with:"\\t")
        }.joined(separator:"\n")
    }
}
