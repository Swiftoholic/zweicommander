import Foundation
import CryptoKit
import Darwin
import CArchive

public enum ArchiveEditEngine {
    public static func execute(_ plan:ArchiveEditPlan,token:CancellationToken = .init(),progress:(String)->Void = { _ in }) -> OperationReport {
        var report = OperationReport(),stageFD:Int32 = -1,parentFD:Int32 = -1,stageVersion:RenameVersion?
        let parent = plan.source.deletingLastPathComponent(),stage = ".zweicommander-archive-edit-"+UUID().uuidString,backup = ".zweicommander-backup-"+UUID().uuidString,name = plan.source.lastPathComponent
        defer {
            if stageFD >= 0 { close(stageFD) }
            if parentFD >= 0 {
                if let stageVersion,(try? RenameVersion.read(parentFD,stage).sameObject(stageVersion)) == true { _ = unlinkat(parentFD,stage,0) }
                close(parentFD)
            }
        }
        do {
            guard plan.hasChanges else { throw CommanderError.message("Noch keine Archivänderungen vorgemerkt.") }
            try plan.validate(token:token)
            parentFD = open(parent.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard parentFD >= 0 else { throw CommanderError.message("Archivordner kann nicht geöffnet werden.") }
            var parentStat = stat();guard fstat(parentFD,&parentStat) == 0,RenameVersion(parentStat).sameObject(plan.parentVersion) else { throw CommanderError.message("Archivordner wurde ersetzt.") }
            let original = try ArchiveEditFile(plan.source,expected:plan.sourceVersion)
            switch plan.format {
            case .zip:try ArchiveEditZip.validate(original.fd,size:Int64(original.version.size),token:token)
            case .sevenZip:try ArchiveEditHeaders.sevenZip(original,maximumBytes:plan.maximumBytes,token:token)
            case .tarGzip:try ArchiveEditHeaders.tarGzip(original,maximumBytes:plan.maximumBytes,token:token)
            };try original.validate()
            stageFD = openat(parentFD,stage,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard stageFD >= 0 else { throw CommanderError.message("Die neue Archivdatei kann nicht vorbereitet werden.") }
            var value = stat();guard fstat(stageFD,&value) == 0 else { throw CommanderError.message("Die neue Archivdatei kann nicht geprüft werden.") };stageVersion = RenameVersion(value)
            progress("Erstelle neue Archivdatei · Original bleibt unverändert")
            let expected = try rewrite(plan,original:original,to:stageFD,token:token,progress:progress)
            if plan.format == .tarGzip {
                let header = try ArchiveEditHeaders.read(original.fd,offset:0,count:10)
                for offset in [3,4,5,6,7,9] { var byte = header[offset];guard pwrite(stageFD,&byte,1,off_t(offset)) == 1 else { throw CommanderError.message("GZip-Kopfdaten können nicht erhalten werden.") } }
            }
            try token.check();try original.validate();try plan.validate(token:token)
            progress("Prüfe vollständige Inhalte und Metadaten")
            guard fstat(stageFD,&value) == 0 else { throw CommanderError.message("Neue Archivdatei nicht verfügbar.") }
            let staged = try ArchiveEditFile(parent.appendingPathComponent(stage),expected:RenameVersion(value))
            switch plan.format {
            case .zip:try ArchiveEditZip.validate(staged.fd,size:Int64(staged.version.size),token:token)
            case .sevenZip:try ArchiveEditHeaders.sevenZip(staged,maximumBytes:plan.maximumBytes,token:token)
            case .tarGzip:try ArchiveEditHeaders.tarGzip(staged,maximumBytes:plan.maximumBytes,token:token)
            }
            try verify(plan,fd:stageFD,expected:expected,token:token,progress:progress)
            try token.check();try original.validate();try plan.validate(token:token)
            // A decoder may have buffered old bytes. Bind the entire verification to the
            // frozen stage version before our own metadata writes create a new version.
            try staged.validate()
            try NativeCopy.metadataDescriptors(original.fd,to:stageFD)
            guard fsync(stageFD) == 0,fstat(stageFD,&value) == 0 else { throw CommanderError.message("Die geprüfte Archivdatei konnte nicht gespeichert werden.") }
            let sizeLimit = plan.maximumBytes.addingReportingOverflow(128*1024*1024),limit = sizeLimit.overflow ? Int64.max : sizeLimit.partialValue
            let sealed = try seal(stageFD,limit:limit,token:token),outputVersion = sealed.version
            progress("Übernehme geprüftes Archiv mit Originalsicherung")
            try token.check();try original.validate();try plan.validate(token:token)
            guard fstat(stageFD,&value) == 0,RenameVersion(value) == outputVersion,try RenameVersion.read(parentFD,stage) == outputVersion else { throw CommanderError.message("Die geprüfte neue Archivdatei wurde verändert.") }
            let finalSeal = try seal(stageFD,limit:limit,token:token)
            guard finalSeal.version == outputVersion,finalSeal.digest == sealed.digest else { throw CommanderError.message("Die geprüfte neue Archivdatei wurde verändert.") }
            try token.check();try original.validate();try plan.validate(token:token)
            guard try RenameVersion.read(parent).sameObject(plan.parentVersion),try RenameVersion.read(parentFD,name) == plan.sourceVersion,try RenameVersion.read(parentFD,stage) == outputVersion,fstat(stageFD,&value) == 0,RenameVersion(value) == outputVersion else { throw CommanderError.message("Archiv oder Ausgabe wurde vor der Übernahme verändert.") }
            guard renameatx_np(parentFD,name,parentFD,backup,UInt32(RENAME_EXCL)) == 0 else { throw CommanderError.message("Die unveränderte Originaldatei konnte nicht gesichert werden.") }
            guard (try? RenameVersion.read(parentFD,backup)).map(plan.sourceVersion.sameAfterRename) == true else {
                _ = renameatx_np(parentFD,backup,parentFD,name,UInt32(RENAME_EXCL))
                throw CommanderError.message("Originaldatei wurde während der Sicherung verändert. Erhaltene Datei prüfen: "+parent.appendingPathComponent(backup).path)
            }
            // Complete this short publication step without another cancellation point.
            guard renameatx_np(parentFD,stage,parentFD,name,UInt32(RENAME_EXCL)) == 0 else {
                let restored = renameatx_np(parentFD,backup,parentFD,name,UInt32(RENAME_EXCL)) == 0
                if !restored { report.undo = [UndoStep(current:plan.source,original:nil,backup:parent.appendingPathComponent(backup),stamp:FileStamp(version:outputVersion))] }
                throw CommanderError.message(restored ? "Archivübernahme fehlgeschlagen; das Original wurde wiederhergestellt." : "Der Archivname wurde inzwischen belegt. Das Original bleibt gesichert unter "+parent.appendingPathComponent(backup).path)
            }
            // Register recovery before any post-publication callback/validation. The frozen stamp
            // cannot authorize undo over a subsequently replaced or modified foreign file.
            report.completed = [plan.source];report.undo = [UndoStep(current:plan.source,original:nil,backup:parent.appendingPathComponent(backup),stamp:FileStamp(version:outputVersion))]
            progress("Prüfe übernommenes Archiv")
            guard let actual = try? RenameVersion.read(parentFD,name),outputVersion.sameAfterRename(actual) else { throw CommanderError.message("Das neue Archiv wurde unmittelbar nach der Übernahme verändert. Original gesichert unter "+parent.appendingPathComponent(backup).path) }
            let stamp = try FileStamp(plan.source)
            guard stamp.inode == UInt64(actual.inode),stamp.device == UInt64(truncatingIfNeeded:actual.device) else { throw CommanderError.message("Das neue Archiv wurde vor dem Erstellen der Rücknahme ersetzt. Das Original bleibt gesichert unter "+parent.appendingPathComponent(backup).path) }
            report.completed = [plan.source];report.undo = [UndoStep(current:plan.source,original:nil,backup:parent.appendingPathComponent(backup),stamp:stamp)]
            progress("Archivänderungen übernommen · Original gesichert")
        } catch { report.errors.append(error.localizedDescription) }
        return report
    }
    private static func seal(_ fd:Int32,limit:Int64,token:CancellationToken) throws -> (version:RenameVersion,digest:Data) {
        var info = stat();guard fstat(fd,&info) == 0,info.st_size >= 0,info.st_size <= limit else { throw CommanderError.message("Archivdatei überschreitet die geprüfte Ausgabegrenze.") }
        let version = RenameVersion(info);var hash = SHA256(),buffer = [UInt8](repeating:0,count:128*1024),offset:Int64 = 0
        while offset < Int64(version.size) {
            try token.check();let length = min(buffer.count,Int(Int64(version.size)-offset))
            let count = buffer.withUnsafeMutableBytes { pread(fd,$0.baseAddress,length,off_t(offset)) }
            guard count > 0 else { throw CommanderError.message("Die neue Archivdatei ist nicht vollständig lesbar.") };hash.update(data:Data(buffer.prefix(count)));offset += Int64(count)
        }
        guard fstat(fd,&info) == 0,RenameVersion(info) == version else { throw CommanderError.message("Die neue Archivdatei wurde während der Dateiprüfung verändert.") }
        return (version,Data(hash.finalize()))
    }
    private struct Expected {
        let member:ArchiveMember,metadata:ArchiveEditMetadata,digest:Data,added:Bool
    }
    private static func configure(_ output:OpaquePointer,plan:ArchiveEditPlan) throws {
        let code:Int32
        switch plan.format {
        case .zip:code = archive_write_set_format_zip(output)
        case .sevenZip:code = archive_write_set_format_7zip(output)
        case .tarGzip:code = archive_write_set_format_pax_restricted(output)
        }
        guard code == 0 else { throw ArchiveService.failure(output) }
        if plan.format == .tarGzip { guard archive_write_add_filter_gzip(output) == 0 else { throw ArchiveService.failure(output) } }
        else { guard archive_write_set_format_option(output,plan.format == .zip ? "zip" : "7zip","compression-level",String(plan.compressionLevel)) == 0 else { throw ArchiveService.failure(output) } }
    }
    private static func rewrite(_ plan:ArchiveEditPlan,original:ArchiveEditFile,to fd:Int32,token:CancellationToken,progress:(String)->Void) throws -> [String:Expected] {
        let reader = try original.reader();defer { archive_read_free(reader) }
        guard let writer = archive_write_new() else { throw CommanderError.message("Archivwriter nicht verfügbar.") };defer { archive_write_free(writer) }
        try configure(writer,plan:plan)
        guard archive_write_open_fd(writer,fd) == 0 else { throw ArchiveService.failure(writer) }
        let byOriginal = Dictionary(uniqueKeysWithValues:plan.rows.compactMap { row in row.originalPath.map { ($0,row) } })
        var seen = Set<String>(),header:OpaquePointer?,result:[String:Expected] = [:],totalRead:Int64 = 0
        var buffer = [UInt8](repeating:0,count:128*1024),lastProgress = ProcessInfo.processInfo.systemUptime
        func content(_ read:()->Int,_ write:Bool,_ declared:Int64) throws -> Data {
            var digest = SHA256(),size:Int64 = 0
            while true {
                try token.check();let count = read();if count == 0 { break }
                guard count > 0 else { throw ArchiveService.failure(reader) }
                let sum = totalRead.addingReportingOverflow(Int64(count));guard !sum.overflow,sum.partialValue <= plan.maximumBytes else { throw CommanderError.message("Archivdaten überschreiten das Inhaltslimit.") };totalRead = sum.partialValue;size += Int64(count)
                guard size <= declared else { throw CommanderError.message("Archivinhalt überschreitet die angegebene Dateigröße.") }
                digest.update(data:Data(buffer.prefix(count)))
                if ProcessInfo.processInfo.systemUptime-lastProgress >= 0.1 { lastProgress = ProcessInfo.processInfo.systemUptime;progress("Gelesen · \(totalRead) Bytes") }
                if write {
                    let written = buffer.withUnsafeBytes { archive_write_data(writer,$0.baseAddress,count) }
                    guard written == count else { throw ArchiveService.failure(writer) }
                }
            }
            guard size == declared else { throw CommanderError.message("Archivinhalt ist kürzer als die angegebene Dateigröße.") }
            return Data(digest.finalize())
        }
        while true {
            try token.check();let code = archive_read_next_header(reader,&header)
            if code == 1 { break };guard code == 0,let header else { throw ArchiveService.failure(reader) }
            try ArchiveEditMetadata.validate(header)
            let member = try ArchiveService.member(header)
            guard seen.insert(member.path).inserted,let row = byOriginal[member.path],member == row.member,ArchiveEditMetadata(header) == plan.metadata[member.path] else { throw CommanderError.message("Archivverzeichnis wurde seit der Vorschau verändert.") }
            progress((row.action == .remove ? "Prüfe Entfernung · " : "Schreibe · ")+row.path)
            if row.action == .remove { _ = try content({ archive_read_data(reader,&buffer,buffer.count) },false,member.size);continue }
            guard let clone = archive_entry_clone(header) else { throw CommanderError.message("Archiv-Metadaten konnten nicht kopiert werden.") };defer { archive_entry_free(clone) }
            archive_entry_set_pathname(clone,row.path)
            guard archive_write_header(writer,clone) == 0 else { throw ArchiveService.failure(writer) }
            let digest = try content({ archive_read_data(reader,&buffer,buffer.count) },!member.isDirectory,member.size)
            result[row.path] = Expected(member:ArchiveMember(path:row.path,size:member.size,isDirectory:member.isDirectory,modified:member.modified,permissions:member.permissions),metadata:ArchiveEditMetadata(clone),digest:digest,added:false)
        }
        guard seen == plan.originalPaths else { throw CommanderError.message("Archivverzeichnis ist unvollständig.") }
        let additions = Dictionary(uniqueKeysWithValues:plan.locals.filter { $0.version.isRegularFile }.map { ($0.path,$0) })
        for row in plan.rows where row.action == .add {
            try token.check();progress("Füge hinzu · "+row.path)
            guard let entry = archive_entry_new() else { throw CommanderError.message("Archiv-Metadaten nicht verfügbar.") };defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry,row.path);archive_entry_set_filetype(entry,row.member.isDirectory ? 0o040000 : 0o100000)
            archive_entry_set_size(entry,row.member.isDirectory ? 0 : row.member.size);archive_entry_set_perm(entry,mode_t(row.member.permissions));archive_entry_set_mtime(entry,Int(row.member.modified.timeIntervalSince1970),0)
            guard archive_write_header(writer,entry) == 0 else { throw ArchiveService.failure(writer) }
            var digest = Data(SHA256.hash(data:Data()))
            if !row.member.isDirectory {
                guard let local = additions[row.path] else { throw CommanderError.message("Hinzugefügte Quelle fehlt.") };try local.validate(parents:plan.localParents)
                let input = open(local.url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
                guard input >= 0 else { throw CommanderError.message("Hinzugefügte Quelle nicht lesbar: "+row.path) };defer { close(input) }
                var current = stat();guard fstat(input,&current) == 0,RenameVersion(current) == local.version else { throw CommanderError.message("Hinzugefügte Quelle wurde ersetzt.") }
                digest = try content({ Darwin.read(input,&buffer,buffer.count) },true,row.member.size)
                guard fstat(input,&current) == 0,RenameVersion(current) == local.version else { throw CommanderError.message("Hinzugefügte Quelle wurde beim Lesen verändert.") };try local.validate(parents:plan.localParents)
            }
            result[row.path] = Expected(member:row.member,metadata:ArchiveEditMetadata(entry),digest:digest,added:true)
        }
        guard archive_write_close(writer) == 0 else { throw ArchiveService.failure(writer) }
        return result
    }
    private static func verify(_ plan:ArchiveEditPlan,fd:Int32,expected:[String:Expected],token:CancellationToken,progress:(String)->Void) throws {
        let reader = try ArchiveEditFile.reader(fd);defer { archive_read_free(reader) }
        var header:OpaquePointer?,seen = Set<String>(),buffer = [UInt8](repeating:0,count:128*1024),total:Int64 = 0
        while true {
            try token.check();let code = archive_read_next_header(reader,&header)
            if code == 1 { break };guard code == 0,let header else { throw ArchiveService.failure(reader) }
            let member = try ArchiveService.member(header)
            guard seen.insert(member.path).inserted,let expected = expected[member.path],member == expected.member else { throw CommanderError.message("Das neue Archiv enthält unerwartete oder veränderte Einträge.") }
            guard ArchiveEditMetadata(header).matches(expected.metadata,added:expected.added) else { throw CommanderError.message("Das gewählte Archivformat kann die Metadaten von „\(member.path)“ nicht unverändert erhalten. Das Original bleibt unverändert.") }
            progress("Prüfe Inhalt · "+member.path)
            var digest = SHA256(),size:Int64 = 0
            while true {
                try token.check();let count = archive_read_data(reader,&buffer,buffer.count);if count == 0 { break };guard count > 0 else { throw ArchiveService.failure(reader) }
                size += Int64(count);total += Int64(count)
                guard size <= member.size,total <= plan.maximumBytes else { throw CommanderError.message("Das neue Archiv überschreitet die geprüften Größen.") };digest.update(data:Data(buffer.prefix(count)))
            }
            guard size == (member.isDirectory ? 0 : member.size),Data(digest.finalize()) == expected.digest else { throw CommanderError.message("Inhaltsprüfung des neuen Archivs fehlgeschlagen: "+member.path) }
        }
        guard seen == Set(expected.keys) else { throw CommanderError.message("Das neue Archiv ist unvollständig.") }
    }
}
