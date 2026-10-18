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

public enum SearchService {
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
