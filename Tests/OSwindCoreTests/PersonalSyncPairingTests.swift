import XCTest
import CSQLite
@testable import OSwindCore

final class PersonalSyncPairingTests:XCTestCase {
    var root:URL!,a:MemoryStore!,b:MemoryStore!,storage:PairingTestStorage!
    var owners=[PersonalSyncPairing]()
    let now=Date(timeIntervalSince1970:1_800_000_000)
    let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"a",count:64))
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-pairing-flow-"+UUID().uuidString)
        a=try MemoryStore(root:root.appendingPathComponent("a"));b=try MemoryStore(root:root.appendingPathComponent("b"));storage=PairingTestStorage()
    }
    override func tearDownWithError()throws {owners.forEach {$0.close()};try a?.close();try b?.close();try FileManager.default.removeItem(at:root)}
    func reopen(_ url:URL)throws->MemoryStore {let backend=storage!;return try MemoryStore(root:url,recoveryReadOnly:false,nativeWriterEnvironment:.init(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{_ in backend}))}
    func open(_ store:MemoryStore)throws->PersonalSyncPairing {
        let value=try PersonalSyncPairing(store:store,stateRoot:root.appendingPathComponent("state"),machine:machine,storage:storage);owners.append(value);return value
    }
    func request(_ joiner:PersonalSyncPairing)throws->String {try XCTUnwrap(joiner.requestJoin(deviceName:"Travel Mac",now:now).request)}
    func testOpenUnconfiguredIsReadOnlyAndDoesNotAllocateCredentialsOrInstallation()throws {
        let first=try open(a),status=try first.status()
        XCTAssertEqual(status.phase,.unconfigured);XCTAssertTrue(storage.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("state").path))
        XCTAssertEqual(try a.withRoutineDatabase {try $0.eraseCount("SELECT enabled FROM personal_sync_capture")},0)
        XCTAssertFalse(first.belongs(to:b));XCTAssertTrue(first.belongs(to:a))
    }
    func testTwoNativeLibrariesPairAcrossOwnerAndJoinerRestartsWithoutActivatingDelivery()throws {
        let owner=try open(a),joiner=try open(b),created=try owner.createGroup(deviceName:"Desk Mac",now:now),text=try request(joiner)
        owner.close();joiner.close()
        let resumedOwner=try open(a),resumedJoiner=try open(b)
        XCTAssertEqual(try resumedJoiner.status().request,text)
        let review=try resumedOwner.reviewRequest(text,now:now),response=try resumedOwner.approve(review,now:now)
        XCTAssertEqual(review.deviceName,"Travel Mac")
        resumedOwner.close();resumedJoiner.close()
        let finalOwner=try open(a),finalJoiner=try open(b)
        let complete=try finalJoiner.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(created.rootFingerprint),now:now)
        XCTAssertEqual(complete.phase,.paired);XCTAssertEqual(Set(complete.memberNames),Set(["Desk Mac","Travel Mac"]))
        XCTAssertEqual(try finalOwner.status().rootFingerprint,complete.rootFingerprint)
        XCTAssertThrowsError(try finalJoiner.acceptResponse(response,trustedRootFingerprint:complete.rootFingerprint!,now:now))
        finalJoiner.close();let reopened=try open(b);XCTAssertEqual(try reopened.status(),complete)
        for store in [a!,b!] {
            XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT enabled FROM personal_sync_capture")},0)
            XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM sqlite_master WHERE name='personal_sync_service_state'")},0)
        }
    }
    func testReviewApprovesExactImmutableRequestAndRetryIsIdempotent()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        let joiner=try open(b),text=try request(joiner),review=try owner.reviewRequest(text,now:now)
        let first=try owner.approve(review,now:now),second=try owner.approve(review,now:now)
        XCTAssertFalse(first.isEmpty);XCTAssertFalse(second.isEmpty)
        XCTAssertEqual(try owner.status().memberNames.count,2)
        _=try joiner.acceptResponse(second,trustedRootFingerprint:owner.status().rootFingerprint!,now:now)
        XCTAssertThrowsError(try joiner.reviewRequest(text,now:now))
    }
    func testWrongFingerprintAndTamperedResponseDoNotConsumePendingRequest()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        let joiner=try open(b),text=try request(joiner),response=try owner.approve(owner.reviewRequest(text,now:now),now:now)
        XCTAssertThrowsError(try joiner.acceptResponse(response,trustedRootFingerprint:String(repeating:"0",count:64),now:now))
        XCTAssertThrowsError(try joiner.acceptResponse(response+" ",trustedRootFingerprint:owner.status().rootFingerprint!,now:now))
        XCTAssertEqual(try joiner.status().request,text)
        _=try joiner.acceptResponse(response,trustedRootFingerprint:owner.status().rootFingerprint!,now:now)
    }
    func testExpiredRequestResumesButRenewalInvalidatesOldResponseAndPairsWithFreshKeys()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        let joiner=try open(b),text=try request(joiner),response=try owner.approve(owner.reviewRequest(text,now:now),now:now)
        joiner.close();let resumed=try open(b),later=now.addingTimeInterval(700)
        XCTAssertEqual(try resumed.status().request,text)
        XCTAssertThrowsError(try resumed.acceptResponse(response,trustedRootFingerprint:owner.status().rootFingerprint!,now:later))
        let next=try XCTUnwrap(resumed.renewRequest(now:later).request)
        let old=try SyncJoinRequest.decode(Data(text.utf8),now:now),new=try SyncJoinRequest.decode(Data(next.utf8),now:later)
        XCTAssertNotEqual(old.body.signingPublicKey,new.body.signingPublicKey)
        XCTAssertNotEqual(old.body.agreementPublicKey,new.body.agreementPublicKey)
        XCTAssertNotEqual(old.body.request,new.body.request)
        XCTAssertThrowsError(try resumed.acceptResponse(response,trustedRootFingerprint:owner.status().rootFingerprint!,now:later))
        let replacement=try owner.approve(owner.reviewRequest(next,now:later),now:later)
        XCTAssertEqual(try resumed.acceptResponse(replacement,trustedRootFingerprint:owner.status().rootFingerprint!,now:later).phase,.paired)
    }
    func testMissingCredentialAfterReservationDoesNotRegenerateAndLocalSourcesRemainUsable()throws {
        let owner=try open(a);storage.failCreate=true
        XCTAssertThrowsError(try owner.createGroup(deviceName:"Desk Mac",now:now));owner.close()
        XCTAssertTrue(storage.values.isEmpty);storage.failCreate=false
        XCTAssertThrowsError(try open(a));XCTAssertTrue(storage.values.isEmpty)
        try a.insert(Memory(id:"local",kind:.note,text:"Recording remains local"));XCTAssertNotNil(try a.get("local"))
    }
    func testFailedReplacementRetainsPendingStateAndCanRetryExactResponse()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        let joiner=try open(b),text=try request(joiner),response=try owner.approve(owner.reviewRequest(text,now:now),now:now)
        storage.failReplace=true
        XCTAssertThrowsError(try joiner.acceptResponse(response,trustedRootFingerprint:owner.status().rootFingerprint!,now:now))
        XCTAssertEqual(try joiner.status().phase,.waitingForOwner)
        storage.failReplace=false
        _=try joiner.acceptResponse(response,trustedRootFingerprint:owner.status().rootFingerprint!,now:now)
    }
    func testRetirementPersistsKeylessTombstoneAndRefusesIdentityRecreation()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        let before=storage.values
        XCTAssertEqual(try owner.retire().phase,.retired);owner.close()
        XCTAssertEqual(storage.values.count,before.count)
        for raw in storage.values.values {
            let value=try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any])
            XCTAssertNil(value["material"]);XCTAssertNil(value["pending"]);XCTAssertEqual(value["retired"] as? Bool,true)
        }
        let reopened=try open(a);XCTAssertEqual(try reopened.status().phase,.retired)
        XCTAssertThrowsError(try reopened.createGroup(deviceName:"Reuse old group",now:now))
    }
    func testRestoringPreAcceptanceDatabaseCannotReplayConsumedRequest()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        let joiner=try open(b),text=try request(joiner),response=try owner.approve(owner.reviewRequest(text,now:now),now:now)
        joiner.close();try b.close()
        let saved=root.appendingPathComponent("pending-native.sqlite"),native=root.appendingPathComponent("b/memory.sqlite")
        try FileManager.default.copyItem(at:native,to:saved)
        b=try reopen(root.appendingPathComponent("b"));let accepted=try open(b)
        _=try accepted.acceptResponse(response,trustedRootFingerprint:owner.status().rootFingerprint!,now:now)
        accepted.close();try b.close()
        try FileManager.default.removeItem(at:native);try FileManager.default.copyItem(at:saved,to:native)
        b=try reopen(root.appendingPathComponent("b"));let restored=try open(b)
        XCTAssertEqual(try restored.status().phase,.paired)
        XCTAssertThrowsError(try restored.acceptResponse(response,trustedRootFingerprint:owner.status().rootFingerprint!,now:now))
    }
    func testWholeLibraryWipeInvalidatesPendingPairingButIndividualErasureDoesNot()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        try a.insert(Memory(id:"one",kind:.note,text:"Removable"));_=try a.delete("one")
        XCTAssertEqual(try owner.status().phase,.owner)
        _=try a.deleteAll()
        XCTAssertThrowsError(try owner.status());owner.close();XCTAssertThrowsError(try open(a))
        XCTAssertFalse(storage.values.isEmpty,"Missing lifetime must not erase external recovery evidence")
    }
    func testCopiedLibraryAndMissingInstallationRefuseWhileOriginalCanResume()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now);owner.close();try a.close()
        let copy=root.appendingPathComponent("copy");try FileManager.default.copyItem(at:a.root,to:copy)
        let clone=try reopen(copy);defer {try? clone.close()}
        XCTAssertThrowsError(try open(clone))
        a=try reopen(root.appendingPathComponent("a"));let original=try open(a);XCTAssertEqual(try original.status().phase,.owner);original.close()
        try FileManager.default.removeItem(at:root.appendingPathComponent("state/installation-v1"))
        XCTAssertThrowsError(try open(a));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("state/installation-v1").path))
    }
    func testExclusiveCredentialOwnerAndProtectionTierCannotBeBypassed()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        XCTAssertThrowsError(try open(a));owner.close()
        let wrong=PairingTestStorage(protection:.dataProtectionKeychain)
        XCTAssertThrowsError(try PersonalSyncPairing(store:a,stateRoot:root.appendingPathComponent("state"),machine:machine,storage:wrong))
        XCTAssertEqual(try open(a).status().phase,.owner)
    }
    func testNativeMetadataContainsOnlyNonsecretHandleAndLifetime()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        let rows=try a.withRoutineDatabase {db->[(String,String)] in
            let row=try db.statement("SELECT key,value FROM store_metadata WHERE key LIKE 'sync-pairing-%'");defer {sqlite3_finalize(row)}
            var values=[(String,String)]();while sqlite3_step(row)==SQLITE_ROW {values.append((db.text(row,0),db.text(row,1)))};return values
        }
        XCTAssertEqual(rows.count,2)
        let handle=try XCTUnwrap(rows.first {$0.0=="sync-pairing-handle-v1"})
        let value=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(handle.1.utf8)) as? [String:Any])
        XCTAssertEqual(Set(value.keys),Set(["format","version","id","protection"]))
        for (_,text) in rows {XCTAssertFalse(text.contains("Private"));XCTAssertFalse(text.contains("material"));XCTAssertFalse(text.contains("Desk Mac"))}
        XCTAssertTrue(String(reflecting:owner).contains("redacted"))
    }
    func testDurableEnvelopeSupportsFullMembershipAndRefusesOverflowWithoutReplacingSavedState()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        for index in 1..<SyncProtocolLimits.peers {
            let pending=try SyncPendingJoin(name:"Generated Mac \(index)",now:now)
            _=try owner.approve(owner.reviewRequest(String(decoding:pending.request.encoded(),as:UTF8.self),now:now),now:now)
        }
        XCTAssertEqual(try owner.status().memberNames.count,64)
        for bytes in storage.values.values {XCTAssertLessThanOrEqual(bytes.count,SyncCredentialStorageLimits.maximumBytes)}
        let saved=storage.values,extra=try SyncPendingJoin(name:"Too many Macs",now:now)
        XCTAssertThrowsError(try owner.approve(owner.reviewRequest(String(decoding:extra.request.encoded(),as:UTF8.self),now:now),now:now))
        XCTAssertEqual(storage.values,saved);owner.close();XCTAssertEqual(try open(a).status().memberNames.count,64)
    }
    func testOwnedNativeKeychainPairingSurvivesReopenAndConsumesResponseDurably()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned pairing Keychain flow; no existing account is enumerated or read")}
        let backend=OwnedPairingKeychainStorage()
        defer {do {try backend.cleanup()}catch {XCTFail("Owned pairing credential cleanup failed")}}
        func native(_ store:MemoryStore)throws->PersonalSyncPairing {
            let owner=try PersonalSyncPairing(store:store,stateRoot:root.appendingPathComponent("native-state"),machine:MacSyncMachineFingerprint(),storage:backend)
            owners.append(owner);return owner
        }
        let owner=try native(a),joiner=try native(b)
        let group=try owner.createGroup(deviceName:"Owned main Mac"),request=try XCTUnwrap(joiner.requestJoin(deviceName:"Owned joining Mac").request)
        let response=try owner.approve(owner.reviewRequest(request))
        owner.close();joiner.close()
        let resumed=try native(b),completed=try resumed.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(group.rootFingerprint))
        XCTAssertEqual(completed.phase,.paired);resumed.close()
        let reopened=try native(b);XCTAssertEqual(try reopened.status(),completed)
        XCTAssertThrowsError(try reopened.acceptResponse(response,trustedRootFingerprint:group.rootFingerprint!))
        XCTAssertEqual(try reopened.retire().phase,.retired);reopened.close()
        XCTAssertEqual(try native(b).status().phase,.retired)
        try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
    }
    func testOversizeAndExpiredReviewFailBeforeMembershipMutation()throws {
        let owner=try open(a);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        let joiner=try open(b),text=try request(joiner)
        XCTAssertThrowsError(try owner.reviewRequest(String(repeating:"x",count:8193),now:now))
        XCTAssertThrowsError(try owner.reviewRequest(text,now:now.addingTimeInterval(601)))
        XCTAssertEqual(try owner.status().memberNames,["Desk Mac"])
    }
}

final class PairingTestStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection
    private let lock=NSLock()
    private var saved=[String:Data]()
    var failCreate=false,failReplace=false
    init(protection:SyncCredentialProtection = .loginKeychain) {self.protection=protection}
    var values:[String:Data] {lock.lock();defer {lock.unlock()};return saved}
    func create(id:String,bytes:Data)throws {lock.lock();defer {lock.unlock()};if failCreate {throw SyncCredentialStorageError.unavailable(-1)};guard saved[id]==nil else {throw SyncCredentialStorageError.alreadyExists};saved[id]=bytes}
    func read(id:String)throws->Data {lock.lock();defer {lock.unlock()};guard let value=saved[id] else {throw SyncCredentialStorageError.missing};return value}
    func replace(id:String,expected:Data,bytes:Data)throws {lock.lock();defer {lock.unlock()};if failReplace {throw SyncCredentialStorageError.unavailable(-1)};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved[id]=bytes}
    func remove(id:String,expected:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved.removeValue(forKey:id)}
}

private final class OwnedPairingKeychainStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let backend=SyncKeychainCredentialStorage(protection:.loginKeychain)
    private(set) var accounts=[String]()
    func create(id:String,bytes:Data)throws {try backend.create(id:id,bytes:bytes);accounts.append(id)}
    func read(id:String)throws->Data {try backend.read(id:id)}
    func replace(id:String,expected:Data,bytes:Data)throws {try backend.replace(id:id,expected:expected,bytes:bytes)}
    func remove(id:String,expected:Data)throws {try backend.remove(id:id,expected:expected)}
    func cleanup()throws {
        for id in accounts {let bytes=try backend.read(id:id);try backend.remove(id:id,expected:bytes)
            do {_=try backend.read(id:id);throw OSwindError.invalid("Owned pairing credential still exists")}
            catch SyncCredentialStorageError.missing {}}
        accounts.removeAll()
    }
}
