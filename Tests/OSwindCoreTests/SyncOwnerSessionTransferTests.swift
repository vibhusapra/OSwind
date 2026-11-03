import XCTest
import CSQLite
@testable import OSwindCore

final class SyncOwnerSessionTransferTests:XCTestCase {
    private var root:URL!,stores=[MemoryStore](),pairings=[PersonalSyncPairing](),sessions=[PersonalSyncSession](),changes=[PersonalSyncOwnerChange]()
    private let storage=PairingTestStorage(),now=Date(timeIntervalSince1970:1_800_000_000)
    private let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"c",count:64))
    private var serial=0
    private var environment:SyncNativeWriterEnvironment {.init(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{[storage] _ in storage})}
    private struct Fixture {let store:MemoryStore,session:PersonalSyncSession,peer:PersonalSyncPairing,request:String,rootFingerprint:String}
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-session-addition-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    }
    override func tearDown()async throws {
        for session in sessions {try await session.stop()}
        try changes.forEach {try $0.close()};pairings.forEach {$0.close()};try stores.forEach {try $0.close()}
        try FileManager.default.removeItem(at:root)
    }
    private func store(_ path:URL)throws->MemoryStore {let value=try MemoryStore(root:path,recoveryReadOnly:false,nativeWriterEnvironment:environment);stores.append(value);return value}
    private func pairing(_ store:MemoryStore)throws->PersonalSyncPairing {let value=try PersonalSyncPairing(store:store,stateRoot:environment.stateRoot,machine:machine,storage:storage);pairings.append(value);return value}
    private func fixture(initialPeer:Bool=false)throws->Fixture {
        serial+=1;let base=root.appendingPathComponent("fixture-\(serial)"),library=try store(base.appendingPathComponent("owner")),owner=try pairing(library)
        _=try owner.createGroup(deviceName:"Owned session desk",now:now)
        let fingerprint=try XCTUnwrap(owner.status().rootFingerprint)
        if initialPeer {
            let first=try pairing(store(base.appendingPathComponent("first"))),request=try XCTUnwrap(first.requestJoin(deviceName:"Owned first travel",now:now).request)
            let response=try owner.approve(owner.reviewRequest(request,now:now),now:now)
            _=try first.acceptResponse(response,trustedRootFingerprint:fingerprint,now:now);first.close()
        }
        let peer=try pairing(store(base.appendingPathComponent("peer")))
        let request=try XCTUnwrap(peer.requestJoin(deviceName:"Owned session travel",now:now).request)
        let session=try owner.prepareSession(sharedFolder:base.appendingPathComponent("provider"),createSharedFolder:true);sessions.append(session)
        try library.insert(Memory(id:"canary",text:"Owned session source"))
        return .init(store:library,session:session,peer:peer,request:request,rootFingerprint:fingerprint)
    }
    private func makeChange(_ f:Fixture,_ review:PersonalSyncOwnerReview)async throws->PersonalSyncOwnerChange {
        let time=now,value=try await f.session.ownerChangeAfterStopping(review,clock:{time});changes.append(value);return value
    }
    private func refused(_ f:Fixture,_ review:PersonalSyncOwnerReview)async {
        do {_=try await makeChange(f,review);XCTFail("A different, live, expired or consumed session review must refuse")}
        catch {}
    }
    func testExactReviewedSessionMustStopBeforeOneOwnedChangeAndExactResponse()async throws {
        let f=try fixture(initialPeer:true),review=try await f.session.reviewOwnerAddition(f.request,now:now),saved=storage.values
        XCTAssertEqual(review.rootFingerprint,f.rootFingerprint);XCTAssertEqual(review.deviceName,"Owned session travel");XCTAssertEqual(review.currentMemberCount,2)
        await refused(f,review);XCTAssertTrue(storage.values==saved)
        try await f.session.stop();let change=try await makeChange(f,review)
        XCTAssertTrue(change.belongs(to:f.store));XCTAssertTrue(storage.values==saved)
        let response=try XCTUnwrap(change.apply(clock:{self.now})),admitted=storage.values
        XCTAssertEqual(try change.apply(clock:{self.now}),response);XCTAssertTrue(storage.values==admitted)
        await refused(f,review);try change.close();XCTAssertTrue(f.store.isClosed)
        XCTAssertThrowsError(try change.apply(clock:{self.now}))
        _=try f.peer.acceptResponse(response.response,trustedRootFingerprint:f.rootFingerprint,now:now)
        let fresh=try store(f.store.root),owner=try pairing(fresh)
        XCTAssertEqual(try owner.lastApprovedResponse(),response);XCTAssertNotNil(try fresh.get("canary"))
        XCTAssertEqual(Set(storage.values.keys),Set(saved.keys))
    }
    func testNewReviewInvalidatesPriorTokenWithoutConsumingCurrentReview()async throws {
        let f=try fixture(),first=try await f.session.reviewOwnerAddition(f.request,now:now),second=try await f.session.reviewOwnerAddition(f.request,now:now),saved=storage.values
        XCTAssertNotEqual(first,second);try await f.session.stop()
        await refused(f,first);let change=try await makeChange(f,second);XCTAssertTrue(storage.values==saved)
        try change.close();let fresh=try store(f.store.root),owner=try pairing(fresh)
        XCTAssertNil(try owner.lastApprovedResponse());XCTAssertNotNil(try fresh.get("canary"))
    }
    func testAnotherSessionAndRootCannotConsumeTheCurrentReview()async throws {
        let a=try fixture(),b=try fixture(),first=try await a.session.reviewOwnerAddition(a.request,now:now),second=try await b.session.reviewOwnerAddition(b.request,now:now),saved=storage.values
        XCTAssertNotEqual(first.rootFingerprint,second.rootFingerprint)
        try await a.session.stop();try await b.session.stop()
        await refused(b,first);await refused(a,second)
        let firstChange=try await makeChange(a,first),secondChange=try await makeChange(b,second)
        XCTAssertFalse(firstChange.belongs(to:b.store));XCTAssertFalse(secondChange.belongs(to:a.store))
        try firstChange.close();try secondChange.close();XCTAssertTrue(storage.values==saved)
    }
    func testReplacementSessionOnSameStoreCannotConsumeEarlierSessionReview()async throws {
        let f=try fixture(),earlier=try await f.session.reviewOwnerAddition(f.request,now:now)
        try await f.session.stop()
        let owner=try pairing(f.store),replacement=try owner.prepareSavedSession();sessions.append(replacement)
        let current=Fixture(store:f.store,session:replacement,peer:f.peer,request:f.request,rootFingerprint:f.rootFingerprint)
        let review=try await replacement.reviewOwnerAddition(f.request,now:now),saved=storage.values
        XCTAssertEqual(review.rootFingerprint,earlier.rootFingerprint);XCTAssertEqual(review.requestFingerprint,earlier.requestFingerprint)
        XCTAssertNotEqual(review.session,earlier.session);try await replacement.stop()
        await refused(current,earlier);let change=try await makeChange(current,review)
        try change.close();XCTAssertTrue(storage.values==saved)
    }
    func testChangeRetainsExactResponseWhenActualCloseFailsAndAllowsSameOwnerRetry()async throws {
        let f=try fixture(),review=try await f.session.reviewOwnerAddition(f.request,now:now)
        try await f.session.stop();let change=try await makeChange(f,review),reply=try XCTUnwrap(change.apply(clock:{self.now})),saved=storage.values
        var statement:OpaquePointer?=try f.store.withMembershipDatabase {try $0.statement("SELECT 1")};defer {sqlite3_finalize(statement)}
        XCTAssertThrowsError(try change.close());XCTAssertFalse(f.store.isClosed)
        XCTAssertEqual(try change.apply(clock:{self.now}),reply);XCTAssertTrue(storage.values==saved)
        sqlite3_finalize(statement);statement=nil;try change.close();XCTAssertTrue(f.store.isClosed)
        let fresh=try store(f.store.root),owner=try pairing(fresh)
        XCTAssertEqual(try owner.lastApprovedResponse(),reply);XCTAssertNotNil(try fresh.get("canary"))
    }
    func testExpiryAfterStopRefusesBeforeIntentAndConsumesThatTransfer()async throws {
        let f=try fixture(),review=try await f.session.reviewOwnerAddition(f.request,now:now),saved=storage.values,time=now.addingTimeInterval(31_536_000)
        try await f.session.stop()
        do {_=try await f.session.ownerChangeAfterStopping(review,clock:{time});XCTFail("Expired request admitted after stop")}
        catch {}
        XCTAssertTrue(storage.values==saved);await refused(f,review)
        try f.store.close();let fresh=try store(f.store.root),owner=try pairing(fresh)
        XCTAssertNil(try owner.lastApprovedResponse());XCTAssertNotNil(try fresh.get("canary"))
    }
}
