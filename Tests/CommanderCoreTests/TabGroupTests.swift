import Foundation
import CommanderCore

extension CoreTests {
    private func tabGroupFixture(_ name: String = "Arbeitsbereich", id: UUID = UUID()) -> TabGroupProfile {
        TabGroupProfile(id: id, name: name,
                        left: TabGroupPane(folders: [TabGroupFolder(path: "/Volumes/Disconnected Disk/Projekt")]),
                        right: TabGroupPane(folders: [TabGroupFolder(path: "/")]))
    }

    func testTabGroupRoundTripPreservesBothPanesAndTabState() throws {
        var library = TabGroupLibrary()
        let view = FolderViewSettings(display: .icons, sortKey: "modified", ascending: false, foldersFirst: false, treeVisible: true,
                                      columns: FolderViewSettings.columnIDs.sorted().map { ViewColumn(id: $0, width: $0 == "name" ? 280 : 90, hidden: $0 != "name") })
        let path = "/Volumes/Disconnected Disk/Grüße ' $ (x) \"\nDateien"
        var profile = tabGroupFixture("Reisen & Projekte")
        profile.left = TabGroupPane(folders: [TabGroupFolder(path: "/"), TabGroupFolder(path: path, title: "Bilder 🧭", locked: true, view: view)], selected: 1)
        profile.right = TabGroupPane(folders: [TabGroupFolder(path: path), TabGroupFolder(path: path, title: "Zweite Ansicht")], selected: 1)
        try library.put(profile)
        let restored = try TabGroupLibrary.decode(library.encoded())
        XCTAssertEqual(restored, library)
        XCTAssertEqual(restored.groups[0].left.selected, 1)
        XCTAssertEqual(restored.groups[0].right.selected, 1)
        XCTAssertEqual(restored.groups[0].left.folders[1].path, path)
        XCTAssertEqual(restored.groups[0].left.folders[1].view, view)
        XCTAssertTrue(restored.groups[0].left.folders[1].locked)
        XCTAssertEqual(restored.groups[0].right.folders.map(\.path), [path, path])
    }

    func testTabGroupPutNormalizesNamesAndRejectsUnicodeDuplicates() throws {
        var library = TabGroupLibrary()
        try library.put(tabGroupFixture("  Cafe\u{301}  "))
        XCTAssertEqual(Array(library.groups[0].name.utf8), Array("Café".utf8))
        let original = library
        XCTAssertThrowsError(try library.put(tabGroupFixture("CAFÉ")))
        XCTAssertThrowsError(try library.put(tabGroupFixture("cafe\u{301}")))
        XCTAssertEqual(library, original)
        var invalid = library;invalid.groups[0].name = "Cafe\u{301}"
        XCTAssertThrowsError(try invalid.encoded())
        invalid.groups[0].name = " Café "
        XCTAssertThrowsError(try invalid.encoded())
    }

    func testTabGroupPutUpdatesInPlaceAndMovesSafely() throws {
        var library = TabGroupLibrary()
        let first = tabGroupFixture("Zuerst"),second = tabGroupFixture("Zweitens"),third = tabGroupFixture("Drittens")
        try library.put(first);try library.put(second);try library.put(third)
        var changed = second;changed.name = " Umbenannt ";changed.left.folders[0].locked = true
        try library.put(changed)
        XCTAssertEqual(library.groups.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(library.groups[1].name, "Umbenannt")
        XCTAssertTrue(library.groups[1].left.folders[0].locked)
        try library.move(third.id, by: -2)
        XCTAssertEqual(library.groups.map(\.id), [third.id, first.id, second.id])
        let reordered = library
        for offset in [Int.min, Int.max, -10, 10, 0] { try library.move(first.id, by: offset) }
        XCTAssertEqual(library, reordered)
        XCTAssertThrowsError(try library.move(UUID(), by: 1))
        XCTAssertEqual(library, reordered)
        XCTAssertEqual(try TabGroupLibrary.decode(library.encoded()), reordered)
    }

    func testTabGroupInvalidMutationsAreAtomic() throws {
        var library = TabGroupLibrary();let first = tabGroupFixture("Gut"),second = tabGroupFixture("Andere")
        try library.put(first);try library.put(second);let original = library
        var invalid = first;invalid.name = second.name
        XCTAssertThrowsError(try library.put(invalid));XCTAssertEqual(library, original)
        invalid = first;invalid.left.selected = 10
        XCTAssertThrowsError(try library.put(invalid));XCTAssertEqual(library, original)
        invalid = first;invalid.right.folders[0].path = "relative/path"
        XCTAssertThrowsError(try library.put(invalid));XCTAssertEqual(library, original)
        invalid = first;invalid.name = "Bad\nName"
        XCTAssertThrowsError(try library.put(invalid));XCTAssertEqual(library, original)
        var broken = library;broken.groups.append(first);let beforeMove = broken
        XCTAssertThrowsError(try broken.move(first.id, by: 1));XCTAssertEqual(broken, beforeMove)
        broken = library;broken.groups[1].id = first.id
        XCTAssertThrowsError(try broken.encoded())
        broken = library;broken.groups[1].name = first.name.uppercased()
        XCTAssertThrowsError(try broken.encoded())
    }

    func testTabGroupRejectsInvalidPanesAndSelections() throws {
        for left in [true, false] {
            for selected in [-1, 1, Int.min, Int.max] {
                var library = TabGroupLibrary(),profile = tabGroupFixture()
                if left { profile.left.selected = selected } else { profile.right.selected = selected }
                XCTAssertThrowsError(try library.put(profile));XCTAssertTrue(library.groups.isEmpty)
            }
            var library = TabGroupLibrary(),profile = tabGroupFixture()
            if left { profile.left.folders = [] } else { profile.right.folders = [] }
            XCTAssertThrowsError(try library.put(profile));XCTAssertTrue(library.groups.isEmpty)
        }
    }

    func testTabGroupRejectsInvalidNamesAndTitles() throws {
        for name in ["", "   ", "Bad\nName", "Bad\tName", "Bad\0Name", String(repeating: "é", count: 121)] {
            var library = TabGroupLibrary()
            XCTAssertThrowsError(try library.put(tabGroupFixture(name)))
            XCTAssertTrue(library.groups.isEmpty)
        }
        for title in ["Bad\nTitle", "Bad\0Title", String(repeating: "🧭", count: 61)] {
            var library = TabGroupLibrary(),profile = tabGroupFixture()
            profile.left.folders[0].title = title
            XCTAssertThrowsError(try library.put(profile));XCTAssertTrue(library.groups.isEmpty)
        }
    }

    func testTabGroupPathValidationIsLexicalAndPreservesCharacters() throws {
        let missing = "/Volumes/Offline Test Volume/does-not-exist/Grüße ' $ (a);[x]\\item\nnext"
        var library = TabGroupLibrary(),profile = tabGroupFixture()
        profile.left.folders[0].path = missing
        try library.put(profile)
        XCTAssertEqual(try TabGroupLibrary.decode(library.encoded()).groups[0].left.folders[0].path, missing)
        for path in ["", "relative", "~/Documents", "file:///tmp", "sftp://example.invalid/a", "C:\\Data", "//host/share", "/tmp//folder", "/tmp/./folder", "/tmp/../folder", "/tmp/", "/tmp/\0folder"] {
            var candidate = profile;candidate.left.folders[0].path = path
            let before = library
            XCTAssertThrowsError(try library.put(candidate));XCTAssertEqual(library, before)
        }
    }

    func testTabGroupNameAndPathByteBoundaries() throws {
        var library = TabGroupLibrary(),profile = tabGroupFixture(String(repeating: "é", count: 120))
        profile.left.folders[0].title = String(repeating: "🧭", count: 60)
        profile.left.folders[0].path = "/" + String(repeating: "é", count: 8191) + "a"
        XCTAssertEqual(profile.left.folders[0].path.utf8.count, 16_384)
        try library.put(profile);let valid = library
        profile.left.folders[0].path += "a"
        XCTAssertThrowsError(try library.put(profile));XCTAssertEqual(library, valid)
        profile = valid.groups[0];profile.name += "a"
        XCTAssertThrowsError(try library.put(profile));XCTAssertEqual(library, valid)
        profile = valid.groups[0];profile.left.folders[0].title! += "a"
        XCTAssertThrowsError(try library.put(profile));XCTAssertEqual(library, valid)
    }

    func testTabGroupCountBoundaries() throws {
        var library = TabGroupLibrary(),profile = tabGroupFixture()
        profile.left = TabGroupPane(folders: (0..<100).map { TabGroupFolder(path: "/missing/left/\($0)") }, selected: 99)
        profile.right = TabGroupPane(folders: (0..<100).map { TabGroupFolder(path: "/missing/right/\($0)") }, selected: 99)
        try library.put(profile)
        var tooMany = profile;tooMany.left.folders.append(TabGroupFolder(path: "/overflow"))
        XCTAssertThrowsError(try library.put(tooMany))
        tooMany = profile;tooMany.right.folders.append(TabGroupFolder(path: "/overflow"))
        XCTAssertThrowsError(try library.put(tooMany))
        for index in 1..<50 { try library.put(tabGroupFixture("Gruppe \(index)")) }
        XCTAssertEqual(library.groups.count, 50)
        let valid = library
        XCTAssertThrowsError(try library.put(tabGroupFixture("Überlauf")))
        XCTAssertEqual(library, valid)
        XCTAssertEqual(try TabGroupLibrary.decode(library.encoded()), valid)
    }

    func testTabGroupRejectsDamagedFutureAndWrongTypedDocuments() throws {
        var library = TabGroupLibrary();try library.put(tabGroupFixture())
        let data = try library.encoded()
        for text in ["{broken", "[]", "{}", "{\"schemaVersion\":1,\"groups\":null}", "{\"schemaVersion\":\"1\",\"groups\":[]}"] {
            XCTAssertThrowsError(try TabGroupLibrary.decode(Data(text.utf8)))
        }
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["schemaVersion"] = 2
        let future = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try TabGroupLibrary.decode(future))
        XCTAssertThrowsError(try JSONDecoder().decode(TabGroupLibrary.self, from: future))
        json["schemaVersion"] = 1
        let originalRows = json["groups"] as! [[String: Any]]
        json["groups"] = originalRows + originalRows
        XCTAssertThrowsError(try TabGroupLibrary.decode(JSONSerialization.data(withJSONObject: json)))
        var rows = originalRows;rows[0]["id"] = "invalid-uuid";json["groups"] = rows
        XCTAssertThrowsError(try TabGroupLibrary.decode(JSONSerialization.data(withJSONObject: json)))
        rows = originalRows;var left = rows[0]["left"] as! [String: Any];left["selected"] = "zero";rows[0]["left"] = left;json["groups"] = rows
        XCTAssertThrowsError(try TabGroupLibrary.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testTabGroupEncodedAndDecodedSizeLimits() throws {
        let empty = try TabGroupLibrary().encoded()
        let padded = empty + Data(repeating: 32, count: TabGroupLibrary.maximumBytes - empty.count)
        XCTAssertEqual(try TabGroupLibrary.decode(padded), TabGroupLibrary())
        XCTAssertThrowsError(try TabGroupLibrary.decode(padded + Data([32])))
        var library = TabGroupLibrary();try library.put(tabGroupFixture("Klein"));let original = library
        var huge = tabGroupFixture("Zu groß")
        let longPath = "/" + String(repeating: "x", count: 16_000)
        huge.left = TabGroupPane(folders: Array(repeating: TabGroupFolder(path: longPath), count: 100))
        huge.right = huge.left
        XCTAssertThrowsError(try library.put(huge));XCTAssertEqual(library, original)
        var invalid = TabGroupLibrary();invalid.groups = [huge]
        XCTAssertThrowsError(try invalid.encoded())
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
    }

    func testTabGroupRejectsInvalidViews() throws {
        var library = TabGroupLibrary();let profile = tabGroupFixture();try library.put(profile);let original = library
        var invalid = profile,view = FolderViewSettings();view.sortKey = "future-sort"
        invalid.left.folders[0].view = view
        XCTAssertThrowsError(try library.put(invalid));XCTAssertEqual(library, original)
        view = FolderViewSettings(columns: FolderViewSettings.columnIDs.sorted().map { ViewColumn(id: $0, width: 100, hidden: false) })
        view.columns![0].width = .infinity;invalid.left.folders[0].view = view
        XCTAssertThrowsError(try library.put(invalid));XCTAssertEqual(library, original)
        var json = try JSONSerialization.jsonObject(with: library.encoded()) as! [String: Any]
        var rows = json["groups"] as! [[String: Any]],left = rows[0]["left"] as! [String: Any]
        var folders = left["folders"] as! [[String: Any]]
        folders[0]["view"] = ["display": "future-view", "sortKey": "name", "ascending": true, "foldersFirst": true, "treeVisible": false]
        left["folders"] = folders;rows[0]["left"] = left;json["groups"] = rows
        XCTAssertThrowsError(try TabGroupLibrary.decode(JSONSerialization.data(withJSONObject: json)))
    }
}
