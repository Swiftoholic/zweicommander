import Foundation
import CommanderCore

struct FileListSnapshot {
    let entries: [FileEntry]
    let indexes: [String:Int]
    let totalBytes: Int64
    static func make(_ source:[FileEntry],filter:NameFilter,key:String,ascending:Bool,foldersFirst:Bool,token:CancellationToken) throws -> FileListSnapshot {
        try token.check()
        let sorted = FileSystem.sorted(source.filter { filter.matches($0.name) },key:key,ascending:ascending,foldersFirst:foldersFirst)
        var parents: [String:String] = [:],indexes: [String:Int] = [:],total:Int64 = 0
        indexes.reserveCapacity(sorted.count)
        for (index,entry) in sorted.enumerated() {
            if index % 128 == 0 { try token.check() }
            let parent = entry.url.deletingLastPathComponent(),path:String
            if let saved = parents[parent.path] { path = saved }
            else { path = FileSystem.canonical(parent).path;parents[parent.path] = path }
            indexes[(path == "/" ? "/" : path+"/")+entry.name] = index
            if !entry.isDirectory { let sum = total.addingReportingOverflow(entry.size);total = sum.overflow ? Int64.max : sum.partialValue }
        }
        try token.check();return FileListSnapshot(entries:sorted,indexes:indexes,totalBytes:total)
    }
}
