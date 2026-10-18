import Foundation
import CryptoKit

public enum HashAlgorithm: String, CaseIterable { case sha256 = "SHA-256", sha512 = "SHA-512", sha1 = "SHA-1", md5 = "MD5" }
public enum Checksums {
    private static func calculate<H: HashFunction>(_ initial: H, url: URL, token: CancellationToken) throws -> String {
        guard try FileEntry(url: url).isRegularFile else { throw CommanderError.message("Prüfsummen benötigen reguläre Dateien.") }
        let before = try FileStamp(url)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = initial
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try token.check(); hash.update(data: data) }
        guard try FileStamp(url) == before else { throw CommanderError.message("Datei während der Prüfsummenberechnung verändert: \(url.path)") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func hash(_ url: URL, algorithm: HashAlgorithm = .sha256, token: CancellationToken = .init()) throws -> String {
        switch algorithm {
        case .sha256: return try calculate(SHA256(), url: url, token: token)
        case .sha512: return try calculate(SHA512(), url: url, token: token)
        case .sha1: return try calculate(Insecure.SHA1(), url: url, token: token)
        case .md5: return try calculate(Insecure.MD5(), url: url, token: token)
        }
    }
    public static func verify(_ manifest: URL, algorithm: HashAlgorithm, token: CancellationToken = .init()) throws -> [String] {
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let parent = manifest.deletingLastPathComponent()
        let regex = try NSRegularExpression(pattern: "^([0-9a-fA-F]+) [ *](.+)$")
        var results: [String] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty && !line.hasPrefix("#") {
            try token.check()
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let h = Range(match.range(at: 1), in: line), let n = Range(match.range(at: 2), in: line) else {
                results.append("UNGÜLTIGE ZEILE: " + line); continue
            }
            let name = String(line[n]), file = parent.appendingPathComponent(name)
            guard !name.hasPrefix("/"), FileSystem.isInside(file, parent) else { results.append("UNSICHERER PFAD: " + name); continue }
            do { results.append((try hash(file, algorithm: algorithm, token: token) == line[h].lowercased() ? "OK  " : "ABWEICHEND  ") + name) }
            catch { results.append("FEHLER  \(name): \(error.localizedDescription)") }
        }
        return results
    }
}

public struct SearchOptions {
    public var name = ""
    public var regex = false
    public var content = ""
    public var showHidden = false
    public var filesOnly = false
    public var minimumSize: Int64 = 0
    public var maximumSize: Int64 = .max
    public var modifiedAfter: Date?
    public var searchArchives = false
    public var searchOfficeDocuments = false
    public init() {}
}
public struct SearchReport {
    public var urls: [URL] = []
    public var archiveMatches: [String] = []
    public var warnings: [String] = []
    public var scanned = 0
}
public enum SearchService {
    public static func search(_ root: URL, options: SearchOptions, token: CancellationToken = .init(), progress: (Int) -> Void = { _ in }) throws -> SearchReport {
        let filter = try NameFilter(options.name, regex: options.regex)
        var result = SearchReport()
        try FileSystem.walk(root, showHidden: options.showHidden, token: token, visit: { url in
            result.scanned += 1
            if result.scanned % 200 == 0 { progress(result.scanned) }
            do {
                let entry = try FileEntry(url: url)
                if options.searchArchives && ArchiveService.isArchive(url) && !entry.isDirectory && !entry.isSymbolicLink {
                    do {
                        for member in try ArchiveService.list(url, token: token) where filter.matches((member.path as NSString).lastPathComponent) {
                            result.archiveMatches.append(url.path + " ▸ " + member.path)
                        }
                    } catch { result.warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
                guard filter.matches(entry.name), (!options.filesOnly || !entry.isDirectory), entry.size >= options.minimumSize, entry.size <= options.maximumSize else { return }
                if let since = options.modifiedAfter, entry.modified < since { return }
                if !options.content.isEmpty {
                    guard entry.isRegularFile else { return }
                    let text: String
                    if options.searchOfficeDocuments && DocumentText.supports(url) {
                        text = try DocumentText.extract(url, token: token)
                    } else {
                        guard entry.size <= 32 * 1024 * 1024 else { result.warnings.append("Inhaltssuche übersprungen (>32 MB): \(url.path)"); return }
                        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                        let data = try handle.read(upToCount: 32*1024*1024+1) ?? Data()
                        guard data.count <= 32*1024*1024 else { throw CommanderError.message("Datei ist während des Lesens über das Limit gewachsen.") }
                        guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return }
                        text = decoded
                    }
                    guard text.localizedCaseInsensitiveContains(options.content) else { return }
                }
                result.urls.append(url)
            } catch { result.warnings.append("\(url.path): \(error.localizedDescription)") }
        }, onError: { url, error in result.warnings.append("\(url.path): \(error.localizedDescription)") })
        try token.check()
        return result
    }
    public static func duplicates(_ root: URL, token: CancellationToken = .init(), progress: (String) -> Void = { _ in }) throws -> [[URL]] {
        var sizes: [Int64: [URL]] = [:]
        try FileSystem.walk(root, token: token) { url in
            let entry = try FileEntry(url: url)
            if entry.isRegularFile { sizes[entry.size, default: []].append(url) }
        }
        var matches: [[URL]] = []
        for group in sizes.values where group.count > 1 {
            var hashes: [String: [URL]] = [:]
            for url in group { try token.check(); progress(url.lastPathComponent); hashes[try Checksums.hash(url, token: token), default: []].append(url) }
            matches += hashes.values.filter { $0.count > 1 }.map { $0.sorted { $0.path < $1.path } }
        }
        return matches.sorted { $0[0].path < $1[0].path }
    }
}
