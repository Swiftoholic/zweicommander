import Foundation
import CArchive

/// Header-only inventory. Paths refer to members, never to extracted local files.
public struct ArchiveCatalog {
    public static let maximumEntries = 100_000
    public let source:URL,members:[ArchiveMember],nodes:[ArchiveMember]
    private let version:RenameVersion
    private let byPath:[String:ArchiveMember],children:[String:[ArchiveMember]]
    public static func read(_ url:URL,password:String? = nil,token:CancellationToken = .init()) throws -> Self {
        guard ArchiveService.isLocal(url) else { throw CommanderError.message("Für ein Archiv wird eine lokale Datei-Adresse ohne fremden Host benötigt.") }
        let source = FileSystem.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent),version = try RenameVersion.read(source)
        guard version.isRegularFile else { throw CommanderError.message("Bitte eine lokale Archivdatei ohne Verknüpfung öffnen.") }
        let reader = try ArchiveService.reader(source,password:password);defer { archive_read_free(reader) }
        var header:OpaquePointer?,values:[ArchiveMember] = [],names = Set<String>()
        while true {
            try token.check();let code = archive_read_next_header(reader,&header)
            if code == 1 { break };guard code == 0,let header else { throw ArchiveService.failure(reader) }
            let item = try ArchiveService.member(header);if item.path.isEmpty { continue }
            guard item.path.utf8.count <= 16_384,item.path.split(separator:"/").count <= 100,names.insert(item.path).inserted else { throw CommanderError.message("Doppelte oder zu lange Archivpfade: "+item.path) }
            guard values.count < maximumEntries else { throw CommanderError.message("Die Inhaltsansicht unterstützt höchstens 100.000 Archiveinträge.") }
            values.append(item)
        }
        guard try RenameVersion.read(source) == version else { throw CommanderError.message("Das Archiv wurde während des Einlesens geändert. Bitte neu einlesen.") }
        return try Self(source:source,version:version,members:values)
    }
    private init(source:URL,version:RenameVersion,members:[ArchiveMember]) throws {
        self.source = source;self.version = version;self.members = members
        var index = Dictionary(uniqueKeysWithValues:members.map { ($0.path,$0) })
        for value in members {
            var parent = (value.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if let old = index[parent] { guard old.isDirectory && !old.isLink else { throw CommanderError.message("Ein Archiveintrag verwendet eine Datei als Elternordner: "+parent) } }
                else { index[parent] = ArchiveMember(path:parent,size:0,isDirectory:true,permissions:0o755) }
                guard index.count <= Self.maximumEntries else { throw CommanderError.message("Zu viele Archivordner und Einträge.") }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        byPath = index;nodes = index.values.sorted { $0.path < $1.path }
        children = Dictionary(grouping:nodes,by:{ ($0.path as NSString).deletingLastPathComponent })
    }
    public func validateSource() throws {
        guard try RenameVersion.read(source) == version else { throw CommanderError.message("Das Archiv wurde geändert oder ersetzt. Bitte mit ⌘R neu einlesen und die Auswahl erneut prüfen.") }
    }
    public func member(at path:String) -> ArchiveMember? { byPath[path] }
    public func isDirectory(_ path:String) -> Bool { path.isEmpty || byPath[path]?.isDirectory == true }
    public func contents(of path:String,showHidden:Bool = false) throws -> [ArchiveMember] {
        guard isDirectory(path) else { throw CommanderError.message("Archivordner nicht gefunden: "+path) }
        return (children[path] ?? []).filter { showHidden || !(($0.path as NSString).lastPathComponent.hasPrefix(".")) }
    }
    public var suggestedFolderName:String { Self.folderName(for:source) }
    public static func folderName(for url:URL) -> String {
        let name = url.lastPathComponent,lower = name.lowercased()
        for suffix in [".tar.gz",".tar.bz2",".tar.xz",".tar.zst",".tgz",".tbz2",".tbz",".txz"] where lower.hasSuffix(suffix) { let stem = String(name.dropLast(suffix.count));return stem.isEmpty ? "Entpackt" : stem }
        let stem = url.deletingPathExtension().lastPathComponent;return stem.isEmpty ? "Entpackt" : stem
    }
}

struct ArchiveSelection {
    let rows:[ArchiveMember],selected:Set<String>,totalBytes:Int64,basePath:String,maximumBytes:Int64
    init(catalog:ArchiveCatalog,selection:[String]?,basePath:String,maximumBytes:Int64) throws {
        try catalog.validateSource()
        guard maximumBytes >= 0,catalog.isDirectory(basePath),selection != nil || basePath.isEmpty else { throw CommanderError.message("Ungültiger Archivordner oder lokales Entpackziel.") }
        let prefixes = selection ?? [""]
        guard !prefixes.isEmpty,prefixes.count <= ArchiveCatalog.maximumEntries else { throw CommanderError.message("Keine Archiveinträge ausgewählt.") }
        for path in prefixes where !(selection == nil && path.isEmpty) {
            guard catalog.member(at:path) != nil,(basePath.isEmpty || path.hasPrefix(basePath+"/")) else { throw CommanderError.message("Die Auswahl gehört nicht zum angezeigten Archivordner.") }
        }
        let roots = Set(prefixes)
        func included(_ path:String) -> Bool {
            if roots.contains("") { return true };var value = path
            while !value.isEmpty { if roots.contains(value) { return true };value = (value as NSString).deletingLastPathComponent };return false
        }
        let values = catalog.nodes.filter { included($0.path) },actual = catalog.members.filter { included($0.path) }
        var total:Int64 = 0
        for value in values {
            guard !value.isLink,value.isDirectory || value.isRegularFile,value.isDirectory || value.size >= 0 else { throw CommanderError.message("Verknüpfungen, Spezialdateien oder unbekannte Dateigrößen können nicht entpackt werden: "+value.path) }
            if !value.isDirectory { let sum = total.addingReportingOverflow(value.size);guard !sum.overflow,sum.partialValue <= maximumBytes else { throw CommanderError.message("Die Auswahl überschreitet das Entpacklimit.") };total = sum.partialValue }
        }
        self.basePath = basePath;self.maximumBytes = maximumBytes;totalBytes = total
        rows = values.map { ArchiveMember(path:basePath.isEmpty ? $0.path : String($0.path.dropFirst(basePath.count+1)),size:$0.size,isDirectory:$0.isDirectory,isRegularFile:$0.isRegularFile,isLink:$0.isLink,modified:$0.modified,permissions:$0.permissions) }
        selected = Set(actual.map(\.path))
    }
    private init(rows:[ArchiveMember],selected:Set<String>,basePath:String,maximumBytes:Int64) {
        self.rows = rows;self.selected = selected;self.basePath = basePath;self.maximumBytes = maximumBytes
        totalBytes = rows.filter { !$0.isDirectory }.reduce(0) { $0+$1.size }
    }
    func selecting(_ paths:Set<String>) -> Self {
        Self(rows:rows.filter { paths.contains($0.path) },selected:Set(selected.filter { paths.contains(basePath.isEmpty ? $0 : String($0.dropFirst(basePath.count+1))) }),basePath:basePath,maximumBytes:maximumBytes)
    }
}

public struct ArchiveExtractionPlan {
    public let catalog:ArchiveCatalog,destination:URL
    public var rows:[ArchiveMember] { selection.rows }
    public var totalBytes:Int64 { selection.totalBytes }
    public var basePath:String { selection.basePath }
    public var maximumBytes:Int64 { selection.maximumBytes }
    let selection:ArchiveSelection,parentVersion:RenameVersion
    public init(catalog:ArchiveCatalog,to destination:URL,selection:[String]? = nil,relativeTo basePath:String = "",maximumBytes:Int64 = 100*1024*1024*1024) throws {
        guard ArchiveService.isLocal(destination) else { throw CommanderError.message("Ein lokaler Zielordner wird benötigt.") }
        let content = try ArchiveSelection(catalog:catalog,selection:selection,basePath:basePath,maximumBytes:maximumBytes)
        let parent = FileSystem.canonical(destination.deletingLastPathComponent()),target = parent.appendingPathComponent(destination.lastPathComponent)
        try FileSystem.validateName(destination.lastPathComponent)
        let parentVersion = try RenameVersion.read(parent);guard parentVersion.isDirectory,!FileSystem.exists(target) else { throw CommanderError.message("Bitte einen neuen, noch nicht vorhandenen Zielordner in einem verfügbaren Ordner angeben.") }
        self.catalog = catalog;self.destination = target;self.parentVersion = parentVersion;self.selection = content
    }
    public func validate() throws {
        try catalog.validateSource()
        guard try RenameVersion.read(destination.deletingLastPathComponent()).sameObject(parentVersion),!FileSystem.exists(destination) else { throw CommanderError.message("Das Entpackziel oder sein Elternordner wurde geändert. Bitte neu prüfen.") }
    }
}
