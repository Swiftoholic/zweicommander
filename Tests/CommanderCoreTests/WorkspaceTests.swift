import Foundation
import CommanderCore

extension CoreTests {
    func testFolderViewsRespectScopeAndSpecificity() throws {
        var library = WorkspaceLibrary()
        let parent = try folder("Bilder"),child = try folder("Bilder/Neu"),sibling = try folder("Bilder-Alt")
        let icons = FolderViewSettings(display:.icons,sortKey:"modified",ascending:false)
        try library.remember(icons,folder:parent,includeSubfolders:true)
        XCTAssertEqual(library.view(for:child)?.settings,icons);XCTAssertTrue(library.view(for:sibling) == nil)
        let details = FolderViewSettings(display:.details,sortKey:"size")
        try library.remember(details,folder:child,includeSubfolders:false)
        XCTAssertEqual(library.view(for:child)?.settings,details)
        XCTAssertEqual(library.view(for:child.appendingPathComponent("Tief"))?.settings,icons)
        try library.remember(details,folder:parent,includeSubfolders:false)
        XCTAssertTrue(library.view(for:parent.appendingPathComponent("Andere")) == nil)
        XCTAssertEqual(library.views.count,2)
    }
    func testFolderViewsRootUnicodeAndNormalizedPaths() throws {
        var library = WorkspaceLibrary()
        let icons = FolderViewSettings(display:.icons),thumbs = FolderViewSettings(display:.thumbnails)
        try library.remember(icons,folder:URL(fileURLWithPath:"/"),includeSubfolders:true)
        try library.remember(thumbs,folder:root.appendingPathComponent("Äpfel/../Grüße"),includeSubfolders:true)
        XCTAssertEqual(library.view(for:root.appendingPathComponent("Grüße/Tief"))?.settings,thumbs)
        XCTAssertEqual(library.view(for:root.appendingPathComponent("Äpfel"))?.settings,icons)
        XCTAssertThrowsError(try library.remember(icons,folder:URL(string:"https://example.invalid/")!,includeSubfolders:true))
        let id = library.views.last!.id;try library.remember(thumbs,folder:root.appendingPathComponent("Grüße"),includeSubfolders:false)
        XCTAssertEqual(library.views.last?.id,id)
    }
    func testWorkspaceRoundTripPreservesOrderAndRules() throws {
        var library = WorkspaceLibrary()
        let a = WorkspaceFavorite(title:"Projekt",url:root,kind:.folder)
        let b = WorkspaceFavorite(title:"Editor",url:URL(fileURLWithPath:"/Applications/Editor.app"),kind:.application,opensSelection:true)
        try library.put(a);try library.put(b);library.moveFavorite(b.id,by:-1)
        try library.remember(.init(display:.icons,sortKey:"ext",ascending:false,foldersFirst:false,treeVisible:true),folder:root,includeSubfolders:true)
        let restored = try WorkspaceLibrary.decode(library.encoded())
        XCTAssertEqual(restored,library);XCTAssertEqual(restored.favorites.map(\.id),[b.id,a.id])
        var renamed = a;renamed.title = "Neues Projekt";try library.put(renamed)
        XCTAssertEqual(library.favorites.count,2);XCTAssertEqual(library.favorites.last?.title,"Neues Projekt")
        library.moveFavorite(b.id,by:Int.min);XCTAssertEqual(library.favorites.first?.id,b.id)
    }
    func testWorkspaceRejectsDamagedAndFutureDocuments() throws {
        XCTAssertThrowsError(try WorkspaceLibrary.decode(Data("{broken".utf8)))
        var json = try JSONSerialization.jsonObject(with:WorkspaceLibrary().encoded()) as! [String:Any]
        json["version"] = 2;XCTAssertThrowsError(try WorkspaceLibrary.decode(JSONSerialization.data(withJSONObject:json)))
        XCTAssertThrowsError(try WorkspaceLibrary.decode(Data(repeating:32,count:2_097_153)))
        json["version"] = 1;json["favorites"] = [["id":UUID().uuidString,"title":"Bad","kind":"script","path":"/tmp","opensSelection":false]]
        XCTAssertThrowsError(try WorkspaceLibrary.decode(JSONSerialization.data(withJSONObject:json)))
    }
    func testWorkspaceValidationNeverReplacesGoodValues() throws {
        var library = WorkspaceLibrary();let item = WorkspaceFavorite(title:"Gut",url:root,kind:.folder)
        try library.put(item);let original = library
        var invalid = item;invalid.title = " \n "
        XCTAssertThrowsError(try library.put(invalid));XCTAssertEqual(library,original)
        invalid = item;invalid.path = "../relative";XCTAssertThrowsError(try library.put(invalid))
        invalid = item;invalid.path = "/tmp/../tmp";XCTAssertThrowsError(try library.put(invalid))
        invalid = item;invalid.opensSelection = true;XCTAssertThrowsError(try library.put(invalid))
        var settings = FolderViewSettings();settings.sortKey = "unknown"
        XCTAssertThrowsError(try library.remember(settings,folder:root,includeSubfolders:false));XCTAssertEqual(library,original)
        invalid = item;invalid.kind = .application;XCTAssertThrowsError(try library.put(invalid))
        invalid = item;invalid.title = "line\nbreak";XCTAssertThrowsError(try library.put(invalid))
    }
    func testWorkspaceValidatesColumnsAndUniqueEntries() throws {
        var settings = FolderViewSettings(columns:FolderViewSettings.columnIDs.sorted().map { ViewColumn(id:$0,width:100,hidden:false) })
        try settings.validate()
        settings.columns![0].width = .infinity;XCTAssertThrowsError(try settings.validate())
        settings.columns![0].width = 100;settings.columns!.removeLast();XCTAssertThrowsError(try settings.validate())
        var library = WorkspaceLibrary();let item = WorkspaceFavorite(title:"A",url:root,kind:.folder)
        library.favorites = [item,item];XCTAssertThrowsError(try library.encoded())
        library.favorites = (0...200).map { WorkspaceFavorite(title:"\($0)",url:root,kind:.folder) };XCTAssertThrowsError(try library.encoded())
    }
    func testLegacyFolderFavoritesMigrateWithoutPrograms() throws {
        let library = WorkspaceLibrary(legacyFolders:[root.path,root.path,"relative","/tmp/../tmp","/"])
        XCTAssertEqual(library.favorites.count,2)
        XCTAssertTrue(library.favorites.allSatisfy { $0.kind == .folder && !$0.opensSelection })
        XCTAssertEqual(library.favorites.map(\.path),[root.path,"/"])
        XCTAssertEqual(library.favorites.map(\.id),WorkspaceLibrary(legacyFolders:[root.path,"/"]).favorites.map(\.id))
        XCTAssertEqual(try WorkspaceLibrary.decode(library.encoded()),library)
    }
    func testProgramFavoritesUseStructuredFileArguments() throws {
        let favorite = WorkspaceFavorite(title:"Editor",url:URL(fileURLWithPath:"/Applications/Editor.app"),kind:.application,opensSelection:true)
        let paths = [root.appendingPathComponent("Grüße ' $(example).txt"),root.appendingPathComponent("a;b.txt")]
        let request = try ProgramLaunchRequest(favorite:favorite,selection:paths)
        XCTAssertEqual(request.files,paths);XCTAssertEqual(request.application.path,favorite.path)
        XCTAssertThrowsError(try ProgramLaunchRequest(favorite:favorite,selection:[]))
        XCTAssertThrowsError(try ProgramLaunchRequest(favorite:favorite,selection:[URL(string:"https://example.invalid/a")!]))
        var launch = favorite;launch.opensSelection = false
        XCTAssertEqual(try ProgramLaunchRequest(favorite:launch,selection:paths).files,[])
        XCTAssertThrowsError(try ProgramLaunchRequest(favorite:.init(title:"Folder",url:root,kind:.folder),selection:paths))
    }
}
