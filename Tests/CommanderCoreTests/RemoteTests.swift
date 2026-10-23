import Foundation
import CommanderCore
import Darwin

private final class MemoryPasswords: RemotePasswordStore {
    var values: [String:String] = [:]
    var failSave = false,failRemove = false
    func password(account: String) throws -> String? { values[account] }
    func save(_ password: String,account: String) throws { if failSave { throw CommanderError.message("test keychain write failed") };values[account] = password }
    func remove(account: String) throws { if failRemove { throw CommanderError.message("test keychain delete failed") };values.removeValue(forKey:account) }
}
private final class RemoteTestState: @unchecked Sendable {
    var error: Error?,completed = false,paused = false
}
private final class FTPFixture {
    let process = Process(),connection: RemoteConnection
    init(root: URL,tls: Bool = false,delay: Double = 0,certificateName: String = "DNS:localhost,IP:127.0.0.1",requirePassword: Bool = false) throws {
        let script = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/ftp_server.py")
        var args = [script.path,root.path,"--delay",String(delay)]
        if requirePassword { args += ["--password","synthetic-credential"] }
        var ca: URL?
        if tls {
            let key = root.deletingLastPathComponent().appendingPathComponent("server-key.pem"),cert = root.deletingLastPathComponent().appendingPathComponent("server-cert.pem")
            _ = try ProcessRunner.run("/usr/bin/openssl",arguments:["req","-x509","-newkey","rsa:2048","-nodes","-keyout",key.path,"-out",cert.path,"-days","1","-subj","/CN=localhost","-addext","subjectAltName="+certificateName])
            args += ["--cert",cert.path,"--key",key.path];ca = cert
        }
        process.executableURL = URL(fileURLWithPath:"/usr/bin/python3");process.arguments = args;process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
        try process.run()
        let port = root.appendingPathComponent("port.txt"),deadline = Date().addingTimeInterval(5)
        while !FileSystem.exists(port) && Date() < deadline && process.isRunning { Thread.sleep(forTimeInterval:0.02) }
        connection = try RemoteConnection(kind:tls ? .ftps : .ftp,host:"127.0.0.1",user:"tester",password:"synthetic-credential",port:Int(String(contentsOf:port,encoding:.utf8))!,caFile:ca)
    }
    deinit { if process.isRunning { process.terminate();process.waitUntilExit() } }
}
extension CoreTests {
    func testRemoteProfilesExcludePasswordsAndScopeCredentialsToEndpoint() throws {
        let passwords = MemoryPasswords();var data: Data?
        let store = RemoteProfileStore(passwords:passwords,read:{ data },write:{ data = $0 })
        let connection = try RemoteConnection(kind:.ftps,host:"server.example",user:"tester",port:21)
        let profile = try store.save(name:"Projekt",connection:connection,path:"/upload",remember:true,password:"secret-must-stay-out")
        XCTAssertFalse(String(decoding:data!,as:UTF8.self).contains("secret-must-stay-out"))
        XCTAssertFalse(String(decoding:data!,as:UTF8.self).contains("password"))
        XCTAssertEqual(try store.connection(connection,profile:profile,enteredPassword:"").password,"secret-must-stay-out")
        let other = try RemoteConnection(kind:.ftps,host:"other.example",user:"tester",port:21)
        XCTAssertEqual(try store.connection(other,profile:profile,enteredPassword:"").password,"")
        XCTAssertThrowsError(try store.save(name:"Projekt",connection:other,path:"/",remember:true,password:nil,replacing:profile))
        XCTAssertEqual(try store.library().profile(profile.id),profile)
        XCTAssertThrowsError(try store.connection(connection,profile:profile,enteredPassword:"bad\npassword"))
    }
    func testRemoteProfileStoreRollsBackBothStoresOnWriteFailure() throws {
        let passwords = MemoryPasswords();var data: Data?,fail = false
        let store = RemoteProfileStore(passwords:passwords,read:{ data },write:{ if fail { throw CommanderError.message("test metadata write failed") };data = $0 })
        let connection = try RemoteConnection(kind:.ftps,host:"server.example",user:"tester",port:21)
        let profile = try store.save(name:"Profil",connection:connection,path:"/",remember:true,password:"old")
        let before = data;fail = true
        XCTAssertThrowsError(try store.save(name:"Profil",connection:connection,path:"/new",remember:true,password:"new",replacing:profile))
        XCTAssertEqual(data,before);XCTAssertEqual(passwords.values[profile.credentialAccount],"old")
        fail = false;passwords.failRemove = true
        XCTAssertThrowsError(try store.save(name:"Profil",connection:connection,path:"/new",remember:false,password:nil,replacing:profile))
        XCTAssertEqual(data,before);XCTAssertEqual(passwords.values[profile.credentialAccount],"old")
        passwords.failRemove = false
        let changed = try store.save(name:"Profil",connection:connection,path:"/new",remember:false,password:nil,replacing:profile)
        XCTAssertFalse(changed.usesKeychain);XCTAssertTrue(passwords.values.isEmpty)
    }
    func testRemoteProfileDeletionMissingCredentialsAndStaleEdits() throws {
        let passwords = MemoryPasswords();var data: Data?
        let store = RemoteProfileStore(passwords:passwords,read:{ data },write:{ data = $0 })
        let connection = try RemoteConnection(kind:.ftps,host:"server.example",user:"tester",port:21)
        let old = try store.save(name:"Alt",connection:connection,path:"/",remember:true,password:"value")
        let new = try store.save(name:"Neu",connection:connection,path:"/",remember:true,password:nil,replacing:old)
        XCTAssertThrowsError(try store.remove(old));XCTAssertThrowsError(try store.save(name:"Alt",connection:connection,path:"/",remember:false,password:nil,replacing:old))
        passwords.values.removeAll();XCTAssertThrowsError(try store.connection(connection,profile:new,enteredPassword:""))
        try store.remove(new);XCTAssertTrue(try store.library().profiles.isEmpty)
        data = Data("broken".utf8);let damaged = data
        XCTAssertThrowsError(try store.save(name:"Fresh",connection:connection,path:"/",remember:false,password:nil));XCTAssertEqual(data,damaged)
    }
    func testRemoteProfileValidationNormalizationAndLimit() throws {
        var library = RemoteProfileLibrary();let connection = try RemoteConnection(kind:.sftp,host:"server.example",user:"tester",port:22)
        _ = try library.save(name:"  Grüße  ",connection:connection,path:"/one/../two",usesKeychain:false)
        XCTAssertEqual(library.profiles[0].name,"Grüße");XCTAssertEqual(library.profiles[0].remotePath,"/two")
        XCTAssertThrowsError(try library.save(name:"grüße",connection:connection,path:"/",usesKeychain:false))
        XCTAssertThrowsError(try library.save(name:"Credential",connection:connection,path:"/",usesKeychain:true))
        for n in 1..<50 { _ = try library.save(name:"Profil \(n)",connection:connection,path:"/",usesKeychain:false) }
        XCTAssertThrowsError(try library.save(name:"Overflow",connection:connection,path:"/",usesKeychain:false))
        XCTAssertEqual(try RemoteProfileLibrary(data:library.encoded()),library)
        XCTAssertThrowsError(try RemoteProfileLibrary(data:Data("{\"version\":9,\"profiles\":[]}".utf8)))
    }
    func testRemoteSFTPRecursiveRoundTripWithEmptyFoldersAndUnicode() throws {
        let server = try folder("server"),source = try folder("source/Projekt"),destination = try folder("download")
        try file("source/Projekt/Unterordner/Grüße ;type=a.txt","SFTP bytes ✔");try folder("source/Projekt/Leer");try file("source/Projekt/Null.bin","")
        let session = try RemoteService.localSFTP(directory:server)
        let upload = try RemotePlanner.upload(session,sources:[source],to:server.path)
        var progress: [Int64] = []
        _ = try RemotePlanner.execute(upload,using:session,progress:{ progress.append($0.bytes) })
        XCTAssertEqual(try read(server.appendingPathComponent("Projekt/Unterordner/Grüße ;type=a.txt")),"SFTP bytes ✔")
        XCTAssertTrue(FileSystem.exists(source));XCTAssertEqual(progress.last,upload.bytes)
        let entry = try session.list(server.path).first { $0.name == "Projekt" }!
        let download = try RemotePlanner.download(session,entries:[entry],path:server.path,to:destination)
        _ = try RemotePlanner.execute(download,using:session)
        XCTAssertEqual(try read(destination.appendingPathComponent("Projekt/Unterordner/Grüße ;type=a.txt")),"SFTP bytes ✔")
        XCTAssertTrue(FileSystem.isDirectory(destination.appendingPathComponent("Projekt/Leer")))
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("Projekt/Null.bin")).count,0)
        XCTAssertThrowsError(try RemotePlanner.download(session,entries:[entry],path:server.path,to:destination))
    }
    func testRemoteSFTPExclusiveCreateAndLinkRejection() throws {
        let server = try folder("server"),source = try file("source/file.txt","new"),old = try file("server/file.txt","old")
        let session = try RemoteService.localSFTP(directory:server)
        XCTAssertThrowsError(try RemotePlanner.upload(session,sources:[source],to:server.path))
        let fd = open(source.path,O_RDONLY);defer { close(fd) }
        XCTAssertThrowsError(try session.upload(fd,size:3,to:old.path,progress:{ _ in }))
        XCTAssertEqual(try read(old),"old")
        try FileManager.default.createSymbolicLink(at:server.appendingPathComponent("link"),withDestinationURL:source)
        let link = try session.list(server.path).first { $0.name == "link" }!
        XCTAssertTrue(link.isLink)
        XCTAssertThrowsError(try RemotePlanner.download(session,entries:[link],path:server.path,to:folder("download")))
        XCTAssertThrowsError(try RemotePlanner.upload(session,sources:[server.appendingPathComponent("link")],to:server.path))
    }
    func testRemotePlansRejectChangedSourcesNewEntriesAndCaseCollisions() throws {
        let server = try folder("server"),source = try folder("source/Projekt"),local = try folder("download")
        let file = try file("source/Projekt/a.txt","before"),session = try RemoteService.localSFTP(directory:server)
        XCTAssertThrowsError(try RemotePlanner.upload(session,sources:[source,file],to:server.path))
        let plan = try RemotePlanner.upload(session,sources:[source],to:server.path)
        try Data("edited".utf8).write(to:file)
        XCTAssertThrowsError(try RemotePlanner.execute(plan,using:session));XCTAssertFalse(FileSystem.exists(server.appendingPathComponent("Projekt")))
        try folder("server/Tree");try self.file("server/Tree/a.txt","a")
        let tree = try session.list(server.path).first { $0.name == "Tree" }!
        let download = try RemotePlanner.download(session,entries:[tree],path:server.path,to:local)
        try self.file("server/Tree/new.txt","new")
        XCTAssertThrowsError(try RemotePlanner.execute(download,using:session));XCTAssertFalse(FileSystem.exists(local.appendingPathComponent("Tree")))
        let one = try self.file("one/Same.txt"),two = try self.file("two/same.txt")
        XCTAssertThrowsError(try RemotePlanner.upload(session,sources:[one,two],to:server.path))
    }
    func testRemoteDownloadRejectsReplacedParentAndCancelsWithoutPublication() throws {
        let server = try folder("server"),local = try folder("download")
        let source = server.appendingPathComponent("large.bin");try Data(repeating:71,count:2*1024*1024).write(to:source)
        let session = try RemoteService.localSFTP(directory:server),entry = try session.list(server.path).first!
        let plan = try RemotePlanner.download(session,entries:[entry],path:server.path,to:local)
        try FileManager.default.moveItem(at:local,to:root.appendingPathComponent("old"));try folder("download")
        XCTAssertThrowsError(try RemotePlanner.execute(plan,using:session))
        let token = CancellationToken(),cancellable = try RemoteService.localSFTP(directory:server,token:token)
        let fresh = try RemotePlanner.download(cancellable,entries:[entry],path:server.path,to:local,token:token)
        XCTAssertThrowsError(try RemotePlanner.execute(fresh,using:cancellable,token:token,progress:{ if $0.bytes > 0 { token.cancel() } }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:local.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf:source).count,2*1024*1024)
    }
    func testRemoteSFTPPauseResumeAndCancelInsideFile() throws {
        let server = try folder("server"),source = try file("source/large.bin","")
        try Data(repeating:88,count:2*1024*1024).write(to:source)
        let token = CancellationToken(),state = RemoteTestState(),done = DispatchSemaphore(value:0)
        let session = try RemoteService.localSFTP(directory:server,token:token)
        let plan = try RemotePlanner.upload(session,sources:[source],to:server.path,token:token)
        DispatchQueue.global().async {
            do { _ = try RemotePlanner.execute(plan,using:session,token:token,progress:{ value in if value.bytes > 0 && !state.paused { state.paused = true;token.pause() } });state.completed = true }
            catch { state.error = error };done.signal()
        }
        let deadline = Date().addingTimeInterval(5)
        while !token.isWaitingForResume && Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
        XCTAssertTrue(token.isWaitingForResume)
        let partial = server.appendingPathComponent("large.bin"),before = try FileEntry(url:partial).size
        Thread.sleep(forTimeInterval:0.1);XCTAssertEqual(try FileEntry(url:partial).size,before)
        XCTAssertTrue(before > 0 && before < plan.bytes);token.resume()
        XCTAssertEqual(done.wait(timeout:.now()+10),.success);XCTAssertTrue(state.completed);XCTAssertTrue(state.error == nil)
        XCTAssertEqual(try Checksums.hash(source),try Checksums.hash(partial))
        let cancelled = CancellationToken(),other = try RemoteService.localSFTP(directory:server,token:cancelled)
        let second = try self.file("source/cancel.bin","");try Data(repeating:55,count:1024*1024).write(to:second)
        let cancelPlan = try RemotePlanner.upload(other,sources:[second],to:server.path,token:cancelled)
        XCTAssertThrowsError(try RemotePlanner.execute(cancelPlan,using:other,token:cancelled,progress:{ if $0.bytes > 0 { cancelled.cancel() } }))
        XCTAssertTrue(try FileEntry(url:server.appendingPathComponent("cancel.bin")).size < cancelPlan.bytes)
        XCTAssertTrue(FileSystem.exists(second))
    }
    func testRemoteTLSRefusesPlaintextDowngradeBeforeSendingPassword() throws {
        let server = try folder("server"),fixture = try FTPFixture(root:server)
        let tls = try RemoteConnection(kind:.ftps,host:fixture.connection.host,user:"tester",password:"synthetic",port:fixture.connection.port)
        XCTAssertThrowsError(try RemoteService.list(tls,path:"/"))
        XCTAssertFalse(FileSystem.exists(server.appendingPathComponent(".login-used")))
    }
    func testRemoteFTPSRecursiveTransfersValidateTLSAndBothDataDirections() throws {
        let server = try folder("server"),source = try folder("source/Projekt"),local = try folder("download")
        try file("source/Projekt/Unterordner/Grüße.txt","Encrypted content");try folder("source/Projekt/Leer")
        let fixture = try FTPFixture(root:server,tls:true)
        let session = try RemoteService.transport(fixture.connection)
        let upload = try RemotePlanner.upload(session,sources:[source],to:"/")
        _ = try RemotePlanner.execute(upload,using:session)
        let entry = try session.list("/").first { $0.name == "Projekt" }!
        _ = try RemotePlanner.execute(RemotePlanner.download(session,entries:[entry],path:"/",to:local),using:session)
        XCTAssertEqual(try read(local.appendingPathComponent("Projekt/Unterordner/Grüße.txt")),"Encrypted content")
        XCTAssertTrue(FileSystem.isDirectory(local.appendingPathComponent("Projekt/Leer")))
        XCTAssertTrue(FileSystem.exists(server.appendingPathComponent(".data-tls-used")))
        var untrusted = fixture.connection;untrusted.caFile = nil
        XCTAssertThrowsError(try RemoteService.list(untrusted,path:"/"))
    }
}

extension CoreTests {
    func testRemoteCredentialReplacementNeverReusesSecretsForChangedLogin() throws {
        let passwords = MemoryPasswords();var data: Data?,fail = false
        let store = RemoteProfileStore(passwords:passwords,read:{ data },write:{ if fail { throw CommanderError.message("test write failure") };data = $0 })
        let connection = try RemoteConnection(kind:.ftps,host:"server.example",user:"tester",port:21)
        let old = try store.save(name:"Profil",connection:connection,path:"/",remember:true,password:"old")
        var clear = connection;clear.kind = .ftp
        XCTAssertEqual(try store.connection(clear,profile:old,enteredPassword:"").password,"")
        var changed = connection;changed.user = "different"
        XCTAssertEqual(try store.connection(changed,profile:old,enteredPassword:"").password,"")
        fail = true
        XCTAssertThrowsError(try store.save(name:"Profil",connection:changed,path:"/",remember:true,password:"new",replacing:old))
        XCTAssertEqual(passwords.values.count,1);XCTAssertEqual(passwords.values[old.credentialAccount],"old")
        fail = false
        let updated = try store.save(name:"Profil",connection:changed,path:"/",remember:true,password:"new",replacing:old)
        XCTAssertEqual(passwords.values.count,1);XCTAssertEqual(passwords.values[updated.credentialAccount],"new")
        XCTAssertTrue(passwords.values[old.credentialAccount] == nil)
    }
    func testRemoteFTPSPauseResumeAndCancelInsideDownload() throws {
        let server = try folder("server"),local = try folder("download"),source = server.appendingPathComponent("large.bin")
        try Data(repeating:93,count:2*1024*1024).write(to:source)
        let fixture = try FTPFixture(root:server,tls:true,delay:0.002),token = CancellationToken(),state = RemoteTestState(),done = DispatchSemaphore(value:0)
        let session = try RemoteService.transport(fixture.connection,token:token),entry = try session.list("/").first { $0.name == "large.bin" }!
        let plan = try RemotePlanner.download(session,entries:[entry],path:"/",to:local,token:token)
        DispatchQueue.global().async {
            do { _ = try RemotePlanner.execute(plan,using:session,token:token,progress:{ value in if value.bytes > 0 && !state.paused { state.paused = true;token.pause() } });state.completed = true }
            catch { state.error = error };done.signal()
        }
        let deadline = Date().addingTimeInterval(8)
        while !token.isWaitingForResume && Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
        XCTAssertTrue(token.isWaitingForResume)
        guard let stage = try FileManager.default.contentsOfDirectory(at:local,includingPropertiesForKeys:nil).first else { token.cancel();throw CommanderError.message("FTPS partial missing") }
        let before = try FileEntry(url:stage).size;Thread.sleep(forTimeInterval:0.1)
        XCTAssertEqual(try FileEntry(url:stage).size,before);XCTAssertTrue(before > 0 && before < plan.bytes)
        token.resume();XCTAssertEqual(done.wait(timeout:.now()+15),.success);XCTAssertTrue(state.completed)
        if let error = state.error { throw error }
        XCTAssertEqual(try Checksums.hash(source),try Checksums.hash(local.appendingPathComponent("large.bin")))
        let cancelLocal = try folder("cancel"),cancelToken = CancellationToken(),other = try RemoteService.transport(fixture.connection,token:cancelToken)
        let cancelPlan = try RemotePlanner.download(other,entries:[entry],path:"/",to:cancelLocal,token:cancelToken)
        XCTAssertThrowsError(try RemotePlanner.execute(cancelPlan,using:other,token:cancelToken,progress:{ if $0.bytes > 0 { cancelToken.cancel() } }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:cancelLocal.path).isEmpty)
    }
}

extension CoreTests {
    func testRemoteRejectsUnknownAndOverflowingListingSizes() throws {
        XCTAssertThrowsError(try RemoteService.parseListing("type=file;modify=20261023000000; unknown.bin\r\n",mlsd:true))
        XCTAssertThrowsError(try RemoteService.parseListing("type=file;size=9999999999999999999999; huge.bin\r\n",mlsd:true))
        XCTAssertThrowsError(try RemoteService.parseListing("-rw-r--r-- 1 user group 9999999999999999999999 Oct 23 12:00 huge.bin\n",mlsd:false))
        XCTAssertEqual(try RemoteService.parseListing("type=file;size=0; empty.bin\r\n",mlsd:true).first?.size,0)
    }
    func testRemoteDeletionMetadataFailureRestoresItsCredential() throws {
        let passwords = MemoryPasswords();var data: Data?,fail = false
        let store = RemoteProfileStore(passwords:passwords,read:{ data },write:{ if fail { throw CommanderError.message("test write failed") };data = $0 })
        let connection = try RemoteConnection(kind:.ftps,host:"server.example",user:"tester",port:21)
        let profile = try store.save(name:"Profil",connection:connection,path:"/",remember:true,password:"preserve")
        let before = data;fail = true
        XCTAssertThrowsError(try store.remove(profile));XCTAssertEqual(data,before)
        XCTAssertEqual(passwords.values[profile.credentialAccount],"preserve")
        fail = false;try store.remove(profile);XCTAssertTrue(passwords.values.isEmpty)
    }
}

extension CoreTests {
    func testRemoteTLSRejectsTrustedCertificateForWrongHost() throws {
        let server = try folder("server"),fixture = try FTPFixture(root:server,tls:true,certificateName:"DNS:wrong.example")
        XCTAssertThrowsError(try RemoteService.list(fixture.connection,path:"/"))
        XCTAssertFalse(FileSystem.exists(server.appendingPathComponent(".login-used")))
    }
}

extension CoreTests {
    func testRemoteLoginFailureDoesNotRetryPasswordAsListingFallback() throws {
        let server = try folder("server"),fixture = try FTPFixture(root:server,requirePassword:true)
        var connection = fixture.connection;connection.password = "synthetic-wrong-secret"
        do { _ = try RemoteService.list(connection,path:"/");XCTAssertTrue(false,"Expected login refusal") }
        catch { XCTAssertFalse(error.localizedDescription.contains(connection.password)) }
        XCTAssertEqual(try read(server.appendingPathComponent(".login-count")),"1")
        XCTAssertFalse(FileSystem.exists(server.appendingPathComponent(".login-used")))
    }
}
