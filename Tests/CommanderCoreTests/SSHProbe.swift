import Foundation
import CommanderCore
import Darwin

func runSSHProbeIfRequested() {
    guard let index = CommandLine.arguments.firstIndex(of:"--ssh-probe"),CommandLine.arguments.indices.contains(index+1) else { return }
    guard let real = realpath(CommandLine.arguments[index+1],nil) else { print("SSH PROBE FAIL fixture directory unavailable");exit(1) }
    let root = URL(fileURLWithPath:String(cString:real)),server = root.appendingPathComponent("Server");free(real)
    var checks = 0
    func check(_ value: Bool,_ text: String) throws {
        guard value else { throw CommanderError.message(text) };checks += 1;print("SSH PROBE PASS "+text)
    }
    func rejects(_ body: () throws -> Void) -> Bool { do { try body();return false } catch { return true } }
    func authEvents() -> Int { (try? String(contentsOf:server.appendingPathComponent(".auth-events"),encoding:.utf8))?.split(separator:"\n").count ?? 0 }
    do {
        guard let port = Int(try String(contentsOf:server.appendingPathComponent("port.txt"),encoding:.utf8)) else { throw CommanderError.message("SSH fixture port missing") }
        let connection = try RemoteConnection(kind:.sftp,host:"127.0.0.1",user:"fixture",port:port,identityFile:root.appendingPathComponent("client"),knownHostsFile:server.appendingPathComponent("known_hosts"))
        var unknown = connection;unknown.knownHostsFile = root.appendingPathComponent("missing_hosts")
        try check(rejects { _ = try RemoteService.list(unknown,path:server.path) } && authEvents() == 0,"unknown host refused before authentication")
        var changed = connection;changed.knownHostsFile = server.appendingPathComponent("wrong_hosts")
        try check(rejects { _ = try RemoteService.list(changed,path:server.path) } && authEvents() == 0,"changed host key refused before authentication")
        var wrong = connection;wrong.identityFile = root.appendingPathComponent("wrong_client")
        try check(rejects { _ = try RemoteService.list(wrong,path:server.path) },"wrong client key refused")
        let session = try RemoteService.transport(connection)
        try check(try session.list(server.path).contains { $0.name == "Initial.txt" },"native SSH authenticates and reads the real system SFTP server")
        let source = root.appendingPathComponent("Local/Projekt"),download = root.appendingPathComponent("Download")
        try FileManager.default.createDirectory(at:source.appendingPathComponent("Leer"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:download,withIntermediateDirectories:true)
        try Data("Encrypted SSH content ✔\n".utf8).write(to:source.appendingPathComponent("Grüße.txt"));try Data().write(to:source.appendingPathComponent("Null.bin"))
        _ = try RemotePlanner.execute(RemotePlanner.upload(session,sources:[source],to:server.path),using:session)
        try check(try Checksums.hash(source.appendingPathComponent("Grüße.txt")) == Checksums.hash(server.appendingPathComponent("Projekt/Grüße.txt")),"recursive upload crosses the encrypted SSH connection with exact content")
        let entry = try session.list(server.path).first { $0.name == "Projekt" }!
        _ = try RemotePlanner.execute(RemotePlanner.download(session,entries:[entry],path:server.path,to:download),using:session)
        try check(try Checksums.hash(download.appendingPathComponent("Projekt/Grüße.txt")) == Checksums.hash(source.appendingPathComponent("Grüße.txt")) && FileSystem.isDirectory(download.appendingPathComponent("Projekt/Leer")),"recursive download preserves content and empty folders over SSH")
        try RemoteMutation.execute(RemoteMutation.prepare(session,kind:.createDirectory,directory:server.path,newName:"Neuer Ordner"),using:session)
        let new = try session.list(server.path).first { $0.name == "Neuer Ordner" }!
        try RemoteMutation.execute(RemoteMutation.prepare(session,kind:.rename,directory:server.path,entries:[new],newName:"Umbenannt"),using:session)
        try check(FileSystem.isDirectory(server.appendingPathComponent("Umbenannt")),"mkdir and rename use SFTP through the authenticated SSH connection")
        try RemoteMutation.execute(RemoteMutation.prepare(session,kind:.delete,directory:server.path,entries:[entry]),using:session)
        try check(!FileSystem.exists(server.appendingPathComponent("Projekt")) && FileSystem.exists(source.appendingPathComponent("Grüße.txt")),"reviewed recursive deletion preserves local sources")
        let large = source.appendingPathComponent("Abbruch.bin");try Data(repeating:73,count:2*1024*1024).write(to:large)
        let token = CancellationToken(),cancellable = try RemoteService.transport(connection,token:token),plan = try RemotePlanner.upload(cancellable,sources:[large],to:server.path,token:token)
        let cancelled = rejects { _ = try RemotePlanner.execute(plan,using:cancellable,token:token,progress:{ if $0.bytes > 0 { token.cancel() } }) }
        let size = try FileEntry(url:server.appendingPathComponent("Abbruch.bin")).size
        try check(cancelled && size > 0 && size < plan.bytes,"cancellation interrupts an actual encrypted SSH upload within the file")
        print("SSH PROBE PASS \(checks) checks");exit(0)
    } catch { print("SSH PROBE FAIL "+error.localizedDescription);exit(1) }
}
