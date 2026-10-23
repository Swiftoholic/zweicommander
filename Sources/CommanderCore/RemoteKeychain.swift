import Foundation
import Security
import LocalAuthentication

public protocol RemotePasswordStore {
    func password(account: String) throws -> String?
    func save(_ password: String,account: String) throws
    func remove(account: String) throws
}
public struct RemoteKeychain: RemotePasswordStore {
    private let service: String
    private let allowInteraction: Bool
    public init(service: String = "local.zweicommander.remote",allowInteraction: Bool = true) { self.service = service;self.allowInteraction = allowInteraction }
    private func query(_ account: String) -> [String:Any] {
        var query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecAttrSynchronizable as String:false]
        if !allowInteraction { let context = LAContext();context.interactionNotAllowed = true;query[kSecUseAuthenticationContext as String] = context }
        return query
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CommanderError.message("Schlüsselbund: "+((SecCopyErrorMessageString(status,nil) as String?) ?? "Zugriff fehlgeschlagen (\(status)).")) }
    }
    public func password(account: String) throws -> String? {
        var q = query(account);q[kSecReturnData as String] = true;q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?;let status = SecItemCopyMatching(q as CFDictionary,&value)
        if status == errSecItemNotFound { return nil };try check(status)
        guard let data = value as? Data,let password = String(data:data,encoding:.utf8) else { throw CommanderError.message("Gespeichertes Passwort ist nicht lesbar.") };return password
    }
    public func save(_ password: String,account: String) throws {
        let q = query(account),value = Data(password.utf8)
        let result = SecItemUpdate(q as CFDictionary,[kSecValueData as String:value] as CFDictionary)
        if result == errSecItemNotFound { var add = q;add[kSecValueData as String] = value;add[kSecAttrLabel as String] = "ZweiCommander · Verbindung";try check(SecItemAdd(add as CFDictionary,nil)) }
        else { try check(result) }
    }
    public func remove(account: String) throws { let status = SecItemDelete(query(account) as CFDictionary);if status != errSecItemNotFound { try check(status) } }
}
