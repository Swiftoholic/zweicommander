import Foundation

public struct RemoteProfile: Codable,Equatable,Identifiable {
    public let id: UUID
    public let name: String
    public let kind: RemoteProtocol
    public let host: String,user: String,remotePath: String
    public let port: Int
    public let identityPath: String,caPath: String
    public let usesKeychain: Bool
    public func connection(password: String = "") throws -> RemoteConnection {
        try RemoteConnection(kind:kind,host:host,user:user,password:password,port:port,identityFile:identityPath.isEmpty ? nil : URL(fileURLWithPath:identityPath),caFile:caPath.isEmpty ? nil : URL(fileURLWithPath:caPath))
    }
    public var credentialAccount: String { id.uuidString+":"+((try? connection())?.endpointID ?? "invalid") }
}
public struct RemoteProfileLibrary: Equatable {
    public private(set) var profiles: [RemoteProfile] = []
    private struct Document: Codable { let version: Int;let profiles: [RemoteProfile] }
    public init() {}
    public init(data: Data) throws {
        guard data.count <= 1_048_576 else { throw CommanderError.message("Verbindungsprofile sind größer als 1 MB.") }
        let document = try JSONDecoder().decode(Document.self,from:data)
        guard document.version == 1 else { throw CommanderError.message("Unbekannte Version der Verbindungsprofile; Daten bleiben erhalten.") }
        try Self.validate(document.profiles);profiles = document.profiles
    }
    public func encoded() throws -> Data {
        try Self.validate(profiles);let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version:1,profiles:profiles))
        guard data.count <= 1_048_576 else { throw CommanderError.message("Zu viele Verbindungsdaten.") };return data
    }
    public func profile(_ id: UUID) -> RemoteProfile? { profiles.first { $0.id == id } }
    @discardableResult public mutating func save(name: String,connection: RemoteConnection,path: String,usesKeychain: Bool,replacing id: UUID? = nil) throws -> RemoteProfile {
        if let id,profile(id) == nil { throw CommanderError.message("Das Verbindungsprofil wurde entfernt.") }
        let value = RemoteProfile(id:id ?? UUID(),name:try Self.cleanName(name),kind:connection.kind,host:connection.host,user:connection.user,remotePath:try RemoteService.normalized(path),port:connection.port,identityPath:connection.identityFile?.path ?? "",caPath:connection.caFile?.path ?? "",usesKeychain:usesKeychain)
        var next = profiles.filter { $0.id != value.id };next.append(value);try Self.validate(next)
        profiles = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending };return value
    }
    @discardableResult public mutating func remove(_ id: UUID) throws -> RemoteProfile {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw CommanderError.message("Profil wurde bereits entfernt.") };return profiles.remove(at:index)
    }
    private static func cleanName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !value.isEmpty,value.count <= 80,!value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CommanderError.message("Profilname: 1 bis 80 Zeichen ohne Steuerzeichen.") };return value
    }
    private static func validate(_ profiles: [RemoteProfile]) throws {
        guard profiles.count <= 50,Set(profiles.map(\.id)).count == profiles.count else { throw CommanderError.message("Höchstens 50 eindeutige Verbindungsprofile speichern.") }
        var names: Set<String> = []
        for profile in profiles {
            guard try cleanName(profile.name) == profile.name,names.insert(profile.name.lowercased()).inserted,
                  try RemoteService.normalized(profile.remotePath) == profile.remotePath,
                  profile.kind != .sftp || !profile.usesKeychain else { throw CommanderError.message("Ungültige oder doppelte Verbindungsprofile.") }
            _ = try profile.connection()
            for path in [profile.identityPath,profile.caPath] where !path.isEmpty { guard path.hasPrefix("/") else { throw CommanderError.message("Schlüssel- und Zertifikatpfade müssen absolut sein.") } }
        }
    }
}
