import Foundation
import Darwin
import CommanderCore

private final class SettingsTestDomain:SettingsBackupDomainStore {
    var values:[String:Any],writes = 0
    var writer:((SettingsTestDomain,[String:Any])throws->Void)?
    init(_ value:[String:Any]) { values = value }
    func readDomain() throws -> [String:Any] { values }
    func replaceDomain(_ value:[String:Any]) throws { writes += 1;if let writer { try writer(self,value) } else { values = value } }
}

extension CoreTests {
    private func backupState(_ theme:Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject:["left":[["path":root.path,"locked":false]],"right":[],"favorites":[],"showHidden":false,"vertical":true,"theme":theme,"shortcuts":[:]],options:.sortedKeys)
    }
    private func backupStores() throws -> [String:Data] {
        [SettingsBackupStores.state:try backupState(),SettingsBackupStores.beforeImport:try backupState(2),
         "ZweiCommander.appearance.v1":Data(#"{"schemaVersion":1,"compact":true,"fontSize":12,"toolbarLabels":true,"importedColors":false}"#.utf8),
         "ZweiCommander.toolbar.v1":Data(#"{"schemaVersion":1,"items":["search","refresh"]}"#.utf8),
         "ZweiCommander.workspace.v1":try WorkspaceLibrary().encoded(),"ZweiCommander.copyProfiles.v1":try CopyProfileLibrary().encoded(),
         "ZweiCommander.renameProfiles.v1":try RenameProfileLibrary().encoded(),"ZweiCommander.searchProfiles.v1":try SearchProfileLibrary().encoded(),
         "ZweiCommander.compareProfiles.v1":try CompareProfileLibrary().encoded(),"ZweiCommander.remoteProfiles.v1":try RemoteProfileLibrary().encoded(),
         "ZweiCommander.tabGroups.v1":try TabGroupLibrary().encoded(),"ZweiCommander.layouts.v1":try LayoutLibrary().encoded(),"ZweiCommander.lastLayout.v1":try WorkspaceLayout().encoded()]
    }
    private func backupRollback(_ bytes:Data) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString+".plist");try SettingsBackupFile.writeNew(bytes,to:url);return url
    }
    func testSettingsBackupAllExistingStoresRoundTripExactPayloadBytes() throws {
        let stores = try backupStores(),value = try SettingsBackupDocument(stores:stores,createdAt:Date(timeIntervalSince1970:1_700_000_000)),encoded = try value.encoded(),decoded = try SettingsBackupDocument.decode(encoded)
        XCTAssertEqual(decoded,value);XCTAssertEqual(decoded.stores,stores);XCTAssertEqual(stores.count,13);XCTAssertEqual(SettingsBackupStores.keys.count,14)
    }
    func testSettingsBackupEmptyDocumentRepresentsDefaultsWithoutWritingDefaults() throws {
        let value = try SettingsBackupDocument.decode(SettingsBackupDocument(stores:[:]).encoded())
        XCTAssertTrue(value.stores.isEmpty);let plan = try SettingsBackupTransaction.prepare(value,domain:[:]);XCTAssertEqual(plan.changedCount,0);XCTAssertEqual(plan.rows.count,14)
    }
    func testSettingsBackupRejectsFutureEnvelopeAndUnknownHeaderFields() throws {
        var json = try SettingsBackupJSON.object(SettingsBackupDocument(stores:[:]).encoded());json["version"] = 2
        XCTAssertThrowsError(try SettingsBackupDocument.decode(JSONSerialization.data(withJSONObject:json)))
        json["version"] = 1;json["future"] = true;XCTAssertThrowsError(try SettingsBackupDocument.decode(JSONSerialization.data(withJSONObject:json)))
        json.removeValue(forKey:"future");json["format"] = "different";XCTAssertThrowsError(try SettingsBackupDocument.decode(JSONSerialization.data(withJSONObject:json)))
    }
    func testSettingsBackupRejectsUnknownStoreAndNonBase64Payload() throws {
        XCTAssertThrowsError(try SettingsBackupDocument(stores:["ZweiCommander.unknown.v1":Data("{}".utf8)]))
        var json = try SettingsBackupJSON.object(SettingsBackupDocument(stores:[:]).encoded());json["stores"] = [SettingsBackupStores.state:"not base64 *"]
        XCTAssertThrowsError(try SettingsBackupDocument.decode(JSONSerialization.data(withJSONObject:json)))
    }
    func testSettingsBackupRejectsTruncatedTrailingAndInvalidJSON() throws {
        let valid = try SettingsBackupDocument(stores:[:]).encoded()
        XCTAssertThrowsError(try SettingsBackupDocument.decode(valid.dropLast()));XCTAssertThrowsError(try SettingsBackupDocument.decode(valid+Data(" true".utf8)))
        for raw in ["[]","null","{\"version\":NaN}","{\"version\":01}","{\"x\":\"\\uD800\"}"] { XCTAssertThrowsError(try SettingsBackupJSON.object(Data(raw.utf8))) }
    }
    func testSettingsBackupRejectsDuplicateEscapedAndNestedKeys() throws {
        for raw in [#"{"version":1,"\u0076ersion":2}"#,#"{"x":{"a":1,"a":2}}"#,#"{"x":[{"a":1,"\u0061":2}]}"#] { XCTAssertThrowsError(try SettingsBackupJSON.object(Data(raw.utf8))) }
        let duplicate = Data(#"{"version":1,"profiles":[],"profiles":[]}"#.utf8)
        XCTAssertThrowsError(try SettingsBackupDocument(stores:["ZweiCommander.copyProfiles.v1":duplicate]))
    }
    func testSettingsBackupJSONRejectsDepthAndAcceptsReorderedUnicode() throws {
        let deep = String(repeating:"{\"x\":",count:66)+"0"+String(repeating:"}",count:66);XCTAssertThrowsError(try SettingsBackupJSON.object(Data(deep.utf8)))
        let value = try SettingsBackupJSON.object(Data(#" { "Gruß": "Wien ✔", "b": [true, false, null, -1.25e+2] } "#.utf8));XCTAssertEqual(value["Gruß"] as? String,"Wien ✔")
    }
    func testSettingsBackupEveryProfileFutureVersionIsRejected() throws {
        for (key,raw) in try backupStores() where ![SettingsBackupStores.state,SettingsBackupStores.beforeImport].contains(key) {
            var json = try SettingsBackupJSON.object(raw);if json["version"] != nil { json["version"] = 99 } else { json["schemaVersion"] = 99 }
            XCTAssertThrowsError(try SettingsBackupDocument(stores:[key:JSONSerialization.data(withJSONObject:json)]))
        }
    }
    func testSettingsBackupUnknownNestedProfileFieldsAreNotSilentlyDropped() throws {
        var library = CopyProfileLibrary();_ = try library.save(name:"Regel",filter:TransferFilter(),policy:.stop,mergeFolders:false)
        var json = try SettingsBackupJSON.object(library.encoded()),profiles = json["profiles"] as! [[String:Any]],filter = profiles[0]["filter"] as! [String:Any];filter["futureRule"] = true;profiles[0]["filter"] = filter;json["profiles"] = profiles
        XCTAssertThrowsError(try SettingsBackupDocument(stores:["ZweiCommander.copyProfiles.v1":JSONSerialization.data(withJSONObject:json)]))
    }
    func testSettingsBackupRemotePasswordsAndOpaqueSecretsAreRejected() throws {
        var library = RemoteProfileLibrary();_ = try library.save(name:"Testserver",connection:RemoteConnection(kind:.ftps,host:"example.invalid",user:"test",port:21),path:"/",usesKeychain:true)
        let safe = try library.encoded();let backup = try SettingsBackupDocument(stores:["ZweiCommander.remoteProfiles.v1":safe]);XCTAssertEqual(backup.stores["ZweiCommander.remoteProfiles.v1"],safe)
        var json = try SettingsBackupJSON.object(safe),profiles = json["profiles"] as! [[String:Any]];profiles[0]["password"] = "synthetic-secret";json["profiles"] = profiles
        XCTAssertThrowsError(try SettingsBackupDocument(stores:["ZweiCommander.remoteProfiles.v1":JSONSerialization.data(withJSONObject:json)]))
    }
    func testSettingsBackupStateWrongTypesAndInvalidViewsAreRejected() throws {
        var json = try SettingsBackupJSON.object(backupState());json["showHidden"] = 1
        XCTAssertThrowsError(try SettingsBackupDocument(stores:[SettingsBackupStores.state:JSONSerialization.data(withJSONObject:json)]))
        json = try SettingsBackupJSON.object(backupState());var tabs = json["left"] as! [[String:Any]];tabs[0]["view"] = ["display":"future"];json["left"] = tabs
        XCTAssertThrowsError(try SettingsBackupDocument(stores:[SettingsBackupStores.state:JSONSerialization.data(withJSONObject:json)]))
    }
    func testSettingsBackupStateInvalidLocksFiltersPathsAndThemeAreRejected() throws {
        for edit in ["theme","lock","filter","path"] {
            var json = try SettingsBackupJSON.object(backupState()),tabs = json["left"] as! [[String:Any]]
            switch edit { case "theme":json["theme"] = 3;case "lock":tabs[0]["lockMode"] = "fixed";case "filter":tabs[0]["filter"] = "[";tabs[0]["filterRegex"] = true;default:tabs[0]["path"] = "relative" };json["left"] = tabs
            XCTAssertThrowsError(try SettingsBackupDocument(stores:[SettingsBackupStores.state:JSONSerialization.data(withJSONObject:json)]))
        }
    }
    func testSettingsBackupUnknownStateFieldsCannotBeLostOnRestore() throws {
        var json = try SettingsBackupJSON.object(backupState());json["futureSession"] = ["active":true]
        XCTAssertThrowsError(try SettingsBackupDocument(stores:[SettingsBackupStores.state:JSONSerialization.data(withJSONObject:json)]))
    }
    func testSettingsBackupLegacyProfileVersionsKeepOriginalBytes() throws {
        let raw = Data("{ \"profiles\" : [], \"version\" : 1 }\n".utf8),key = "ZweiCommander.renameProfiles.v1"
        let decoded = try SettingsBackupDocument.decode(SettingsBackupDocument(stores:[key:raw]).encoded());XCTAssertEqual(decoded.stores[key],raw)
    }
    func testSettingsBackupNewToolsRequireRegisteredTypedCodec() throws {
        let raw = Data(#"{"version":1,"tools":[]}"#.utf8)
        XCTAssertThrowsError(try SettingsBackupDocument(stores:[SettingsBackupStores.tools:raw]))
        let validator:SettingsBackupDocument.Validator = { key,data in try SettingsBackupValidation.validate(key,data,externalTools:{ candidate in let obj = try SettingsBackupJSON.object(candidate);guard Set(obj.keys) == ["version","tools"] else { throw CommanderError.message("bad tool") };return candidate }) }
        let value = try SettingsBackupDocument(stores:[SettingsBackupStores.tools:raw],validator:validator)
        XCTAssertEqual(try SettingsBackupDocument.decode(value.encoded(),validator:validator).stores[SettingsBackupStores.tools],raw)
    }
    func testSettingsBackupReviewDistinguishesAddReplaceRemoveRepairAndUnchanged() throws {
        let stores = try backupStores(),key = SettingsBackupStores.state,current:[String:Any] = [key:try backupState(2),"ZweiCommander.copyProfiles.v1":stores["ZweiCommander.copyProfiles.v1"]!,"ZweiCommander.toolbar.v1":stores["ZweiCommander.toolbar.v1"]!,"ZweiCommander.searchProfiles.v1":123]
        let plan = try SettingsBackupTransaction.prepare(SettingsBackupDocument(stores:[key:stores[key]!,"ZweiCommander.copyProfiles.v1":stores["ZweiCommander.copyProfiles.v1"]!,"ZweiCommander.workspace.v1":stores["ZweiCommander.workspace.v1"]!]),domain:current)
        XCTAssertEqual(plan.rows.first { $0.key == key }?.change,.replace);XCTAssertEqual(plan.rows.first { $0.key == "ZweiCommander.copyProfiles.v1" }?.change,.unchanged)
        XCTAssertEqual(plan.rows.first { $0.key == "ZweiCommander.workspace.v1" }?.change,.add);XCTAssertEqual(plan.rows.first { $0.key == "ZweiCommander.toolbar.v1" }?.change,.remove);XCTAssertEqual(plan.rows.first { $0.key == "ZweiCommander.searchProfiles.v1" }?.change,.repair)
    }
    func testSettingsBackupRestoreResetsMissingStoresAndPreservesUnownedValues() throws {
        let before = try backupStores(),domain = SettingsTestDomain(before.merging(["unowned":Data("keep".utf8)],uniquingKeysWith:{ a,_ in a })),doc = try SettingsBackupDocument(stores:[SettingsBackupStores.state:backupState(2)]),plan = try SettingsBackupTransaction.prepare(doc,domain:domain.values)
        let result = try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:backupRollback)
        XCTAssertEqual(domain.values[SettingsBackupStores.state] as? Data,doc.stores[SettingsBackupStores.state]);XCTAssertEqual(domain.values["unowned"] as? Data,Data("keep".utf8));XCTAssertEqual(domain.values.count,2)
        XCTAssertEqual(result.restoredKeys,1);XCTAssertEqual(result.resetKeys,13);XCTAssertTrue(FileManager.default.fileExists(atPath:result.rollbackURL.path))
    }
    func testSettingsBackupRestoreRetainsExactUnreadableOriginalInPrivateRollback() throws {
        let domain = SettingsTestDomain([SettingsBackupStores.state:123,"ZweiCommander.appearance.v1":Data("unreadable".utf8)]),doc = try SettingsBackupDocument(stores:[:]),plan = try SettingsBackupTransaction.prepare(doc,domain:domain.values)
        let result = try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:backupRollback),saved = try PropertyListSerialization.propertyList(from:Data(contentsOf:result.rollbackURL),format:nil) as! [String:Any],values = saved["values"] as! [String:Any]
        XCTAssertEqual(values[SettingsBackupStores.state] as? Int,123);XCTAssertEqual(values["ZweiCommander.appearance.v1"] as? Data,Data("unreadable".utf8));XCTAssertTrue(domain.values.isEmpty)
    }
    func testSettingsBackupConcurrentOwnedChangeInvalidatesBeforeAnyWrite() throws {
        let domain = SettingsTestDomain([SettingsBackupStores.state:try backupState()]),doc = try SettingsBackupDocument(stores:[:]),plan = try SettingsBackupTransaction.prepare(doc,domain:domain.values);domain.values[SettingsBackupStores.state] = try backupState(2)
        var backups = 0;XCTAssertThrowsError(try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:{ data in backups += 1;return try self.backupRollback(data) }));XCTAssertEqual(backups,0);XCTAssertEqual(domain.writes,0)
    }
    func testSettingsBackupConcurrentUnownedChangeIsPreserved() throws {
        let domain = SettingsTestDomain(["foreign":"first"]),doc = try SettingsBackupDocument(stores:[SettingsBackupStores.state:backupState()]),plan = try SettingsBackupTransaction.prepare(doc,domain:domain.values);domain.values["foreign"] = "new"
        _ = try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:backupRollback);XCTAssertEqual(domain.values["foreign"] as? String,"new")
    }
    func testSettingsBackupChangeDuringRollbackSaveCannotCommit() throws {
        let domain = SettingsTestDomain([SettingsBackupStores.state:try backupState()]),plan = try SettingsBackupTransaction.prepare(SettingsBackupDocument(stores:[:]),domain:domain.values)
        XCTAssertThrowsError(try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:backupRollback,beforeCommit:{ domain.values["ZweiCommander.toolbar.v1"] = Data("newer".utf8) }));XCTAssertEqual(domain.writes,0)
    }
    func testSettingsBackupRollbackWriteFailurePrecedesMutation() throws {
        let domain = SettingsTestDomain([SettingsBackupStores.state:try backupState()]),plan = try SettingsBackupTransaction.prepare(SettingsBackupDocument(stores:[:]),domain:domain.values)
        XCTAssertThrowsError(try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:{ _ in throw CommanderError.message("no disk") }));XCTAssertEqual(domain.writes,0);XCTAssertNotNil(domain.values[SettingsBackupStores.state])
    }
    func testSettingsBackupFailedDomainCommitRollsBackWholeOldState() throws {
        let original = try backupStores(),domain = SettingsTestDomain(original),plan = try SettingsBackupTransaction.prepare(SettingsBackupDocument(stores:[:]),domain:domain.values)
        domain.writer = { store,value in if store.writes == 1 { store.values = value;throw CommanderError.message("disk confirmation") };store.values = value }
        do { _ = try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:backupRollback);XCTAssertTrue(false) } catch let error as SettingsBackupRestoreFailure { XCTAssertTrue(error.rolledBack);XCTAssertNotNil(error.rollbackURL) }
        XCTAssertEqual(try SettingsBackupCurrentSnapshot(domain:domain.values).stateID,try SettingsBackupCurrentSnapshot(domain:original).stateID);XCTAssertEqual(domain.writes,2)
    }
    func testSettingsBackupPartialFailingStoreRollsBackAndKeepsNewUnownedValue() throws {
        let original = try backupStores(),domain = SettingsTestDomain(original),plan = try SettingsBackupTransaction.prepare(SettingsBackupDocument(stores:[:]),domain:domain.values)
        domain.writer = { store,value in if store.writes == 1 { store.values.removeValue(forKey:SettingsBackupStores.state);store.values["unowned"] = "new";throw CommanderError.message("partial") };store.values = value }
        XCTAssertThrowsError(try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:backupRollback));XCTAssertEqual(domain.values[SettingsBackupStores.state] as? Data,original[SettingsBackupStores.state]);XCTAssertEqual(domain.values["unowned"] as? String,"new")
    }
    func testSettingsBackupRollbackNeverOverwritesForeignOwnedChange() throws {
        let domain = SettingsTestDomain([SettingsBackupStores.state:try backupState()]),plan = try SettingsBackupTransaction.prepare(SettingsBackupDocument(stores:[:]),domain:domain.values),foreign = Data("external writer".utf8)
        domain.writer = { store,value in store.values = value;store.values[SettingsBackupStores.state] = foreign;throw CommanderError.message("conflict") }
        do { _ = try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:backupRollback);XCTAssertTrue(false) } catch let error as SettingsBackupRestoreFailure { XCTAssertFalse(error.rolledBack);XCTAssertTrue(FileManager.default.fileExists(atPath:error.rollbackURL!.path)) }
        XCTAssertEqual(domain.values[SettingsBackupStores.state] as? Data,foreign);XCTAssertEqual(domain.writes,1)
    }
    func testSettingsBackupSnapshotOrderIndependentButTypeSensitive() throws {
        let a:[String:Any] = [SettingsBackupStores.state:Data([1,2]),"ZweiCommander.toolbar.v1":true],b:[String:Any] = ["ZweiCommander.toolbar.v1":true,SettingsBackupStores.state:Data([1,2])],c:[String:Any] = ["ZweiCommander.toolbar.v1":1,SettingsBackupStores.state:Data([1,2])]
        XCTAssertEqual(try SettingsBackupCurrentSnapshot(domain:a).stateID,try SettingsBackupCurrentSnapshot(domain:b).stateID);XCTAssertFalse(try SettingsBackupCurrentSnapshot(domain:a).stateID == SettingsBackupCurrentSnapshot(domain:c).stateID)
    }
    func testSettingsBackupLegacyBeforeImportAliasPreservesBytesAndNormalizesOnlyAtRestore() throws {
        let alias = "ZweiCommander.beforeLegacyImport",state = try backupState(),domain = SettingsTestDomain([alias:state]),snapshot = try SettingsBackupCurrentSnapshot(domain:domain.values)
        XCTAssertEqual(snapshot.payloads[SettingsBackupStores.beforeImport],state);XCTAssertNotNil(domain.values[alias])
        let plan = try SettingsBackupTransaction.prepare(SettingsBackupDocument(stores:snapshot.payloads),domain:domain.values)
        _ = try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:backupRollback);XCTAssertEqual(domain.values[SettingsBackupStores.beforeImport] as? Data,state);XCTAssertTrue(domain.values[alias] == nil)
    }
    func testSettingsBackupAmbiguousLegacyAliasesAreVisibleAsInvalid() throws {
        let snapshot = try SettingsBackupCurrentSnapshot(domain:["ZweiCommander.beforeFirstImport":try backupState(),"ZweiCommander.beforeSecondImport":try backupState(2)])
        XCTAssertTrue(snapshot.invalidKeys.contains(SettingsBackupStores.beforeImport));XCTAssertTrue(snapshot.payloads[SettingsBackupStores.beforeImport] == nil)
    }
    func testSettingsBackupReaderRejectsLinksDirectoriesAndFIFOWithoutBlocking() throws {
        let target = try file("backup.json","{}"),link = root.appendingPathComponent("link.json");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        XCTAssertThrowsError(try SettingsBackupFile.read(link));XCTAssertThrowsError(try SettingsBackupFile.read(root))
        let fifo = root.appendingPathComponent("fifo");XCTAssertEqual(mkfifo(fifo.path,0o600),0);let start = Date();XCTAssertThrowsError(try SettingsBackupFile.read(fifo));XCTAssertTrue(Date().timeIntervalSince(start) < 1)
    }
    func testSettingsBackupReaderRejectsOversizedSparseFileAndCancellation() throws {
        let path = try file("large.json"),descriptor = open(path.path,O_WRONLY);XCTAssertTrue(descriptor >= 0);defer { close(descriptor) };XCTAssertEqual(ftruncate(descriptor,off_t(SettingsBackupDocument.maximumBytes+1)),0)
        XCTAssertThrowsError(try SettingsBackupFile.read(path));let small = try file("small.json","{}"),token = CancellationToken();token.cancel();XCTAssertThrowsError(try SettingsBackupFile.read(small,token:token))
    }
    func testSettingsBackupNewFileIsPrivateAndNeverReplacesExistingOrLinkedTarget() throws {
        let path = root.appendingPathComponent("backup.json"),data = try SettingsBackupDocument(stores:[:]).encoded();try SettingsBackupFile.writeNew(data,to:path)
        XCTAssertEqual(try Data(contentsOf:path),data);let attrs = try FileManager.default.attributesOfItem(atPath:path.path);XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertThrowsError(try SettingsBackupFile.writeNew(Data("replace".utf8),to:path));XCTAssertEqual(try Data(contentsOf:path),data)
        let outside = try file("outside","keep"),link = root.appendingPathComponent("linked.json");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        XCTAssertThrowsError(try SettingsBackupFile.writeNew(data,to:link));XCTAssertEqual(try read(outside),"keep")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy { !$0.hasPrefix(".zweicommander-settings-") })
    }
    func testSettingsBackupReaderDetectsChangedBytesAndReplacedPath() throws {
        let data = Data(repeating:65,count:256*1024),url = root.appendingPathComponent("racing.json");try data.write(to:url)
        var changed = false
        XCTAssertThrowsError(try SettingsBackupFile.read(url,progress:{ _ in if !changed { changed = true;try! Data(repeating:66,count:data.count).write(to:url) } }))
        try data.write(to:url);changed = false;let displaced = root.appendingPathComponent("displaced.json")
        XCTAssertThrowsError(try SettingsBackupFile.read(url,progress:{ _ in if !changed { changed = true;try! FileManager.default.moveItem(at:url,to:displaced);try! data.write(to:url) } }))
        XCTAssertEqual(try Data(contentsOf:displaced),data)
    }
    func testSettingsBackupRollbackFailureRetainsOriginalSnapshotFile() throws {
        let domain = SettingsTestDomain([SettingsBackupStores.state:try backupState()]),plan = try SettingsBackupTransaction.prepare(SettingsBackupDocument(stores:[:]),domain:domain.values)
        domain.writer = { store,value in if store.writes == 1 { store.values = value };throw CommanderError.message("disk unavailable") }
        do { _ = try SettingsBackupTransaction.apply(plan,to:domain,saveRollback:backupRollback);XCTAssertTrue(false) } catch let failure as SettingsBackupRestoreFailure { XCTAssertFalse(failure.rolledBack);XCTAssertTrue(FileManager.default.fileExists(atPath:failure.rollbackURL!.path)) }
    }

    func testSettingsBackupCurrentMalformedPropertyListIsBoundedBeforeSnapshotEncoding() throws {
        var nested:Any = "leaf";for _ in 0..<70 { nested = [nested] }
        XCTAssertThrowsError(try SettingsBackupCurrentSnapshot(domain:[SettingsBackupStores.state:nested]))
        XCTAssertThrowsError(try SettingsBackupCurrentSnapshot(domain:[SettingsBackupStores.state:Data(repeating:0,count:SettingsBackupDocument.maximumPayloadBytes+1)]))
        XCTAssertThrowsError(try SettingsBackupCurrentSnapshot(domain:[SettingsBackupStores.state:Array(repeating:"x",count:300_001)]))
    }

    func testSettingsBackupLegacyImportedProfileAliasPreservesOriginalRawState() throws {
        let profile = try INISettingsImport.parse(main:Data("[Form]\nColorSchema=Synthetic\n".utf8))
        var state = try SettingsBackupJSON.object(backupState());state["legacyProfile"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(profile))
        let raw = try JSONSerialization.data(withJSONObject:state),value = try SettingsBackupDocument.decode(SettingsBackupDocument(stores:[SettingsBackupStores.state:raw]).encoded())
        XCTAssertEqual(value.stores[SettingsBackupStores.state],raw)
    }
    func testSettingsBackupImportedProfileFutureSchemaAndInvalidColorAreRejected() throws {
        let profile = try INISettingsImport.parse(main:Data("[Form]\nColorSchema=Synthetic\n".utf8)),original = try SettingsBackupJSON.object(JSONEncoder().encode(profile))
        for field in ["schema","color"] {
            var value = original
            if field == "schema" { value["schemaVersion"] = 2 } else { value["background"] = ["red":2.0,"green":0.0,"blue":0.0] }
            var state = try SettingsBackupJSON.object(backupState());state["importedProfile"] = value
            XCTAssertThrowsError(try SettingsBackupDocument(stores:[SettingsBackupStores.state:JSONSerialization.data(withJSONObject:state)]))
        }
    }

    func testSettingsBackupAcceptsNativeImportFontAndSchemaOutputs() throws {
        for size in ["0","6","9","11","18","48","72","-1","not-a-number"] {
            let profile = try INISettingsImport.parse(main:Data(("[Form]\nFileListFont_Name=System\nFileListFont_Size="+size+"\n").utf8))
            var state = try SettingsBackupJSON.object(backupState());state["importedProfile"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(profile))
            let raw = try JSONSerialization.data(withJSONObject:state),backup = try SettingsBackupDocument(stores:[SettingsBackupStores.state:raw])
            XCTAssertEqual(backup.stores[SettingsBackupStores.state],raw);XCTAssertEqual(profile.schemaVersion,1);XCTAssertTrue((11...24).contains(profile.fontSize))
        }
    }

}
