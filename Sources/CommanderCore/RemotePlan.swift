import Foundation
import Darwin

public enum RemoteDirection { case upload,download }
public struct RemotePlannedNode: Identifiable {
    public let id = UUID()
    public let relative: String,remotePath: String
    public let local: URL
    public let entry: RemoteEntry
    let localVersion: RenameVersion?
}
public struct RemoteTransferPlan {
    public let direction: RemoteDirection
    public let endpointID: String,remoteDirectory: String
    public let localDirectory: URL
    public let nodes: [RemotePlannedNode]
    let destinationVersion: RenameVersion?
    public var rootNames: [String] { nodes.filter { !$0.relative.contains("/") }.map(\.relative) }
    public var bytes: Int64 { nodes.filter { !$0.entry.isDirectory }.reduce(0) { $0+$1.entry.size } }
    public var files: Int { nodes.filter { !$0.entry.isDirectory }.count }
    public var initialItems: [TransferItemProgress] {
        nodes.map { node in
            let remote = URL(string:"remote:/")!.appendingPathComponent(node.remotePath)
            return TransferItemProgress(id:node.id,source:direction == .upload ? node.local : remote,target:direction == .upload ? remote : node.local,state:.waiting,bytes:0,totalBytes:node.entry.isDirectory ? 0 : node.entry.size,isByteTracked:true,message:"")
        }
    }
}
public struct RemoteTransferResult { public let files: Int,bytes: Int64 }
public enum RemotePlanner {
    public static let maximumNodes = 10000
    private static func folded(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    private static func validate(_ nodes: [RemotePlannedNode]) throws {
        guard !nodes.isEmpty,nodes.count <= maximumNodes else { throw CommanderError.message("Remote-Auftrag: 1 bis 10.000 Dateien und Ordner auswählen.") }
        var paths: Set<String> = [],total: Int64 = 0
        for node in nodes {
            try RemoteService.validatePath(node.remotePath)
            guard node.relative.split(separator:"/").count <= 100,paths.insert(folded(node.relative)).inserted,!node.entry.isLink,node.entry.size >= 0 else { throw CommanderError.message("Nicht eindeutiger, zu tiefer oder nicht regulärer Remote-Dateibaum.") }
            if !node.entry.isDirectory { let next = total.addingReportingOverflow(node.entry.size);guard !next.overflow else { throw CommanderError.message("Remote-Gesamtgröße ist zu groß.") };total = next.partialValue }
        }
    }
    private static func absent(_ names: [String],in entries: [RemoteEntry]) throws {
        let existing = Set(entries.map { folded($0.name) })
        if let occupied = names.first(where: { existing.contains(folded($0)) }) { throw CommanderError.message("Ziel ist bereits belegt: "+occupied) }
    }
    public static func upload(_ session: RemoteTransport,sources: [URL],to path: String,token: CancellationToken = .init()) throws -> RemoteTransferPlan {
        let remote = try RemoteService.normalized(path)
        guard !sources.isEmpty,sources.count <= maximumNodes else { throw CommanderError.message("Quellauswahl prüfen.") }
        var nodes: [RemotePlannedNode] = []
        func scan(_ url: URL,_ relative: String,_ depth: Int) throws {
            try token.check();try FileSystem.validateName(url.lastPathComponent);try RemoteService.validatePath(relative)
            guard nodes.count < maximumNodes,depth <= 100 else { throw CommanderError.message("Remote-Auftrag ist zu groß oder zu tief.") }
            let version = try RenameVersion.read(url)
            guard version.isDirectory || version.isRegularFile,version.size >= 0 else { throw CommanderError.message("Verknüpfungen und Spezialdateien werden nicht übertragen: "+url.lastPathComponent) }
            let entry = RemoteEntry(name:url.lastPathComponent,isDirectory:version.isDirectory,size:version.isDirectory ? 0 : Int64(version.size))
            nodes.append(RemotePlannedNode(relative:relative,remotePath:RemoteService.child(remote,relative),local:url,entry:entry,localVersion:version))
            if version.isDirectory {
                for child in try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { try scan(child,relative+"/"+child.lastPathComponent,depth+1) }
            }
        }
        let normalized = sources.map { FileSystem.canonical($0.deletingLastPathComponent()).appendingPathComponent($0.lastPathComponent) }
        for (index,source) in normalized.enumerated() {
            guard !normalized.enumerated().contains(where: { $0.offset != index && FileSystem.isInside(source,$0.element) }) else { throw CommanderError.message("Überlappende Quellordner bitte getrennt auswählen.") }
            try scan(source,source.lastPathComponent,0)
        }
        try validate(nodes);try absent(sources.map(\.lastPathComponent),in:session.list(remote))
        return RemoteTransferPlan(direction:.upload,endpointID:session.endpointID,remoteDirectory:remote,localDirectory:sources[0].deletingLastPathComponent(),nodes:nodes,destinationVersion:nil)
    }
    public static func download(_ session: RemoteTransport,entries: [RemoteEntry],path: String,to directory: URL,token: CancellationToken = .init()) throws -> RemoteTransferPlan {
        let remote = try RemoteService.normalized(path),directory = FileSystem.canonical(directory),parent = try RenameVersion.read(directory)
        guard parent.isDirectory,!entries.isEmpty else { throw CommanderError.message("Lokalen Zielordner und Remote-Auswahl prüfen.") }
        let current = try session.list(remote)
        for entry in entries { guard current.contains(entry) else { throw CommanderError.message("Serverauswahl wurde verändert; Liste aktualisieren.") } }
        var nodes: [RemotePlannedNode] = []
        func scan(_ entry: RemoteEntry,_ relative: String,_ depth: Int) throws {
            try token.check();try FileSystem.validateName(entry.name);try RemoteService.validatePath(entry.name)
            guard nodes.count < maximumNodes,depth <= 100,!entry.isLink else { throw CommanderError.message("Remote-Baum zu groß, zu tief oder enthält Verknüpfungen.") }
            let path = RemoteService.child(remote,relative)
            nodes.append(RemotePlannedNode(relative:relative,remotePath:path,local:directory.appendingPathComponent(relative),entry:entry,localVersion:nil))
            if entry.isDirectory { for child in try session.list(path) { try scan(child,relative+"/"+child.name,depth+1) } }
        }
        for entry in entries { try scan(entry,entry.name,0) };try validate(nodes)
        try localAbsent(entries.map(\.name),directory)
        return RemoteTransferPlan(direction:.download,endpointID:session.endpointID,remoteDirectory:remote,localDirectory:directory,nodes:nodes,destinationVersion:parent)
    }
    private static func localAbsent(_ names: [String],_ directory: URL) throws {
        try absent(names,in:FileManager.default.contentsOfDirectory(atPath:directory.path).map { RemoteEntry(name:$0,isDirectory:false) })
    }
    private static func validateSource(_ plan: RemoteTransferPlan,_ session: RemoteTransport,_ token: CancellationToken) throws {
        if plan.direction == .upload {
            let roots = plan.nodes.filter { !$0.relative.contains("/") }
            var actual: Set<String> = []
            for root in roots {
                actual.insert(root.relative)
                if root.entry.isDirectory { try FileSystem.walk(root.local,token:token) { actual.insert(root.relative+"/"+(try FileSystem.relativePath(of:$0,inside:root.local))) } }
            }
            guard actual == Set(plan.nodes.map(\.relative)) else { throw CommanderError.message("Quellbaum wurde seit der Vorschau verändert.") }
            for node in plan.nodes { try token.check();guard try RenameVersion.read(node.local) == node.localVersion else { throw CommanderError.message("Quelle wurde verändert: "+node.relative) } }
        } else {
            var listings: [String:[RemoteEntry]] = [:]
            for node in plan.nodes {
                try token.check();let parent = (node.remotePath as NSString).deletingLastPathComponent
                if listings[parent] == nil { listings[parent] = try session.list(parent) }
                guard listings[parent]!.contains(node.entry) else { throw CommanderError.message("Serverdatei wurde verändert: "+node.relative) }
                if node.entry.isDirectory {
                    let children = try session.list(node.remotePath);listings[node.remotePath] = children
                    let expected = plan.nodes.filter { ($0.remotePath as NSString).deletingLastPathComponent == node.remotePath }.map(\.entry)
                    guard children.count == expected.count,Set(children.map(\.name)) == Set(expected.map(\.name)) else { throw CommanderError.message("Serverordner wurde seit der Vorschau verändert.") }
                }
            }
        }
    }
    public static func execute(_ plan: RemoteTransferPlan,using session: RemoteTransport,token: CancellationToken = .init(),progress: @escaping (TransferProgress)->Void = { _ in }) throws -> RemoteTransferResult {
        var items = plan.initialItems,last = Date.distantPast,published: Set<String> = [],detail = "Prüfe Remote-Dateiplan …"
        func emit(_ force: Bool = true) {
            guard force || Date().timeIntervalSince(last) >= 0.08 else { return };last = Date()
            let count = items.reduce(Int64(0)) { $0+$1.bytes }
            let complete = items.allSatisfy { $0.state == .completed }
            progress(TransferProgress(detail:detail,bytes:count,totalBytes:plan.bytes,measuredBytes:true,fraction:plan.bytes > 0 ? (complete ? 1 : min(0.999,Double(count)/Double(plan.bytes))) : nil,items:items))
        }
        emit()
        do {
            guard session.endpointID == plan.endpointID else { throw CommanderError.message("Dieser Plan gehört zu einer anderen Verbindung.") }
            try token.check();try validateSource(plan,session,token)
            if plan.direction == .upload { try absent(plan.rootNames,in:session.list(plan.remoteDirectory)) }
            else {
                guard try RenameVersion.read(plan.localDirectory).sameObject(plan.destinationVersion!) else { throw CommanderError.message("Lokaler Zielordner wurde ersetzt.") }
                try localAbsent(plan.rootNames,plan.localDirectory)
            }
            for root in plan.rootNames {
                let indexes = plan.nodes.indices.filter { plan.nodes[$0].relative == root || plan.nodes[$0].relative.hasPrefix(root+"/") }
                if plan.direction == .download {
                    try downloadRoot(plan,indexes,session,token) { index,count,complete in
                        let firstBytes = items[index].bytes == 0 && count > 0
                        items[index].state = complete ? .completed : .running;items[index].bytes = min(max(items[index].bytes,count),items[index].totalBytes);detail = plan.nodes[index].relative;emit(complete || firstBytes)
                    }
                    published.insert(root)
                } else {
                    for index in indexes {
                        try token.check();let node = plan.nodes[index]
                        items[index].state = .running;detail = node.relative;emit()
                        guard try RenameVersion.read(node.local) == node.localVersion else { throw CommanderError.message("Uploadquelle wurde seit der Vorschau verändert.") }
                        try absent([node.entry.name],in:session.list((node.remotePath as NSString).deletingLastPathComponent))
                        if node.entry.isDirectory { try session.mkdir(node.remotePath) }
                        else {
                            let fd = open(node.local.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
                            guard fd >= 0 else { throw CommanderError.message("Uploadquelle nicht lesbar.") };defer { close(fd) }
                            guard try recoveryFDVersion(fd) == node.localVersion else { throw CommanderError.message("Uploadquelle wurde ersetzt.") }
                            try session.upload(fd,size:node.entry.size,to:node.remotePath) { count in
                                let firstBytes = items[index].bytes == 0 && count > 0
                                items[index].bytes = min(max(items[index].bytes,count),node.entry.size);emit(firstBytes)
                            }
                            guard try recoveryFDVersion(fd) == node.localVersion,try RenameVersion.read(node.local) == node.localVersion else { throw CommanderError.message("Uploadquelle wurde während der Übertragung verändert.") }
                            let after = try session.list((node.remotePath as NSString).deletingLastPathComponent)
                            guard after.contains(where: { $0.name == node.entry.name && !$0.isLink && !$0.isDirectory && $0.size == node.entry.size }) else { throw CommanderError.message("Server bestätigt die hochgeladene Dateigröße nicht.") }
                        }
                        items[index].bytes = items[index].totalBytes;items[index].state = .completed;emit()
                    }
                    published.insert(root)
                }
            }
            detail = "Remote-Übertragung abgeschlossen";emit();return RemoteTransferResult(files:plan.files,bytes:plan.bytes)
        } catch {
            for index in items.indices {
                let root = plan.nodes[index].relative.split(separator:"/").first.map(String.init) ?? ""
                if plan.direction == .download && !published.contains(root) || [.waiting,.running].contains(items[index].state) {
                    items[index].state = token.isCancelled ? .cancelled : .failed;items[index].message = "Nicht abgeschlossen"
                }
            }
            detail = error.localizedDescription;emit();throw error
        }
    }
    private static func downloadRoot(_ plan: RemoteTransferPlan,_ indexes: [Int],_ session: RemoteTransport,_ token: CancellationToken,_ update: @escaping (Int,Int64,Bool)->Void) throws {
        let first = plan.nodes[indexes[0]],directory = plan.localDirectory,parent = plan.destinationVersion!
        let stage = directory.appendingPathComponent(".zweicommander-download-"+UUID().uuidString)
        let parentFD = try recoveryParent(stage,parent);defer { close(parentFD) }
        var owned: [String:RenameVersion] = [:],published = false
        defer {
            if !published,let root = owned[""],(try? RenameVersion.read(stage)).map({ root.sameObject($0) }) == true,
               (try? RenameVersion.read(directory)).map({ parent.sameObject($0) }) == true { try? FileManager.default.removeItem(at:stage) }
        }
        func parentFDFor(_ relative: String) throws -> Int32 {
            if relative.isEmpty { return dup(parentFD) }
            var fd = dup(parentFD),prefix = ""
            do {
                for part in ([stage.lastPathComponent]+relative.split(separator:"/").dropLast().map(String.init)) {
                    let next = openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                    guard next >= 0 else { throw CommanderError.message("Download-Zwischenordner wurde verändert.") }
                    close(fd);fd = next
                    if part != stage.lastPathComponent { prefix = prefix.isEmpty ? part : prefix+"/"+part }
                    guard let expected = owned[prefix],try recoveryFDVersion(fd).sameObject(expected) else { throw CommanderError.message("Download-Zwischenordner wurde ersetzt.") }
                }
                return fd
            } catch { close(fd);throw error }
        }
        for index in indexes {
            try token.check();let node = plan.nodes[index]
            let relative = node.relative == first.relative ? "" : String(node.relative.dropFirst(first.relative.count+1))
            let fd = try parentFDFor(relative);defer { close(fd) };let leaf = relative.isEmpty ? stage.lastPathComponent : (relative as NSString).lastPathComponent
            update(index,0,false)
            if node.entry.isDirectory {
                guard mkdirat(fd,leaf,0o700) == 0 else { throw CommanderError.message("Downloadordner konnte nicht angelegt werden.") };owned[relative] = try RenameVersion.read(fd,leaf)
            } else {
                let output = openat(fd,leaf,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
                guard output >= 0 else { throw CommanderError.message("Download-Zwischendatei konnte nicht angelegt werden.") };defer { close(output) }
                owned[relative] = try recoveryFDVersion(output)
                try session.download(node.remotePath,to:output,size:node.entry.size) { update(index,$0,false) }
                guard fsync(output) == 0,try recoveryFDVersion(output).size == node.entry.size else { throw CommanderError.message("Downloadgröße stimmt nicht mit dem Plan überein.") }
                owned[relative] = try recoveryFDVersion(output)
            }
            update(index,node.entry.isDirectory ? 0 : node.entry.size,true)
        }
        let subplan = RemoteTransferPlan(direction:.download,endpointID:plan.endpointID,remoteDirectory:plan.remoteDirectory,localDirectory:directory,nodes:indexes.map { plan.nodes[$0] },destinationVersion:parent)
        try validateSource(subplan,session,token)
        var visited: Set<String> = []
        func check(_ relative: String,_ url: URL) throws {
            try token.check();let current = try RenameVersion.read(url)
            guard let expected = owned[relative],expected.isDirectory ? expected.sameObject(current) : expected == current else { throw CommanderError.message("Download-Zwischendaten wurden verändert.") };visited.insert(relative)
        }
        try check("",stage)
        if first.entry.isDirectory { try FileSystem.walk(stage,token:token) { try check(FileSystem.relativePath(of:$0,inside:stage),$0) } }
        guard visited == Set(owned.keys),try RenameVersion.read(directory).sameObject(parent) else { throw CommanderError.message("Download-Zwischenablage wurde verändert.") }
        try localAbsent([first.entry.name],directory);try token.check()
        guard renameatx_np(parentFD,stage.lastPathComponent,parentFD,first.entry.name,UInt32(RENAME_EXCL)) == 0 else { throw CommanderError.message("Downloadziel wurde inzwischen belegt; nichts ersetzt.") }
        published = true
    }
}
