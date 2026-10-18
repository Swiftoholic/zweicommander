import AppKit
import CommanderCore

extension Preferences {
    static let copyProfilesKey = "ZweiCommander.copyProfiles.v1"
    static let copyProfilesChanged = Notification.Name("ZweiCommander.copyProfilesChanged")
    private static var testProfiles = CopyProfileLibrary()
    static var copyProfileTestDefaults: UserDefaults?
    private static var profileDefaults: UserDefaults? { testMode ? copyProfileTestDefaults : .standard }
    static func copyProfiles() throws -> CopyProfileLibrary {
        guard let defaults = profileDefaults else { return testProfiles }
        guard let data = defaults.data(forKey:copyProfilesKey) else { return CopyProfileLibrary() }
        return try CopyProfileLibrary(data:data)
    }
    @discardableResult static func editCopyProfiles<Value>(_ edit: (inout CopyProfileLibrary) throws -> Value) throws -> Value {
        var library = try copyProfiles()
        let result = try edit(&library),data = try library.encoded()
        if let defaults = profileDefaults { defaults.set(data,forKey:copyProfilesKey) }
        else { testProfiles = library }
        NotificationCenter.default.post(name:copyProfilesChanged,object:nil)
        return result
    }
}
