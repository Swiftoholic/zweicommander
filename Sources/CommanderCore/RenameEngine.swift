import Foundation
import Darwin

struct RenameVersion: Equatable, Codable {
    let device: dev_t,inode: ino_t,mode: mode_t,size: off_t
    let modifiedSeconds: Int,modifiedNanos: Int,changedSeconds: Int,changedNanos: Int,birthSeconds: Int,birthNanos: Int
    var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    var modified: Date { Date(timeIntervalSince1970:Double(modifiedSeconds)+Double(modifiedNanos)/1e9) }
    var created: Date { Date(timeIntervalSince1970:Double(birthSeconds)+Double(birthNanos)/1e9) }
    init(_ value: stat) {
        device = value.st_dev;inode = value.st_ino;mode = value.st_mode;size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec;modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec;changedNanos = value.st_ctimespec.tv_nsec
        birthSeconds = value.st_birthtimespec.tv_sec;birthNanos = value.st_birthtimespec.tv_nsec
    }
    static func read(_ url: URL) throws -> Self {
        guard url.isFileURL,!url.path.contains("\0") else { throw CommanderError.message("Ein lokaler Dateipfad wird benötigt.") }
        var value = stat()
        guard lstat(url.path,&value) == 0 else { throw failure(url.lastPathComponent) };return Self(value)
    }
    static func read(_ fd: Int32,_ name: String) throws -> Self {
        var value = stat()
        guard fstatat(fd,name,&value,AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(name) };return Self(value)
    }
    func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode && (mode & S_IFMT) == (other.mode & S_IFMT) }
    func sameAfterRename(_ other: Self) -> Bool {
        sameObject(other) && mode == other.mode && size == other.size && modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos &&
            birthSeconds == other.birthSeconds && birthNanos == other.birthNanos
    }
}
private func failure(_ name: String) -> CommanderError { .message(name+": "+String(cString:strerror(errno))) }
private func normalized(_ url: URL) -> URL { FileSystem.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent) }
private func folded(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }

public struct RenameItem {
    public let source: URL
    public let target: URL
    let version: RenameVersion?
    let parentVersion: RenameVersion?
    public init(source: URL,target: URL) {
        self.source = normalized(source);self.target = normalized(target)
        version = source.isFileURL && target.isFileURL ? try? RenameVersion.read(self.source) : nil
        parentVersion = source.isFileURL ? try? RenameVersion.read(self.source.deletingLastPathComponent()) : nil
    }
    init(source: URL,target: URL,version: RenameVersion,parent: RenameVersion) {
        self.source = source;self.target = target;self.version = version;parentVersion = parent
    }
    public var changed: Bool { source.path != target.path }
    /// Keep the original file and parent snapshots while the user edits a name.
    public func renaming(to name:String) throws -> RenameItem {
        try FileSystem.validateName(name)
        guard let version,let parentVersion else { throw CommanderError.message("Quelle oder Elternordner ist nicht mehr verfügbar.") }
        return RenameItem(source:source,target:source.deletingLastPathComponent().appendingPathComponent(name),version:version,parent:parentVersion)
    }
}
public struct RenamePreviewRow {
    public let source: URL
    public let item: RenameItem?
    public var error: String?
    public var targetName: String? { item?.target.lastPathComponent }
}
public struct RenamePreview {
    public var rows: [RenamePreviewRow]
    public var items: [RenameItem] { rows.compactMap(\.item) }
    public var changedCount: Int { rows.filter { $0.item?.changed == true }.count }
    public var errorCount: Int { rows.filter { $0.error != nil }.count }
    public var canApply: Bool { errorCount == 0 && changedCount > 0 }
}
public enum RenamePhase: String { case staging, publishing, restoring }
public struct RenameProgress {
    public let phase: RenamePhase
    public let completed: Int
    public let total: Int
    public let name: String
}

public enum RenameEngine {
    public static let maximumItems = 10_000
    public static func plan(_ urls: [URL],rule: RenameRule,token: CancellationToken = .init()) throws -> RenamePreview {
        guard urls.count <= maximumItems else { throw CommanderError.message("Höchstens 10.000 Objekte je Umbenennung auswählen.") }
        let compiled = try CompiledRenameRule(rule);var counters: [String:Int] = [:],rows: [RenamePreviewRow] = []
        for (index,url) in urls.enumerated() {
            try token.check()
            do {
                guard url.isFileURL else { throw CommanderError.message("Nur lokale Dateipfade sind erlaubt.") }
                let source = normalized(url),version = try RenameVersion.read(source),parent = source.deletingLastPathComponent()
                let parentVersion = try RenameVersion.read(parent)
                let number = rule.resetPerFolder ? counters[parent.path,default:0] : index
                counters[parent.path,default:0] += 1
                let name = try compiled.filename(source,version:version,index:number)
                let item = RenameItem(source:source,target:parent.appendingPathComponent(name),version:version,parent:parentVersion)
                rows.append(RenamePreviewRow(source:url,item:item,error:nil))
            } catch { rows.append(RenamePreviewRow(source:url,item:nil,error:error.localizedDescription)) }
        }
        let indexes = rows.indices.filter { rows[$0].item != nil },items = indexes.compactMap { rows[$0].item }
        for (index,error) in issues(items) { rows[indexes[index]].error = error }
        return RenamePreview(rows:rows)
    }
    public static func preview(_ urls: [URL],rule: RenameRule) throws -> [RenameItem] {
        let result = try plan(urls,rule:rule)
        if let error = result.rows.first(where: { $0.error != nil })?.error { throw CommanderError.message(error) }
        return result.items
    }
    private static func issues(_ items: [RenameItem]) -> [Int:String] {
        var result: [Int:String] = [:],sources: [String:[Int]] = [:],targets: [String:[Int]] = [:],objects: [String:[Int]] = [:],directoryNames: [String:Set<String>] = [:]
        for (index,item) in items.enumerated() {
            sources[item.source.path,default:[]].append(index);targets[folded(item.target.path),default:[]].append(index)
            if let version = item.version { objects["\(version.device):\(version.inode)",default:[]].append(index) }
        }
        for duplicates in sources.values where duplicates.count > 1 { for index in duplicates { result[index] = "Quelle ist mehrfach enthalten." } }
        for duplicates in targets.values where duplicates.count > 1 { for index in duplicates { result[index] = "Mehrere Objekte erhalten denselben Zielnamen." } }
        for duplicates in objects.values where duplicates.count > 1 { for index in duplicates { result[index] = "Mehrere Namen desselben Dateiobjekts bitte getrennt umbenennen." } }
        for (index,item) in items.enumerated() {
            do {
                try FileSystem.validateName(item.source.lastPathComponent);try FileSystem.validateName(item.target.lastPathComponent)
                let parent = item.source.deletingLastPathComponent()
                guard parent.path == item.target.deletingLastPathComponent().path else { throw CommanderError.message("Umbenennen bleibt im ursprünglichen Ordner.") }
                guard let version = item.version,let parentVersion = item.parentVersion,parentVersion.isDirectory,
                      version.isDirectory || version.isRegularFile || (version.mode & S_IFMT) == S_IFLNK else { throw CommanderError.message("Quelle oder Elternordner ist nicht verfügbar oder kein unterstütztes Dateiobjekt.") }
                if item.changed,FileSystem.exists(item.target),sources[item.target.path] == nil {
                    if directoryNames[parent.path] == nil { directoryNames[parent.path] = Set(try FileManager.default.contentsOfDirectory(atPath:parent.path)) }
                    let caseAlias = folded(item.source.lastPathComponent) == folded(item.target.lastPathComponent) &&
                        directoryNames[parent.path]?.contains(item.target.lastPathComponent) == false &&
                        (try? RenameVersion.read(item.target)).map { version.sameObject($0) } == true
                    guard caseAlias else { throw CommanderError.message("Zielname existiert bereits: "+item.target.lastPathComponent) }
                }
                if version.isDirectory {
                    let prefix = item.source.path+"/"
                    for other in items.indices where other != index && items[other].source.path.hasPrefix(prefix) {
                        result[index] = "Ordner und enthaltene Objekte nicht gemeinsam umbenennen.";result[other] = result[index]
                    }
                }
            } catch { result[index] = error.localizedDescription }
        }
        return result
    }
    public static func validate(_ items: [RenameItem]) throws {
        guard items.count <= maximumItems else { throw CommanderError.message("Zu viele Umbenennungen.") }
        if let error = issues(items).sorted(by: { $0.key < $1.key }).first?.value { throw CommanderError.message(error) }
        for item in items {
            guard try RenameVersion.read(item.source) == item.version else { throw CommanderError.message("Quelle wurde seit der Vorschau verändert: "+item.source.lastPathComponent) }
            guard let parent = item.parentVersion,parent.sameObject(try RenameVersion.read(item.source.deletingLastPathComponent())) else { throw CommanderError.message("Elternordner wurde seit der Vorschau ersetzt.") }
        }
    }
    @discardableResult public static func apply(_ items: [RenameItem],token: CancellationToken = .init(),progress: (RenameProgress)->Void = { _ in }) throws -> [RenameItem] {
        try token.check();try validate(items)
        let changed = items.filter(\.changed);var descriptors: [String:Int32] = [:]
        defer { for fd in descriptors.values { close(fd) } }
        for item in changed {
            let path = item.source.deletingLastPathComponent().path
            if descriptors[path] == nil {
                let fd = open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard fd >= 0 else { throw failure(path) };descriptors[path] = fd
                var value = stat()
                guard fstat(fd,&value) == 0,item.parentVersion?.sameObject(RenameVersion(value)) == true else { throw CommanderError.message("Elternordner wurde ersetzt.") }
            }
        }
        struct Staged {
            let item: RenameItem
            let fd: Int32
            let temporary: String
            var version: RenameVersion
            var published = false
        }
        var staged: [Staged] = []
        func checkParent(_ item: RenameItem) throws {
            guard let original = item.parentVersion,original.sameObject(try RenameVersion.read(item.source.deletingLastPathComponent())) else { throw CommanderError.message("Elternordner wurde während der Umbenennung ersetzt oder verschoben.") }
        }
        func move(_ fd: Int32,_ from: String,_ to: String) throws {
            guard renameatx_np(fd,from,fd,to,UInt32(RENAME_EXCL)) == 0 else { throw failure(from+" → "+to) }
        }
        func recoveryPath(_ fd: Int32,_ name: String,parent: URL) -> String {
            var buffer = [CChar](repeating:0,count:Int(MAXPATHLEN))
            let found = buffer.withUnsafeMutableBufferPointer { fcntl(fd,F_GETPATH,$0.baseAddress!) }
            let path = found == 0 ? String(cString:buffer) : parent.path
            return URL(fileURLWithPath:path).appendingPathComponent(name).path
        }
        do {
            for (index,item) in changed.enumerated() {
                progress(RenameProgress(phase:.staging,completed:index,total:changed.count,name:item.source.lastPathComponent));try token.check();try checkParent(item)
                let fd = descriptors[item.source.deletingLastPathComponent().path]!
                guard try RenameVersion.read(fd,item.source.lastPathComponent) == item.version else { throw CommanderError.message("Quelle wurde seit der Vorschau verändert: "+item.source.lastPathComponent) }
                let temporary = ".zweicommander-rename-"+UUID().uuidString
                try move(fd,item.source.lastPathComponent,temporary)
                // Record the owned location before any subsequent operation can fail.
                staged.append(Staged(item:item,fd:fd,temporary:temporary,version:item.version!))
                staged[staged.count-1].version = try RenameVersion.read(fd,temporary)
                guard item.version!.sameAfterRename(staged[staged.count-1].version) else { throw CommanderError.message("Quelle wurde beim Vorbereiten der Umbenennung verändert.") }
            }
            for index in staged.indices {
                let entry = staged[index]
                progress(RenameProgress(phase:.publishing,completed:index,total:changed.count,name:entry.item.target.lastPathComponent));try token.check();try checkParent(entry.item)
                guard try RenameVersion.read(entry.fd,entry.temporary) == entry.version else { throw CommanderError.message("Quelle wurde während der Umbenennung verändert.") }
                try move(entry.fd,entry.temporary,entry.item.target.lastPathComponent);staged[index].published = true
                staged[index].version = try RenameVersion.read(entry.fd,entry.item.target.lastPathComponent)
                guard entry.version.sameAfterRename(staged[index].version) else { throw CommanderError.message("Quelle wurde beim Veröffentlichen der Umbenennung verändert.") }
            }
            let undo = staged.map { RenameItem(source:$0.item.target,target:$0.item.source,version:$0.version,parent:$0.item.parentVersion!) }
            progress(RenameProgress(phase:.publishing,completed:changed.count,total:changed.count,name:"Abgeschlossen"));return undo
        } catch {
            var recovery: [String] = []
            for index in staged.indices.reversed() where staged[index].published {
                let entry = staged[index]
                do {
                    try checkParent(entry.item)
                    guard entry.version.sameObject(try RenameVersion.read(entry.fd,entry.item.target.lastPathComponent)) else { throw CommanderError.message("Ziel wurde von außen ersetzt; es bleibt unberührt.") }
                    try move(entry.fd,entry.item.target.lastPathComponent,entry.temporary);staged[index].published = false
                } catch { recovery.append(recoveryPath(entry.fd,entry.item.target.lastPathComponent,parent:entry.item.target.deletingLastPathComponent())+": "+error.localizedDescription) }
            }
            for (index,entry) in staged.reversed().enumerated() where !entry.published {
                progress(RenameProgress(phase:.restoring,completed:index,total:staged.count,name:entry.item.source.lastPathComponent))
                do {
                    try checkParent(entry.item)
                    guard entry.version.sameObject(try RenameVersion.read(entry.fd,entry.temporary)) else { throw CommanderError.message("Zwischenablage wurde von außen ersetzt; sie bleibt unberührt.") }
                    try move(entry.fd,entry.temporary,entry.item.source.lastPathComponent)
                } catch { recovery.append(recoveryPath(entry.fd,entry.temporary,parent:entry.item.source.deletingLastPathComponent())+": "+error.localizedDescription) }
            }
            if recovery.isEmpty { throw error }
            throw CommanderError.message(error.localizedDescription+"\nNicht vollständig zurückgesetzt. Erhaltene Zwischenablagen/Ziele prüfen:\n"+recovery.joined(separator:"\n"))
        }
    }
    public static func reversed(_ items: [RenameItem]) -> [RenameItem] { items.map { RenameItem(source:$0.target,target:$0.source) } }
}
