import Foundation
import Darwin

private struct ArchivePublished {
    let index:Int,path:String,version:RenameVersion,backup:String?,backupVersion:RenameVersion?
}
private struct ArchiveCreatedFolder { let index:Int,path:String,version:RenameVersion }

extension ArchiveService {
    /// Reads and verifies the payload before changing existing destination entries.
    /// Failed publication is rolled back only while the affected entries are still ours.
    public static func extract(_ plan:ArchiveMergePlan,password:String? = nil,token:CancellationToken = .init(),progress:(TransferProgress)->Void = { _ in }) -> OperationReport {
        var report = OperationReport(),items = plan.initialItems,stageName:String?,stageVersion:RenameVersion?,stageFD:Int32 = -1
        var tree:ArchiveDestination?,bindings = plan.bindings,published:[ArchivePublished] = [],created:[ArchiveCreatedFolder] = []
        var detail = "Prüfe Ziel und Konfliktentscheidungen …",readBytes:Int64 = 0,reading = true,last = Date.distantPast,finished = false
        let byPath = Dictionary(uniqueKeysWithValues:plan.actions.enumerated().map { ($0.element.member.path,$0.offset) })
        func emit(_ force:Bool = true) {
            guard force || Date().timeIntervalSince(last) >= 0.08 else { return };last = Date()
            let count = items.filter { [.completed,.skipped].contains($0.state) }.count
            let fraction = finished ? 1 : reading ? (plan.totalBytes > 0 ? 0.8*Double(readBytes)/Double(plan.totalBytes) : 0) : 0.8+0.19*Double(count)/Double(max(1,items.count))
            progress(TransferProgress(detail:detail,bytes:readBytes,totalBytes:plan.totalBytes,measuredBytes:true,fraction:min(1,fraction),items:items))
        }
        func parent(_ path:String) throws -> Int32 {
            guard let tree else { throw CommanderError.message("Zielordner nicht verfügbar.") }
            return try tree.folder((path as NSString).deletingLastPathComponent,bindings:bindings)
        }
        func current(_ fd:Int32,_ name:String) throws -> RenameVersion? {
            var value = stat();if fstatat(fd,name,&value,AT_SYMLINK_NOFOLLOW) == 0 { return RenameVersion(value) }
            if errno == ENOENT { return nil };throw CommanderError.message("Datei kann nicht geprüft werden: "+name)
        }
        func stageParent(_ path:String) throws -> Int32 {
            var fd = dup(stageFD);guard fd >= 0 else { throw CommanderError.message("Entpackdaten sind nicht verfügbar.") }
            do {
                for component in (path as NSString).deletingLastPathComponent.split(separator:"/").map(String.init) {
                    let next = openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                    guard next >= 0 else { throw CommanderError.message("Entpackter Ordner ist nicht verfügbar: "+path) };close(fd);fd = next
                }
                return fd
            } catch { close(fd);throw error }
        }
        func restore(_ record:ArchivePublished) -> Bool {
            do {
                let fd = try parent(record.path);defer { close(fd) };let name = (record.path as NSString).lastPathComponent
                if let now = try current(fd,name) {
                    guard record.version.sameAfterRename(now) else { return false }
                    guard unlinkat(fd,name,0) == 0 else { return false }
                }
                if let backup = record.backup,let version = record.backupVersion {
                    guard try current(fd,backup).map(version.sameAfterRename) == true else { return false }
                    guard renameatx_np(fd,backup,fd,name,UInt32(RENAME_EXCL)) == 0 else { return false }
                }
                return true
            } catch { return false }
        }
        func retainBackup(_ record:ArchivePublished) {
            guard let backup = record.backup else { return }
            let target = plan.destination.appendingPathComponent(record.path),url = target.deletingLastPathComponent().appendingPathComponent(backup)
            report.undo.append(UndoStep(current:target,original:nil,backup:url,stamp:FileStamp(version:record.version)))
            report.errors.append("Vorheriger Inhalt bleibt gesichert: "+url.path)
        }
        emit()
        defer {
            if stageFD >= 0 { close(stageFD) }
            if let tree,let stageName,let stageVersion { try? removeArchiveStage(tree.fd,name:stageName,version:stageVersion) }
            tree?.close()
        }
        do {
            try token.check();try plan.validate(token:token)
            let destination = try ArchiveDestination(plan.destination,version:plan.rootVersion);tree = destination
            for action in plan.actions where plan.isSkipped(action) { report.skipped.append(plan.destination.appendingPathComponent(plan.targetPath(for:action))) }
            let active = plan.actions.filter { !plan.isSkipped($0) }
            if active.isEmpty { finished = true;detail = "Alle Einträge übersprungen";emit();return report }
            let stage = ".zweicommander-extract-"+UUID().uuidString;stageName = stage
            guard mkdirat(destination.fd,stage,0o700) == 0 else { throw CommanderError.message("Entpackdaten können nicht vorbereitet werden.") }
            stageFD = openat(destination.fd,stage,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard stageFD >= 0 else { throw CommanderError.message("Entpackdaten können nicht geöffnet werden.") }
            var stageStat = stat();guard fstat(stageFD,&stageStat) == 0 else { throw CommanderError.message("Entpackordner kann nicht geprüft werden.") };stageVersion = RenameVersion(stageStat)
            var input = "",startBytes:Int64 = 0
            try writeExtraction(plan.selection.selecting(Set(active.map { $0.member.path })),catalog:plan.catalog,to:stageFD,password:password,token:token,directoryMetadata:false,progress:{ name,total in
                let changed = input != name
                if changed { input = name;startBytes = total };readBytes = total;detail = "Entpacke · "+name
                if let index = byPath[name] { items[index].state = .running;items[index].bytes = total-startBytes;items[index].message = "Inhalt wird vorbereitet" };emit(changed)
            })
            try token.check();try plan.validate(token:token);reading = false
            for index in items.indices where items[index].state != .skipped { items[index].state = .waiting;items[index].message = "Bereit zum Übernehmen" }
            for (index,action) in plan.actions.enumerated() where !plan.isSkipped(action) {
                try token.check();let path = plan.targetPath(for:action),name = (path as NSString).lastPathComponent
                items[index].state = .running;detail = "Übernehme · "+path;emit()
                try destination.validateRoot();try plan.catalog.validateSource()
                let directory = try parent(path);defer { close(directory) }
                if action.member.isDirectory {
                    if action.blockedBy == nil,let old = action.version,old.isDirectory {
                        guard try current(directory,name).map(old.sameObject) == true else { throw CommanderError.message("Zielordner wurde ersetzt: "+path) }
                    } else {
                        let temporary = ".folder-"+UUID().uuidString
                        guard mkdirat(stageFD,temporary,0o700) == 0 else { throw CommanderError.message("Ordner kann nicht vorbereitet werden: "+path) }
                        let version = try RenameVersion.read(stageFD,temporary)
                        guard renameatx_np(stageFD,temporary,directory,name,UInt32(RENAME_EXCL)) == 0 else { throw CommanderError.message("Ein Ordnerziel wurde inzwischen belegt: "+path) }
                        created.append(ArchiveCreatedFolder(index:index,path:path,version:version));bindings[path] = version
                        guard try current(directory,name).map(version.sameObject) == true else { throw CommanderError.message("Ein neuer Zielordner wurde ersetzt: "+path) }
                    }
                } else {
                    let sourceDirectory = try stageParent(action.member.path);defer { close(sourceDirectory) }
                    let sourceName = (action.member.path as NSString).lastPathComponent,version = try RenameVersion.read(sourceDirectory,sourceName)
                    guard version.isRegularFile,version.size == action.member.size else { throw CommanderError.message("Vorbereiteter Dateiinhalt wurde verändert: "+path) }
                    let old = try current(directory,name),replace = action.conflict && action.decision == .replace
                    guard old == (replace ? action.version : nil) else { throw CommanderError.message("Zieldatei wurde seit der Vorschau geändert: "+path) }
                    var backup:String?,backupVersion:RenameVersion?
                    if replace,let old {
                        let name = ".zweicommander-backup-"+UUID().uuidString
                        guard renameatx_np(directory,(path as NSString).lastPathComponent,directory,name,UInt32(RENAME_EXCL)) == 0 else { throw CommanderError.message("Vorherige Zieldatei kann nicht gesichert werden: "+path) }
                        backup = name;backupVersion = old
                        // Register the move before validation, so any failed publication restores it.
                        let record = ArchivePublished(index:index,path:path,version:version,backup:backup,backupVersion:backupVersion)
                        published.append(record)
                        backupVersion = try RenameVersion.read(directory,name)
                        published[published.count-1] = ArchivePublished(index:index,path:path,version:version,backup:backup,backupVersion:backupVersion)
                        guard backupVersion.map(old.sameAfterRename) == true else { throw CommanderError.message("Die Zieldatei wurde während der Sicherung verändert: "+path) }
                        detail = "Sichere bisherigen Inhalt · "+path;emit();try token.check();try destination.validateRoot();try plan.catalog.validateSource()
                    }
                    if !replace { published.append(ArchivePublished(index:index,path:path,version:version,backup:nil,backupVersion:nil)) }
                    guard renameatx_np(sourceDirectory,sourceName,directory,name,UInt32(RENAME_EXCL)) == 0 else { throw CommanderError.message("Ziel wurde inzwischen belegt. Nichts wurde überschrieben: "+path) }
                    guard try current(directory,name).map(version.sameAfterRename) == true else { throw CommanderError.message("Übernommene Datei wurde unmittelbar verändert: "+path) }
                    items[index].bytes = action.member.size
                }
                items[index].state = .completed;items[index].message = plan.description(of:action);emit()
            }
            try token.check();try destination.validateRoot();try plan.catalog.validateSource()
            for folder in created.reversed() {
                try token.check();let fd = try destination.folder(folder.path,bindings:bindings);defer { close(fd) }
                let action = plan.actions[folder.index]
                if action.member.modified != .distantPast { var times = [timeval(tv_sec:Int(action.member.modified.timeIntervalSince1970),tv_usec:0),timeval(tv_sec:Int(action.member.modified.timeIntervalSince1970),tv_usec:0)];guard futimes(fd,&times) == 0 else { throw CommanderError.message("Ordnerdatum konnte nicht gesetzt werden: "+folder.path) } }
                guard fchmod(fd,mode_t(action.member.permissions == 0 ? 0o755 : action.member.permissions)) == 0 else { throw CommanderError.message("Ordnerrechte konnten nicht gesetzt werden: "+folder.path) }
            }
            try token.check();try destination.validateRoot();try plan.catalog.validateSource()
            for record in published {
                let target = plan.destination.appendingPathComponent(record.path)
                report.completed.append(target);report.undo.append(UndoStep(current:target,original:nil,backup:record.backup.map { target.deletingLastPathComponent().appendingPathComponent($0) },stamp:FileStamp(version:record.version)))
            }
            report.completed += created.map { plan.destination.appendingPathComponent($0.path) }
            finished = true;detail = "\(report.completed.count) übernommen · \(plan.skippedCount) übersprungen · \(plan.replacingCount) gesichert";emit()
        } catch {
            report.errors.append(error.localizedDescription)
            // Restore traversal access only for directories created by this operation.
            for folder in created {
                if let tree,let fd = try? tree.folder(folder.path,bindings:bindings) { _ = fchmod(fd,0o700);close(fd) }
            }
            var incomplete = false
            for record in published.reversed() {
                if restore(record) { items[record.index].bytes = 0 }
                else { incomplete = true;retainBackup(record);report.errors.append("Nachträglich verändertes Ziel bleibt erhalten: "+record.path) }
            }
            for folder in created.reversed() {
                do {
                    let fd = try parent(folder.path);defer { close(fd) };let name = (folder.path as NSString).lastPathComponent
                    if try current(fd,name).map(folder.version.sameObject) == true,unlinkat(fd,name,AT_REMOVEDIR) != 0 { incomplete = true }
                } catch { incomplete = true }
            }
            for index in items.indices where items[index].state != .skipped { items[index].state = token.isCancelled ? .cancelled : .failed;items[index].message = "Nicht abgeschlossen" }
            detail = (token.isCancelled ? "Abgebrochen" : "Entpacken fehlgeschlagen")+(incomplete ? " · veränderte Ziele und Sicherungen prüfen" : " · Änderungen zurückgesetzt");emit()
        }
        return report
    }
    private static func removeArchiveStage(_ parent:Int32,name:String,version:RenameVersion) throws {
        guard try version.sameObject(RenameVersion.read(parent,name)) else { return }
        let fd = openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd >= 0 else { return };defer { close(fd) }
        guard let stream = fdopendir(dup(fd)) else { return };defer { closedir(stream) }
        while let entry = readdir(stream) {
            let child = withUnsafePointer(to:&entry.pointee.d_name) { String(cString:UnsafeRawPointer($0).assumingMemoryBound(to:CChar.self)) }
            if child == "." || child == ".." { continue }
            let item = try RenameVersion.read(fd,child)
            if item.isDirectory { try removeArchiveStage(fd,name:child,version:item) } else { guard unlinkat(fd,child,0) == 0 else { return } }
        }
        _ = unlinkat(parent,name,AT_REMOVEDIR)
    }
}
