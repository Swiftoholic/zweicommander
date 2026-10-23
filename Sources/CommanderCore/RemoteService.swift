import Foundation
import CryptoKit

public enum RemoteProtocol: String,CaseIterable,Codable { case sftp = "SFTP (SSH-Schlüssel)",ftps = "FTPS (TLS)",ftp = "FTP (unverschlüsselt)" }
public struct RemoteConnection {
    public var kind: RemoteProtocol
    public var host: String,user: String,password: String
    public var port: Int
    public var identityFile: URL?,knownHostsFile: URL?,caFile: URL?
    public init(kind: RemoteProtocol,host: String,user: String,password: String = "",port: Int,identityFile: URL? = nil,knownHostsFile: URL? = nil,caFile: URL? = nil) throws {
        let allowed = CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        guard !host.isEmpty,host.count <= 253,!host.hasPrefix("-"),host.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              (1...65535).contains(port),!user.isEmpty,user.count <= 255,!user.hasPrefix("-"),!user.contains("@"),!user.contains(":"),
              !user.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !password.contains("\0"),!password.contains("\n"),!password.contains("\r") else { throw CommanderError.message("Ungültige Verbindungsdaten.") }
        for url in [identityFile,knownHostsFile,caFile].compactMap({ $0 }) { guard url.isFileURL else { throw CommanderError.message("Schlüssel und Zertifikate benötigen lokale Dateipfade.") };try RemoteService.validatePath(url.path) }
        self.kind = kind;self.host = host;self.user = user;self.password = password;self.port = port
        self.identityFile = identityFile;self.knownHostsFile = knownHostsFile;self.caFile = caFile
    }
    public func authenticated(_ password: String) throws -> RemoteConnection {
        try RemoteConnection(kind:kind,host:host,user:user,password:password,port:port,identityFile:identityFile,knownHostsFile:knownHostsFile,caFile:caFile)
    }
    public var endpointID: String {
        let data = try! JSONEncoder().encode([kind.rawValue,host.lowercased(),String(port),user])
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    public func address(_ path: String) -> URL {
        var url = URLComponents();url.scheme = kind == .sftp ? "sftp" : kind == .ftps ? "ftps" : "ftp";url.host = host;url.port = port;url.path = path
        return url.url ?? URL(string:"remote:/")!
    }
}
public struct RemoteEntry: Equatable {
    public let name: String
    public let isDirectory: Bool,isLink: Bool
    public let size: Int64
    public let version: String
    public init(name: String,isDirectory: Bool,isLink: Bool = false,size: Int64 = 0,version: String = "") {
        self.name = name;self.isDirectory = isDirectory;self.isLink = isLink;self.size = size;self.version = version
    }
}
public protocol RemoteTransport: AnyObject {
    var endpointID: String { get }
    func list(_ path: String) throws -> [RemoteEntry]
    func download(_ path: String,to descriptor: Int32,size: Int64,progress: @escaping (Int64)->Void) throws
    func upload(_ descriptor: Int32,size: Int64,to path: String,progress: @escaping (Int64)->Void) throws
    func mkdir(_ path: String) throws
}
public enum RemoteService {
    public static func validatePath(_ path: String) throws {
        guard !path.isEmpty,path.utf8.count <= 32768,!path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CommanderError.message("Remote-Pfad ist leer, zu lang oder enthält Steuerzeichen.") }
    }
    public static func normalized(_ path: String) throws -> String {
        try validatePath(path)
        guard path.hasPrefix("/") else { throw CommanderError.message("Remote-Pfade müssen mit / beginnen.") }
        var parts: [String] = []
        for part in path.split(separator:"/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() };continue }
            try FileSystem.validateName(String(part));parts.append(String(part))
        }
        return "/"+parts.joined(separator:"/")
    }
    public static func transport(_ connection: RemoteConnection,token: CancellationToken = .init()) throws -> RemoteTransport {
        try token.check();let connection = try connection.authenticated(connection.password)
        return connection.kind == .sftp ? try SFTPTransport(connection,token:token) : FTPTransport(connection,token:token)
    }
    public static func batchQuote(_ path:String) throws -> String {
        try validatePath(path)
        let safePath = path.hasPrefix("-") ? "./"+path : path
        let escaped = safePath.map { char -> String in
            if "\\\"*?[]".contains(char) { return "\\"+String(char) }; return String(char)
        }.joined()
        return "\""+escaped+"\""
    }
    public static func parseListing(_ text:String,mlsd:Bool) throws -> [RemoteEntry] {
        let unix = try NSRegularExpression(pattern:"^([dl-])[rwxstST-]{9}[+@.]?\\s+\\d+\\s+\\S+\\s+\\S+\\s+(\\d+)\\s+\\S+\\s+\\d+\\s+\\S+\\s+(.+)$")
        var entries:[RemoteEntry] = [],unparsed = 0
        for raw in text.components(separatedBy:.newlines) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty || line.hasPrefix("sftp>") || line.hasPrefix("total ") || line.hasPrefix("Connected to ") { continue }
            if mlsd,let space = line.firstIndex(of:" ") {
                let facts = line[..<space].split(separator:";").reduce(into:[String:String]()) { result,fact in let pair = fact.split(separator:"=",maxSplits:1); if pair.count == 2 { result[String(pair[0]).lowercased()] = String(pair[1]) } }
                let name = String(line[line.index(after:space)...]),type = facts["type"]?.lowercased() ?? ""
                if type == "cdir" || type == "pdir" { continue }
                guard !name.isEmpty,!name.contains("/"),type == "dir" || type == "file" || type.contains("slink") else { unparsed += 1; continue }
                guard let size = Int64(facts["size"] ?? "0"),size >= 0,type != "file" || facts["size"] != nil else { unparsed += 1;continue }
                entries.append(RemoteEntry(name:name,isDirectory:type == "dir",isLink:type.contains("slink"),size:size,version:facts["modify"] ?? "")); continue
            }
            guard let match = unix.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)),let t = Range(match.range(at:1),in:line),let s = Range(match.range(at:2),in:line),let n = Range(match.range(at:3),in:line) else { unparsed += 1; continue }
            let type = String(line[t]); var name = String(line[n])
            if type == "l",let arrow = name.range(of:" -> ",options:.backwards) { name = String(name[..<arrow.lowerBound]) }
            if name == "." || name == ".." { continue }
            guard !name.contains("/"),!name.isEmpty else { unparsed += 1; continue }
            guard let size = Int64(line[s]) else { unparsed += 1;continue }
            entries.append(RemoteEntry(name:name,isDirectory:type == "d",isLink:type == "l",size:size,version:String(line[..<n.lowerBound])))
        }
        guard unparsed == 0 else { throw CommanderError.message("Server-Dateiliste enthält \(unparsed) nicht lesbare Zeilen. Das Listenformat wird nicht vollständig unterstützt; es wurden keine Transfers ausgeführt.") }
        for entry in entries { try FileSystem.validateName(entry.name);guard entry.size >= 0 else { throw CommanderError.message("Ungültige Remote-Dateigröße.") } }
        guard Set(entries.map(\.name)).count == entries.count else { throw CommanderError.message("Doppelte Server-Dateinamen.") }
        return entries.sorted { a,b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    public static func list(_ connection: RemoteConnection,path: String,token: CancellationToken = .init()) throws -> [RemoteEntry] {
        try transport(connection,token:token).list(normalized(path))
    }
    public static func child(_ path: String,_ name: String) -> String { (path.hasSuffix("/") ? path : path+"/")+name }
    public static func download(_ connection: RemoteConnection,path: String,entry: RemoteEntry,to directory: URL,token: CancellationToken = .init()) throws -> URL {
        let session = try transport(connection,token:token)
        let plan = try RemotePlanner.download(session,entries:[entry],path:path,to:directory,token:token)
        _ = try RemotePlanner.execute(plan,using:session,token:token)
        return directory.appendingPathComponent(entry.name)
    }
    public static func upload(_ connection: RemoteConnection,source: URL,path: String,token: CancellationToken = .init()) throws {
        let session = try transport(connection,token:token)
        let plan = try RemotePlanner.upload(session,sources:[source],to:path,token:token)
        _ = try RemotePlanner.execute(plan,using:session,token:token)
    }
}
