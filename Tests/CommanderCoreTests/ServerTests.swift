import Foundation
import CommanderCore
import Darwin

private final class MutationObserver: RemoteTransport {
    let underlying: RemoteTransport
    var endpointID: String
    var afterRemove: (()->Void)?
    init(_ underlying: RemoteTransport,endpoint: String? = nil) { self.underlying = underlying;endpointID = endpoint ?? underlying.endpointID }
    func list(_ path:String) throws -> [RemoteEntry] { try underlying.list(path) }
    func mkdir(_ path:String) throws { try underlying.mkdir(path) }
    func rename(_ source:String,to target:String) throws { try underlying.rename(source,to:target) }
    func remove(_ path:String,directory:Bool) throws { try underlying.remove(path,directory:directory);afterRemove?() }
    func upload(_ fd:Int32,size:Int64,to path:String,progress:@escaping(Int64)->Void) throws { try underlying.upload(fd,size:size,to:path,progress:progress) }
    func download(_ path:String,to fd:Int32,size:Int64,progress:@escaping(Int64)->Void) throws { try underlying.download(path,to:fd,size:size,progress:progress) }
}

extension CoreTests {
    private func serverDirectory() throws -> URL {
        let path = try folder("server")
        guard let real = realpath(path.path,nil) else { throw CommanderError.message("Synthetic server directory unavailable") }
        defer { free(real) };return URL(fileURLWithPath:String(cString:real))
    }
    func testServerMutationsRejectLinkedDirectoryAncestors() throws {
        let server = try serverDirectory();try file("server/Tree/one","keep")
        let alias = root.appendingPathComponent("alias");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:server)
        let session = try RemoteService.localSFTP(directory:server),entry = try session.list(server.path).first!
        XCTAssertThrowsError(try RemoteMutation.prepare(session,kind:.delete,directory:alias.path,entries:[entry]))
        XCTAssertThrowsError(try RemoteMutation.prepare(session,kind:.createDirectory,directory:alias.appendingPathComponent("Tree").path,newName:"New"))
        XCTAssertEqual(try read(server.appendingPathComponent("Tree/one")),"keep")
    }
    func testServerMutationsRejectReplacedParentAfterPreview() throws {
        let server = try serverDirectory(),directory = try folder("server/Target"),outside = try folder("outside"),session = try RemoteService.localSFTP(directory:server)
        let plan = try RemoteMutation.prepare(session,kind:.createDirectory,directory:server.appendingPathComponent("Target").path,newName:"New")
        try FileManager.default.moveItem(at:directory,to:server.appendingPathComponent("Old"));try FileManager.default.createSymbolicLink(at:directory,withDestinationURL:outside)
        XCTAssertThrowsError(try RemoteMutation.execute(plan,using:session));XCTAssertFalse(FileSystem.exists(outside.appendingPathComponent("New")))
    }
    private func mutationRoundTrip(_ session: RemoteTransport,path: String) throws {
        let create = try RemoteMutation.prepare(session,kind:.createDirectory,directory:path,newName:"Grüße ;type=a")
        XCTAssertFalse(try session.list(path).contains { $0.name == "Grüße ;type=a" })
        try RemoteMutation.execute(create,using:session)
        let entry = try session.list(path).first { $0.name == "Grüße ;type=a" }!
        let rename = try RemoteMutation.prepare(session,kind:.rename,directory:path,entries:[entry],newName:"Neuer Name")
        try RemoteMutation.execute(rename,using:session)
        let renamed = try session.list(path).first { $0.name == "Neuer Name" }!
        try RemoteMutation.execute(RemoteMutation.prepare(session,kind:.delete,directory:path,entries:[renamed]),using:session)
        XCTAssertFalse(try session.list(path).contains { $0.name == "Neuer Name" })
    }
    func testServerSFTPMkdirRenameAndDelete() throws {
        let server = try serverDirectory();try mutationRoundTrip(RemoteService.localSFTP(directory:server),path:server.path)
    }
    func testServerFTPMkdirRenameAndDelete() throws {
        let fixture = try FTPFixture(root:folder("server"));try mutationRoundTrip(RemoteService.transport(fixture.connection),path:"/")
    }
    func testServerFTPSMkdirRenameAndDelete() throws {
        let fixture = try FTPFixture(root:folder("server"),tls:true);try mutationRoundTrip(RemoteService.transport(fixture.connection),path:"/")
    }
    func testServerDeleteReviewsCompleteTreeBeforeChangingIt() throws {
        let server = try serverDirectory();try file("server/Tree/Sub/Grüße.txt","keep until execution");try file("server/Tree/zero","");try folder("server/Tree/Empty");try file("server/Outside.txt","outside")
        let session = try RemoteService.localSFTP(directory:server),tree = try session.list(server.path).first { $0.name == "Tree" }!
        let plan = try RemoteMutation.prepare(session,kind:.delete,directory:server.path,entries:[tree])
        XCTAssertEqual(plan.files,2);XCTAssertEqual(plan.folders,3);XCTAssertTrue(FileSystem.exists(server.appendingPathComponent("Tree/Sub/Grüße.txt")))
        var done = 0;try RemoteMutation.execute(plan,using:session,progress:{ count,total,_ in done = count;XCTAssertEqual(total,5) })
        XCTAssertEqual(done,5);XCTAssertFalse(FileSystem.exists(server.appendingPathComponent("Tree")));XCTAssertEqual(try read(server.appendingPathComponent("Outside.txt")),"outside")
    }
    func testServerDeleteRejectsNewEntriesBeforeFirstChange() throws {
        let server = try serverDirectory();try file("server/Tree/old.txt","old")
        let session = try RemoteService.localSFTP(directory:server),tree = try session.list(server.path).first!
        let plan = try RemoteMutation.prepare(session,kind:.delete,directory:server.path,entries:[tree])
        try file("server/Tree/new.txt","new")
        XCTAssertThrowsError(try RemoteMutation.execute(plan,using:session));XCTAssertEqual(try read(server.appendingPathComponent("Tree/old.txt")),"old");XCTAssertEqual(try read(server.appendingPathComponent("Tree/new.txt")),"new")
    }
    func testServerRenameRejectsChangedSourceAndOccupiedTarget() throws {
        let server = try serverDirectory(),source = try file("server/source.txt","old");try file("server/occupied.txt","occupied")
        let session = try RemoteService.localSFTP(directory:server),entry = try session.list(server.path).first { $0.name == "source.txt" }!
        XCTAssertThrowsError(try RemoteMutation.prepare(session,kind:.rename,directory:server.path,entries:[entry],newName:"OCCUPIED.txt"))
        let plan = try RemoteMutation.prepare(session,kind:.rename,directory:server.path,entries:[entry],newName:"renamed.txt")
        try Data("changed content".utf8).write(to:source)
        XCTAssertThrowsError(try RemoteMutation.execute(plan,using:session));XCTAssertTrue(FileSystem.exists(source));XCTAssertFalse(FileSystem.exists(server.appendingPathComponent("renamed.txt")))
    }
    func testServerCreateRefusesNamesAddedAfterPreview() throws {
        let server = try serverDirectory(),session = try RemoteService.localSFTP(directory:server)
        let plan = try RemoteMutation.prepare(session,kind:.createDirectory,directory:server.path,newName:"New")
        try file("server/New","keep")
        XCTAssertThrowsError(try RemoteMutation.execute(plan,using:session));XCTAssertEqual(try read(server.appendingPathComponent("New")),"keep")
    }
    func testServerMutationRejectsInvalidNamesAndCaseOnlyRename() throws {
        let server = try serverDirectory();try file("server/name.txt")
        let session = try RemoteService.localSFTP(directory:server),entry = try session.list(server.path).first!
        for name in ["..","a/b","bad\r\nDELE name.txt",String(repeating:"x",count:256)] { XCTAssertThrowsError(try RemoteMutation.prepare(session,kind:.createDirectory,directory:server.path,newName:name)) }
        XCTAssertThrowsError(try RemoteMutation.prepare(session,kind:.rename,directory:server.path,entries:[entry],newName:"NAME.txt"))
        XCTAssertTrue(FileSystem.exists(server.appendingPathComponent("name.txt")))
    }
    func testServerDeleteRefusesLinksAtAnyDepth() throws {
        let server = try serverDirectory();try file("outside","private");try folder("server/Tree")
        try FileManager.default.createSymbolicLink(at:server.appendingPathComponent("Tree/link"),withDestinationURL:root.appendingPathComponent("outside"))
        let session = try RemoteService.localSFTP(directory:server),tree = try session.list(server.path).first!
        XCTAssertThrowsError(try RemoteMutation.prepare(session,kind:.delete,directory:server.path,entries:[tree]));XCTAssertTrue(FileSystem.exists(server.appendingPathComponent("Tree/link")));XCTAssertEqual(try read(root.appendingPathComponent("outside")),"private")
    }
    func testServerMutationRejectsDifferentEndpointAndCancellation() throws {
        let server = try serverDirectory();try file("server/one","1")
        let session = try RemoteService.localSFTP(directory:server),entry = try session.list(server.path).first!
        let plan = try RemoteMutation.prepare(session,kind:.delete,directory:server.path,entries:[entry])
        XCTAssertThrowsError(try RemoteMutation.execute(plan,using:MutationObserver(session,endpoint:"other")))
        let token = CancellationToken();token.cancel();XCTAssertThrowsError(try RemoteMutation.execute(plan,using:session,token:token));XCTAssertTrue(FileSystem.exists(server.appendingPathComponent("one")))
    }
    func testServerDeletePreservesNewFilesAppearingDuringExecution() throws {
        let server = try serverDirectory();try file("server/Tree/old","old")
        let session = try RemoteService.localSFTP(directory:server),tree = try session.list(server.path).first!,observer = MutationObserver(session)
        let plan = try RemoteMutation.prepare(session,kind:.delete,directory:server.path,entries:[tree])
        observer.afterRemove = { try! Data("new".utf8).write(to:server.appendingPathComponent("Tree/new")) }
        XCTAssertThrowsError(try RemoteMutation.execute(plan,using:observer));XCTAssertEqual(try read(server.appendingPathComponent("Tree/new")),"new");XCTAssertTrue(FileSystem.isDirectory(server.appendingPathComponent("Tree")))
    }
    func testServerDeleteCanCancelBetweenReviewedObjects() throws {
        let server = try serverDirectory();try file("server/one");try file("server/two")
        let session = try RemoteService.localSFTP(directory:server),plan = try RemoteMutation.prepare(session,kind:.delete,directory:server.path,entries:session.list(server.path)),token = CancellationToken()
        XCTAssertThrowsError(try RemoteMutation.execute(plan,using:session,token:token,progress:{ _,_,_ in token.cancel() }))
        XCTAssertEqual(try session.list(server.path).count,1)
    }
    func testServerDeleteDepthLimitChangesNoFiles() throws {
        let server = try serverDirectory(),deep = (0..<101).map { _ in "d" }.joined(separator:"/");try folder("server/"+deep)
        let session = try RemoteService.localSFTP(directory:server),entry = try session.list(server.path).first!
        XCTAssertThrowsError(try RemoteMutation.prepare(session,kind:.delete,directory:server.path,entries:[entry]));XCTAssertTrue(FileSystem.isDirectory(server.appendingPathComponent(deep)))
    }
    func testServerEntriesNeverAliasLocalFileMetadata() throws {
        let local = try file("local.txt","local private data"),connection = try RemoteConnection(kind:.sftp,host:"server.example",user:"fixture",port:22),url = connection.address(local.path)
        let entry = FileEntry(remote:RemoteEntry(name:"local.txt",isDirectory:false,size:42),address:url)
        XCTAssertEqual(entry.size,42);XCTAssertEqual(entry.kind,"Serverdatei");XCTAssertFalse(entry.url.isFileURL)
        XCTAssertThrowsError(try FileEntry(url:url));XCTAssertFalse(FileSystem.exists(url));XCTAssertFalse(FileSystem.isDirectory(url));XCTAssertEqual(FileSystem.canonical(url),url)
        XCTAssertEqual(try read(local),"local private data")
    }
}
