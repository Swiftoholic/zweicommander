import Foundation

/// Serializes metadata/credential changes and restores the prior state if either store fails.
public final class RemoteProfileStore {
    private let lock = NSLock()
    private let readData: () throws -> Data?,writeData: (Data) throws -> Void
    private let passwords: RemotePasswordStore
    public init(passwords: RemotePasswordStore,read: @escaping () throws -> Data?,write: @escaping (Data) throws -> Void) { self.passwords = passwords;readData = read;writeData = write }
    private func load() throws -> RemoteProfileLibrary { if let data = try readData() { return try RemoteProfileLibrary(data:data) };return RemoteProfileLibrary() }
    public func library() throws -> RemoteProfileLibrary { lock.lock();defer { lock.unlock() };return try load() }
    private func restore(_ value: String?,_ account: String) throws { if let value { try passwords.save(value,account:account) } else { try passwords.remove(account:account) } }
    @discardableResult public func save(name: String,connection: RemoteConnection,path: String,remember: Bool,password: String?,replacing old: RemoteProfile? = nil) throws -> RemoteProfile {
        lock.lock();defer { lock.unlock() }
        if let password { _ = try connection.authenticated(password) }
        var library = try load();let previous = library
        if let old { guard library.profile(old.id) == old else { throw CommanderError.message("Profil wurde in einem anderen Fenster verändert. Bitte neu auswählen.") } }
        let value = try library.save(name:name,connection:connection,path:path,usesKeychain:remember,replacing:old?.id)
        let bytes = try library.encoded(),previousBytes = try previous.encoded()
        let oldAccount = old?.usesKeychain == true ? old?.credentialAccount : nil,newAccount = value.credentialAccount
        var priorNew: String?,changedNew = false,metadataSaved = false
        do {
            if remember {
                priorNew = try passwords.password(account:newAccount)
                if let password,!password.isEmpty { try passwords.save(password,account:newAccount);changedNew = true }
                else { guard priorNew != nil else { throw CommanderError.message("Zum Speichern für diesen Server ein Passwort eingeben. Ein Passwort wird nicht auf einen anderen Server übertragen.") } }
            }
            try writeData(bytes);metadataSaved = true
            if let oldAccount,oldAccount != newAccount || !remember { try passwords.remove(account:oldAccount) }
            return value
        } catch {
            var rollback: [String] = []
            if metadataSaved { do { try writeData(previousBytes) } catch { rollback.append("Profildaten") } }
            if changedNew { do { try restore(priorNew,newAccount) } catch { rollback.append("neues Passwort") } }
            if !rollback.isEmpty { throw CommanderError.message("Speichern wurde angehalten; Wiederherstellung prüfen: "+rollback.joined(separator:", ")+". "+error.localizedDescription) }
            throw error
        }
    }
    public func remove(_ profile: RemoteProfile) throws {
        lock.lock();defer { lock.unlock() };var library = try load()
        guard library.profile(profile.id) == profile else { throw CommanderError.message("Verbindungsprofil wurde inzwischen verändert.") }
        _ = try library.remove(profile.id);let data = try library.encoded()
        let secret = profile.usesKeychain ? try passwords.password(account:profile.credentialAccount) : nil
        if profile.usesKeychain { try passwords.remove(account:profile.credentialAccount) }
        do { try writeData(data) }
        catch {
            let failure = error
            if profile.usesKeychain {
                do { try restore(secret,profile.credentialAccount) }
                catch { throw CommanderError.message("Profil konnte nicht entfernt werden; auch das Wiederherstellen seines Schlüsselbund-Eintrags ist fehlgeschlagen. Passwort beim nächsten Verbinden erneut eingeben. "+failure.localizedDescription) }
            }
            throw failure
        }
    }
    public func connection(_ connection: RemoteConnection,profile: RemoteProfile?,enteredPassword: String) throws -> RemoteConnection {
        let result = connection
        if !enteredPassword.isEmpty { return try connection.authenticated(enteredPassword) }
        guard let profile,profile.usesKeychain,try profile.connection().endpointID == connection.endpointID else { return result }
        lock.lock();defer { lock.unlock() }
        guard try load().profile(profile.id) == profile else { throw CommanderError.message("Gespeicherte Verbindung wurde inzwischen verändert.") }
        guard let value = try passwords.password(account:profile.credentialAccount) else { throw CommanderError.message("Passwort fehlt im Schlüsselbund. Bitte erneut eingeben.") }
        return try result.authenticated(value)
    }
}
