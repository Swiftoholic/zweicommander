import AppKit
import CommanderCore

extension Preferences {
    static let searchProfilesKey = "ZweiCommander.searchProfiles.v1"
    static let searchProfilesChanged = Notification.Name("ZweiCommander.searchProfilesChanged")
    static var searchTestDefaults: UserDefaults?
    private static var testSearchProfiles = SearchProfileLibrary()
    private static var searchDefaults: UserDefaults? { testMode ? searchTestDefaults : .standard }
    static func searchProfiles() throws -> SearchProfileLibrary {
        guard let defaults = searchDefaults else { return testSearchProfiles }
        guard let object = defaults.object(forKey:searchProfilesKey) else { return SearchProfileLibrary() }
        guard let data = object as? Data else { throw CommanderError.message("Die gespeicherten Suchprofile sind nicht lesbar. Vorhandene Daten bleiben erhalten.") }
        return try SearchProfileLibrary(data:data)
    }
    @discardableResult static func editSearchProfiles<Value>(_ edit: (inout SearchProfileLibrary) throws -> Value) throws -> Value {
        var library = try searchProfiles()
        let result = try edit(&library),data = try library.encoded()
        if let defaults = searchDefaults { defaults.set(data,forKey:searchProfilesKey) }
        else { testSearchProfiles = library }
        NotificationCenter.default.post(name:searchProfilesChanged,object:nil);return result
    }
}
