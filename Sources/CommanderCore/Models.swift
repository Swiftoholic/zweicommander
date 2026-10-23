import Foundation

public enum CommanderError: LocalizedError {
    case message(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return "Vorgang abgebrochen. Bereits abgeschlossene Schritte bleiben erhalten."
        }
    }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSCondition()
    private var value = false
    private var paused = false
    private var waiters = 0
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    public var isWaitingForResume: Bool { lock.lock(); defer { lock.unlock() }; return waiters > 0 }
    public func cancel() { lock.lock(); value = true; paused = false; lock.broadcast(); lock.unlock() }
    public func pause() { lock.lock(); if !value { paused = true }; lock.unlock() }
    public func resume() { lock.lock(); paused = false; lock.broadcast(); lock.unlock() }
    public func check() throws {
        lock.lock()
        if paused && !value {
            waiters += 1
            while paused && !value { lock.wait() }
            waiters -= 1
        }
        let cancelled = value; lock.unlock()
        if cancelled { throw CommanderError.cancelled }
    }
}

public struct FileEntry: Identifiable, Hashable {
    static let metadataKeys: Set<URLResourceKey> = [.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey,.isPackageKey,.fileSizeKey,.contentModificationDateKey,.localizedTypeDescriptionKey]
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isRegularFile: Bool
    public let isPackage: Bool
    public let size: Int64
    public let modified: Date
    public let kind: String
    public let permissions: Int
    public var id: String { url.path }
    public var fileExtension: String { isDirectory ? "" : url.pathExtension }
    public var attributeText: String {
        [(isDirectory ? "D" : ""),(isSymbolicLink ? "L" : ""),(name.hasPrefix(".") ? "H" : ""),(permissions & 0o200 == 0 ? "R" : "")].filter { !$0.isEmpty }.joined(separator:" ")
    }
    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys:Self.metadataKeys)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        self.url = url
        name = url.lastPathComponent
        isSymbolicLink = values.isSymbolicLink ?? false
        isRegularFile = (attrs[.type] as? FileAttributeType) == .typeRegular
        isDirectory = values.isDirectory ?? false
        isPackage = values.isPackage ?? false
        size = Int64(values.fileSize ?? 0)
        modified = values.contentModificationDate ?? .distantPast
        kind = values.localizedTypeDescription ?? (isDirectory ? "Ordner" : "Datei")
        permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}

public enum FileSystem {
    public static let fm = FileManager.default
    public static func exists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }
    public static func isDirectory(_ url: URL) -> Bool {
        var value: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue
    }
    public static func isSymlink(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
    public static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    public static func relativePath(of url: URL, inside root: URL) throws -> String {
        // macOS enumerators resolve /var to /private/var. Preserve the final link itself.
        let base = canonical(root).pathComponents
        let path = canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).pathComponents
        guard path.count >= base.count, Array(path.prefix(base.count)) == base else { throw CommanderError.message("Pfad liegt außerhalb des Basisordners: \(url.path)") }
        return path.dropFirst(base.count).joined(separator: "/")
    }
    public static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = canonical(child).path, p = canonical(parent).path
        return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
    }
    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else {
            throw CommanderError.message("Ungültiger Dateiname: \(name)")
        }
    }
    public static func list(_ directory: URL, showHidden: Bool,token: CancellationToken = .init(),onBatch: (([FileEntry])->Void)? = nil) throws -> [FileEntry] {
        try token.check()
        let urls = try fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:Array(FileEntry.metadataKeys),options:showHidden ? [] : [.skipsHiddenFiles])
        var result: [FileEntry] = [],batch: [FileEntry] = [],last = ProcessInfo.processInfo.systemUptime
        result.reserveCapacity(urls.count)
        for url in urls {
            try token.check()
            guard let entry = try? FileEntry(url:url) else { continue }
            result.append(entry)
            if let onBatch {
                batch.append(entry)
                if result.count == 100 || (batch.count >= 512 && ProcessInfo.processInfo.systemUptime-last >= 0.12) {
                    onBatch(batch);batch.removeAll(keepingCapacity:true);last = ProcessInfo.processInfo.systemUptime
                }
            }
        }
        try token.check()
        if !batch.isEmpty { onBatch?(batch) }
        return result
    }
    public static func sorted(_ entries: [FileEntry], key: String = "name", ascending: Bool = true, foldersFirst: Bool = true) -> [FileEntry] {
        entries.sorted { a, b in
            if foldersFirst && a.isDirectory != b.isDirectory { return a.isDirectory }
            var comparison: ComparisonResult = .orderedSame
            switch key {
            case "size": comparison = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case "modified": comparison = a.modified.compare(b.modified)
            case "ext": comparison = a.fileExtension.localizedStandardCompare(b.fileExtension)
            case "kind": comparison = a.kind.localizedStandardCompare(b.kind)
            case "attributes": comparison = a.attributeText.localizedStandardCompare(b.attributeText)
            case "permissions": comparison = a.permissions == b.permissions ? .orderedSame : (a.permissions < b.permissions ? .orderedAscending : .orderedDescending)
            case "path": comparison = a.url.path.localizedStandardCompare(b.url.path)
            default: break
            }
            if comparison == .orderedSame { comparison = a.name.localizedStandardCompare(b.name) }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
    public static func uniqueDestination(_ original: URL) -> URL {
        if !exists(original) { return original }
        let parent = original.deletingLastPathComponent()
        let ext = original.pathExtension
        let stem = ext.isEmpty ? original.lastPathComponent : original.deletingPathExtension().lastPathComponent
        for index in 2...100_000 {
            let name = "\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
            let result = parent.appendingPathComponent(name)
            if !exists(result) { return result }
        }
        return parent.appendingPathComponent(UUID().uuidString + "-" + original.lastPathComponent)
    }
    public static func topLevelSelection(_ urls: [URL]) -> [URL] {
        let unique = Array(Set(urls.map { $0.standardizedFileURL }))
        return unique.filter { item in
            !unique.contains { other in
                other != item && !isSymlink(other) && isDirectory(other) && item.path.hasPrefix(other.path + "/")
            }
        }.sorted { $0.path < $1.path }
    }
    public static func walk(_ root: URL, showHidden: Bool = true, token: CancellationToken = .init(), visit: (URL) throws -> Void, onError: ((URL, Error) -> Void)? = nil) throws {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        var failure: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: options, errorHandler: { url, error in
            if let handler = onError { handler(url, error); return true }
            failure = error; return false
        }) else { throw CommanderError.message("Ordner kann nicht gelesen werden: \(root.path)") }
        for case let url as URL in enumerator {
            try token.check()
            if isSymlink(url) { enumerator.skipDescendants() }
            try visit(url)
        }
        if let failure { throw failure }
    }
    public static func directorySize(_ root: URL, token: CancellationToken = .init()) throws -> (bytes: Int64, files: Int) {
        var total: Int64 = 0, count = 0
        try walk(root, token: token) { url in
            let e = try FileEntry(url: url)
            if !e.isDirectory { total += e.size; count += 1 }
        }
        return (total, count)
    }
}

public struct NameFilter {
    private let expression: NSRegularExpression?
    private let text: String
    public init(_ text: String, regex: Bool = false) throws {
        self.text = text
        if regex && !text.isEmpty {
            expression = try NSRegularExpression(pattern: text, options: [.caseInsensitive])
        } else if text.contains("*") || text.contains("?") {
            let escaped = NSRegularExpression.escapedPattern(for: text).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".")
            expression = try NSRegularExpression(pattern: "^" + escaped + "$", options: [.caseInsensitive])
        } else { expression = nil }
    }
    public func matches(_ name: String) -> Bool {
        if text.isEmpty { return true }
        if let expression { return expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil }
        return name.localizedCaseInsensitiveContains(text)
    }
}

public struct FileStamp: Equatable, Codable {
    let size: UInt64
    let date: Date
    let inode: UInt64
    let device: UInt64
    func sameObject(as other: FileStamp) -> Bool { inode == other.inode && device == other.device }
    public init(_ url: URL) throws {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        date = a[.modificationDate] as? Date ?? .distantPast
        inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        device = (a[.systemNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
