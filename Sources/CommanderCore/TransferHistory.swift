import Foundation
import Darwin
import CryptoKit

public enum RecoveryItemKind: String { case backup, partial }
public struct RecoveryItem: Identifiable {
    public let id: UUID
    public let kind: RecoveryItemKind
    public let original: URL,stored: URL
    public let source: URL?
    public let created: Date
    public let bytes: Int64,totalBytes: Int64
    public let available: Bool
    public let note: String
}
struct PartialCopy: Codable {
    let id: UUID,source: URL,target: URL,stage: URL,created: Date
    let parent: RenameVersion,sourceVersion: RenameVersion
    let signature: String,filter: TransferFilter,totalBytes: Int64
    let kind: TransferKind,policy: ConflictPolicy
    var owned: [String:RenameVersion]
}
struct SavedBackup: Codable {
    let id: UUID,original: URL,stored: URL,created: Date
    let parent: RenameVersion,version: RenameVersion
}
private struct HistoryDocument: Codable {
    var version = 1
    var partials: [PartialCopy] = []
    var backups: [SavedBackup] = []
    func validate() throws {
        guard version == 1,partials.count <= 200,backups.count <= 2000,
              Set(partials.map(\.id)+backups.map(\.id)).count == partials.count+backups.count else { throw recoveryError("Unbekannte, zu große oder doppelte Wiederherstellungsdaten.") }
        func local(_ url: URL) -> Bool {
            url.isFileURL && (url.host == nil || url.host == "") && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && url.path.hasPrefix("/") && !url.path.contains("\0") && url.path.utf8.count <= 32768 && url.path == url.standardizedFileURL.path
        }
        for item in partials {
            guard [item.source,item.target,item.stage].allSatisfy(local),item.stage.deletingLastPathComponent().path == item.target.deletingLastPathComponent().path,
                  item.stage.lastPathComponent == ".zweicommander-transfer-"+item.id.uuidString,
                  item.parent.isDirectory,item.owned[""] != nil,item.owned.count <= 2000,
                  item.signature.count == 64,item.totalBytes >= 0,item.created.timeIntervalSince1970.isFinite else { throw recoveryError("Ungültige Teilkopie.") }
            try item.filter.validate()
            for (path,version) in item.owned {
                guard path.isEmpty || (!path.hasPrefix("/") && !path.contains("\0") && !path.split(separator:"/",omittingEmptySubsequences:false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })),
                      version.isDirectory || version.isRegularFile else { throw recoveryError("Ungültiger Teilkopiepfad.") }
            }
        }
        for item in backups {
            guard [item.original,item.stored].allSatisfy(local),item.original.deletingLastPathComponent().path == item.stored.deletingLastPathComponent().path,
                  [".zweicommander-backup-",".zweicommander-move-"].contains(where: { item.stored.lastPathComponent.hasPrefix($0) }),
                  item.parent.isDirectory,item.created.timeIntervalSince1970.isFinite else { throw recoveryError("Ungültige Sicherung.") }
        }
    }
}
func recoveryError(_ message: String) -> CommanderError { .message("Wiederherstellung: "+message) }
func recoveryFDVersion(_ fd: Int32) throws -> RenameVersion {
    var value = stat();guard fstat(fd,&value) == 0 else { throw recoveryError("Dateiobjekt nicht lesbar.") };return RenameVersion(value)
}
func recoveryParent(_ url: URL,_ version: RenameVersion) throws -> Int32 {
    let parent = url.deletingLastPathComponent()
    let fd = open(parent.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
    guard fd >= 0 else { throw recoveryError("Datenträger oder Zielordner nicht verfügbar.") }
    do {
        guard try recoveryFDVersion(fd).sameObject(version),try RenameVersion.read(parent).sameObject(version) else { throw recoveryError("Elternordner wurde ersetzt oder verschoben.") }
        return fd
    } catch { close(fd);throw error }
}
public struct BackupRestorePlan {
    public let item: RecoveryItem
    public let replacesExisting: Bool
    let backup: SavedBackup
    let current: RenameVersion?
}

/// Local recovery metadata shares the transfer journal's private directory and lifetime lock.
public final class TransferHistory: @unchecked Sendable {
    let journal: TransferJournal
    private let lock = NSLock()
    private var document = HistoryDocument()
    private var active: Set<UUID> = []
    private var failure: String?
    public var persistenceError: String? { lock.lock();defer { lock.unlock() };return failure }
    public init(journal: TransferJournal) throws {
        self.journal = journal
        if let data = try journal.loadHistory() {
            do { document = try JSONDecoder().decode(HistoryDocument.self,from:data);try document.validate() }
            catch { throw recoveryError("Vorhandene Wiederherstellungsdaten bleiben unverändert: "+error.localizedDescription) }
        }
    }
    private func save(_ next: HistoryDocument) throws {
        if let failure { throw recoveryError(failure) }
        try next.validate();let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 16*1024*1024 else { throw recoveryError("Beschreibungsablage ist voll. Nicht mehr benötigte Einträge zuerst entfernen.") }
        do { try journal.saveHistory(data);document = next }
        catch { failure = error.localizedDescription;throw error }
    }
    private func checkStorage() throws {
        if let failure = persistenceError { throw recoveryError(failure) }
        do { try journal.checkHistory() }
        catch { lock.lock();failure = error.localizedDescription;lock.unlock();throw error }
    }
    public func inspect() -> [RecoveryItem] {
        lock.lock();let snapshot = document,inUse = active;lock.unlock()
        let partials = snapshot.partials.map { item -> RecoveryItem in
            var amount: Int64 = 0
            let valid = (try? RenameVersion.read(item.stage)).map { item.owned[""]!.sameObject($0) } == true && (try? RenameVersion.read(item.stage.deletingLastPathComponent())).map { item.parent.sameObject($0) } == true
            if valid {
                for (path,expected) in item.owned where expected.isRegularFile {
                    let url = path.isEmpty ? item.stage : item.stage.appendingPathComponent(path)
                    if let current = try? RenameVersion.read(url),expected.sameObject(current) { amount += max(0,current.size) }
                }
            }
            let available = valid && !inUse.contains(item.id)
            return RecoveryItem(id:item.id,kind:.partial,original:item.target,stored:item.stage,source:item.source,created:item.created,bytes:min(item.totalBytes,amount),totalBytes:item.totalBytes,available:available,note:inUse.contains(item.id) ? "Wird verwendet" : valid ? "Vor Fortsetzen vollständig prüfen" : "Datenträger fehlt oder Teilkopie verändert")
        }
        let backups = snapshot.backups.map { item -> RecoveryItem in
            let valid = (try? RenameVersion.read(item.stored)).map { item.version.sameAfterRename($0) } == true && (try? RenameVersion.read(item.stored.deletingLastPathComponent())).map { item.parent.sameObject($0) } == true
            return RecoveryItem(id:item.id,kind:.backup,original:item.original,stored:item.stored,source:nil,created:item.created,bytes:max(0,item.version.size),totalBytes:max(0,item.version.size),available:valid,note:valid ? (item.version.isDirectory ? "Ordnersicherung" : "Sicherung vorhanden") : "Datenträger fehlt, Sicherung verändert oder bereits verwendet")
        }
        return (partials+backups).sorted { $0.created > $1.created }
    }
    public func partialFilter(_ id: UUID) -> TransferFilter? { lock.lock();defer { lock.unlock() };return document.partials.first { $0.id == id }?.filter }
    public func partialIntent(_ id: UUID) -> TransferIntent? {
        lock.lock();defer { lock.unlock() }
        guard let item = document.partials.first(where: { $0.id == id }) else { return nil }
        return TransferIntent(sources:[item.source],destination:item.target.deletingLastPathComponent(),kind:item.kind,policy:item.policy,filter:item.filter)
    }
    func stageBackup(original: URL,stored: URL,version: RenameVersion? = nil) throws -> UUID {
        lock.lock();defer { lock.unlock() }
        if let old = document.backups.first(where: { $0.stored == stored }) { return old.id }
        let value = try version ?? RenameVersion.read(original)
        let item = SavedBackup(id:UUID(),original:original.standardizedFileURL,stored:stored.standardizedFileURL,created:Date(),parent:try RenameVersion.read(original.deletingLastPathComponent()),version:value)
        var next = document;next.backups.append(item);try save(next);return item.id
    }
    public func captureBackups(_ steps: [UndoStep]) throws {
        for step in steps {
            guard let stored = step.backup,FileSystem.exists(stored) else { continue }
            _ = try stageBackup(original:step.current,stored:stored,version:RenameVersion.read(stored))
        }
    }
    func forgetBackup(_ id: UUID) throws {
        lock.lock();defer { lock.unlock() };var next = document;next.backups.removeAll { $0.id == id };try save(next)
    }
    public func planRestore(_ id: UUID) throws -> BackupRestorePlan {
        lock.lock();let backup = document.backups.first { $0.id == id };lock.unlock()
        guard let backup else { throw recoveryError("Sicherung wurde entfernt.") }
        let fd = try recoveryParent(backup.stored,backup.parent);defer { close(fd) }
        guard try backup.version.sameAfterRename(RenameVersion.read(fd,backup.stored.lastPathComponent)) else { throw recoveryError("Sicherung wurde verändert.") }
        let current = FileSystem.exists(backup.original) ? try RenameVersion.read(fd,backup.original.lastPathComponent) : nil
        let item = RecoveryItem(id:backup.id,kind:.backup,original:backup.original,stored:backup.stored,source:nil,created:backup.created,bytes:max(0,backup.version.size),totalBytes:max(0,backup.version.size),available:true,note:"Vorheriger Inhalt wird wiederhergestellt")
        return BackupRestorePlan(item:item,replacesExisting:current != nil,backup:backup,current:current)
    }
    public func restore(_ plan: BackupRestorePlan,token: CancellationToken = .init()) throws {
        try token.check();try checkStorage();let item = plan.backup
        let fd = try recoveryParent(item.stored,item.parent);defer { close(fd) }
        guard try item.version.sameAfterRename(RenameVersion.read(fd,item.stored.lastPathComponent)) else { throw recoveryError("Sicherung wurde seit der Vorschau verändert.") }
        let current = FileSystem.exists(item.original) ? try RenameVersion.read(fd,item.original.lastPathComponent) : nil
        guard current == plan.current else { throw recoveryError("Aktuelles Ziel wurde seit der Vorschau verändert. Bitte erneut prüfen.") }
        var saved: URL?
        if let current {
            let next = item.original.deletingLastPathComponent().appendingPathComponent(".zweicommander-backup-"+UUID().uuidString)
            _ = try stageBackup(original:item.original,stored:next,version:current)
            guard renameatx_np(fd,item.original.lastPathComponent,fd,next.lastPathComponent,UInt32(RENAME_EXCL)) == 0 else { throw recoveryError("Aktueller Inhalt konnte nicht gesichert werden.") }
            saved = next
            guard try current.sameAfterRename(RenameVersion.read(fd,next.lastPathComponent)) else {
                _ = renameatx_np(fd,next.lastPathComponent,fd,item.original.lastPathComponent,UInt32(RENAME_EXCL))
                throw recoveryError("Aktueller Inhalt wurde beim Sichern verändert.")
            }
        }
        if renameatx_np(fd,item.stored.lastPathComponent,fd,item.original.lastPathComponent,UInt32(RENAME_EXCL)) != 0 {
            if let saved { _ = renameatx_np(fd,saved.lastPathComponent,fd,item.original.lastPathComponent,UInt32(RENAME_EXCL)) }
            throw recoveryError("Wiederherstellung angehalten. Sicherungen bleiben erhalten.")
        }
        try forgetBackup(item.id)
    }
    @discardableResult public func discard(_ id: UUID) throws -> URL? {
        try checkStorage()
        lock.lock();let partial = document.partials.first { $0.id == id },backup = document.backups.first { $0.id == id },busy = active.contains(id);lock.unlock()
        guard !busy else { throw recoveryError("Diese Teilkopie wird gerade verwendet.") }
        let stored: URL,parent: RenameVersion,expected: RenameVersion
        if let partial { stored = partial.stage;parent = partial.parent;expected = partial.owned[""]! }
        else if let backup { stored = backup.stored;parent = backup.parent;expected = backup.version }
        else { throw recoveryError("Eintrag nicht mehr vorhanden.") }
        let fd = try recoveryParent(stored,parent);defer { close(fd) }
        let current = try RenameVersion.read(fd,stored.lastPathComponent)
        guard partial != nil ? expected.sameObject(current) : expected.sameAfterRename(current) else { throw recoveryError("Dateiobjekt wurde verändert; es bleibt erhalten.") }
        var result: NSURL?
        try FileManager.default.trashItem(at:stored,resultingItemURL:&result)
        lock.lock();defer { lock.unlock() };var next = document;next.partials.removeAll { $0.id == id };next.backups.removeAll { $0.id == id };try save(next)
        return result.map { $0 as URL }
    }
    /// Removes only an unavailable description; never touches the filesystem.
    public func forgetUnavailable(_ id: UUID) throws {
        guard let item = inspect().first(where: { $0.id == id }),!item.available else { throw recoveryError("Vorhandene Daten zuerst ausdrücklich verwerfen.") }
        lock.lock();defer { lock.unlock() }
        guard !active.contains(id) else { throw recoveryError("Teilkopie wird verwendet.") }
        var next = document;next.partials.removeAll { $0.id == id };next.backups.removeAll { $0.id == id };try save(next)
    }
    func beginCopy(source: URL,target: URL,tree: CopyTree,kind: TransferKind,policy: ConflictPolicy,token: CancellationToken) throws -> ResumableCopy? {
        try checkStorage()
        let signature = try tree.recoverySignature(source,token:token)
        lock.lock();defer { lock.unlock() }
        if let old = document.partials.first(where: { $0.source == source.standardizedFileURL && $0.target == target.standardizedFileURL }) {
            guard !active.contains(old.id),old.signature == signature,old.kind == kind else { throw recoveryError("Quelle, Filter oder Auftragsart passen nicht mehr zur Teilkopie. Teilkopie in der Wiederherstellung prüfen oder verwerfen.") }
            let fd = try recoveryParent(old.stage,old.parent);defer { close(fd) }
            guard try old.owned[""]!.sameObject(RenameVersion.read(fd,old.stage.lastPathComponent)) else { throw recoveryError("Teilkopie wurde ersetzt.") }
            active.insert(old.id);return ResumableCopy(history:self,record:old)
        }
        guard tree.nodes.count <= 2000,tree.bytes >= 4*1024*1024,!tree.nodes.contains(where: \.link) else { return nil }
        let id = UUID(),parent = try RenameVersion.read(target.deletingLastPathComponent())
        let stage = target.deletingLastPathComponent().appendingPathComponent(".zweicommander-transfer-"+id.uuidString)
        let fd = try recoveryParent(stage,parent);defer { close(fd) }
        if tree.nodes.first?.directory == true {
            guard mkdirat(fd,stage.lastPathComponent,0o700) == 0 else { throw recoveryError("Teilkopieordner konnte nicht angelegt werden.") }
        } else {
            let file = openat(fd,stage.lastPathComponent,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard file >= 0 else { throw recoveryError("Teilkopie konnte nicht angelegt werden.") };close(file)
        }
        let record = PartialCopy(id:id,source:source.standardizedFileURL,target:target.standardizedFileURL,stage:stage,created:Date(),parent:parent,sourceVersion:try RenameVersion.read(source),signature:signature,filter:tree.filter,totalBytes:tree.bytes,kind:kind,policy:policy,owned:["":try RenameVersion.read(fd,stage.lastPathComponent)])
        var next = document;next.partials.append(record)
        do { try save(next) }
        catch { _ = unlinkat(fd,stage.lastPathComponent,tree.nodes.first?.directory == true ? AT_REMOVEDIR : 0);throw error }
        active.insert(id);return ResumableCopy(history:self,record:record)
    }
    func updateCopy(_ record: PartialCopy) throws {
        lock.lock();defer { lock.unlock() }
        guard let index = document.partials.firstIndex(where: { $0.id == record.id }) else { throw recoveryError("Teilkopieeintrag fehlt.") }
        var next = document;next.partials[index] = record;try save(next)
    }
    func finishCopy(_ id: UUID) throws {
        lock.lock();defer { lock.unlock() };var next = document;next.partials.removeAll { $0.id == id };try save(next)
    }
    func releaseCopy(_ id: UUID) { lock.lock();active.remove(id);lock.unlock() }
}

extension CopyTree {
    func recoverySignature(_ source: URL,token: CancellationToken) throws -> String {
        struct Item: Encodable { let path: String,version: RenameVersion }
        var hasher = SHA256();let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        for node in nodes {
            try token.check();let path = node.relative.isEmpty ? source : source.appendingPathComponent(node.relative)
            hasher.update(data:try encoder.encode(Item(path:node.relative,version:RenameVersion.read(path))))
        }
        return hasher.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
