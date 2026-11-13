import Foundation
import Darwin

public struct AttributeReceipt {
    public let source:URL,before:AttributeSnapshot,after:AttributeSnapshot
    let anchors:[AttributeAnchor]
    let retained:AttributeRetainedFile?
}
final class AttributeRetainedFile {
    let fd:Int32
    init(_ fd:Int32) { self.fd = fd }
    deinit { close(fd) }
}
public struct AttributeReport {
    public var completed:[URL] = [],skipped:[URL] = [],errors:[String] = [],receipts:[AttributeReceipt] = []
    public init() {}
    public var operationReport:OperationReport { var value = OperationReport();value.completed = completed;value.skipped = skipped;value.errors = errors;return value }
}

private final class AttributeParent {
    let fd:Int32,anchors:[AttributeAnchor]
    init(_ anchors:[AttributeAnchor]) throws { self.anchors = anchors;fd = try attributeOpenAnchors(anchors) }
    deinit { close(fd) }
    func validate() throws { try attributeValidateAnchors(anchors);guard let last = anchors.last,try AttributeSnapshot.read(fd).version.sameObject(last.version) else { throw attributeError("Auswahl-Elternordner wurde ersetzt.") } }
    func path() throws -> URL { var path = [CChar](repeating:0,count:Int(MAXPATHLEN));guard fcntl(fd,F_GETPATH,&path) == 0 else { throw attributeFailure("Elternordnerpfad") };return URL(fileURLWithPath:String(cString:path),isDirectory:true) }
}
private final class AttributeContext {
    let plan:AttributePlan
    var parents:[String:AttributeParent] = [:]
    var retained:[String:AttributeRetainedFile] = [:]
    var pinned:[String:AttributeRetainedFile] = [:]
    let observed:[String:AttributeObservation]
    init(_ plan:AttributePlan) throws {
        self.plan = plan;observed = Dictionary(uniqueKeysWithValues:plan.observations.map { ($0.source.path,$0) })
        // Root parents and selected inode handles are reserved before any mutation.
        // Native descriptor limits can reject a large plan without partial changes.
        for root in plan.roots {
            let key = root.source.deletingLastPathComponent().path
            if parents[key] == nil { parents[key] = try AttributeParent(root.anchors) }
        }
    }
    func parent(root:Int,relative:String) throws -> (Int32,String) {
        let source = plan.roots[root].source,key = source.deletingLastPathComponent().path
        guard let anchor = parents[key] else { throw attributeError("Elternordnerhandle fehlt.") };try anchor.validate()
        let parts = ([source.lastPathComponent]+relative.split(separator:"/").map(String.init)),name = parts.last!
        var current = dup(anchor.fd);guard current >= 0 else { throw attributeFailure("Elternordner") }
        do {
            var path = source.deletingLastPathComponent()
            for component in parts.dropLast() {
                path.appendPathComponent(component)
                guard let expected = observed[path.path],expected.snapshot.isDirectory else { throw attributeError("Ungeprüfter Zwischenordner.") }
                let next = openat(current,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard next >= 0 else { throw attributeFailure(component) }
                guard (try? AttributeSnapshot.read(next).version.sameObject(expected.snapshot.version)) == true else { close(next);throw attributeError("Zwischenordner wurde ersetzt: "+path.path) }
                close(current);current = next
            }
            return (current,name)
        } catch { close(current);throw error }
    }
    func open(root:Int,relative:String) throws -> Int32 {
        let (parent,name) = try self.parent(root:root,relative:relative);defer { close(parent) }
        let fd = openat(parent,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
        guard fd >= 0 else { throw attributeFailure(name) };return fd
    }
    func validateAll(_ token:CancellationToken) throws {
        let selected = Set(plan.selectedRows.map(\.id))
        for observation in plan.observations {
            try token.check();let (parent,name) = try self.parent(root:observation.root,relative:observation.relative);defer { close(parent) }
            let fresh = try AttributeSnapshot.read(parent,name)
            guard fresh.version == observation.snapshot.version else { throw attributeError("Objekt wurde seit der Vorschau geändert: "+observation.source.path) }
            if plan.rule.accessed.isChanged,fresh.isRegularFile,fresh.accessed != observation.snapshot.accessed { throw attributeError("Zugriffszeit wurde seit der Vorschau geändert: "+observation.source.path) }
            if let children = observation.children {
                let fd = openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd >= 0 else { throw attributeFailure(name) };defer { close(fd) }
                guard try AttributeSnapshot.read(fd).version == observation.snapshot.version,try attributeChildren(fd) == children else { throw attributeError("Ordnerinhalt wurde seit der Vorschau geändert: "+observation.source.path) }
            }
            if selected.contains(observation.source.path) {
                let fd = openat(parent,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);guard fd >= 0 else { throw attributeFailure("Ausgewähltes Objekt nicht lesbar") };defer { close(fd) }
                guard try AttributeSnapshot.read(fd).version == observation.snapshot.version else { throw attributeError("Ausgewähltes Objekt wurde während der Vorprüfung verändert.") }
            }
        }
    }
    func reserveRows(_ token:CancellationToken) throws {
        let restrictedParents = plan.selectedRows.filter { $0.before.isDirectory && ($0.after?.permissions ?? $0.before.permissions) & 0o500 != 0o500 }.map(\.source.path)
        for row in plan.selectedRows {
            try token.check()
            let fd = try open(root:row.root,relative:row.relative)
            do {
                guard try AttributeSnapshot.read(fd).version == row.before.version else { throw attributeError("Objekt wurde vor Reservierung des Rücknahmebelegs verändert.") }
                let held = AttributeRetainedFile(fd);pinned[row.id] = held
                let mode = row.after?.permissions ?? row.before.permissions
                if mode & 0o400 == 0 || row.before.isDirectory && mode & 0o500 != 0o500 || restrictedParents.contains(where:{row.source.path.hasPrefix($0+"/")}) { retained[row.id] = held }
            }
            catch { close(fd);throw error }
        }
    }
    func validatePath(_ row:AttributeRow,_ snapshot:AttributeSnapshot) throws {
        let (parent,name) = try self.parent(root:row.root,relative:row.relative);defer { close(parent) }
        guard try AttributeSnapshot.read(parent,name).version == snapshot.version else { throw attributeError("Objekt wurde während des Auftrags ersetzt oder verschoben: "+row.source.path) }
    }
}

public enum AttributeEngine {
    public static func execute(_ plan:AttributePlan,token:CancellationToken = .init(),progress:@escaping (TransferProgress)->Void = { _ in }) -> AttributeReport {
        let rows = plan.selectedRows.sorted { lhs,rhs in let l = lhs.source.pathComponents.count,r = rhs.source.pathComponents.count;return l == r ? lhs.source.path < rhs.source.path : l > r }
        var report = AttributeReport(),items = plan.initialItems,detail = "Prüfe Eigenschaftsplan …"
        var context:AttributeContext?,tracked:[(receipt:Int,completed:Int?,row:AttributeRow)] = [],recoveryIssue:String?
        let indexes = Dictionary(uniqueKeysWithValues:plan.selectedRows.enumerated().map { ($0.element.id,$0.offset) })
        func reconcile() {
            // Each completed inode remains pinned until the final callback returns.
            // A later row's callback can rename or unlink an earlier completed leaf.
            let restrictedParents = tracked.compactMap { entry -> String? in
                let receipt = report.receipts[entry.receipt]
                guard receipt.after.isDirectory,receipt.after.permissions & 0o500 != 0o500,
                      let held = context?.pinned[entry.row.id],let current = try? AttributeSnapshot.read(held.fd),current.version == receipt.after.version else { return nil }
                return try? attributeActualPath(held.fd).path
            }
            for entry in tracked {
                let old = report.receipts[entry.receipt]
                do {
                    guard let held = context?.pinned[entry.row.id] else { throw attributeError("Dateihandle für einen abgeschlossenen Schritt fehlt.") }
                    let source = try attributeLinkedPath(held.fd,restrictedParents:restrictedParents),current = try AttributeSnapshot.read(held.fd)
                    if current.version != old.after.version { recoveryIssue = "Ein bereits geändertes Objekt wurde während des Auftrags nochmals verändert: "+source.path }
                    if source.path != old.source.path {
                        let anchors = (try? attributeAnchors(source.deletingLastPathComponent())) ?? old.anchors
                        // Relocation changes paths only, never the post-operation seal.
                        report.receipts[entry.receipt] = AttributeReceipt(source:source,before:old.before,after:old.after,anchors:anchors,retained:old.retained)
                        if let completed = entry.completed { report.completed[completed] = source }
                        recoveryIssue = "Ein Objekt oder Elternordner wurde während des Auftrags verschoben. Änderungen und Rücknahmebelege am tatsächlichen Ort prüfen: "+source.path
                    }
                } catch { recoveryIssue = "Abgeschlossener Schritt nicht mehr eindeutig verfügbar: "+old.source.path+" · "+error.localizedDescription }
            }
        }
        func emit() { let done = items.filter { $0.state == .completed }.count;progress(TransferProgress(detail:detail,bytes:0,totalBytes:0,measuredBytes:false,fraction:items.isEmpty ? nil : Double(done)/Double(items.count),items:items));reconcile() }
        emit()
        do {
            try token.check();try plan.rule.validate();guard !rows.isEmpty else { throw attributeError("Keine Eigenschaftsänderung ausgewählt.") }
            let active = try AttributeContext(plan);context = active;try active.validateAll(token);try active.reserveRows(token)
            report.skipped = plan.rows.filter { !$0.selected }.map(\.source)
            for row in rows {
                try token.check();let index = indexes[row.id]!;items[index].state = .running;detail = "Eigenschaften ändern · "+row.source.lastPathComponent;emit()
                if let recoveryIssue { throw attributeError(recoveryIssue) }
                guard let pinned = active.pinned[row.id] else { throw attributeError("Vorab reservierter Objekthandle fehlt.") };let retained = active.retained[row.id],fd = pinned.fd
                let before = try AttributeSnapshot.read(fd)
                guard before.version == row.before.version,before.isRegularFile || before.isDirectory,let desired = row.after else { throw attributeError("Objekt wurde seit der Vorschau geändert: "+row.source.path) }
                if plan.rule.accessed.isChanged,before.isRegularFile,before.accessed != row.before.accessed { throw attributeError("Zugriffszeit wurde inzwischen geändert: "+row.source.path) }
                try active.validatePath(row,before)
                var recorded = false
                do {
                    try token.check()
                    try apply(fd,before:before,desired:desired,permissions:plan.rule.permissions != nil,created:plan.rule.created.isChanged,modified:plan.rule.modified.isChanged,accessed:plan.rule.accessed.isChanged)
                    let after = try AttributeSnapshot.read(fd)
                    try verify(before:before,after:after,desired:desired,rule:plan.rule)
                    try active.validatePath(row,after)
                    let anchors = try attributeAnchors(row.source.deletingLastPathComponent())
                    tracked.append((report.receipts.count,report.completed.count,row));report.completed.append(row.source);report.receipts.append(AttributeReceipt(source:row.source,before:before,after:after,anchors:anchors,retained:retained));recorded = true
                    items[index].state = .completed;items[index].message = "Eigenschaften geändert";emit()
                    if let recoveryIssue { throw attributeError(recoveryIssue) }
                } catch {
                    // A syscall may have applied an earlier field before a later one failed.
                    // Keep an identity-bound receipt even for that partial row.
                    if !recorded,let after = try? AttributeSnapshot.read(fd),after.version.sameObject(before.version),AttributeValues(after) != AttributeValues(before) {
                        let source = (try? attributeActualPath(fd)) ?? row.source
                        let anchors = (try? attributeAnchors(source.deletingLastPathComponent())) ?? plan.roots[row.root].anchors
                        tracked.append((report.receipts.count,nil,row));report.receipts.append(AttributeReceipt(source:source,before:before,after:after,anchors:anchors,retained:retained))
                    }
                    if !recorded { items[index].state = token.isCancelled ? .cancelled : .failed };items[index].message = error.localizedDescription;throw error
                }
            }
        } catch {
            report.errors.append(error.localizedDescription)
            for index in items.indices where items[index].state == .running { items[index].state = token.isCancelled ? .cancelled : .failed;items[index].message = error.localizedDescription }
            for index in items.indices where items[index].state == .waiting { items[index].state = .cancelled;items[index].message = "Nicht ausgeführt" }
        }
        detail = report.errors.isEmpty ? "Eigenschaftsänderungen abgeschlossen" : token.isCancelled ? "Abgebrochen · fertige Änderungen bleiben erhalten" : "Angehalten · fertige Änderungen und Bericht prüfen";emit()
        if let recoveryIssue,!report.errors.contains(recoveryIssue) { report.errors.append(recoveryIssue) };return report
    }
    public static func undo(_ receipts:[AttributeReceipt],token:CancellationToken = .init(),progress:@escaping (TransferProgress)->Void = { _ in }) -> AttributeReport {
        var report = AttributeReport()
        let rows = receipts.sorted { $0.source.pathComponents.count < $1.source.pathComponents.count }
        report.receipts = rows
        var pinned:[Int:AttributeRetainedFile] = [:],restored:[(row:Int,completed:Int,seal:AttributeSnapshot)] = [],callbackIssue = false,conflicts = Dictionary(uniqueKeysWithValues:rows.enumerated().map { ($0.offset,$0.element) })
        func error(_ text:String) { if !report.errors.contains(text) { report.errors.append(text) } }
        func restrictedParents() -> [String] {
            rows.indices.compactMap { index in
                let row = rows[index]
                guard row.after.isDirectory,row.after.permissions & 0o500 != 0o500,let fd = pinned[index]?.fd,
                      let current = try? AttributeSnapshot.read(fd),current.version == row.after.version else { return nil }
                return try? attributeActualPath(fd).path
            }
        }
        func reconcile() {
            let restricted = restrictedParents()
            for entry in restored {
                do {
                    guard let fd = pinned[entry.row]?.fd else { throw attributeError("Rücknahmehandle fehlt.") }
                    let source = try attributeLinkedPath(fd,restrictedParents:restricted),current = try AttributeSnapshot.read(fd)
                    let changed = current.version != entry.seal.version,moved = source.path != rows[entry.row].source.path
                    if changed { callbackIssue = true;error("Ein zurückgenommenes Objekt wurde während der Rücknahme nochmals verändert: "+source.path) }
                    if source.path != report.completed[entry.completed].path { report.completed[entry.completed] = source;callbackIssue = true;error("Ein zurückgenommenes Objekt wurde während der Rücknahme verschoben. Tatsächlichen Ort prüfen: "+source.path) }
                    if changed || moved {
                        let old = rows[entry.row],anchors = (try? attributeAnchors(source.deletingLastPathComponent())) ?? old.anchors
                        conflicts[entry.row] = AttributeReceipt(source:source,before:old.before,after:old.after,anchors:anchors,retained:old.retained)
                    } else { conflicts.removeValue(forKey:entry.row) }
                } catch let failure { callbackIssue = true;if conflicts[entry.row] == nil { conflicts[entry.row] = rows[entry.row] };error("Zurückgenommenes Objekt nicht mehr eindeutig verfügbar: "+rows[entry.row].source.path+" · "+failure.localizedDescription) }
            }
        }
        // Pin all still-valid objects before the first restore. Descendants made
        // inaccessible by this operation already have retained session handles.
        // Resource exhaustion aborts before any metadata is restored.
        for (index,row) in rows.enumerated() {
            do {
                try token.check()
                if let held = row.retained { pinned[index] = held }
                else {
                    try attributeValidateAnchors(row.anchors)
                    let parent = try attributeOpenAnchors(try attributeAnchors(row.source.deletingLastPathComponent()));defer { close(parent) }
                    let fd = openat(parent,row.source.lastPathComponent,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
                    guard fd >= 0 else {
                        if errno == EMFILE || errno == ENFILE { error("Nicht genug Dateihandles für eine vollständig geprüfte Rücknahme. Es wurde nichts zurückgenommen.");return report }
                        throw attributeError("Objekt für eine sichere Rücknahme nicht lesbar: "+row.source.path)
                    }
                    pinned[index] = AttributeRetainedFile(fd)
                }
                guard let fd = pinned[index]?.fd,try AttributeSnapshot.read(fd).version == row.after.version else { pinned.removeValue(forKey:index);throw attributeError("Objekt wurde nach der Änderung verändert; keine Rücknahme: "+row.source.path) }
            } catch let failure {
                if let system = failure as? AttributeSystemError,system.code == EMFILE || system.code == ENFILE { error("Nicht genug Dateihandles für eine vollständig geprüfte Rücknahme. Es wurde nichts zurückgenommen.");return report }
                error(failure.localizedDescription);if token.isCancelled { return report }
            }
        }
        for (index,row) in rows.enumerated() {
            guard let fd = pinned[index]?.fd else { continue }
            do {
                try token.check();try attributeValidateAnchors(row.anchors)
                let parentAnchors = try attributeAnchors(row.source.deletingLastPathComponent()),parent = try attributeOpenAnchors(parentAnchors);defer { close(parent) }
                let before = try AttributeSnapshot.read(fd)
                guard before.version == row.after.version,try AttributeSnapshot.read(parent,row.source.lastPathComponent).version == row.after.version,
                      try attributeLinkedPath(fd,restrictedParents:restrictedParents()).path == row.source.path,
                      row.before.accessed == row.after.accessed || before.accessed == row.after.accessed else { throw attributeError("Objekt wurde nach der Änderung verändert; keine Rücknahme: "+row.source.path) }
                let old = AttributeValues(row.before)
                try apply(fd,before:before,desired:old,permissions:row.before.permissions != row.after.permissions,created:row.before.created != row.after.created,modified:row.before.modified != row.after.modified,accessed:row.before.accessed != row.after.accessed)
                let after = try AttributeSnapshot.read(fd)
                guard after.version.sameObject(row.before.version),after.permissions == row.before.permissions,after.created == row.before.created,after.modified == row.before.modified,
                      row.before.accessed == row.after.accessed || after.accessed == row.before.accessed else { throw attributeError("Rücknahme konnte nicht vollständig bestätigt werden: "+row.source.path) }
                restored.append((index,report.completed.count,after));report.completed.append(row.source)
                progress(TransferProgress(detail:"Eigenschaften zurückgenommen · "+row.source.lastPathComponent,bytes:0,totalBytes:0,measuredBytes:false,fraction:Double(index+1)/Double(rows.count),items:[]))
                reconcile();if callbackIssue { break }
            } catch let failure { error(failure.localizedDescription);if token.isCancelled { break } }
        }
        progress(TransferProgress(detail:report.errors.isEmpty ? "Rücknahme abgeschlossen" : "Rücknahme beendet · Belege prüfen",bytes:0,totalBytes:0,measuredBytes:false,fraction:rows.isEmpty ? nil : Double(report.completed.count)/Double(rows.count),items:[]));reconcile()
        report.receipts = conflicts.keys.sorted().compactMap { conflicts[$0] }
        return report
    }
    private static func apply(_ fd:Int32,before:AttributeSnapshot,desired:AttributeValues,permissions:Bool,created:Bool,modified:Bool,accessed:Bool) throws {
        if created || modified || accessed {
            // Supply all three times in one native metadata call. Unspecified values
            // come from the just-opened inode, preserving subsecond precision and
            // avoiding the implicit birth-time adjustment of mtime-only operations.
            var list = attrlist();list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT);list.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME)
            var values = [(created ? desired.created : before.created).native,(modified ? desired.modified : before.modified).native,(accessed ? desired.accessed : before.accessed).native]
            guard values.withUnsafeMutableBytes({ fsetattrlist(fd,&list,$0.baseAddress,$0.count,0) }) == 0 else { throw attributeFailure("Zeitstempel ändern") }
        }
        // Permission changes happen last, so restrictive modes cannot block the
        // time changes of this row. Descendants are processed before directories.
        if permissions,desired.permissions != before.permissions, fchmod(fd,mode_t(desired.permissions)) != 0 { throw attributeFailure("Rechte ändern") }
    }
    private static func verify(before:AttributeSnapshot,after:AttributeSnapshot,desired:AttributeValues,rule:AttributeRule) throws {
        guard before.version.sameObject(after.version),before.bytes == after.bytes,
              after.permissions == desired.permissions,
              after.created == (rule.created.isChanged ? desired.created : before.created),
              after.modified == (rule.modified.isChanged ? desired.modified : before.modified),
              after.accessed == (rule.accessed.isChanged ? desired.accessed : before.accessed) else { throw attributeError("Dateisystem bestätigt die gewünschten Eigenschaften nicht vollständig; Teiländerung im Bericht prüfen.") }
    }
}

func attributeOpenAnchors(_ expected:[AttributeAnchor]) throws -> Int32 {
    guard let first = expected.first,first.path.path == "/" else { throw attributeError("Elternordnerbeleg fehlt.") }
    var current = open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);guard current >= 0 else { throw attributeFailure("Dateisystemwurzel") }
    do {
        guard try AttributeSnapshot.read(current).version.sameObject(first.version) else { throw attributeError("Dateisystemwurzel wurde ersetzt.") }
        for entry in expected.dropFirst() {
            let next = openat(current,entry.path.lastPathComponent,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next >= 0 else { throw attributeFailure(entry.path.lastPathComponent) }
            guard (try? AttributeSnapshot.read(next).version.sameObject(entry.version)) == true else { close(next);throw attributeError("Ein übergeordneter Ordner wurde ersetzt oder verschoben.") }
            close(current);current = next
        }
        return current
    } catch { close(current);throw error }
}
func attributeChildren(_ fd:Int32) throws -> [String] {
    let duplicate = dup(fd);guard duplicate >= 0 else { throw attributeFailure("Ordnerhandle") }
    guard let directory = fdopendir(duplicate) else { close(duplicate);throw attributeFailure("Ordnerinhalt") };defer { closedir(directory) }
    rewinddir(directory);var result:[String] = [];errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to:&entry.pointee.d_name) { value in value.withMemoryRebound(to:CChar.self,capacity:Int(entry.pointee.d_namlen)+1) { String(cString:$0) } }
        if name == "." || name == ".." { continue };try FileSystem.validateName(name);result.append(name)
        guard result.count <= AttributePlan.maximumItems else { throw attributeError("Ordner enthält mehr als 10.000 Einträge.") };errno = 0
    }
    guard errno == 0 else { throw attributeFailure("Ordnerinhalt") };return result.sorted()
}
private func attributeActualPath(_ fd:Int32) throws -> URL { var path = [CChar](repeating:0,count:Int(MAXPATHLEN));guard fcntl(fd,F_GETPATH,&path) == 0 else { throw attributeFailure("Aktueller Objektpfad") };return URL(fileURLWithPath:String(cString:path)) }
private func attributeLinkedPath(_ fd:Int32,restrictedParents:[String]) throws -> URL {
    var value = stat();guard fstat(fd,&value) == 0 else { throw attributeFailure("Objektbeleg") }
    guard value.st_nlink > 0 else { throw attributeError("Objekt wurde gelöscht oder durch einen anderen Eintrag ersetzt.") }
    let source = try attributeActualPath(fd);var named = stat()
    if lstat(source.path,&named) == 0 { guard RenameVersion(named).sameObject(RenameVersion(value)) else { throw attributeError("Der tatsächliche Objektpfad gehört inzwischen zu einem anderen Eintrag.") } }
    else {
        // Own directory permission changes can intentionally remove search access.
        // The pinned live vnode plus an unchanged restricted ancestor is still a
        // valid receipt; ENOENT/other failures are never treated as success.
        guard errno == EACCES,restrictedParents.contains(where:{source.path.hasPrefix($0+"/")}) else { throw attributeFailure("Tatsächlicher Objektpfad nicht verfügbar") }
    }
    return source
}
