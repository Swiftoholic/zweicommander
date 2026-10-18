import Foundation

public enum MergeDecision: String,CaseIterable { case pending, skip, keepBoth, replace }
public enum MergeObjectKind { case file, directory, symbolicLink, other }
public struct MergeMetadata {
    public let kind: MergeObjectKind
    public let bytes: Int64
    public let modified: Date
    static func read(_ url: URL) throws -> MergeMetadata? {
        guard FileSystem.exists(url) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath:url.path),stamp = try FileStamp(url)
        let type = attrs[.type] as? FileAttributeType
        let kind: MergeObjectKind = type == .typeDirectory ? .directory : type == .typeSymbolicLink ? .symbolicLink : type == .typeRegular ? .file : .other
        return MergeMetadata(kind:kind,bytes:Int64(clamping:stamp.size),modified:stamp.date)
    }
}
public struct MergeAction: Identifiable {
    public let id: UUID
    public let source: URL,requestedTarget: URL
    public let sourceInfo: MergeMetadata,targetInfo: MergeMetadata?
    public let conflict: Bool
    public let allowedDecisions: [MergeDecision]
    public fileprivate(set) var decision: MergeDecision
    public let alternateTarget: URL?
    let owner: UUID,blockedBy: UUID?
    let node: CopyNode
    let targetVersion: TargetVersion
    public var target: URL { decision == .keepBoth ? alternateTarget ?? requestedTarget : requestedTarget }
}
public struct MergePlan {
    public private(set) var actions: [MergeAction]
    let base: URL,baseVersion: FileStamp
    private let byID: [UUID:Int],bySource: [String:Int]
    private init(actions: [MergeAction],base: URL,baseVersion: FileStamp) {
        self.actions = actions;self.base = base;self.baseVersion = baseVersion
        byID = Dictionary(uniqueKeysWithValues:actions.enumerated().map { ($0.element.id,$0.offset) })
        bySource = Dictionary(uniqueKeysWithValues:actions.enumerated().map { ($0.element.source.standardizedFileURL.path,$0.offset) })
    }
    public func action(for source: URL) -> MergeAction? { bySource[source.standardizedFileURL.path].map { actions[$0] } }
    public func isSkipped(_ action: MergeAction) -> Bool {
        if let blocker = action.blockedBy,let index = byID[blocker] { return actions[index].decision == .skip }
        return action.conflict && action.decision == .skip
    }
    public var unresolvedCount: Int { actions.filter { $0.blockedBy == nil && $0.conflict && $0.decision == .pending }.count }
    public var bytes: Int64 { actions.filter { !isSkipped($0) }.reduce(0) { $0+$1.node.bytes } }
    public func description(of action: MergeAction) -> String {
        if isSkipped(action) { return "Überspringen" }
        if action.blockedBy != nil { return "Übergeordneten Konflikt klären" }
        if action.conflict && action.decision == .pending { return "Entscheidung fehlt" }
        if action.node.directory { return action.targetInfo == nil ? "Ordner anlegen" : "Ordner beibehalten" }
        if action.decision == .keepBoth { return "Kopie: "+action.target.lastPathComponent }
        if action.conflict && action.decision == .replace { return "Ersetzen mit Sicherung" }
        return action.node.link ? "Verknüpfung kopieren" : "Datei kopieren"
    }
    public var initialItems: [TransferItemProgress] {
        actions.map { TransferItemProgress(id:$0.id,source:$0.source,target:$0.target,state:isSkipped($0) ? .skipped : .waiting,bytes:0,totalBytes:$0.node.bytes,isByteTracked:true,message:description(of:$0)) }
    }
    func selecting(_ owners: Set<UUID>) -> MergePlan { MergePlan(actions:actions.filter { owners.contains($0.owner) },base:base,baseVersion:baseVersion) }
    func resolving(_ id: UUID,with decision: MergeDecision) throws -> MergePlan {
        guard let index = byID[id],actions[index].allowedDecisions.contains(decision) else { throw CommanderError.message("Diese Entscheidung ist für den Konflikttyp nicht verfügbar.") }
        var result = self;result.actions[index].decision = decision;return result
    }
    static func prepare(_ entries: [PlannedTransfer],to destination: URL,policy: ConflictPolicy,token: CancellationToken) throws -> MergePlan {
        let base = FileSystem.canonical(destination),version = try FileStamp(base)
        guard try MergeMetadata.read(base)?.kind == .directory else { throw CommanderError.message("Zielordner ist nicht verfügbar.") }
        var actions: [MergeAction] = [],reserved: Set<String> = []
        // Reserve every incoming name before allocating alternate names, also on case-insensitive volumes.
        func key(_ url: URL) -> String { url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX")) }
        for entry in entries {
            guard FileSystem.canonical(entry.source) != FileSystem.canonical(entry.target) else { throw CommanderError.message("Zusammenführen in denselben Quellordner ist nicht erlaubt.") }
            for node in entry.tree.nodes {
                try token.check()
                let root = base.appendingPathComponent(entry.source.lastPathComponent)
                let target = node.relative.isEmpty ? root : root.appendingPathComponent(node.relative)
                guard reserved.insert(key(target)).inserted else { throw CommanderError.message("Mehrere Auswahlobjekte führen zum gleichen Zielnamen: "+target.lastPathComponent) }
            }
        }
        func alternate(_ target: URL) throws -> URL {
            let parent = target.deletingLastPathComponent(),ext = target.pathExtension
            let stem = ext.isEmpty ? target.lastPathComponent : target.deletingPathExtension().lastPathComponent
            for number in 2...100_000 {
                try token.check()
                let name = "\(stem) (\(number))"+(ext.isEmpty ? "" : "."+ext),candidate = parent.appendingPathComponent(name)
                if !FileSystem.exists(candidate) && reserved.insert(key(candidate)).inserted { return candidate }
            }
            throw CommanderError.message("Kein freier Alternativname für "+target.lastPathComponent)
        }
        for entry in entries {
            var blockedFolders: [String:UUID] = [:]
            for node in entry.tree.nodes {
                try token.check()
                guard actions.count < 1_000_000 else { throw CommanderError.message("Zusammenführen enthält mehr als eine Million Objekte.") }
                let source = node.relative.isEmpty ? entry.source : entry.source.appendingPathComponent(node.relative)
                let targetRoot = base.appendingPathComponent(entry.source.lastPathComponent)
                let target = node.relative.isEmpty ? targetRoot : targetRoot.appendingPathComponent(node.relative)
                let parent = (node.relative as NSString).deletingLastPathComponent
                let blocker = node.relative.isEmpty ? nil : blockedFolders[parent]
                let info = blocker == nil ? try MergeMetadata.read(target) : nil
                let conflict = blocker == nil && info != nil && !(node.directory && info?.kind == .directory)
                var allowed: [MergeDecision] = conflict ? [.pending,.skip] : []
                if conflict && !node.directory && info?.kind != .directory && info?.kind != .other { allowed += [.keepBoth,.replace] }
                let wanted: MergeDecision = policy == .skip ? .skip : policy == .keepBoth ? .keepBoth : policy == .replace ? .replace : .pending
                let choice = conflict ? (allowed.contains(wanted) ? wanted : .pending) : .replace
                let other = allowed.contains(.keepBoth) ? try alternate(target) : nil
                let expected = blocker == nil ? try TargetVersion(target) : TargetVersion(stamp:nil)
                let action = MergeAction(id:UUID(),source:source,requestedTarget:target,sourceInfo:MergeMetadata(kind:node.directory ? .directory : node.link ? .symbolicLink : .file,bytes:node.bytes,modified:node.stamp.date),targetInfo:info,conflict:conflict,allowedDecisions:allowed,decision:choice,alternateTarget:other,owner:entry.id,blockedBy:blocker,node:node,targetVersion:expected)
                actions.append(action)
                if node.directory {
                    if let blocker { blockedFolders[node.relative] = blocker }
                    else if conflict { blockedFolders[node.relative] = action.id }
                }
            }
        }
        return MergePlan(actions:actions,base:base,baseVersion:version)
    }
    func execute(entries: [PlannedTransfer],token: CancellationToken,progress: @escaping (TransferProgress) -> Void) -> OperationReport {
        var report = OperationReport(),items = initialItems
        var bindings: [String:FileStamp] = [base.path:baseVersion],created: [Int] = []
        var last = Date.distantPast,delivered = false,detail = "Prüfe Zusammenführungsplan …",current: Int?
        func emit(_ force: Bool = true) {
            let copied = items.reduce(Int64(0)) { $0+$1.bytes }
            let activeBytes = current.map { items[$0].bytes } ?? 0
            guard force || (!delivered && activeBytes > 0) || Date().timeIntervalSince(last) >= 0.08 else { return }
            last = Date();if activeBytes > 0 { delivered = true }
            let total = items.filter { $0.state != .skipped }.reduce(Int64(0)) { $0+$1.totalBytes }
            let finished = items.allSatisfy { [.completed,.skipped].contains($0.state) }
            let fraction: Double? = total > 0 ? (finished ? 1 : min(0.999,Double(copied)/Double(total))) : nil
            progress(TransferProgress(detail:detail,bytes:copied,totalBytes:total,measuredBytes:true,fraction:fraction,items:items))
        }
        func directory(_ url: URL) throws {
            guard let expected = bindings[url.path],try MergeMetadata.read(url)?.kind == .directory,try FileStamp(url).sameObject(as:expected) else { throw CommanderError.message("Zielordner wurde ersetzt oder ist nicht mehr verfügbar: "+url.path) }
        }
        func parents(_ target: URL) throws {
            var parent = target.deletingLastPathComponent()
            while true {
                guard parent.path == base.path || parent.path.hasPrefix(base.path+"/") else { throw CommanderError.message("Ziel liegt außerhalb des Zusammenführungsordners.") }
                try directory(parent);if parent.path == base.path { break };parent.deleteLastPathComponent()
            }
        }
        emit()
        do {
            try token.check()
            guard unresolvedCount == 0 else { throw CommanderError.message("\(unresolvedCount) Konflikt(e) müssen vor dem Start entschieden werden.") }
            try directory(base)
            for entry in entries { try entry.tree.validate(entry.source,token:token) }
            for action in actions where !isSkipped(action) {
                try token.check()
                if action.node.directory && action.targetInfo?.kind == .directory {
                    guard let stamp = action.targetVersion.stamp,try MergeMetadata.read(action.target)?.kind == .directory,try FileStamp(action.target).sameObject(as:stamp) else { throw CommanderError.message("Zielordner wurde seit der Vorschau ersetzt.") }
                    bindings[action.target.path] = stamp
                } else { try action.targetVersion.validate(action.requestedTarget) }
                if action.decision == .keepBoth { try TargetVersion(stamp:nil).validate(action.target) }
            }
            for (index,action) in actions.enumerated() {
                if isSkipped(action) { report.skipped.append(action.source);continue }
                current = index;delivered = false;try token.check();try parents(action.target)
                items[index].state = .running;detail = action.source.path;emit()
                if action.node.directory {
                    if action.targetInfo?.kind == .directory { try directory(action.target);items[index].state = .completed }
                    else {
                        try action.targetVersion.validate(action.target)
                        guard try FileStamp(action.source) == action.node.stamp else { throw CommanderError.message("Quellordner wurde verändert.") }
                        try FileManager.default.createDirectory(at:action.target,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                        bindings[action.target.path] = try FileStamp(action.target);created.append(index)
                        items[index].message = "Ordner angelegt · Metadaten folgen"
                    }
                } else {
                    let node = CopyNode(relative:"",stamp:action.node.stamp,directory:false,link:action.node.link,bytes:action.node.bytes)
                    let tree = CopyTree(nodes:[node],filter:.init())
                    let policy: ConflictPolicy = action.conflict && action.decision == .replace ? .replace : .stop
                    let expectation = action.decision == .keepBoth ? TargetVersion(stamp:nil) : action.targetVersion
                    let step = try FileOperations.transferPrepared(action.source,to:action.target,kind:.copy,policy:policy,token:token,tree:tree,expectedTarget:expectation,validateTarget:{ try parents(action.target) }) { _,copied,_ in
                        items[index].bytes = max(items[index].bytes,copied);emit(false)
                    }
                    if let step { report.completed.append(step.current);report.undo.append(step) }
                    items[index].state = .completed
                    items[index].message = action.target.path
                }
                emit()
            }
            current = nil
            for entry in entries { try entry.tree.validate(entry.source,token:token) }
            for index in created.reversed() {
                current = index;try token.check();let action = actions[index]
                try parents(action.target);try directory(action.target)
                guard try FileStamp(action.source) == action.node.stamp else { throw CommanderError.message("Quellordner wurde während des Vorgangs verändert.") }
                try NativeCopy.copy(action.source,to:action.target,metadataOnly:true,token:token,progress:{ _ in })
                items[index].state = .completed;items[index].message = "Ordner und Metadaten angelegt";report.completed.append(action.target);emit()
            }
            detail = "\(report.completed.count) ergänzt/ersetzt · \(report.skipped.count) übersprungen"
        } catch {
            report.errors.append(error.localizedDescription)
            if let index = current { items[index].state = token.isCancelled ? .cancelled : .failed;items[index].message = error.localizedDescription }
            for i in items.indices where [.waiting,.running].contains(items[i].state) { items[i].state = token.isCancelled ? .cancelled : .failed;items[i].message = "Nicht abgeschlossen · fertige Schritte bleiben erhalten" }
            detail = token.isCancelled ? "Abgebrochen · fertige Dateien bleiben erhalten" : error.localizedDescription
        }
        emit();return report
    }
}
