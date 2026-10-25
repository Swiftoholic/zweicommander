import Foundation
import Darwin
import CArchive

public struct ArchiveMember: Hashable {
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
    public let isRegularFile: Bool
    public let isLink: Bool
    public let modified: Date
    public let permissions: Int
    public init(path:String,size:Int64,isDirectory:Bool,isRegularFile:Bool = true,isLink:Bool = false,modified:Date = .distantPast,permissions:Int = 0o644) {
        self.path = path;self.size = size;self.isDirectory = isDirectory;self.isRegularFile = !isDirectory && isRegularFile;self.isLink = isLink;self.modified = modified;self.permissions = permissions
    }
}
public enum ArchiveService {
    public static let extensions: Set<String> = ["zip", "jar", "war", "ear", "7z", "rar", "tar", "tgz", "gz", "bz2", "xz", "tbz", "txz", "cpio", "iso"]
    public static func isArchive(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    static func isLocal(_ url:URL) -> Bool { url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil && !url.path.contains("\0") }
    static func failure(_ archive: OpaquePointer) -> Error { CommanderError.message(archive_error_string(archive).map { String(cString: $0) } ?? "Archivfehler") }
    static func reader(_ url: URL, password: String?) throws -> OpaquePointer {
        guard let a = archive_read_new() else { throw CommanderError.message("Archiv konnte nicht geöffnet werden.") }
        archive_read_support_filter_all(a); archive_read_support_format_all(a)
        if let password, !password.isEmpty { archive_read_add_passphrase(a, password) }
        if archive_read_open_filename(a, url.path, 1024 * 128) != 0 { let e = failure(a); archive_read_free(a); throw e }
        return a
    }
    static func member(_ entry:OpaquePointer) throws -> ArchiveMember {
        guard let raw = archive_entry_pathname(entry) else { throw CommanderError.message("Archiveintrag ohne Namen.") }
        let path = try safePath(String(cString:raw)),type = archive_entry_filetype(entry)
        return ArchiveMember(path:path,size:archive_entry_size(entry),isDirectory:type == 0o040000,isRegularFile:type == 0o100000,isLink:archive_entry_symlink(entry) != nil || archive_entry_hardlink(entry) != nil || type == 0o120000,modified:Date(timeIntervalSince1970:Double(archive_entry_mtime(entry))),permissions:Int(archive_entry_perm(entry)) & 0o777)
    }
    public static func safePath(_ raw: String) throws -> String {
        guard !raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains("\0") else { throw CommanderError.message("Unsicherer Archivpfad: \(raw)") }
        let pieces = raw.split(separator: "/").filter { $0 != "." }
        guard !pieces.contains(".."), !(pieces.first?.contains(":") ?? false) else { throw CommanderError.message("Unsicherer Archivpfad: \(raw)") }
        return pieces.joined(separator: "/")
    }
    public static func list(_ url: URL, password: String? = nil, token: CancellationToken = .init()) throws -> [ArchiveMember] {
        let a = try reader(url, password: password); defer { archive_read_free(a) }
        var entry: OpaquePointer?, result: [ArchiveMember] = []
        while true {
            try token.check()
            let code = archive_read_next_header(a, &entry)
            if code == 1 { break }
            guard code == 0, let e = entry, let p = archive_entry_pathname(e) else { throw failure(a) }
            let path = try safePath(String(cString: p))
            if !path.isEmpty { result.append(try member(e)) }
            guard result.count <= 1_000_000 else { throw CommanderError.message("Archiv enthält mehr als eine Million Einträge.") }
        }
        return result
    }
    /// Visits headers without retaining an unbounded member list. Returning false stops reading.
    public static func visitMembers(_ url: URL, token: CancellationToken = .init(), visit: (ArchiveMember) throws -> Bool) throws {
        let a = try reader(url,password:nil);defer { archive_read_free(a) }
        var entry: OpaquePointer?,count = 0
        while true {
            try token.check()
            let code = archive_read_next_header(a,&entry)
            if code == 1 { return }
            guard code == 0,let e = entry,let p = archive_entry_pathname(e) else { throw failure(a) }
            count += 1;guard count <= 100_000 else { throw CommanderError.message("Archivsuche: Grenze von 100.000 Einträgen erreicht.") }
            let path = try safePath(String(cString:p))
            if !path.isEmpty,try !visit(ArchiveMember(path:path,size:archive_entry_size(e),isDirectory:archive_entry_filetype(e) == 0o040000)) { return }
        }
    }
    // Whole-archive extraction uses the same checked plan and private staging as member extraction.
    public static func extract(_ url: URL, to destination: URL, password: String? = nil, maxBytes: Int64 = 100 * 1024 * 1024 * 1024, token: CancellationToken = .init(), progress: (String) -> Void = { _ in }) throws {
        let catalog = try ArchiveCatalog.read(url,password:password,token:token)
        let plan = try ArchiveExtractionPlan(catalog:catalog,to:destination,maximumBytes:maxBytes)
        try extract(plan,password:password,token:token,progress:progress)
    }
    public static func readMembers(_ url: URL, maxBytes: Int = 32*1024*1024, token: CancellationToken = .init(), matching: (String) -> Bool) throws -> [(String, Data)] {
        let a = try reader(url, password: nil); defer { archive_read_free(a) }
        var entry: OpaquePointer?, result: [(String, Data)] = [], total = 0, count = 0
        var buffer = [UInt8](repeating: 0, count: 64*1024)
        while true {
            try token.check()
            let code = archive_read_next_header(a, &entry)
            if code == 1 { break }
            guard code == 0, let e = entry, let p = archive_entry_pathname(e) else { throw failure(a) }
            count += 1
            guard count <= 100_000 else { throw CommanderError.message("Zu viele Dokumenteinträge.") }
            let name = try safePath(String(cString: p))
            guard matching(name) else { continue }
            guard archive_entry_filetype(e) == 0o100000, archive_entry_symlink(e) == nil, archive_entry_hardlink(e) == nil else { throw CommanderError.message("Dokumentinhalt enthält eine Verknüpfung oder Spezialdatei.") }
            guard archive_entry_size(e) >= 0, archive_entry_size(e) <= Int64(maxBytes-total) else { throw CommanderError.message("Dokumentinhalt überschreitet das Leselimit.") }
            var data = Data()
            while true {
                try token.check()
                let n = archive_read_data(a, &buffer, buffer.count)
                if n == 0 { break }
                guard n > 0 else { throw failure(a) }
                total += n
                guard total <= maxBytes else { throw CommanderError.message("Dokumentinhalt überschreitet das Leselimit.") }
                data.append(contentsOf: buffer.prefix(n))
            }
            result.append((name, data))
        }
        return result
    }
    public static func pack(_ urls: [URL], to destination: URL, tarGzip: Bool = false, sevenZip: Bool = false, compressionLevel: Int = 6, token: CancellationToken = .init(), progress: (String) -> Void = { _ in },validateBeforePublish:()throws->Void = {}) throws {
        guard isLocal(destination),urls.allSatisfy(isLocal) else { throw CommanderError.message("Archive benötigen lokale Quell- und Zieladressen.") }
        guard !FileSystem.exists(destination) else { throw CommanderError.message("Archivname ist bereits belegt.") }
        let inputs = FileSystem.topLevelSelection(urls)
        guard !inputs.isEmpty else { throw CommanderError.message("Keine Dateien ausgewählt.") }
        for source in inputs where FileSystem.isDirectory(source) {
            guard !FileSystem.isInside(destination, source) else { throw CommanderError.message("Das Archivziel liegt in einem Quellordner.") }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".zweicommander-archive-" + UUID().uuidString)
        let parent = FileSystem.canonical(destination.deletingLastPathComponent()),parentFD = open(parent.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard parentFD >= 0 else { throw CommanderError.message("Archivzielordner ist nicht verfügbar.") };defer { close(parentFD) }
        var parentStat = stat();guard fstat(parentFD,&parentStat) == 0 else { throw CommanderError.message("Archivzielordner konnte nicht geprüft werden.") };let parentVersion = RenameVersion(parentStat)
        guard let a = archive_write_new() else { throw CommanderError.message("Archiv kann nicht erstellt werden.") }
        var outputFD:Int32 = -1,stageVersion:RenameVersion?
        defer {
            archive_write_free(a);if outputFD >= 0 { close(outputFD) }
            if let stageVersion,(try? RenameVersion.read(parent).sameObject(parentVersion)) == true,(try? RenameVersion.read(parentFD,staging.lastPathComponent).sameObject(stageVersion)) == true { try? FileManager.default.removeItem(at:staging) }
        }
        if tarGzip {
            guard archive_write_set_format_pax_restricted(a) == 0, archive_write_add_filter_gzip(a) == 0 else { throw failure(a) }
        } else if sevenZip {
            guard archive_write_set_format_7zip(a) == 0 else { throw failure(a) }
        } else {
            guard archive_write_set_format_zip(a) == 0 else { throw failure(a) }
        }
        if !tarGzip {
            guard archive_write_set_format_option(a, sevenZip ? "7zip" : "zip", "compression-level", String(max(0,min(9,compressionLevel)))) == 0 else { throw failure(a) }
        }
        outputFD = openat(parentFD,staging.lastPathComponent,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard outputFD >= 0 else { throw CommanderError.message("Private Archivausgabe konnte nicht angelegt werden.") }
        var stageStat = stat();guard fstat(outputFD,&stageStat) == 0 else { throw CommanderError.message("Archivausgabe konnte nicht geprüft werden.") };stageVersion = RenameVersion(stageStat)
        guard archive_write_open_fd(a,outputFD) == 0 else { throw failure(a) }
        var names = Set<String>()
        func write(_ url: URL, name: String) throws {
            try token.check()
            let file = try RenameVersion.read(url)
            guard file.isDirectory || file.isRegularFile else { throw CommanderError.message("Spezialdatei kann nicht archiviert werden: \(url.path)") }
            guard names.insert(name).inserted else { throw CommanderError.message("Doppelter Archivname: \(name)") }
            guard let e = archive_entry_new() else { throw CommanderError.message("Zu wenig Speicher.") }
            defer { archive_entry_free(e) }
            archive_entry_set_pathname(e, name)
            archive_entry_set_size(e, file.isDirectory ? 0 : Int64(file.size))
            archive_entry_set_filetype(e, file.isDirectory ? 0o040000 : 0o100000)
            archive_entry_set_perm(e, file.mode & 0o777)
            archive_entry_set_mtime(e, Int(file.modified.timeIntervalSince1970), 0)
            guard archive_write_header(a, e) == 0 else { throw failure(a) }
            progress(name)
            if !file.isDirectory {
                let fd = open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
                guard fd >= 0 else { throw CommanderError.message("Archivquelle kann nicht sicher geöffnet werden: "+name) }
                var opened = stat()
                guard fstat(fd,&opened) == 0,RenameVersion(opened) == file else { close(fd);throw CommanderError.message("Archivquelle wurde vor dem Öffnen geändert: "+name) }
                let input = FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer { try? input.close() }
                while let data = try input.read(upToCount: 128 * 1024), !data.isEmpty {
                    try token.check()
                    let n = data.withUnsafeBytes { archive_write_data(a, $0.baseAddress, data.count) }
                    guard n == data.count else { throw failure(a) }
                }
                var finished = stat();guard fstat(fd,&finished) == 0,RenameVersion(finished) == file,try RenameVersion.read(url) == file else { throw CommanderError.message("Archivquelle wurde beim Lesen geändert: "+name) }
            }
        }
        for source in inputs {
            try write(source, name: source.lastPathComponent)
            if FileSystem.isDirectory(source) {
                try FileSystem.walk(source, token: token) { url in
                    try write(url, name: source.lastPathComponent + "/" + FileSystem.relativePath(of: url, inside: source))
                }
            }
        }
        guard archive_write_close(a) == 0 else { throw failure(a) }
        try token.check();try validateBeforePublish()
        guard try RenameVersion.read(parent).sameObject(parentVersion),let stageVersion,try RenameVersion.read(parentFD,staging.lastPathComponent).sameObject(stageVersion),renameatx_np(parentFD,staging.lastPathComponent,parentFD,destination.lastPathComponent,UInt32(RENAME_EXCL)) == 0 else { throw CommanderError.message("Archivziel oder Zielordner wurde geändert. Nichts wurde ersetzt.") }
    }
}
