import Foundation

public enum SettingsBackupValidation {
    public static func validate(_ key:String,_ data:Data) throws { try validate(key,data,externalTools:nil) }
    public static func validate(_ key:String,_ data:Data,externalTools:((Data)throws->Data)?) throws {
        guard SettingsBackupStores.keys.contains(key) else { throw CommanderError.message("Unbekannter Einstellungsbereich.") }
        let original = try SettingsBackupJSON.object(data,maximumBytes:4*1024*1024)
        let encoded:Data
        switch key {
        case SettingsBackupStores.state,SettingsBackupStores.beforeImport:
            let normalized = try normalizeState(original);let value = try JSONDecoder().decode(BackupState.self,from:JSONSerialization.data(withJSONObject:normalized));try value.validate()
            encoded = try JSONEncoder().encode(value)
            try SettingsBackupJSON.rejectUnknownFields(original:normalized,encoded:try JSONSerialization.jsonObject(with:encoded));return
        case "ZweiCommander.copyProfiles.v1":encoded = try CopyProfileLibrary(data:data).encoded()
        case "ZweiCommander.renameProfiles.v1":encoded = try RenameProfileLibrary(data:data).encoded()
        case "ZweiCommander.searchProfiles.v1":encoded = try SearchProfileLibrary(data:data).encoded()
        case "ZweiCommander.compareProfiles.v1":encoded = try CompareProfileLibrary(data:data).encoded()
        case "ZweiCommander.remoteProfiles.v1":encoded = try RemoteProfileLibrary(data:data).encoded()
        case "ZweiCommander.workspace.v1":encoded = try WorkspaceLibrary.decode(data).encoded()
        case "ZweiCommander.tabGroups.v1":encoded = try TabGroupLibrary.decode(data).encoded()
        case "ZweiCommander.layouts.v1":encoded = try LayoutLibrary.decode(data).encoded()
        case "ZweiCommander.lastLayout.v1":encoded = try WorkspaceLayout.decode(data).encoded()
        case "ZweiCommander.appearance.v1":
            let value = try JSONDecoder().decode(BackupAppearance.self,from:data);try value.validate();encoded = try JSONEncoder().encode(value)
        case "ZweiCommander.toolbar.v1":
            let value = try JSONDecoder().decode(BackupToolbar.self,from:data);try value.validate();encoded = try JSONEncoder().encode(value)
        case SettingsBackupStores.tools:
            guard let externalTools else { throw CommanderError.message("Werkzeugdefinitionen können erst mit dem passenden Werkzeugleser geprüft werden.") };encoded = try externalTools(data)
        default:throw CommanderError.message("Unbekannter Einstellungsbereich.")
        }
        try SettingsBackupJSON.rejectUnknownFields(original:original,encoded:try JSONSerialization.jsonObject(with:encoded))
    }
    private static func normalizeState(_ source:[String:Any]) throws -> [String:Any] {
        var value = source
        if value["importedProfile"] == nil {
            let candidates = value.compactMap { key,raw -> (String,[String:Any])? in
                guard let profile = raw as? [String:Any],profile["sourceSHA256"] is String,profile["columns"] is [[String:Any]],profile["viewerShortcuts"] is [String:String] else { return nil };return (key,profile)
            }
            if candidates.count == 1,let (key,profile) = candidates.first { value.removeValue(forKey:key);value["importedProfile"] = profile }
        }
        return value
    }
    private struct BackupAppearance:Codable {
        let schemaVersion:Int,compact:Bool,fontSize:Int,toolbarLabels:Bool,importedColors:Bool
        func validate() throws { guard schemaVersion == 1,[0,10,11,12,13,14,16].contains(fontSize) else { throw CommanderError.message("Nicht unterstützte Darstellungseinstellungen.") } }
    }
    private struct BackupToolbar:Codable {
        let schemaVersion:Int,items:[String]
        func validate() throws {
            let known:Set<String> = ["back","forward","pack","extract","filter","tree","details","thumbnails","icons","search","compare","batchRename","quickView","refresh"]
            guard schemaVersion == 1,items.count == Set(items).count,Set(items).isSubset(of:known) else { throw CommanderError.message("Nicht unterstützte Werkzeugleisteneinstellungen.") }
        }
    }
    private struct BackupTab:Codable {
        let path:String,title:String?,locked:Bool,view:FolderViewSettings?,selected:Bool?,lockMode:TabLockMode?,filter:String?,filterRegex:Bool?
        func validate() throws {
            try LayoutTab.validatePath(path)
            if let title { guard title.utf8.count <= 240,!title.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw CommanderError.message("Ungültiger gespeicherter Tabname.") } }
            if let view { try view.validate() }
            if let lockMode { guard lockMode.preventsClosing == locked else { throw CommanderError.message("Tabsperre und Sperrart widersprechen sich.") } }
            if let filter { guard filter.utf8.count <= 4096,!filter.contains("\0") else { throw CommanderError.message("Ungültiger gespeicherter Tabfilter.") };_ = try NameFilter(filter,regex:filterRegex ?? false) }
        }
    }
    private struct BackupState:Codable {
        let left:[BackupTab],right:[BackupTab],favorites:[String],showHidden:Bool,vertical:Bool,theme:Int,shortcuts:[String:String],importedProfile:SettingsProfile?
        func validate() throws {
            guard left.count <= 1000,right.count <= 1000,favorites.count <= 200,(0...2).contains(theme),shortcuts.count <= 300 else { throw CommanderError.message("Gespeicherte Tabs oder Bedienungseinstellungen überschreiten die unterstützten Grenzen.") }
            for tab in left+right { try tab.validate() };for path in favorites { try LayoutTab.validatePath(path) }
            for pane in [left,right] { guard pane.filter({ $0.selected == true }).count <= 1 else { throw CommanderError.message("Mehrere aktive Tabs in derselben gespeicherten Seite.") } }
            for (key,value) in shortcuts {
                guard !key.isEmpty,key.utf8.count <= 120,key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),value.utf8.count <= 120,!value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw CommanderError.message("Ungültige gespeicherte Tastenkürzel.") }
            }
            if let profile = importedProfile { try SettingsBackupValidation.validateProfile(profile) }
        }
    }
    private static func validateProfile(_ value:SettingsProfile) throws {
        let columns:Set<String> = ["name","ext","size","modified","kind","attributes","permissions","path"]
        guard value.schemaVersion == 1,value.sourceSHA256.count == 64,value.sourceSHA256.allSatisfy({ $0.isHexDigit }),value.fontSize.isFinite,(8...48).contains(value.fontSize),
              value.columns.count <= 32,value.columns.allSatisfy({ columns.contains($0.id) && (1...1000).contains($0.characterWidth) && $0.title.utf8.count <= 1024 }),
              value.fileColors.count <= 1024,value.plugins.count <= 1024,value.notes.count <= 4096,value.shortcuts.count <= 300,value.viewerShortcuts.count <= 300,
              (1...20).contains(value.renameCounterDigits),(0...9).contains(value.zipCompressionLevel),(0...9).contains(value.sevenZipCompressionLevel),["zip","7z","tar.gz"].contains(value.defaultArchiveExtension),
              FolderViewSettings.columnIDs.contains(value.leftSort.key),FolderViewSettings.columnIDs.contains(value.rightSort.key) else { throw CommanderError.message("Die importierten Anzeigevorgaben besitzen unbekannte oder ungültige Werte.") }
        for color in [value.background,value.inactiveBackground,value.foreground].compactMap({ $0 })+value.fileColors.map(\.color) { guard [color.red,color.green,color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw CommanderError.message("Ungültige importierte Farbe.") } }
        for field in [value.colorScheme,value.fontName]+value.notes+value.plugins.flatMap({ [$0.name,$0.category]+$0.extensions })+value.fileColors.flatMap(\.patterns) {
            guard field.utf8.count <= 16_384,!field.contains("\0") else { throw CommanderError.message("Importierte Vorgaben enthalten zu lange oder ungültige Textfelder.") }
        }
        for (key,binding) in value.shortcuts.merging(value.viewerShortcuts,uniquingKeysWith:{ a,_ in a }) { guard key.utf8.count <= 120,binding.utf8.count <= 120,!key.contains("\0"),!binding.contains("\0") else { throw CommanderError.message("Ungültige importierte Tastenkürzel.") } }
    }
}
