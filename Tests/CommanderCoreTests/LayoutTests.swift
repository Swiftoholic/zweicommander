import Foundation
import CommanderCore

extension CoreTests {
    private func layoutFixture(_ name:String = "Arbeit") -> LayoutProfile {
        LayoutProfile(name:name,left:LayoutPane(tabs:[LayoutTab(path:"/Volumes/Offline/Quellen")]),right:LayoutPane(tabs:[LayoutTab(path:"/")]))
    }
    func testLayoutProfileRoundTripPreservesCompleteWorkspace() throws {
        var value = layoutFixture();value.left.tabs.append(LayoutTab(path:"/Volumes/Offline/Grüße ' $ (x)\nOrdner",title:"Bilder",lockMode:.fixed,view:.init(display:.icons,sortKey:"modified",ascending:false,foldersFirst:false,treeVisible:true),filter:"*.png;*.jpg"));value.left.selected = 1
        value.right.tabs[0].lockMode = .closeOnly;value.layout.vertical = false;value.layout.ratio = 0.62;value.layout.quickVisible = true;value.layout.linked = true;value.layout.presentation = .right;value.layout.active = .right
        value.layout.frame = WorkspaceFrame(x:-1500,y:80,width:1200,height:800)
        var library = LayoutLibrary();try library.put(value)
        XCTAssertEqual(try LayoutLibrary.decode(library.encoded()),library)
        let restored = try LayoutLibrary.decode(library.encoded()).profiles[0]
        XCTAssertEqual(restored,value);XCTAssertEqual(restored.left.tabs[1].filter,"*.png;*.jpg");XCTAssertEqual(restored.right.tabs[0].lockMode,.closeOnly)
    }
    func testLayoutProfileNamesNormalizeAndRejectUnicodeDuplicates() throws {
        var library = LayoutLibrary();try library.put(layoutFixture("  Cafe\u{301}  "));XCTAssertEqual(library.profiles[0].name,"Café")
        let original = library;XCTAssertThrowsError(try library.put(layoutFixture("CAFÉ")));XCTAssertEqual(library,original)
        for name in ["", "   ","A\nB","A\tB",String(repeating:"ü",count:121)] { XCTAssertThrowsError(try library.put(layoutFixture(name))) }
        var value = library;value.profiles[0].name = " Café ";XCTAssertThrowsError(try value.encoded())
    }
    func testLayoutProfileMutationsAreAtomicAndReorderSafely() throws {
        var library = LayoutLibrary();let first = layoutFixture("Erster"),second = layoutFixture("Zweiter");try library.put(first);try library.put(second)
        var changed = first;changed.left.tabs[0].lockMode = .newTab;try library.put(changed);XCTAssertEqual(library.profiles.map(\.id),[first.id,second.id])
        try library.move(second.id,by:-1);XCTAssertEqual(library.profiles.map(\.id),[second.id,first.id])
        let original = library;try library.move(first.id,by:Int.max);try library.move(second.id,by:Int.min);XCTAssertEqual(library,original)
        XCTAssertThrowsError(try library.move(UUID(),by:1));changed.left.selected = 9;XCTAssertThrowsError(try library.put(changed));XCTAssertEqual(library,original)
    }
    func testLayoutProfileCountsAndSelectionsAreBounded() throws {
        var profile = layoutFixture(),library = LayoutLibrary();profile.left.tabs = [];XCTAssertThrowsError(try library.put(profile))
        profile = layoutFixture();profile.right.selected = -1;XCTAssertThrowsError(try library.put(profile));profile.right.selected = 1;XCTAssertThrowsError(try library.put(profile))
        profile.right.selected = 0;profile.left.tabs = Array(repeating:LayoutTab(path:"/"),count:100);try library.put(profile)
        profile.left.tabs.append(LayoutTab(path:"/"));XCTAssertThrowsError(try library.put(profile))
        library = LayoutLibrary();for index in 0..<50 { try library.put(layoutFixture("Profil \(index)")) };let original = library
        XCTAssertThrowsError(try library.put(layoutFixture("Zu viel")));XCTAssertEqual(library,original)
    }
    func testLayoutPathsAreValidatedWithoutRequiringMountedVolumes() throws {
        let paths = ["/", "/Volumes/Unplugged Disk/Projekt", "/tmp/Grüße ' $ (x)\nDateien"]
        for path in paths { try LayoutTab(path:path).validate() }
        for path in ["", "relative", "~/Dateien", "file:///tmp", "ftp://example.invalid", "/a/../b", "/a/./b", "//a", "/a//b", "/a/", "/a\0b"] { XCTAssertThrowsError(try LayoutTab(path:path).validate()) }
    }
    func testLayoutNamePathAndFilterByteBoundaries() throws {
        var library = LayoutLibrary();try library.put(layoutFixture(String(repeating:"ü",count:120)))
        try LayoutTab(path:"/"+String(repeating:"a",count:16_383),filter:String(repeating:"a",count:4096)).validate()
        XCTAssertThrowsError(try LayoutTab(path:"/"+String(repeating:"a",count:16_384)).validate())
        XCTAssertThrowsError(try LayoutTab(path:"/",title:String(repeating:"ü",count:121)).validate())
        XCTAssertThrowsError(try LayoutTab(path:"/",filter:String(repeating:"ü",count:2049)).validate())
    }
    func testLayoutFilterValidationRejectsInvalidRegexAndNulls() throws {
        try LayoutTab(path:"/",filter:"*.png;*.jpg").validate();try LayoutTab(path:"/",filter:"^Plan\\.(txt|md)$",filterRegex:true).validate()
        XCTAssertThrowsError(try LayoutTab(path:"/",filter:"[",filterRegex:true).validate())
        XCTAssertThrowsError(try LayoutTab(path:"/",filter:"a\0b").validate())
        XCTAssertThrowsError(try LayoutTab(path:"/",title:"A\nB").validate())
    }
    func testLayoutRejectsInvalidViewSnapshots() throws {
        var profile = layoutFixture();profile.left.tabs[0].view.sortKey = "unknown";var library = LayoutLibrary();XCTAssertThrowsError(try library.put(profile))
        profile = layoutFixture();profile.left.tabs[0].view.columns = [ViewColumn(id:"name",width:300,hidden:false)];XCTAssertThrowsError(try library.put(profile))
    }
    func testLayoutLibraryRejectsCorruptFutureAndWrongTypes() throws {
        for text in ["{broken", "[]", "{\"schemaVersion\":99,\"profiles\":[]}", "{\"schemaVersion\":1,\"profiles\":true}", "{\"profiles\":[]}"] { XCTAssertThrowsError(try LayoutLibrary.decode(Data(text.utf8))) }
        var library = LayoutLibrary();let value = layoutFixture();library.profiles = [value,value];XCTAssertThrowsError(try library.encoded())
    }
    func testLayoutLibraryRejectsOversizedDocumentsBeforeDecode() throws {
        XCTAssertThrowsError(try LayoutLibrary.decode(Data(repeating:32,count:LayoutLibrary.maximumBytes+1)))
        var library = LayoutLibrary(),value = layoutFixture();value.left.tabs = Array(repeating:LayoutTab(path:"/"+String(repeating:"a",count:16_383)),count:100);value.right = value.left
        try library.put(value);let original = library
        value.id = UUID();value.name = "Zweiter";XCTAssertThrowsError(try library.put(value));XCTAssertEqual(library,original)
    }
    func testWorkspaceLayoutVersionRatioAndVisibility() throws {
        let original = WorkspaceLayout();XCTAssertEqual(try WorkspaceLayout.decode(original.encoded()),original)
        for ratio in [Double.nan,Double.infinity,-0.1,0.09,0.91] { var value = original;value.ratio = ratio;XCTAssertThrowsError(try value.validate()) }
        var value = original;value.presentation = .right;XCTAssertThrowsError(try value.validate());value.active = .right;try value.validate()
        value.schemaVersion = 2;XCTAssertThrowsError(try value.encoded())
        XCTAssertThrowsError(try WorkspaceLayout.decode(Data(repeating:32,count:16_385)))
    }
    func testWorkspaceFrameRejectsNonfiniteAndExcessiveCoordinates() throws {
        try WorkspaceFrame(x:-4000,y:-200,width:900,height:520).validate()
        for value in [WorkspaceFrame(x:.nan,y:0,width:900,height:520),WorkspaceFrame(x:0,y:.infinity,width:900,height:520),WorkspaceFrame(x:0,y:0,width:399,height:520),WorkspaceFrame(x:100_001,y:0,width:900,height:520),WorkspaceFrame(x:0,y:0,width:20_000,height:520)] { XCTAssertThrowsError(try value.validate()) }
    }
    func testWorkspaceFrameFitsWhenSavedDisplayIsDisconnected() throws {
        let screen = WorkspaceFrame(x:0,y:30,width:1440,height:850),saved = WorkspaceFrame(x:4000,y:-300,width:1800,height:1100)
        XCTAssertEqual(saved.fitted(to:[screen]),WorkspaceFrame(x:0,y:30,width:1440,height:850))
        XCTAssertEqual(saved.fitted(to:[]),saved)
        let tiny = WorkspaceFrame(x:10,y:10,width:800,height:500);XCTAssertEqual(saved.fitted(to:[tiny]),tiny)
    }
    func testWorkspaceFrameChoosesLargestVisibleScreenIntersection() throws {
        let left = WorkspaceFrame(x:-1920,y:0,width:1920,height:1080),right = WorkspaceFrame(x:0,y:0,width:1440,height:900),saved = WorkspaceFrame(x:-1600,y:100,width:1200,height:700)
        XCTAssertEqual(saved.fitted(to:[right,left]),saved)
        let partial = WorkspaceFrame(x:1300,y:700,width:1200,height:700);XCTAssertEqual(partial.fitted(to:[right]),WorkspaceFrame(x:240,y:200,width:1200,height:700))
    }
    func testLegacyTabGroupLocksMigrateAndCustomModesRoundTrip() throws {
        let old = Data("{\"schemaVersion\":1,\"groups\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Alt\",\"left\":{\"folders\":[{\"path\":\"/\",\"locked\":true}],\"selected\":0},\"right\":{\"folders\":[{\"path\":\"/\",\"locked\":false}],\"selected\":0}}]}".utf8)
        var library = try TabGroupLibrary.decode(old);XCTAssertEqual(library.groups[0].left.folders[0].effectiveLockMode,.newTab);XCTAssertEqual(library.groups[0].right.folders[0].effectiveLockMode,.none)
        library.groups[0].left.folders[0].lockMode = .fixed;XCTAssertEqual(try TabGroupLibrary.decode(library.encoded()),library)
        library.groups[0].right.folders[0].lockMode = .closeOnly;XCTAssertThrowsError(try library.encoded())
    }
    func testTabLockModesDecodeStrictlyAndProtectClosing() throws {
        for mode in TabLockMode.allCases { XCTAssertEqual(try JSONDecoder().decode(TabLockMode.self,from:JSONEncoder().encode(mode)),mode);XCTAssertEqual(mode.preventsClosing,mode != .none) }
        XCTAssertThrowsError(try JSONDecoder().decode(TabLockMode.self,from:Data("\"future-mode\"".utf8)))
    }
}
