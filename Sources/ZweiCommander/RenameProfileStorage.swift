import AppKit
import CommanderCore

extension Preferences {
    static let renameProfilesKey = "ZweiCommander.renameProfiles.v1"
    static let renameProfilesChanged = Notification.Name("ZweiCommander.renameProfilesChanged")
    static var renameTestDefaults: UserDefaults?
    private static var testRenameProfiles = RenameProfileLibrary()
    private static var renameDefaults: UserDefaults? { testMode ? renameTestDefaults : .standard }
    static func renameProfiles() throws -> RenameProfileLibrary {
        guard let defaults = renameDefaults else { return testRenameProfiles }
        guard let object = defaults.object(forKey:renameProfilesKey) else { return RenameProfileLibrary() }
        guard let data = object as? Data else { throw CommanderError.message("Die gespeicherten Umbenennungsprofile sind nicht lesbar. Vorhandene Daten bleiben erhalten.") }
        return try RenameProfileLibrary(data:data)
    }
    @discardableResult static func editRenameProfiles<Value>(_ edit: (inout RenameProfileLibrary) throws -> Value) throws -> Value {
        var library = try renameProfiles()
        let result = try edit(&library),data = try library.encoded()
        if let defaults = renameDefaults { defaults.set(data,forKey:renameProfilesKey) }
        else { testRenameProfiles = library }
        NotificationCenter.default.post(name:renameProfilesChanged,object:nil);return result
    }
}
