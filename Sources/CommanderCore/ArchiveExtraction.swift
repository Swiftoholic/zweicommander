import Foundation
import Darwin
import CArchive

extension ArchiveService {
    public static func extract(_ plan:ArchiveExtractionPlan,password:String? = nil,token:CancellationToken = .init(),progress:(String)->Void = { _ in }) throws {
        try token.check();try plan.validate()
        let destination = plan.destination,parent = destination.deletingLastPathComponent(),stage = ".zweicommander-extract-"+UUID().uuidString
        let parentFD = open(parent.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard parentFD >= 0 else { throw CommanderError.message("Der Zielordner kann nicht geöffnet werden.") };defer { close(parentFD) }
        var parentStat = stat();guard fstat(parentFD,&parentStat) == 0,RenameVersion(parentStat).sameObject(plan.parentVersion) else { throw CommanderError.message("Der Zielordner wurde ersetzt.") }
        guard mkdirat(parentFD,stage,0o700) == 0 else { throw CommanderError.message("Temporärer Entpackordner konnte nicht angelegt werden.") }
        let stageFD = openat(parentFD,stage,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard stageFD >= 0 else { throw CommanderError.message("Temporärer Entpackordner kann nicht geöffnet werden.") }
        var published = false
        defer {
            close(stageFD)
            if !published,(try? RenameVersion.read(parent).sameObject(plan.parentVersion)) == true { try? FileManager.default.removeItem(at:parent.appendingPathComponent(stage)) }
        }
        try writeExtraction(plan.selection,catalog:plan.catalog,to:stageFD,password:password,token:token,progress:{ name,_ in progress(name) })
        try token.check();try plan.validate()
        guard renameatx_np(parentFD,stage,parentFD,destination.lastPathComponent,UInt32(RENAME_EXCL)) == 0 else { throw CommanderError.message("Das Entpackziel wurde inzwischen belegt. Nichts wurde ersetzt.") }
        published = true
    }
    // The caller owns a private directory descriptor on the destination volume.
    static func writeExtraction(_ selection:ArchiveSelection,catalog:ArchiveCatalog,to stageFD:Int32,password:String?,token:CancellationToken,directoryMetadata:Bool = true,progress:(String,Int64)->Void) throws {
        try token.check();try catalog.validateSource()
        func folder(_ path:String) throws -> Int32 {
            var fd = dup(stageFD);guard fd >= 0 else { throw CommanderError.message("Entpackordner nicht verfügbar.") }
            do {
                for component in path.split(separator:"/").map(String.init) {
                    try token.check()
                    if mkdirat(fd,component,0o700) != 0 && errno != EEXIST { throw CommanderError.message("Archivordner konnte nicht angelegt werden: "+path) }
                    let next = openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                    guard next >= 0 else { throw CommanderError.message("Archivordner ist keine sichere direkte Verzeichnisstruktur: "+path) };close(fd);fd = next
                }
                return fd
            } catch { close(fd);throw error }
        }
        let reader = try reader(catalog.source,password:password);defer { archive_read_free(reader) }
        let expected = Dictionary(uniqueKeysWithValues:catalog.members.map { ($0.path,$0) });var seen = Set<String>(),written = Set<String>(),header:OpaquePointer?,total:Int64 = 0,count = 0
        var buffer = [UInt8](repeating:0,count:128*1024)
        while true {
            try token.check();let code = archive_read_next_header(reader,&header)
            if code == 1 { break };guard code == 0,let header else { throw failure(reader) }
            let value = try member(header);if value.path.isEmpty { continue };count += 1
            guard count <= ArchiveCatalog.maximumEntries,seen.insert(value.path).inserted,expected[value.path] == value else { throw CommanderError.message("Die Archiveinträge stimmen nicht mehr mit der Vorschau überein.") }
            guard selection.selected.contains(value.path) else { continue }
            let name = selection.basePath.isEmpty ? value.path : String(value.path.dropFirst(selection.basePath.count+1))
            progress(name,total)
            if value.isDirectory { let fd = try folder(name);close(fd) }
            else {
                let directory = try folder((name as NSString).deletingLastPathComponent);defer { close(directory) }
                let fd = openat(directory,(name as NSString).lastPathComponent,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
                guard fd >= 0 else { throw CommanderError.message("Doppelter oder nicht schreibbarer Archivname: "+name) }
                let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false);defer { try? handle.close() }
                var size:Int64 = 0
                while true {
                    try token.check();let amount = archive_read_data(reader,&buffer,buffer.count)
                    if amount == 0 { break };guard amount > 0 else { throw failure(reader) }
                    let next = total.addingReportingOverflow(Int64(amount)),fileNext = size.addingReportingOverflow(Int64(amount))
                    guard !next.overflow,!fileNext.overflow,next.partialValue <= selection.maximumBytes,fileNext.partialValue <= value.size else { throw CommanderError.message("Dateigröße oder Entpacklimit wurde überschritten: "+name) }
                    total = next.partialValue;size = fileNext.partialValue;try handle.write(contentsOf:Data(buffer.prefix(amount)));progress(name,total)
                }
                guard size == value.size else { throw CommanderError.message("Unvollständiger Archivinhalt: "+name) }
                try handle.synchronize()
                guard fchmod(fd,mode_t(value.permissions == 0 ? 0o644 : value.permissions)) == 0 else { throw CommanderError.message("Dateirechte konnten nicht gesetzt werden.") }
                if value.modified != .distantPast { var times = [timeval(tv_sec:Int(value.modified.timeIntervalSince1970),tv_usec:0),timeval(tv_sec:Int(value.modified.timeIntervalSince1970),tv_usec:0)];guard futimes(fd,&times) == 0 else { throw CommanderError.message("Dateidatum konnte nicht gesetzt werden.") } }
            }
            written.insert(value.path)
        }
        guard seen == Set(expected.keys),written == selection.selected,total == selection.totalBytes else { throw CommanderError.message("Die Archivauswahl ist unvollständig oder wurde geändert.") }
        if directoryMetadata { for value in selection.rows.reversed() where value.isDirectory {
            let fd = try folder(value.path);defer { close(fd) }
            if value.modified != .distantPast { var times = [timeval(tv_sec:Int(value.modified.timeIntervalSince1970),tv_usec:0),timeval(tv_sec:Int(value.modified.timeIntervalSince1970),tv_usec:0)];guard futimes(fd,&times) == 0 else { throw CommanderError.message("Ordnerdatum konnte nicht gesetzt werden.") } }
            guard fchmod(fd,mode_t(value.permissions == 0 ? 0o755 : value.permissions)) == 0 else { throw CommanderError.message("Ordnerrechte konnten nicht gesetzt werden.") }
        }
        }
        try catalog.validateSource()
    }
}
