import Foundation

public enum ConflictPolicy: String, CaseIterable, Codable { case stop, skip, keepBoth, replace }
public enum TransferKind: String, Codable { case copy, move }
public struct UndoStep {
    public let current: URL
    public let original: URL?
    public let backup: URL?
    public let stamp: FileStamp
}
public struct OperationReport {
    public var completed: [URL] = []
    public var skipped: [URL] = []
    public var undo: [UndoStep] = []
    public var errors: [String] = []
    public init() {}
}

public enum FileOperations {
    // Stage copies on the destination volume. Publishing uses a non-overwriting move.
    public static func transfer(_ urls: [URL], to destination: URL, kind: TransferKind, policy: ConflictPolicy, token: CancellationToken = .init(), progress: (String, Int, Int) -> Void = { _,_,_ in }) -> OperationReport {
        var report = OperationReport()
        let sources = FileSystem.topLevelSelection(urls)
        guard FileSystem.isDirectory(destination) else { report.errors = ["Ziel ist kein Ordner: \(destination.path)"]; return report }
        for (index, source) in sources.enumerated() {
            do {
                try token.check()
                progress(source.lastPathComponent, index, sources.count)
                let result = try transferOne(source, to: destination.appendingPathComponent(source.lastPathComponent), kind: kind, policy: policy, token: token)
                if let result { report.completed.append(result.current); report.undo.append(result) }
                else { report.skipped.append(source) }
            } catch {
                report.errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
                if token.isCancelled || policy == .stop { break }
            }
        }
        progress("Fertig", sources.count, sources.count)
        return report
    }

    public static func transferOne(_ source: URL, to requested: URL, kind: TransferKind, policy: ConflictPolicy, token: CancellationToken = .init()) throws -> UndoStep? {
        try transferPrepared(source,to:requested,kind:kind,policy:policy,token:token,tree:nil,expectedTarget:nil,byteProgress:{ _,_,_ in })
    }
    static func transferPrepared(_ source: URL,to requested: URL,kind: TransferKind,policy: ConflictPolicy,token: CancellationToken,tree: CopyTree?,expectedTarget: TargetVersion?,validateTarget: (() throws -> Void)? = nil,byteProgress: @escaping (String,Int64,Int64) -> Void) throws -> UndoStep? {
        let fm = FileManager.default
        try validateTarget?()
        guard FileSystem.exists(source) else { throw CommanderError.message("Quelle existiert nicht mehr.") }
        let sourcePath = FileSystem.canonical(source).path
        guard sourcePath != "/" else { throw CommanderError.message("Das Wurzelverzeichnis kann nicht übertragen werden.") }
        var target = requested.standardizedFileURL
        let expectation = try expectedTarget ?? TargetVersion(requested)
        try expectation.validate(requested)
        if FileSystem.canonical(target) == FileSystem.canonical(source) {
            if kind == .copy && policy == .keepBoth { target = FileSystem.uniqueDestination(target) }
            else { throw CommanderError.message("Quelle und Ziel sind identisch.") }
        }
        if FileSystem.isDirectory(source) && !FileSystem.isSymlink(source) && FileSystem.isInside(target.deletingLastPathComponent(), source) {
            throw CommanderError.message("Ein Ordner kann nicht in sich selbst übertragen werden.")
        }
        if FileSystem.exists(target) {
            switch policy {
            case .stop: throw CommanderError.message("Ziel existiert bereits: \(target.lastPathComponent)")
            case .skip: return nil
            case .keepBoth: target = FileSystem.uniqueDestination(target)
            case .replace: break
            }
        }
        try token.check()
        let parent = target.deletingLastPathComponent()
        let parentVersion = try FileStamp(parent)
        let staging = parent.appendingPathComponent(".zweicommander-transfer-" + UUID().uuidString)
        var backup: URL?
        var published = false
        defer {
            if !published,FileSystem.exists(staging),let current = try? FileStamp(parent),current.sameObject(as:parentVersion) { try? fm.removeItem(at:staging) }
        }
        let before = try FileStamp(source)
        if kind == .copy {
            let snapshot = try tree ?? CopyTree.scan(source,token:token)
            try snapshot.validate(source,token:token)
            try snapshot.copy(source,to:staging,token:token,progress:byteProgress)
        }
        try token.check()
        try validateTarget?()
        guard try FileStamp(parent).sameObject(as:parentVersion) else { throw CommanderError.message("Zielordner wurde während des Vorgangs ersetzt.") }
        guard try FileStamp(source) == before else { throw CommanderError.message("Quelle wurde während des Vorgangs verändert. Bitte erneut versuchen.") }
        if policy != .keepBoth { try expectation.validate(target) }
        if FileSystem.exists(target) {
            guard policy == .replace else { throw CommanderError.message("Ziel wurde inzwischen angelegt; nichts überschrieben.") }
            let saved = parent.appendingPathComponent(".zweicommander-backup-" + UUID().uuidString)
            try fm.moveItem(at: target, to: saved)
            backup = saved
        }
        do { try fm.moveItem(at: kind == .copy ? staging : source, to: target); published = true }
        catch {
            if let backup {
                if !FileSystem.exists(target) {
                    do { try fm.moveItem(at: backup, to: target) }
                    catch { throw CommanderError.message("Übertragung fehlgeschlagen. Die vorherige Zieldatei liegt weiterhin unter \(backup.path). Wiederherstellung fehlgeschlagen: \(error.localizedDescription)") }
                } else { throw CommanderError.message("Das Ziel wurde während des Vorgangs belegt. Die vorherige Zieldatei wurde unter \(backup.path) gesichert.") }
            }
            throw error
        }
        return UndoStep(current: target, original: kind == .move ? source : nil, backup: backup, stamp: try FileStamp(target))
    }

    public static func undo(_ steps: [UndoStep]) -> [String] {
        let fm = FileManager.default
        var errors: [String] = []
        for step in steps.reversed() {
            do {
                guard FileSystem.exists(step.current), try FileStamp(step.current) == step.stamp else {
                    throw CommanderError.message("Datei wurde nachträglich geändert. Rückgängig übersprungen: \(step.current.path)")
                }
                // Never recursively remove a directory on undo: its descendants may have changed.
                if FileSystem.isDirectory(step.current) && !FileSystem.isSymlink(step.current) {
                    throw CommanderError.message("Ordner werden zum Schutz späterer Änderungen nicht automatisch zurückgesetzt: \(step.current.path)")
                }
                if let original = step.original {
                    guard !FileSystem.exists(original) else { throw CommanderError.message("Ursprünglicher Name ist wieder belegt: \(original.path)") }
                    try fm.moveItem(at: step.current, to: original)
                } else {
                    var trashed: NSURL?
                    try fm.trashItem(at: step.current, resultingItemURL: &trashed)
                }
                if let backup = step.backup { try fm.moveItem(at: backup, to: step.current) }
            } catch { errors.append(error.localizedDescription) }
        }
        return errors
    }

    public static func trash(_ urls: [URL], token: CancellationToken = .init()) -> OperationReport {
        var report = OperationReport()
        for url in FileSystem.topLevelSelection(urls) {
            do {
                try token.check()
                guard url.path != "/", url.standardizedFileURL != FileManager.default.homeDirectoryForCurrentUser else { throw CommanderError.message("Dieser Ordner ist geschützt.") }
                var result: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                report.completed.append(url)
                if let result { let u = result as URL; report.undo.append(UndoStep(current: u, original: url, backup: nil, stamp: try FileStamp(u))) }
            } catch { report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return report
    }
    public static func rename(_ url: URL, to name: String) throws -> URL {
        try FileSystem.validateName(name)
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        if url == target { return url }
        guard !FileSystem.exists(target) else { throw CommanderError.message("Der Name ist bereits belegt: \(name)") }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
    public static func newDirectory(in parent: URL, name: String) throws {
        try FileSystem.validateName(name)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: false)
    }
    public static func newFile(in parent: URL, name: String) throws -> URL {
        try FileSystem.validateName(name)
        let url = parent.appendingPathComponent(name)
        let handle = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard handle >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        close(handle)
        return url
    }
}
