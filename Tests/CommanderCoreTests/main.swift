import Foundation
import CommanderCore
import CArchive

let coreTestExecutable = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
setvbuf(stdout,nil,_IOLBF,0)
if CommandLine.arguments.contains("--keychain-probe") {
    var result: Int32 = 0
    let keychain = RemoteKeychain(service:"local.zweicommander.tests."+UUID().uuidString,allowInteraction:false),account = UUID().uuidString
    do {
        defer { try? keychain.remove(account:account) }
        try keychain.save("synthetic-first",account:account)
        guard try keychain.password(account:account) == "synthetic-first" else { throw CommanderError.message("Keychain read mismatch") }
        try keychain.save("synthetic-updated",account:account)
        guard try keychain.password(account:account) == "synthetic-updated" else { throw CommanderError.message("Keychain update mismatch") }
        try keychain.remove(account:account)
        guard try keychain.password(account:account) == nil else { throw CommanderError.message("Keychain cleanup mismatch") }
        print("KEYCHAIN PROBE PASS create/read/update/delete; isolated synthetic entry removed")
    } catch { print("KEYCHAIN PROBE FAIL "+error.localizedDescription);result = 1 }
    exit(result)
}
runRecoveryChildIfRequested()
runFilteredMoveChildIfRequested()
runSSHProbeIfRequested()

final class CoreTests {
    var root:URL!
    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ZweiCommander-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    func tearDownWithError() throws { if let root,FileSystem.exists(root) { try FileManager.default.removeItem(at:root) } }
    @discardableResult func folder(_ path:String) throws -> URL {
        let u = root.appendingPathComponent(path); try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true); return u
    }
    @discardableResult func file(_ path:String,_ text:String = "example") throws -> URL {
        let u = root.appendingPathComponent(path); try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(text.utf8).write(to:u); return u
    }
    func read(_ url:URL) throws -> String { try String(contentsOf:url,encoding:.utf8) }
    func testCopyNeverOverwritesByDefault() throws {
        let source = try file("a/test.txt","new"), dest = try folder("b"), existing = try file("b/test.txt","old")
        let report = FileOperations.transfer([source],to:dest,kind:.copy,policy:.stop)
        XCTAssertEqual(report.errors.count,1); XCTAssertEqual(try read(existing),"old"); XCTAssertEqual(try read(source),"new")
    }
    func testCopyKeepBothAndSkip() throws {
        let source = try file("a/data.txt","new"), dest = try folder("b"); try file("b/data.txt","old")
        let keep = FileOperations.transfer([source],to:dest,kind:.copy,policy:.keepBoth)
        XCTAssertTrue(keep.errors.isEmpty); XCTAssertEqual(try read(dest.appendingPathComponent("data (2).txt")),"new")
        let skip = FileOperations.transfer([source],to:dest,kind:.copy,policy:.skip)
        XCTAssertEqual(skip.skipped,[source]); XCTAssertEqual(skip.completed.count,0)
    }
    func testReplaceKeepsRecoverableBackup() throws {
        let source = try file("a/data.txt","new"), dest = try folder("b"); try file("b/data.txt","old")
        let result = FileOperations.transfer([source],to:dest,kind:.copy,policy:.replace)
        XCTAssertTrue(result.errors.isEmpty); XCTAssertEqual(try read(result.completed[0]),"new")
        XCTAssertNotNil(result.undo.first?.backup); XCTAssertEqual(try read(result.undo[0].backup!),"old")
    }
    func testMovePreservesContentAndRemovesSource() throws {
        let source = try file("a/move.txt","payload"), dest = try folder("b")
        let result = FileOperations.transfer([source],to:dest,kind:.move,policy:.stop)
        XCTAssertTrue(result.errors.isEmpty); XCTAssertFalse(FileSystem.exists(source)); XCTAssertEqual(try read(dest.appendingPathComponent("move.txt")),"payload")
        XCTAssertEqual(FileOperations.undo(result.undo),[]); XCTAssertEqual(try read(source),"payload")
    }
    func testUndoRefusesModifiedTarget() throws {
        let source = try file("a/file.txt","data"), dest = try folder("b")
        let result = FileOperations.transfer([source],to:dest,kind:.copy,policy:.stop)
        try "changed after copying".write(to:result.completed[0],atomically:true,encoding:.utf8)
        XCTAssertEqual(FileOperations.undo(result.undo).count,1); XCTAssertEqual(try read(result.completed[0]),"changed after copying")
    }
    func testDirectoryCannotBeCopiedIntoItselfViaSymlink() throws {
        let source = try folder("tree"), sub = try folder("tree/sub"); try file("tree/a")
        let alias = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:sub)
        let result = FileOperations.transfer([source],to:alias,kind:.copy,policy:.stop)
        XCTAssertEqual(result.errors.count,1); XCTAssertFalse(FileSystem.exists(sub.appendingPathComponent("tree")))
    }
    func testCancellationLeavesNoDestination() throws {
        let source = try file("a/a.txt"), target = try folder("b"),token = CancellationToken(); token.cancel()
        let result = FileOperations.transfer([source],to:target,kind:.copy,policy:.replace,token:token)
        XCTAssertEqual(result.errors.count,1); XCTAssertTrue(try FileSystem.list(target,showHidden:true).isEmpty)
    }
    func testFileCreationDoesNotTruncate() throws {
        let url = try file("unchanged.txt","keep")
        XCTAssertThrowsError(try FileOperations.newFile(in:root,name:"unchanged.txt")); XCTAssertEqual(try read(url),"keep")
    }
    func testRenamePreviewAndApplyWithUnicode() throws {
        let a = try file("Äpfel.txt"),b = try file("Birnen.txt")
        var rule = RenameRule(); rule.pattern = "{n}-{name}"; rule.start = 7; rule.digits = 2
        let items = try RenameEngine.preview([a,b],rule:rule)
        XCTAssertEqual(items[0].target.lastPathComponent,"07-Äpfel.txt")
        try RenameEngine.apply(items); XCTAssertFalse(FileSystem.exists(a)); XCTAssertTrue(FileSystem.exists(items[0].target))
        try RenameEngine.apply(RenameEngine.reversed(items)); XCTAssertTrue(FileSystem.exists(a))
    }
    func testRenameCyclesAreSafe() throws {
        let a = try file("a","AAA"),b = try file("b","BBB")
        try RenameEngine.apply([RenameItem(source:a,target:b),RenameItem(source:b,target:a)])
        XCTAssertEqual(try read(a),"BBB"); XCTAssertEqual(try read(b),"AAA")
    }
    func testRenameRejectsDuplicateNamesAndTraversal() throws {
        let a = try file("a.txt"),b = try file("b.txt"); var rule = RenameRule(); rule.pattern = "same"
        XCTAssertThrowsError(try RenameEngine.preview([a,b],rule:rule)); rule.pattern = "../bad"; XCTAssertThrowsError(try RenameEngine.preview([a],rule:rule))
        XCTAssertTrue(FileSystem.exists(a)); XCTAssertTrue(FileSystem.exists(b))
    }
    func testGlobAndRegexFilter() throws {
        XCTAssertTrue(try NameFilter("*.pdf").matches("Résumé.PDF")); XCTAssertFalse(try NameFilter("*.pdf").matches("a.pdf.bak"))
        XCTAssertTrue(try NameFilter("^a[0-9]+$",regex:true).matches("A12")); XCTAssertThrowsError(try NameFilter("[",regex:true))
    }
    func testSearchContentAndHidden() throws {
        try file("dir/first.txt","hello search"); try file("dir/second.txt","no match"); try file("dir/.hidden.txt","hello search")
        var options = SearchOptions(); options.name = "*.txt"; options.content = "SEARCH"
        let result = try SearchService.search(root.appendingPathComponent("dir"),options:options)
        XCTAssertEqual(result.urls.map(\.lastPathComponent),["first.txt"])
        options.showHidden = true; XCTAssertEqual(try SearchService.search(root.appendingPathComponent("dir"),options:options).urls.count,2)
    }
    func testDuplicatesUseContentNotOnlySize() throws {
        try file("a","ABC"); try file("b","ABC"); try file("c","DEF")
        let groups = try SearchService.duplicates(root); XCTAssertEqual(groups.count,1); XCTAssertEqual(groups[0].count,2)
    }
    func testHashKnownVectors() throws {
        let a = try file("abc","abc")
        XCTAssertEqual(try Checksums.hash(a),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try Checksums.hash(a,algorithm:.md5),"900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(try Checksums.hash(a,algorithm:.sha1),"a9993e364706816aba3e25717850c26c9cd0d89d")
    }
    func testChecksumManifestRejectsOutsideFiles() throws {
        let a = try file("abc","abc"),hash = try Checksums.hash(a)
        let manifest = try file("sums.sha256",hash+"  abc\n"+hash+"  ../outside\n")
        let result = try Checksums.verify(manifest,algorithm:.sha256)
        XCTAssertEqual(result[0],"OK  abc"); XCTAssertTrue(result[1].hasPrefix("UNSICHERER"))
    }
    func testCompareAndNonDeletingSync() throws {
        let l = try folder("left"),r = try folder("right")
        try file("left/shared.txt","new"); try file("right/shared.txt","old"); try file("left/nested/new.txt","x"); try file("right/keep.txt","keep")
        let comparison = try CompareService.compare(l,r)
        XCTAssertEqual(comparison.first { $0.relativePath == "shared.txt" }?.state,.different)
        let plan = try CompareService.plan(comparison,left:l,right:r,leftToRight:true)
        let report = CompareService.synchronize(plan)
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n")); XCTAssertEqual(try read(r.appendingPathComponent("shared.txt")),"new")
        XCTAssertEqual(try read(r.appendingPathComponent("nested/new.txt")),"x"); XCTAssertEqual(try read(r.appendingPathComponent("keep.txt")),"keep")
    }
    func testSyncRejectsStalePreviewBeforeAnyChanges() throws {
        let l = try folder("left"),r = try folder("right")
        try file("left/a","new"); try file("left/z","new"); try file("right/z","old")
        let plan = try CompareService.plan(CompareService.compare(l,r),left:l,right:r,leftToRight:true)
        try file("right/z","user changed target")
        let report = CompareService.synchronize(plan); XCTAssertEqual(report.errors.count,1); XCTAssertFalse(FileSystem.exists(r.appendingPathComponent("a")))
        XCTAssertEqual(try read(r.appendingPathComponent("z")),"user changed target")
    }
    func testSyncTypeConflictsAreNotOverwritten() throws {
        let l = try folder("left"),r = try folder("right"); try file("left/object"); try folder("right/object")
        let comparison = try CompareService.compare(l,r)
        XCTAssertThrowsError(try CompareService.plan(comparison,left:l,right:r,leftToRight:true))
    }
    func testZIPAndTARArchiveRoundTrip() throws {
        let source = try folder("source"); try file("source/Grüße.txt","Unicode ✔"); try folder("source/empty"); try file("source/sub/data","xyz")
        for format in [false,true] {
            let archive = root.appendingPathComponent(format ? "test.tar.gz" : "test.zip")
            try ArchiveService.pack([source],to:archive,tarGzip:format)
            let members = try ArchiveService.list(archive); XCTAssertTrue(members.contains { $0.path == "source/Grüße.txt" })
            let out = root.appendingPathComponent(format ? "out-tar" : "out-zip"); try ArchiveService.extract(archive,to:out)
            XCTAssertEqual(try read(out.appendingPathComponent("source/Grüße.txt")),"Unicode ✔"); XCTAssertTrue(FileSystem.isDirectory(out.appendingPathComponent("source/empty")))
        }
    }
    func unsafeArchive(_ path:String,entries:[(String,String)]) throws -> URL {
        let url = root.appendingPathComponent(path),a = archive_write_new()!; defer { archive_write_free(a) }
        XCTAssertEqual(archive_write_set_format_zip(a),0); XCTAssertEqual(archive_write_open_filename(a,url.path),0)
        for (name,value) in entries {
            let entry = archive_entry_new()!; defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry,name); archive_entry_set_filetype(entry,0o100000); archive_entry_set_perm(entry,0o644)
            let data = Data(value.utf8); archive_entry_set_size(entry,Int64(data.count)); XCTAssertEqual(archive_write_header(a,entry),0)
            XCTAssertEqual(data.withUnsafeBytes { archive_write_data(a,$0.baseAddress,data.count) },data.count)
        }
        XCTAssertEqual(archive_write_close(a),0); return url
    }
    func testArchiveTraversalRollsBackStaging() throws {
        let archive = try unsafeArchive("bad.zip",entries:[("good.txt","ok"),("../escape.txt","bad")]),dest = root.appendingPathComponent("extracted")
        XCTAssertThrowsError(try ArchiveService.extract(archive,to:dest)); XCTAssertFalse(FileSystem.exists(dest)); XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("escape.txt")))
        XCTAssertFalse(try FileSystem.list(root,showHidden:true).contains { $0.name.hasPrefix(".zweicommander-extract-") })
    }
    func testArchiveBudgetAndDuplicateEntriesFailSafely() throws {
        let archive = try unsafeArchive("too-big.zip",entries:[("data.txt","1234567890")])
        XCTAssertThrowsError(try ArchiveService.extract(archive,to:root.appendingPathComponent("budget"),maxBytes:5))
        XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("budget")))
        let duplicate = try unsafeArchive("duplicate.zip",entries:[("a","one"),("a","two")])
        XCTAssertThrowsError(try ArchiveService.extract(duplicate,to:root.appendingPathComponent("dupe")))
    }
    func testArchivePathValidationHandlesEmptyAndAbsolute() throws {
        XCTAssertEqual(try ArchiveService.safePath("./"),""); XCTAssertEqual(try ArchiveService.safePath("./a/b"),"a/b")
        for value in ["/etc/passwd","../../escape","x/../y","C:/x","a\\b"] { XCTAssertThrowsError(try ArchiveService.safePath(value)) }
    }
    func testArchiveDoesNotFollowSymlinks() throws {
        let source = try folder("src"),secret = try file("secret","private")
        try FileManager.default.createSymbolicLink(at:source.appendingPathComponent("link"),withDestinationURL:secret)
        XCTAssertThrowsError(try ArchiveService.pack([source],to:root.appendingPathComponent("links.zip"))); XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("links.zip")))
    }
    func testSplitJoinAndTamperDetection() throws {
        let original = try file("large.bin",String(repeating:"abcdefgh",count:1000)),pieces = root.appendingPathComponent("pieces")
        try FileTools.split(original,to:pieces,chunkBytes:1023)
        let manifest = pieces.appendingPathComponent("parts.zwei.json"),dest = root.appendingPathComponent("joined.bin")
        try FileTools.join(manifest,to:dest); XCTAssertEqual(try Data(contentsOf:original),try Data(contentsOf:dest))
        let info = try JSONDecoder().decode(SplitManifest.self,from:Data(contentsOf:manifest))
        try "tampered".write(to:pieces.appendingPathComponent(info.parts[0].name),atomically:true,encoding:.utf8)
        let bad = root.appendingPathComponent("bad.bin"); XCTAssertThrowsError(try FileTools.join(manifest,to:bad)); XCTAssertFalse(FileSystem.exists(bad))
    }
    func testSplitJoinEmptyFile() throws {
        let source = try file("empty",""),parts = root.appendingPathComponent("parts"),dest = root.appendingPathComponent("result")
        try FileTools.split(source,to:parts,chunkBytes:4); try FileTools.join(parts.appendingPathComponent("parts.zwei.json"),to:dest)
        XCTAssertEqual(try Data(contentsOf:dest).count,0)
    }
    func testTopLevelSelectionDoesNotDoubleProcessDescendants() throws {
        let parent = try folder("folder"),child = try file("folder/file")
        XCTAssertEqual(FileSystem.topLevelSelection([parent,child,parent]).map(\.path),[parent.path])
    }
    func testRemoteListingHandlesSpacesAndUnicode() throws {
        let unix = "sftp> ls -la \"/\"\n" + "drwxr-xr-x    2 user group      64 Oct 17 12:00 Fotos Wien\n" + "-rw-r--r--    1 user group     123 Oct 17 12:00 Grüße.txt\n" + "lrwxrwxrwx    1 user group       4 Oct 17 12:00 link -> dest\n"
        let entries = try RemoteService.parseListing(unix,mlsd:false)
        XCTAssertEqual(entries.count,3); XCTAssertEqual(entries[0].name,"Fotos Wien"); XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries.first { $0.name == "Grüße.txt" }?.size,123)
        XCTAssertTrue(entries.first { $0.name == "link" }?.isLink ?? false)
        let mlsd = "type=cdir;modify=20261017000000; .\n" + "type=dir;modify=20261017000000; Folder with spaces\n" + "type=file;size=42;modify=20261017000000; name;with;semicolons.txt\n"
        let result = try RemoteService.parseListing(mlsd,mlsd:true)
        XCTAssertEqual(result.count,2); XCTAssertEqual(result[1].name,"name;with;semicolons.txt"); XCTAssertEqual(result[1].size,42)
    }
    func testRemoteCommandsRejectInjectionAndMalformedListings() throws {
        XCTAssertThrowsError(try RemoteService.batchQuote("a\nrm file"))
        XCTAssertThrowsError(try RemoteConnection(kind:.sftp,host:"-oProxyCommand=bad",user:"a",port:22))
        XCTAssertThrowsError(try RemoteConnection(kind:.ftp,host:"server",user:"a",password:"x\nurl=bad",port:21))
        XCTAssertThrowsError(try RemoteService.parseListing("unknown listing format",mlsd:false))
        XCTAssertEqual(try RemoteService.batchQuote("a b*.txt"),"\"a b\\*.txt\"")
    }
    func testProcessInputAndNonzeroExit() throws {
        let text = try ProcessRunner.run("/bin/cat",arguments:[],input:Data("safe input\n".utf8))
        XCTAssertEqual(text,"safe input\n")
        XCTAssertThrowsError(try ProcessRunner.run("/usr/bin/false",arguments:[]))
    }
    func testArchiveNameSearch() throws {
        let source = try file("src/readme.txt","content"),dest = root.appendingPathComponent("bundle.zip")
        try ArchiveService.pack([source],to:dest)
        var options = SearchOptions(); options.searchArchives = true; options.name = "*.txt"
        let report = try SearchService.search(root,options:options)
        XCTAssertTrue(report.archiveMatches.contains { $0.hasSuffix(" ▸ readme.txt") })
    }
    func testRelativePathsPreserveSymlinkNames() throws {
        let folder = try self.folder("dir"),target = try file("outside.txt")
        let link = folder.appendingPathComponent("shortcut"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        var paths:[String] = []
        try FileSystem.walk(folder) { paths.append(try FileSystem.relativePath(of:$0,inside:folder)) }
        XCTAssertEqual(paths,["shortcut"])
    }

    func testFTPLoopbackListingDownloadAndUpload() throws {
        let serverRoot = try folder("server"), localRoot = try folder("local")
        try file("server/hello world.txt","FTP content ✔")
        try file("server/notes;type=a","Literal FTP filename\r\n")
        try folder("server/Folder")
        let script = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/ftp_server.py")
        let server = Process(); server.executableURL = URL(fileURLWithPath:"/usr/bin/python3"); server.arguments = [script.path,serverRoot.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let portFile = serverRoot.appendingPathComponent("port.txt"),deadline = Date().addingTimeInterval(5)
        while !FileSystem.exists(portFile) && Date() < deadline && server.isRunning { Thread.sleep(forTimeInterval:0.02) }
        guard let port = Int(try String(contentsOf:portFile,encoding:.utf8)) else { throw CommanderError.message("FTP fixture did not start") }
        let connection = try RemoteConnection(kind:.ftp,host:"127.0.0.1",user:"tester",password:"quote\"in-password",port:port)
        let listing = try RemoteService.list(connection,path:"/")
        guard let entry = listing.first(where:{$0.name == "hello world.txt"}) else { throw CommanderError.message("FTP file missing") }
        let downloaded = try RemoteService.download(connection,path:"/",entry:entry,to:localRoot)
        XCTAssertEqual(try read(downloaded),"FTP content ✔")
        XCTAssertThrowsError(try RemoteService.download(connection,path:"/",entry:entry,to:localRoot))
        guard let special = listing.first(where:{$0.name == "notes;type=a"}) else { throw CommanderError.message("Special FTP filename missing") }
        let specialFile = try RemoteService.download(connection,path:"/",entry:special,to:localRoot)
        XCTAssertEqual(try read(specialFile),"Literal FTP filename\r\n")
        let source = try file("local/upload Grüße;type=a","Uploaded data")
        try RemoteService.upload(connection,source:source,path:"/")
        XCTAssertEqual(try read(serverRoot.appendingPathComponent(source.lastPathComponent)),"Uploaded data")
        XCTAssertThrowsError(try RemoteService.upload(connection,source:source,path:"/"))
    }

    func testINIEncodingsAndLiteralValues() throws {
        let text = "[Form]\r\nLabel=Grüße\r\nLiteral=a=b;keep this\r\n"
        var utf8 = Data([0xef,0xbb,0xbf]); utf8.append(Data(text.utf8))
        var utf16 = Data([0xff,0xfe]); utf16.append(text.data(using:.utf16LittleEndian)!)
        var big = Data([0xfe,0xff]);big.append(text.data(using:.utf16BigEndian)!)
        for data in [utf8,utf16,big,text.data(using:.windowsCP1252)!] {
            let ini = try INIDocument(data:data)
            XCTAssertEqual(ini["FORM","label"],"Grüße")
            XCTAssertEqual(ini["form","literal"],"a=b;keep this")
        }
    }
    func testSettingsProfileImportsActualLayoutAndActive64BitPlugins() throws {
        let sample = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/INISettings.sample.ini")
        let shc = Data("[ShortCuts]\nactFileView=Space\nactViewTabNewFileCart=Ctrl+Alt+T\nactViewTabFileCartRemoveItem=Alt+Del\n[TfcViewerForm_ShortCuts]\nactViewModeText=T\nactFileClose=Esc\nactViewModeImages=I\nactViewModeImageMultimedia=M\n".utf8)
        let find = Data("[TfcSearchFrame]\nSearchOfficeXml=1\n".utf8)
        let rename = Data("[fcFormMultiRename]\nCounterDigits=4\n".utf8)
        let data = try Data(contentsOf:sample)
        let profile = try INISettingsImport.parse(main:data,shortcuts:shc,search:find,rename:rename)
        XCTAssertEqual(profile.columns.map(\.id),["name","size","modified","kind","attributes"])
        XCTAssertEqual(profile.columns[0].characterWidth,52)
        XCTAssertTrue(profile.darkAppearance);XCTAssertTrue(profile.showHidden);XCTAssertTrue(profile.foldersFirst)
        XCTAssertEqual(profile.background?.hex,"#414141");XCTAssertEqual(profile.fontSize,12)
        XCTAssertEqual(profile.rightSort.key,"kind");XCTAssertTrue(profile.rightSort.ascending)
        XCTAssertEqual(profile.shortcuts["preview"],"space");XCTAssertEqual(profile.shortcuts["newCollection"],"cmd+option+t")
        XCTAssertEqual(profile.shortcuts["removeCollectionItem"],"option+delete")
        XCTAssertEqual(profile.viewerShortcuts["preview"],"i");XCTAssertEqual(profile.viewerShortcuts["multimedia"],"m")
        XCTAssertTrue(profile.officeContentSearch);XCTAssertEqual(profile.renameCounterDigits,4)
        XCTAssertEqual(profile.plugins.filter { $0.category == "Viewer" && $0.enabled }.map(\.name),["fileinfo","ulister"])
        XCTAssertEqual(profile.plugins.first { $0.name == "ulister" }?.extensions,["docx","dwg","xlsx"])
        XCTAssertFalse(profile.plugins.first { $0.name == "fc7Zip" }?.enabled ?? true)
        let exported = String(decoding:try JSONEncoder().encode(profile),as:UTF8.self)
        XCTAssertFalse(exported.contains("SHOULD_NEVER_APPEAR"));XCTAssertFalse(exported.contains("cmd.exe"))
        XCTAssertFalse(exported.contains("D:\\private"))
        let changed = try INISettingsImport.parse(main:data,shortcuts:Data("[ShortCuts]\nactFileView=F3".utf8))
        XCTAssertFalse(changed.sourceSHA256 == profile.sourceSHA256)
        XCTAssertTrue(profile.fileColors.first?.matches("Backup.ZIP") ?? false)
        XCTAssertFalse(profile.fileColors.first?.matches("notes.txt") ?? true)
    }
    func testINISettingsImportRejectsUnrelatedAndOversizeFiles() throws {
        XCTAssertThrowsError(try INISettingsImport.parse(main:Data("[Other]\nkey=value".utf8)))
        XCTAssertThrowsError(try INIDocument(data:Data(repeating:65,count:4*1024*1024+1)))
        XCTAssertEqual(INISettingsImport.nativeShortcut("Ctrl+Shift+F3"),"cmd+shift+f3")
        XCTAssertEqual(INISettingsImport.nativeShortcut("-1"),nil)
        XCTAssertEqual(INISettingsImport.nativeShortcut("Ctrl+UnknownKey"),nil)
    }
    func testINIImportSelectedFilenameAndAmbiguousFolder() throws {
        let directory = try folder("settings")
        let sample = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/INISettings.sample.ini")
        let selected = directory.appendingPathComponent("Layout.ini")
        try Data(contentsOf:sample).write(to:selected)
        try file("settings/Layout.shc","[ShortCuts]\nactFileView=Space\n")
        try file("settings/Layout.find.ini","[TfcSearchFrame]\nSearchOfficeXml=1\n")
        try file("settings/Layout.mren.ini","[fcFormMultiRename]\nCounterDigits=5\n")
        try file("settings/Layout.ftp.ini","[FTP]\nPassword=SHOULD_NEVER_APPEAR\n")
        let profile = try INISettingsImport.load(directory:directory)
        XCTAssertEqual(profile,try INISettingsImport.load(directory:selected))
        XCTAssertEqual(profile.shortcuts["preview"],"space")
        XCTAssertTrue(profile.officeContentSearch);XCTAssertEqual(profile.renameCounterDigits,5)
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(profile),as:UTF8.self).contains("SHOULD_NEVER_APPEAR"))
        try Data(contentsOf:sample).write(to:directory.appendingPathComponent("Other.ini"))
        XCTAssertThrowsError(try INISettingsImport.load(directory:directory))
        XCTAssertEqual(profile,try INISettingsImport.load(directory:selected))
    }
    func testSevenZipRoundTripAndCompression() throws {
        let source = try folder("data")
        try file("data/Grüße.txt",String(repeating:"7z archive payload ",count:4000))
        let archive = root.appendingPathComponent("data.7z")
        try ArchiveService.pack([source],to:archive,sevenZip:true,compressionLevel:6)
        let bytes = try Data(contentsOf:archive)
        XCTAssertEqual(Array(bytes.prefix(6)),[0x37,0x7a,0xbc,0xaf,0x27,0x1c])
        XCTAssertTrue(bytes.count < 5000)
        let dest = root.appendingPathComponent("out")
        try ArchiveService.extract(archive,to:dest)
        XCTAssertEqual(try read(dest.appendingPathComponent("data/Grüße.txt")),String(repeating:"7z archive payload ",count:4000))
    }
    func testOfficeTextAcrossRunsAndContentSearch() throws {
        let document = "<w:document xmlns:w=\"urn:test\"><w:p><w:r><w:t>Gefühls</w:t></w:r><w:r><w:t>achterbahn &amp; Wien</w:t></w:r></w:p></w:document>"
        let archive = try unsafeArchive("meeting.docx",entries:[("word/document.xml",document),("word/header1.xml","<p>Header example</p>")])
        let text = try DocumentText.extract(archive)
        XCTAssertTrue(text.contains("Gefühlsachterbahn & Wien"));XCTAssertTrue(text.contains("Header example"))
        var options = SearchOptions();options.content = "Gefühlsachterbahn";options.name = "*.docx";options.searchOfficeDocuments = true
        let found = try SearchService.search(root,options:options)
        XCTAssertEqual(found.urls.map(\.lastPathComponent),["meeting.docx"])
        options.searchOfficeDocuments = false
        XCTAssertTrue(try SearchService.search(root,options:options).urls.isEmpty)
    }
    func testOfficeSpreadsheetOdtAndPowerPointText() throws {
        for (ext,path,xml) in [("xlsx","xl/sharedStrings.xml","<sst><si><t>Finanzplanung</t></si></sst>"),("odt","content.xml","<document><p>Finanzplanung</p></document>"),("pptx","ppt/slides/slide1.xml","<slide><p>Finanzplanung</p></slide>")] {
            let url = try unsafeArchive("document."+ext,entries:[(path,xml)])
            XCTAssertTrue(try DocumentText.extract(url).contains("Finanzplanung"))
        }
    }
    func testOfficeXmlRejectsEntitiesCorruptionAndZipExpansion() throws {
        XCTAssertThrowsError(try DocumentText.parseXML(Data("<!DOCTYPE doc [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><doc>&x;</doc>".utf8)))
        XCTAssertThrowsError(try DocumentText.parseXML(Data("<doc><broken>".utf8)))
        let archive = try unsafeArchive("large.docx",entries:[("word/document.xml","<p>"+String(repeating:"x",count:1000)+"</p>")])
        XCTAssertThrowsError(try DocumentText.extract(archive,maxBytes:50))
        let escape = try unsafeArchive("escape.docx",entries:[("../word/document.xml","<p>bad</p>")])
        XCTAssertThrowsError(try DocumentText.extract(escape))
    }
    func versionBlock(_ key:String,value:Data = Data(),type:Int = 0,valueLength:Int? = nil,children:[Data] = []) -> Data {
        var data = Data(repeating:0,count:6)
        for code in (key+"\0").utf16 { data.append(UInt8(code & 255));data.append(UInt8(code >> 8)) }
        while data.count%4 != 0 { data.append(0) }
        data.append(value)
        for child in children { while data.count%4 != 0 { data.append(0) };data.append(child) }
        for (offset,number) in [(0,data.count),(2,valueLength ?? (type == 1 ? value.count/2 : value.count)),(4,type)] {
            data[offset] = UInt8(number & 255);data[offset+1] = UInt8(number >> 8)
        }
        return data
    }
    func testWindowsVersionResourceAndPEHeader() throws {
        let product = versionBlock("ProductName",value:("Fixture Product\0").data(using:.utf16LittleEndian)!,type:1)
        let version = versionBlock("FileVersion",value:("1.2.3.4\0").data(using:.utf16LittleEndian)!,type:1)
        let table = versionBlock("040904B0",children:[product,version])
        let info = versionBlock("StringFileInfo",children:[table])
        let blob = versionBlock("VS_VERSION_INFO",children:[info])
        XCTAssertEqual(try BinaryInspector.versionStrings(blob)["FileVersion"],"1.2.3.4")
        var pe = Data(repeating:0,count:0x800)
        func put(_ offset:Int,_ value:Int,_ count:Int = 4) { for i in 0..<count { pe[offset+i] = UInt8((value >> (i*8)) & 255) } }
        pe[0]=0x4d;pe[1]=0x5a;put(0x3c,0x80);put(0x80,0x4550)
        put(0x84,0x8664,2);put(0x86,1,2);put(0x94,240,2);put(0x98,0x20b,2)
        put(0x98+128,0x1000);put(0x98+132,0x400)
        pe.replaceSubrange(0x188..<0x190,with:Data([46,114,115,114,99,0,0,0]))
        put(0x188+8,0x400);put(0x188+12,0x1000);put(0x188+16,0x400);put(0x188+20,0x400)
        put(0x400+14,1,2);put(0x410,16);put(0x414,0x80000020)
        put(0x420+14,1,2);put(0x430,1);put(0x434,0x80000040)
        put(0x440+14,1,2);put(0x450,0x409);put(0x454,0x60)
        put(0x460,0x1080);put(0x464,blob.count)
        pe.replaceSubrange(0x480..<0x480+blob.count,with:blob)
        let file = root.appendingPathComponent("program.exe");try pe.write(to:file)
        let result = try BinaryInspector.describe(file) ?? ""
        XCTAssertTrue(result.contains("x86_64"));XCTAssertTrue(result.contains("Fixture Product"));XCTAssertTrue(result.contains("1.2.3.4"))
    }
    func testBinaryInspectorHandlesMalformedAndUniversalHeaders() throws {
        var bad = Data(repeating:0,count:128);bad[0]=0x4d;bad[1]=0x5a
        for i in 0..<4 { bad[0x3c+i]=255 }
        let exe = root.appendingPathComponent("bad.exe");try bad.write(to:exe)
        XCTAssertThrowsError(try BinaryInspector.describe(exe))
        var fat = Data(repeating:0,count:64);fat.replaceSubrange(0..<4,with:[0xca,0xfe,0xba,0xbe]);fat[7]=2
        fat.replaceSubrange(8..<12,with:[1,0,0,7]);fat.replaceSubrange(28..<32,with:[1,0,0,12])
        let macho = root.appendingPathComponent("universal");try fat.write(to:macho)
        let result = try BinaryInspector.describe(macho) ?? ""
        XCTAssertTrue(result.contains("x86_64"));XCTAssertTrue(result.contains("arm64"))
        XCTAssertEqual(try BinaryInspector.describe(file("plain.txt","normal text")),nil)
    }

}

// Portable assertions: works with Apple's Command Line Tools without an Xcode installation.
var assertionFailures: [String] = []
func recordFailure(_ message: String, file: StaticString, line: UInt) { assertionFailures.append("\(file):\(line): \(message)") }
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let a = try lhs(), b = try rhs(); if a != b { recordFailure("Expected \(b), received \(a). \(message)", file:file, line:line) } }
    catch { recordFailure(error.localizedDescription, file:file, line:line) }
}
func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !expression() { recordFailure("Expected true. \(message)", file:file, line:line) } }
    catch { recordFailure(error.localizedDescription, file:file, line:line) }
}
func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() { recordFailure("Expected false. \(message)", file:file, line:line) } }
    catch { recordFailure(error.localizedDescription, file:file, line:line) }
}
func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value == nil { recordFailure("Unexpected nil", file:file, line:line) } }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); recordFailure("Expected an error", file:file, line:line) } catch { }
}

let tests: [(String, (CoreTests) throws -> Void)] = [
    ("testComparisonModesAndInclusiveTimeTolerance", { try $0.testComparisonModesAndInclusiveTimeTolerance() }),
    ("testComparisonContentIgnoresDatesForIdenticalBytes", { try $0.testComparisonContentIgnoresDatesForIdenticalBytes() }),
    ("testComparisonFiltersPruneAndPreserveStructure", { try $0.testComparisonFiltersPruneAndPreserveStructure() }),
    ("testComparisonBlocksLinksSpecialFilesAndConflictDescendants", { try $0.testComparisonBlocksLinksSpecialFilesAndConflictDescendants() }),
    ("testComparisonCaseAndUnicodeAmbiguityBlocksWholeBranch", { try $0.testComparisonCaseAndUnicodeAmbiguityBlocksWholeBranch() }),
    ("testComparisonRejectsInvalidRootsAndOptions", { try $0.testComparisonRejectsInvalidRootsAndOptions() }),
    ("testComparisonRejectsMutationDuringScan", { try $0.testComparisonRejectsMutationDuringScan() }),
    ("testComparisonPresetsDistinguishUndecidedAndSkipped", { try $0.testComparisonPresetsDistinguishUndecidedAndSkipped() }),
    ("testSyncSelectedFilesCreateOnlyRequiredParents", { try $0.testSyncSelectedFilesCreateOnlyRequiredParents() }),
    ("testSyncMixedDirectionsBackupsExtrasAndUndo", { try $0.testSyncMixedDirectionsBackupsExtrasAndUndo() }),
    ("testSyncStaleSourceCtimeRejectsEntirePlan", { try $0.testSyncStaleSourceCtimeRejectsEntirePlan() }),
    ("testSyncStaleTargetCtimeRejectsBeforeAnyMutation", { try $0.testSyncStaleTargetCtimeRejectsBeforeAnyMutation() }),
    ("testSyncReplacedRootsAndParentsNeverFollowLinks", { try $0.testSyncReplacedRootsAndParentsNeverFollowLinks() }),
    ("testSyncNewTargetAndAliasAreNeverOverwritten", { try $0.testSyncNewTargetAndAliasAreNeverOverwritten() }),
    ("testSyncContentMutationDuringCopyKeepsOldTarget", { try $0.testSyncContentMutationDuringCopyKeepsOldTarget() }),
    ("testSyncTargetAppearingDuringCopyIsPreserved", { try $0.testSyncTargetAppearingDuringCopyIsPreserved() }),
    ("testSyncParentRelocationDuringCopyKeepsBothLocations", { try $0.testSyncParentRelocationDuringCopyKeepsBothLocations() }),
    ("testSyncForeignReplacementOfStagingIsNeverRemoved", { try $0.testSyncForeignReplacementOfStagingIsNeverRemoved() }),
    ("testSyncCancelDuringCopyPreservesExistingTarget", { try $0.testSyncCancelDuringCopyPreservesExistingTarget() }),
    ("testSyncCancelAfterCompletedFileKeepsPartialResult", { try $0.testSyncCancelAfterCompletedFileKeepsPartialResult() }),
    ("testSyncPauseResumeWithByteProgressAndMetadata", { try $0.testSyncPauseResumeWithByteProgressAndMetadata() }),
    ("testSyncDirectoriesPermissionsAndNoopPlan", { try $0.testSyncDirectoriesPermissionsAndNoopPlan() }),
    ("testSyncPlanRejectsUnknownAndInvalidDirections", { try $0.testSyncPlanRejectsUnknownAndInvalidDirections() }),
    ("testComparisonProfilesRoundTripAndValidateLimits", { try $0.testComparisonProfilesRoundTripAndValidateLimits() }),

    ("testSearchMultipleMasksExclusionsAndFolderPruning", { try $0.testSearchMultipleMasksExclusionsAndFolderPruning() }),
    ("testSearchNonrecursiveTypesAndSymbolicLinks", { try $0.testSearchNonrecursiveTypesAndSymbolicLinks() }),
    ("testSearchMetadataBoundsAndLinkExclusion", { try $0.testSearchMetadataBoundsAndLinkExclusion() }),
    ("testSearchRelativeAgeSnapshotAndFutureExclusion", { try $0.testSearchRelativeAgeSnapshotAndFutureExclusion() }),
    ("testSearchLiteralCaseWholeWordsAndSnippets", { try $0.testSearchLiteralCaseWholeWordsAndSnippets() }),
    ("testSearchUTF16AndExplicitLegacyEncoding", { try $0.testSearchUTF16AndExplicitLegacyEncoding() }),
    ("testSearchBinaryAndOversizeInputsStayUnchanged", { try $0.testSearchBinaryAndOversizeInputsStayUnchanged() }),
    ("testSearchStreamingCancellationRetainsExactlyDeliveredResults", { try $0.testSearchStreamingCancellationRetainsExactlyDeliveredResults() }),
    ("testSearchPrecancelledAndNoMatchesHaveDifferentReports", { try $0.testSearchPrecancelledAndNoMatchesHaveDifferentReports() }),
    ("testSearchResultLimitIncludesArchiveMembers", { try $0.testSearchResultLimitIncludesArchiveMembers() }),
    ("testSearchArchiveFoldersHiddenAndExcludedNames", { try $0.testSearchArchiveFoldersHiddenAndExcludedNames() }),
    ("testSearchArchiveContentAndDatesRequireSeparateMode", { try $0.testSearchArchiveContentAndDatesRequireSeparateMode() }),
    ("testSearchBadArchivesWarnAndContinueWithoutInventedPaths", { try $0.testSearchBadArchivesWarnAndContinueWithoutInventedPaths() }),
    ("testSearchWarningStorageIsBounded", { try $0.testSearchWarningStorageIsBounded() }),
    ("testSearchValidationRejectsInvalidRulesBeforeTraversal", { try $0.testSearchValidationRejectsInvalidRulesBeforeTraversal() }),
    ("testSearchProfilesRoundTripRulesAndNoLocations", { try $0.testSearchProfilesRoundTripRulesAndNoLocations() }),
    ("testSearchProfileLimitsDuplicateNamesAndDamagedData", { try $0.testSearchProfileLimitsDuplicateNamesAndDamagedData() }),
    ("testRenameParentRelocationReportsActualRecoveryLocation", { try $0.testRenameParentRelocationReportsActualRecoveryLocation() }),
    ("testRenameOpenHandleEditDuringStagingIsPreserved", { try $0.testRenameOpenHandleEditDuringStagingIsPreserved() }),
    ("testRenameTemplatesSlicesEscapesAndLiteralValues", { try $0.testRenameTemplatesSlicesEscapesAndLiteralValues() }),
    ("testRenameSeparateExtensionsAndTargetedTransforms", { try $0.testRenameSeparateExtensionsAndTargetedTransforms() }),
    ("testRenameCounterStepsPerFolderAndOverflow", { try $0.testRenameCounterStepsPerFolderAndOverflow() }),
    ("testRenameDateAndImageMetadataTokens", { try $0.testRenameDateAndImageMetadataTokens() }),
    ("testRenameMissingMetadataAndInvalidRulesStayVisible", { try $0.testRenameMissingMetadataAndInvalidRulesStayVisible() }),
    ("testRenameCollisionsAnnotateEveryConflictingRow", { try $0.testRenameCollisionsAnnotateEveryConflictingRow() }),
    ("testRenameStaleSourceBlocksAllNamesBeforeMutation", { try $0.testRenameStaleSourceBlocksAllNamesBeforeMutation() }),
    ("testRenameDetectsSameSizeEditsWithRestoredTimestamp", { try $0.testRenameDetectsSameSizeEditsWithRestoredTimestamp() }),
    ("testRenameReplacedParentAndSourceAreRejected", { try $0.testRenameReplacedParentAndSourceAreRejected() }),
    ("testRenameCancellationRestoresStagedNames", { try $0.testRenameCancellationRestoresStagedNames() }),
    ("testRenameCancellationRestoresPublishedCycle", { try $0.testRenameCancellationRestoresPublishedCycle() }),
    ("testRenameNeverOverwritesTargetCreatedDuringPublication", { try $0.testRenameNeverOverwritesTargetCreatedDuringPublication() }),
    ("testRenameFailedRollbackPreservesForeignAndOwnedFiles", { try $0.testRenameFailedRollbackPreservesForeignAndOwnedFiles() }),
    ("testRenameUndoRefusesEditsAndOccupiedOriginals", { try $0.testRenameUndoRefusesEditsAndOccupiedOriginals() }),
    ("testRenameLinksNestedSelectionsAndHardlinks", { try $0.testRenameLinksNestedSelectionsAndHardlinks() }),
    ("testRenameCaseOnlyCyclesAndUnchangedRows", { try $0.testRenameCaseOnlyCyclesAndUnchangedRows() }),
    ("testRenameProfilesRoundTripUnicodeAndRulesOnly", { try $0.testRenameProfilesRoundTripUnicodeAndRulesOnly() }),
    ("testRenameProfileErrorsNeverReplaceExistingRules", { try $0.testRenameProfileErrorsNeverReplaceExistingRules() }),
    ("testScopedSchedulerCancellationKeepsOtherJobs", { try $0.testScopedSchedulerCancellationKeepsOtherJobs() }),
    ("testRenameManualPlansCannotMoveOutsideParent", { try $0.testRenameManualPlansCannotMoveOutsideParent() }),
    ("testFolderViewsRespectScopeAndSpecificity", { try $0.testFolderViewsRespectScopeAndSpecificity() }),
    ("testFolderViewsRootUnicodeAndNormalizedPaths", { try $0.testFolderViewsRootUnicodeAndNormalizedPaths() }),
    ("testWorkspaceRoundTripPreservesOrderAndRules", { try $0.testWorkspaceRoundTripPreservesOrderAndRules() }),
    ("testWorkspaceRejectsDamagedAndFutureDocuments", { try $0.testWorkspaceRejectsDamagedAndFutureDocuments() }),
    ("testWorkspaceValidationNeverReplacesGoodValues", { try $0.testWorkspaceValidationNeverReplacesGoodValues() }),
    ("testWorkspaceValidatesColumnsAndUniqueEntries", { try $0.testWorkspaceValidatesColumnsAndUniqueEntries() }),
    ("testLegacyFolderFavoritesMigrateWithoutPrograms", { try $0.testLegacyFolderFavoritesMigrateWithoutPrograms() }),
    ("testProgramFavoritesUseStructuredFileArguments", { try $0.testProgramFavoritesUseStructuredFileArguments() }),
    ("testAgeUnitsParsingAndOverflowAreExact", { try $0.testAgeUnitsParsingAndOverflowAreExact() }),
    ("testAgeValidationRejectsMixedModesAndReversedUnits", { try $0.testAgeValidationRejectsMixedModesAndReversedUnits() }),
    ("testAgeRangeIncludesBothBoundariesAndExcludesFuture", { try $0.testAgeRangeIncludesBothBoundariesAndExcludesFuture() }),
    ("testAgeOneSidedRangesAndZeroUseNoFutureDates", { try $0.testAgeOneSidedRangesAndZeroUseNoFutureDates() }),
    ("testAgeReferenceIsFrozenForEveryRootAndExecution", { try $0.testAgeReferenceIsFrozenForEveryRootAndExecution() }),
    ("testAgeFreshPlansRecalculateWhileEmptyPlansKeepTheirReference", { try $0.testAgeFreshPlansRecalculateWhileEmptyPlansKeepTheirReference() }),
    ("testAgeCombinesWithNamesSizeSubtreesAndLinkExclusion", { try $0.testAgeCombinesWithNamesSizeSubtreesAndLinkExclusion() }),
    ("testAgeSourceEnteringRangeInvalidatesBeforeAnyPublication", { try $0.testAgeSourceEnteringRangeInvalidatesBeforeAnyPublication() }),
    ("testAgeMergeKeepsReferenceAndRequiresRealConflictDecision", { try $0.testAgeMergeKeepsReferenceAndRequiresRealConflictDecision() }),
    ("testAgeStructureSuspendsRulesAndFilteredMovePlansKeepAge", { try $0.testAgeStructureSuspendsRulesAndFilteredMovePlansKeepAge() }),
    ("testAgeProfilesUseVersionTwoAndPreserveLegacyRecords", { try $0.testAgeProfilesUseVersionTwoAndPreserveLegacyRecords() }),
    ("testAgeJournalRestoresRelativeRuleAndNewPlansUseNewTime", { try $0.testAgeJournalRestoresRelativeRuleAndNewPlansUseNewTime() }),
    ("testLaterSelectionObjectReportsItsFirstPartialBytes", { try $0.testLaterSelectionObjectReportsItsFirstPartialBytes() }),
    ("testJournalCapacityDoesNotEvictUnfinishedEntries", { try $0.testJournalCapacityDoesNotEvictUnfinishedEntries() }),
    ("testJournalRestoresIntentWithoutExecutingOrLosingRules", { try $0.testJournalRestoresIntentWithoutExecutingOrLosingRules() }),
    ("testJournalUnfinishedStatesRequireReviewAndKeepLastReportedBytes", { try $0.testJournalUnfinishedStatesRequireReviewAndKeepLastReportedBytes() }),
    ("testJournalCompletedFailedAndCancelledHistorySurvivesRestart", { try $0.testJournalCompletedFailedAndCancelledHistorySurvivesRestart() }),
    ("testJournalUsesPrivatePermissionsAndExclusiveLifetimeLock", { try $0.testJournalUsesPrivatePermissionsAndExclusiveLifetimeLock() }),
    ("testJournalCorruptAndUnknownDocumentsStayUntouched", { try $0.testJournalCorruptAndUnknownDocumentsStayUntouched() }),
    ("testJournalRejectsSymlinkAndHardlinkDataFiles", { try $0.testJournalRejectsSymlinkAndHardlinkDataFiles() }),
    ("testJournalRejectsLinkedDirectoryAndLockFile", { try $0.testJournalRejectsLinkedDirectoryAndLockFile() }),
    ("testJournalRefusesExternalChangesBeforeWriting", { try $0.testJournalRefusesExternalChangesBeforeWriting() }),
    ("testJournalRefusesReplacedDirectoryWithoutWritingOutside", { try $0.testJournalRefusesReplacedDirectoryWithoutWritingOutside() }),
    ("testJournalDoesNotRecreateExternallyRemovedFileOrReplacedLock", { try $0.testJournalDoesNotRecreateExternallyRemovedFileOrReplacedLock() }),
    ("testJournalReorderRemoveAndReplacementPersistAtomically", { try $0.testJournalReorderRemoveAndReplacementPersistAtomically() }),
    ("testJournalBoundsItemExcerptButKeepsAggregateProgress", { try $0.testJournalBoundsItemExcerptButKeepsAggregateProgress() }),
    ("testJournalRejectsUnsafeIntentAndInvalidProgressWithoutMutation", { try $0.testJournalRejectsUnsafeIntentAndInvalidProgressWithoutMutation() }),
    ("testJournalFreshPlanSeesChangesAndMissingMoveSourceDoesNotExecute", { try $0.testJournalFreshPlanSeesChangesAndMissingMoveSourceDoesNotExecute() }),
    ("testJournalRestoredMergeRequiresIndividualDecisionsAgain", { try $0.testJournalRestoredMergeRequiresIndividualDecisionsAgain() }),
    ("testSchedulerRestoredWorkCannotStartOrDisappearWithFinishedHistory", { try $0.testSchedulerRestoredWorkCannotStartOrDisappearWithFinishedHistory() }),
    ("testTransferSizeUnitsAndExactBoundaries", { try $0.testTransferSizeUnitsAndExactBoundaries() }),
    ("testTransferFilterOldSchemaAndMetadataRoundTrip", { try $0.testTransferFilterOldSchemaAndMetadataRoundTrip() }),
    ("testCopySizeBoundsIncludeBothEndsAndEmptyFiles", { try $0.testCopySizeBoundsIncludeBothEndsAndEmptyFiles() }),
    ("testCopyDateBoundsUseInclusiveStartAndExclusiveEnd", { try $0.testCopyDateBoundsUseInclusiveStartAndExclusiveEnd() }),
    ("testMetadataFiltersCombineWithNamesAndMergeDecisions", { try $0.testMetadataFiltersCombineWithNamesAndMergeDecisions() }),
    ("testMetadataFiltersExcludeLinksWithoutCopyingTheirTargets", { try $0.testMetadataFiltersExcludeLinksWithoutCopyingTheirTargets() }),
    ("testInvalidMetadataBoundsBlockBeforeAnyCopy", { try $0.testInvalidMetadataBoundsBlockBeforeAnyCopy() }),
    ("testStructureCopyIgnoresFileMetadataConditions", { try $0.testStructureCopyIgnoresFileMetadataConditions() }),
    ("testMetadataPlanRejectsExcludedFileEnteringRange", { try $0.testMetadataPlanRejectsExcludedFileEnteringRange() }),
    ("testCopyProfilesRoundTripDropsUnknownPathFields", { try $0.testCopyProfilesRoundTripDropsUnknownPathFields() }),
    ("testCopyProfileNamesNormalizeAndRejectDuplicatesWithoutMutation", { try $0.testCopyProfileNamesNormalizeAndRejectDuplicatesWithoutMutation() }),
    ("testCopyProfileUpdatingKeepsIdentityAndOtherRecords", { try $0.testCopyProfileUpdatingKeepsIdentityAndOtherRecords() }),
    ("testCopyProfileCapacityAndInvalidFilterKeepExistingData", { try $0.testCopyProfileCapacityAndInvalidFilterKeepExistingData() }),
    ("testCopyProfileCorruptUnknownAndDuplicateDocumentsAreRejected", { try $0.testCopyProfileCorruptUnknownAndDuplicateDocumentsAreRejected() }),

    ("testMergePreservesExtraDestinationFilesAndDirectoryPermissions", { try $0.testMergePreservesExtraDestinationFilesAndDirectoryPermissions() }),
    ("testUnresolvedMergeConflictPreventsEveryDestinationChange", { try $0.testUnresolvedMergeConflictPreventsEveryDestinationChange() }),
    ("testMergeIndividualSkipKeepBothAndReplaceWithBackup", { try $0.testMergeIndividualSkipKeepBothAndReplaceWithBackup() }),
    ("testMergeSkipPolicyAndFilterPreserveUnselectedContents", { try $0.testMergeSkipPolicyAndFilterPreserveUnselectedContents() }),
    ("testMergeTypeConflictsMustBeSkippedWithoutTraversingLinks", { try $0.testMergeTypeConflictsMustBeSkippedWithoutTraversingLinks() }),
    ("testMergeRejectsChangedTargetsBeforeFirstPublication", { try $0.testMergeRejectsChangedTargetsBeforeFirstPublication() }),
    ("testMergeRejectsOccupiedAlternateNameWithoutChoosingAnother", { try $0.testMergeRejectsOccupiedAlternateNameWithoutChoosingAnother() }),
    ("testMergeRejectsChangedSourceAndReplacedTargetDirectory", { try $0.testMergeRejectsChangedSourceAndReplacedTargetDirectory() }),
    ("testMergeRejectsParentLinkReplacementDuringNativeCopy", { try $0.testMergeRejectsParentLinkReplacementDuringNativeCopy() }),
    ("testMergeRejectsTargetEditsDuringCopyWithoutOverwritingThem", { try $0.testMergeRejectsTargetEditsDuringCopyWithoutOverwritingThem() }),
    ("testMergeCancellationKeepsCompletedFilesAndCurrentOldTarget", { try $0.testMergeCancellationKeepsCompletedFilesAndCurrentOldTarget() }),
    ("testMergeNewDirectoriesPreserveReadOnlyModeAndAttributes", { try $0.testMergeNewDirectoriesPreserveReadOnlyModeAndAttributes() }),
    ("testMergeUndoRestoresReplacedFilesAndPreservesExtras", { try $0.testMergeUndoRestoresReplacedFilesAndPreservesExtras() }),
    ("testMergeSelectionRemovesUnselectedConflictsAndDuplicateNamesFail", { try $0.testMergeSelectionRemovesUnselectedConflictsAndDuplicateNamesFail() }),
    ("testMergeUnrelatedDestinationEditsArePreservedAndMovesRejected", { try $0.testMergeUnrelatedDestinationEditsArePreservedAndMovesRejected() }),
    ("testFilteredFolderReplacementKeepsPreviousFolderAsBackup", { try $0.testFilteredFolderReplacementKeepsPreviousFolderAsBackup() }),
    ("testCopyFilterMasksExcludeUnicodeAndExtensionlessNames", { try $0.testCopyFilterMasksExcludeUnicodeAndExtensionlessNames() }),
    ("testCopyFilterRegularExpressionsAndInvalidInputs", { try $0.testCopyFilterRegularExpressionsAndInvalidInputs() }),
    ("testFilteredCopyMatchesPreviewAndByteCountExactly", { try $0.testFilteredCopyMatchesPreviewAndByteCountExactly() }),
    ("testCopyFilterKeepsOrPrunesEmptyOutputFolders", { try $0.testCopyFilterKeepsOrPrunesEmptyOutputFolders() }),
    ("testCopyFilterCanLimitToDirectChildren", { try $0.testCopyFilterCanLimitToDirectChildren() }),
    ("testCopyFilterPrunesExcludedSubtreesBeforeReadingTheirContents", { try $0.testCopyFilterPrunesExcludedSubtreesBeforeReadingTheirContents() }),
    ("testStructureOnlyCopiesFoldersAndNoLinksOrFileData", { try $0.testStructureOnlyCopiesFoldersAndNoLinksOrFileData() }),
    ("testCopyFilterTreatsSymbolicLinksAsLinksWithoutTraversal", { try $0.testCopyFilterTreatsSymbolicLinksAsLinksWithoutTraversal() }),
    ("testFilteredPlanRejectsChangedOrNewMatchingFilesBeforeAnyCopy", { try $0.testFilteredPlanRejectsChangedOrNewMatchingFilesBeforeAnyCopy() }),
    ("testCopyFilterNoMatchesAndEmptySelectionHaveDistinctResults", { try $0.testCopyFilterNoMatchesAndEmptySelectionHaveDistinctResults() }),
    ("testFilteredMoveStructureOnlyIsRejectedWithoutChangingSourceOrTarget", { try $0.testFilteredMoveStructureOnlyIsRejectedWithoutChangingSourceOrTarget() }),
    ("testFilteredCopyCancellationRetainsExistingTargetAndExcludedFiles", { try $0.testFilteredCopyCancellationRetainsExistingTargetAndExcludedFiles() }),
    ("testNativeCopyProgressAndMetadata", { try $0.testNativeCopyProgressAndMetadata() }),
    ("testPauseResumeInsideCopy", { try $0.testPauseResumeInsideCopy() }),
    ("testCancelPausedCopyKeepsPreviousDestination", { try $0.testCancelPausedCopyKeepsPreviousDestination() }),
    ("testPlanRejectsStaleSourcesBeforeAnyCopy", { try $0.testPlanRejectsStaleSourcesBeforeAnyCopy() }),
    ("testPlanRejectsNestedSourceMutation", { try $0.testPlanRejectsNestedSourceMutation() }),
    ("testPlanRejectsChangedDestinationAndReplacedParent", { try $0.testPlanRejectsChangedDestinationAndReplacedParent() }),
    ("testCopyRejectsTargetMutationWhileCopying", { try $0.testCopyRejectsTargetMutationWhileCopying() }),
    ("testCopyRejectsSourceMutationWhileCopying", { try $0.testCopyRejectsSourceMutationWhileCopying() }),
    ("testPlanSelectionAndSkipStates", { try $0.testPlanSelectionAndSkipStates() }),
    ("testNativeDirectoryCopyPreservesLinksAndReadOnlyMode", { try $0.testNativeDirectoryCopyPreservesLinksAndReadOnlyMode() }),
    ("testMovePlanDoesNotInventByteProgress", { try $0.testMovePlanDoesNotInventByteProgress() }),
    ("testSchedulerReordersAndRemovesOnlyWaitingWork", { try $0.testSchedulerReordersAndRemovesOnlyWaitingWork() }),
    ("testSchedulerPauseCancelAndResumeNext", { try $0.testSchedulerPauseCancelAndResumeNext() }),
    ("testSchedulerFailureContinuesAndClearsHistory", { try $0.testSchedulerFailureContinuesAndClearsHistory() }),
    ("testINIEncodingsAndLiteralValues", { try $0.testINIEncodingsAndLiteralValues() }),
    ("testSettingsProfileImportsActualLayoutAndActive64BitPlugins", { try $0.testSettingsProfileImportsActualLayoutAndActive64BitPlugins() }),
    ("testINISettingsImportRejectsUnrelatedAndOversizeFiles", { try $0.testINISettingsImportRejectsUnrelatedAndOversizeFiles() }),
    ("testINIImportSelectedFilenameAndAmbiguousFolder", { try $0.testINIImportSelectedFilenameAndAmbiguousFolder() }),
    ("testSevenZipRoundTripAndCompression", { try $0.testSevenZipRoundTripAndCompression() }),
    ("testOfficeTextAcrossRunsAndContentSearch", { try $0.testOfficeTextAcrossRunsAndContentSearch() }),
    ("testOfficeSpreadsheetOdtAndPowerPointText", { try $0.testOfficeSpreadsheetOdtAndPowerPointText() }),
    ("testOfficeXmlRejectsEntitiesCorruptionAndZipExpansion", { try $0.testOfficeXmlRejectsEntitiesCorruptionAndZipExpansion() }),
    ("testWindowsVersionResourceAndPEHeader", { try $0.testWindowsVersionResourceAndPEHeader() }),
    ("testBinaryInspectorHandlesMalformedAndUniversalHeaders", { try $0.testBinaryInspectorHandlesMalformedAndUniversalHeaders() }),
    ("testServerMutationsRejectLinkedDirectoryAncestors", { try $0.testServerMutationsRejectLinkedDirectoryAncestors() }),
    ("testServerMutationsRejectReplacedParentAfterPreview", { try $0.testServerMutationsRejectReplacedParentAfterPreview() }),
    ("testServerSFTPMkdirRenameAndDelete", { try $0.testServerSFTPMkdirRenameAndDelete() }),
    ("testServerFTPMkdirRenameAndDelete", { try $0.testServerFTPMkdirRenameAndDelete() }),
    ("testServerFTPSMkdirRenameAndDelete", { try $0.testServerFTPSMkdirRenameAndDelete() }),
    ("testServerDeleteReviewsCompleteTreeBeforeChangingIt", { try $0.testServerDeleteReviewsCompleteTreeBeforeChangingIt() }),
    ("testServerDeleteRejectsNewEntriesBeforeFirstChange", { try $0.testServerDeleteRejectsNewEntriesBeforeFirstChange() }),
    ("testServerRenameRejectsChangedSourceAndOccupiedTarget", { try $0.testServerRenameRejectsChangedSourceAndOccupiedTarget() }),
    ("testServerCreateRefusesNamesAddedAfterPreview", { try $0.testServerCreateRefusesNamesAddedAfterPreview() }),
    ("testServerMutationRejectsInvalidNamesAndCaseOnlyRename", { try $0.testServerMutationRejectsInvalidNamesAndCaseOnlyRename() }),
    ("testServerDeleteRefusesLinksAtAnyDepth", { try $0.testServerDeleteRefusesLinksAtAnyDepth() }),
    ("testServerMutationRejectsDifferentEndpointAndCancellation", { try $0.testServerMutationRejectsDifferentEndpointAndCancellation() }),
    ("testServerDeletePreservesNewFilesAppearingDuringExecution", { try $0.testServerDeletePreservesNewFilesAppearingDuringExecution() }),
    ("testServerDeleteCanCancelBetweenReviewedObjects", { try $0.testServerDeleteCanCancelBetweenReviewedObjects() }),
    ("testServerDeleteDepthLimitChangesNoFiles", { try $0.testServerDeleteDepthLimitChangesNoFiles() }),
    ("testServerEntriesNeverAliasLocalFileMetadata", { try $0.testServerEntriesNeverAliasLocalFileMetadata() }),
    ("testRemoteLoginFailureDoesNotRetryPasswordAsListingFallback", { try $0.testRemoteLoginFailureDoesNotRetryPasswordAsListingFallback() }),
    ("testRemoteTLSRejectsTrustedCertificateForWrongHost", { try $0.testRemoteTLSRejectsTrustedCertificateForWrongHost() }),
    ("testRemoteRejectsUnknownAndOverflowingListingSizes", { try $0.testRemoteRejectsUnknownAndOverflowingListingSizes() }),
    ("testRemoteDeletionMetadataFailureRestoresItsCredential", { try $0.testRemoteDeletionMetadataFailureRestoresItsCredential() }),
    ("testRemoteCredentialReplacementNeverReusesSecretsForChangedLogin", { try $0.testRemoteCredentialReplacementNeverReusesSecretsForChangedLogin() }),
    ("testRemoteFTPSPauseResumeAndCancelInsideDownload", { try $0.testRemoteFTPSPauseResumeAndCancelInsideDownload() }),
    ("testRemoteProfilesExcludePasswordsAndScopeCredentialsToEndpoint", { try $0.testRemoteProfilesExcludePasswordsAndScopeCredentialsToEndpoint() }),
    ("testRemoteProfileStoreRollsBackBothStoresOnWriteFailure", { try $0.testRemoteProfileStoreRollsBackBothStoresOnWriteFailure() }),
    ("testRemoteProfileDeletionMissingCredentialsAndStaleEdits", { try $0.testRemoteProfileDeletionMissingCredentialsAndStaleEdits() }),
    ("testRemoteProfileValidationNormalizationAndLimit", { try $0.testRemoteProfileValidationNormalizationAndLimit() }),
    ("testRemoteSFTPRecursiveRoundTripWithEmptyFoldersAndUnicode", { try $0.testRemoteSFTPRecursiveRoundTripWithEmptyFoldersAndUnicode() }),
    ("testRemoteSFTPExclusiveCreateAndLinkRejection", { try $0.testRemoteSFTPExclusiveCreateAndLinkRejection() }),
    ("testRemotePlansRejectChangedSourcesNewEntriesAndCaseCollisions", { try $0.testRemotePlansRejectChangedSourcesNewEntriesAndCaseCollisions() }),
    ("testRemoteDownloadRejectsReplacedParentAndCancelsWithoutPublication", { try $0.testRemoteDownloadRejectsReplacedParentAndCancelsWithoutPublication() }),
    ("testRemoteSFTPPauseResumeAndCancelInsideFile", { try $0.testRemoteSFTPPauseResumeAndCancelInsideFile() }),
    ("testRemoteTLSRefusesPlaintextDowngradeBeforeSendingPassword", { try $0.testRemoteTLSRefusesPlaintextDowngradeBeforeSendingPassword() }),
    ("testRemoteFTPSRecursiveTransfersValidateTLSAndBothDataDirections", { try $0.testRemoteFTPSRecursiveTransfersValidateTLSAndBothDataDirections() }),
    ("testFTPLoopbackListingDownloadAndUpload", { try $0.testFTPLoopbackListingDownloadAndUpload() }),
    ("testRemoteListingHandlesSpacesAndUnicode", { try $0.testRemoteListingHandlesSpacesAndUnicode() }),
    ("testRemoteCommandsRejectInjectionAndMalformedListings", { try $0.testRemoteCommandsRejectInjectionAndMalformedListings() }),
    ("testProcessInputAndNonzeroExit", { try $0.testProcessInputAndNonzeroExit() }),
    ("testArchiveNameSearch", { try $0.testArchiveNameSearch() }),
    ("testRelativePathsPreserveSymlinkNames", { try $0.testRelativePathsPreserveSymlinkNames() }),
    ("testCopyNeverOverwritesByDefault", { try $0.testCopyNeverOverwritesByDefault() }),
    ("testCopyKeepBothAndSkip", { try $0.testCopyKeepBothAndSkip() }),
    ("testReplaceKeepsRecoverableBackup", { try $0.testReplaceKeepsRecoverableBackup() }),
    ("testMovePreservesContentAndRemovesSource", { try $0.testMovePreservesContentAndRemovesSource() }),
    ("testUndoRefusesModifiedTarget", { try $0.testUndoRefusesModifiedTarget() }),
    ("testDirectoryCannotBeCopiedIntoItselfViaSymlink", { try $0.testDirectoryCannotBeCopiedIntoItselfViaSymlink() }),
    ("testCancellationLeavesNoDestination", { try $0.testCancellationLeavesNoDestination() }),
    ("testFileCreationDoesNotTruncate", { try $0.testFileCreationDoesNotTruncate() }),
    ("testRenamePreviewAndApplyWithUnicode", { try $0.testRenamePreviewAndApplyWithUnicode() }),
    ("testRenameCyclesAreSafe", { try $0.testRenameCyclesAreSafe() }),
    ("testRenameRejectsDuplicateNamesAndTraversal", { try $0.testRenameRejectsDuplicateNamesAndTraversal() }),
    ("testGlobAndRegexFilter", { try $0.testGlobAndRegexFilter() }),
    ("testSearchContentAndHidden", { try $0.testSearchContentAndHidden() }),
    ("testDuplicatesUseContentNotOnlySize", { try $0.testDuplicatesUseContentNotOnlySize() }),
    ("testHashKnownVectors", { try $0.testHashKnownVectors() }),
    ("testChecksumManifestRejectsOutsideFiles", { try $0.testChecksumManifestRejectsOutsideFiles() }),
    ("testCompareAndNonDeletingSync", { try $0.testCompareAndNonDeletingSync() }),
    ("testSyncRejectsStalePreviewBeforeAnyChanges", { try $0.testSyncRejectsStalePreviewBeforeAnyChanges() }),
    ("testSyncTypeConflictsAreNotOverwritten", { try $0.testSyncTypeConflictsAreNotOverwritten() }),
    ("testZIPAndTARArchiveRoundTrip", { try $0.testZIPAndTARArchiveRoundTrip() }),
    ("testArchiveTraversalRollsBackStaging", { try $0.testArchiveTraversalRollsBackStaging() }),
    ("testArchiveBudgetAndDuplicateEntriesFailSafely", { try $0.testArchiveBudgetAndDuplicateEntriesFailSafely() }),
    ("testArchivePathValidationHandlesEmptyAndAbsolute", { try $0.testArchivePathValidationHandlesEmptyAndAbsolute() }),
    ("testArchiveDoesNotFollowSymlinks", { try $0.testArchiveDoesNotFollowSymlinks() }),
    ("testSplitJoinAndTamperDetection", { try $0.testSplitJoinAndTamperDetection() }),
    ("testSplitJoinEmptyFile", { try $0.testSplitJoinEmptyFile() }),
    ("testTopLevelSelectionDoesNotDoubleProcessDescendants", { try $0.testTopLevelSelectionDoesNotDoubleProcessDescendants() }),
    ("testResumeRejectsPrefixModifiedDuringTheResumedWrite", { try $0.testResumeRejectsPrefixModifiedDuringTheResumedWrite() }),
    ("testBackupExternalCatalogEditBlocksRestoringIntoAbsentTarget", { try $0.testBackupExternalCatalogEditBlocksRestoringIntoAbsentTarget() }),
    ("testFilteredMoveCrashBeforeSourceRemovalKeepsRecoverableSource", { try $0.testFilteredMoveCrashBeforeSourceRemovalKeepsRecoverableSource() }),
    ("testFilteredMoveRefusesDestinationEditedAfterPublication", { try $0.testFilteredMoveRefusesDestinationEditedAfterPublication() }),
    ("testDiscardUsesTrashAndPreservesSourceAndCurrentTarget", { try $0.testDiscardUsesTrashAndPreservesSourceAndCurrentTarget() }),
    ("testResumeFileAfterReopeningPrivateStorage", { try $0.testResumeFileAfterReopeningPrivateStorage() }),
    ("testResumeAfterActualAbruptProcessExit", { try $0.testResumeAfterActualAbruptProcessExit() }),
    ("testResumeFolderReusesCompletedAndPartialFiles", { try $0.testResumeFolderReusesCompletedAndPartialFiles() }),
    ("testResumeRejectsSourceEditEvenWithRestoredModificationDate", { try $0.testResumeRejectsSourceEditEvenWithRestoredModificationDate() }),
    ("testResumeRefusesTamperedPrefixWithoutOverwritingIt", { try $0.testResumeRefusesTamperedPrefixWithoutOverwritingIt() }),
    ("testResumeRejectsHardLinkedPartial", { try $0.testResumeRejectsHardLinkedPartial() }),
    ("testResumeRejectsReplacedParentAndSymlinkStage", { try $0.testResumeRejectsReplacedParentAndSymlinkStage() }),
    ("testResumeCanCancelDuringPrefixVerification", { try $0.testResumeCanCancelDuringPrefixVerification() }),
    ("testResumePreservesConflictingTargetUntilPublication", { try $0.testResumePreservesConflictingTargetUntilPublication() }),
    ("testBackupRestoreAfterRestartPreservesCurrentVersionAsNewBackup", { try $0.testBackupRestoreAfterRestartPreservesCurrentVersionAsNewBackup() }),
    ("testBackupRestoreRefusesStaleTargetAndChangedBackup", { try $0.testBackupRestoreRefusesStaleTargetAndChangedBackup() }),
    ("testBackupFolderRestorationRetainsCurrentFolderTree", { try $0.testBackupFolderRestorationRetainsCurrentFolderTree() }),
    ("testHistoryExternalEditsBlockBeforeAnyDataCopy", { try $0.testHistoryExternalEditsBlockBeforeAnyDataCopy() }),
    ("testHistoryDamagedDocumentIsNeverReplaced", { try $0.testHistoryDamagedDocumentIsNeverReplaced() }),
    ("testUnavailableRecoveryEntryCanBeForgottenWithoutDeletingData", { try $0.testUnavailableRecoveryEntryCanBeForgottenWithoutDeletingData() }),
    ("testFilteredMovePreservesExcludedFilesAndSupportsSessionUndo", { try $0.testFilteredMovePreservesExcludedFilesAndSupportsSessionUndo() }),
    ("testFilteredMoveConflictsAndStalePlanNeverRemoveSource", { try $0.testFilteredMoveConflictsAndStalePlanNeverRemoveSource() }),
    ("testFilteredMoveCancellationRetainsAllSourcesAndPreviousTarget", { try $0.testFilteredMoveCancellationRetainsAllSourcesAndPreviousTarget() }),
    ("testFilteredMoveRulesPersistAsJournalVersionThree", { try $0.testFilteredMoveRulesPersistAsJournalVersionThree() }),
    ("testListingBatchesPreserveMetadataAndHiddenRules", { try $0.testListingBatchesPreserveMetadataAndHiddenRules() }),
    ("testListingCancellationStopsAfterPublishedBatch", { try $0.testListingCancellationStopsAfterPublishedBatch() }),
    ("testEditedSingleNameRetainsOriginalVersionAndLiteralText", { try $0.testEditedSingleNameRetainsOriginalVersionAndLiteralText() })
]
var failed = 0
let testFilter = CommandLine.arguments.firstIndex(of:"--filter").flatMap { CommandLine.arguments.indices.contains($0+1) ? CommandLine.arguments[$0+1] : nil }
let selectedTests = tests.filter { testFilter.map($0.0.localizedCaseInsensitiveContains) ?? true }
guard !selectedTests.isEmpty else { fputs("Keine passenden Tests.\n",stderr);exit(2) }
for (name, test) in selectedTests {
    let suite = CoreTests(); assertionFailures = []
    do { try suite.setUpWithError(); try test(suite) } catch { assertionFailures.append(error.localizedDescription) }
    do { try suite.tearDownWithError() } catch { assertionFailures.append("Cleanup: " + error.localizedDescription) }
    if assertionFailures.isEmpty { print("PASS " + name) } else { failed += 1; print("FAIL " + name + "\n" + assertionFailures.joined(separator:"\n")) }
}
print("\(selectedTests.count - failed)/\(selectedTests.count) tests passed")
exit(failed == 0 ? 0 : 1)
