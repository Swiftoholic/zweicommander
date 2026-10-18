import Foundation

public struct RenameRule {
    public var pattern = "{name}"
    public var search = ""
    public var replacement = ""
    public var regex = false
    public var start = 1
    public var digits = 3
    public var letterCase = 0 // 0 unchanged, 1 lowercase, 2 uppercase
    public init() {}
}
public struct RenameItem {
    public let source: URL
    public let target: URL
    public init(source: URL, target: URL) { self.source = source; self.target = target }
    public var changed: Bool { source.path != target.path }
}
public enum RenameEngine {
    public static func preview(_ urls: [URL], rule: RenameRule) throws -> [RenameItem] {
        let expression = rule.regex && !rule.search.isEmpty ? try NSRegularExpression(pattern: rule.search) : nil
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"
        var result: [RenameItem] = []
        for (index, url) in urls.enumerated() {
            let isDir = FileSystem.isDirectory(url)
            let ext = isDir ? "" : url.pathExtension
            let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            var name = rule.pattern
                .replacingOccurrences(of: "{name}", with: stem)
                .replacingOccurrences(of: "{full}", with: url.lastPathComponent)
                .replacingOccurrences(of: "{ext}", with: ext)
                .replacingOccurrences(of: "{n}", with: String(format: "%0*d", max(1, min(10, rule.digits)), rule.start + index))
                .replacingOccurrences(of: "{date}", with: date.string(from: (try? FileEntry(url: url).modified) ?? Date()))
            if !rule.pattern.contains("{ext}") && !rule.pattern.contains("{full}") && !ext.isEmpty { name += "." + ext }
            if let expression { name = expression.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: rule.replacement) }
            else if !rule.search.isEmpty { name = name.replacingOccurrences(of: rule.search, with: rule.replacement) }
            if rule.letterCase == 1 { name = name.lowercased() }
            if rule.letterCase == 2 { name = name.uppercased() }
            try FileSystem.validateName(name)
            result.append(RenameItem(source: url, target: url.deletingLastPathComponent().appendingPathComponent(name)))
        }
        try validate(result)
        return result
    }
    public static func validate(_ items: [RenameItem]) throws {
        var names = Set<String>()
        let sourcePaths = Set(items.map { $0.source.path })
        for item in items {
            // Conservative collision detection also protects case-insensitive volumes.
            let key = item.target.path.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(key).inserted else { throw CommanderError.message("Mehrere Dateien erhalten denselben Namen: \(item.target.lastPathComponent)") }
            if item.changed && FileSystem.exists(item.target) && !sourcePaths.contains(item.target.path) {
                // A case-only rename refers to the same filesystem object on insensitive volumes.
                let same = (try? FileStamp(item.source)) == (try? FileStamp(item.target))
                guard same else { throw CommanderError.message("Zielname existiert bereits: \(item.target.lastPathComponent)") }
            }
        }
    }
    public static func apply(_ items: [RenameItem]) throws {
        try validate(items)
        let fm = FileManager.default
        var staged: [(RenameItem, URL)] = []
        var published: [(RenameItem, URL)] = []
        do {
            for item in items where item.changed {
                let temp = item.source.deletingLastPathComponent().appendingPathComponent(".zweicommander-rename-" + UUID().uuidString)
                try fm.moveItem(at: item.source, to: temp)
                staged.append((item, temp))
            }
            for (item, temp) in staged {
                try fm.moveItem(at: temp, to: item.target)
                published.append((item, temp))
            }
        } catch {
            var recovery: [String] = []
            // Re-stage published targets first so cycles can be rolled back safely.
            for (item, temp) in published.reversed() {
                do { try fm.moveItem(at: item.target, to: temp) }
                catch { recovery.append("\(item.target.path): \(error.localizedDescription)") }
            }
            for (item, temp) in staged.reversed() where FileSystem.exists(temp) {
                do { try fm.moveItem(at: temp, to: item.source) }
                catch { recovery.append("\(temp.path) → \(item.source.path): \(error.localizedDescription)") }
            }
            throw CommanderError.message(error.localizedDescription + (recovery.isEmpty ? "" : "\nWiederherstellung erforderlich:\n" + recovery.joined(separator: "\n")))
        }
    }
    public static func reversed(_ items: [RenameItem]) -> [RenameItem] { items.map { RenameItem(source: $0.target, target: $0.source) } }
}
