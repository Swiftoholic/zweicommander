import Foundation
import Darwin

public enum SearchKind: String, Codable, CaseIterable { case all, files, folders }
public enum SearchEncoding: String, Codable, CaseIterable { case automatic, utf8, utf16LE, utf16BE, windows1252 }
public struct SearchOptions: Codable, Equatable {
    public var name = ""
    public var regex = false
    public var excludedNames = ""
    public var excludedFolders = ""
    public var recursive = true
    public var content = ""
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
    let options: SearchOptions,names: SearchNames,excluded: TransferPatterns,folders: TransferPatterns,metadata: CompiledTransferFilter
    init(_ options: SearchOptions,referenceDate: Date = Date()) throws {
        guard (1...50_000).contains(options.resultLimit) else { throw CommanderError.message("Treffergrenze: 1 bis 50.000.") }
        guard options.content.utf8.count <= 4096,!options.content.contains("\0") else { throw CommanderError.message("Suchtext: höchstens 4096 UTF-8-Bytes ohne Nullzeichen.") }
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
    func range(in text: String) -> Range<String.Index>? {
        let searchOptions: String.CompareOptions = options.caseSensitive ? [.literal] : [.caseInsensitive,.literal]
        var start = text.startIndex
        let word = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn:"_"))
        func isWord(_ ch: Character) -> Bool { ch.unicodeScalars.contains { word.contains($0) } }
        while start < text.endIndex,let range = text.range(of:options.content,options:searchOptions,range:start..<text.endIndex) {
            if !options.wholeWords || ((range.lowerBound == text.startIndex || !isWord(text[text.index(before:range.lowerBound)])) &&
                (range.upperBound == text.endIndex || !isWord(text[range.upperBound]))) { return range }
            start = text.index(after:range.lowerBound)
        }
        return nil
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
    func text(encoding: SearchEncoding,token: CancellationToken) throws -> String? {
        let limit = 32*1024*1024
        guard before.st_size <= limit else { throw CommanderError.message("Inhaltssuche übersprungen (>32 MiB): \(url.path)") }
        var data = Data(),buffer = [UInt8](repeating:0,count:64*1024)
        while true {
            try token.check();let count = Darwin.read(fd,&buffer,buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CommanderError.message("Datei konnte nicht gelesen werden: \(url.path)") }
            if count == 0 { break }
            guard data.count + count <= limit else { throw CommanderError.message("Datei ist während der Suche über 32 MiB gewachsen.") }
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
        guard root.isFileURL else { throw CommanderError.message("Suchordner muss lokal sein.") }
        let compiled = try CompiledSearch(options),root = FileSystem.canonical(root)
        guard root.isFileURL,FileSystem.isDirectory(root) else { throw CommanderError.message("Bitte einen vorhandenen lokalen Suchordner wählen.") }
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
        guard let iterator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil,options:enumeration,errorHandler:{ url,error in
            warn("\(url.path): \(error.localizedDescription)");return !token.isCancelled
        }) else { throw CommanderError.message("Suchordner kann nicht gelesen werden.") }
        do {
            for case let url as URL in iterator {
                try token.check();if result.limitReached { break };result.scanned += 1
                do {
                    var info = stat();guard lstat(url.path,&info) == 0 else { throw CommanderError.message("Eintrag nicht lesbar: \(url.path)") }
                    let directory = info.st_mode & S_IFMT == S_IFDIR,link = info.st_mode & S_IFMT == S_IFLNK,regular = info.st_mode & S_IFMT == S_IFREG
                    if link || !options.recursive { iterator.skipDescendants() }
                    if directory && compiled.folders.matches(url.lastPathComponent) { iterator.skipDescendants();publish();continue }
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
                        guard regular else { publish();continue }
                        let reader = try SearchReader(url,expected:info),text: String?
                        if options.searchOfficeDocuments && DocumentText.supports(url) {
                            text = try DocumentText.extract(reader.descriptorURL,token:token,fileExtension:url.pathExtension);try reader.verify()
                        } else { text = try reader.text(encoding:options.encoding,token:token) }
                        try token.check()
                        guard let text,let match = compiled.range(in:text) else { publish();continue }
                        let lower = text.index(match.lowerBound,offsetBy:-60,limitedBy:text.startIndex) ?? text.startIndex
                        let upper = text.index(lower,offsetBy:240,limitedBy:text.endIndex) ?? text.endIndex
                        snippet = String(text[lower..<upper]).replacingOccurrences(of:"\r",with:" ").replacingOccurrences(of:"\n",with:" ")
                        // The path must still refer to the same file after matching.
                        try reader.verify()
                    }
                    append(SearchHit(url:url,member:nil,size:info.st_size,isDirectory:directory,modified:modified,snippet:snippet));publish()
                } catch CommanderError.cancelled { throw CommanderError.cancelled }
                catch { warn(error.localizedDescription) }
            }
            try token.check()
        } catch CommanderError.cancelled { result.cancelled = true }
        publish(force:true);return result
    }
}
