import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    func testFolderTreeReadExposesOnlyVisibleOrdinaryDirectories() throws {
        let directory = try folder("Tree"),a = try folder("Tree/Alpha"),b = try folder("Tree/Grüße")
        try folder("Tree/.hidden");try folder("Tree/Preview.app");try file("Tree/notes.txt")
        try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("Alias"),withDestinationURL:a)
        try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("Broken"),withDestinationURL:directory.appendingPathComponent("Missing"))
        XCTAssertEqual(try FolderNavigation.children(of:directory),[a,b])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:directory.appendingPathComponent("Alias").path),a.path)
    }
    func testFolderTreeMissingAndFileBranchesThrowInsteadOfAppearingEmpty() throws {
        let file = try file("not-a-folder.txt","preserved"),missing = root.appendingPathComponent("Missing")
        XCTAssertThrowsError(try FolderNavigation.children(of:missing))
        XCTAssertThrowsError(try FolderNavigation.children(of:file))
        XCTAssertEqual(try read(file),"preserved")
    }
    func testFolderTreeUnreadableBranchCanBeRetriedAfterPermissionsRestore() throws {
        let directory = try folder("Locked"),child = try folder("Locked/Child")
        guard geteuid() != 0 else { throw CommanderError.message("Berechtigungsprüfung benötigt ein unprivilegiertes Testkonto.") }
        defer { chmod(directory.path,0o700) }
        XCTAssertEqual(chmod(directory.path,0),0)
        XCTAssertThrowsError(try FolderNavigation.children(of:directory))
        XCTAssertEqual(chmod(directory.path,0o700),0)
        XCTAssertEqual(try FolderNavigation.children(of:directory),[child])
    }
    func testFolderTreeFreshReadSeesCreatedRenamedAndRemovedChildren() throws {
        let directory = try folder("Tree"),first = try folder("Tree/First")
        XCTAssertEqual(try FolderNavigation.children(of:directory),[first])
        let second = try folder("Tree/Second"),renamed = directory.appendingPathComponent("Renamed")
        try FileManager.default.moveItem(at:first,to:renamed)
        XCTAssertEqual(Set(try FolderNavigation.children(of:directory)),Set([renamed,second]))
        try FileManager.default.removeItem(at:second)
        XCTAssertEqual(try FolderNavigation.children(of:directory),[renamed])
    }
    func testFolderTreeReadableButNonSearchableBranchCannotMasqueradeAsEmpty() throws {
        let directory = try folder("Restricted"),child = try folder("Restricted/Child")
        guard geteuid() != 0 else { throw CommanderError.message("Berechtigungsprüfung benötigt ein unprivilegiertes Testkonto.") }
        defer { chmod(directory.path,0o700) }
        XCTAssertEqual(chmod(directory.path,0o400),0)
        // POSIX can enumerate these names even though resolving child metadata is denied.
        guard let handle = opendir(directory.path) else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        var names:[String] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to:&entry.pointee.d_name) { value in value.withMemoryRebound(to:CChar.self,capacity:Int(NAME_MAX)+1) { String(cString:$0) } }
            if name != ".",name != ".." { names.append(name) }
        }
        closedir(handle)
        XCTAssertEqual(names,[child.lastPathComponent])
        XCTAssertThrowsError(try FolderNavigation.children(of:directory))
        XCTAssertEqual(chmod(directory.path,0o700),0)
        XCTAssertEqual(try FolderNavigation.children(of:directory),[child])
    }
    func testFolderTreeRejectedRootLinkNeverTraversesItsTarget() throws {
        let directory = try folder("Outside"),child = try folder("Outside/Child"),link = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:directory)
        XCTAssertThrowsError(try FolderNavigation.children(of:link))
        XCTAssertTrue(FileSystem.isDirectory(child));XCTAssertTrue(FileSystem.isSymlink(link))
    }
    func testFolderTreeCancelledReadLeavesDirectoryUnchanged() throws {
        let directory = try folder("Tree"),child = try folder("Tree/Child"),token = CancellationToken();token.cancel()
        XCTAssertThrowsError(try FolderNavigation.children(of:directory,token:token))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path),[child.lastPathComponent])
    }
    func testLinkedNavigationDescendsMultipleUnicodeComponents() throws {
        let old = URL(fileURLWithPath:"/Source"),new = old.appendingPathComponent("Grüße/A B"),other = URL(fileURLWithPath:"/Other")
        XCTAssertEqual(FolderNavigation.linkedDestination(from:old,to:new,opposite:other)?.path,"/Other/Grüße/A B")
    }
    func testLinkedNavigationAscendsExactNumberOfComponents() throws {
        XCTAssertEqual(FolderNavigation.linkedDestination(from:URL(fileURLWithPath:"/Source/A/Deep"),to:URL(fileURLWithPath:"/Source"),opposite:URL(fileURLWithPath:"/Other/B/Deep"))?.path,"/Other")
    }
    func testLinkedNavigationRefusesUnrelatedAndSameLocations() throws {
        let a = URL(fileURLWithPath:"/Source/A"),other = URL(fileURLWithPath:"/Other")
        XCTAssertTrue(FolderNavigation.linkedDestination(from:a,to:URL(fileURLWithPath:"/Source/A2"),opposite:other) == nil)
        XCTAssertTrue(FolderNavigation.linkedDestination(from:a,to:a,opposite:other) == nil)
        XCTAssertTrue(FolderNavigation.linkedDestination(from:a,to:URL(fileURLWithPath:"/Unrelated"),opposite:other) == nil)
    }
    func testLinkedNavigationDoesNotClampAboveOppositeFilesystemRoot() throws {
        XCTAssertTrue(FolderNavigation.linkedDestination(from:URL(fileURLWithPath:"/Source/A/B"),to:URL(fileURLWithPath:"/Source"),opposite:URL(fileURLWithPath:"/Other")) == nil)
        XCTAssertEqual(FolderNavigation.linkedDestination(from:URL(fileURLWithPath:"/Source/A"),to:URL(fileURLWithPath:"/Source"),opposite:URL(fileURLWithPath:"/Other"))?.path,"/")
    }
    func testLinkedNavigationRejectsRemoteAndArchiveContexts() throws {
        let old = URL(fileURLWithPath:"/Source"),new = old.appendingPathComponent("A"),other = URL(fileURLWithPath:"/Other")
        for remote in [URL(string:"sftp://example.invalid/Source")!,URL(string:"zwei-archive://fixture/")!,URL(string:"file://example.invalid/Source")!] {
            XCTAssertTrue(FolderNavigation.linkedDestination(from:remote,to:new,opposite:other) == nil)
            XCTAssertTrue(FolderNavigation.linkedDestination(from:old,to:remote,opposite:other) == nil)
            XCTAssertTrue(FolderNavigation.linkedDestination(from:old,to:new,opposite:remote) == nil)
        }
    }
    func testLinkedNavigationNormalizesDotsWithoutFollowingDiskAliases() throws {
        XCTAssertEqual(FolderNavigation.linkedDestination(from:URL(fileURLWithPath:"/Source/./A"),to:URL(fileURLWithPath:"/Source/A/../A/Deep"),opposite:URL(fileURLWithPath:"/Other/./B"))?.path,"/Other/B/Deep")
    }
}
