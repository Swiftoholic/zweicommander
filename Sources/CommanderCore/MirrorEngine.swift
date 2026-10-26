import Foundation
import Darwin

public enum FolderMirrorEngine {
    public static func execute(_ plan:FolderMirrorPlan,token:CancellationToken = .init(),history:TransferHistory? = nil,progress:@escaping (TransferProgress)->Void = { _ in }) -> OperationReport {
        var report = OperationReport(),items = plan.initialItems,detail = "Prüfe Spiegelungsplan …",last = Date.distantPast
        let offset = plan.copies.steps.count
        func emit(_ force:Bool = true) {
            guard force || Date().timeIntervalSince(last) >= 0.08 else { return };last = Date()
            let amount = items.prefix(offset).reduce(Int64(0)) { $0+$1.bytes },finished = items.allSatisfy { $0.state == .completed }
            progress(TransferProgress(detail:detail,bytes:amount,totalBytes:plan.bytes,measuredBytes:true,fraction:plan.bytes > 0 ? (finished ? 1 : min(0.999,Double(amount)/Double(plan.bytes))) : nil,items:items))
        }
        var source:SyncRoot?,target:SyncRoot?,deliveredCopyProgress = false
        func check(_ removal:MirrorRemoval) throws {
            try token.check();try sourceAbsent(source!,path:removal.path,token:token)
            guard let parent = try target!.parent(removal.path) else { throw mirrorError("Zielordner fehlt.") };defer { close(parent) }
            try target!.checkParent(removal.path,parent)
            try MirrorTree.validate(parent:parent,name:removal.original.lastPathComponent,members:removal.receipt.members,afterRename:false,token:token)
            guard try mirrorOptional(parent,removal.stored.lastPathComponent) == nil else { throw mirrorError("Geplanter Sicherungsname ist inzwischen belegt.") }
        }
        emit()
        do {
            let ltr = plan.direction == .leftToRight
            source = try SyncRoot(plan.source,ltr ? plan.comparison.leftVersion : plan.comparison.rightVersion,ltr ? plan.comparison.leftEntries : plan.comparison.rightEntries)
            target = try SyncRoot(plan.destination,ltr ? plan.comparison.rightVersion : plan.comparison.leftVersion,ltr ? plan.comparison.rightEntries : plan.comparison.leftEntries)
            guard try mirrorVersion(source!.fd) == source!.version,try mirrorVersion(target!.fd) == target!.version else { throw mirrorError("Vergleichsordner seit Vorschau verändert.") }
            // The entire removal phase must be valid before the first copy is started.
            for removal in plan.removals { try check(removal) }
            let copied = FolderSyncEngine.execute(plan.copies,token:token,progress:{ value in
                for index in 0..<min(offset,value.items.count) { items[index] = value.items[index] };detail = "Kopieren · "+value.detail
                if value.bytes > 0 && !deliveredCopyProgress { deliveredCopyProgress = true;emit() } else { emit(false) }
            })
            report = copied
            guard copied.errors.isEmpty,!token.isCancelled else { throw mirrorError("Kopierphase nicht vollständig abgeschlossen; keine zusätzlichen Ziele entfernt.") }
            try history?.captureBackups(copied.undo)
            // Copying can take time. Revalidate every removal before any of them is moved.
            for removal in plan.removals { try check(removal) }
            for (number,removal) in plan.removals.enumerated() {
                let index = offset+number;items[index].state = .running;detail = "Entfernen mit Sicherung · "+removal.path;emit()
                var historyID:UUID?,moved = false,completed = false
                guard let parent = try target!.parent(removal.path) else { throw mirrorError("Zielordner fehlt.") };defer { close(parent) }
                do {
                    try check(removal)
                    historyID = try history?.stageBackup(original:removal.original,stored:removal.stored,version:removal.receipt.members[""],mirror:removal.receipt)
                    try token.check();try target!.checkParent(removal.path,parent)
                    guard renameatx_np(parent,removal.original.lastPathComponent,parent,removal.stored.lastPathComponent,UInt32(RENAME_EXCL)) == 0 else { throw mirrorError("Zieleintrag konnte nicht gesichert werden: "+removal.path) };moved = true
                    try target!.checkParent(removal.path,parent);try sourceAbsent(source!,path:removal.path,token:token)
                    try MirrorTree.validate(parent:parent,name:removal.stored.lastPathComponent,members:removal.receipt.members,afterRename:true,token:token)
                    var receipt = removal.receipt;receipt.storedVersion = try RenameVersion.read(parent,removal.stored.lastPathComponent)
                    let stamp = FileStamp(version:receipt.storedVersion!)
                    report.completed.append(removal.original);report.undo.append(UndoStep(current:removal.stored,original:removal.original,backup:nil,stamp:stamp,mirrorRemoval:receipt));completed = true
                    // Store the post-rename version before authorizing the next removal.
                    _ = try history?.stageBackup(original:removal.original,stored:removal.stored,version:receipt.members[""],mirror:receipt)
                    items[index].state = .completed;items[index].message = "Entfernt · Sicherung bleibt erhalten";emit()
                } catch {
                    if moved && !completed {
                        let current = try? mirrorOptional(parent,removal.stored.lastPathComponent)
                        if current.map({ removal.receipt.members[""]!.sameAfterRename($0) }) == true,
                           (try? mirrorOptional(parent,removal.original.lastPathComponent)) == nil,
                           renameatx_np(parent,removal.stored.lastPathComponent,parent,removal.original.lastPathComponent,UInt32(RENAME_EXCL)) == 0 {
                            moved = false
                        } else {
                            // A changed or newly occupied name is never overwritten during rollback.
                            if let current {
                                var receipt = removal.receipt;receipt.storedVersion = current
                                report.completed.append(removal.original);report.undo.append(UndoStep(current:removal.stored,original:removal.original,backup:nil,stamp:FileStamp(version:current),mirrorRemoval:receipt))
                            }
                            report.errors.append("Rücksetzung nicht möglich; Sicherung erhalten: "+removal.stored.path)
                        }
                    }
                    if !moved,let historyID { try? history?.forgetBackup(historyID) }
                    items[index].state = token.isCancelled ? .cancelled : .failed;items[index].message = error.localizedDescription;throw error
                }
            }
        } catch {
            report.errors.append(error.localizedDescription)
            for index in items.indices where items[index].state == .waiting { items[index].state = .cancelled;items[index].message = "Nicht ausgeführt" }
            for index in items.indices where items[index].state == .running { items[index].state = token.isCancelled ? .cancelled : .failed;items[index].message = error.localizedDescription }
        }
        detail = token.isCancelled ? "Spiegelung abgebrochen · fertige Schritte und Sicherungen bleiben erhalten" : report.errors.isEmpty ? "Spiegelung abgeschlossen · Sicherungen bleiben erhalten" : "Spiegelung angehalten · fertige Schritte und Sicherungen prüfen"
        emit();return report
    }
    private static func sourceAbsent(_ root:SyncRoot,path:String,token:CancellationToken) throws {
        guard try isSourceAbsent(root,path:path,token:token) else { throw mirrorError("Zusätzliches Ziel hat inzwischen ein Gegenstück in der Quelle: "+path) }
    }
    static func isSourceAbsent(_ root:SyncRoot,path:String,token:CancellationToken) throws -> Bool {
        try root.validate();var current = dup(root.fd);guard current >= 0 else { throw mirrorError("Quellordnerhandle fehlt.") };defer { close(current) }
        let parts = path.split(separator:"/").map(String.init);var prefix = "",expectedParent = root.version
        for (index,part) in parts.enumerated() {
            try token.check();guard try mirrorVersion(current) == expectedParent else { throw mirrorError("Quellordner seit Vorschau verändert; erneut vergleichen.") }
            let value = try mirrorOptional(current,part)
            guard try mirrorVersion(current) == expectedParent else { throw mirrorError("Quellordner während Prüfung verändert.") }
            let nextPath = prefix.isEmpty ? part : prefix+"/"+part
            if value == nil {
                try root.checkParent(prefix.isEmpty ? part : prefix+"/"+part,current);return true
            }
            if index == parts.count-1 { return false }
            guard let expected = root.folders[nextPath] else { return false }
            guard value == expected,expected.isDirectory else { throw mirrorError("Quellpfad seit Vorschau verändert.") }
            let next = openat(current,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard next >= 0 else { throw mirrorError("Quellpfad wurde verändert.") }
            guard (try? mirrorVersion(next)) == expected else { close(next);throw mirrorError("Quellpfad beim Öffnen verändert.") }
            close(current);current = next;prefix = nextPath;expectedParent = expected
        }
        throw mirrorError("Quellgegenstück inzwischen vorhanden.")
    }
    static func validateStored(_ receipt:MirrorRemovalReceipt,parent:Int32,token:CancellationToken = .init()) throws {
        try MirrorTree.validate(parent:parent,name:receipt.stored.lastPathComponent,members:receipt.members,afterRename:true,token:token)
        if let expected = receipt.storedVersion { guard try RenameVersion.read(parent,receipt.stored.lastPathComponent) == expected else { throw mirrorError("Sicherung seit Erstellung verändert.") } }
    }
    static func restoreRemoval(_ receipt:MirrorRemovalReceipt,token:CancellationToken = .init()) throws {
        let root = try receipt.anchor();guard let parent = try root.parent(receipt.path) else { throw mirrorError("Ursprünglicher Zielordner fehlt.") };defer { close(parent) }
        try root.checkParent(receipt.path,parent);try validateStored(receipt,parent:parent,token:token)
        guard try mirrorOptional(parent,receipt.original.lastPathComponent) == nil else { throw mirrorError("Ursprünglicher Name ist wieder belegt; Sicherung bleibt erhalten.") }
        try token.check()
        guard renameatx_np(parent,receipt.stored.lastPathComponent,parent,receipt.original.lastPathComponent,UInt32(RENAME_EXCL)) == 0 else { throw mirrorError("Sicherung konnte nicht ohne Überschreiben zurückgesetzt werden.") }
        do {
            try root.checkParent(receipt.path,parent)
            try MirrorTree.validate(parent:parent,name:receipt.original.lastPathComponent,members:receipt.members,afterRename:true,token:.init())
        } catch {
            if let current = try? mirrorOptional(parent,receipt.original.lastPathComponent),receipt.members[""]!.sameAfterRename(current),
               (try? mirrorOptional(parent,receipt.stored.lastPathComponent)) == nil {
                _ = renameatx_np(parent,receipt.original.lastPathComponent,parent,receipt.stored.lastPathComponent,UInt32(RENAME_EXCL))
            }
            throw error
        }
    }
}
