import Foundation
import CryptoKit

public enum SettingsBackupStores {
    public static let state = "ZweiCommander.state.v1",beforeImport = "ZweiCommander.beforeSettingsImport",tools = "ZweiCommander.externalTools.v1"
    public static let titles:[String:String] = [
        state:"Tabs, Favoriten und Bedienung",beforeImport:"Stand vor dem INI-Import","ZweiCommander.appearance.v1":"Darstellung","ZweiCommander.toolbar.v1":"Werkzeugleiste","ZweiCommander.workspace.v1":"Favoriten und Ordneransichten","ZweiCommander.copyProfiles.v1":"Übertragungsprofile","ZweiCommander.renameProfiles.v1":"Umbenennungsprofile","ZweiCommander.searchProfiles.v1":"Suchprofile","ZweiCommander.compareProfiles.v1":"Vergleichsprofile","ZweiCommander.remoteProfiles.v1":"Serverprofile","ZweiCommander.tabGroups.v1":"Tabgruppen","ZweiCommander.layouts.v1":"Arbeitsbereiche","ZweiCommander.lastLayout.v1":"Letzte Fensteranordnung",tools:"Eigene Werkzeuge"
    ]
    public static let keys = titles.keys.sorted()
    public static func isLegacyBeforeImport(_ key:String) -> Bool { key != beforeImport && key.hasPrefix("ZweiCommander.before") && key.hasSuffix("Import") && key.utf8.count <= 240 }
}

public struct SettingsBackupDocument:Equatable {
    public static let maximumBytes = 48*1024*1024,maximumPayloadBytes = 32*1024*1024
    public let stores:[String:Data]
    public let createdAt:Date
    private struct Document:Codable { let format:String,version:Int,createdAt:Date,stores:[String:Data] }
    public typealias Validator = (String,Data) throws -> Void
    public init(stores:[String:Data],createdAt:Date = Date(),validator:Validator = SettingsBackupValidation.validate) throws {
        guard Set(stores.keys).isSubset(of:Set(SettingsBackupStores.keys)),createdAt.timeIntervalSinceReferenceDate.isFinite else { throw CommanderError.message("Die Sicherung enthält unbekannte Einstellungsbereiche.") }
        var count = 0
        for key in stores.keys.sorted() { let data = stores[key]!;guard data.count <= Self.maximumPayloadBytes-count else { throw CommanderError.message("Die Einstellungen sind zusammen größer als 32 MiB.") };count += data.count;try validator(key,data) }
        self.stores = stores;self.createdAt = createdAt
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys];let data = try encoder.encode(Document(format:"ZweiCommander.SettingsBackup",version:1,createdAt:createdAt,stores:stores))
        guard data.count <= Self.maximumBytes else { throw CommanderError.message("Die Sicherungsdatei ist größer als 48 MiB.") };return data
    }
    public static func decode(_ data:Data,validator:Validator = SettingsBackupValidation.validate) throws -> Self {
        let json = try SettingsBackupJSON.object(data)
        guard Set(json.keys) == Set(["format","version","createdAt","stores"]) else { throw CommanderError.message("Die Sicherungsdatei enthält unbekannte oder fehlende Kopffelder.") }
        let value = try JSONDecoder().decode(Document.self,from:data)
        guard value.format == "ZweiCommander.SettingsBackup",value.version == 1 else { throw CommanderError.message("Dieses Einstellungsformat oder diese Version wird nicht unterstützt. Vorhandene Einstellungen bleiben erhalten.") }
        return try Self(stores:value.stores,createdAt:value.createdAt,validator:validator)
    }
}

public enum SettingsBackupChange:String { case unchanged,add,replace,remove,repair
    public var title:String { switch self { case .unchanged:return "Unverändert";case .add:return "Übernehmen";case .replace:return "Ersetzen";case .remove:return "Auf Standard zurücksetzen";case .repair:return "Unlesbaren Bestand ersetzen" } }
}
public struct SettingsBackupReviewRow:Identifiable,Equatable {
    public var id:String { key };public let key:String,change:SettingsBackupChange,currentBytes:Int?,incomingBytes:Int?
    public var title:String { SettingsBackupStores.titles[key] ?? key }
}
public struct SettingsBackupRestorePlan {
    public let document:SettingsBackupDocument,expectedStateID:String,rows:[SettingsBackupReviewRow]
    public var changedCount:Int { rows.filter { $0.change != .unchanged }.count }
    public init(document:SettingsBackupDocument,current:[String:Data],invalidCurrent:Set<String> = [],expectedStateID:String) throws {
        guard Set(current.keys).isSubset(of:Set(SettingsBackupStores.keys)),invalidCurrent.isSubset(of:Set(SettingsBackupStores.keys)) else { throw CommanderError.message("Unbekannter aktueller Einstellungsbereich.") }
        self.document = document;self.expectedStateID = expectedStateID
        rows = SettingsBackupStores.keys.map { key in
            let before = current[key],after = document.stores[key]
            let change:SettingsBackupChange = invalidCurrent.contains(key) ? .repair : before == after ? .unchanged : before == nil ? .add : after == nil ? .remove : .replace
            return SettingsBackupReviewRow(key:key,change:change,currentBytes:before?.count,incomingBytes:after?.count)
        }
    }
}
