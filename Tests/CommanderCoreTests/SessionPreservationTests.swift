import Foundation
import CommanderCore

extension CoreTests {
    private func sessionObject(_ tabs:[[String:Any]]? = nil) -> [String:Any] {
        ["left":tabs ?? [["path":root.path,"locked":false]],"right":[],"favorites":[],"showHidden":false,"vertical":true,"theme":0,"shortcuts":[:]]
    }
    private func sessionData(_ object:[String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:object,options:.sortedKeys) }
    private func sessionTree(_ state:SavedState) throws -> [String:SessionJSON] { try SessionJSON.parse(state.encoded()).fields! }
    private func sessionTab(_ state:SavedState,_ index:Int = 0) throws -> [String:SessionJSON] { try sessionTree(state)["left"]!.elements![index].fields! }
    func testSessionPreservationUnknownRootAndTabFieldsSurviveUnrelatedEdits() throws {
        var object = sessionObject([["path":root.path,"locked":false,"futureTab":["mode":"later","list":[1,2,3]]]])
        object["futureSession"] = ["state":"✓","enabled":true]
        var state = try SavedState.decode(sessionData(object));state.theme = 2;state.showHidden = true
        let result = try sessionTree(state)
        XCTAssertEqual(result["futureSession"],try SessionJSON.parse(sessionData(object)).fields!["futureSession"])
        XCTAssertNotNil(try sessionTab(state)["futureTab"]);XCTAssertEqual(try result["theme"]?.decoded(Int.self),2);XCTAssertTrue(state.hasUnrecognizedData)
    }
    func testSessionPreservationInvalidOptionalTypesKeepOriginalWithUsableFallback() throws {
        let input = try sessionData(sessionObject([["path":root.path,"locked":true,"view":["future":true],"lockMode":["new":1],"filter":["next"],"filterRegex":"automatic","selected":["future":true]]]))
        let state = try SavedState.decode(input),tab = state.left[0],output = try sessionTab(state),original = try SessionJSON.parse(input).fields!["left"]!.elements![0].fields!
        XCTAssertEqual(tab.path,root.path);XCTAssertTrue(tab.locked);XCTAssertEqual(tab.view,nil);XCTAssertEqual(tab.lockMode,nil);XCTAssertEqual(tab.filter,nil);XCTAssertEqual(tab.selected,nil)
        for key in ["view","lockMode","filter","filterRegex","selected"] { XCTAssertEqual(output[key],original[key]) }
    }
    func testSessionPreservationUnknownLockModeKeepsLegacyProtection() throws {
        for locked in [true,false] {
            let state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":locked,"lockMode":"future-mode"]])))
            XCTAssertEqual(state.left[0].lockMode,nil);XCTAssertEqual(state.left[0].locked,locked)
            XCTAssertEqual(try sessionTab(state)["lockMode"]?.decoded(String.self),"future-mode")
        }
    }
    func testSessionPreservationContradictingKnownLockFallsBackWithoutChangingRawMode() throws {
        let state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":true,"lockMode":"none"]])))
        XCTAssertEqual(state.left[0].lockMode,nil);XCTAssertTrue(state.left[0].locked)
        XCTAssertEqual(try sessionTab(state)["lockMode"]?.decoded(String.self),"none")
    }
    func testSessionPreservationFutureViewSurvivesAutomaticFallbackSnapshot() throws {
        var view = try JSONSerialization.jsonObject(with:JSONEncoder().encode(FolderViewSettings())) as! [String:Any];view["sortKey"] = "future-column"
        var state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":false,"view":view]])))
        state.left[0].view = FolderViewSettings(display:.icons)
        XCTAssertEqual(try sessionTab(state)["view"]?.fields?["sortKey"]?.decoded(String.self),"future-column")
    }
    func testSessionPreservationExplicitViewEditReplacesOnlyUnsupportedView() throws {
        var state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":false,"view":["future":1],"futureTab":"keep"]])))
        state.left[0].view = FolderViewSettings(display:.icons);state.left[0].explicitlyReplacedFields.insert("view")
        let tab = try sessionTab(state)
        XCTAssertEqual(try tab["view"]?.fields?["display"]?.decoded(String.self),"icons");XCTAssertEqual(tab["view"]?.fields?["future"],nil)
        XCTAssertEqual(try tab["futureTab"]?.decoded(String.self),"keep")
    }
    func testSessionPreservationUnknownNestedColumnFieldsFollowColumnIdentity() throws {
        let columns = FolderViewSettings.baseColumnIDs.sorted().map { ViewColumn(id:$0,width:100,hidden:false) }
        var view = try JSONSerialization.jsonObject(with:JSONEncoder().encode(FolderViewSettings(columns:columns))) as! [String:Any]
        var values = view["columns"] as! [[String:Any]];values[0]["futureWidth"] = ["units":"cells"];view["columns"] = values;view["futureStyle"] = "keep"
        var state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":false,"view":view]])))
        let id = state.left[0].view!.columns![0].id
        state.left[0].view!.columns!.reverse();let index = state.left[0].view!.columns!.firstIndex { $0.id == id }!
        state.left[0].view!.columns![index].width = 225;state.left[0].explicitlyReplacedFields.insert("view")
        let saved = try sessionTab(state)["view"]!.fields!,result = saved["columns"]!.elements!
        let changed = result.first { (try? $0.fields?["id"]?.decoded(String.self)) == id }!.fields!
        XCTAssertNotNil(changed["futureWidth"]);XCTAssertEqual(try changed["width"]?.decoded(Int.self),225)
        XCTAssertEqual(try saved["futureStyle"]?.decoded(String.self),"keep")
    }
    func testSessionPreservationBadRegexAndOversizedFilterFallBackWithoutLoss() throws {
        for filter in ["[",String(repeating:"a",count:4097),"bad\0filter"] {
            let state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":false,"filter":filter,"filterRegex":true]])))
            XCTAssertEqual(state.left[0].filter,nil);XCTAssertEqual(state.left[0].filterRegex,nil)
            XCTAssertEqual(try sessionTab(state)["filter"]?.decoded(String.self),filter);XCTAssertEqual(try sessionTab(state)["filterRegex"]?.decoded(Bool.self),true)
        }
    }
    func testSessionPreservationExplicitFilterAndLockEditsReplaceProtectedValues() throws {
        var state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":false,"filter":["future"],"filterRegex":"next","lockMode":"next","selected":"next"]])))
        state.left[0].filter = "*.txt";state.left[0].filterRegex = false;state.left[0].lockMode = .fixed;state.left[0].locked = true
        state.left[0].explicitlyReplacedFields.formUnion(["filter","filterRegex","lockMode"])
        let tab = try sessionTab(state)
        XCTAssertEqual(try tab["filter"]?.decoded(String.self),"*.txt");XCTAssertEqual(try tab["filterRegex"]?.decoded(Bool.self),false);XCTAssertEqual(try tab["lockMode"]?.decoded(String.self),"fixed")
        XCTAssertEqual(try tab["selected"]?.decoded(String.self),"next")
    }
    func testSessionPreservationUnknownSelectionStaysUntilExplicitSelection() throws {
        var state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":false,"selected":["next":2]]])))
        state.left[0].selected = true;XCTAssertNotNil(try sessionTab(state)["selected"]?.fields)
        state.left[0].explicitlyReplacedFields.insert("selected");XCTAssertEqual(try sessionTab(state)["selected"]?.decoded(Bool.self),true)
    }
    func testSessionPreservationDuplicatePathsReorderAndMoveWithoutCrossContamination() throws {
        var state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":false,"futureID":"first"],["path":root.path,"locked":false,"futureID":"second"]])))
        state.left.swapAt(0,1)
        XCTAssertEqual(try sessionTab(state,0)["futureID"]?.decoded(String.self),"second");XCTAssertEqual(try sessionTab(state,1)["futureID"]?.decoded(String.self),"first")
        state.right.append(state.left.removeLast());let tree = try sessionTree(state)
        XCTAssertEqual(try tree["right"]?.elements?[0].fields?["futureID"]?.decoded(String.self),"first")
    }
    func testSessionPreservationRepeatedReloadDoesNotAccumulateOrDropOpaqueFields() throws {
        var state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":false,"futureID":"keep","lockMode":"next"]])))
        for value in 0..<20 { state.theme = value%3;state = try SavedState.decode(state.encoded()) }
        let tab = try sessionTab(state);XCTAssertEqual(try tab["futureID"]?.decoded(String.self),"keep");XCTAssertEqual(try tab["lockMode"]?.decoded(String.self),"next")
    }
    func testSessionPreservationOpaqueNumbersAndEscapedUnicodeRemainExact() throws {
        let data = try sessionData(sessionObject()),tail = Data(#", "futureNumber":12345678901234567890123456789012345678901234567890, "futureExponent":1e999, "futureText":"\u0041\ud83d\ude80"}"#.utf8)
        let input = data.dropLast()+tail,state = try SavedState.decode(input),encoded = try state.encoded(),original = try SessionJSON.parse(input).fields!,result = try SessionJSON.parse(encoded).fields!
        for key in ["futureNumber","futureExponent","futureText"] { XCTAssertEqual(result[key],original[key]) }
    }
    func testSessionPreservationLegacyImportedProfileNormalizesCompleteOpaqueSubtree() throws {
        let profile = try INISettingsImport.parse(main:Data("[Form]\nFontSize=12\n".utf8))
        var raw = try JSONSerialization.jsonObject(with:JSONEncoder().encode(profile)) as! [String:Any];raw["futureProfile"] = ["flag":true]
        var object = sessionObject();object["legacyProfile"] = raw
        let state = try SavedState.decode(sessionData(object)),tree = try sessionTree(state)
        XCTAssertNotNil(state.importedProfile);XCTAssertEqual(tree["legacyProfile"],nil);XCTAssertNotNil(tree["importedProfile"]?.fields?["futureProfile"])
        XCTAssertThrowsError(try SettingsBackupValidation.validate(SettingsBackupStores.state,state.encoded()))
    }
    func testSessionPreservationFutureImportedProfileUsesFallbackAndRemainsOpaque() throws {
        let profile = try INISettingsImport.parse(main:Data("[Form]\nFontSize=12\n".utf8));var raw = try JSONSerialization.jsonObject(with:JSONEncoder().encode(profile)) as! [String:Any];raw["schemaVersion"] = 2
        var object = sessionObject();object["importedProfile"] = raw
        var state = try SavedState.decode(sessionData(object));XCTAssertEqual(state.importedProfile,nil);XCTAssertEqual(try sessionTree(state)["importedProfile"]?.fields?["schemaVersion"]?.decoded(Int.self),2)
        state.importedProfile = profile;state.explicitlyReplacedFields.insert("importedProfile")
        XCTAssertEqual(try sessionTree(state)["importedProfile"]?.fields?["schemaVersion"]?.decoded(Int.self),1)
    }
    func testSessionPreservationNormalAndLegacyKnownSettingsRemainMutable() throws {
        var state = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":true]])))
        XCTAssertFalse(state.hasUnrecognizedData);state.theme = 1;state.left[0].filter = "*.md";state.left[0].view = FolderViewSettings(display:.icons)
        let decoded = try SavedState.decode(state.encoded());XCTAssertEqual(decoded.theme,1);XCTAssertEqual(decoded.left[0].filter,"*.md");XCTAssertEqual(decoded.left[0].view?.display,.icons)
        try SettingsBackupValidation.validate(SettingsBackupStores.state,state.encoded())
    }
    func testSessionPreservationStrictBackupStillRejectsRetainedUnsupportedFields() throws {
        var object = sessionObject([["path":root.path,"locked":false,"view":["future":1]]]);object["futureSession"] = true
        let state = try SavedState.decode(sessionData(object));XCTAssertThrowsError(try SettingsBackupValidation.validate(SettingsBackupStores.state,state.encoded()))
    }
    func testSessionPreservationDuplicateInvalidAndTruncatedJSONRejectBeforeDecode() throws {
        for raw in [#"{"x":1,"\u0078":2}"#,#"{"x":{"a":1,"a":2}}"#,"{\"x\":01}","{\"x\":1.}","{\"x\":true} false","{\"x\":\"\\uD800\"}","{\"x\":[1,}"] { XCTAssertThrowsError(try SessionJSON.parse(Data(raw.utf8))) }
        let valid = try sessionData(sessionObject());XCTAssertThrowsError(try SavedState.decode(valid.dropLast()))
    }
    func testSessionPreservationDepthNodeAndByteBudgetsAreBounded() throws {
        XCTAssertThrowsError(try SessionJSON.parse(Data((String(repeating:"[",count:66)+"0"+String(repeating:"]",count:66)).utf8)))
        XCTAssertThrowsError(try SessionJSON.parse(Data(("["+String(repeating:"0,",count:300_000)+"0]").utf8)))
        XCTAssertThrowsError(try SessionJSON.parse(Data(repeating:32,count:SessionJSON.maximumBytes+1)))
    }
    func testSessionPreservationInvalidRequiredFieldsAndPathsRejectRatherThanDropTabs() throws {
        XCTAssertThrowsError(try SavedState.decode(sessionData(sessionObject([["path":"relative","locked":false]]))))
        XCTAssertThrowsError(try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":"unknown"]]))))
        var object = sessionObject();object["left"] = "future-layout";XCTAssertThrowsError(try SavedState.decode(sessionData(object)))
        object = sessionObject();object["theme"] = 3;XCTAssertThrowsError(try SavedState.decode(sessionData(object)))
    }
    func testSessionPreservationViewRecoveryNeverReintroducesOldLockFilterOrMetadata() throws {
        let old = try SavedState.decode(sessionData(sessionObject([["path":root.path,"locked":true,"view":["future":"style"],"lockMode":"future-mode","filter":["old"],"futureID":"old-tab"]]))).left[0]
        var current = SavedTab(path:root.path,title:nil,locked:false,view:FolderViewSettings(display:.icons),selected:true,lockMode:TabLockMode.none,filter:"*.md",filterRegex:false)
        current.preservation = try current.currentFieldPreservation().restoringFields(["view"],from:old.preservation!)
        let saved = try current.sessionJSON().fields!
        XCTAssertEqual(saved["view"],try old.sessionJSON().fields!["view"])
        XCTAssertEqual(try saved["filter"]?.decoded(String.self),"*.md");XCTAssertEqual(try saved["locked"]?.decoded(Bool.self),false)
        XCTAssertEqual(try saved["lockMode"]?.decoded(String.self),"none")
        XCTAssertEqual(saved["futureID"],nil);XCTAssertEqual(try saved["selected"]?.decoded(Bool.self),true)
    }
    func testSessionPreservationNormalSessionIsNotLimitedToBackupTabCount() throws {
        var state = SavedState();state.left = (0..<1001).map { _ in SavedTab(path:root.path,title:nil,locked:false,view:nil,selected:nil) }
        let decoded = try SavedState.decode(state.encoded());XCTAssertEqual(decoded.left.count,1001)
        XCTAssertThrowsError(try SettingsBackupValidation.validate(SettingsBackupStores.state,state.encoded()))
    }
}
