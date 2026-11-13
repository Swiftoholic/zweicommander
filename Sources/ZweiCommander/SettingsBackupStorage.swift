import AppKit
import CommanderCore

final class SettingsBackupDefaultsDomain:SettingsBackupDomainStore {
    let defaults:UserDefaults,domainName:String
    init(_ defaults:UserDefaults,_ domainName:String) { self.defaults = defaults;self.domainName = domainName }
    func readDomain() throws -> [String:Any] { _ = defaults.synchronize();return defaults.persistentDomain(forName:domainName) ?? [:] }
    func replaceDomain(_ value:[String:Any]) throws {
        defaults.setPersistentDomain(value,forName:domainName)
        guard defaults.synchronize() else { throw CommanderError.message("Die wiederhergestellten Einstellungen konnten nicht dauerhaft bestätigt werden.") }
    }
}

final class SettingsBackupStorage {
    static var externalToolsCodec:((Data)throws->Data)?
    private static let mutationLock = NSRecursiveLock()
    private static var restoringFlag = false,restartFlag = false
    static var isRestoring:Bool {
        get { mutationLock.lock();defer { mutationLock.unlock() };return restoringFlag }
        set { mutationLock.lock();defer { mutationLock.unlock() };restoringFlag = newValue }
    }
    static var restartPending:Bool {
        get { mutationLock.lock();defer { mutationLock.unlock() };return restartFlag }
        set { mutationLock.lock();defer { mutationLock.unlock() };restartFlag = newValue }
    }
    static var persistenceSuspended:Bool { mutationLock.lock();defer { mutationLock.unlock() };return restoringFlag || restartFlag }
    /// Hold through the entire synchronous preference mutation, including credential bookkeeping.
    /// The returned closure must be called once on the same thread, normally with defer.
    static func beginSettingsMutation() throws -> ()->Void {
        mutationLock.lock()
        guard !restoringFlag,!restartFlag else { mutationLock.unlock();throw CommanderError.message("Einstellungen wurden wiederhergestellt. Vor weiteren Änderungen neu starten.") }
        return { mutationLock.unlock() }
    }
    static var onRestartRequested:(()->Void)?
    let domain:SettingsBackupDefaultsDomain,rollbackDirectory:URL,requiresRestart:Bool
    init(defaults:UserDefaults = .standard,domainName:String = "local.zweicommander.app",rollbackDirectory:URL? = nil,requiresRestart:Bool = true) {
        domain = SettingsBackupDefaultsDomain(defaults,domainName);self.requiresRestart = requiresRestart
        self.rollbackDirectory = rollbackDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ZweiCommander/SettingsBackups",isDirectory:true)
    }
    static func validate(_ key:String,_ data:Data) throws {
        try SettingsBackupValidation.validate(key,data,externalTools:externalToolsCodec)
        if key == SettingsBackupStores.state || key == SettingsBackupStores.beforeImport {
            guard let state = Preferences.decode(data) else { throw CommanderError.message("Der gespeicherte Sitzungsstand ist nicht lesbar.") }
            _ = try AppDelegate.shortcutOverrides(state.shortcuts.keys.sorted().map { $0+"="+state.shortcuts[$0]! }.joined(separator:"\n"))
        }
    }
    func exportDocument() throws -> SettingsBackupDocument {
        Self.mutationLock.lock();defer { Self.mutationLock.unlock() }
        let snapshot = try SettingsBackupCurrentSnapshot(domain:domain.readDomain())
        guard snapshot.invalidKeys.isEmpty else { throw CommanderError.message("Ein gespeicherter Einstellungsbereich ist nicht lesbar. Die Sicherung wurde nicht erstellt: "+snapshot.invalidKeys.sorted().compactMap { SettingsBackupStores.titles[$0] }.joined(separator:", ")) }
        return try SettingsBackupDocument(stores:snapshot.payloads,validator:Self.validate)
    }
    func read(_ url:URL,token:CancellationToken = .init()) throws -> SettingsBackupDocument { try SettingsBackupDocument.decode(SettingsBackupFile.read(url,token:token),validator:Self.validate) }
    func prepare(_ document:SettingsBackupDocument) throws -> SettingsBackupRestorePlan {
        Self.mutationLock.lock();defer { Self.mutationLock.unlock() }
        return try SettingsBackupTransaction.prepare(document,domain:domain.readDomain())
    }
    func restore(_ plan:SettingsBackupRestorePlan) throws -> SettingsBackupRestoreReceipt {
        Self.mutationLock.lock();defer { Self.mutationLock.unlock() }
        guard !Self.persistenceSuspended else { throw CommanderError.message("Eine Einstellungswiederherstellung ist bereits aktiv oder wartet auf den Neustart.") }
        // Validate again at the commit boundary; a preview never authorizes unchecked data.
        _ = try SettingsBackupDocument(stores:plan.document.stores,createdAt:plan.document.createdAt,validator:Self.validate)
        Self.isRestoring = true;defer { Self.isRestoring = false }
        do {
            let receipt = try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:{ [self] data in
                try FileManager.default.createDirectory(at:rollbackDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let stem = "Vor-Wiederherstellung-"+UUID().uuidString,url = rollbackDirectory.appendingPathComponent(stem+".plist")
                try SettingsBackupFile.writeNew(data,to:url)
                // A valid previous state also gets a normal, reviewable backup file.
                // The binary original remains even when old values cannot be imported.
                if let raw = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],let values = raw["values"] as? [String:Any] {
                    let snapshot = try SettingsBackupCurrentSnapshot(domain:values)
                    if snapshot.invalidKeys.isEmpty,let document = try? SettingsBackupDocument(stores:snapshot.payloads,validator:Self.validate) {
                        let readable = rollbackDirectory.appendingPathComponent(stem+".json");try SettingsBackupFile.writeNew(document.encoded(),to:readable);return readable
                    }
                }
                return url
            })
            if requiresRestart { Self.restartPending = true };return receipt
        } catch let failure as SettingsBackupRestoreFailure {
            if requiresRestart && !failure.rolledBack { Self.restartPending = true };throw failure
        }
    }
}

extension MainWindow {
    func showSettingsBackup() {
        guard !SettingsBackupStorage.persistenceSuspended else { SettingsBackupStorage.onRestartRequested?();return }
        guard canTerminate,pendingWork == 0 else { content.status.stringValue = "Laufende Vorgänge vor der Einstellungswiederherstellung abschließen.";return }
        saveState()
        let controller = SettingsBackupController(storage:SettingsBackupStorage(),canRestore:{ [weak self] in
            guard let self else { return false };return self.canTerminate && self.pendingWork == 0 && !self.left.pathField.sessionActive && !self.right.pathField.sessionActive && !self.left.inlineRename.isEditing && !self.right.inlineRename.isEditing
        })
        controller.onApplied = { [weak self] _ in self?.pendingLayoutSave?.cancel();self?.layoutPersistenceReady = false;self?.content.status.stringValue = "Einstellungen wiederhergestellt. Jetzt neu starten." }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
}
