import Foundation

public struct SavedTab: Codable {
    public var path:String,title:String?,locked:Bool,view:FolderViewSettings?,selected:Bool?
    public var lockMode:TabLockMode?,filter:String?,filterRegex:Bool?
    public var preservation:SessionFieldPreservation?
    public var explicitlyReplacedFields:Set<String> = []
    enum CodingKeys:String,CodingKey,CaseIterable { case path,title,locked,view,selected,lockMode,filter,filterRegex }
    public init(path:String,title:String?,locked:Bool,view:FolderViewSettings?,selected:Bool?,lockMode:TabLockMode? = nil,filter:String? = nil,filterRegex:Bool? = nil) {
        self.path = path;self.title = title;self.locked = locked;self.view = view;self.selected = selected;self.lockMode = lockMode;self.filter = filter;self.filterRegex = filterRegex
    }
    public init(from decoder:Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        path = try values.decode(String.self,forKey:.path);try LayoutTab.validatePath(path)
        locked = try values.decode(Bool.self,forKey:.locked)
        title = try? values.decode(String.self,forKey:.title)
        view = try? values.decode(FolderViewSettings.self,forKey:.view)
        if let value = view,(try? value.validate()) == nil { view = nil }
        selected = try? values.decode(Bool.self,forKey:.selected)
        lockMode = try? values.decode(TabLockMode.self,forKey:.lockMode)
        if let value = lockMode,value.preventsClosing != locked { lockMode = nil }
        filter = try? values.decode(String.self,forKey:.filter)
        filterRegex = try? values.decode(Bool.self,forKey:.filterRegex)
        if let value = filter,value.utf8.count > 4096 || value.contains("\0") || (try? NameFilter(value,regex:filterRegex ?? false)) == nil { filter = nil;filterRegex = nil }
    }
    /// Ordinary preference writes must use this projection, rather than dropping
    /// values the current UI only knows how to display with a compatible fallback.
    public func sessionJSON() throws -> SessionJSON {
        let current = try SessionJSON.parse(JSONEncoder().encode(self))
        return try preservation?.merged(with:current,explicitlyReplacing:explicitlyReplacedFields) ?? current
    }
    public func currentFieldPreservation() throws -> SessionFieldPreservation {
        let current = try SessionJSON.parse(JSONEncoder().encode(self))
        return try SessionFieldPreservation(original:current,baseline:current,knownFields:Set(CodingKeys.allCases.map(\.rawValue)))
    }
    mutating func retain(_ original:SessionJSON) throws {
        preservation = try SessionFieldPreservation(original:original,baseline:SessionJSON.parse(JSONEncoder().encode(self)),knownFields:Set(CodingKeys.allCases.map(\.rawValue)))
    }
}

public struct SavedState: Codable {
    public var left:[SavedTab] = [],right:[SavedTab] = [],favorites:[String] = []
    public var showHidden = false,vertical = true,theme = 0
    public var shortcuts:[String:String] = [:]
    public var importedProfile:SettingsProfile?
    public var preservation:SessionFieldPreservation?
    public var explicitlyReplacedFields:Set<String> = []
    enum CodingKeys:String,CodingKey,CaseIterable { case left,right,favorites,showHidden,vertical,theme,shortcuts,importedProfile }
    public init() {}
    public init(from decoder:Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        left = try values.decode([SavedTab].self,forKey:.left);right = try values.decode([SavedTab].self,forKey:.right)
        favorites = try values.decode([String].self,forKey:.favorites);showHidden = try values.decode(Bool.self,forKey:.showHidden)
        vertical = try values.decode(Bool.self,forKey:.vertical);theme = try values.decode(Int.self,forKey:.theme);shortcuts = try values.decode([String:String].self,forKey:.shortcuts)
        guard (0...2).contains(theme) else { throw CommanderError.message("Der gespeicherte Darstellungsmodus wird nicht unterstützt. Die Sitzung bleibt erhalten.") }
        importedProfile = try? values.decode(SettingsProfile.self,forKey:.importedProfile)
        if let profile = importedProfile,(try? SettingsBackupValidation.validateProfile(profile)) == nil { importedProfile = nil }
    }
    public var hasUnrecognizedData:Bool {
        preservation?.containsUnrecognizedData(ignoring:explicitlyReplacedFields.union(["left","right"])) == true || (left+right).contains { tab in
            tab.preservation?.containsUnrecognizedData(ignoring:(tab.preservation?.protectedFields ?? []).intersection(tab.explicitlyReplacedFields)) == true
        }
    }
    public static func decode(_ data:Data) throws -> SavedState {
        let parsed = try SessionJSON.parse(data)
        guard var fields = parsed.fields else { throw CommanderError.message("Die Sitzung enthält kein JSON-Objekt. Der bisherige Stand bleibt erhalten.") }
        // Older builds used a different property name for the same imported schema.
        // Move the complete opaque profile subtree, including future nested fields.
        if fields["importedProfile"] == nil {
            let candidates = fields.filter { _,node in
                guard let value = node.fields,value["sourceSHA256"].flatMap({ try? $0.decoded(String.self) }) != nil,
                      let columns = value["columns"]?.elements,columns.allSatisfy({ $0.fields != nil }),
                      let shortcuts = value["viewerShortcuts"]?.fields,shortcuts.values.allSatisfy({ (try? $0.decoded(String.self)) != nil }) else { return false };return true
            }
            if candidates.count == 1,let (key,profile) = candidates.first { fields.removeValue(forKey:key);fields["importedProfile"] = profile }
        }
        let normalized = SessionJSON.object(fields)
        var state = try JSONDecoder().decode(Self.self,from:normalized.encoded())
        for (side,raw) in [("left",fields["left"]?.elements),("right",fields["right"]?.elements)] {
            guard let raw else { continue }
            if side == "left" { for index in state.left.indices { try state.left[index].retain(raw[index]) } }
            else { for index in state.right.indices { try state.right[index].retain(raw[index]) } }
        }
        state.preservation = try SessionFieldPreservation(original:normalized,baseline:SessionJSON.parse(JSONEncoder().encode(state)),knownFields:Set(CodingKeys.allCases.map(\.rawValue)))
        return state
    }
    /// Encodes each tab with its own retention context before merging root fields.
    /// This remains correct when identical paths occur or tabs move between sides.
    public func encoded() throws -> Data {
        guard var fields = try SessionJSON.parse(JSONEncoder().encode(self)).fields else { throw CommanderError.message("Die Sitzung konnte nicht gespeichert werden.") }
        fields["left"] = .array(try left.map { try $0.sessionJSON() });fields["right"] = .array(try right.map { try $0.sessionJSON() })
        let current = SessionJSON.object(fields)
        return try (preservation?.merged(with:current,forceReplacing:explicitlyReplacedFields.union(["left","right"])) ?? current).encoded()
    }
}
