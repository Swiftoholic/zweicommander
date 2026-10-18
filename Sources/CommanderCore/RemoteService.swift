import Foundation

public enum RemoteProtocol:String,CaseIterable { case sftp = "SFTP (SSH-Schlüssel)",ftps = "FTPS (TLS)",ftp = "FTP (unverschlüsselt)" }
public struct RemoteConnection {
    public var kind:RemoteProtocol
    public var host:String
    public var user:String
    public var password:String
    public var port:Int
    public init(kind:RemoteProtocol,host:String,user:String,password:String = "",port:Int) throws {
        let allowed = CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        guard !host.isEmpty,!host.hasPrefix("-"),host.unicodeScalars.allSatisfy({allowed.contains($0)}),(1...65535).contains(port),!user.isEmpty,!user.hasPrefix("-"),!user.contains("@"),!user.contains(":"),!user.contains("\0"),!user.contains("\n"),!user.contains("\r"),!password.contains("\0"),!password.contains("\n"),!password.contains("\r") else { throw CommanderError.message("Ungültige Verbindungsdaten.") }
        self.kind = kind; self.host = host; self.user = user; self.password = password; self.port = port
    }
}
public struct RemoteEntry {
    public let name:String
    public let isDirectory:Bool
    public let isLink:Bool
    public let size:Int64
}
public enum RemoteService {
    public static func validatePath(_ path:String) throws {
        guard !path.contains("\n"),!path.contains("\r"),!path.contains("\0"),!path.isEmpty else { throw CommanderError.message("Remote-Pfade dürfen keine Zeilenumbrüche enthalten.") }
    }
    public static func batchQuote(_ path:String) throws -> String {
        try validatePath(path)
        let safePath = path.hasPrefix("-") ? "./"+path : path
        let escaped = safePath.map { char -> String in
            if "\\\"*?[]".contains(char) { return "\\"+String(char) }; return String(char)
        }.joined()
        return "\""+escaped+"\""
    }
    private static func sftp(_ connection:RemoteConnection,commands:[String],token:CancellationToken) throws -> String {
        let host = connection.host.contains(":") ? "[\(connection.host)]" : connection.host
        return try ProcessRunner.run("/usr/bin/sftp",arguments:["-b","-","-oBatchMode=yes","-oStrictHostKeyChecking=yes","-oConnectTimeout=10","-P",String(connection.port),connection.user+"@"+host],input:Data((commands.joined(separator:"\n")+"\n").utf8),token:token,timeout:3600)
    }
    private static func ftp(_ connection:RemoteConnection,path:String,directory:Bool,options:[String] = [],token:CancellationToken) throws -> String {
        try validatePath(path)
        var url = URLComponents(); url.scheme = "ftp"; url.host = connection.host; url.port = connection.port
        let fullPath = (path.hasPrefix("/") ? path : "/"+path)+(directory && !path.hasSuffix("/") ? "/" : "")
        let allowed = CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        guard let encoded = fullPath.addingPercentEncoding(withAllowedCharacters:allowed) else { throw CommanderError.message("FTP-Pfad kann nicht kodiert werden.") }
        url.percentEncodedPath = encoded
        guard let address = url.url?.absoluteString else { throw CommanderError.message("Ungültige FTP-Adresse.") }
        func configQuote(_ value:String)->String { value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"") }
        let config = "user = \""+configQuote(connection.user+":"+connection.password)+"\"\n"
        var arguments = ["--disable","--config","-","--silent","--show-error","--fail","--connect-timeout","15","--max-time","3600","--proto","=ftp","--ftp-pasv","--globoff"]
        if connection.kind == .ftps { arguments.append("--ssl-reqd") }
        arguments += options+[address]
        return try ProcessRunner.run("/usr/bin/curl",arguments:arguments,input:Data(config.utf8),token:token,timeout:3610)
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
                entries.append(RemoteEntry(name:name,isDirectory:type == "dir",isLink:type.contains("slink"),size:Int64(facts["size"] ?? "0") ?? 0)); continue
            }
            guard let match = unix.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)),let t = Range(match.range(at:1),in:line),let s = Range(match.range(at:2),in:line),let n = Range(match.range(at:3),in:line) else { unparsed += 1; continue }
            let type = String(line[t]); var name = String(line[n])
            if type == "l",let arrow = name.range(of:" -> ",options:.backwards) { name = String(name[..<arrow.lowerBound]) }
            if name == "." || name == ".." { continue }
            guard !name.contains("/"),!name.isEmpty else { unparsed += 1; continue }
            entries.append(RemoteEntry(name:name,isDirectory:type == "d",isLink:type == "l",size:Int64(line[s]) ?? 0))
        }
        guard unparsed == 0 else { throw CommanderError.message("Server-Dateiliste enthält \(unparsed) nicht lesbare Zeilen. Das Listenformat wird nicht vollständig unterstützt; es wurden keine Transfers ausgeführt.") }
        return entries.sorted { a,b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    public static func list(_ connection:RemoteConnection,path:String,token:CancellationToken = .init()) throws -> [RemoteEntry] {
        if connection.kind == .sftp { return try parseListing(sftp(connection,commands:["ls -la "+batchQuote(path)],token:token),mlsd:false) }
        do { return try parseListing(ftp(connection,path:path,directory:true,options:["--request","MLSD"],token:token),mlsd:true) }
        catch { try token.check(); return try parseListing(ftp(connection,path:path,directory:true,token:token),mlsd:false) }
    }
    public static func child(_ path:String,_ name:String) -> String { (path.hasSuffix("/") ? path : path+"/")+name }
    public static func download(_ connection:RemoteConnection,path:String,entry:RemoteEntry,to directory:URL,token:CancellationToken = .init()) throws -> URL {
        try FileSystem.validateName(entry.name)
        guard !entry.isDirectory,!entry.isLink else { throw CommanderError.message("Remote-Transfers unterstützen hier reguläre Einzeldateien. Für rekursive SFTP-Transfers den Terminalzugang verwenden.") }
        let dest = directory.appendingPathComponent(entry.name)
        guard !FileSystem.exists(dest) else { throw CommanderError.message("Lokales Ziel existiert bereits: "+entry.name) }
        let staging = directory.appendingPathComponent(".zweicommander-download-"+UUID().uuidString)
        defer { if FileSystem.exists(staging) { try? FileManager.default.removeItem(at:staging) } }
        let remote = child(path,entry.name)
        if connection.kind == .sftp { _ = try sftp(connection,commands:["get -p "+batchQuote(remote)+" "+batchQuote(staging.path)],token:token) }
        else { _ = try ftp(connection,path:remote,directory:false,options:["--output",staging.path],token:token) }
        try token.check()
        guard try FileEntry(url:staging).size == entry.size else { throw CommanderError.message("Heruntergeladene Dateigröße stimmt nicht mit der Liste überein. Bitte die Serverliste aktualisieren.") }
        try FileManager.default.moveItem(at:staging,to:dest)
        return dest
    }
    public static func upload(_ connection:RemoteConnection,source:URL,path:String,token:CancellationToken = .init()) throws {
        let entry = try FileEntry(url:source)
        guard entry.isRegularFile else { throw CommanderError.message("Bitte reguläre Einzeldateien zum Hochladen auswählen.") }
        try validatePath(source.lastPathComponent)
        let existing = try list(connection,path:path,token:token)
        guard !existing.contains(where:{$0.name.caseInsensitiveCompare(source.lastPathComponent) == .orderedSame}) else { throw CommanderError.message("Remote-Ziel ist bereits belegt: "+source.lastPathComponent) }
        let remote = child(path,source.lastPathComponent)
        if connection.kind == .sftp { _ = try sftp(connection,commands:["put -p "+batchQuote(source.path)+" "+batchQuote(remote)],token:token) }
        else { _ = try ftp(connection,path:remote,directory:false,options:["--upload-file",source.path],token:token) }
    }
}
