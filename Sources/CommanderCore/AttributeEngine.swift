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
    let observed:[String:AttributeObservation]
    init(_ plan:AttributePlan) throws {
        self.plan = plan;observed = Dictionary(uniqueKeysWithValues:plan.observations.map { ($0.source.path,$0) })
        // Reserve root-parent handles before any mutation; descendants are opened
        // one at a time, so a 10,000-row preview does not retain 10,000 descriptors.
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
    func reserveRestrictiveRows(_ token:CancellationToken) throws {
        guard plan.rule.permissions != nil else { return }
        for row in plan.selectedRows {
            try token.check();guard let mode = row.after?.permissions,mode & 0o400 == 0 || row.before.isDirectory && mode & 0o500 != 0o500 else { continue }
            let fd = try open(root:row.root,relative:row.relative)
            do { guard try AttributeSnapshot.read(fd).version == row.before.version else { throw attributeError("Objekt wurde vor Reservierung des Rücknahmebelegs verändert.") };retained[row.id] = AttributeRetainedFile(fd) }
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
        var context:AttributeContext?,tracked:[(receipt:Int,completed:Int?,row:AttributeRow)] = [],relocations:[String:URL] = [:],recoveryIssue:String?
        let indexes = Dictionary(uniqueKeysWithValues:plan.selectedRows.enumerated().map { ($0.element.id,$0.offset) })
        func relocate(_ source:URL) -> URL {
            guard let prefix = relocations.keys.filter({source.path == $0 || source.path.hasPrefix($0+"/")}).max(by:{$0.count < $1.count}),let actual = relocations[prefix] else { return source }
            let suffix = String(source.path.dropFirst(prefix.count));return suffix.isEmpty ? actual : actual.appendingPathComponent(String(suffix.dropFirst()))
        }
        func reconcile(_ fd:Int32? = nil,_ row:AttributeRow? = nil) {
            for (original,parent) in context?.parents ?? [:] {
                if let actual = try? parent.path(),actual.path != original { relocations[original] = actual }
            }
            if let fd,let row,let actual = try? attributeActualPath(fd),actual.path != row.source.path { relocations[row.source.path] = actual }
            for entry in tracked {
                let old = report.receipts[entry.receipt],source = relocate(entry.row.source)
                let moved = source.path != old.source.path
                if let current = try? AttributeSnapshot.read(source) {
                    if current.version != old.after.version { recoveryIssue = "Ein bereits geändertes Objekt wurde während des Auftrags nochmals verändert: "+source.path }
                }
                if moved {
                    let anchors = (try? attributeAnchors(source.deletingLastPathComponent())) ?? old.anchors
                    // Relocating a receipt must never reseal its target version.
                    // Renaming a leaf changes ctime, but a concurrent write can do
                    // that too. Such a leaf therefore requires a new user review.
                    report.receipts[entry.receipt] = AttributeReceipt(source:source,before:old.before,after:old.after,anchors:anchors,retained:old.retained)
                    if let completed = entry.completed { report.completed[completed] = source }
                    recoveryIssue = "Ein Objekt oder Elternordner wurde während des Auftrags verschoben. Änderungen und Rücknahmebelege am tatsächlichen Ort prüfen: "+source.path
                }
            }
        }
        func emit() { let done = items.filter { $0.state == .completed }.count;progress(TransferProgress(detail:detail,bytes:0,totalBytes:0,measuredBytes:false,fraction:items.isEmpty ? nil : Double(done)/Double(items.count),items:items));reconcile() }
        emit()
        do {
            try token.check();try plan.rule.validate();guard !rows.isEmpty else { throw attributeError("Keine Eigenschaftsänderung ausgewählt.") }
            let active = try AttributeContext(plan);context = active;try active.validateAll(token);try active.reserveRestrictiveRows(token)
            report.skipped = plan.rows.filter { !$0.selected }.map(\.source)
            for row in rows {
                try token.check();let index = indexes[row.id]!;items[index].state = .running;detail = "Eigenschaften ändern · "+row.source.lastPathComponent;emit()
                let retained = active.retained[row.id],fd = try retained?.fd ?? active.open(root:row.root,relative:row.relative);defer { if retained == nil { close(fd) } }
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
                    items[index].state = .completed;items[index].message = "Eigenschaften geändert";emit();reconcile(fd,row)
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
        // Restore parent permissions before their children; each row remains guarded
        // by its own post-change inode/version. A conflict never authorizes a restore.
        let rows = receipts.sorted { $0.source.pathComponents.count < $1.source.pathComponents.count }
        for (index,row) in rows.enumerated() {
            do {
                try token.check();try attributeValidateAnchors(row.anchors)
                let parentAnchors = try attributeAnchors(row.source.deletingLastPathComponent()),parent = try attributeOpenAnchors(parentAnchors);defer { close(parent) }
                let retained = row.retained,fd = retained?.fd ?? openat(parent,row.source.lastPathComponent,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);guard fd >= 0 else { throw attributeError("Objekt für eine sichere Rücknahme nicht lesbar: "+row.source.path) };defer { if retained == nil { close(fd) } }
                let before = try AttributeSnapshot.read(fd)
                guard before.version == row.after.version,try AttributeSnapshot.read(parent,row.source.lastPathComponent).version == row.after.version,
                      try attributeActualPath(fd).path == row.source.path,
                      row.before.accessed == row.after.accessed || before.accessed == row.after.accessed else { throw attributeError("Objekt wurde nach der Änderung verändert; keine Rücknahme: "+row.source.path) }
                let old = AttributeValues(row.before)
                try apply(fd,before:before,desired:old,permissions:row.before.permissions != row.after.permissions,created:row.before.created != row.after.created,modified:row.before.modified != row.after.modified,accessed:row.before.accessed != row.after.accessed)
                let after = try AttributeSnapshot.read(fd)
                guard after.version.sameObject(row.before.version),after.permissions == row.before.permissions,after.created == row.before.created,after.modified == row.before.modified,
                      row.before.accessed == row.after.accessed || after.accessed == row.before.accessed else { throw attributeError("Rücknahme konnte nicht vollständig bestätigt werden: "+row.source.path) }
                report.completed.append(row.source)
                progress(TransferProgress(detail:"Eigenschaften zurückgenommen · "+row.source.lastPathComponent,bytes:0,totalBytes:0,measuredBytes:false,fraction:Double(index+1)/Double(rows.count),items:[]))
            } catch { report.errors.append(error.localizedDescription);if token.isCancelled { break } }
        }
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
