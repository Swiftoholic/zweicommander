import Foundation

public struct CompareProfile: Codable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let options: CompareOptions
}
public struct CompareProfileLibrary: Equatable {
    public private(set) var profiles: [CompareProfile] = []
    private struct Document: Codable { let version: Int;let profiles: [CompareProfile] }
    public init() {}
    public init(data: Data) throws {
        guard data.count <= 1_048_576 else { throw CommanderError.message("Die Vergleichsprofile sind größer als 1 MiB.") }
        let document = try JSONDecoder().decode(Document.self,from:data)
        guard document.version == 1 else { throw CommanderError.message("Diese Version der Vergleichsprofile wird nicht unterstützt.") }
        try Self.validate(document.profiles);profiles = document.profiles
    }
    public func encoded() throws -> Data {
        try Self.validate(profiles);let data = try JSONEncoder().encode(Document(version:1,profiles:profiles))
        guard data.count <= 1_048_576 else { throw CommanderError.message("Die Vergleichsprofile sind größer als 1 MiB.") };return data
    }
    public func profile(_ id: UUID) -> CompareProfile? { profiles.first { $0.id == id } }
    @discardableResult public mutating func save(name: String,options: CompareOptions,replacing id: UUID? = nil) throws -> UUID {
        try options.validate()
        let name = try Self.clean(name)
        if let id,profile(id) == nil { throw CommanderError.message("Das ausgewählte Profil wurde inzwischen entfernt.") }
        let id = id ?? UUID(),value = CompareProfile(id:id,name:name,options:options)
        var next = profiles.filter { $0.id != id };next.append(value);try Self.validate(next)
        profiles = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending };return id
    }
    public mutating func remove(_ id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw CommanderError.message("Das Profil wurde bereits entfernt.") }
        profiles.removeAll { $0.id == id }
    }
    private static func clean(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !value.isEmpty,value.count <= 80,!value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CommanderError.message("Profilname: 1 bis 80 Zeichen ohne Steuerzeichen.") };return value
    }
    private static func validate(_ profiles: [CompareProfile]) throws {
        guard profiles.count <= 50 else { throw CommanderError.message("Höchstens 50 Vergleichsprofile speichern.") }
        var names = Set<String>(),ids = Set<UUID>()
        for profile in profiles {
            let name = try clean(profile.name)
            guard name == profile.name,ids.insert(profile.id).inserted,
                  names.insert(name.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))).inserted else { throw CommanderError.message("Ungültige oder doppelte Profilnamen/Kennungen.") }
            try profile.options.validate()
        }
    }
}
