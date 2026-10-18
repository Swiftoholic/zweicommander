import Foundation
import CryptoKit
import Darwin

public enum ComparisonState: String { case equal = "Gleich", leftOnly = "Nur links", rightOnly = "Nur rechts", different = "Verschieden", typeConflict = "Typkonflikt", link = "Verknüpfung", special = "Spezialdatei", ambiguous = "Schreibweisenkonflikt", blocked = "Übergeordneter Konflikt" }
public enum ComparisonMode: String,Codable,CaseIterable { case content,sizeAndDate,sizeOnly }
public enum SyncDirection: String,CaseIterable { case skip,pending,leftToRight,rightToLeft }
public enum SyncStrategy: String,Codable,CaseIterable { case leftToRight,rightToLeft,newerBoth,missingBoth }
public struct CompareOptions: Codable,Equatable {
    public var mode: ComparisonMode = .content
    public var timeTolerance = 1
    public var include = "*",exclude = "",excludedFolders = ""
    public var recursive = true,showHidden = true
    public var strategy: SyncStrategy = .leftToRight
    public init() {}
    public func validate() throws {
        guard (0...3600).contains(timeTolerance) else { throw CommanderError.message("Zeittoleranz: 0 bis 3600 Sekunden.") }
        _ = try compiled()
    }
    func compiled() throws -> CompiledTransferFilter {
        var filter = TransferFilter();filter.include = include;filter.exclude = exclude;filter.excludedFolders = excludedFolders;filter.recursive = true
        return try CompiledTransferFilter(filter)
    }
}
public struct ComparedEntry {
    public let url: URL,size: Int64,modified: Date
    public let isDirectory: Bool,isRegularFile: Bool,isLink: Bool
    let version: RenameVersion
    init(_ url: URL,_ version: RenameVersion) {
        self.url = url;self.version = version;size = Int64(version.size);modified = version.modified
        isDirectory = version.isDirectory;isRegularFile = version.isRegularFile;isLink = version.mode & S_IFMT == S_IFLNK
    }
}
public struct ComparisonItem: Identifiable {
    public let relativePath: String,left: ComparedEntry?,right: ComparedEntry?,state: ComparisonState
    public var id: String { relativePath }
    public var isDirectory: Bool { left?.isDirectory ?? right?.isDirectory ?? false }
    public var isBlocked: Bool { ![.equal,.leftOnly,.rightOnly,.different].contains(state) }
    public var allowedDirections: [SyncDirection] {
        if isBlocked || state == .equal { return [.skip] }
        return [.skip] + (left != nil ? [.leftToRight] : []) + (right != nil ? [.rightToLeft] : [])
    }
}
public struct FolderComparison: RandomAccessCollection {
    public typealias Index = Int
    public let left: URL,right: URL,options: CompareOptions,items: [ComparisonItem]
    let leftEntries: [String:ComparedEntry],rightEntries: [String:ComparedEntry]
    let leftVersion: RenameVersion,rightVersion: RenameVersion
    public var startIndex: Int { items.startIndex };public var endIndex: Int { items.endIndex }
    public subscript(index: Int) -> ComparisonItem { items[index] }
    public func suggestions(_ strategy: SyncStrategy) -> [String:SyncDirection] {
        Dictionary(uniqueKeysWithValues:items.map { row in
            let direction: SyncDirection
            if row.isBlocked || row.state == .equal { direction = .skip }
            else if strategy == .leftToRight { direction = row.left == nil ? .skip : .leftToRight }
            else if strategy == .rightToLeft { direction = row.right == nil ? .skip : .rightToLeft }
            else if row.left == nil { direction = .rightToLeft }
            else if row.right == nil { direction = .leftToRight }
            else if strategy == .missingBoth { direction = .skip }
            else {
                let difference = row.left!.modified.timeIntervalSince(row.right!.modified)
                direction = abs(difference) <= Double(options.timeTolerance) ? .pending : difference > 0 ? .leftToRight : .rightToLeft
            }
            return (row.id,direction)
        })
    }
    public func plan(_ directions: [String:SyncDirection]) throws -> FolderSyncPlan {
        var steps: [String:SyncStep] = [:]
        func add(_ path: String,_ direction: SyncDirection) throws {
            let ltr = direction == .leftToRight,source = ltr ? leftEntries : rightEntries,target = ltr ? rightEntries : leftEntries
            let key = direction.rawValue+":"+path
            if steps[key] != nil { return }
            guard let entry = source[path],entry.isDirectory || entry.isRegularFile else { throw CommanderError.message("Quelle nicht verfügbar: "+path) }
            if let destination = target[path],entry.isDirectory || !destination.isRegularFile { throw CommanderError.message("Zieltyp nicht unterstützt: "+path) }
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                if let existing = target[parent] { guard existing.isDirectory else { throw CommanderError.message("Zielpfad ist kein echter Ordner: "+parent) } }
                else { try add(parent,direction) }
            }
            steps[key] = SyncStep(id:UUID(),path:path,source:entry.url,destination:(ltr ? right : left).appendingPathComponent(path),direction:direction,sourceVersion:entry.version,targetVersion:target[path]?.version)
        }
        let known = Set(items.map(\.id))
        guard Set(directions.keys).isSubset(of:known) else { throw CommanderError.message("Unbekannte Zeile im Synchronisationsplan.") }
        for row in items {
            let direction = directions[row.id] ?? .skip
            guard direction != .pending else { throw CommanderError.message("Kopierrichtung noch offen: "+row.relativePath) }
            guard row.allowedDirections.contains(direction) else { throw CommanderError.message("Diese Zeile kann nicht in die gewählte Richtung kopiert werden: "+row.relativePath) }
            if direction != .skip { try add(row.relativePath,direction) }
        }
        let ordered = steps.values.sorted { a,b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            if a.isDirectory {
                let x = a.path.split(separator:"/").count,y = b.path.split(separator:"/").count
                if x != y { return x < y }
            }
            return a.destination.path < b.destination.path
        }
        var total: Int64 = 0
        for step in ordered { let sum = total.addingReportingOverflow(step.bytes);guard !sum.overflow else { throw CommanderError.message("Die Gesamtgröße ist zu groß.") };total = sum.partialValue }
        return FolderSyncPlan(comparison:self,steps:ordered,bytes:total)
    }
}
public struct SyncStep: Identifiable {
    public let id: UUID,path: String,source: URL,destination: URL,direction: SyncDirection
    let sourceVersion: RenameVersion,targetVersion: RenameVersion?
    public var isDirectory: Bool { sourceVersion.isDirectory }
    public var replacing: Bool { targetVersion != nil }
    public var bytes: Int64 { isDirectory ? 0 : Int64(sourceVersion.size) }
}
public struct FolderSyncPlan {
    let comparison: FolderComparison
    public let steps: [SyncStep],bytes: Int64
    public var initialItems: [TransferItemProgress] { steps.map { TransferItemProgress(id:$0.id,source:$0.source,target:$0.destination,state:.waiting,bytes:0,totalBytes:$0.bytes,isByteTracked:!$0.isDirectory,message:$0.isDirectory ? "Ordner anlegen" : $0.replacing ? "Ersetzen mit Sicherung" : "Neu kopieren") } }
}
public enum CompareService {
    public static func compare(_ left: URL,_ right: URL,content: Bool = true,token: CancellationToken = .init(),progress: (String)->Void = { _ in }) throws -> FolderComparison {
        var options = CompareOptions();options.mode = content ? .content : .sizeAndDate
        return try compare(left,right,options:options,token:token,progress:progress)
    }
    public static func compare(_ left: URL,_ right: URL,options: CompareOptions,token: CancellationToken = .init(),progress: (String)->Void = { _ in }) throws -> FolderComparison {
        try options.validate()
        guard left.isFileURL,right.isFileURL else { throw CommanderError.message("Lokale Vergleichsordner wählen.") }
        let left = FileSystem.canonical(left),right = FileSystem.canonical(right)
        guard !FileSystem.isInside(left,right),!FileSystem.isInside(right,left) else { throw CommanderError.message("Vergleichsordner müssen verschieden sein und dürfen nicht ineinander liegen.") }
        let lv = try RenameVersion.read(left),rv = try RenameVersion.read(right),filter = try options.compiled()
        guard lv.isDirectory,rv.isDirectory else { throw CommanderError.message("Beide Vergleichspfade müssen Ordner sein.") }
        func index(_ root: URL) throws -> [String:ComparedEntry] {
            var result: [String:ComparedEntry] = [:],failure: Error?
            guard let iterator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil,options:options.showHidden ? [] : [.skipsHiddenFiles],errorHandler:{ _,error in failure = error;return false }) else { throw CommanderError.message("Ordner nicht lesbar: "+root.path) }
            for case let url as URL in iterator {
                try token.check();let version = try RenameVersion.read(url),name = url.lastPathComponent
                if name.hasPrefix(".zweicommander-") || (version.isDirectory && filter.excludesFolder(name)) { iterator.skipDescendants();continue }
                if !options.recursive || version.mode & S_IFMT == S_IFLNK { iterator.skipDescendants() }
                guard result.count < 50_000 else { throw CommanderError.message("Vergleich auf 50.000 Einträge je Seite begrenzt. Bitte kleinere Ordner oder mehr Ordnerausschlüsse wählen.") }
                let path = try FileSystem.relativePath(of:url,inside:root);result[path] = ComparedEntry(url,version);progress("Erfasse "+path)
            }
            if let failure { throw failure };return result
        }
        let l = try index(left),r = try index(right),paths = Set(l.keys).union(r.keys).sorted()
        guard paths.count <= 50_000 else { throw CommanderError.message("Vergleich enthält mehr als 50.000 Zeilen. Bitte kleinere Ordner oder mehr Ordnerausschlüsse wählen.") }
        var spellings: [String:Set<String>] = [:]
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX")) }
        for path in paths { spellings[key(path),default:[]].insert(path) }
        var ambiguous = Set(spellings.filter { $0.value.count > 1 }.map(\.key)),blocked: Set<String> = [],rows: [ComparisonItem] = []
        for path in paths {
            try token.check();let a = l[path],b = r[path],state: ComparisonState
            guard a?.isDirectory == true || b?.isDirectory == true || filter.includesFile((path as NSString).lastPathComponent) else { continue }
            progress("Vergleiche "+path)
            let parts = path.split(separator:"/");let parents = (1..<max(1,parts.count)).map { parts.prefix($0).joined(separator:"/") }
            if ambiguous.contains(key(path)) || parents.contains(where:{ ambiguous.contains(key($0)) }) { state = .ambiguous;ambiguous.insert(key(path)) }
            else if parents.contains(where:{ blocked.contains($0) }) { state = .blocked }
            else if a?.isLink == true || b?.isLink == true { state = .link }
            else if a.map({ !$0.isDirectory && !$0.isRegularFile }) == true || b.map({ !$0.isDirectory && !$0.isRegularFile }) == true { state = .special }
            else if a == nil { state = .rightOnly }
            else if b == nil { state = .leftOnly }
            else if a!.isDirectory != b!.isDirectory { state = .typeConflict }
            else if a!.isDirectory { state = .equal }
            else if a!.size != b!.size { state = .different }
            else if options.mode == .content { state = try hash(a!,token:token) == hash(b!,token:token) ? .equal : .different }
            else if options.mode == .sizeOnly { state = .equal }
            else { state = abs(a!.modified.timeIntervalSince(b!.modified)) <= Double(options.timeTolerance) ? .equal : .different }
            if [.link,.special,.typeConflict,.ambiguous,.blocked].contains(state) { blocked.insert(path) }
            rows.append(ComparisonItem(relativePath:path,left:a,right:b,state:state))
        }
        // No partial or stale comparison can become an executable preview.
        for entry in rows.flatMap({ [$0.left,$0.right].compactMap { $0 } }) { try token.check();guard try RenameVersion.read(entry.url) == entry.version else { throw CommanderError.message("Eintrag während des Vergleichs verändert: "+entry.url.path) } }
        guard try RenameVersion.read(left) == lv,try RenameVersion.read(right) == rv else { throw CommanderError.message("Vergleichsordner während der Prüfung verändert. Bitte erneut vergleichen.") }
        return FolderComparison(left:left,right:right,options:options,items:rows,leftEntries:l,rightEntries:r,leftVersion:lv,rightVersion:rv)
    }
    private static func hash(_ entry: ComparedEntry,token: CancellationToken) throws -> String {
        let fd = open(entry.url.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CommanderError.message("Datei kann nicht sicher geöffnet werden: "+entry.url.path) };defer { close(fd) }
        var value = stat();guard fstat(fd,&value) == 0,RenameVersion(value) == entry.version else { throw CommanderError.message("Datei vor Inhaltsprüfung verändert.") }
        var hash = SHA256(),buffer = [UInt8](repeating:0,count:1024*1024)
        while true {
            try token.check();let count = Darwin.read(fd,&buffer,buffer.count)
            if count < 0 && errno == EINTR { continue };guard count >= 0 else { throw CommanderError.message("Datei konnte nicht gelesen werden.") }
            if count == 0 { break };hash.update(data:Data(buffer.prefix(count)))
        }
        guard fstat(fd,&value) == 0,RenameVersion(value) == entry.version,try RenameVersion.read(entry.url) == entry.version else { throw CommanderError.message("Datei während Inhaltsprüfung verändert.") }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    public static func plan(_ comparison: FolderComparison,left: URL,right: URL,leftToRight: Bool) throws -> FolderSyncPlan {
        guard FileSystem.canonical(left) == comparison.left,FileSystem.canonical(right) == comparison.right else { throw CommanderError.message("Vergleich und Zielordner passen nicht zusammen.") }
        if let blocked = comparison.first(where: { $0.isBlocked }) { throw CommanderError.message("Konflikt zunächst manuell klären: "+blocked.relativePath) }
        return try comparison.plan(comparison.suggestions(leftToRight ? .leftToRight : .rightToLeft))
    }
    public static func synchronize(_ plan: FolderSyncPlan,token: CancellationToken = .init(),progress: @escaping (String)->Void = { _ in }) -> OperationReport {
        FolderSyncEngine.execute(plan,token:token,progress:{ progress($0.detail) })
    }
}
