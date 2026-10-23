import Foundation
import Darwin

/// An intention to make a new plan, never a serialized executable plan.
public struct TransferIntent: Codable {
    public let sources: [URL]
    public let destination: URL
    public let kind: TransferKind
    public let policy: ConflictPolicy
    public let filter: TransferFilter
    public let mergeFolders: Bool
    init(sources: [URL],destination: URL,kind: TransferKind,policy: ConflictPolicy,filter: TransferFilter) {
        self.sources = sources;self.destination = destination;self.kind = kind;self.policy = policy;self.filter = filter;mergeFolders = false
    }
    public init(_ plan: TransferPlan) {
        sources = plan.entries.map(\.source);destination = plan.destination;kind = plan.kind
        policy = plan.policy;filter = plan.filter;mergeFolders = plan.merge != nil
    }
    public func validate() throws {
        guard !sources.isEmpty,sources.count <= 1000,Set(sources).count == sources.count else { throw journalError("Ungültige Quellauswahl.") }
        for url in sources+[destination] { try validateJournalURL(url) }
        try filter.validate()
        guard kind == .copy || (!mergeFolders && !filter.structureOnly) else { throw journalError("Ungültige Regeln für einen Verschiebeauftrag.") }
    }
}

public struct TransferJournalEntry: Codable, Identifiable {
    public var id: UUID { snapshot.id }
    public let intent: TransferIntent
    public var snapshot: WorkSnapshot
    public let created: Date
    public var updated: Date
    public var itemCount: Int
    public var restoredSnapshot: WorkSnapshot {
        var value = snapshot
        if !value.isFinished {
            value.state = .review
            value.detail = "Letzter gemeldeter Stand · "+snapshot.detail
        }
        return value
    }
}

private struct JournalDocument: Codable {
    var version = 1
    var entries: [TransferJournalEntry] = []
    func validate() throws {
        guard [1,2,3].contains(version) else { throw journalError("Diese Auftragsdatei hat eine unbekannte Version.") }
        guard version >= 2 || !entries.contains(where: { $0.intent.filter.modifiedAge != nil }) else { throw journalError("Relative Altersfilter benötigen die neue Auftragsversion.") }
        guard version >= 3 || !entries.contains(where: { $0.intent.kind == .move && $0.intent.filter.isActive }) else { throw journalError("Gefiltertes Verschieben benötigt die neue Auftragsversion.") }
        guard entries.count <= TransferJournal.maximumEntries,Set(entries.map(\.id)).count == entries.count else { throw journalError("Zu viele oder doppelte Aufträge.") }
        for entry in entries {
            try entry.intent.validate()
            let value = entry.snapshot
            guard entry.created.timeIntervalSince1970.isFinite,entry.updated.timeIntervalSince1970.isFinite,
                  value.title.utf8.count <= 4096,value.detail.utf8.count <= 16384,
                  value.items.count <= TransferJournal.maximumItems,entry.itemCount >= value.items.count,
                  value.fraction.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  value.transferredBytes.map({ $0 >= 0 }) ?? true,value.totalBytes.map({ $0 >= 0 }) ?? true,
                  Set(value.items.map(\.id)).count == value.items.count else { throw journalError("Ungültiger gespeicherter Fortschritt.") }
            for item in value.items {
                try validateJournalURL(item.source);try validateJournalURL(item.target)
                guard item.bytes >= 0,item.totalBytes >= 0,item.message.utf8.count <= 16384 else { throw journalError("Ungültiger Objektstand.") }
            }
        }
    }
}

private func journalError(_ message: String) -> CommanderError { .message("Aufträge konnten nicht sicher gespeichert werden. "+message) }
private func validateJournalURL(_ url: URL) throws {
    guard url.isFileURL,url.host == nil || url.host == "",url.user == nil,url.password == nil,
          url.query == nil,url.fragment == nil,url.path.hasPrefix("/"),!url.path.contains("\0"),
          url.path.utf8.count <= 32768 else { throw journalError("Ungültiger lokaler Dateipfad.") }
}
private struct JournalFileVersion: Equatable {
    let device: dev_t,inode: ino_t,size: off_t,mode: mode_t
    let seconds: Int,nanoseconds: Int,changedSeconds: Int,changedNanoseconds: Int
    init(_ value: stat) {
        device = value.st_dev;inode = value.st_ino;size = value.st_size;mode = value.st_mode
        seconds = value.st_mtimespec.tv_sec;nanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec;changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

/// Private, atomically replaced local storage. One writer owns the lock for its lifetime.
public final class TransferJournal: @unchecked Sendable {
    public static let maximumEntries = 200
    public static let maximumItems = 200
    private static let maximumBytes = 16*1024*1024
    public static var defaultDirectory: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("ZweiCommander",isDirectory:true).appendingPathComponent("Transfers",isDirectory:true)
    }
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("journal.json") }
    private let lock = NSLock()
    private var dirFD: Int32 = -1,lockFD: Int32 = -1
    private var directoryVersion: JournalFileVersion?
    private var diskVersion: JournalFileVersion?
    private var historyVersion: JournalFileVersion?
    private var historyLoaded = false
    private var document = JournalDocument()
    private var lastWrite = Date.distantPast

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        do {
            try validateJournalURL(self.directory)
            if !FileSystem.exists(self.directory) {
                try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            }
            dirFD = open(self.directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            var value = stat()
            guard dirFD >= 0,fstat(dirFD,&value) == 0,value.st_uid == getuid(),(value.st_mode & S_IFMT) == S_IFDIR else { throw journalError("Der private Ablageordner ist nicht verfügbar.") }
            guard fchmod(dirFD,0o700) == 0 else { throw journalError("Der Ablageordner lässt sich nicht schützen.") }
            directoryVersion = JournalFileVersion(value)
            lockFD = openat(dirFD,".journal.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard lockFD >= 0,fstat(lockFD,&value) == 0,isPrivateRegular(value),fchmod(lockFD,0o600) == 0 else { throw journalError("Die Sperrdatei ist nicht sicher verfügbar.") }
            guard flock(lockFD,LOCK_EX|LOCK_NB) == 0 else { throw journalError("Eine weitere App-Instanz verwendet die Auftragsablage.") }
            let data = try readDisk()
            if let data {
                do { document = try JSONDecoder().decode(JournalDocument.self,from:data);try document.validate() }
                catch { throw journalError("Die vorhandene Auftragsdatei bleibt unverändert: "+error.localizedDescription) }
            }
        } catch { closeFiles();throw error }
    }
    deinit { closeFiles() }
    private func closeFiles() { if lockFD >= 0 { Darwin.close(lockFD);lockFD = -1 };if dirFD >= 0 { Darwin.close(dirFD);dirFD = -1 } }
    public var entries: [TransferJournalEntry] { lock.lock();defer { lock.unlock() };return document.entries }
    public func entry(_ id: UUID) -> TransferJournalEntry? { lock.lock();defer { lock.unlock() };return document.entries.first { $0.id == id } }

    public func stage(_ intent: TransferIntent,snapshot: WorkSnapshot,replacing id: UUID? = nil) throws {
        lock.lock();defer { lock.unlock() }
        var next = document
        guard snapshot.state == .waiting,!next.entries.contains(where: { $0.id == snapshot.id }) else { throw journalError("Der neue Auftrag ist nicht eindeutig.") }
        let now = Date(),entry = TransferJournalEntry(intent:intent,snapshot:bounded(snapshot),created:now,updated:now,itemCount:snapshot.items.count)
        if let id {
            guard let index = next.entries.firstIndex(where: { $0.id == id }) else { throw journalError("Der vorherige Auftrag wurde entfernt.") }
            next.entries[index] = entry
        } else { next.entries.append(entry) }
        try save(next)
    }
    public func remove(_ ids: Set<UUID>) throws {
        lock.lock();defer { lock.unlock() }
        var next = document;next.entries.removeAll { ids.contains($0.id) }
        if next.entries.count != document.entries.count { try save(next) }
    }
    public func synchronize(_ snapshots: [WorkSnapshot]) throws {
        lock.lock();defer { lock.unlock() }
        try validateDirectory()
        guard try currentDiskVersion() == diskVersion else { throw journalError("Die Auftragsdatei wurde außerhalb der App verändert; sie bleibt unverändert.") }
        let current = Dictionary(uniqueKeysWithValues:snapshots.map { ($0.id,$0) })
        var next = document,important = false,changed = false
        for index in next.entries.indices {
            guard let snapshot = current[next.entries[index].id],snapshot.state != .review else { continue }
            let old = next.entries[index].snapshot,new = bounded(snapshot)
            // A state boundary is durable immediately; byte-only updates are bounded to four writes/sec.
            let boundary = old.state != new.state || zip(old.items,new.items).contains { $0.state != $1.state || ($0.bytes == 0 && $1.bytes > 0) } || old.items.count != new.items.count || ((old.transferredBytes ?? 0) == 0 && (new.transferredBytes ?? 0) > 0)
            if boundary || Date().timeIntervalSince(lastWrite) >= 0.25 {
                let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
                if try encoder.encode(old) != encoder.encode(new) {
                    next.entries[index].snapshot = new;next.entries[index].itemCount = snapshot.items.count
                    next.entries[index].updated = Date();changed = true;important = important || boundary
                }
            }
        }
        let positions = Dictionary(uniqueKeysWithValues:snapshots.enumerated().map { ($1.id,$0) })
        next.entries.sort { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
        if next.entries.map(\.id) != document.entries.map(\.id) { changed = true;important = true }
        if changed && (important || Date().timeIntervalSince(lastWrite) >= 0.25) { try save(next) }
    }
    private func bounded(_ snapshot: WorkSnapshot) -> WorkSnapshot {
        var value = snapshot;value.items = Array(value.items.prefix(Self.maximumItems))
        value.detail = String(value.detail.prefix(4000))
        for index in value.items.indices { value.items[index].message = String(value.items[index].message.prefix(4000)) }
        return value
    }
    private func isPrivateRegular(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG && value.st_uid == getuid() && value.st_nlink == 1
    }
    private func validateDirectory() throws {
        var value = stat()
        guard lstat(directory.path,&value) == 0,(value.st_mode & S_IFMT) == S_IFDIR,
              value.st_dev == directoryVersion?.device,value.st_ino == directoryVersion?.inode,
              value.st_uid == getuid(),value.st_mode & 0o077 == 0 else { throw journalError("Der Ablageordner wurde verändert.") }
        var lockValue = stat(),held = stat()
        guard fstatat(dirFD,".journal.lock",&lockValue,AT_SYMLINK_NOFOLLOW) == 0,fstat(lockFD,&held) == 0,
              isPrivateRegular(lockValue),lockValue.st_dev == held.st_dev,lockValue.st_ino == held.st_ino else { throw journalError("Die Sperrdatei wurde verändert.") }
    }
    private func currentDiskVersion(_ name: String = "journal.json") throws -> JournalFileVersion? {
        var value = stat()
        if fstatat(dirFD,name,&value,AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil };throw journalError("Die Auftragsdatei ist nicht lesbar.")
        }
        guard isPrivateRegular(value),value.st_size >= 0,value.st_size <= Self.maximumBytes else { throw journalError("Die Auftragsdatei ist keine sichere reguläre Datei oder zu groß.") }
        return JournalFileVersion(value)
    }

    // Shares the journal's lifetime lock; recovery metadata never introduces a second writer.
    func loadHistory() throws -> Data? {
        lock.lock();defer { lock.unlock() }
        try validateDirectory()
        let expected = try currentDiskVersion("history.json")
        guard let expected else { historyLoaded = true;historyVersion = nil;return nil }
        let fd = openat(dirFD,"history.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw journalError("Wiederherstellungsdaten sind nicht lesbar.") };defer { close(fd) }
        var value = stat()
        guard fstat(fd,&value) == 0,JournalFileVersion(value) == expected,isPrivateRegular(value),value.st_mode & 0o077 == 0 else { throw journalError("Wiederherstellungsdaten wurden verändert.") }
        var data = Data(),buffer = [UInt8](repeating:0,count:65536)
        while true {
            let count = read(fd,&buffer,buffer.count)
            if count == 0 { break };if count < 0 && errno == EINTR { continue }
            guard count > 0,data.count+count <= Self.maximumBytes else { throw journalError("Wiederherstellungsdaten sind nicht vollständig lesbar.") }
            data.append(contentsOf:buffer.prefix(count))
        }
        guard try currentDiskVersion("history.json") == expected else { throw journalError("Wiederherstellungsdaten wurden beim Lesen verändert.") }
        historyVersion = expected;historyLoaded = true;return data
    }
    func saveHistory(_ data: Data) throws {
        lock.lock();defer { lock.unlock() }
        guard historyLoaded,data.count <= Self.maximumBytes else { throw journalError("Wiederherstellungsablage ist nicht verfügbar oder voll.") }
        try validateDirectory()
        guard try currentDiskVersion("history.json") == historyVersion else { throw journalError("Wiederherstellungsdaten wurden außerhalb der App verändert.") }
        let name = ".history-"+UUID().uuidString+".tmp"
        let fd = openat(dirFD,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw journalError("Wiederherstellungsdaten lassen sich nicht anlegen.") }
        defer { close(fd);unlinkat(dirFD,name,0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw journalError("Wiederherstellungsdaten konnten nicht geschrieben werden.") };offset += count
            }
        }
        guard fsync(fd) == 0 else { throw journalError("Wiederherstellungsdaten konnten nicht gesichert werden.") }
        try validateDirectory()
        guard try currentDiskVersion("history.json") == historyVersion else { throw journalError("Wiederherstellungsdaten wurden beim Speichern verändert.") }
        guard renameat(dirFD,name,dirFD,"history.json") == 0 else { throw journalError("Wiederherstellungsdaten konnten nicht veröffentlicht werden.") }
        historyVersion = try currentDiskVersion("history.json")
        guard fsync(dirFD) == 0 else { throw journalError("Wiederherstellungsablage konnte nicht gesichert werden.") }
    }
    func checkHistory() throws {
        lock.lock();defer { lock.unlock() };try validateDirectory()
        guard historyLoaded,try currentDiskVersion("history.json") == historyVersion else { throw journalError("Wiederherstellungsdaten wurden außerhalb der App verändert.") }
    }
    private func readDisk() throws -> Data? {
        try validateDirectory();diskVersion = try currentDiskVersion()
        guard let expected = diskVersion else { return nil }
        let fd = openat(dirFD,"journal.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw journalError("Die Auftragsdatei lässt sich nicht öffnen.") };defer { Darwin.close(fd) }
        var value = stat()
        guard fstat(fd,&value) == 0,JournalFileVersion(value) == expected,isPrivateRegular(value),fchmod(fd,0o600) == 0 else { throw journalError("Die Auftragsdatei wurde beim Öffnen verändert.") }
        // fchmod changes the mode in the version guard; remember the protected mode.
        guard fstat(fd,&value) == 0 else { throw journalError("Der Dateistand ist nicht lesbar.") }
        diskVersion = JournalFileVersion(value)
        var data = Data(),buffer = [UInt8](repeating:0,count:65536)
        while true {
            let count = Darwin.read(fd,&buffer,buffer.count)
            if count == 0 { break };if count < 0 { if errno == EINTR { continue };throw journalError("Lesefehler in der Auftragsdatei.") }
            guard data.count+count <= Self.maximumBytes else { throw journalError("Die Auftragsdatei ist zu groß.") };data.append(contentsOf:buffer.prefix(count))
        }
        guard try currentDiskVersion() == diskVersion else { throw journalError("Die Auftragsdatei wurde beim Lesen verändert.") };return data
    }
    private func save(_ next: JournalDocument) throws {
        var next = next
        next.version = next.entries.contains { $0.intent.kind == .move && $0.intent.filter.isActive } ? 3 : next.entries.contains { $0.intent.filter.modifiedAge != nil } ? 2 : 1
        try next.validate();let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= Self.maximumBytes else { throw journalError("Die Auftragsablage ist voll. Bitte erledigte Aufträge ausblenden.") }
        try validateDirectory()
        guard try currentDiskVersion() == diskVersion else { throw journalError("Die Auftragsdatei wurde außerhalb der App verändert; sie bleibt unverändert.") }
        let name = ".journal-"+UUID().uuidString+".tmp",fd = openat(dirFD,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw journalError("Die neue Auftragsdatei lässt sich nicht anlegen.") }
        defer { Darwin.close(fd);unlinkat(dirFD,name,0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw journalError("Schreibfehler in der Auftragsdatei.") };offset += count
            }
        }
        guard fsync(fd) == 0 else { throw journalError("Die Auftragsdatei konnte nicht auf den Datenträger geschrieben werden.") }
        try validateDirectory()
        guard try currentDiskVersion() == diskVersion else { throw journalError("Die Auftragsdatei wurde während des Speicherns verändert.") }
        guard renameat(dirFD,name,dirFD,"journal.json") == 0 else { throw journalError("Die Auftragsdatei konnte nicht veröffentlicht werden.") }
        diskVersion = try currentDiskVersion();document = next;lastWrite = Date()
        guard fsync(dirFD) == 0 else { throw journalError("Der Ablageordner konnte nicht auf den Datenträger geschrieben werden.") }
    }
}
