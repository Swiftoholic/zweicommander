import Foundation
import CArchive

public struct ArchiveMember {
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
}
public enum ArchiveService {
    public static let extensions: Set<String> = ["zip", "jar", "war", "ear", "7z", "rar", "tar", "tgz", "gz", "bz2", "xz", "tbz", "txz", "cpio", "iso"]
    public static func isArchive(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    private static func failure(_ archive: OpaquePointer) -> Error { CommanderError.message(archive_error_string(archive).map { String(cString: $0) } ?? "Archivfehler") }
    private static func reader(_ url: URL, password: String?) throws -> OpaquePointer {
        guard let a = archive_read_new() else { throw CommanderError.message("Archiv konnte nicht geöffnet werden.") }
        archive_read_support_filter_all(a); archive_read_support_format_all(a)
        if let password, !password.isEmpty { archive_read_add_passphrase(a, password) }
        if archive_read_open_filename(a, url.path, 1024 * 128) != 0 { let e = failure(a); archive_read_free(a); throw e }
        return a
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
            if !path.isEmpty { result.append(ArchiveMember(path: path, size: archive_entry_size(e), isDirectory: archive_entry_filetype(e) == 0o040000)) }
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
    // Extraction is only into a newly created staging directory. Links and special files are rejected.
    public static func extract(_ url: URL, to destination: URL, password: String? = nil, maxBytes: Int64 = 100 * 1024 * 1024 * 1024, token: CancellationToken = .init(), progress: (String) -> Void = { _ in }) throws {
        guard !FileSystem.exists(destination) else { throw CommanderError.message("Entpacken benötigt einen neuen Zielordner.") }
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".zweicommander-extract-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? fm.removeItem(at: staging) } }
        let a = try reader(url, password: password); defer { archive_read_free(a) }
        var entry: OpaquePointer?, total: Int64 = 0, count = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        var directoryDates: [(URL, Date)] = []
        while true {
            try token.check()
            let code = archive_read_next_header(a, &entry)
            if code == 1 { break }
            guard code == 0, let e = entry, let p = archive_entry_pathname(e) else { throw failure(a) }
            let name = try safePath(String(cString: p))
            if name.isEmpty { continue }
            count += 1
            guard count <= 1_000_000 else { throw CommanderError.message("Zu viele Archiveinträge.") }
            guard archive_entry_symlink(e) == nil, archive_entry_hardlink(e) == nil else { throw CommanderError.message("Archiv enthält Verknüpfungen. Automatisches Entpacken wurde zum Schutz anderer Dateien abgebrochen: \(name)") }
            let type = archive_entry_filetype(e)
            guard type == 0o100000 || type == 0o040000 else { throw CommanderError.message("Nicht unterstützter Archiveintrag: \(name)") }
            let target = staging.appendingPathComponent(name)
            guard FileSystem.isInside(target, staging) else { throw CommanderError.message("Archivpfad verlässt das Ziel.") }
            progress(name)
            let date = Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(e)))
            if type == 0o040000 {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                directoryDates.append((target, date))
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let file = try FileOperations.newFile(in: target.deletingLastPathComponent(), name: target.lastPathComponent)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                while true {
                    try token.check()
                    let n = archive_read_data(a, &buffer, buffer.count)
                    if n == 0 { break }
                    guard n > 0 else { throw failure(a) }
                    total += Int64(n)
                    guard total <= maxBytes else { throw CommanderError.message("Entpacklimit von \(maxBytes / 1024 / 1024 / 1024) GB erreicht.") }
                    try handle.write(contentsOf: Data(buffer.prefix(n)))
                }
                try handle.synchronize()
                let safePermissions = Int(archive_entry_perm(e)) & 0o777
                try fm.setAttributes([.modificationDate: date, .posixPermissions: safePermissions == 0 ? 0o644 : safePermissions], ofItemAtPath: target.path)
            }
        }
        for (url, date) in directoryDates.reversed() { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        try fm.moveItem(at: staging, to: destination)
        complete = true
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
    public static func pack(_ urls: [URL], to destination: URL, tarGzip: Bool = false, sevenZip: Bool = false, compressionLevel: Int = 6, token: CancellationToken = .init(), progress: (String) -> Void = { _ in }) throws {
        guard !FileSystem.exists(destination) else { throw CommanderError.message("Archivname ist bereits belegt.") }
        let inputs = FileSystem.topLevelSelection(urls)
        guard !inputs.isEmpty else { throw CommanderError.message("Keine Dateien ausgewählt.") }
        for source in inputs where FileSystem.isDirectory(source) {
            guard !FileSystem.isInside(destination, source) else { throw CommanderError.message("Das Archivziel liegt in einem Quellordner.") }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".zweicommander-archive-" + UUID().uuidString)
        guard let a = archive_write_new() else { throw CommanderError.message("Archiv kann nicht erstellt werden.") }
        defer { archive_write_free(a); if FileSystem.exists(staging) { try? FileManager.default.removeItem(at: staging) } }
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
        guard archive_write_open_filename(a, staging.path) == 0 else { throw failure(a) }
        var names = Set<String>()
        func write(_ url: URL, name: String) throws {
            try token.check()
            let file = try FileEntry(url: url)
            guard !file.isSymbolicLink else { throw CommanderError.message("Verknüpfungen werden nicht archiviert: \(url.path)") }
            guard file.isDirectory || file.isRegularFile else { throw CommanderError.message("Spezialdatei kann nicht archiviert werden: \(url.path)") }
            guard names.insert(name).inserted else { throw CommanderError.message("Doppelter Archivname: \(name)") }
            guard let e = archive_entry_new() else { throw CommanderError.message("Zu wenig Speicher.") }
            defer { archive_entry_free(e) }
            archive_entry_set_pathname(e, name)
            archive_entry_set_size(e, file.isDirectory ? 0 : file.size)
            archive_entry_set_filetype(e, file.isDirectory ? 0o040000 : 0o100000)
            archive_entry_set_perm(e, mode_t(file.permissions & 0o777))
            archive_entry_set_mtime(e, Int(file.modified.timeIntervalSince1970), 0)
            guard archive_write_header(a, e) == 0 else { throw failure(a) }
            progress(name)
            if !file.isDirectory {
                let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
                while let data = try input.read(upToCount: 128 * 1024), !data.isEmpty {
                    try token.check()
                    let n = data.withUnsafeBytes { archive_write_data(a, $0.baseAddress, data.count) }
                    guard n == data.count else { throw failure(a) }
                }
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
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}
