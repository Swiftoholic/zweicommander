import Foundation

public enum RemoteMutationKind { case rename,createDirectory,delete }
public struct RemoteMutationNode {
    public let path: String,entry: RemoteEntry
}
public struct RemoteMutationPlan {
    public let kind: RemoteMutationKind,endpointID: String,directory: String
    public let nodes: [RemoteMutationNode],target: String?
    let ancestors: [RemoteMutationNode]
    public var files: Int { nodes.filter { !$0.entry.isDirectory }.count }
    public var folders: Int { nodes.count-files }
}

/// A reviewed mutation never follows links, replaces names, or silently expands its selection.
public enum RemoteMutation {
    private static func fold(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
    private static func name(_ text: String) throws {
        try FileSystem.validateName(text);try RemoteService.validatePath(text)
        guard text.utf8.count <= 255 else { throw CommanderError.message("Der Servername ist zu lang.") }
    }
    private static func absent(_ text: String,in entries: [RemoteEntry]) throws {
        guard !entries.contains(where:{ fold($0.name) == fold(text) }) else { throw CommanderError.message("Der Zielname ist auf dem Server bereits belegt.") }
    }
    private static func selected(_ entries: [RemoteEntry],in listing: [RemoteEntry]) throws {
        guard !entries.isEmpty,entries.count <= 10000,Set(entries.map { fold($0.name) }).count == entries.count else { throw CommanderError.message("Eine eindeutige Serverauswahl mit höchstens 10.000 Objekten verwenden.") }
        for entry in entries {
            try name(entry.name)
            guard !entry.isLink,listing.first(where:{ $0.name == entry.name }) == entry else { throw CommanderError.message("Die Serverauswahl wurde geändert oder enthält eine Verknüpfung. Liste aktualisieren.") }
        }
    }
    private static func checkedAncestors(_ session:RemoteTransport,_ directory:String,_ token:CancellationToken) throws -> [RemoteMutationNode] {
        var parent = "/",nodes: [RemoteMutationNode] = []
        for component in directory.split(separator:"/") {
            try token.check();let name = String(component)
            guard let entry = try session.list(parent).first(where:{ $0.name == name }),entry.isDirectory,!entry.isLink else { throw CommanderError.message("Der Serverpfad enthält einen nicht lesbaren Ordner oder eine Verknüpfung. Einen direkten Serverpfad verwenden.") }
            parent = RemoteService.child(parent,name);nodes.append(RemoteMutationNode(path:parent,entry:entry))
        }
        return nodes
    }
    private static func sameAncestors(_ lhs:[RemoteMutationNode],_ rhs:[RemoteMutationNode]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs,rhs).enumerated().allSatisfy { index,pair in
            guard pair.0.path == pair.1.path else { return false }
            if index == lhs.count-1 { return pair.0.entry == pair.1.entry }
            // Activity in unrelated ancestor folders must not invalidate a reviewed child.
            return pair.0.entry.name == pair.1.entry.name && pair.0.entry.isDirectory == pair.1.entry.isDirectory && pair.0.entry.isLink == pair.1.entry.isLink && pair.0.entry.permissions == pair.1.entry.permissions
        }
    }
    public static func prepare(_ session: RemoteTransport,kind: RemoteMutationKind,directory: String,entries: [RemoteEntry] = [],newName: String = "",token: CancellationToken = .init()) throws -> RemoteMutationPlan {
        try token.check();let directory = try RemoteService.normalized(directory)
        let anchors = try checkedAncestors(session,directory,token),listing = try session.list(directory)
        if kind == .createDirectory {
            try name(newName);try absent(newName,in:listing)
            return RemoteMutationPlan(kind:kind,endpointID:session.endpointID,directory:directory,nodes:[],target:RemoteService.child(directory,newName),ancestors:anchors)
        }
        try selected(entries,in:listing)
        if kind == .rename {
            guard entries.count == 1 else { throw CommanderError.message("Zum Umbenennen genau ein Serverobjekt auswählen.") }
            try name(newName)
            guard fold(newName) != fold(entries[0].name) else { throw CommanderError.message("Einen anderen Namen wählen. Reine Änderungen der Schreibweise sind hier nicht unterstützt.") }
            try absent(newName,in:listing)
            return RemoteMutationPlan(kind:kind,endpointID:session.endpointID,directory:directory,nodes:[RemoteMutationNode(path:RemoteService.child(directory,entries[0].name),entry:entries[0])],target:RemoteService.child(directory,newName),ancestors:anchors)
        }
        var nodes: [RemoteMutationNode] = []
        func scan(_ entry: RemoteEntry,_ path: String,_ depth: Int) throws {
            try token.check();try name(entry.name)
            guard nodes.count < 10000,depth <= 100,!entry.isLink else { throw CommanderError.message("Löschplan zu groß, zu tief oder enthält Verknüpfungen. Es wurde nichts gelöscht.") }
            nodes.append(RemoteMutationNode(path:path,entry:entry))
            if entry.isDirectory {
                let children = try session.list(path)
                guard Set(children.map { fold($0.name) }).count == children.count else { throw CommanderError.message("Nicht eindeutiger Serverbaum.") }
                for child in children { try scan(child,RemoteService.child(path,child.name),depth+1) }
            }
        }
        for entry in entries { try scan(entry,RemoteService.child(directory,entry.name),1) }
        return RemoteMutationPlan(kind:kind,endpointID:session.endpointID,directory:directory,nodes:nodes,target:nil,ancestors:anchors)
    }
    public static func execute(_ plan: RemoteMutationPlan,using session: RemoteTransport,token: CancellationToken = .init(),progress: (Int,Int,String)->Void = { _,_,_ in }) throws {
        try token.check()
        guard plan.endpointID == session.endpointID else { throw CommanderError.message("Dieser Dateiplan gehört zu einer anderen Serververbindung.") }
        let roots = plan.nodes.filter { ($0.path as NSString).deletingLastPathComponent == plan.directory }.map(\.entry)
        let fresh = try prepare(session,kind:plan.kind,directory:plan.directory,entries:roots,newName:plan.target.map { ($0 as NSString).lastPathComponent } ?? "",token:token)
        guard fresh.nodes.count == plan.nodes.count,zip(fresh.nodes,plan.nodes).allSatisfy({ $0.path == $1.path && $0.entry == $1.entry }),fresh.target == plan.target,
              sameAncestors(fresh.ancestors,plan.ancestors) else { throw CommanderError.message("Der Serverbaum oder ein übergeordneter Ordner wurde seit der Vorschau geändert. Erneut prüfen; es wurde nichts ausgeführt.") }
        if plan.kind == .createDirectory,let target = plan.target { try token.check();try session.mkdir(target);progress(1,1,target);return }
        if plan.kind == .rename,let source = plan.nodes.first,let target = plan.target { try token.check();try session.rename(source.path,to:target);progress(1,1,target);return }
        for (index,node) in plan.nodes.reversed().enumerated() {
            try token.check()
            let parent = (node.path as NSString).deletingLastPathComponent
            _ = try checkedAncestors(session,parent,token)
            guard let current = try session.list(parent).first(where:{ $0.name == node.entry.name }),!current.isLink,current.isDirectory == node.entry.isDirectory,
                  node.entry.isDirectory || current == node.entry else { throw CommanderError.message("Serverobjekt wurde während des Löschens geändert. Bereits gelöschte Objekte bleiben gelöscht.") }
            if current.isDirectory,!(try session.list(node.path)).isEmpty { throw CommanderError.message("Serverordner enthält neue Objekte und bleibt erhalten. Bereits gelöschte Objekte bleiben gelöscht.") }
            try session.remove(node.path,directory:current.isDirectory);progress(index+1,plan.nodes.count,node.path)
        }
    }
}
