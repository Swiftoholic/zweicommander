import Foundation
import Darwin

public enum ArchiveConflictPolicy:String,CaseIterable {
    case review,skip,replace,replaceOlder,keepBoth
    public var title:String {
        switch self { case .review:return "Einzeln entscheiden";case .skip:return "Alle Konflikte überspringen";case .replace:return "Dateien überschreiben";case .replaceOlder:return "Nur ältere Dateien überschreiben";case .keepBoth:return "Beide behalten" }
    }
}
public enum ArchiveConflictDecision:Equatable { case pending,skip,replace,keepBoth,rename(String) }
public enum ArchiveTargetKind { case file,directory,link,other }
public struct ArchiveTargetInfo {
    public let kind:ArchiveTargetKind,bytes:Int64,modified:Date
    init(_ version:RenameVersion) {
        kind = version.isDirectory ? .directory : version.isRegularFile ? .file : version.mode & S_IFMT == S_IFLNK ? .link : .other
        bytes = max(0,version.size);modified = version.modified
    }
}
public struct ArchiveMergeAction:Identifiable {
    public let id:UUID,member:ArchiveMember,targetInfo:ArchiveTargetInfo?,conflict:Bool,canReplace:Bool
    public private(set) var decision:ArchiveConflictDecision
    public private(set) var alternatePath:String?
    let version:RenameVersion?,blockedBy:String?,suggestedAlternatePath:String?
    init(member:ArchiveMember,version:RenameVersion?,blockedBy:String?,alternate:String?,sourceVersion:RenameVersion) {
        id = UUID();self.member = member;self.version = version;self.blockedBy = blockedBy;alternatePath = alternate;suggestedAlternatePath = alternate
        targetInfo = version.map(ArchiveTargetInfo.init);conflict = blockedBy == nil && version != nil && !(member.isDirectory && version?.isDirectory == true)
        canReplace = !member.isDirectory && version?.isRegularFile == true && version?.sameObject(sourceVersion) == false
        decision = conflict ? .pending : .replace
    }
    mutating func choose(_ value:ArchiveConflictDecision) { decision = value }
    mutating func resetAlternate() { alternatePath = suggestedAlternatePath }
    mutating func rename(_ name:String) { alternatePath = name;decision = .rename((name as NSString).lastPathComponent) }
}

/// Header-only review against a frozen, directly traversed destination tree.
public struct ArchiveMergePlan {
    public let catalog:ArchiveCatalog,destination:URL
    public private(set) var actions:[ArchiveMergeAction]
    let selection:ArchiveSelection,rootVersion:RenameVersion,bindings:[String:RenameVersion]
    private let indexes:[String:Int]
    public var rows:[ArchiveMember] { actions.map(\.member) }
    public var totalBytes:Int64 { actions.filter { !isSkipped($0) && !$0.member.isDirectory }.reduce(0) { $0+$1.member.size } }
    public var unresolvedCount:Int { actions.filter { $0.conflict && $0.decision == .pending }.count }
    public var conflictCount:Int { actions.filter(\.conflict).count }
    public var skippedCount:Int { actions.filter(isSkipped).count }
    public var replacingCount:Int { actions.filter { $0.conflict && $0.decision == .replace && !isSkipped($0) }.count }
    public init(catalog:ArchiveCatalog,to destination:URL,selection:[String]? = nil,relativeTo basePath:String = "",policy:ArchiveConflictPolicy = .review,maximumBytes:Int64 = 100*1024*1024*1024,token:CancellationToken = .init()) throws {
        guard ArchiveService.isLocal(destination) else { throw CommanderError.message("Ein lokaler Zielordner wird benötigt.") }
        let content = try ArchiveSelection(catalog:catalog,selection:selection,basePath:basePath,maximumBytes:maximumBytes)
        let root = destination.path == "/" ? destination : FileSystem.canonical(destination.deletingLastPathComponent()).appendingPathComponent(destination.lastPathComponent)
        let version = try RenameVersion.read(root);guard version.isDirectory else { throw CommanderError.message("Der vorhandene Zielordner muss ein direktes Verzeichnis sein.") }
        let tree = try ArchiveDestination(root,version:version);defer { tree.close() }
        var members = Dictionary(uniqueKeysWithValues:content.rows.map { ($0.path,$0) })
        for member in content.rows {
            var parent = (member.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if members[parent] == nil {
                    let path = basePath.isEmpty ? parent : basePath+"/"+parent
                    let original = catalog.member(at:path)
                    members[parent] = ArchiveMember(path:parent,size:0,isDirectory:true,modified:original?.modified ?? .distantPast,permissions:original?.permissions ?? 0o755)
                }
                guard members.count <= ArchiveCatalog.maximumEntries else { throw CommanderError.message("Zu viele Entpackordner und Einträge.") }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let values = members.values.sorted { a,b in let x = a.path.split(separator:"/").count,y = b.path.split(separator:"/").count;return x == y ? a.path < b.path : x < y }
        var reserved = Set<String>()
        for value in values {
            try FileSystem.validateName((value.path as NSString).lastPathComponent)
            guard reserved.insert(Self.key(value.path)).inserted else { throw CommanderError.message("Archivnamen unterscheiden sich nur durch Großschreibung oder Unicode-Darstellung: "+value.path) }
        }
        var result:[ArchiveMergeAction] = [],blocked:[String:String] = [:],missing = Set<String>(),folders:[String:RenameVersion] = ["":version]
        let sourceVersion = try RenameVersion.read(catalog.source)
        func alternate(_ member:ArchiveMember) throws -> String {
            let parent = (member.path as NSString).deletingLastPathComponent,name = (member.path as NSString).lastPathComponent
            let ext = member.isDirectory ? "" : (name as NSString).pathExtension,stem = member.isDirectory || ext.isEmpty ? name : (name as NSString).deletingPathExtension
            for number in 2...100_000 {
                try token.check();var prefix = stem,tail = " (\(number))"+(ext.isEmpty ? "" : "."+ext)
                if tail.utf8.count >= 250 { prefix = name;tail = " (\(number))" }
                while prefix.utf8.count+tail.utf8.count > 255 { prefix.removeLast() }
                let leaf = prefix+tail,candidate = parent.isEmpty ? leaf : parent+"/"+leaf
                if !reserved.contains(Self.key(candidate)),try tree.read(candidate,bindings:folders) == nil { try FileSystem.validateName(leaf);reserved.insert(Self.key(candidate));return candidate }
            }
            throw CommanderError.message("Kein freier Alternativname für "+name)
        }
        for member in values {
            try token.check();let parent = (member.path as NSString).deletingLastPathComponent,blocker = blocked[parent]
            let target = blocker == nil && !missing.contains(parent) ? try tree.read(member.path,bindings:folders) : nil
            let conflict = blocker == nil && target != nil && !(member.isDirectory && target?.isDirectory == true)
            result.append(ArchiveMergeAction(member:member,version:target,blockedBy:blocker,alternate:conflict ? try alternate(member) : nil,sourceVersion:sourceVersion))
            if member.isDirectory {
                if let blocker { blocked[member.path] = blocker }
                else if conflict { blocked[member.path] = member.path }
                else if let target { folders[member.path] = target }
                else { missing.insert(member.path) }
            }
        }
        self.catalog = catalog;self.destination = root;self.selection = content;rootVersion = version;bindings = folders;actions = result
        indexes = Dictionary(uniqueKeysWithValues:result.enumerated().map { ($0.element.member.path,$0.offset) })
        actions = applying(policy).actions
    }
    static func key(_ path:String) -> String { path.precomposedStringWithCanonicalMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX")) }
    public func action(for path:String) -> ArchiveMergeAction? { indexes[path].map { actions[$0] } }
    public func isSkipped(_ action:ArchiveMergeAction) -> Bool {
        if action.decision == .skip { return true }
        return action.blockedBy.flatMap { self.action(for:$0) }?.decision == .skip
    }
    public func isBlocked(_ action:ArchiveMergeAction) -> Bool {
        action.blockedBy.flatMap { self.action(for:$0) }?.decision == .pending
    }
    public func targetPath(for action:ArchiveMergeAction) -> String {
        if let path = action.blockedBy,let parent = self.action(for:path) { return targetPath(for:parent)+String(action.member.path.dropFirst(path.count)) }
        switch action.decision { case .keepBoth,.rename:return action.alternatePath ?? action.member.path;default:return action.member.path }
    }
    public func description(of action:ArchiveMergeAction) -> String {
        if isSkipped(action) { return "Überspringen" };if isBlocked(action) { return "Übergeordneten Konflikt klären" }
        if action.conflict {
            switch action.decision { case .pending:return "Entscheidung fehlt";case .skip:return "Überspringen";case .replace:return "Überschreiben mit Sicherung";case .keepBoth,.rename:return "Neuer Name: "+(targetPath(for:action) as NSString).lastPathComponent }
        }
        return action.member.isDirectory ? (action.version?.isDirectory == true && action.blockedBy == nil ? "Ordner beibehalten" : "Ordner anlegen") : "Entpacken"
    }
    public func applying(_ policy:ArchiveConflictPolicy) -> Self {
        var result = self
        for index in result.actions.indices where result.actions[index].conflict {
            let action = result.actions[index],choice:ArchiveConflictDecision
            switch policy {
            case .review:choice = .pending
            case .skip:choice = .skip
            case .keepBoth:choice = .keepBoth
            case .replace:choice = action.canReplace ? .replace : .pending
            case .replaceOlder:
                if action.canReplace,action.member.modified.timeIntervalSince1970 > 0,let target = action.targetInfo { choice = action.member.modified > target.modified ? .replace : .skip }
                else { choice = .pending }
            }
            result.actions[index].resetAlternate();result.actions[index].choose(choice)
        }
        return result
    }
    public func resolving(_ path:String,with choice:ArchiveConflictDecision) throws -> Self {
        guard let index = indexes[path],actions[index].conflict else { throw CommanderError.message("Dieser Eintrag hat keinen einzeln entscheidbaren Konflikt.") }
        var result = self
        switch choice {
        case .replace:guard actions[index].canReplace else { throw CommanderError.message("Ordner, Verknüpfungen, Spezialdateien und das Quellarchiv werden nicht überschrieben. Überspringen oder einen neuen Namen wählen.") }
        case .rename(let name):
            try FileSystem.validateName(name)
            let parent = (path as NSString).deletingLastPathComponent,target = parent.isEmpty ? name : parent+"/"+name,key = Self.key(target)
            guard !actions.enumerated().contains(where:{ $0.offset != index && (Self.key($0.element.member.path) == key || $0.element.alternatePath.map(Self.key) == key) }),key != Self.key(path) else { throw CommanderError.message("Dieser Name ist bereits in der Vorschau reserviert.") }
            let tree = try ArchiveDestination(destination,version:rootVersion);defer { tree.close() }
            guard try tree.read(target,bindings:bindings) == nil else { throw CommanderError.message("Dieser Zielname ist bereits belegt.") }
            result.actions[index].rename(target)
        case .keepBoth:result.actions[index].resetAlternate()
        default:break
        }
        result.actions[index].choose(choice);return result
    }
    public func validate(token:CancellationToken = .init()) throws {
        try token.check();try catalog.validateSource()
        guard unresolvedCount == 0 else { throw CommanderError.message("\(unresolvedCount) Konflikt(e) vor dem Start entscheiden.") }
        let tree = try ArchiveDestination(destination,version:rootVersion);defer { tree.close() }
        var targets = Set<String>()
        for action in actions where !isSkipped(action) {
            try token.check();let path = targetPath(for:action)
            guard targets.insert(Self.key(path)).inserted else { throw CommanderError.message("Mehrere Einträge verwenden denselben Zielpfad: "+path) }
            if action.blockedBy == nil {
                let current = try tree.read(action.member.path,bindings:bindings)
                if action.member.isDirectory,let old = action.version,old.isDirectory { guard current.map(old.sameObject) == true else { throw CommanderError.message("Ein Zielordner wurde seit der Vorschau ersetzt: "+action.member.path) } }
                else { guard current == action.version else { throw CommanderError.message("Ziel wurde seit der Vorschau geändert: "+action.member.path) } }
                switch action.decision { case .keepBoth,.rename:guard try tree.read(path,bindings:bindings) == nil else { throw CommanderError.message("Der neue Zielname wurde inzwischen belegt: "+path) };default:break }
            }
        }
    }
    public var initialItems:[TransferItemProgress] {
        actions.map { action in TransferItemProgress(id:action.id,source:catalog.source,target:destination.appendingPathComponent(targetPath(for:action)),state:isSkipped(action) ? .skipped : .waiting,bytes:0,totalBytes:action.member.isDirectory ? 0 : action.member.size,isByteTracked:true,message:action.member.path+" · "+description(of:action)) }
    }
}

/// Every traversal starts at the original root descriptor and refuses directory links.
final class ArchiveDestination {
    private(set) var fd:Int32
    let url:URL,version:RenameVersion
    init(_ url:URL,version:RenameVersion) throws {
        self.url = url;self.version = version;fd = open(url.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw CommanderError.message("Zielordner kann nicht direkt geöffnet werden.") }
        var value = stat();guard fstat(fd,&value) == 0,version.sameObject(RenameVersion(value)) else { close();throw CommanderError.message("Der Zielordner wurde ersetzt.") }
    }
    deinit { close() }
    func close() { if fd >= 0 { Darwin.close(fd);fd = -1 } }
    func validateRoot() throws { guard try version.sameObject(RenameVersion.read(url)) else { throw CommanderError.message("Der Zielordner wurde seit der Vorschau ersetzt oder verschoben.") } }
    func folder(_ path:String,bindings:[String:RenameVersion]) throws -> Int32 {
        var current = dup(fd),relative = "";guard current >= 0 else { throw CommanderError.message("Zielordner nicht verfügbar.") }
        do {
            for part in path.split(separator:"/").map(String.init) {
                relative = relative.isEmpty ? part : relative+"/"+part
                guard let expected = bindings[relative],expected.isDirectory else { throw CommanderError.message("Zielordner fehlt in der geprüften Vorschau: "+relative) }
                let next = openat(current,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard next >= 0 else { throw CommanderError.message("Zielordner wurde ersetzt oder ist nicht zugänglich: "+relative) }
                Darwin.close(current);current = next;var value = stat()
                guard fstat(current,&value) == 0,expected.sameObject(RenameVersion(value)) else { throw CommanderError.message("Zielordner wurde ersetzt: "+relative) }
            }
            return current
        } catch { Darwin.close(current);throw error }
    }
    func read(_ path:String,bindings:[String:RenameVersion]) throws -> RenameVersion? {
        let parent = (path as NSString).deletingLastPathComponent
        // A planned new parent makes its descendants absent until publication.
        if !parent.isEmpty,bindings[parent] == nil { return nil }
        let directory = try folder(parent,bindings:bindings);defer { Darwin.close(directory) }
        var value = stat()
        if fstatat(directory,(path as NSString).lastPathComponent,&value,AT_SYMLINK_NOFOLLOW) == 0 { return RenameVersion(value) }
        if errno == ENOENT { return nil };throw CommanderError.message("Ziel kann nicht geprüft werden: "+path+" · "+String(cString:strerror(errno)))
    }
}
