import Foundation
import CommanderCore

extension CoreTests {
    func testLaunchURLRoundTripBothPanesAndUnicodeSelection() throws {
        let left = try file("A/Grüße & #1.txt","a"),right = try file("B/Other.txt","b")
        let request = try LaunchRequest.parse([left.path,right.path,"--active","right","--new-tabs"])
        let result = try LaunchRequest.navigationRequest(request.navigationURL())
        XCTAssertEqual(result.left?.selection?.lastPathComponent,left.lastPathComponent)
        XCTAssertEqual(result.right?.selection?.lastPathComponent,right.lastPathComponent)
        XCTAssertEqual(result.active,.right);XCTAssertTrue(result.newTabs);try result.validate()
    }
    func testLaunchURLRejectsUnknownDuplicateAndCredentialValues() throws {
        for value in ["zweicommander://open?active=left&active=right","zweicommander://open?import-settings=file.ini","zweicommander://open?export-settings-profile=file.json","zweicommander://name:password@open?active=left","zweicommander://open:123/?active=left","zweicommander://open/path?active=left","zweicommander://open?active=left#fragment","https://open?active=left","zweicommander://open?active="] {
            XCTAssertThrowsError(try LaunchRequest.navigationRequest(URL(string:value)!))
        }
    }
    func testLaunchURLCannotTransportSettingsImport() throws {
        let request = try LaunchRequest.parse(["--import-settings","sample.ini"])
        XCTAssertThrowsError(try request.navigationURL())
    }
    func testLaunchURLSelectsLiteralFlagNamedFileWithoutEnablingCommands() throws {
        let target = try file("--import-settings","literal")
        let request = try LaunchRequest.parse(["--",target.path])
        let restored = try LaunchRequest.navigationRequest(request.navigationURL())
        XCTAssertEqual(restored.left?.selection?.lastPathComponent,"--import-settings")
        XCTAssertTrue(restored.settingsImportPath == nil && restored.settingsExportPath == nil)
    }
    func testLaunchURLChecksFolderBoundariesAndCurrentTargets() throws {
        let directory = try folder("Selected"),elsewhere = try file("Elsewhere.txt","outside")
        var value = URLComponents();value.scheme = LaunchRequest.urlScheme;value.host = "open"
        value.queryItems = [.init(name:"left",value:directory.path),.init(name:"select-left",value:elsewhere.path)]
        XCTAssertThrowsError(try LaunchRequest.navigationRequest(value.url!))
        let target = try file("Selected/Present.txt","inside"),request = try LaunchRequest.parse([target.path]),url = try request.navigationURL()
        try FileManager.default.removeItem(at:target)
        XCTAssertThrowsError(try LaunchRequest.navigationRequest(url))
    }
    func testLaunchURLEmptyActiveAndInvalidNewTabRequests() throws {
        XCTAssertTrue(try LaunchRequest.navigationRequest(URL(string:"zweicommander://open")!).isEmpty)
        XCTAssertEqual(try LaunchRequest.navigationRequest(URL(string:"ZWEICOMMANDER://OPEN?active=right")!).active,.right)
        for value in ["zweicommander://open?new-tabs=0","zweicommander://open?new-tabs=1","zweicommander://open?active=top"] {
            XCTAssertThrowsError(try LaunchRequest.navigationRequest(URL(string:value)!))
        }
    }
    func testLaunchURLLocalFileSchemeAndLocalhostAreCaseInsensitive() throws {
        let target = try file("Case sensitive folder/Name.txt","literal")
        var parts = URLComponents(url:target,resolvingAgainstBaseURL:false)!
        parts.scheme = "FILE";parts.host = "LOCALHOST"
        let request = try LaunchRequest.parse([parts.string!])
        XCTAssertEqual(request.left?.selection?.lastPathComponent,target.lastPathComponent);try request.validate()
    }
}
