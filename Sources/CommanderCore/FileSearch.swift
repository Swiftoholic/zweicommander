import Foundation
import Darwin

public enum SearchKind: String, Codable, CaseIterable { case all, files, folders }
public enum SearchContentMode: String, Codable, CaseIterable { case literal, regularExpression, hex }
public enum SearchEncoding: String, Codable, CaseIterable { case automatic, utf8, utf16LE, utf16BE, windows1252 }
public struct SearchOptions: Codable, Equatable {
    public var name = ""
    public var regex = false
    public var excludedNames = ""
    public var excludedFolders = ""
    public var recursive = true
    public var content = ""
    public var contentMode: SearchContentMode = .literal
    public var contentNegated = false
    /// Folder levels below each selected root; zero includes only direct entries.
    public var maximumDepth: Int?
    public var caseSensitive = false
    public var wholeWords = false
    public var encoding: SearchEncoding = .automatic
    public var showHidden = false
    public var kind: SearchKind = .all
    public var filesOnly: Bool { get { kind == .files } set { kind = newValue ? .files : .all } }
    public var minimumSize: Int64 = 0
    public var maximumSize: Int64 = .max
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var modifiedAge: TransferAgeRange?
    public var searchArchives = false
    public var searchOfficeDocuments = false
    public var resultLimit = 10_000
    public init() {}
    public var usesAdvancedRules: Bool { contentMode != .literal || contentNegated || maximumDepth != nil }
    private enum CodingKeys: String,CodingKey {
        case name,regex,excludedNames,excludedFolders,recursive,content,contentMode,contentNegated,maximumDepth,caseSensitive,wholeWords,encoding,showHidden,kind,minimumSize,maximumSize,modifiedAfter,modifiedBefore,modifiedAge,searchArchives,searchOfficeDocuments,resultLimit
    }
    public init(from decoder:Decoder) throws {
        self.init();let c = try decoder.container(keyedBy:CodingKeys.self)
        name = try c.decodeIfPresent(String.self,forKey:.name) ?? name;regex = try c.decodeIfPresent(Bool.self,forKey:.regex) ?? regex
        excludedNames = try c.decodeIfPresent(String.self,forKey:.excludedNames) ?? excludedNames;excludedFolders = try c.decodeIfPresent(String.self,forKey:.excludedFolders) ?? excludedFolders
        recursive = try c.decodeIfPresent(Bool.self,forKey:.recursive) ?? recursive;content = try c.decodeIfPresent(String.self,forKey:.content) ?? content
        contentMode = try c.decodeIfPresent(SearchContentMode.self,forKey:.contentMode) ?? contentMode;contentNegated = try c.decodeIfPresent(Bool.self,forKey:.contentNegated) ?? contentNegated
        maximumDepth = try c.decodeIfPresent(Int.self,forKey:.maximumDepth)
        caseSensitive = try c.decodeIfPresent(Bool.self,forKey:.caseSensitive) ?? caseSensitive;wholeWords = try c.decodeIfPresent(Bool.self,forKey:.wholeWords) ?? wholeWords
        encoding = try c.decodeIfPresent(SearchEncoding.self,forKey:.encoding) ?? encoding;showHidden = try c.decodeIfPresent(Bool.self,forKey:.showHidden) ?? showHidden
        kind = try c.decodeIfPresent(SearchKind.self,forKey:.kind) ?? kind;minimumSize = try c.decodeIfPresent(Int64.self,forKey:.minimumSize) ?? minimumSize;maximumSize = try c.decodeIfPresent(Int64.self,forKey:.maximumSize) ?? maximumSize
        modifiedAfter = try c.decodeIfPresent(Date.self,forKey:.modifiedAfter);modifiedBefore = try c.decodeIfPresent(Date.self,forKey:.modifiedBefore);modifiedAge = try c.decodeIfPresent(TransferAgeRange.self,forKey:.modifiedAge)
        searchArchives = try c.decodeIfPresent(Bool.self,forKey:.searchArchives) ?? searchArchives;searchOfficeDocuments = try c.decodeIfPresent(Bool.self,forKey:.searchOfficeDocuments) ?? searchOfficeDocuments
        resultLimit = try c.decodeIfPresent(Int.self,forKey:.resultLimit) ?? resultLimit
    }
    public func validate() throws { _ = try CompiledSearch(self) }
}

public struct SearchHit: Identifiable, Equatable {
    /// Archive hits refer to the archive URL, never to a fictitious filesystem path.
    public let url: URL
    public let member: String?
    public let size: Int64
    public let isDirectory: Bool
    public let modified: Date
    public let snippet: String
    public var id: String { url.path + "\0" + (member ?? "") }
    public var name: String { member.map { ($0 as NSString).lastPathComponent } ?? url.lastPathComponent }
    public var location: String { member.map { url.path + " ▸ " + $0 } ?? url.deletingLastPathComponent().path }
}
public struct SearchUpdate {
    public let hits: [SearchHit]
    public let scanned: Int
    public let totalHits: Int
    public let warningCount: Int
}
public struct SearchReport {
    public internal(set) var hits: [SearchHit] = []
    public var urls: [URL] { hits.filter { $0.member == nil }.map(\.url) }
    public var archiveMatches: [String] { hits.compactMap { hit in hit.member.map { hit.url.path + " ▸ " + $0 } } }
    public internal(set) var warnings: [String] = []
    public internal(set) var warningCount = 0
    public internal(set) var scanned = 0
    public internal(set) var cancelled = false
    public internal(set) var limitReached = false
    public internal(set) var scanLimitReached = false
}

private struct SearchNames {
    let filters: [NameFilter]
    init(_ text: String,regex: Bool) throws {
        guard text.utf8.count <= 4096 else { throw CommanderError.message("Suchmuster: höchstens 4096 UTF-8-Bytes.") }
        let parts = regex ? [text] : text.components(separatedBy:";").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        guard parts.count <= 128 else { throw CommanderError.message("Höchstens 128 Namensmuster verwenden.") }
        filters = try (parts.isEmpty ? [""] : parts).map { try NameFilter($0 == "*.*" && !regex ? "*" : $0,regex:regex) }
    }
    func matches(_ name: String) -> Bool { filters.contains { $0.matches(name) } }
}
private struct CompiledSearch {
    let options: SearchOptions,names: SearchNames,excluded: TransferPatterns,folders: TransferPatterns,metadata: CompiledTransferFilter,content: CompiledSearchContent
    init(_ options: SearchOptions,referenceDate: Date = Date()) throws {
        if let depth = options.maximumDepth { guard (0...1000).contains(depth) else { throw CommanderError.message("Unterordnertiefe: 0 bis 1000 oder unbegrenzt.") } }
        guard (1...50_000).contains(options.resultLimit) else { throw CommanderError.message("Treffergrenze: 1 bis 50.000.") }
        guard options.content.utf8.count <= 4096,!options.content.contains("\0") else { throw CommanderError.message("Suchtext: höchstens 4096 UTF-8-Bytes ohne Nullzeichen.") }
        content = try CompiledSearchContent(options)
        guard options.content.isEmpty || options.kind != .folders else { throw CommanderError.message("Inhaltssuche ist nur für Dateien möglich.") }
        guard options.kind != .folders || (options.minimumSize == 0 && options.maximumSize == .max) else {
            throw CommanderError.message("Größenfilter gelten für Dateien. Für reine Ordnersuche die Größengrenzen entfernen.")
        }
        // Archive member search intentionally uses names and sizes only.
        guard !options.searchArchives || (options.content.isEmpty && options.modifiedAfter == nil && options.modifiedBefore == nil && options.modifiedAge == nil) else {
            throw CommanderError.message("Archivnamen getrennt von Inhalt und Änderungsdatum suchen.")
        }
        self.options = options;names = try SearchNames(options.name,regex:options.regex)
        excluded = try TransferPatterns(options.excludedNames,regex:false,emptyMatchesAll:false)
        folders = try TransferPatterns(options.excludedFolders,regex:false,emptyMatchesAll:false)
        var filter = TransferFilter();filter.minimumSize = options.minimumSize;filter.maximumSize = options.maximumSize
        filter.modifiedFrom = options.modifiedAfter;filter.modifiedBefore = options.modifiedBefore;filter.modifiedAge = options.modifiedAge
        metadata = try CompiledTransferFilter(filter,referenceDate:referenceDate)
    }
    func accepts(_ name: String,size: Int64,directory: Bool,modified: Date,isLink: Bool = false) -> Bool {
        guard names.matches(name),!excluded.matches(name) else { return false }
        guard options.kind != .files || !directory,options.kind != .folders || directory else { return false }
        if directory && (options.minimumSize != 0 || options.maximumSize != .max) { return false }
        // Size zero/unbounded and no date restrictions also allow links as names.
        let restricted = options.minimumSize != 0 || options.maximumSize != .max || options.modifiedAfter != nil || options.modifiedBefore != nil || options.modifiedAge != nil
        if restricted && !metadata.includesMetadata(size:size,modified:modified,isLink:isLink) { return false }
        return true
    }

}

/// Holds a regular file open without following its final symbolic link. Reads are bounded and
/// checked against the open inode and path afterwards; changed files cannot produce a content hit.
private final class SearchReader {
    let fd: Int32,url: URL,before: stat
    init(_ url: URL,expected: stat) throws {
        self.url = url;fd = open(url.path,O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CommanderError.message("Datei kann nicht sicher geöffnet werden: \(url.path)") }
        var info = stat()
        guard fstat(fd,&info) == 0,(info.st_mode & S_IFMT) == S_IFREG else {
            close(fd);throw CommanderError.message("Inhaltssuche benötigt eine reguläre Datei.")
        }
        guard Self.same(expected,info) else { close(fd);throw CommanderError.message("Datei vor dem Lesen verändert: \(url.path)") }
        before = info
    }
    deinit { close(fd) }
    var descriptorURL: URL { URL(fileURLWithPath:"/dev/fd/\(fd)") }
    func verify() throws {
        var current = stat(),path = stat()
        guard fstat(fd,&current) == 0,lstat(url.path,&path) == 0,Self.same(before,current),Self.same(before,path) else { throw CommanderError.message("Datei während der Suche verändert: \(url.path)") }
    }
    private static func same(_ a: stat,_ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    func hex(_ needle:Data,token:CancellationToken) throws -> Int64? {
        guard before.st_size <= 32*1024*1024 else { throw CommanderError.message("Hex-Inhaltssuche übersprungen (>32 MiB): \(url.path)") }
        var buffer = [UInt8](repeating:0,count:64*1024),tail = Data(),offset:Int64 = 0,total = 0
        while true {
            try token.check();let count = Darwin.read(fd,&buffer,buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CommanderError.message("Datei konnte nicht gelesen werden: "+url.path) }
            if count == 0 { break };total += count
            guard total <= 32*1024*1024 else { throw CommanderError.message("Datei ist während der Hexsuche über 32 MiB gewachsen.") }
            var data = tail;data.append(contentsOf:buffer.prefix(count))
            if let range = data.range(of:needle) { try verify();try token.check();return offset-Int64(tail.count)+Int64(range.lowerBound) }
            tail = Data(data.suffix(max(0,needle.count-1)));offset += Int64(count)
        }
        try verify();try token.check();return nil
    }
    func text(encoding: SearchEncoding,token: CancellationToken,limit:Int = 32*1024*1024) throws -> String? {
        guard before.st_size <= limit else { throw CommanderError.message("Inhaltssuche übersprungen (>\(limit / 1024 / 1024) MiB): \(url.path)") }
        var data = Data(),buffer = [UInt8](repeating:0,count:64*1024)
        while true {
            try token.check();let count = Darwin.read(fd,&buffer,buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CommanderError.message("Datei konnte nicht gelesen werden: \(url.path)") }
            if count == 0 { break }
            guard data.count + count <= limit else { throw CommanderError.message("Datei ist während der Suche über das Moduslimit gewachsen.") }
            data.append(contentsOf:buffer.prefix(count))
        }
        try verify();try token.check()
        let decoded: String?
        switch encoding {
        case .utf8: decoded = String(data:data,encoding:.utf8)
        case .utf16LE: decoded = String(data:data,encoding:.utf16LittleEndian)
        case .utf16BE: decoded = String(data:data,encoding:.utf16BigEndian)
        case .windows1252: decoded = String(data:data,encoding:.windowsCP1252)
        case .automatic:
            if data.starts(with:[0xFF,0xFE]) || data.starts(with:[0xFE,0xFF]) { decoded = String(data:data,encoding:.utf16) }
            else if !data.contains(0) { decoded = String(data:data,encoding:.utf8) }
            else { decoded = nil }
        }
        // A selected legacy encoding must not turn binary data into text matches.
        guard let text = decoded,!text.unicodeScalars.contains(where: { $0.value < 32 && ![9,10,12,13].contains($0.value) }) else { return nil }
        return text
    }
}

extension SearchService {
    public static func search(_ root: URL,options: SearchOptions,token: CancellationToken = .init(),progress: (Int)->Void = { _ in },onUpdate: (SearchUpdate)->Void = { _ in }) throws -> SearchReport {
        try search([root],options:options,token:token,progress:progress,onUpdate:onUpdate)
    }
    public static func search(_ roots:[URL],options:SearchOptions,token:CancellationToken = .init(),progress:(Int)->Void = { _ in },onUpdate:(SearchUpdate)->Void = { _ in }) throws -> SearchReport {
        let compiled = try CompiledSearch(options),roots = try searchRoots(roots,options:options)
        var result = SearchReport(),batch: [SearchHit] = [],lastUpdate = Date.distantPast
        func warn(_ message: String) {
            result.warningCount += 1
            if result.warnings.count < 200 { result.warnings.append(message) }
        }
        func publish(force: Bool = false) {
            guard force || batch.count >= 50 || Date().timeIntervalSince(lastUpdate) >= 0.1 else { return }
            progress(result.scanned);onUpdate(SearchUpdate(hits:batch,scanned:result.scanned,totalHits:result.hits.count,warningCount:result.warningCount))
            batch.removeAll(keepingCapacity:true);lastUpdate = Date()
        }
        func append(_ hit: SearchHit) {
            result.hits.append(hit);batch.append(hit);publish()
            if result.hits.count >= options.resultLimit { result.limitReached = true }
        }
        let enumeration: FileManager.DirectoryEnumerationOptions = options.showHidden ? [] : [.skipsHiddenFiles]
        // Only overlapping explicit subtrees need a visited-path set. A single large
        // root and disjoint roots stream without retaining every nonmatching path.
        let duplicateSubtrees = roots.enumerated().compactMap { index,value -> String? in
            roots.enumerated().contains(where: { $0.offset != index && FileSystem.isInside(value,$0.element) }) ? value.path : nil
        }
        var seen = Set<String>()
        let depthLimit = options.recursive ? options.maximumDepth : 0
        do {
          rootsLoop: for root in roots {
            try token.check();if result.limitReached { break }
            guard let iterator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil,options:enumeration,errorHandler:{ url,error in
                warn("\(url.path): \(error.localizedDescription)");return !token.isCancelled
            }) else { warn("Suchordner kann nicht gelesen werden: "+root.path);continue }
            for case let url as URL in iterator {
                try token.check();if result.limitReached { break rootsLoop }
                let depth = max(0,iterator.level-1)
                if let limit = depthLimit,depth >= limit { iterator.skipDescendants() }
                if let limit = depthLimit,depth > limit { continue }
                let path = url.standardizedFileURL.path
                let duplicate = duplicateSubtrees.contains(where: { path == $0 || path.hasPrefix($0+"/") }) && !seen.insert(path).inserted
                if !duplicate {
                    guard result.scanned < 1_000_000 else { result.scanLimitReached = true;warn("Prüfgrenze von 1.000.000 eindeutigen Einträgen erreicht. Teilergebnisse bleiben erhalten.");break rootsLoop }
                    result.scanned += 1
                }
                do {
                    var info = stat();guard lstat(url.path,&info) == 0 else { throw CommanderError.message("Eintrag nicht lesbar: \(url.path)") }
                    let directory = info.st_mode & S_IFMT == S_IFDIR,link = info.st_mode & S_IFMT == S_IFLNK,regular = info.st_mode & S_IFMT == S_IFREG
                    if link || !options.recursive { iterator.skipDescendants() }
                    let excludedFolder = directory && compiled.folders.matches(url.lastPathComponent)
                    if excludedFolder { iterator.skipDescendants() }
                    // A duplicate directory still belongs to this traversal: apply its
                    // pruning rules before skipping its already-reported result row.
                    if duplicate { continue }
                    if excludedFolder { publish();continue }
                    let modified = Date(timeIntervalSince1970:Double(info.st_mtimespec.tv_sec)+Double(info.st_mtimespec.tv_nsec)/1e9)
                    if options.searchArchives && regular && ArchiveService.isArchive(url) && !compiled.excluded.matches(url.lastPathComponent) {
                        do {
                            let reader = try SearchReader(url,expected:info)
                            // Hold candidate archive hits until the container has passed its change check.
                            var members: [SearchHit] = []
                            try ArchiveService.visitMembers(reader.descriptorURL,token:token) { member in
                                let parts = member.path.split(separator:"/").map(String.init)
                                if !options.showHidden && parts.contains(where: { $0.hasPrefix(".") }) { return true }
                                let folderParts = member.isDirectory ? parts : Array(parts.dropLast())
                                if folderParts.contains(where: { compiled.folders.matches($0) }) { return true }
                                if !options.recursive && parts.count > 1 { return true }
                                if let limit = depthLimit,depth+max(0,parts.count-1) > limit { return true }
                                let name = parts.last ?? ""
                                if compiled.accepts(name,size:member.size,directory:member.isDirectory,modified:modified) {
                                    members.append(SearchHit(url:url,member:member.path,size:member.size,isDirectory:member.isDirectory,modified:modified,snippet:"Archivname · Inhalt nicht geprüft"))
                                }
                                return result.hits.count + members.count < options.resultLimit
                            }
                            try reader.verify()
                            for hit in members { try token.check();append(hit) }
                        } catch CommanderError.cancelled { throw CommanderError.cancelled }
                        catch { warn("\(url.path): \(error.localizedDescription)") }
                    }
                    if result.limitReached { break }
                    guard compiled.accepts(url.lastPathComponent,size:info.st_size,directory:directory,modified:modified,isLink:link) else { publish();continue }
                    var snippet = ""
                    if !options.content.isEmpty {
                        guard regular else { publish();continue };publish()
                        let reader = try SearchReader(url,expected:info)
                        if options.contentMode == .hex {
                            let offset = try reader.hex(compiled.content.needle,token:token)
                            guard options.contentNegated ? offset == nil : offset != nil else { publish();continue }
                            snippet = offset.map { "Hex · Byteoffset \($0)" } ?? "Hexfolge nicht enthalten · Datei geprüft"
                        } else {
                            let text: String?
                            if options.searchOfficeDocuments && DocumentText.supports(url) {
                                text = try DocumentText.extract(reader.descriptorURL,token:token,fileExtension:url.pathExtension);try reader.verify()
                            } else { text = try reader.text(encoding:options.encoding,token:token,limit:options.contentMode == .regularExpression ? CompiledSearchContent.regexByteLimit : 32*1024*1024) }
                            try token.check()
                            guard let text,let match = try compiled.content.snippet(in:text,token:token) else { publish();continue }
                            snippet = match
                        }
                        // The path must still refer to the same file after matching.
                        try reader.verify()
                    }
                    append(SearchHit(url:url,member:nil,size:info.st_size,isDirectory:directory,modified:modified,snippet:snippet));publish()
                } catch CommanderError.cancelled { throw CommanderError.cancelled }
                catch { warn(error.localizedDescription) }
            }
          }
            try token.check()
        } catch CommanderError.cancelled { result.cancelled = true }
        publish(force:true);return result
    }
}

extension SearchService {
    /// Paths are individual URL values, never a delimiter-separated expression.
    public static func searchRoots(_ roots:[URL],options:SearchOptions) throws -> [URL] {
        guard !roots.isEmpty,roots.count <= 100 else { throw CommanderError.message("1 bis 100 Suchordner wählen.") }
        var unique = Set<String>(),values:[URL] = []
        for root in roots {
            guard root.isFileURL,!root.path.contains("\0") else { throw CommanderError.message("Suchordner müssen lokal sein.") }
            let value = FileSystem.canonical(root)
            guard FileSystem.isDirectory(value) else { throw CommanderError.message("Suchordner nicht gefunden: "+root.path) }
            if unique.insert(value.path).inserted { values.append(value) }
        }
        values.sort { $0.path < $1.path }
        if options.recursive && options.maximumDepth == nil {
            let excluded = try TransferPatterns(options.excludedFolders,regex:false,emptyMatchesAll:false)
            func covers(_ child:URL,_ parent:URL) -> Bool {
                guard FileSystem.isInside(child,parent) else { return false }
                let parts = Array(child.pathComponents.dropFirst(parent.pathComponents.count));var current = parent
                for part in parts {
                    if excluded.matches(part) { return false }
                    current.appendPathComponent(part)
                    if !options.showHidden {
                        guard let hidden = try? current.resourceValues(forKeys:[.isHiddenKey]).isHidden,hidden == false else { return false }
                    }
                }
                return true
            }
            var result:[URL] = []
            for value in values where !result.contains(where: { covers(value,$0) }) { result.append(value) }
            return result
        }
        return values
    }
}
