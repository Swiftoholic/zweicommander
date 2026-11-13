import Foundation
import CommanderCore

private final class GatePasswords: RemotePasswordStore {
    var values: [String:String] = [:]
    var beforeAccess: () -> Void = {}
    var accesses = 0
    func password(account: String) throws -> String? { beforeAccess();accesses += 1;return values[account] }
    func save(_ password: String,account: String) throws { beforeAccess();accesses += 1;values[account] = password }
    func remove(account: String) throws { beforeAccess();accesses += 1;values.removeValue(forKey:account) }
}

extension CoreTests {
    func testRemoteProfileMutationGateRefusalPrecedesCredentialAccess() throws {
        let passwords = GatePasswords(),connection = try RemoteConnection(kind:.ftps,host:"server.example",user:"tester",port:21)
        var library = RemoteProfileLibrary();let profile = try library.save(name:"Existing",connection:connection,path:"/",usesKeychain:true)
        let original = try library.encoded();var reads = 0,writes = 0
        let store = RemoteProfileStore(passwords:passwords,read:{ reads += 1;return original },write:{ _ in writes += 1 },mutationGate:{ throw CommanderError.message("Restart required") })
        XCTAssertThrowsError(try store.save(name:"New",connection:connection,path:"/",remember:true,password:"synthetic-password"))
        XCTAssertThrowsError(try store.remove(profile));XCTAssertEqual(reads,0);XCTAssertEqual(writes,0);XCTAssertEqual(passwords.accesses,0)
    }
    func testRemoteProfileMutationGateCoversCredentialAndMetadataSave() throws {
        let passwords = GatePasswords(),connection = try RemoteConnection(kind:.ftps,host:"server.example",user:"tester",port:21)
        var data: Data?,held = false,releaseCount = 0
        passwords.beforeAccess = { XCTAssertTrue(held) }
        let store = RemoteProfileStore(passwords:passwords,read:{ XCTAssertTrue(held);return data },write:{ XCTAssertTrue(held);data = $0 },mutationGate:{ XCTAssertFalse(held);held = true;return { XCTAssertTrue(held);held = false;releaseCount += 1 } })
        let profile = try store.save(name:"New",connection:connection,path:"/",remember:true,password:"synthetic-password")
        XCTAssertFalse(held);XCTAssertEqual(releaseCount,1);XCTAssertEqual(passwords.values[profile.credentialAccount],"synthetic-password")
        XCTAssertEqual(try RemoteProfileLibrary(data:data!).profile(profile.id),profile)
    }
    func testRemoteProfileMutationGateCoversRemoveFailureAndCredentialRollback() throws {
        let passwords = GatePasswords(),connection = try RemoteConnection(kind:.ftps,host:"server.example",user:"tester",port:21)
        var library = RemoteProfileLibrary();let profile = try library.save(name:"Existing",connection:connection,path:"/",usesKeychain:true)
        passwords.values[profile.credentialAccount] = "original-synthetic-password"
        let original = try library.encoded();var held = false,releases = 0
        passwords.beforeAccess = { XCTAssertTrue(held) }
        let store = RemoteProfileStore(passwords:passwords,read:{ XCTAssertTrue(held);return original },write:{ _ in XCTAssertTrue(held);throw CommanderError.message("Synthetic write error") },mutationGate:{ held = true;return { held = false;releases += 1 } })
        XCTAssertThrowsError(try store.remove(profile))
        XCTAssertEqual(passwords.values[profile.credentialAccount],"original-synthetic-password");XCTAssertFalse(held);XCTAssertEqual(releases,1)
    }
    func testRemoteProfileMutationGateReleasesAfterValidationFailure() throws {
        let passwords = GatePasswords(),connection = try RemoteConnection(kind:.ftps,host:"server.example",user:"tester",port:21)
        var held = false,releases = 0,writes = 0
        let store = RemoteProfileStore(passwords:passwords,read:{ nil },write:{ _ in writes += 1 },mutationGate:{ held = true;return { held = false;releases += 1 } })
        XCTAssertThrowsError(try store.save(name:"",connection:connection,path:"/",remember:false,password:nil))
        XCTAssertFalse(held);XCTAssertEqual(releases,1);XCTAssertEqual(writes,0);XCTAssertEqual(passwords.accesses,0)
    }
}
