import AppKit
import CommanderCore

extension Preferences {
    static let compareProfilesKey = "ZweiCommander.compareProfiles.v1"
    static let compareProfilesChanged = Notification.Name("ZweiCommander.compareProfilesChanged")
    static var compareTestDefaults: UserDefaults?
    private static var testCompareProfiles = CompareProfileLibrary()
    private static var compareDefaults: UserDefaults? { testMode ? compareTestDefaults : .standard }
    static func compareProfiles() throws -> CompareProfileLibrary {
        guard let defaults = compareDefaults else { return testCompareProfiles }
        guard let object = defaults.object(forKey:compareProfilesKey) else { return CompareProfileLibrary() }
        guard let data = object as? Data else { throw CommanderError.message("Die gespeicherten Vergleichsprofile sind nicht lesbar. Vorhandene Daten bleiben erhalten.") }
        return try CompareProfileLibrary(data:data)
    }
    @discardableResult static func editCompareProfiles<Value>(_ edit: (inout CompareProfileLibrary) throws -> Value) throws -> Value {
        var library = try compareProfiles()
        let result = try edit(&library),data = try library.encoded()
        if let defaults = compareDefaults { defaults.set(data,forKey:compareProfilesKey) }
        else { testCompareProfiles = library }
        NotificationCenter.default.post(name:compareProfilesChanged,object:nil);return result
    }
}
