import Foundation

public enum ComparisonState: String { case equal = "Gleich", leftOnly = "Nur links", rightOnly = "Nur rechts", different = "Verschieden", typeConflict = "Typkonflikt", link = "Verknüpfung" }
public struct ComparisonItem {
    public let relativePath: String
    public let left: URL?
    public let right: URL?
    public let state: ComparisonState
    public let isDirectory: Bool
    public let leftStamp: FileStamp?
    public let rightStamp: FileStamp?
}
public struct SyncItem {
    public let source: URL
    public let destination: URL
    public let sourceStamp: FileStamp
    public let destinationStamp: FileStamp?
    public let isDirectory: Bool
}
public enum CompareService {
    public static func compare(_ left: URL, _ right: URL, content: Bool = true, token: CancellationToken = .init(), progress: (String) -> Void = { _ in }) throws -> [ComparisonItem] {
        guard !FileSystem.isInside(left, right), !FileSystem.isInside(right, left) else { throw CommanderError.message("Vergleichsordner müssen verschieden sein und dürfen nicht ineinander liegen.") }
        func index(_ root: URL) throws -> [String: FileEntry] {
            var value: [String: FileEntry] = [:]
            try FileSystem.walk(root, token: token) { url in
                let relative = try FileSystem.relativePath(of: url, inside: root)
                if !relative.split(separator: "/").contains(where: { $0.hasPrefix(".zweicommander-") }) { value[relative] = try FileEntry(url: url) }
            }
            return value
        }
        let l = try index(left), r = try index(right)
        var results: [ComparisonItem] = []
        for path in Set(l.keys).union(r.keys).sorted() {
            try token.check(); progress(path)
            let a = l[path], b = r[path]
            let state: ComparisonState
            if a?.isSymbolicLink == true || b?.isSymbolicLink == true { state = .link }
            else if a == nil { state = .rightOnly }
            else if b == nil { state = .leftOnly }
            else if a!.isDirectory != b!.isDirectory { state = .typeConflict }
            else if a!.isDirectory { state = .equal }
            else if a!.size != b!.size { state = .different }
            else if content { state = try Checksums.hash(a!.url, token: token) == Checksums.hash(b!.url, token: token) ? .equal : .different }
            else { state = abs(a!.modified.timeIntervalSince(b!.modified)) < 1 ? .equal : .different }
            results.append(ComparisonItem(relativePath: path, left: a?.url, right: b?.url, state: state, isDirectory: a?.isDirectory ?? b?.isDirectory ?? false, leftStamp: try a.map { try FileStamp($0.url) }, rightStamp: try b.map { try FileStamp($0.url) }))
        }
        return results
    }
    public static func plan(_ comparison: [ComparisonItem], left: URL, right: URL, leftToRight: Bool) throws -> [SyncItem] {
        var plan: [SyncItem] = []
        for entry in comparison where entry.state != .equal {
            guard entry.state != .typeConflict && entry.state != .link else { throw CommanderError.message("Typkonflikte oder Verknüpfungen zunächst manuell auflösen: \(entry.relativePath)") }
            let source = leftToRight ? entry.left : entry.right
            guard let source else { continue } // Destination-only items are never deleted.
            let stamp = leftToRight ? entry.leftStamp : entry.rightStamp
            let destinationStamp = leftToRight ? entry.rightStamp : entry.leftStamp
            plan.append(SyncItem(source: source, destination: (leftToRight ? right : left).appendingPathComponent(entry.relativePath), sourceStamp: stamp!, destinationStamp: destinationStamp, isDirectory: entry.isDirectory))
        }
        return plan.sorted { $0.destination.path < $1.destination.path }
    }
    public static func synchronize(_ plan: [SyncItem], token: CancellationToken = .init(), progress: (String) -> Void = { _ in }) -> OperationReport {
        var report = OperationReport()
        // Validate the entire preview before making the first change.
        do {
            for item in plan {
                guard try FileStamp(item.source) == item.sourceStamp else { throw CommanderError.message("Quelle seit Vergleich geändert: \(item.source.path)") }
                if let expected = item.destinationStamp {
                    guard try FileStamp(item.destination) == expected else { throw CommanderError.message("Ziel seit Vergleich geändert: \(item.destination.path)") }
                } else if FileSystem.exists(item.destination) { throw CommanderError.message("Ziel wurde seit Vergleich angelegt: \(item.destination.path)") }
            }
            for item in plan {
                try token.check(); progress(item.destination.lastPathComponent)
                if item.isDirectory {
                    try FileManager.default.createDirectory(at: item.destination, withIntermediateDirectories: false)
                    report.completed.append(item.destination)
                } else {
                    guard try FileStamp(item.source) == item.sourceStamp else { throw CommanderError.message("Quelle wurde inzwischen geändert.") }
                    if let expected = item.destinationStamp {
                        guard try FileStamp(item.destination) == expected else { throw CommanderError.message("Ziel wurde inzwischen geändert.") }
                    } else if FileSystem.exists(item.destination) { throw CommanderError.message("Ziel wurde inzwischen angelegt.") }
                    if let undo = try FileOperations.transferOne(item.source, to: item.destination, kind: .copy, policy: item.destinationStamp == nil ? .stop : .replace, token: token) {
                        report.completed.append(undo.current); report.undo.append(undo)
                    }
                }
            }
        } catch { report.errors.append(error.localizedDescription) }
        return report
    }
}
