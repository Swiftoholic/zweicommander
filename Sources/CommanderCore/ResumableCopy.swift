import Foundation
import Darwin

final class ResumableCopy {
    let history: TransferHistory
    private(set) var record: PartialCopy
    private(set) var reusedBytes: Int64 = 0
    private var verified: [String:RenameVersion] = [:]
    var stage: URL { record.stage }
    init(history: TransferHistory,record: PartialCopy) { self.history = history;self.record = record }
    deinit { history.releaseCopy(record.id) }
    private func parent(_ path: String) throws -> Int32 {
        if path.isEmpty { return try recoveryParent(stage,record.parent) }
        guard let root = record.owned[""],root.isDirectory else { throw recoveryError("Teilkopieordner fehlt.") }
        let outer = try recoveryParent(stage,record.parent);defer { close(outer) }
        var fd = openat(outer,stage.lastPathComponent,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw recoveryError("Teilkopieordner nicht lesbar.") }
        do {
            guard try root.sameObject(recoveryFDVersion(fd)) else { throw recoveryError("Teilkopieordner wurde ersetzt.") }
            guard fchmod(fd,0o700) == 0 else { throw recoveryError("Teilkopieordner ist nicht beschreibbar.") }
            var prefix = ""
            for part in path.split(separator:"/").dropLast().map(String.init) {
                prefix = prefix.isEmpty ? part : prefix+"/"+part
                guard let expected = record.owned[prefix],expected.isDirectory else { throw recoveryError("Teilkopie enthält einen unbekannten Ordner.") }
                let next = openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard next >= 0 else { throw recoveryError("Teilkopie-Unterordner nicht lesbar.") }
                guard let version = try? recoveryFDVersion(next),expected.sameObject(version),fchmod(next,0o700) == 0 else { close(next);throw recoveryError("Teilkopie-Unterordner wurde ersetzt.") }
                close(fd);fd = next
            }
            return fd
        } catch { close(fd);throw error }
    }
    private func name(_ path: String) -> String { path.isEmpty ? stage.lastPathComponent : (path as NSString).lastPathComponent }
    private func validateParent(_ path: String,_ held: Int32) throws {
        let actual = try parent(path);defer { close(actual) }
        guard try recoveryFDVersion(actual).sameObject(recoveryFDVersion(held)) else { throw recoveryError("Teilkopieordner wurde während des Kopierens verändert.") }
    }
    private func remember(_ path: String,_ version: RenameVersion) throws {
        record.owned[path] = version;try history.updateCopy(record)
    }
    func copy(_ tree: CopyTree,token: CancellationToken,progress: @escaping (String,Int64,Int64)->Void) throws {
        var completed: Int64 = 0
        for node in tree.nodes {
            try token.check()
            let source = node.relative.isEmpty ? record.source : record.source.appendingPathComponent(node.relative)
            guard try RenameVersion.read(source) == node.version else { throw recoveryError("Quelle wurde seit der Vorschau verändert.") }
            let fd = try parent(node.relative);defer { close(fd) }
            let leaf = name(node.relative)
            if let owned = record.owned[node.relative] {
                guard try owned.sameObject(RenameVersion.read(fd,leaf)) else { throw recoveryError("Teilkopie wurde von außen ersetzt.") }
            } else {
                if node.directory {
                    guard mkdirat(fd,leaf,0o700) == 0 else { throw recoveryError("Teilkopieordner konnte nicht angelegt werden.") }
                } else {
                    let output = openat(fd,leaf,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
                    guard output >= 0 else { throw recoveryError("Teilkopie wurde inzwischen belegt.") };close(output)
                }
                let owned = try RenameVersion.read(fd,leaf)
                do { try remember(node.relative,owned) }
                catch { if (try? RenameVersion.read(fd,leaf)).map({ owned.sameObject($0) }) == true { _ = unlinkat(fd,leaf,node.directory ? AT_REMOVEDIR : 0) };throw error }
            }
            if node.directory { continue }
            let input = open(source.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
            guard input >= 0 else { throw recoveryError("Quelle nicht lesbar.") };defer { close(input) }
            guard try recoveryFDVersion(input) == node.version else { throw recoveryError("Quelle wurde beim Öffnen verändert.") }
            let protected = openat(fd,leaf,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
            guard protected >= 0 else { throw recoveryError("Teilkopie nicht lesbar.") }
            var value = stat()
            let safe = fstat(protected,&value) == 0 && record.owned[node.relative]!.sameObject(RenameVersion(value)) && value.st_nlink == 1 && value.st_uid == getuid()
            guard safe,fchmod(protected,0o600) == 0 else { close(protected);throw recoveryError("Teilkopie ist kein ausschließlich eigenes Dateiobjekt.") };close(protected)
            let output = openat(fd,leaf,O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
            guard output >= 0 else { throw recoveryError("Teilkopie nicht beschreibbar.") };defer { close(output) }
            let current = try recoveryFDVersion(output)
            guard record.owned[node.relative]!.sameObject(current),current.isRegularFile,current.size >= 0,current.size <= node.bytes else { throw recoveryError("Teilkopiegröße oder Dateiobjekt stimmt nicht.") }
            let offset = Int64(current.size),base = completed
            defer { _ = fsync(output) }
            progress((offset > 0 ? "Fortsetzen · " : "")+source.lastPathComponent,base,tree.bytes)
            try NativeCopy.resumeDescriptors(input,to:output,offset:offset,total:node.bytes,token:token,verifying:{ _ in
                progress("Prüfe Teilkopie · "+source.lastPathComponent,base,tree.bytes)
            },progress:{ count in
                progress((offset > 0 ? "Fortsetzen · " : "")+source.lastPathComponent,base+count,tree.bytes)
            })
            if offset > 0 {
                let before = try recoveryFDVersion(output)
                try NativeCopy.resumeDescriptors(input,to:output,offset:node.bytes,total:node.bytes,token:token,verifying:{ _ in
                    progress("Prüfe fortgesetzte Datei · "+source.lastPathComponent,base+node.bytes,tree.bytes)
                },progress:{ _ in })
                guard try recoveryFDVersion(output) == before else { throw recoveryError("Fortgesetzte Datei wurde während der Ergebnisprüfung verändert.") }
            }
            try token.check();try validateParent(node.relative,fd)
            guard try recoveryFDVersion(input) == node.version,try RenameVersion.read(source) == node.version,
                  try record.owned[node.relative]!.sameObject(RenameVersion.read(fd,leaf)) else { throw recoveryError("Quelle oder Teilkopie wurde während des Kopierens verändert.") }
            try NativeCopy.metadataDescriptors(input,to:output)
            guard fsync(output) == 0 else { throw recoveryError("Teilkopie konnte nicht auf den Datenträger geschrieben werden.") }
            guard fstat(output,&value) == 0,value.st_nlink == 1,value.st_uid == getuid() else { throw recoveryError("Teilkopie wurde während des Kopierens verknüpft.") }
            verified[node.relative] = RenameVersion(value)
            reusedBytes += offset;completed += node.bytes;progress(source.lastPathComponent,completed,tree.bytes)
        }
        try tree.validate(record.source,token:token)
        guard try tree.recoverySignature(record.source,token:token) == record.signature else { throw recoveryError("Quelle wurde während des Kopierens verändert.") }
        for node in tree.nodes.reversed() where node.directory {
            try token.check();let fd = try parent(node.relative);defer { close(fd) }
            let source = node.relative.isEmpty ? record.source : record.source.appendingPathComponent(node.relative)
            let input = open(source.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard input >= 0 else { throw recoveryError("Quellordner nicht lesbar.") };defer { close(input) }
            let output = openat(fd,name(node.relative),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard output >= 0 else { throw recoveryError("Teilkopieordner nicht lesbar.") };defer { close(output) }
            guard try record.owned[node.relative]!.sameObject(recoveryFDVersion(output)) else { throw recoveryError("Teilkopieordner wurde ersetzt.") }
            try NativeCopy.metadataDescriptors(input,to:output)
            verified[node.relative] = try recoveryFDVersion(output)
        }
    }
    func validateForPublish(token: CancellationToken) throws {
        let parent = try recoveryParent(stage,record.parent);defer { close(parent) }
        guard verified.count == record.owned.count,let root = verified[""],try RenameVersion.read(parent,stage.lastPathComponent) == root else { throw recoveryError("Teilkopie wurde vor Veröffentlichung verändert.") }
        func check(_ path: String,_ url: URL) throws {
            try token.check();var value = stat()
            guard let expected = verified[path],lstat(url.path,&value) == 0,RenameVersion(value) == expected,
                  expected.isDirectory || (expected.isRegularFile && value.st_nlink == 1 && value.st_uid == getuid()) else { throw recoveryError("Teilkopie enthält ein verändertes oder unbekanntes Objekt.") }
        }
        try check("",stage)
        if root.isDirectory {
            var count = 1
            try FileSystem.walk(stage,token:token) { url in count += 1;try check(FileSystem.relativePath(of:url,inside:stage),url) }
            guard count == verified.count else { throw recoveryError("Teilkopie enthält fehlende oder zusätzliche Objekte.") }
        }
    }
    func published() throws { try history.finishCopy(record.id) }
}
