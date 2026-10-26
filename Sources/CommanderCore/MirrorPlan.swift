import Foundation
import Darwin

func mirrorError(_ text:String) -> CommanderError { .message("Spiegelung: "+text) }
func mirrorVersion(_ fd:Int32) throws -> RenameVersion {
    var value = stat();guard fstat(fd,&value) == 0 else { throw mirrorError("Dateiobjekt nicht lesbar.") };return RenameVersion(value)
}
func mirrorOptional(_ fd:Int32,_ name:String) throws -> RenameVersion? {
    var value = stat();if fstatat(fd,name,&value,AT_SYMLINK_NOFOLLOW) == 0 { return RenameVersion(value) }
    if errno == ENOENT { return nil };throw mirrorError("Eintrag nicht lesbar: "+name)
}
func mirrorValidPath(_ path:String) -> Bool {
    !path.isEmpty && path.utf8.count <= 32768 && !path.hasPrefix("/") && !path.contains("\0") && !path.split(separator:"/",omittingEmptySubsequences:false).contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".zweicommander-") }
}

/// Describes one retained removal. No file content is stored in this receipt.
public struct MirrorRemovalReceipt:Codable,Equatable {
    let root:URL,rootVersion:RenameVersion,path:String,stored:URL
    let ancestors:[String:RenameVersion],members:[String:RenameVersion]
    var storedVersion:RenameVersion? = nil
    func validateShape() throws {
        guard root.isFileURL,stored.isFileURL,root.path == root.standardizedFileURL.path,mirrorValidPath(path),
              (root.host == nil || root.host == ""),root.user == nil,root.password == nil,root.query == nil,root.fragment == nil,!root.path.contains("\0"),root.path.utf8.count <= 32768,
              stored.deletingLastPathComponent().path == root.appendingPathComponent(path).deletingLastPathComponent().path,
              stored.lastPathComponent.hasPrefix(".zweicommander-backup-"),rootVersion.isDirectory,
              !members.isEmpty,members.count <= 50_000,ancestors.count <= 256,members[""] != nil else { throw mirrorError("Ungültiger Entfernungsbeleg.") }
        let parentParts = path.split(separator:"/").dropLast(),expectedParents = Set((0..<parentParts.count).map { parentParts.prefix($0+1).joined(separator:"/") })
        guard Set(ancestors.keys) == expectedParents,UUID(uuidString:String(stored.lastPathComponent.dropFirst(".zweicommander-backup-".count))) != nil else { throw mirrorError("Unvollständiger Entfernungsbeleg.") }
        for (path,value) in members { guard (path.isEmpty || mirrorValidPath(path)),value.isRegularFile || value.isDirectory else { throw mirrorError("Ungültiger Sicherungseintrag.") } }
        guard members[""]!.isDirectory || members.count == 1 else { throw mirrorError("Ungültiger Sicherungsbaum.") }
        for path in members.keys where !path.isEmpty { let parent = (path as NSString).deletingLastPathComponent;guard members[parent]?.isDirectory == true else { throw mirrorError("Unvollständiger Sicherungsbaum.") } }
        for (path,value) in ancestors { guard mirrorValidPath(path),value.isDirectory else { throw mirrorError("Ungültiger Sicherungsordner.") } }
    }
    var original:URL { root.appendingPathComponent(path) }
    func anchor() throws -> SyncRoot {
        try validateShape();return try SyncRoot(root,rootVersion,ancestors.mapValues { ComparedEntry(root,$0) })
    }
}
public struct MirrorRemoval:Identifiable {
    public let id:UUID,path:String,original:URL,stored:URL,bytes:Int64,isDirectory:Bool
    let receipt:MirrorRemovalReceipt
    public var members:[MirrorRemovalMember] { receipt.members.keys.sorted().map { MirrorRemovalMember(path:$0,isDirectory:receipt.members[$0]!.isDirectory,bytes:receipt.members[$0]!.isRegularFile ? Int64(receipt.members[$0]!.size) : 0) } }
}
public struct MirrorRemovalMember {
    public let path:String,isDirectory:Bool,bytes:Int64
}
public struct MirrorRetained:Identifiable {
    public let path:String,reason:String
    public var id:String { path }
}
public struct FolderMirrorPlan {
    let comparison:FolderComparison
    public let direction:SyncDirection,copies:FolderSyncPlan,removals:[MirrorRemoval],retained:[MirrorRetained]
    public let skippedPaths:Set<String>
    public var bytes:Int64 { copies.bytes }
    public var source:URL { direction == .leftToRight ? comparison.left : comparison.right }
    public var destination:URL { direction == .leftToRight ? comparison.right : comparison.left }
    public var initialItems:[TransferItemProgress] {
        copies.initialItems+removals.map { TransferItemProgress(id:$0.id,source:$0.original,target:$0.stored,state:.waiting,bytes:0,totalBytes:0,isByteTracked:false,message:"Entfernen mit Sicherung") }
    }
    /// Builds an exact, immutable review. Skipped directories also skip their descendants.
    public static func prepare(_ comparison:FolderComparison,direction:SyncDirection,skipping:Set<String> = [],token:CancellationToken = .init()) throws -> FolderMirrorPlan {
        guard direction == .leftToRight || direction == .rightToLeft else { throw mirrorError("Eine feste Spiegelrichtung wählen.") }
        guard skipping.isSubset(of:Set(comparison.items.map(\.id))) else { throw mirrorError("Unbekannte ausgelassene Zeile.") }
        let ltr = direction == .leftToRight,source = ltr ? comparison.leftEntries : comparison.rightEntries,target = ltr ? comparison.rightEntries : comparison.leftEntries
        let root = ltr ? comparison.right : comparison.left,rootVersion = ltr ? comparison.rightVersion : comparison.leftVersion
        guard try RenameVersion.read(comparison.left) == comparison.leftVersion,try RenameVersion.read(comparison.right) == comparison.rightVersion else { throw mirrorError("Vergleichsordner verändert; erneut vergleichen.") }
        func skipped(_ path:String) -> Bool {
            let parts = path.split(separator:"/");return (1...parts.count).contains { skipping.contains(parts.prefix($0).joined(separator:"/")) }
        }
        var decisions = comparison.suggestions(ltr ? .leftToRight : .rightToLeft)
        for row in comparison where skipped(row.id) { decisions[row.id] = .skip }
        let copies = try comparison.plan(decisions)
        let sourceRoot = try SyncRoot(ltr ? comparison.left : comparison.right,ltr ? comparison.leftVersion : comparison.rightVersion,source)
        var candidates:[String:ComparedEntry] = [:],retained:[MirrorRetained] = []
        for row in comparison {
            try token.check()
            if row.isBlocked { if (ltr ? row.right : row.left) != nil { retained.append(MirrorRetained(path:row.id,reason:row.state.rawValue+" · bleibt erhalten")) };continue }
            guard !skipped(row.id),source[row.id] == nil,let item = target[row.id] else { continue }
            guard try FolderMirrorEngine.isSourceAbsent(sourceRoot,path:row.id,token:token) else { retained.append(MirrorRetained(path:row.id,reason:"Gegenstück außerhalb der geprüften Auswahl · bleibt erhalten"));continue }
            guard mirrorValidPath(row.id),item.isDirectory || item.isRegularFile else { throw mirrorError("Unzulässiger Zielpfad.") }
            candidates[row.id] = item
        }
        let targetRoot = try SyncRoot(root,rootVersion,target),allowed = Set(candidates.keys)
        var covered = Set<String>(),removals:[MirrorRemoval] = [],budget = 200_000
        for path in candidates.keys.sorted(by:{ a,b in let x = a.split(separator:"/").count,y = b.split(separator:"/").count;return x == y ? a < b : x < y }) {
            try token.check();if covered.contains(path) { continue };let item = candidates[path]!
            var members = ["":item.version]
            if item.isDirectory {
                do {
                    guard let parent = try targetRoot.parent(path) else { throw mirrorError("Zielordner fehlt.") };defer { close(parent) }
                    members = try MirrorTree.read(parent:parent,name:(path as NSString).lastPathComponent,expected:target,pathPrefix:path,allowed:allowed,budget:&budget,token:token)
                } catch is MirrorTree.Retained {
                    retained.append(MirrorRetained(path:path,reason:"Enthält ausgelassene, versteckte oder nicht vollständig geprüfte Einträge · Ordner bleibt"));continue
                }
            }
            let parent = (path as NSString).deletingLastPathComponent
            var ancestors:[String:RenameVersion] = [:]
            if !parent.isEmpty { let parts = parent.split(separator:"/");for count in 1...parts.count { let p = parts.prefix(count).joined(separator:"/");guard let folder = target[p],folder.isDirectory else { throw mirrorError("Zielpfad nicht vollständig erfasst.") };ancestors[p] = folder.version } }
            let id = UUID(),original = root.appendingPathComponent(path),stored = original.deletingLastPathComponent().appendingPathComponent(".zweicommander-backup-"+id.uuidString)
            let receipt = MirrorRemovalReceipt(root:root,rootVersion:rootVersion,path:path,stored:stored,ancestors:ancestors,members:members);try receipt.validateShape()
            var amount:Int64 = 0
            for value in members.values where value.isRegularFile { let next = amount.addingReportingOverflow(Int64(value.size));guard !next.overflow else { throw mirrorError("Sicherungsgröße zu groß.") };amount = next.partialValue }
            removals.append(MirrorRemoval(id:id,path:path,original:original,stored:stored,bytes:amount,isDirectory:item.isDirectory,receipt:receipt))
            for member in members.keys { covered.insert(member.isEmpty ? path : path+"/"+member) }
        }
        guard removals.count <= 2000 else { throw mirrorError("Höchstens 2.000 getrennte Entfernungen pro Plan; kleinere Ordner wählen.") }
        return FolderMirrorPlan(comparison:comparison,direction:direction,copies:copies,removals:removals,retained:retained,skippedPaths:skipping)
    }
}

// Enumerate through held directory descriptors; never follow a link or a moved parent.
enum MirrorTree {
    struct Retained:Error {}
    static func names(_ fd:Int32) throws -> [String] {
        let duplicate = dup(fd);guard duplicate >= 0 else { throw mirrorError("Ordnerhandle fehlt.") }
        guard let iterator = fdopendir(duplicate) else { close(duplicate);throw mirrorError("Ordner nicht lesbar.") };defer { closedir(iterator) }
        var result:[String] = []
        while true {
            errno = 0;guard let entry = readdir(iterator) else { if errno != 0 { throw mirrorError("Ordner konnte nicht vollständig gelesen werden.") };break }
            let name = withUnsafePointer(to:&entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1) { String(validatingUTF8:$0) } }
            guard let name else { throw Retained() };if name == "." || name == ".." { continue };result.append(name)
            guard result.count <= 50_000 else { throw Retained() }
        }
        return result.sorted()
    }
    static func read(parent:Int32,name:String,expected:[String:ComparedEntry],pathPrefix:String,allowed:Set<String>,budget:inout Int,token:CancellationToken) throws -> [String:RenameVersion] {
        var result:[String:RenameVersion] = [:]
        func visit(_ parent:Int32,_ name:String,_ relative:String,_ full:String,_ depth:Int) throws {
            try token.check();budget -= 1;guard budget >= 0,depth <= 256 else { throw Retained() }
            guard allowed.contains(full),let expected = expected[full]?.version else { throw Retained() }
            guard let current = try mirrorOptional(parent,name),current == expected else { throw mirrorError("Zieleintrag seit Vergleich verändert: "+full) }
            guard current.isDirectory || current.isRegularFile else { throw Retained() };result[relative] = current
            if current.isDirectory {
                let fd = openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd >= 0 else { throw mirrorError("Zielordner nicht lesbar: "+full) };defer { close(fd) }
                guard try mirrorVersion(fd) == current else { throw mirrorError("Zielordner beim Öffnen verändert.") }
                for child in try names(fd) { try visit(fd,child,relative.isEmpty ? child : relative+"/"+child,full+"/"+child,depth+1) }
                guard try mirrorVersion(fd) == current else { throw mirrorError("Zielordner während Prüfung verändert.") }
            }
        }
        try visit(parent,name,"",pathPrefix,0);return result
    }
    static func validate(parent:Int32,name:String,members:[String:RenameVersion],afterRename:Bool,token:CancellationToken) throws {
        var seen = Set<String>()
        func visit(_ parent:Int32,_ name:String,_ relative:String,_ depth:Int) throws {
            try token.check();guard depth <= 256,let expected = members[relative],let current = try mirrorOptional(parent,name),relative.isEmpty && afterRename ? expected.sameAfterRename(current) : current == expected else { throw mirrorError("Entfernungsbaum wurde seit der Vorschau verändert.") }
            seen.insert(relative)
            if current.isDirectory {
                let fd = openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd >= 0 else { throw mirrorError("Sicherungsordner nicht verfügbar.") };defer { close(fd) }
                guard try mirrorVersion(fd) == current else { throw mirrorError("Sicherungsordner beim Öffnen verändert.") }
                for child in try names(fd) { try visit(fd,child,relative.isEmpty ? child : relative+"/"+child,depth+1) }
                guard try mirrorVersion(fd) == current else { throw mirrorError("Sicherungsordner während Prüfung verändert.") }
            }
        }
        try visit(parent,name,"",0);guard seen == Set(members.keys) else { throw mirrorError("Entfernungsbaum ist nicht mehr vollständig.") }
    }
}
