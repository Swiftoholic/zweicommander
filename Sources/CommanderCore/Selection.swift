import Foundation

public enum SelectionCombine: String,CaseIterable {
    case replace,add,remove,intersect
    public func apply(current:Set<URL>,matches:Set<URL>,universe:Set<URL>) -> Set<URL> {
        let current = current.intersection(universe),matches = matches.intersection(universe)
        switch self {
        case .replace:return matches
        case .add:return current.union(matches)
        case .remove:return current.subtracting(matches)
        case .intersect:return current.intersection(matches)
        }
    }
}

public struct SelectionRule {
    private let filters: [NameFilter]
    public let files: Bool,folders: Bool
    public init(_ pattern:String,regex:Bool = false,files:Bool = true,folders:Bool = true) throws {
        guard files || folders else { throw CommanderError.message("Mindestens Dateien oder Ordner wählen.") }
        guard pattern.utf8.count <= 4096 else { throw CommanderError.message("Das Auswahlmuster ist zu lang.") }
        self.files = files;self.folders = folders
        let patterns = regex ? [pattern] : pattern.split(separator:";",omittingEmptySubsequences:true).map { $0.trimmingCharacters(in:.whitespaces) }
        filters = try (patterns.isEmpty ? [""] : patterns).map { try NameFilter($0,regex:regex) }
    }
    public func matching(_ entries:[FileEntry]) -> Set<URL> {
        Set(entries.filter { entry in (entry.isDirectory ? folders : files) && filters.contains(where:{ $0.matches(entry.name) }) }.map(\.url))
    }
}

public enum SelectionNames {
    private static func key(_ text:String) -> String { text.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")).precomposedStringWithCanonicalMapping }
    public static func stem(_ entry:FileEntry) -> String { entry.isDirectory ? entry.name : (entry.name as NSString).deletingPathExtension }
    public static func sameStem(as seed:FileEntry,in entries:[FileEntry]) -> Set<URL> {
        let name = key(stem(seed))
        return Set(entries.filter { $0.isDirectory == seed.isDirectory && key(stem($0)) == name }.map(\.url))
    }
    public static func sameExtension(as seed:FileEntry,in entries:[FileEntry]) -> Set<URL> {
        guard !seed.isDirectory else { return [] }
        let ext = key(seed.fileExtension)
        return Set(entries.filter { !$0.isDirectory && key($0.fileExtension) == ext }.map(\.url))
    }
}

public enum SelectionCopyFormat: String,CaseIterable {
    case names,stems,paths,urls,shellArguments,table
    public func render(_ entries:[FileEntry]) throws -> String {
        func address(_ url:URL) -> String {
            var value = URLComponents(url:url,resolvingAgainstBaseURL:false)
            value?.user = nil;value?.password = nil;value?.query = nil;value?.fragment = nil
            return value?.url?.absoluteString ?? ""
        }
        func path(_ entry:FileEntry) -> String { entry.url.isFileURL ? entry.url.path : address(entry.url) }
        switch self {
        case .names:return entries.map(\.name).joined(separator:"\n")
        case .stems:return entries.map { SelectionNames.stem($0) }.joined(separator:"\n")
        case .paths:return entries.map(path).joined(separator:"\n")
        case .urls:return entries.map { address($0.url) }.joined(separator:"\n")
        case .shellArguments:
            guard entries.allSatisfy({$0.url.isFileURL}) else { throw CommanderError.message("Shell-Argumente sind nur für lokale Dateien verfügbar.") }
            return entries.map { "'"+$0.url.path.replacingOccurrences(of:"'",with:"'\\''")+"'" }.joined(separator:" ")
        case .table:
            func escape(_ text:String) -> String { text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\t",with:"\\t").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"\n",with:"\\n") }
            let date = ISO8601DateFormatter()
            return (["Name\tBytes\tGeändert\tArt\tPfad"]+entries.map { entry in
                [entry.name,entry.isDirectory ? "" : String(entry.size),entry.modified == .distantPast ? "" : date.string(from:entry.modified),entry.kind,path(entry)].map(escape).joined(separator:"\t")
            }).joined(separator:"\n")
        }
    }
}

public struct SelectionDocument: Codable {
    public static let maximumBytes = 2*1024*1024,maximumItems = 10_000
    public let schemaVersion: Int
    public let paths: [String]
    public var urls: [URL] { paths.compactMap(URL.init(string:)) }
    public init(_ urls:[URL]) throws { schemaVersion = 1;paths = urls.map(\.absoluteString);try validate() }
    public func validate() throws {
        guard schemaVersion == 1 else { throw CommanderError.message("Diese Version der Auswahldatei wird nicht unterstützt.") }
        guard paths.count <= Self.maximumItems,Set(paths).count == paths.count else { throw CommanderError.message("Die Auswahldatei enthält zu viele oder doppelte Einträge.") }
        for path in paths {
            guard path.utf8.count <= 64*1024,!path.contains("\0"),let url = URL(string:path),
                  URLComponents(url:url,resolvingAgainstBaseURL:false)?.percentEncodedPath.removingPercentEncoding?.contains("\0") == false,
                  let scheme = url.scheme?.lowercased(),["file","ftp","ftps","sftp"].contains(scheme),url.path.hasPrefix("/"),url.user == nil,url.password == nil,url.query == nil,url.fragment == nil,
                  (scheme == "file" ? (url.host == nil || url.host == "" || url.host == "localhost") && url.port == nil : !(url.host ?? "").isEmpty),
                  url.port.map({(1...65535).contains($0)}) ?? true else { throw CommanderError.message("Die Auswahldatei enthält eine ungültige oder mit Zugangsdaten versehene Adresse.") }
        }
    }
    public func encoded() throws -> Data {
        try validate();let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw CommanderError.message("Die Auswahldatei ist zu groß (höchstens 2 MiB).") };return data
    }
    public static func decode(_ data:Data) throws -> SelectionDocument {
        guard data.count <= maximumBytes else { throw CommanderError.message("Die Auswahldatei ist zu groß (höchstens 2 MiB).") }
        let value = try JSONDecoder().decode(Self.self,from:data);try value.validate();return value
    }
}
