import Foundation
import Darwin

enum FilteredMove {
    static func execute(_ plan: TransferPlan,token: CancellationToken,validateExecution: (() throws -> Void)?,history: TransferHistory?,progress: @escaping (TransferProgress)->Void) -> OperationReport {
        var report = OperationReport(),items = plan.initialItems,last = Date.distantPast,detail = "Prüfe gefilterten Verschiebeplan …"
        func emit(_ force: Bool = true) {
            guard force || Date().timeIntervalSince(last) >= 0.08 else { return };last = Date()
            let bytes = items.reduce(Int64(0)) { $0+$1.bytes },total = items.filter { $0.state != .skipped }.reduce(Int64(0)) { $0+$1.totalBytes }
            let done = items.allSatisfy { [.completed,.skipped].contains($0.state) }
            progress(TransferProgress(detail:detail,bytes:bytes,totalBytes:total,measuredBytes:true,fraction:total > 0 ? (done ? 1 : min(0.999,Double(bytes)/Double(total))) : nil,items:items))
        }
        emit()
        do {
            try token.check();try validateExecution?()
            guard try FileStamp(plan.destination).sameObject(as:plan.destinationVersion) else { throw recoveryError("Zielordner wurde seit der Vorschau ersetzt.") }
            for entry in plan.entries { try entry.tree.validate(entry.source,token:token);try entry.targetVersion.validate(entry.target) }
            for (index,entry) in plan.entries.enumerated() {
                do {
                    try token.check();try validateExecution?();items[index].state = .running;detail = entry.source.lastPathComponent;emit()
                    guard let step = try FileOperations.transferPrepared(entry.source,to:entry.target,kind:.copy,policy:plan.policy,token:token,tree:entry.tree,expectedTarget:entry.targetVersion,validateTarget:validateExecution,history:history,intentKind:.move,reused:{ report.reusedBytes += $0 },byteProgress:{ name,count,_ in
                        items[index].bytes = count;detail = name;emit(count > 0 && count <= 1024*1024)
                    }) else { items[index].state = .skipped;report.skipped.append(entry.source);emit();continue }
                    // Publish the selected tree before removing any selected source.
                    try entry.tree.validate(entry.source,token:token)
                    let leaves = entry.tree.nodes.filter { !$0.directory }
                    let targets = try Dictionary(uniqueKeysWithValues:leaves.map { node -> (String,RenameVersion) in
                        let target = node.relative.isEmpty ? step.current : step.current.appendingPathComponent(node.relative)
                        return (node.relative,try RenameVersion.read(target))
                    })
                    for node in leaves {
                        try token.check();try validateExecution?()
                        let source = node.relative.isEmpty ? entry.source : entry.source.appendingPathComponent(node.relative)
                        let target = node.relative.isEmpty ? step.current : step.current.appendingPathComponent(node.relative)
                        let relativeParent = (node.relative as NSString).deletingLastPathComponent
                        let parentVersion = node.relative.isEmpty ? entry.sourceParentVersion : entry.tree.nodes.first { $0.relative == relativeParent && $0.directory }!.version
                        let fd = try recoveryParent(source,parentVersion);defer { close(fd) }
                        guard try RenameVersion.read(fd,source.lastPathComponent) == node.version,try RenameVersion.read(target) == targets[node.relative] else { throw recoveryError("Quelle oder veröffentlichte Kopie wurde verändert. Quelle bleibt erhalten.") }
                        let saved = source.deletingLastPathComponent().appendingPathComponent(".zweicommander-move-"+UUID().uuidString)
                        let recoveryID = try history?.stageBackup(original:source,stored:saved,version:node.version)
                        guard renameatx_np(fd,source.lastPathComponent,fd,saved.lastPathComponent,UInt32(RENAME_EXCL)) == 0 else { throw recoveryError("Quelle konnte nicht zum Entfernen vorbereitet werden.") }
                        do {
                            guard try node.version.sameAfterRename(RenameVersion.read(fd,saved.lastPathComponent)),try RenameVersion.read(target) == targets[node.relative],
                                  try RenameVersion.read(source.deletingLastPathComponent()).sameObject(parentVersion) else { throw recoveryError("Dateistand wurde beim Verschieben verändert.") }
                            try token.check()
                            detail = "Entferne geprüfte Quelle · "+source.lastPathComponent;emit()
                            try token.check()
                            guard try node.version.sameAfterRename(RenameVersion.read(fd,saved.lastPathComponent)),try RenameVersion.read(target) == targets[node.relative] else { throw recoveryError("Dateistand wurde vor dem Entfernen verändert.") }
                            guard unlinkat(fd,saved.lastPathComponent,0) == 0 else { throw recoveryError("Kopierte Quelle konnte nicht entfernt werden.") }
                        } catch {
                            if renameatx_np(fd,saved.lastPathComponent,fd,source.lastPathComponent,UInt32(RENAME_EXCL)) != 0 { throw recoveryError("Quellinhalt bleibt gesichert unter "+saved.path+". "+error.localizedDescription) }
                            if let recoveryID { try? history?.forgetBackup(recoveryID) };throw error
                        }
                        report.undo.append(UndoStep(current:target,original:source,backup:node.relative.isEmpty ? step.backup : nil,stamp:try FileStamp(target)))
                        if let recoveryID { try history?.forgetBackup(recoveryID) }
                    }
                    // Source folders may still contain excluded, new, or empty objects.
                    items[index].state = .completed;items[index].message = "Passende Dateien verschoben · Quellordner erhalten"
                    report.completed.append(step.current);emit()
                } catch {
                    items[index].state = token.isCancelled ? .cancelled : .failed;items[index].message = error.localizedDescription
                    report.errors.append(entry.source.lastPathComponent+": "+error.localizedDescription)
                    if token.isCancelled || plan.policy == .stop { break }
                }
            }
        } catch { report.errors.append(error.localizedDescription) }
        for index in items.indices where [.waiting,.running].contains(items[index].state) { items[index].state = token.isCancelled ? .cancelled : .failed;items[index].message = "Nicht abgeschlossen" }
        detail = report.errors.isEmpty ? "Gefiltertes Verschieben abgeschlossen · Quellordner erhalten" : "Angehalten · fertige Schritte bleiben erhalten"
        emit();return report
    }
}
