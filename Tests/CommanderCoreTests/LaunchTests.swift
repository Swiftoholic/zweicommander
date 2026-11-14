import Foundation
import CommanderCore
import Darwin

extension CoreTests {
    private func launchPath(_ url: URL) -> String { FileSystem.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).path }
    func testLaunchEmptyRequestDoesNotInventTargets() throws {
        let request = try LaunchRequest.parse([])
        XCTAssertTrue(request.isEmpty);XCTAssertTrue(request.left == nil);XCTAssertTrue(request.right == nil);XCTAssertTrue(request.active == nil)
    }
    func testLaunchTwoDirectoriesAndExplicitActiveSide() throws {
        let left = try folder("Links mit Leerzeichen"), right = try folder("Rechts 🎵")
        let request = try LaunchRequest.parse(["--left",left.path,"--right",right.path,"--active","right","--new-tabs"])
        XCTAssertEqual(request.left?.directory,FileSystem.canonical(left));XCTAssertEqual(request.right?.directory,FileSystem.canonical(right))
        XCTAssertEqual(request.active,.right);XCTAssertTrue(request.newTabs);try request.validate()
    }
    func testLaunchPositionalFileSelectsItInItsParent() throws {
        let file = try file("Rechnungen/Grüße ' $ (x).txt","unverändert")
        let request = try LaunchRequest.parse([file.path])
        XCTAssertEqual(request.left?.directory,FileSystem.canonical(file.deletingLastPathComponent()))
        XCTAssertEqual(request.left?.selection?.path,launchPath(file));XCTAssertEqual(try Data(contentsOf:file),Data("unverändert".utf8))
    }
    func testLaunchRelativePathsAndExplicitSelection() throws {
        let directory = try folder("Projekt"), file = try file("Projekt/Plan.txt","plan")
        let request = try LaunchRequest.parse(["--left","Projekt","--select-left","Plan.txt"],directory:root)
        XCTAssertEqual(request.left?.directory,FileSystem.canonical(directory));XCTAssertEqual(request.left?.selection?.path,launchPath(file))
    }
    func testLaunchTwoPositionalPathsAndMixedRightOption() throws {
        let left = try folder("Links"),right = try folder("Rechts")
        let a = try LaunchRequest.parse([left.path,right.path]),b = try LaunchRequest.parse([left.path,"--right",right.path])
        XCTAssertEqual(a,b)
        XCTAssertThrowsError(try LaunchRequest.parse([left.path,right.path,"--right",right.path]))
        XCTAssertThrowsError(try LaunchRequest.parse([left.path,"--left",left.path]))
    }
    func testLaunchLocalFileURLsAndUnicodePercentEscapes() throws {
        let directory = try folder("Grüße und Bilder"),file = try file("Grüße und Bilder/Bild #1.txt","content")
        let request = try LaunchRequest.parse(["--left",directory.absoluteString,"--select-left",file.absoluteString])
        XCTAssertEqual(request.left?.selection?.path,launchPath(file))
        let localhost = directory.absoluteString.replacingOccurrences(of:"file:///",with:"file://localhost/")
        XCTAssertEqual(try LaunchRequest.parse([localhost]).left?.directory.path,FileSystem.canonical(directory).path)
    }
    func testLaunchRejectsRemoteCredentialAndQueryURLs() throws {
        for path in ["https://example.invalid/path","file://remote.invalid/path","file://name:password@localhost/","file:///tmp?value=1","file:///tmp#fragment","file:///tmp%00bad"] {
            XCTAssertThrowsError(try LaunchRequest.parse([path]))
        }
    }
    func testLaunchRejectsMissingDuplicateUnknownOrAmbiguousOptions() throws {
        let directory = try folder("Target")
        for args in [["--left"],["--active","top"],["--bogus"],["--left",""],["--left",directory.path,"--left",directory.path],["--new-tabs"],["--left",directory.path,"--new-tabs","--new-tabs"],["--select-left","item"],[directory.path,directory.path,directory.path],["--export-settings-profile","file.json"]] {
            XCTAssertThrowsError(try LaunchRequest.parse(args))
        }
    }
    func testLaunchSelectionCannotEscapeChosenFolder() throws {
        let left = try folder("Left");_ = try file("Elsewhere.txt","else")
        XCTAssertThrowsError(try LaunchRequest.parse(["--left",left.path,"--select-left","../Elsewhere.txt"]))
        XCTAssertThrowsError(try LaunchRequest.parse(["--left",left.path,"--select-left","missing.txt"]))
    }
    func testLaunchSelectsDanglingLinkWithoutFollowingIt() throws {
        let directory = try folder("Links"),link = directory.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:"missing-target")
        let request = try LaunchRequest.parse([link.path]);XCTAssertEqual(request.left?.selection?.path,launchPath(link));try request.validate()
    }
    func testLaunchDetectsReplacedFileBeforeApplyingEitherSide() throws {
        let a = try file("A/a.txt","a"),b = try file("B/b.txt","b"),request = try LaunchRequest.parse([a.path,b.path])
        try FileManager.default.moveItem(at:b,to:b.deletingLastPathComponent().appendingPathComponent("old"));try Data("b".utf8).write(to:b)
        XCTAssertThrowsError(try request.validate());XCTAssertEqual(try Data(contentsOf:a),Data("a".utf8))
    }
    func testLaunchDetectsChangedSelectedFileButAllowsUnrelatedDirectoryActivity() throws {
        let file = try file("Work/a.txt","a"),request = try LaunchRequest.parse([file.path])
        _ = try self.file("Work/unrelated.txt","other");try request.validate()
        try Data("changed".utf8).write(to:file);XCTAssertThrowsError(try request.validate())
    }
    func testLaunchDetectsReplacedDirectory() throws {
        let folder = try folder("Work"),request = try LaunchRequest.parse([folder.path])
        try FileManager.default.moveItem(at:folder,to:root.appendingPathComponent("Old"));try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        XCTAssertThrowsError(try request.validate())
    }
    func testLaunchRejectsSpecialTargetsAndOversizedArguments() throws {
        let fifo = root.appendingPathComponent("pipe");XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        XCTAssertThrowsError(try LaunchRequest.parse([fifo.path]))
        XCTAssertThrowsError(try LaunchRequest.parse([String(repeating:"x",count:16_385)]))
        XCTAssertThrowsError(try LaunchRequest.parse(Array(repeating:"--",count:33)))
        XCTAssertThrowsError(try LaunchRequest.parse(["bad\0name"]))
    }
    func testLaunchLiteralDashFilenameAndFinderProcessSerialNumber() throws {
        let target = try folder("--named")
        XCTAssertEqual(try LaunchRequest.parse(["--","--named"],directory:root).left?.directory,FileSystem.canonical(target))
        XCTAssertTrue(try LaunchRequest.parse(["-psn_0_12345"]).isEmpty)
        XCTAssertThrowsError(try LaunchRequest.parse(["-psn_"]))
    }
    func testLaunchHomeAndActiveOnlyRequests() throws {
        XCTAssertEqual(try LaunchRequest.parse(["~"]).left?.directory,FileSystem.canonical(FileManager.default.homeDirectoryForCurrentUser))
        XCTAssertThrowsError(try LaunchRequest.parse(["~someone"]))
        let request = try LaunchRequest.parse(["--active","right"]);XCTAssertEqual(request.active,.right);XCTAssertTrue(request.left == nil)
    }
    func testLaunchLegacyImportArgumentsDoNotBecomeNavigationTargets() throws {
        let request = try LaunchRequest.parse(["--import-settings","sample.ini","--export-settings-profile","sample.json"])
        XCTAssertTrue(request.isEmpty)
        XCTAssertEqual(request.settingsImportPath,"sample.ini");XCTAssertEqual(request.settingsExportPath,"sample.json")
        XCTAssertThrowsError(try LaunchRequest.parse(["--import-settings","sample.ini","--unexpected"]))
    }
    func testLaunchLiteralOptionNamesCannotRequestImportExportOrInspection() throws {
        for name in ["--import-settings","--export-settings-profile","--inspect-binary"] {
            let path = try file(name,"literal file"),other = try file("ordinary.ini","[Display]\nShowHidden=1")
            let request = try LaunchRequest.parse(["--",name,other.lastPathComponent],directory:root)
            XCTAssertEqual(request.left?.selection?.path,launchPath(path));XCTAssertEqual(request.right?.selection?.path,launchPath(other))
            XCTAssertTrue(request.settingsImportPath == nil && request.settingsExportPath == nil)
            try request.validate()
        }
    }
}
