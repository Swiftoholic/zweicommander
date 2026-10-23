import Foundation
import Darwin

private struct SFTPReader {
    let data: Data
    var offset = 0
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0,offset <= data.count-count else { throw CommanderError.message("Unvollständige SFTP-Antwort.") }
        defer { offset += count };return data.subdata(in:offset..<offset+count)
    }
    mutating func byte() throws -> UInt8 { try bytes(1).first! }
    mutating func uint() throws -> UInt32 { try bytes(4).reduce(0) { ($0 << 8)|UInt32($1) } }
    mutating func large() throws -> UInt64 { try bytes(8).reduce(0) { ($0 << 8)|UInt64($1) } }
    mutating func string() throws -> Data { try bytes(Int(uint())) }
    mutating func text() throws -> String {
        guard let text = String(data:try string(),encoding:.utf8) else { throw CommanderError.message("SFTP-Dateiname ist nicht als UTF-8 lesbar.") };return text
    }
    mutating func entry(_ name: String) throws -> RemoteEntry {
        let flags = try uint();var size: UInt64 = 0,owner = "",mode: UInt32 = 0,time: UInt32 = 0
        guard flags & ~UInt32(0x8000000f) == 0 else { throw CommanderError.message("Unbekannte SFTP-Dateiattribute.") }
        if flags & 1 != 0 { size = try large() }
        if flags & 2 != 0 { owner = "\(try uint()):\(try uint())" }
        if flags & 4 != 0 { mode = try uint() }
        if flags & 8 != 0 { _ = try uint();time = try uint() }
        if flags & 0x80000000 != 0 {
            let count = try uint();guard count <= 64 else { throw CommanderError.message("Zu viele SFTP-Zusatzattribute.") }
            for _ in 0..<count { _ = try string();_ = try string() }
        }
        guard size <= Int64.max,flags & 4 != 0 else { throw CommanderError.message("SFTP-Dateityp oder Größe nicht unterstützt.") }
        let type = mode & 0o170000
        guard type != 0o100000 || flags & 1 != 0 else { throw CommanderError.message("SFTP-Dateigröße fehlt.") }
        return RemoteEntry(name:name,isDirectory:type == 0o040000,isLink:type != 0o040000 && type != 0o100000,size:type == 0o040000 ? 0 : Int64(size),version:"\(mode):\(time):"+owner)
    }
}
private extension Data {
    mutating func sftpUInt(_ value: UInt32) { append(contentsOf:[UInt8(truncatingIfNeeded:value >> 24),UInt8(truncatingIfNeeded:value >> 16),UInt8(truncatingIfNeeded:value >> 8),UInt8(truncatingIfNeeded:value)]) }
    mutating func sftpLarge(_ value: UInt64) { sftpUInt(UInt32(truncatingIfNeeded:value >> 32));sftpUInt(UInt32(truncatingIfNeeded:value)) }
    mutating func sftpString(_ value: Data) { sftpUInt(UInt32(value.count));append(value) }
    mutating func sftpText(_ text: String) { sftpString(Data(text.utf8)) }
}

/// SFTP v3 framing over the system SSH client. Key verification and authentication stay with OpenSSH.
final class SFTPTransport: RemoteTransport {
    let endpointID: String,token: CancellationToken
    private let process = Process(),input = Pipe(),output = Pipe()
    private let errorURL: URL,errorHandle: FileHandle
    private var sequence: UInt32 = 0
    private var closed = false
    convenience init(_ connection: RemoteConnection,token: CancellationToken) throws {
        var arguments = ["-T","-oBatchMode=yes","-oStrictHostKeyChecking=yes","-oConnectTimeout=15","-oClearAllForwardings=yes","-oPermitLocalCommand=no","-p",String(connection.port),"-l",connection.user]
        if let key = connection.identityFile { arguments += ["-i",key.path,"-oIdentitiesOnly=yes"] }
        if let hosts = connection.knownHostsFile { arguments += ["-oUserKnownHostsFile="+hosts.path] }
        arguments += ["-s",connection.host,"sftp"]
        try self.init(executable:URL(fileURLWithPath:"/usr/bin/ssh"),arguments:arguments,endpointID:connection.endpointID,token:token)
    }
    // The package tests use the system's real sftp-server over pipes, without opening an SSH listener.
    package init(executable: URL,arguments: [String],endpointID: String,token: CancellationToken) throws {
        self.endpointID = endpointID;self.token = token
        errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("zwei-ssh-"+UUID().uuidString)
        let descriptor = open(errorURL.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard descriptor >= 0 else { throw CommanderError.message("Private SFTP-Diagnoseablage konnte nicht angelegt werden.") }
        errorHandle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        process.executableURL = executable;process.arguments = arguments;process.standardInput = input;process.standardOutput = output;process.standardError = errorHandle
        do {
            try token.check();try process.run()
            try input.fileHandleForReading.close();try output.fileHandleForWriting.close()
            for fd in [input.fileHandleForWriting.fileDescriptor,output.fileHandleForReading.fileDescriptor] { _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK) }
            _ = fcntl(input.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
            var initPacket = Data([1]);initPacket.sftpUInt(3);try send(initPacket)
            var response = SFTPReader(data:try receive())
            guard try response.byte() == 2,try response.uint() == 3 else { throw CommanderError.message("Der Server bietet SFTP Version 3 nicht an.") }
        } catch { close();throw error }
    }
    deinit { close() }
    private func close() {
        guard !closed else { return };closed = true
        try? input.fileHandleForWriting.close();try? output.fileHandleForReading.close()
        if process.isRunning {
            process.terminate();let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.02) }
            if process.isRunning { kill(process.processIdentifier,SIGKILL) };process.waitUntilExit()
        }
        try? errorHandle.close();try? FileManager.default.removeItem(at:errorURL)
    }
    private func failure() -> CommanderError {
        let text = (try? Data(contentsOf:errorURL)).map { String(decoding:$0.prefix(4096),as:UTF8.self) } ?? ""
        return .message("SFTP-Verbindung beendet. SSH-Schlüssel/Agent und bekannten Hostschlüssel prüfen.\n"+text)
    }
    private func io(_ data: Data?,count: Int) throws -> Data {
        let fd = data == nil ? output.fileHandleForReading.fileDescriptor : input.fileHandleForWriting.fileDescriptor
        var buffer = [UInt8](repeating:0,count:count),offset = 0,idle: TimeInterval = 0
        while offset < count {
            try token.check()
            guard ((try? FileEntry(url:errorURL).size) ?? 0) <= 1024*1024 else { throw CommanderError.message("SFTP-Diagnoseausgabe zu groß.") }
            var descriptor = pollfd(fd:fd,events:Int16(data == nil ? POLLIN : POLLOUT),revents:0)
            let before = Date();let ready = poll(&descriptor,1,50);idle += Date().timeIntervalSince(before)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0,idle < 30 else { throw CommanderError.message("SFTP antwortet nicht innerhalb von 30 Sekunden.") }
            if ready == 0 { continue }
            let amount: Int = buffer.withUnsafeMutableBytes { raw in
                if let data { return data.withUnsafeBytes { Darwin.write(fd,$0.baseAddress!.advanced(by:offset),count-offset) } }
                return Darwin.read(fd,raw.baseAddress!.advanced(by:offset),count-offset)
            }
            if amount < 0 && [EAGAIN,EINTR].contains(errno) { continue }
            guard amount > 0 else { throw failure() };offset += amount;idle = 0
        }
        return Data(buffer)
    }
    private func send(_ packet: Data) throws { var data = Data();data.sftpUInt(UInt32(packet.count));data.append(packet);_ = try io(data,count:data.count) }
    private func receive() throws -> Data {
        var header = SFTPReader(data:try io(nil,count:4));let size = Int(try header.uint())
        guard size >= 1,size <= 2*1024*1024 else { throw CommanderError.message("Ungültige SFTP-Paketgröße.") };return try io(nil,count:size)
    }
    private func request(_ type: UInt8,_ payload: Data) throws -> (UInt8,SFTPReader) {
        try token.check();sequence &+= 1
        var packet = Data([type]);packet.sftpUInt(sequence);packet.append(payload);try send(packet)
        var reader = SFTPReader(data:try receive());let type = try reader.byte()
        guard try reader.uint() == sequence else { throw CommanderError.message("SFTP-Antwort gehört zu einem anderen Auftrag.") }
        return (type,reader)
    }
    private func status(_ response: (UInt8,SFTPReader),eof: Bool = false) throws -> Bool {
        guard response.0 == 101 else { throw CommanderError.message("Unerwartete SFTP-Antwort.") }
        var reader = response.1;let code = try reader.uint()
        if code == 0 { return false };if eof && code == 1 { return true }
        let message = (try? reader.text()) ?? ""
        throw CommanderError.message("SFTP-Anfrage fehlgeschlagen (\(code)): "+message)
    }
    private func handle(_ type: UInt8,_ payload: Data) throws -> Data {
        let response = try request(type,payload);var reader = response.1
        guard response.0 == 102 else { _ = try status(response);throw CommanderError.message("SFTP-Datei konnte nicht geöffnet werden.") }
        let value = try reader.string();guard value.count <= 4096 else { throw CommanderError.message("SFTP-Dateihandle zu groß.") };return value
    }
    private func closeHandle(_ value: Data) throws { var payload = Data();payload.sftpString(value);_ = try status(request(4,payload)) }
    func list(_ path: String) throws -> [RemoteEntry] {
        var payload = Data();payload.sftpText(try RemoteService.normalized(path))
        let directory = try handle(11,payload);defer { try? closeHandle(directory) }
        payload = Data();payload.sftpString(directory);var rows: [RemoteEntry] = []
        while true {
            let response = try request(12,payload)
            if response.0 == 101 { guard try status(response,eof:true) else { throw CommanderError.message("SFTP-Liste hat keinen Abschluss.") };break }
            guard response.0 == 104 else { throw CommanderError.message("Unerwartete SFTP-Dateiliste.") }
            var reader = response.1;let count = try reader.uint()
            guard count > 0,count <= 10000,rows.count+Int(count) <= 10002 else { throw CommanderError.message("SFTP-Dateiliste ist zu groß oder leer ohne Abschluss.") }
            for _ in 0..<count {
                let name = try reader.text();_ = try reader.string();let entry = try reader.entry(name)
                if name == "." || name == ".." { continue };try FileSystem.validateName(name);try RemoteService.validatePath(name);rows.append(entry)
            }
        }
        guard Set(rows.map(\.name)).count == rows.count else { throw CommanderError.message("Doppelte SFTP-Dateinamen.") }
        return rows.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func mkdir(_ path: String) throws {
        var payload = Data();payload.sftpText(try RemoteService.normalized(path));payload.sftpUInt(4);payload.sftpUInt(0o700)
        _ = try status(request(14,payload))
    }
    func download(_ path: String,to descriptor: Int32,size: Int64,progress: @escaping (Int64)->Void) throws {
        var payload = Data();payload.sftpText(try RemoteService.normalized(path));payload.sftpUInt(1);payload.sftpUInt(0)
        let file = try handle(3,payload);defer { try? closeHandle(file) };var offset: Int64 = 0
        while offset < size {
            payload = Data();payload.sftpString(file);payload.sftpLarge(UInt64(offset));payload.sftpUInt(UInt32(min(32768,size-offset)))
            let response = try request(5,payload)
            guard response.0 == 103 else { _ = try status(response);throw CommanderError.message("SFTP-Datei ist kürzer als geplant.") }
            var reader = response.1;let data = try reader.string()
            guard !data.isEmpty,data.count <= min(32768,size-offset) else { throw CommanderError.message("Ungültige SFTP-Dateidaten.") }
            var written = 0
            try data.withUnsafeBytes { raw in
                while written < data.count { try token.check();let count = Darwin.write(descriptor,raw.baseAddress!.advanced(by:written),data.count-written);if count < 0 && errno == EINTR { continue };guard count > 0 else { throw CommanderError.message("Download kann nicht geschrieben werden.") };written += count }
            }
            offset += Int64(data.count);progress(offset);try token.check()
        }
        payload = Data();payload.sftpString(file);payload.sftpLarge(UInt64(size));payload.sftpUInt(1)
        let end = try request(5,payload)
        guard end.0 == 101,try status(end,eof:true) else { throw CommanderError.message("SFTP-Datei ist länger als geplant.") }
    }
    func upload(_ descriptor: Int32,size: Int64,to path: String,progress: @escaping (Int64)->Void) throws {
        var payload = Data();payload.sftpText(try RemoteService.normalized(path));payload.sftpUInt(2|8|32);payload.sftpUInt(4);payload.sftpUInt(0o600)
        let file = try handle(3,payload);var handleClosed = false;defer { if !handleClosed { try? closeHandle(file) } };var offset: Int64 = 0,buffer = [UInt8](repeating:0,count:32768)
        while offset < size {
            try token.check();let count = Darwin.read(descriptor,&buffer,Int(min(32768,size-offset)))
            if count < 0 && errno == EINTR { continue };guard count > 0 else { throw CommanderError.message("Uploadquelle ist kürzer als geplant.") }
            payload = Data();payload.sftpString(file);payload.sftpLarge(UInt64(offset));payload.sftpString(Data(buffer.prefix(count)))
            _ = try status(request(6,payload));offset += Int64(count);progress(offset);try token.check()
        }
        try closeHandle(file);handleClosed = true
    }
}

extension RemoteService {
    package static func localSFTP(directory: URL,token: CancellationToken = .init()) throws -> RemoteTransport {
        try SFTPTransport(executable:URL(fileURLWithPath:"/usr/libexec/sftp-server"),arguments:["-d",directory.path],endpointID:"local-sftp-fixture",token:token)
    }
}
