import Foundation
import Darwin
import CArchive

public struct ArchiveEditAddition {
    public let source:URL,path:String
    public init(source:URL,path:String) { self.source = source;self.path = path }
}
public enum ArchiveEditAction:String { case keep = "Behalten",rename = "Umbenennen",remove = "Entfernen",add = "Hinzufügen" }
public struct ArchiveEditRow:Identifiable {
    public let originalPath:String?,path:String,member:ArchiveMember,action:ArchiveEditAction
    public var id:String { (originalPath ?? "add:")+"→"+path }
}
struct ArchiveEditMetadata:Equatable {
    let permissions:mode_t,uid:Int64,gid:Int64,uname:String,gname:String,modified:Int,nanos:Int
    let atime:[Int],birthtime:[Int],ctime:[Int]
    init(_ entry:OpaquePointer) {
        permissions = archive_entry_perm(entry);uid = archive_entry_uid(entry);gid = archive_entry_gid(entry)
        uname = archive_entry_uname(entry).map(String.init(cString:)) ?? "";gname = archive_entry_gname(entry).map(String.init(cString:)) ?? ""
        modified = Int(archive_entry_mtime(entry));nanos = Int(archive_entry_mtime_nsec(entry))
        atime = archive_entry_atime_is_set(entry) != 0 ? [Int(archive_entry_atime(entry)),Int(archive_entry_atime_nsec(entry))] : []
        birthtime = archive_entry_birthtime_is_set(entry) != 0 ? [Int(archive_entry_birthtime(entry)),Int(archive_entry_birthtime_nsec(entry))] : []
        ctime = archive_entry_ctime_is_set(entry) != 0 ? [Int(archive_entry_ctime(entry)),Int(archive_entry_ctime_nsec(entry))] : []
    }
    func matches(_ expected:Self,added:Bool) -> Bool {
        if self == expected { return true }
        // ZIP's writer emits unset secondary times as epoch-zero fields for newly created headers.
        // Retained headers always use exact comparison, including their optional timestamp presence.
        guard added,permissions == expected.permissions,uid == expected.uid,gid == expected.gid,uname == expected.uname,gname == expected.gname,modified == expected.modified,nanos == expected.nanos else { return false }
        return zip([atime,birthtime,ctime],[expected.atime,expected.birthtime,expected.ctime]).allSatisfy { actual,wanted in actual == wanted || wanted.isEmpty && actual == [0,0] }
    }
    static func validate(_ entry:OpaquePointer) throws {
        var size = 0,set:UInt = 0,clear:UInt = 0
        _ = archive_entry_mac_metadata(entry,&size);archive_entry_fflags(entry,&set,&clear)
        guard archive_entry_is_encrypted(entry) == 0,archive_entry_xattr_count(entry) == 0,archive_entry_sparse_count(entry) == 0,archive_entry_acl_count(entry,0x3F00) == 0,size == 0,set == 0,clear == 0 else { throw CommanderError.message("Verschlüsselung, ACLs, erweiterte Attribute, Dateiflags, Resource Forks oder Sparse-Daten können beim Bearbeiten nicht unverändert erhalten werden.") }
    }
}
struct ArchiveEditLocal {
    let url:URL,path:String,version:RenameVersion,root:URL
    static func key(_ url:URL) -> String { var path = url.path;while path.count > 1 && path.hasSuffix("/") { path.removeLast() };return path }
    func validateIdentity() throws {
        guard try RenameVersion.read(url) == version else { throw CommanderError.message("Hinzugefügte Quelle wurde geändert: "+url.lastPathComponent) }
    }
    func validate(parents:[String:RenameVersion]) throws {
        var parent = url.deletingLastPathComponent(),count = 0
        while true {
            let path = Self.key(parent),base = Self.key(root)
            guard count <= 100,let expected = parents[path],try RenameVersion.read(parent).sameObject(expected) else { throw CommanderError.message("Ein Quellordner wurde ersetzt: "+parent.lastPathComponent) }
            if path == base { break };guard base == "/" || path.hasPrefix(base+"/") else { throw CommanderError.message("Quellpfad gehört nicht mehr zur Vorschau.") };parent = parent.deletingLastPathComponent();count += 1
        }
        try validateIdentity()
    }
}
final class ArchiveEditFile {
    let url:URL,fd:Int32,version:RenameVersion
    init(_ url:URL,expected:RenameVersion? = nil) throws {
        guard ArchiveService.isLocal(url) else { throw CommanderError.message("Ein lokales Archiv ohne fremden Host wird benötigt.") }
        self.url = url
        let version = try RenameVersion.read(url)
        guard version.isRegularFile,version.size >= 0,expected == nil || expected == version else { throw CommanderError.message("Die Archivdatei wurde geändert oder ist keine reguläre Datei.") }
        let opened = open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard opened >= 0 else { throw CommanderError.message("Archivdatei kann nicht sicher geöffnet werden.") }
        var current = stat()
        guard fstat(opened,&current) == 0,RenameVersion(current) == version else { close(opened);throw CommanderError.message("Archivdatei wurde beim Öffnen verändert.") }
        fd = opened;self.version = version
    }
    deinit { close(fd) }
    func validate() throws {
        var current = stat();guard fstat(fd,&current) == 0,RenameVersion(current) == version,try RenameVersion.read(url) == version else { throw CommanderError.message("Das Archiv wurde seit der Vorschau verändert. Bitte neu prüfen.") }
    }
    func reader() throws -> OpaquePointer { try Self.reader(fd) }
    static func reader(_ fd:Int32) throws -> OpaquePointer {
        guard lseek(fd,0,SEEK_SET) == 0,let reader = archive_read_new() else { throw CommanderError.message("Archivdaten können nicht gelesen werden.") }
        archive_read_support_filter_all(reader);archive_read_support_format_all(reader)
        guard archive_read_open_fd(reader,fd,128*1024) == 0 else { let error = ArchiveService.failure(reader);archive_read_free(reader);throw error };return reader
    }
}

/// A frozen, explicit edit. Every retained member is rewritten and checked before the original is moved.
/// TAR-GZip preserves checked TAR member data/metadata; outer GZip concatenations and ancillary
/// envelope details are not guaranteed. Interfaces must disclose this boundary before submission.
public struct ArchiveEditPlan {
    public static let maximumEntries = 100_000
    public let source:URL,format:ArchiveFormat,rows:[ArchiveEditRow],totalBytes:Int64,maximumBytes:Int64,compressionLevel:Int
    public var changedCount:Int { rows.filter { $0.action != .keep }.count }
    public var hasChanges:Bool { changedCount > 0 }
    public var outputCount:Int { rows.filter { $0.action != .remove }.count }
    public var containerNote:String { format == .tarGzip ? "Die äußere GZip-Hülle wird neu erstellt. Zusätzliche Hüllenfelder und Verkettungen werden nicht garantiert bewahrt; geprüft werden Dateiinhalte und unterstützte TAR-Metadaten." : "Dateiinhalte und unterstützte Eintragsmetadaten werden vollständig geprüft." }
    let sourceVersion:RenameVersion,parentVersion:RenameVersion,metadata:[String:ArchiveEditMetadata],locals:[ArchiveEditLocal],localParents:[String:RenameVersion],originalPaths:Set<String>
    public init(source requested:URL,renames:[String:String] = [:],removals:Set<String> = [],additions:[ArchiveEditAddition] = [],maximumBytes:Int64 = 100*1024*1024*1024,compressionLevel:Int = 6,token:CancellationToken = .init()) throws {
        guard ArchiveService.isLocal(requested),maximumBytes >= 0,(0...9).contains(compressionLevel) else { throw CommanderError.message("Ungültige Archivquelle oder Archivgrenze.") }
        let source = FileSystem.canonical(requested.deletingLastPathComponent()).appendingPathComponent(requested.lastPathComponent)
        let parent = try RenameVersion.read(source.deletingLastPathComponent()),file = try ArchiveEditFile(source)
        guard parent.isDirectory else { throw CommanderError.message("Archivordner ist nicht verfügbar.") }
        switch source.pathExtension.lowercased() {
        case "zip":try ArchiveEditZip.validate(file.fd,size:Int64(file.version.size),token:token)
        case "7z":try ArchiveEditHeaders.sevenZip(file,maximumBytes:maximumBytes,token:token)
        case "gz","tgz":try ArchiveEditHeaders.tarGzip(file,maximumBytes:maximumBytes,token:token)
        default:throw CommanderError.message("Bearbeitet werden ZIP-, 7z- und TAR-GZip-Archive mit passender Endung.")
        }
        let inventory = try Self.inventory(file,token:token)
        let format = inventory.format
        let members = inventory.members
        var nodes = Dictionary(uniqueKeysWithValues:members.map { ($0.path,$0) })
        for member in members {
            var parent = (member.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if let existing = nodes[parent] { guard existing.isDirectory else { throw CommanderError.message("Datei als Archiv-Elternordner: "+parent) } }
                else { nodes[parent] = ArchiveMember(path:parent,size:0,isDirectory:true,permissions:0o755) }
                guard nodes.count <= Self.maximumEntries else { throw CommanderError.message("Zu viele Archivordner.") };parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let mutationPaths = Array(renames.keys)+Array(removals)
        guard mutationPaths.count <= Self.maximumEntries,additions.count <= Self.maximumEntries else { throw CommanderError.message("Zu viele Archivänderungen.") }
        for path in mutationPaths { guard nodes[path] != nil,try Self.checkedPath(path) == path else { throw CommanderError.message("Archiveintrag gehört nicht zur Vorschau: "+path) } }
        for (old,new) in renames {
            _ = try Self.checkedPath(new)
            guard old != new,!Self.contains(old,new) else { throw CommanderError.message("Ein Ordner kann nicht in sich selbst verschoben werden.") }
        }
        var rows:[ArchiveEditRow] = [],locals:[ArchiveEditLocal] = [],localParents:[String:RenameVersion] = [:]
        for member in members {
            try token.check()
            let removed = removals.contains { Self.contains($0,member.path) }
            let rename = renames.filter { Self.contains($0.key,member.path) }.max { $0.key.count < $1.key.count }
            let path = rename.map { $0.value+String(member.path.dropFirst($0.key.count)) } ?? member.path
            rows.append(ArchiveEditRow(originalPath:member.path,path:path,member:member,action:removed ? .remove : rename == nil ? .keep : .rename))
        }
        var availableDirectories = Set(rows.filter { $0.action != .remove && $0.member.isDirectory }.map(\.path))
        for addition in additions {
            let path = try Self.checkedPath(addition.path)
            guard ArchiveService.isLocal(addition.source) else { throw CommanderError.message("Nur lokale Dateien und Ordner können hinzugefügt werden.") }
            let parent = FileSystem.canonical(addition.source.deletingLastPathComponent()),url = parent.appendingPathComponent(addition.source.lastPathComponent)
            guard url != source else { throw CommanderError.message("Das Archiv kann nicht sich selbst hinzugefügt werden.") }
            localParents[ArchiveEditLocal.key(parent)] = try RenameVersion.read(parent)
            func append(_ url:URL,_ path:String) throws {
                try token.check();_ = try Self.checkedPath(path);let version = try RenameVersion.read(url)
                guard version.isRegularFile || version.isDirectory else { throw CommanderError.message("Verknüpfungen und Spezialdateien werden nicht hinzugefügt: "+path) }
                guard url != source else { throw CommanderError.message("Ein hinzugefügter Ordner enthält die bearbeitete Archivdatei.") }
                guard !version.sameObject(file.version) else { throw CommanderError.message("Das Archiv kann auch über einen zweiten Namen nicht sich selbst hinzugefügt werden.") }
                guard locals.count < Self.maximumEntries else { throw CommanderError.message("Höchstens 100.000 hinzugefügte Quellen können geprüft werden.") }
                let member = ArchiveMember(path:path,size:version.isDirectory ? 0 : Int64(version.size),isDirectory:version.isDirectory,modified:Date(timeIntervalSince1970:Double(version.modifiedSeconds)),permissions:Int(version.mode & 0o777))
                if version.isDirectory { localParents[ArchiveEditLocal.key(url)] = version }
                locals.append(ArchiveEditLocal(url:url,path:path,version:version,root:parent))
                // Existing real directories are reused; their metadata wins and all new children still collide normally.
                if version.isDirectory,!availableDirectories.insert(path).inserted { return }
                rows.append(ArchiveEditRow(originalPath:nil,path:path,member:member,action:.add))
                guard rows.count <= Self.maximumEntries else { throw CommanderError.message("Höchstens 100.000 Einträge können bearbeitet werden.") }
            }
            try append(url,path)
            if try RenameVersion.read(url).isDirectory {
                try FileSystem.walk(url,token:token) { child in
                    let relative = try FileSystem.relativePath(of:child,inside:url)
                    let normalized = relative.split(separator:"/").reduce(url) { $0.appendingPathComponent(String($1)) }
                    try append(normalized,path+"/"+relative)
                }
            }
        }
        var names:[String:ArchiveEditRow] = [:],total:Int64 = 0,pathBytes = 0
        for row in rows where row.action != .remove {
            _ = try Self.checkedPath(row.path)
            pathBytes += row.path.utf8.count;guard pathBytes <= 32*1024*1024 else { throw CommanderError.message("Archivpfade überschreiten zusammen 32 MiB.") }
            let key = Self.folded(row.path)
            guard names[key] == nil else { throw CommanderError.message("Zwei Einträge erhalten denselben Archivpfad: "+row.path) };names[key] = row
            let sum = total.addingReportingOverflow(row.member.isDirectory ? 0 : row.member.size)
            guard row.member.size >= 0,!sum.overflow,sum.partialValue <= maximumBytes else { throw CommanderError.message("Die Archivbearbeitung überschreitet das Inhaltslimit.") };total = sum.partialValue
        }
        for row in names.values {
            var parent = (row.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard names[Self.folded(parent)]?.member.isDirectory != false else { throw CommanderError.message("Eine Datei blockiert einen Archiv-Unterordner: "+parent) };parent = (parent as NSString).deletingLastPathComponent
            }
        }
        var workload:Int64 = 0
        for size in members.filter({!$0.isDirectory}).map(\.size)+locals.filter({$0.version.isRegularFile}).map({Int64($0.version.size)}) {
            let sum = workload.addingReportingOverflow(size);guard size >= 0,!sum.overflow,sum.partialValue <= maximumBytes else { throw CommanderError.message("Original und hinzugefügte Daten überschreiten zusammen das Inhaltslimit.") };workload = sum.partialValue
        }
        try file.validate()
        self.source = source;sourceVersion = file.version;parentVersion = parent;self.format = format;self.rows = rows;totalBytes = total;self.maximumBytes = maximumBytes;self.compressionLevel = compressionLevel;self.metadata = inventory.metadata;self.locals = locals;self.localParents = localParents;originalPaths = Set(members.map(\.path))
        try validate(token:token)
    }
    static func folded(_ path:String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    static func contains(_ root:String,_ child:String) -> Bool { child == root || child.hasPrefix(root+"/") }
    static func checkedPath(_ path:String) throws -> String {
        guard !path.isEmpty,path.utf8.count <= 16_384,path.split(separator:"/").count <= 100,try ArchiveService.safePath(path) == path else { throw CommanderError.message("Bitte einen eindeutigen relativen Archivpfad ohne .. angeben.") };return path
    }
    public func validate(token:CancellationToken = .init()) throws {
        try token.check()
        guard try RenameVersion.read(source.deletingLastPathComponent()).sameObject(parentVersion),try RenameVersion.read(source) == sourceVersion else { throw CommanderError.message("Archiv oder Archivordner seit der Vorschau geändert. Bitte neu prüfen.") }
        for (path,expected) in localParents { try token.check();let url = URL(fileURLWithPath:path);guard try RenameVersion.read(url).sameObject(expected) else { throw CommanderError.message("Ein hinzugefügter Quellordner wurde ersetzt: "+url.lastPathComponent) } }
        for local in locals { try token.check();try local.validateIdentity() }
    }
    static func inventory(_ file:ArchiveEditFile,token:CancellationToken) throws -> (format:ArchiveFormat,members:[ArchiveMember],metadata:[String:ArchiveEditMetadata]) {
        let reader = try file.reader();defer { archive_read_free(reader) }
        var header:OpaquePointer?,members:[ArchiveMember] = [],metadata:[String:ArchiveEditMetadata] = [:],names = Set<String>(),format:ArchiveFormat?,pathBytes = 0
        while true {
            try token.check();let code = archive_read_next_header(reader,&header)
            if format == nil { format = try detectedFormat(reader,source:file.url) }
            if code == 1 { break };guard code == 0,let header else { throw ArchiveService.failure(reader) }
            guard let raw = archive_entry_pathname(header),strnlen(raw,16_385) <= 16_384 else { throw CommanderError.message("Ein Archivpfad überschreitet 16 KiB.") }
            for name in [archive_entry_uname(header),archive_entry_gname(header)] { if let name { guard strnlen(name,1025) <= 1024 else { throw CommanderError.message("Archiv-Metadatenname ist zu lang.") } } }
            try ArchiveEditMetadata.validate(header)
            let member = try ArchiveService.member(header);if member.path.isEmpty { throw CommanderError.message("Leere Archiveinträge können nicht bearbeitet werden.") }
            _ = try checkedPath(member.path)
            pathBytes += member.path.utf8.count
            guard !member.isLink,member.isRegularFile || member.isDirectory,member.size >= 0,member.isDirectory ? member.size == 0 : true,pathBytes <= 32*1024*1024,members.count < maximumEntries,names.insert(folded(member.path)).inserted else { throw CommanderError.message("Doppelte/überlange Pfade, Verknüpfungen oder Spezialdateien können nicht bearbeitet werden: "+member.path) }
            metadata[member.path] = ArchiveEditMetadata(header);members.append(member)
        }
        guard archive_read_has_encrypted_entries(reader) != 1 else { throw CommanderError.message("Verschlüsselte Archive bleiben unverändert und können hier nicht bearbeitet werden.") }
        guard let format else { throw CommanderError.message("Nicht unterstütztes Archivformat.") }
        return (format,members,metadata)
    }
    static func detectedFormat(_ reader:OpaquePointer,source:URL) throws -> ArchiveFormat {
        let kind = archive_format(reader) & 0xFF0000
        let filters = (0..<archive_filter_count(reader)).map { archive_filter_code(reader,$0) }.filter { $0 != 0 }
        if kind == 0x50000,filters.isEmpty,source.pathExtension.lowercased() == "zip" { return .zip }
        if kind == 0xE0000,filters.isEmpty,source.pathExtension.lowercased() == "7z" { return .sevenZip }
        if kind == 0x30000,filters == [1],source.lastPathComponent.lowercased().hasSuffix(".tar.gz") || source.pathExtension.lowercased() == "tgz" { return .tarGzip }
        throw CommanderError.message("Bearbeitet werden unverschlüsselte ZIP-, 7z- und TAR-GZip-Archive mit passender Endung. Andere Formate bleiben unverändert.")
    }
}
