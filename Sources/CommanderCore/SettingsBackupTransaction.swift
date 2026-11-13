import Foundation
import CryptoKit
import CoreFoundation

/// The store replaces one complete preference domain in a single operation.
public protocol SettingsBackupDomainStore:AnyObject {
    func readDomain() throws -> [String:Any]
    func replaceDomain(_ value:[String:Any]) throws
}
public struct SettingsBackupCurrentSnapshot {
    public let payloads:[String:Data],invalidKeys:Set<String>,stateID:String
    fileprivate let owned:[String:Any]
    public init(domain:[String:Any]) throws {
        let keys = Set(SettingsBackupStores.keys),aliases = domain.keys.filter(SettingsBackupStores.isLegacyBeforeImport)
        guard aliases.count <= 16 else { throw CommanderError.message("Zu viele ältere Einstellungsablagen; vor der Wiederherstellung prüfen.") }
        owned = domain.filter { keys.contains($0.key) || SettingsBackupStores.isLegacyBeforeImport($0.key) }
        stateID = try Self.identifier(owned)
        var values:[String:Data] = [:],invalid = Set<String>()
        for key in keys {
            guard let object = domain[key] else { continue }
            if let data = object as? Data { values[key] = data } else { invalid.insert(key) }
        }
        if domain[SettingsBackupStores.beforeImport] == nil,!aliases.isEmpty {
            if aliases.count == 1,let value = domain[aliases[0]] as? Data { values[SettingsBackupStores.beforeImport] = value }
            else { invalid.insert(SettingsBackupStores.beforeImport) }
        }
        payloads = values;invalidKeys = invalid
    }
    static func identifier(_ owned:[String:Any]) throws -> String {
        var budget = SnapshotBudget();let value = try canonical(owned,depth:0,budget:&budget)
        let data = try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)
        guard data.count <= 64*1024*1024 else { throw CommanderError.message("Die aktuellen Einstellungsdaten sind zu groß.") }
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    private struct SnapshotBudget {
        var nodes = 0,bytes = 0
        mutating func consume(_ count:Int,depth:Int) throws {
            guard depth <= 64,nodes < 300_000,count >= 0,count <= SettingsBackupDocument.maximumPayloadBytes-bytes else { throw CommanderError.message("Die aktuellen Einstellungen sind zu tief verschachtelt oder zu groß.") };nodes += 1;bytes += count
        }
    }
    private static func canonical(_ value:Any,depth:Int,budget:inout SnapshotBudget) throws -> Any {
        try budget.consume(0,depth:depth)
        if let value = value as? Data { try budget.consume(value.count,depth:depth);return ["data":value.base64EncodedString()] }
        if let value = value as? Date { try budget.consume(16,depth:depth);guard value.timeIntervalSinceReferenceDate.isFinite else { throw CommanderError.message("Ungültiger Zeitpunkt in den aktuellen Einstellungen.") };return ["date":value.timeIntervalSinceReferenceDate] }
        if let value = value as? String { try budget.consume(value.utf8.count,depth:depth);return ["string":value] }
        if let value = value as? NSNumber {
            try budget.consume(64,depth:depth)
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return ["bool":value.boolValue] }
            guard value.doubleValue.isFinite else { throw CommanderError.message("Ungültige Zahl in den aktuellen Einstellungen.") };return ["number":String(cString:value.objCType)+":"+value.stringValue]
        }
        if let value = value as? [String:Any] {
            guard value.count <= 300_000-budget.nodes else { throw CommanderError.message("Zu viele Werte in den aktuellen Einstellungen.") }
            var rows:[[String:Any]] = []
            for key in value.keys.sorted() { try budget.consume(key.utf8.count,depth:depth);rows.append(["key":key,"value":try canonical(value[key]!,depth:depth+1,budget:&budget)]) };return rows
        }
        if let value = value as? [Any] {
            guard value.count <= 300_000-budget.nodes else { throw CommanderError.message("Zu viele Werte in den aktuellen Einstellungen.") }
            var rows:[Any] = [];for item in value { rows.append(try canonical(item,depth:depth+1,budget:&budget)) };return rows
        }
        throw CommanderError.message("Die aktuellen Einstellungen enthalten einen unbekannten Werttyp.")
    }
}
public struct SettingsBackupRestoreReceipt {
    public let rollbackURL:URL,restoredKeys:Int,resetKeys:Int
}
public struct SettingsBackupRestoreFailure:LocalizedError {
    public let detail:String,rollbackURL:URL?,rolledBack:Bool
    public var errorDescription:String? {
        detail+(rolledBack ? " Die bisherigen Einstellungen wurden vollständig wiederhergestellt." : " Die Änderung wurde angehalten; die lokale Sicherung des bisherigen Stands bleibt erhalten.")+(rollbackURL.map { "\nSicherung: "+$0.path } ?? "")
    }
}
public enum SettingsBackupTransaction {
    private static let lock = NSRecursiveLock()
    public static func prepare(_ document:SettingsBackupDocument,domain:[String:Any]) throws -> SettingsBackupRestorePlan {
        let before = try SettingsBackupCurrentSnapshot(domain:domain)
        return try SettingsBackupRestorePlan(document:document,current:before.payloads,invalidCurrent:before.invalidKeys,expectedStateID:before.stateID)
    }
    /// Rollback data includes the exact old owned values, including unreadable values; never credentials outside the owned catalog.
    public static func apply(_ plan:SettingsBackupRestorePlan,to store:SettingsBackupDomainStore,saveRollback:(Data)throws->URL,beforeCommit:()->Void = {}) throws -> SettingsBackupRestoreReceipt {
        lock.lock();defer { lock.unlock() }
        let before = try SettingsBackupCurrentSnapshot(domain:store.readDomain())
        guard before.stateID == plan.expectedStateID else { throw CommanderError.message("Die Einstellungen wurden seit der Vorschau geändert. Erneut prüfen; es wurde nichts übernommen.") }
        let rollback = try PropertyListSerialization.data(fromPropertyList:["format":"ZweiCommander.SettingsRollback","version":1,"values":before.owned],format:.binary,options:0)
        guard rollback.count <= 48*1024*1024 else { throw CommanderError.message("Die Sicherung des bisherigen Stands ist zu groß. Es wurde nichts übernommen.") }
        let rollbackURL = try saveRollback(rollback)
        beforeCommit()
        var latest = try store.readDomain()
        guard try SettingsBackupCurrentSnapshot(domain:latest).stateID == before.stateID else { throw CommanderError.message("Die Einstellungen wurden während der Sicherung geändert. Erneut prüfen; es wurde nichts übernommen.") }
        for key in latest.keys where SettingsBackupStores.keys.contains(key) || SettingsBackupStores.isLegacyBeforeImport(key) { latest.removeValue(forKey:key) }
        for (key,data) in plan.document.stores { latest[key] = data }
        let expected = try SettingsBackupCurrentSnapshot(domain:latest)
        do {
            try store.replaceDomain(latest)
            guard try SettingsBackupCurrentSnapshot(domain:store.readDomain()).stateID == expected.stateID else { throw CommanderError.message("Die gespeicherten Einstellungen stimmen nicht mit der geprüften Wiederherstellung überein.") }
        } catch {
            let originalError = error
            do {
                var current = try store.readDomain();let now = try SettingsBackupCurrentSnapshot(domain:current)
                // A failed whole-domain writer can leave either snapshot. Never overwrite new foreign values.
                for key in Set(now.owned.keys).union(before.owned.keys).union(expected.owned.keys) {
                    let value = now.owned[key]
                    guard equal(value,before.owned[key]) || equal(value,expected.owned[key]) else { throw CommanderError.message("Eine gleichzeitige Einstellungsänderung verhindert die automatische Rücksetzung.") }
                }
                for key in current.keys where SettingsBackupStores.keys.contains(key) || SettingsBackupStores.isLegacyBeforeImport(key) { current.removeValue(forKey:key) }
                for (key,value) in before.owned { current[key] = value }
                try store.replaceDomain(current)
                guard try SettingsBackupCurrentSnapshot(domain:store.readDomain()).stateID == before.stateID else { throw CommanderError.message("Der ursprüngliche Einstellungsstand konnte nicht vollständig bestätigt werden.") }
                throw SettingsBackupRestoreFailure(detail:originalError.localizedDescription,rollbackURL:rollbackURL,rolledBack:true)
            } catch let failure as SettingsBackupRestoreFailure { throw failure }
            catch { throw SettingsBackupRestoreFailure(detail:originalError.localizedDescription+"\n"+error.localizedDescription,rollbackURL:rollbackURL,rolledBack:false) }
        }
        return SettingsBackupRestoreReceipt(rollbackURL:rollbackURL,restoredKeys:plan.document.stores.count,resetKeys:SettingsBackupStores.keys.count-plan.document.stores.count)
    }
    private static func equal(_ a:Any?,_ b:Any?) -> Bool {
        if a == nil && b == nil { return true };guard let a,let b else { return false }
        guard let first = try? SettingsBackupCurrentSnapshot.identifier(["value":a]),let second = try? SettingsBackupCurrentSnapshot.identifier(["value":b]) else { return false };return first == second
    }
}
