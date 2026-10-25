import Foundation

public enum ArchiveFormat:String,CaseIterable {
    case zip,sevenZip,tarGzip
    public var title:String { switch self { case .zip:return "ZIP";case .sevenZip:return "7z";case .tarGzip:return "TAR + GZip" } }
    public var fileExtension:String { switch self { case .zip:return "zip";case .sevenZip:return "7z";case .tarGzip:return "tar.gz" } }
    public func accepts(_ url:URL) -> Bool { let name = url.lastPathComponent.lowercased();return self == .tarGzip ? name.hasSuffix(".tar.gz") : url.pathExtension.lowercased() == fileExtension }
}

public struct ArchivePackPlan {
    public let sources:[URL],destination:URL,format:ArchiveFormat,compressionLevel:Int,rows:[ArchiveMember],totalBytes:Int64
    private let versions:[(URL,RenameVersion)],parent:RenameVersion
    public init(sources:[URL],to destination:URL,format:ArchiveFormat = .zip,compressionLevel:Int = 6,token:CancellationToken = .init()) throws {
        guard !sources.isEmpty,sources.count <= ArchiveCatalog.maximumEntries,sources.allSatisfy(ArchiveService.isLocal),ArchiveService.isLocal(destination),format.accepts(destination),(0...9).contains(compressionLevel) else { throw CommanderError.message("Bitte Quellen, Archivformat, passende Endung und eine Kompressionsstufe von 0 bis 9 wählen.") }
        let parentURL = FileSystem.canonical(destination.deletingLastPathComponent()),target = parentURL.appendingPathComponent(destination.lastPathComponent)
        try FileSystem.validateName(target.lastPathComponent);parent = try RenameVersion.read(parentURL)
        guard parent.isDirectory,!FileSystem.exists(target) else { throw CommanderError.message("Bitte einen neuen Archivnamen in einem vorhandenen Ordner angeben.") }
        for source in sources { let version = try RenameVersion.read(source);guard version.isDirectory || version.isRegularFile else { throw CommanderError.message("Verknüpfungen und Spezialdateien werden nicht archiviert.") } }
        let inputs = FileSystem.topLevelSelection(sources);var versions:[(URL,RenameVersion)] = [],rows:[ArchiveMember] = [],names = Set<String>(),total:Int64 = 0
        func append(_ url:URL,_ path:String) throws {
            try token.check();let version = try RenameVersion.read(url)
            guard version.isDirectory || version.isRegularFile else { throw CommanderError.message("Verknüpfung oder Spezialdatei: "+path) }
            guard rows.count < ArchiveCatalog.maximumEntries,names.insert(path).inserted,try ArchiveService.safePath(path) == path else { throw CommanderError.message("Doppelte, unsichere oder zu viele Archivnamen: "+path) }
            let bytes = version.isDirectory ? 0 : Int64(version.size),sum = total.addingReportingOverflow(bytes)
            guard bytes >= 0,!sum.overflow else { throw CommanderError.message("Die Gesamtgröße kann nicht ermittelt werden.") };total = sum.partialValue
            rows.append(ArchiveMember(path:path,size:bytes,isDirectory:version.isDirectory,modified:version.modified,permissions:Int(version.mode) & 0o777));versions.append((url,version))
        }
        for source in inputs {
            guard !FileSystem.isInside(target,source) else { throw CommanderError.message("Das Archivziel liegt in einer Quelle.") }
            let name = source.lastPathComponent;try append(source,name)
            if FileSystem.isDirectory(source) { try FileSystem.walk(source,token:token) { try append($0,name+"/"+FileSystem.relativePath(of:$0,inside:source)) } }
        }
        self.sources = inputs;self.destination = target;self.format = format;self.compressionLevel = compressionLevel;self.versions = versions;self.rows = rows;totalBytes = total
        try validate(token:token)
    }
    public func validate(token:CancellationToken = .init()) throws {
        guard try RenameVersion.read(destination.deletingLastPathComponent()).sameObject(parent),!FileSystem.exists(destination) else { throw CommanderError.message("Archivziel oder Elternordner wurde geändert. Bitte neu prüfen.") }
        for (url,version) in versions { try token.check();guard try RenameVersion.read(url) == version else { throw CommanderError.message("Eine Archivquelle wurde geändert. Bitte die Vorschau erneuern: "+url.lastPathComponent) } }
    }
    public func execute(token:CancellationToken = .init(),progress:(String)->Void = { _ in }) throws {
        try validate(token:token)
        try ArchiveService.pack(sources,to:destination,tarGzip:format == .tarGzip,sevenZip:format == .sevenZip,compressionLevel:compressionLevel,token:token,progress:progress,validateBeforePublish:{ try validate(token:token) })
    }
}
