import Foundation

public struct CopyProfile: Codable,Equatable,Identifiable {
    public let id: UUID
    public let name: String
    public let filter: TransferFilter
    public let policy: ConflictPolicy
    public let mergeFolders: Bool
}

public struct CopyProfileLibrary: Equatable {
    public private(set) var profiles: [CopyProfile] = []
    private struct Document: Codable { let version: Int;let profiles: [CopyProfile] }
    public init() {}
    public init(data: Data) throws {
        guard data.count <= 1_048_576 else { throw CommanderError.message("Profildatei ist größer als 1 MB.") }
        let document = try JSONDecoder().decode(Document.self,from:data)
        guard document.version == 1 else { throw CommanderError.message("Diese Version der Kopierprofile wird nicht unterstützt.") }
        try Self.validate(document.profiles);profiles = document.profiles
    }
    public func encoded() throws -> Data {
        try Self.validate(profiles)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version:1,profiles:profiles))
        guard data.count <= 1_048_576 else { throw CommanderError.message("Kopierprofile benötigen mehr als 1 MB.") }
        return data
    }
    public func profile(_ id: UUID) -> CopyProfile? { profiles.first { $0.id == id } }
    @discardableResult public mutating func save(name: String,filter: TransferFilter,policy: ConflictPolicy,mergeFolders: Bool,replacing id: UUID? = nil) throws -> UUID {
        let name = try Self.name(name)
        try filter.validate()
        if let id,profile(id) == nil { throw CommanderError.message("Das ausgewählte Profil wurde inzwischen entfernt.") }
        let id = id ?? UUID(),value = CopyProfile(id:id,name:name,filter:filter,policy:policy,mergeFolders:mergeFolders)
        var next = profiles.filter { $0.id != id };next.append(value)
        try Self.validate(next)
        profiles = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return id
    }
    @discardableResult public mutating func remove(_ id: UUID) throws -> CopyProfile {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw CommanderError.message("Das ausgewählte Profil wurde inzwischen entfernt.") }
        return profiles.remove(at:index)
    }
    private static func name(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !clean.isEmpty,clean.count <= 80,!clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CommanderError.message("Profilname: 1 bis 80 Zeichen, ohne Zeilenumbrüche oder Steuerzeichen.") }
        return clean
    }
    private static func validate(_ profiles: [CopyProfile]) throws {
        guard profiles.count <= 50 else { throw CommanderError.message("Höchstens 50 Kopierprofile speichern.") }
        var names: Set<String> = [],ids: Set<UUID> = []
        for profile in profiles {
            let clean = try name(profile.name)
            guard clean == profile.name else { throw CommanderError.message("Profilname hat ein ungültiges Format.") }
            let key = clean.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))
            guard names.insert(key).inserted else { throw CommanderError.message("Ein Profil mit diesem Namen ist bereits vorhanden.") }
            guard ids.insert(profile.id).inserted else { throw CommanderError.message("Kopierprofile enthalten doppelte Kennungen.") }
            try profile.filter.validate()
        }
    }
}
