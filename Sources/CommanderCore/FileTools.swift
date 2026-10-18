import Foundation

public struct SplitManifest: Codable {
    public let originalName: String
    public let originalSize: Int64
    public let parts: [Part]
    public struct Part: Codable { public let name: String; public let bytes: Int64; public let sha256: String }
}
public enum FileTools {
    public static func split(_ source:URL,to directory:URL,chunkBytes:Int64,token:CancellationToken = .init(),progress:(String)->Void = {_ in}) throws {
        guard chunkBytes > 0, try FileEntry(url:source).isRegularFile else { throw CommanderError.message("Eine reguläre Datei und eine positive Teilgröße auswählen.") }
        guard !FileSystem.exists(directory) else { throw CommanderError.message("Zielordner existiert bereits.") }
        let before = try FileStamp(source)
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".zweicommander-split-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
        defer { if FileSystem.exists(staging) { try? FileManager.default.removeItem(at:staging) } }
        let input = try FileHandle(forReadingFrom:source); defer { try? input.close() }
        let originalSize = try FileEntry(url:source).size
        var total:Int64 = 0, parts:[SplitManifest.Part] = [], index = 1
        repeat {
            try token.check()
            let name = source.lastPathComponent+String(format:".part%04d",index)
            let output = try FileOperations.newFile(in:staging,name:name)
            let handle = try FileHandle(forWritingTo:output)
            var written:Int64 = 0
            do {
                while written < chunkBytes {
                    try token.check()
                    guard let data = try input.read(upToCount:Int(min(1024*1024,chunkBytes-written))), !data.isEmpty else { break }
                    try handle.write(contentsOf:data); written += Int64(data.count)
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            guard written > 0 || originalSize == 0 else { throw CommanderError.message("Quelldatei wurde während des Teilens verkürzt.") }
            parts.append(.init(name:name,bytes:written,sha256:try Checksums.hash(output,token:token)))
            total += written; index += 1; progress("\(parts.count) Teile · \(total) Bytes")
        } while total < originalSize
        guard total == originalSize,try FileStamp(source) == before else { throw CommanderError.message("Quelldatei wurde während des Teilens geändert.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(SplitManifest(originalName:source.lastPathComponent,originalSize:originalSize,parts:parts)).write(to:staging.appendingPathComponent("parts.zwei.json"))
        try FileManager.default.moveItem(at:staging,to:directory)
    }
    public static func join(_ manifestURL:URL,to destination:URL,token:CancellationToken = .init(),progress:(String)->Void = {_ in}) throws {
        guard !FileSystem.exists(destination) else { throw CommanderError.message("Die Zieldatei existiert bereits.") }
        let manifest = try JSONDecoder().decode(SplitManifest.self,from:Data(contentsOf:manifestURL))
        guard !manifest.parts.isEmpty else { throw CommanderError.message("Leere Teileliste.") }
        let parent = manifestURL.deletingLastPathComponent()
        let staging = try FileOperations.newFile(in:destination.deletingLastPathComponent(),name:".zweicommander-join-"+UUID().uuidString)
        defer { if FileSystem.exists(staging) { try? FileManager.default.removeItem(at:staging) } }
        let output = try FileHandle(forWritingTo:staging); defer { try? output.close() }
        var total:Int64 = 0
        for part in manifest.parts {
            try FileSystem.validateName(part.name); try token.check(); progress(part.name)
            let url = parent.appendingPathComponent(part.name)
            guard !FileSystem.isSymlink(url),try Checksums.hash(url,token:token) == part.sha256 else { throw CommanderError.message("Prüfsumme stimmt nicht: \(part.name)") }
            let stamp = try FileStamp(url), input = try FileHandle(forReadingFrom:url)
            var size:Int64 = 0
            do {
                while let data = try input.read(upToCount:1024*1024),!data.isEmpty { try token.check(); try output.write(contentsOf:data); size += Int64(data.count) }
                try input.close()
            } catch { try? input.close(); throw error }
            guard size == part.bytes,try FileStamp(url) == stamp else { throw CommanderError.message("Teil wurde verändert: \(part.name)") }
            total += size
        }
        guard total == manifest.originalSize else { throw CommanderError.message("Gesamtgröße stimmt nicht mit der Teileliste überein.") }
        try output.synchronize(); try output.close()
        try FileManager.default.moveItem(at:staging,to:destination)
    }
    public static func exportTSV(_ entries:[FileEntry]) -> String {
        func clean(_ s:String)->String { s.replacingOccurrences(of:"\t",with:"\\t").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"\n",with:"\\n") }
        let date = ISO8601DateFormatter()
        return "Name\tPfad\tTyp\tBytes\tGeändert\tRechte\n"+entries.map { e in
            [clean(e.name),clean(e.url.path),e.isDirectory ? "Ordner" : "Datei",String(e.size),date.string(from:e.modified),String(format:"%03o",e.permissions)].joined(separator:"\t")
        }.joined(separator:"\n")+"\n"
    }
}
