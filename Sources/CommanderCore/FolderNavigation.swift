import Foundation

public enum FolderNavigation {
    /// A fresh branch read; errors remain errors, never a successful empty branch.
    public static func children(of directory:URL,token:CancellationToken = .init()) throws -> [URL] {
        try token.check()
        guard directory.isFileURL,(directory.host == nil || directory.host == "localhost"),!directory.path.contains("\0") else { throw CommanderError.message("Ein lokaler Ordner wird benötigt.") }
        let entry = try FileEntry(url:directory)
        guard entry.isDirectory,!entry.isSymbolicLink else { throw CommanderError.message("Ordnerbaum benötigt einen gewöhnlichen lokalen Ordner.") }
        let urls = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isPackageKey],options:[.skipsHiddenFiles])
        var children:[URL] = []
        for url in urls {
            try token.check()
            // A readable but non-searchable directory can enumerate names while every
            // child stat fails. Silently discarding those errors would look empty.
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard (attributes[.type] as? FileAttributeType) == .typeDirectory else { continue }
            guard try url.resourceValues(forKeys:[.isPackageKey]).isPackage != true else { continue }
            children.append(directory.appendingPathComponent(url.lastPathComponent,isDirectory:false))
        }
        try token.check()
        // Directory enumeration can resolve parent aliases (for example a mounted alias).
        // Keep child identities under the requested branch, so a refresh reuses its rows.
        return children.sorted { let comparison = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent);return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedAscending }
    }

    /// Follow an ancestor/descendant move by the same number of levels on the other side.
    /// Unrelated locations do not have a meaningful linked destination.
    public static func linkedDestination(from old:URL,to new:URL,opposite:URL) -> URL? {
        guard [old,new,opposite].allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "localhost") && !$0.path.contains("\0") }) else { return nil }
        let before = old.standardizedFileURL.pathComponents,after = new.standardizedFileURL.pathComponents
        guard before != after else { return nil }
        if after.count > before.count,Array(after.prefix(before.count)) == before {
            return after.dropFirst(before.count).reduce(opposite.standardizedFileURL) { $0.appendingPathComponent($1,isDirectory:false) }
        }
        guard before.count > after.count,Array(before.prefix(after.count)) == after else { return nil }
        let steps = before.count-after.count,other = opposite.standardizedFileURL.pathComponents
        // Do not silently clamp repeated parent moves at the filesystem root.
        guard steps < other.count else { return nil }
        return (0..<steps).reduce(opposite.standardizedFileURL) { value,_ in value.deletingLastPathComponent() }
    }
}
