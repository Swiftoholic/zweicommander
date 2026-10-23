import Foundation
import CFileCopy

struct CopyNode: Equatable {
    let relative: String
    let stamp: FileStamp
    let directory: Bool, link: Bool
    let bytes: Int64
    let version: RenameVersion
}
struct CopyTree: Equatable {
    let nodes: [CopyNode]
    let filter: TransferFilter
    let referenceDate: Date?
    init(nodes: [CopyNode],filter: TransferFilter,referenceDate: Date? = nil) { self.nodes = nodes;self.filter = filter;self.referenceDate = referenceDate }
    var bytes: Int64 { nodes.reduce(0) { $0+$1.bytes } }
    static func scan(_ source: URL, filter: TransferFilter = .init(), token: CancellationToken,referenceDate: Date? = nil) throws -> CopyTree {
        let reference = filter.modifiedAge != nil && !filter.structureOnly ? referenceDate ?? Date() : nil
        let compiled = try CompiledTransferFilter(filter,referenceDate:reference ?? Date())
        var nodes: [CopyNode] = []
        var visited = 0
        enum ScanDisposition { case descend, skip, leaf }
        @discardableResult func append(_ url: URL, relative: String) throws -> ScanDisposition {
            try token.check()
            let entry = try FileEntry(url:url)
            visited += 1
            guard visited <= 1_000_000 else { throw CommanderError.message("Auftrag enthält mehr als eine Million erfasste Objekte.") }
            let directory = entry.isDirectory && !entry.isSymbolicLink
            if directory && !relative.isEmpty && (!filter.recursive || compiled.excludesFolder(entry.name)) { return .skip }
            if !directory && (filter.structureOnly || !compiled.includesFile(entry.name)) { return entry.isSymbolicLink ? .skip : .leaf }
            guard entry.isDirectory || entry.isSymbolicLink || entry.isRegularFile else { throw CommanderError.message("Spezialdatei wird nicht kopiert: \(url.path)") }
            let stamp = try FileStamp(url)
            if !directory && !compiled.includesMetadata(size:Int64(clamping:stamp.size),modified:stamp.date,isLink:entry.isSymbolicLink) { return entry.isSymbolicLink ? .skip : .leaf }
            nodes.append(CopyNode(relative:relative,stamp:stamp,directory:directory,link:entry.isSymbolicLink,bytes:entry.isRegularFile && !entry.isSymbolicLink ? Int64(clamping:stamp.size) : 0,version:try RenameVersion.read(url)))
            return directory ? .descend : entry.isSymbolicLink ? .skip : .leaf
        }
        let directory = try append(source,relative:"")
        if directory == .descend {
            var failure: Error?
            guard let enumerator = FileManager.default.enumerator(at:source,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],errorHandler:{ _,error in failure = error;return false }) else { throw CommanderError.message("Ordner kann nicht gelesen werden: \(source.path)") }
            for case let url as URL in enumerator {
                if try append(url,relative:FileSystem.relativePath(of:url,inside:source)) == .skip { enumerator.skipDescendants() }
            }
            if let failure { throw failure }
        }
        if !filter.keepEmptyFolders && !filter.structureOnly {
            var needed: Set<String> = []
            for node in nodes where !node.directory {
                var parent = node.relative as NSString
                while parent.length > 0 {
                    parent = parent.deletingLastPathComponent as NSString
                    needed.insert(parent as String)
                }
            }
            nodes.removeAll { $0.directory && !needed.contains($0.relative) }
        }
        try token.check()
        return CopyTree(nodes:nodes.sorted { $0.relative < $1.relative },filter:filter,referenceDate:reference)
    }
    func validate(_ source: URL, token: CancellationToken) throws {
        guard try Self.scan(source,filter:filter,token:token,referenceDate:referenceDate) == self else { throw CommanderError.message("Quelle wurde seit der Dateivorschau verändert: \(source.lastPathComponent)") }
    }
    func copy(_ source: URL, to destination: URL, token: CancellationToken, progress: @escaping (String,Int64,Int64) -> Void) throws {
        let fm = FileManager.default
        let totalBytes = bytes
        var completed: Int64 = 0
        for node in nodes {
            try token.check()
            let from = node.relative.isEmpty ? source : source.appendingPathComponent(node.relative)
            let to = node.relative.isEmpty ? destination : destination.appendingPathComponent(node.relative)
            guard try FileStamp(from) == node.stamp else { throw CommanderError.message("Quelle wurde während des Kopierens verändert: \(from.lastPathComponent)") }
            if node.directory {
                try fm.createDirectory(at:to,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            } else {
                let offset = completed
                progress(node.relative.isEmpty ? source.lastPathComponent : node.relative,completed,totalBytes)
                try NativeCopy.copy(from,to:to,token:token) { count in progress(node.relative.isEmpty ? source.lastPathComponent : node.relative,offset+min(node.bytes,count),totalBytes) }
                completed += node.bytes
                progress(node.relative.isEmpty ? source.lastPathComponent : node.relative,completed,totalBytes)
            }
        }
        // Apply directory metadata after their contents, so read-only source permissions cannot block staging.
        for node in nodes.reversed() where node.directory {
            try token.check()
            let from = node.relative.isEmpty ? source : source.appendingPathComponent(node.relative)
            let to = node.relative.isEmpty ? destination : destination.appendingPathComponent(node.relative)
            try NativeCopy.copy(from,to:to,metadataOnly:true,token:token,progress:{ _ in })
        }
        try validate(source,token:token)
    }
}
private final class NativeCopyContext {
    let token: CancellationToken
    let progress: (Int64) -> Void
    var error: Error?
    var highest: Int64 = 0
    init(_ token: CancellationToken, _ progress: @escaping (Int64) -> Void) { self.token = token; self.progress = progress }
    func update(_ bytes: Int64) -> Int32 {
        do {
            try token.check()
            if bytes > highest { highest = bytes; progress(bytes) }
            try token.check(); return 0
        } catch { self.error = error; return 1 }
    }
}
enum NativeCopy {
    static func resumeDescriptors(_ source: Int32,to destination: Int32,offset: Int64,total: Int64,token: CancellationToken,verifying: @escaping (Int64)->Void,progress: @escaping (Int64)->Void) throws {
        func invoke(_ callback: @escaping (Int64)->Void,_ body: (UnsafeMutableRawPointer)->Int32) throws {
            try token.check();let context = NativeCopyContext(token,callback)
            let result = body(Unmanaged.passUnretained(context).toOpaque())
            if let error = context.error { throw error }
            if result == EILSEQ { throw recoveryError("Teilkopie stimmt nicht mit der Quelle überein. Sie bleibt zur Prüfung erhalten.") }
            guard result == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(result)) };try token.check()
        }
        let bridge: @convention(c) (UnsafeMutableRawPointer?,Int64)->Int32 = { raw,count in
            guard let raw else { return 1 };return Unmanaged<NativeCopyContext>.fromOpaque(raw).takeUnretainedValue().update(count)
        }
        if offset > 0 { try invoke(verifying) { zc_verify_prefix_fd(source,destination,offset,bridge,$0) } }
        try invoke(progress) { zc_resume_fd(source,destination,offset,total,bridge,$0) }
    }
    static func metadataDescriptors(_ source: Int32,to destination: Int32) throws {
        let result = zc_metadata_fd(source,destination)
        guard result == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(result)) }
    }
    static func copyDescriptors(_ source: Int32,to destination: Int32,token: CancellationToken,progress: @escaping (Int64)->Void) throws {
        try token.check();let context = NativeCopyContext(token,progress)
        let result = zc_copy_fd(source,destination,{ raw,bytes in
            guard let raw else { return 1 }
            return Unmanaged<NativeCopyContext>.fromOpaque(raw).takeUnretainedValue().update(bytes)
        },Unmanaged.passUnretained(context).toOpaque())
        if let error = context.error { throw error }
        guard result == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(result)) };try token.check()
    }
    static func copy(_ source: URL,to destination: URL,metadataOnly: Bool = false,token: CancellationToken,progress: @escaping (Int64) -> Void) throws {
        try token.check()
        let context = NativeCopyContext(token,progress)
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        let result = zc_copy(source.path,destination.path,metadataOnly ? 1 : 0,{ raw,bytes in
            guard let raw else { return 1 }
            return Unmanaged<NativeCopyContext>.fromOpaque(raw).takeUnretainedValue().update(bytes)
        },opaque)
        if let error = context.error { throw error }
        guard result == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(result)) }
        try token.check()
    }
}
