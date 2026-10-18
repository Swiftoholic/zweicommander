import Foundation
import Darwin

private func syncError(_ text: String) -> CommanderError { .message(text+": "+String(cString:strerror(errno))) }
private func optionalVersion(_ fd: Int32,_ name: String) throws -> RenameVersion? {
    var value = stat();if fstatat(fd,name,&value,AT_SYMLINK_NOFOLLOW) == 0 { return RenameVersion(value) }
    if errno == ENOENT { return nil };throw syncError(name)
}
private func descriptorVersion(_ fd: Int32) throws -> RenameVersion {
    var value = stat();guard fstat(fd,&value) == 0 else { throw syncError("Dateiobjekt nicht lesbar") };return RenameVersion(value)
}
private func descriptorPath(_ fd: Int32) throws -> URL {
    var buffer = [CChar](repeating:0,count:Int(MAXPATHLEN))
    guard fcntl(fd,F_GETPATH,&buffer) == 0 else { throw syncError("Aktueller Ordnerpfad nicht lesbar") };return URL(fileURLWithPath:String(cString:buffer))
}
private final class SyncRoot {
    let url: URL,fd: Int32,version: RenameVersion
    var folders: [String:RenameVersion]
    init(_ url: URL,_ version: RenameVersion,_ entries: [String:ComparedEntry]) throws {
        self.url = url;self.version = version;folders = entries.filter { $0.value.isDirectory }.mapValues(\.version)
        let opened = open(url.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw syncError("Vergleichsordner nicht verfügbar") }
        guard let current = try? descriptorVersion(opened),current.sameObject(version) else { close(opened);throw CommanderError.message("Vergleichsordner wurde ersetzt.") }
        fd = opened
    }
    deinit { close(fd) }
    func validate() throws {
        guard try RenameVersion.read(url).sameObject(version),try descriptorVersion(fd).sameObject(version) else { throw CommanderError.message("Vergleichsordner wurde verschoben oder ersetzt.") }
    }
    func parent(_ path: String,allowMissing: Bool = false) throws -> Int32? {
        try validate();var current = dup(fd);guard current >= 0 else { throw syncError("Ordnerhandle") }
        var prefix = ""
        for part in path.split(separator:"/").dropLast().map(String.init) {
            prefix = prefix.isEmpty ? part : prefix+"/"+part
            do {
                guard let value = try optionalVersion(current,part) else {
                    if allowMissing && folders[prefix] == nil { close(current);return nil }
                    throw CommanderError.message("Übergeordneter Ordner fehlt: "+prefix)
                }
                guard let expected = folders[prefix],expected.isDirectory,value.sameObject(expected) else { throw CommanderError.message("Übergeordneter Ordner wurde ersetzt: "+prefix) }
                let next = openat(current,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw syncError(prefix) }
                guard let opened = try? descriptorVersion(next),opened.sameObject(expected) else { close(next);throw CommanderError.message("Ordner wurde beim Öffnen verändert: "+prefix) }
                close(current);current = next
            } catch { close(current);throw error }
        }
        return current
    }
    func inspect(_ path: String) throws -> RenameVersion? {
        guard let parent = try parent(path,allowMissing:true) else { return nil };defer { close(parent) }
        return try optionalVersion(parent,(path as NSString).lastPathComponent)
    }
    func checkParent(_ path: String,_ held: Int32) throws {
        guard let current = try parent(path) else { throw CommanderError.message("Zielordner fehlt.") };defer { close(current) }
        guard try descriptorVersion(current).sameObject(descriptorVersion(held)) else { throw CommanderError.message("Ordnerpfad wurde während der Übertragung verändert.") }
    }
}
public enum FolderSyncEngine {
    public static func execute(_ plan: FolderSyncPlan,token: CancellationToken = .init(),progress: @escaping (TransferProgress)->Void = { _ in }) -> OperationReport {
        var report = OperationReport(),items = plan.initialItems,last = Date.distantPast,detail = "Prüfe Synchronisationsplan …"
        var left: SyncRoot?,right: SyncRoot?,created: [(SyncRoot,SyncStep)] = []
        func emit(_ force: Bool = true) {
            guard force || Date().timeIntervalSince(last) >= 0.08 else { return };last = Date()
            let copied = items.reduce(Int64(0)) { $0+$1.bytes },finished = items.allSatisfy { $0.state == .completed }
            progress(TransferProgress(detail:detail,bytes:copied,totalBytes:plan.bytes,measuredBytes:true,fraction:plan.bytes > 0 ? (finished ? 1 : min(0.999,Double(copied)/Double(plan.bytes))) : nil,items:items))
        }
        func pair(_ step: SyncStep) -> (SyncRoot,SyncRoot) { step.direction == .leftToRight ? (left!,right!) : (right!,left!) }
        func check(_ step: SyncStep,_ source: SyncRoot,_ target: SyncRoot) throws {
            try token.check()
            guard let current = try source.inspect(step.path),step.isDirectory ? current.sameObject(step.sourceVersion) : current == step.sourceVersion else { throw CommanderError.message("Quelle seit Vergleich verändert: "+step.source.path) }
            guard try target.inspect(step.path) == step.targetVersion else { throw CommanderError.message("Ziel seit Vergleich verändert: "+step.destination.path) }
        }
        emit()
        do {
            left = try SyncRoot(plan.comparison.left,plan.comparison.leftVersion,plan.comparison.leftEntries)
            right = try SyncRoot(plan.comparison.right,plan.comparison.rightVersion,plan.comparison.rightEntries)
            // Validate all selected steps before the first filesystem mutation.
            for step in plan.steps { let (source,target) = pair(step);try check(step,source,target) }
            for (index,step) in plan.steps.enumerated() {
                do {
                    let (source,target) = pair(step);try check(step,source,target)
                    items[index].state = .running;detail = step.path;emit()
                    guard let parent = try target.parent(step.path) else { throw CommanderError.message("Zielordner fehlt.") };defer { close(parent) }
                    let name = (step.path as NSString).lastPathComponent
                    if step.isDirectory {
                        guard mkdirat(parent,name,0o700) == 0 else { throw syncError("Ordner nicht angelegt: "+step.path) }
                        guard let version = try optionalVersion(parent,name),version.isDirectory else { throw CommanderError.message("Neuer Ordner wurde verändert.") }
                        target.folders[step.path] = version;created.append((target,step));report.completed.append(try descriptorPath(parent).appendingPathComponent(name))
                    } else {
                        guard let sourceParent = try source.parent(step.path) else { throw CommanderError.message("Quellordner fehlt.") };defer { close(sourceParent) }
                        let sourceFD = openat(sourceParent,name,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                        guard sourceFD >= 0 else { throw syncError("Quelle nicht geöffnet: "+step.path) };defer { close(sourceFD) }
                        guard try descriptorVersion(sourceFD) == step.sourceVersion else { throw CommanderError.message("Quelle wurde beim Öffnen verändert.") }
                        let temporary = ".zweicommander-sync-"+UUID().uuidString
                        let temporaryFD = openat(parent,temporary,O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
                        guard temporaryFD >= 0 else { throw syncError("Zwischenkopie nicht angelegt") };defer { close(temporaryFD) }
                        let owned = try descriptorVersion(temporaryFD)
                        defer {
                            if let current = try? optionalVersion(parent,temporary),current.sameObject(owned) { _ = unlinkat(parent,temporary,0) }
                        }
                        var delivered = false
                        try NativeCopy.copyDescriptors(sourceFD,to:temporaryFD,token:token) { count in
                            items[index].bytes = min(step.bytes,max(items[index].bytes,count))
                            if count > 0 && !delivered { delivered = true;emit() } else { emit(false) }
                        }
                        try token.check();try source.checkParent(step.path,sourceParent);try target.checkParent(step.path,parent)
                        guard try descriptorVersion(sourceFD) == step.sourceVersion else { throw CommanderError.message("Quelle während Kopie verändert.") }
                        try check(step,source,target)
                        guard try optionalVersion(parent,temporary)?.sameObject(owned) == true else { throw CommanderError.message("Zwischenkopie wurde von außen ersetzt.") }
                        guard fsync(temporaryFD) == 0 else { throw syncError("Zwischenkopie nicht gespeichert") }
                        let staged = try descriptorVersion(temporaryFD)
                        var backup: String?
                        if let expected = step.targetVersion {
                            let saved = ".zweicommander-backup-"+UUID().uuidString
                            guard renameatx_np(parent,name,parent,saved,UInt32(RENAME_EXCL)) == 0 else { throw syncError("Zielsicherung fehlgeschlagen") };backup = saved
                            let savedVersion = try optionalVersion(parent,saved)
                            guard savedVersion.map({ expected.sameAfterRename($0) }) == true else {
                                if (try? optionalVersion(parent,name)) == nil { _ = renameatx_np(parent,saved,parent,name,UInt32(RENAME_EXCL)) }
                                throw CommanderError.message("Ziel während Sicherung verändert. Sicherung prüfen: "+(try descriptorPath(parent)).appendingPathComponent(saved).path)
                            }
                        }
                        if renameatx_np(parent,temporary,parent,name,UInt32(RENAME_EXCL)) != 0 {
                            let originalError = syncError("Zwischenkopie nicht veröffentlicht")
                            if let backup {
                                if renameatx_np(parent,backup,parent,name,UInt32(RENAME_EXCL)) != 0 {
                                    throw CommanderError.message("Ziel wurde inzwischen belegt. Vorheriger Inhalt bleibt unter "+(try descriptorPath(parent)).appendingPathComponent(backup).path)
                                }
                            }
                            throw originalError
                        }
                        let actual = try descriptorPath(parent).appendingPathComponent(name)
                        guard let published = try optionalVersion(parent,name),staged.sameAfterRename(published) else { throw CommanderError.message("Ergebnis wurde unmittelbar nach der Kopie verändert: "+actual.path) }
                        let stamp = try FileStamp(actual)
                        guard stamp.inode == UInt64(staged.inode),stamp.device == UInt64(truncatingIfNeeded:staged.device) else { throw CommanderError.message("Ergebnis wurde vor Erstellung der Rücknahme ersetzt.") }
                        report.completed.append(actual)
                        report.undo.append(UndoStep(current:actual,original:nil,backup:backup.map { actual.deletingLastPathComponent().appendingPathComponent($0) },stamp:stamp))
                    }
                    items[index].state = .completed;items[index].bytes = step.bytes;items[index].message = "Abgeschlossen";emit()
                } catch { items[index].state = token.isCancelled ? .cancelled : .failed;items[index].message = error.localizedDescription;throw error }
            }
        } catch {
            report.errors.append(error.localizedDescription)
            for index in items.indices where items[index].state == .waiting { items[index].state = .cancelled;items[index].message = "Nicht ausgeführt" }
        }
        // Keep partially completed copies and created folders; apply permissions only to our own directories.
        for (root,step) in created.reversed() {
            do {
                guard let parent = try root.parent(step.path) else { continue };defer { close(parent) }
                let fd = openat(parent,(step.path as NSString).lastPathComponent,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw syncError("Ordnerrechte") };defer { close(fd) }
                guard let expected = root.folders[step.path],try descriptorVersion(fd).sameObject(expected) else { throw CommanderError.message("Neuer Ordner wurde ersetzt.") }
                guard fchmod(fd,step.sourceVersion.mode & 0o777) == 0 else { throw syncError("Ordnerrechte nicht übernommen") }
            } catch { report.errors.append(error.localizedDescription) }
        }
        detail = token.isCancelled ? "Abgebrochen · fertige Schritte bleiben erhalten" : report.errors.isEmpty ? "Synchronisierung abgeschlossen" : "Angehalten · Bericht prüfen"
        emit();return report
    }
}
