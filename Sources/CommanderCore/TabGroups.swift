import Foundation

public struct TabGroupFolder: Codable, Equatable {
    public var path: String
    public var title: String?
    public var locked: Bool
    public var view: FolderViewSettings?

    public init(path: String, title: String? = nil, locked: Bool = false, view: FolderViewSettings? = nil) {
        self.path = path;self.title = title;self.locked = locked;self.view = view
    }
}

public struct TabGroupPane: Codable, Equatable {
    public var folders: [TabGroupFolder]
    public var selected: Int

    public init(folders: [TabGroupFolder], selected: Int = 0) {
        self.folders = folders;self.selected = selected
    }
}

public struct TabGroupProfile: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var left: TabGroupPane
    public var right: TabGroupPane

    public init(id: UUID = UUID(), name: String, left: TabGroupPane, right: TabGroupPane) {
        self.id = id;self.name = name;self.left = left;self.right = right
    }
}

public struct TabGroupLibrary: Codable, Equatable {
    public static let maximumBytes = 2 * 1024 * 1024
    public static let maximumGroups = 50
    public static let maximumFoldersPerPane = 100
    public static let maximumNameBytes = 240
    public static let maximumPathBytes = 16_384

    public private(set) var schemaVersion = 1
    public var groups: [TabGroupProfile] = []

    private struct Document: Codable {
        let schemaVersion: Int
        let groups: [TabGroupProfile]
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let document = try Document(from: decoder)
        schemaVersion = document.schemaVersion;groups = document.groups
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        try Document(schemaVersion: schemaVersion, groups: groups).encode(to: encoder)
    }

    public func validate() throws { _ = try validatedData() }

    public func encoded() throws -> Data { try validatedData() }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CommanderError.message("Die Tabgruppen-Datei ist größer als 2 MiB.") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public mutating func put(_ profile: TabGroupProfile) throws {
        var value = profile
        value.name = try Self.cleanName(profile.name)
        var next = self
        if let index = next.groups.firstIndex(where: { $0.id == value.id }) { next.groups[index] = value }
        else { next.groups.append(value) }
        try next.validate();self = next
    }

    public mutating func move(_ id: UUID, by offset: Int) throws {
        try validate()
        guard let source = groups.firstIndex(where: { $0.id == id }) else { throw CommanderError.message("Diese Tabgruppe wurde inzwischen entfernt.") }
        let target = source.addingReportingOverflow(offset)
        guard !target.overflow,groups.indices.contains(target.partialValue),source != target.partialValue else { return }
        var next = self
        let item = next.groups.remove(at: source)
        next.groups.insert(item, at: target.partialValue)
        try next.validate();self = next
    }

    private static func cleanName(_ name: String) throws -> String {
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CommanderError.message("Der Tabgruppenname darf keine Steuerzeichen enthalten.")
        }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !value.isEmpty,value.utf8.count <= maximumNameBytes else {
            throw CommanderError.message("Tabgruppenname: 1 bis 240 UTF-8-Bytes ohne äußere Leerzeichen.")
        }
        return value
    }

    private static func validate(_ pane: TabGroupPane) throws {
        guard !pane.folders.isEmpty,pane.folders.count <= maximumFoldersPerPane,pane.folders.indices.contains(pane.selected) else {
            throw CommanderError.message("Jede Seite benötigt 1 bis 100 Ordner und einen gültigen ausgewählten Tab.")
        }
        for folder in pane.folders {
            let path = folder.path
            guard path.hasPrefix("/"),path.utf8.count <= maximumPathBytes,!path.contains("\0") else {
                throw CommanderError.message("Ein vollständiger lokaler Ordnerpfad bis 16.384 UTF-8-Bytes wird benötigt.")
            }
            // Validate spelling only; a disconnected volume or missing folder is still a valid saved target.
            if path != "/" {
                let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                    throw CommanderError.message("Tabgruppen benötigen normalisierte Ordnerpfade ohne leere, . oder ..-Bestandteile.")
                }
            }
            if let title = folder.title {
                guard title.utf8.count <= maximumNameBytes,!title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw CommanderError.message("Tabtitel: höchstens 240 UTF-8-Bytes ohne Steuerzeichen.")
                }
            }
            try folder.view?.validate()
        }
    }

    private func validatedData() throws -> Data {
        guard schemaVersion == 1 else { throw CommanderError.message("Diese Version der Tabgruppen-Datei wird nicht unterstützt.") }
        guard groups.count <= Self.maximumGroups else { throw CommanderError.message("Höchstens 50 Tabgruppen speichern.") }
        var ids = Set<UUID>(),names = Set<String>(),payloadBytes = 0
        for profile in groups {
            let name = try Self.cleanName(profile.name)
            let key = name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
            guard name.utf8.elementsEqual(profile.name.utf8),ids.insert(profile.id).inserted,names.insert(key).inserted else {
                throw CommanderError.message("Tabgruppen benötigen bereinigte, eindeutige Namen und Kennungen.")
            }
            try Self.validate(profile.left);try Self.validate(profile.right)
            payloadBytes += name.utf8.count
            for folder in profile.left.folders + profile.right.folders {
                payloadBytes += folder.path.utf8.count + (folder.title?.utf8.count ?? 0)
            }
            guard payloadBytes <= Self.maximumBytes else { throw CommanderError.message("Die Tabgruppen-Datei ist größer als 2 MiB.") }
        }
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(Document(schemaVersion: schemaVersion, groups: groups))
        guard data.count <= Self.maximumBytes else { throw CommanderError.message("Die Tabgruppen-Datei ist größer als 2 MiB.") }
        return data
    }
}
