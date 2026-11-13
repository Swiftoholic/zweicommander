import Foundation

public enum ExternalToolKind: String, Codable, CaseIterable { case executable, application }

public struct ExternalTool: Codable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var category: String
    public var kind: ExternalToolKind
    public var target: String
    public var arguments: [String]
    public var workingDirectory: String
    public var perSelection: Bool
    public var opensSelection: Bool
    public var showInToolbar: Bool
    public var shortcutSlot: Int?
    public var enabled: Bool
    public var timeoutSeconds: Int
    public init(id: UUID = UUID(), title: String, category: String = "", kind: ExternalToolKind = .executable, target: String, arguments: [String] = [], workingDirectory: String = "{active}", perSelection: Bool = false, opensSelection: Bool = false, showInToolbar: Bool = false, shortcutSlot: Int? = nil, enabled: Bool = true, timeoutSeconds: Int = 300) {
        self.id = id;self.title = title;self.category = category;self.kind = kind;self.target = target;self.arguments = arguments;self.workingDirectory = workingDirectory;self.perSelection = perSelection;self.opensSelection = opensSelection;self.showInToolbar = showInToolbar;self.shortcutSlot = shortcutSlot;self.enabled = enabled;self.timeoutSeconds = timeoutSeconds
    }
    public func validate() throws {
        guard Self.labelValid(title,maximum:240),category.isEmpty || Self.labelValid(category,maximum:120),
              target.hasPrefix("/"),target.utf8.count <= 16_384,!target.contains("\0"),URL(fileURLWithPath:target).standardizedFileURL.path == target,
              kind != .application || target.lowercased().hasSuffix(".app") && workingDirectory == "{active}",kind == .application || !opensSelection,
              arguments.count <= 128,arguments.allSatisfy({ $0.utf8.count <= 8192 && !$0.contains("\0") }),
              arguments.reduce(0,{ $0+$1.utf8.count }) <= 262_144,
              !workingDirectory.isEmpty,workingDirectory.utf8.count <= 4096,!workingDirectory.contains("\0"),
              shortcutSlot == nil || (1...9).contains(shortcutSlot!), (1...3600).contains(timeoutSeconds) else {
            throw CommanderError.message("Ungültiges Werkzeug. Name, Ziel, Argumente, Arbeitsordner und Kürzelplatz prüfen.")
        }
        for argument in arguments { _ = try ExternalToolTemplate.parse(argument,allowLists:true) }
        _ = try ExternalToolTemplate.parse(workingDirectory,allowLists:false)
    }
    private static func labelValid(_ value:String,maximum:Int) -> Bool {
        !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.utf8.count <= maximum && !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
}

public struct ExternalToolLibrary: Codable, Equatable {
    public private(set) var version = 1
    public var tools: [ExternalTool] = []
    public init(tools:[ExternalTool] = []) { self.tools = tools }
    public func validate() throws {
        guard version == 1 else { throw CommanderError.message("Diese Werkzeugdatei benötigt eine neuere Programmversion.") }
        guard tools.count <= 100,Set(tools.map(\.id)).count == tools.count,Set(tools.compactMap(\.shortcutSlot)).count == tools.compactMap(\.shortcutSlot).count else {
            throw CommanderError.message("Höchstens 100 Werkzeuge mit eindeutigen Kennungen und Kürzelplätzen sind möglich.")
        }
        for tool in tools { try tool.validate() }
    }
    public static func decode(_ data:Data) throws -> ExternalToolLibrary {
        guard data.count <= 1_048_576 else { throw CommanderError.message("Werkzeugdatei größer als 1 MiB.") }
        try ExternalToolJSON.check(data)
        let value = try JSONDecoder().decode(Self.self,from:data);try value.validate();return value
    }
    public func encoded() throws -> Data {
        try validate();let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 1_048_576 else { throw CommanderError.message("Werkzeugdatei größer als 1 MiB.") };return data
    }
    public mutating func put(_ tool:ExternalTool) throws {
        var next = self
        if let index = next.tools.firstIndex(where:{ $0.id == tool.id }) { next.tools[index] = tool } else { next.tools.append(tool) }
        try next.validate();self = next
    }
    public mutating func move(_ id:UUID,by offset:Int) {
        guard let source = tools.firstIndex(where:{ $0.id == id }) else { return }
        let target = source.addingReportingOverflow(offset);guard !target.overflow,tools.indices.contains(target.partialValue) else { return }
        tools.insert(tools.remove(at:source),at:target.partialValue)
    }
}

/// Checks duplicate keys before Foundation's JSON decoder can collapse them.
enum ExternalToolJSON {
    static func check(_ data:Data) throws {
        guard String(data:data,encoding:.utf8) != nil else { throw CommanderError.message("Werkzeugdateien müssen UTF-8 verwenden.") }
        let bytes = Array(data);var position = 0
        func failure() -> CommanderError { .message("Werkzeugdatei enthält unbekannte, doppelte oder ungültige Felder.") }
        func spaces() { while position < bytes.count && [9,10,13,32].contains(bytes[position]) { position += 1 } }
        func string() throws -> String {
            guard position < bytes.count,bytes[position] == 34 else { throw failure() };let start = position;position += 1
            while position < bytes.count {
                if bytes[position] == 34 { position += 1;return try JSONDecoder().decode(String.self,from:Data(bytes[start..<position])) }
                if bytes[position] == 92 { position += 1;guard position < bytes.count else { throw failure() } }
                position += 1
            }
            throw failure()
        }
        func value(_ depth:Int) throws {
            guard depth <= 8 else { throw failure() };spaces();guard position < bytes.count else { throw failure() }
            if bytes[position] == 34 { _ = try string();return }
            if bytes[position] == 123 {
                position += 1;spaces();var keys = Set<String>()
                if position < bytes.count,bytes[position] == 125 { position += 1;return }
                while true {
                    spaces();let key = try string();guard keys.insert(key).inserted else { throw failure() };spaces()
                    guard position < bytes.count,bytes[position] == 58 else { throw failure() };position += 1;try value(depth+1);spaces()
                    guard position < bytes.count else { throw failure() }
                    if bytes[position] == 125 { position += 1;return }
                    guard bytes[position] == 44 else { throw failure() };position += 1
                }
            }
            if bytes[position] == 91 {
                position += 1;spaces();if position < bytes.count,bytes[position] == 93 { position += 1;return }
                while true { try value(depth+1);spaces();guard position < bytes.count else { throw failure() };if bytes[position] == 93 { position += 1;return };guard bytes[position] == 44 else { throw failure() };position += 1 }
            }
            let start = position
            while position < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[position]) { position += 1 }
            guard position > start else { throw failure() }
        }
        spaces();guard position < bytes.count,bytes[position] == 123 else { throw failure() }
        try value(0);spaces();guard position == bytes.count else { throw failure() }
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(object.keys) == ["version","tools"],let tools = object["tools"] as? [[String:Any]] else { throw failure() }
        let required:Set<String> = ["id","title","category","kind","target","arguments","workingDirectory","perSelection","opensSelection","showInToolbar","enabled","timeoutSeconds"]
        for tool in tools { let keys = Set(tool.keys);guard required.isSubset(of:keys),keys.isSubset(of:required.union(["shortcutSlot"])) else { throw failure() } }
    }
}
