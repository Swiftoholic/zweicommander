import Foundation

struct TargetVersion {
    let stamp: FileStamp?
    init(stamp: FileStamp?) { self.stamp = stamp }
    init(_ url: URL) throws { stamp = FileSystem.exists(url) ? try FileStamp(url) : nil }
    func validate(_ url: URL) throws {
        let current = FileSystem.exists(url) ? try FileStamp(url) : nil
        guard current == stamp else { throw CommanderError.message("Ziel wurde seit der Vorschau verändert: \(url.lastPathComponent)") }
    }
}
public enum PlannedObjectKind { case file, directory, symbolicLink }
public struct PlannedObject {
    public let relativePath: String
    public let source: URL
    public let kind: PlannedObjectKind
    public let bytes: Int64
    public let modified: Date
}
public struct PlannedTransfer: Identifiable {
    public let id: UUID
    public let source: URL, target: URL
    public let bytes: Int64, objectCount: Int
    public let fileCount: Int, directoryCount: Int, linkCount: Int
    public let conflict: Bool
    let tree: CopyTree
    let targetVersion: TargetVersion
    public func object(at index: Int) -> PlannedObject? {
        guard tree.nodes.indices.contains(index) else { return nil }
        let node = tree.nodes[index]
        return PlannedObject(relativePath:source.lastPathComponent+(node.relative.isEmpty ? "" : "/"+node.relative),source:node.relative.isEmpty ? source : source.appendingPathComponent(node.relative),kind:node.directory ? .directory : node.link ? .symbolicLink : .file,bytes:node.bytes,modified:node.stamp.date)
    }
}
public struct TransferPlan {
    public let kind: TransferKind
    public let policy: ConflictPolicy
    public let destination: URL
    public let filter: TransferFilter
    public let ageReference: Date?
    public let merge: MergePlan?
    let destinationVersion: FileStamp
    public let entries: [PlannedTransfer]
    public var bytes: Int64 { merge?.bytes ?? entries.reduce(0) { $0+$1.bytes } }
    public var initialItems: [TransferItemProgress] { merge?.initialItems ?? entries.map { TransferItemProgress(id:$0.id,source:$0.source,target:$0.target,state:.waiting,bytes:0,totalBytes:$0.bytes,isByteTracked:kind == .copy,message:"") } }
    public func selecting(_ ids: Set<UUID>) -> TransferPlan { TransferPlan(kind:kind,policy:policy,destination:destination,filter:filter,ageReference:ageReference,merge:merge?.selecting(ids),destinationVersion:destinationVersion,entries:entries.filter { ids.contains($0.id) }) }
    public func resolving(_ action: UUID,with decision: MergeDecision) throws -> TransferPlan {
        guard let merge else { throw CommanderError.message("Einzelentscheidungen benötigen den Zusammenführen-Modus.") }
        return TransferPlan(kind:kind,policy:policy,destination:destination,filter:filter,ageReference:ageReference,merge:try merge.resolving(action,with:decision),destinationVersion:destinationVersion,entries:entries)
    }
}
public enum TransferItemState: String, Codable { case waiting, running, completed, skipped, failed, cancelled }
public struct TransferItemProgress: Identifiable, Codable {
    public let id: UUID
    public let source: URL, target: URL
    public var state: TransferItemState
    public var bytes: Int64
    public let totalBytes: Int64
    public let isByteTracked: Bool
    public var message: String
}
public struct TransferProgress {
    public let detail: String
    public let bytes: Int64
    public let totalBytes: Int64
    public let measuredBytes: Bool
    public let fraction: Double?
    public let items: [TransferItemProgress]
}
public enum TransferPlanner {
    public static func prepare(_ urls: [URL],to destination: URL,kind: TransferKind,policy: ConflictPolicy,filter: TransferFilter = .init(),mergeFolders: Bool = false,token: CancellationToken = .init(),referenceDate: Date = Date()) throws -> TransferPlan {
        guard kind == .copy || !mergeFolders else { throw CommanderError.message("Ordnerzusammenführung ist derzeit nur beim Kopieren verfügbar.") }
        guard kind == .copy || !filter.isActive else { throw CommanderError.message("Dateifilter und Strukturkopien sind derzeit nur beim Kopieren verfügbar. Verschieben benötigt die vollständige Auswahl.") }
        _ = try CompiledTransferFilter(filter,referenceDate:referenceDate)
        let ageReference = filter.modifiedAge != nil && !filter.structureOnly ? referenceDate : nil
        guard !urls.isEmpty else { throw CommanderError.message("Keine Objekte ausgewählt.") }
        guard FileSystem.isDirectory(destination) else { throw CommanderError.message("Ziel ist kein Ordner: \(destination.path)") }
        let destinationVersion = try FileStamp(destination)
        let entries = try FileSystem.topLevelSelection(urls).compactMap { source -> PlannedTransfer? in
            try token.check()
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard FileSystem.canonical(source).path != "/" else { throw CommanderError.message("Das Wurzelverzeichnis kann nicht übertragen werden.") }
            if FileSystem.isDirectory(source) && !FileSystem.isSymlink(source) && FileSystem.isInside(destination,source) { throw CommanderError.message("Ziel liegt innerhalb des Quellordners.") }
            if FileSystem.canonical(source) == FileSystem.canonical(target) && !(kind == .copy && policy == .keepBoth) { throw CommanderError.message("Quelle und Ziel sind identisch.") }
            let tree = try CopyTree.scan(source,filter:filter,token:token,referenceDate:ageReference)
            guard !tree.nodes.isEmpty else { return nil }
            return PlannedTransfer(id:UUID(),source:source,target:target,bytes:tree.bytes,objectCount:tree.nodes.count,fileCount:tree.nodes.filter { !$0.directory && !$0.link }.count,directoryCount:tree.nodes.filter(\.directory).count,linkCount:tree.nodes.filter(\.link).count,conflict:FileSystem.exists(target),tree:tree,targetVersion:try TargetVersion(target))
        }
        let merge = mergeFolders ? try MergePlan.prepare(entries,to:destination,policy:policy,token:token) : nil
        return TransferPlan(kind:kind,policy:policy,destination:destination,filter:filter,ageReference:ageReference,merge:merge,destinationVersion:destinationVersion,entries:entries)
    }
    public static func execute(_ plan: TransferPlan,token: CancellationToken = .init(),validateExecution: (() throws -> Void)? = nil,progress: @escaping (TransferProgress) -> Void = { _ in }) -> OperationReport {
        if let merge = plan.merge { return merge.execute(entries:plan.entries,token:token,validateExecution:validateExecution,progress:progress) }
        var report = OperationReport()
        var items = plan.initialItems
        var last = Date.distantPast, detail = "Prüfe Dateiplan …"
        var deliveredBytes = false,current: Int?
        func emit(_ force: Bool = true) {
            let copied = items.reduce(Int64(0)) { $0+$1.bytes }
            let activeBytes = current.map { items[$0].bytes } ?? 0
            guard force || (!deliveredBytes && activeBytes > 0) || Date().timeIntervalSince(last) >= 0.08 else { return }; last = Date()
            if activeBytes > 0 { deliveredBytes = true }
            let total = items.filter { $0.state != .skipped }.reduce(Int64(0)) { $0+$1.totalBytes }
            let finished = items.allSatisfy { [.completed,.skipped].contains($0.state) }
            let fraction: Double? = plan.kind == .copy && total > 0 ? (finished ? 1 : min(0.999,Double(copied)/Double(total))) : nil
            progress(TransferProgress(detail:detail,bytes:copied,totalBytes:total,measuredBytes:plan.kind == .copy,fraction:fraction,items:items))
        }
        emit()
        do {
            try token.check()
            try validateExecution?()
            guard FileSystem.isDirectory(plan.destination) else { throw CommanderError.message("Zielordner ist nicht mehr verfügbar.") }
            guard try FileStamp(plan.destination).sameObject(as:plan.destinationVersion) else { throw CommanderError.message("Zielordner wurde seit der Vorschau ersetzt.") }
            // Validate every selected row before changing any destination.
            for entry in plan.entries { try entry.tree.validate(entry.source,token:token); try entry.targetVersion.validate(entry.target) }
        } catch {
            report.errors.append(error.localizedDescription)
            for i in items.indices { items[i].state = token.isCancelled ? .cancelled : .failed; items[i].message = error.localizedDescription }
            detail = token.isCancelled ? "Abgebrochen" : "Dateiplan nicht mehr aktuell"; emit(); return report
        }
        for (index,entry) in plan.entries.enumerated() {
            do {
                try token.check()
                try validateExecution?()
                current = index;deliveredBytes = false
                items[index].state = .running; detail = entry.source.lastPathComponent; emit()
                let step = try FileOperations.transferPrepared(entry.source,to:entry.target,kind:plan.kind,policy:plan.policy,token:token,tree:entry.tree,expectedTarget:entry.targetVersion,validateTarget:validateExecution) { name,bytes,_ in
                    items[index].bytes = max(items[index].bytes,bytes); detail = name; emit(false)
                }
                if let step {
                    items[index].state = .completed; items[index].message = step.current.lastPathComponent
                    report.completed.append(step.current); report.undo.append(step)
                } else { items[index].state = .skipped; report.skipped.append(entry.source) }
            } catch {
                items[index].state = token.isCancelled ? .cancelled : .failed; items[index].message = error.localizedDescription
                report.errors.append(entry.source.lastPathComponent+": "+error.localizedDescription)
                if token.isCancelled || plan.policy == .stop {
                    for i in items.indices where items[i].state == .waiting { items[i].state = .cancelled; items[i].message = "Nicht ausgeführt" }
                    emit(); break
                }
            }
            emit()
        }
        detail = token.isCancelled ? "Abgebrochen · fertige Schritte bleiben erhalten" : "\(report.completed.count) abgeschlossen · \(report.skipped.count) übersprungen · \(report.errors.count) Fehler"
        emit(); return report
    }
}
