import Foundation
import Darwin

/// Both the descriptor and its selected path must still describe the frozen regular file.
final class DiffFileSource {
    let url:URL,version:RenameVersion,fd:Int32,limit:Int
    init(_ url:URL,limit:Int) throws {
        guard url.isFileURL,!url.path.contains("\0") else { throw CommanderError.message("Dateivergleich benötigt zwei lokale reguläre Dateien.") }
        self.url = FileSystem.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent);self.limit = limit
        let before = try RenameVersion.read(self.url)
        guard before.isRegularFile,before.size >= 0,before.size <= limit else { throw CommanderError.message("Nur reguläre Dateien bis \(limit) Bytes je Seite vergleichen; Links und Spezialdateien werden nicht gelesen.") }
        let opened = open(self.url.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
        guard opened >= 0 else { throw CommanderError.message("Datei kann nicht geöffnet werden: "+url.lastPathComponent) }
        var value = stat()
        guard fstat(opened,&value) == 0,RenameVersion(value) == before else { close(opened);throw CommanderError.message("Datei wurde vor dem Lesen verändert: "+url.lastPathComponent) }
        fd = opened;version = before
    }
    deinit { close(fd) }
    func validate() throws {
        var value = stat()
        guard fstat(fd,&value) == 0,RenameVersion(value) == version,try RenameVersion.read(url) == version else { throw CommanderError.message("Datei wurde während des Vergleichs verändert: "+url.lastPathComponent) }
    }
    func read(token:CancellationToken,progress:(Int)->Void) throws -> Data {
        progress(0);try token.check();try validate()
        var result = Data(),buffer = [UInt8](repeating:0,count:128*1024);result.reserveCapacity(Int(version.size))
        while true {
            try token.check();let amount = Darwin.read(fd,&buffer,buffer.count)
            if amount < 0 { if errno == EINTR { continue };throw CommanderError.message("Datei konnte nicht vollständig gelesen werden: "+url.lastPathComponent) }
            if amount == 0 { break }
            guard result.count <= limit-amount else { throw CommanderError.message("Datei ist über die Vergleichsgrenze gewachsen.") }
            result.append(contentsOf:buffer.prefix(amount));progress(result.count)
        }
        try token.check();try validate();guard result.count == version.size else { throw CommanderError.message("Dateigröße stimmt nach dem Lesen nicht mehr überein.") };return result
    }
}
