import Foundation
import CRemote

private struct FTPRequestFailure: LocalizedError {
    let code: Int32,text: String
    var errorDescription: String? { "Serveranfrage fehlgeschlagen (\(code)): "+text }
}
private final class FTPProgress {
    let token: CancellationToken,update: (Int64)->Void
    var error: Error?
    init(_ token: CancellationToken,_ update: @escaping (Int64)->Void) { self.token = token;self.update = update }
    func report(_ count: Int64) -> Int32 {
        do { try token.check();update(count);try token.check();return 0 }
        catch { self.error = error;return 1 }
    }
}
final class FTPTransport: RemoteTransport {
    let connection: RemoteConnection,token: CancellationToken
    var endpointID: String { connection.endpointID }
    init(_ connection: RemoteConnection,token: CancellationToken) { self.connection = connection;self.token = token }
    func request(_ path: String,directory: Bool = false,operation: Int32 = 0,command: String = "",fd: Int32 = -1,size: Int64 = 0,progress: @escaping (Int64)->Void = { _ in }) throws -> String {
        let path = try RemoteService.normalized(path)
        var components = URLComponents();components.scheme = "ftp";components.host = connection.host;components.port = connection.port
        let allowed = CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        let full = "/"+path+(directory && !path.hasSuffix("/") ? "/" : "")
        guard let encoded = full.addingPercentEncoding(withAllowedCharacters:allowed) else { throw CommanderError.message("Serverpfad kann nicht kodiert werden.") };components.percentEncodedPath = encoded
        guard let address = components.url?.absoluteString else { throw CommanderError.message("Ungültige Serveradresse.") }
        let bridge = FTPProgress(token,progress)
        var output: UnsafeMutablePointer<CChar>?,length = 0,error = [CChar](repeating:0,count:1024)
        let result = zr_request(address,connection.user,connection.password,connection.kind == .ftps ? 1 : 0,connection.caFile?.path ?? "",operation,command,fd,size,&output,&length,&error,error.count,{ raw,count in
            guard let raw else { return 1 };return Unmanaged<FTPProgress>.fromOpaque(raw).takeUnretainedValue().report(count)
        },Unmanaged.passUnretained(bridge).toOpaque())
        defer { zr_free(output) }
        if let failure = bridge.error { throw failure };try token.check()
        guard result == 0 else {
            var message = String(cString:error)
            if !connection.password.isEmpty { message = message.replacingOccurrences(of:connection.password,with:"••••") }
            throw FTPRequestFailure(code:result,text:message)
        }
        guard let output else { return "" }
        guard let text = String(data:Data(bytes:output,count:length),encoding:.utf8) else { throw CommanderError.message("Server-Dateinamen sind nicht als UTF-8 lesbar.") }
        return text
    }
    func list(_ path: String) throws -> [RemoteEntry] {
        do { return try RemoteService.parseListing(request(path,directory:true,command:"MLSD"),mlsd:true) }
        catch let failure as FTPRequestFailure where ![19,21,22].contains(failure.code) { throw failure }
        catch { try token.check();return try RemoteService.parseListing(request(path,directory:true),mlsd:false) }
    }
    func download(_ path: String,to descriptor: Int32,size: Int64,progress: @escaping (Int64)->Void) throws { _ = try request(path,operation:1,fd:descriptor,size:size,progress:progress) }
    func upload(_ descriptor: Int32,size: Int64,to path: String,progress: @escaping (Int64)->Void) throws { _ = try request(path,operation:2,fd:descriptor,size:size,progress:progress) }
    func mkdir(_ path: String) throws {
        let path = try RemoteService.normalized(path)
        _ = try request("/",directory:true,operation:3,command:"MKD "+path)
    }
}
