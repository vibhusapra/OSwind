import XCTest
@testable import OSwindCore

final class SyncCredentialStorageTests:XCTestCase {
    func testCredentialBoundsRejectInvalidAccountAndEmptyOrOversizeBytes()throws {
        let id=UUID().uuidString.lowercased()
        for bad in ["",id.uppercased(),"../"+id,id+"\0"] {XCTAssertThrowsError(try SyncCredentialStorageLimits.validate(id:bad))}
        XCTAssertThrowsError(try SyncCredentialStorageLimits.validate(id:id,bytes:Data()))
        XCTAssertThrowsError(try SyncCredentialStorageLimits.validate(id:id,bytes:Data(repeating:0,count:SyncCredentialStorageLimits.maximumBytes+1)))
        try SyncCredentialStorageLimits.validate(id:id,bytes:Data(repeating:0,count:SyncCredentialStorageLimits.maximumBytes))
        XCTAssertNotEqual(SyncKeychainCredentialStorage.service,"com.oswind.secrets")
        XCTAssertNotEqual(SyncKeychainCredentialStorage.service,"com.oswind.vault-passphrases")
    }
    func testOwnedNativeLoginCredentialCreateCompareReplaceAndConfirmedDelete()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned random-account Keychain test; never enumerates existing credentials")}
        let storage=SyncKeychainCredentialStorage(protection:.loginKeychain),id=UUID().uuidString.lowercased(),first=Data("Owned disposable sync credential".utf8),next=Data("Owned replacement sync credential".utf8)
        var created=false
        defer {if created {do {let current=try storage.read(id:id);try storage.remove(id:id,expected:current)}catch {XCTFail("Owned sync test credential cleanup did not complete")}}}
        try storage.create(id:id,bytes:first);created=true
        XCTAssertEqual(try storage.read(id:id),first)
        XCTAssertThrowsError(try storage.create(id:id,bytes:next)) {XCTAssertEqual($0 as? SyncCredentialStorageError,.alreadyExists)}
        XCTAssertThrowsError(try storage.replace(id:id,expected:next,bytes:next)) {XCTAssertEqual($0 as? SyncCredentialStorageError,.changed)}
        XCTAssertEqual(try storage.read(id:id),first)
        try storage.replace(id:id,expected:first,bytes:next);XCTAssertEqual(try storage.read(id:id),next)
        XCTAssertThrowsError(try storage.remove(id:id,expected:first)) {XCTAssertEqual($0 as? SyncCredentialStorageError,.changed)}
        try storage.remove(id:id,expected:next);created=false
        XCTAssertThrowsError(try storage.read(id:id)) {XCTAssertEqual($0 as? SyncCredentialStorageError,.missing)}
        XCTAssertThrowsError(try storage.replace(id:id,expected:next,bytes:first)) {XCTAssertEqual($0 as? SyncCredentialStorageError,.missing)}
    }
    func testOwnedNativeDataProtectionRequestNeverFallsBackToLoginKeychain()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned random-account Keychain capability test; not production app entitlement acceptance")}
        let protected=SyncKeychainCredentialStorage(protection:.dataProtectionKeychain),login=SyncKeychainCredentialStorage(protection:.loginKeychain),id=UUID().uuidString.lowercased(),bytes=Data("Owned disposable protection-tier probe".utf8)
        var created=false
        defer {if created {do {try protected.remove(id:id,expected:bytes)}catch {XCTFail("Owned protected test credential cleanup did not complete")}}}
        do {
            try protected.create(id:id,bytes:bytes);created=true
            XCTAssertEqual(try protected.read(id:id),bytes)
            print("SYNC_KEYCHAIN_OWNED_PROBE dataProtectionAvailableToTestHost=true")
        }catch let error as SyncCredentialStorageError {
            guard case .unavailable(let status)=error else {throw error}
            print("SYNC_KEYCHAIN_OWNED_PROBE dataProtectionAvailableToTestHost=false status=\(status)")
        }
        XCTAssertThrowsError(try login.read(id:id)) {XCTAssertEqual($0 as? SyncCredentialStorageError,.missing)}
        if created {try protected.remove(id:id,expected:bytes);created=false}
    }
    func testOwnedNativeKeychainReloadsGeneratedOwnerAndDeviceKeysAtMembershipCapacity()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit generated-group credential round trip; no user account or existing key is read")}
        let pending=try SyncPendingJoin(name:"Owned persistent owner")
        var owner=try SyncGroupAuthority(owner:pending.request)
        for index in 1..<SyncProtocolLimits.peers {owner=try owner.admitting(SyncPendingJoin(name:"Owned generated Mac \(index)").request)}
        let joined=try pending.accept(owner.response(to:pending.request),expectedRootFingerprint:owner.fingerprint),material=try SyncCredentialMaterial(joined:joined,owner:owner)
        let bytes=try material.encodedForKeychain(),storage=SyncKeychainCredentialStorage(protection:.loginKeychain),id=UUID().uuidString.lowercased()
        var created=false
        defer {if created {do {try storage.remove(id:id,expected:bytes)}catch {XCTFail("Owned generated credential cleanup did not complete")}}}
        try storage.create(id:id,bytes:bytes);created=true
        let recovered=try SyncCredentialMaterial.decodeFromKeychain(storage.read(id:id))
        XCTAssertEqual(recovered.joined.certificate.body.members.count,64)
        XCTAssertEqual(try XCTUnwrap(recovered.owner).fingerprint,try owner.fingerprint)
        let descriptor=Data("owned persistent native-keychain packet".utf8),payload=Data("Owned generated payload".utf8)
        let packet=try recovered.joined.packetAuthority().seal(payload,purpose:.operation,descriptor:descriptor,replica:joined.replica)
        XCTAssertEqual(try joined.packetAuthority().open(packet,purpose:.operation,descriptor:descriptor,replica:joined.replica),payload)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-sync-persistent-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let original=try joined.createTransport(at:root),reopened=try recovered.joined.openTransport(at:root)
        original.close();reopened.close()
        try storage.remove(id:id,expected:bytes);created=false
        XCTAssertThrowsError(try storage.read(id:id)) {XCTAssertEqual($0 as? SyncCredentialStorageError,.missing)}
    }
}
