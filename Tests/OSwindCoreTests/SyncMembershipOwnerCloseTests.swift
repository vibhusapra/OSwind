import XCTest
import CSQLite
@testable import OSwindCore

/// Real unfinalized SQLite work makes close fail. Original credential leases
/// must remain owned until the exact connection can be closed successfully.
final class SyncMembershipOwnerCloseTests:XCTestCase {
    private var root:URL!,stores=[MemoryStore](),pairings=[PersonalSyncPairing](),operations=[SyncMembershipPreparationOwner]()
    private let storage=MembershipCloseStorage(),now=Date(timeIntervalSince1970:1_800_000_000)
    private let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"b",count:64))
    private var environment:SyncNativeWriterEnvironment {.init(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{[storage] _ in storage})}
    private struct Fixture {let store:MemoryStore,operation:SyncMembershipPreparationOwner,accounts:[String],draft:SyncMembershipPreparationOwner.ApprovalDraft}
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-membership-close-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    }
    override func tearDownWithError()throws {
        storage.failAfterReplace=false
        try operations.forEach {try $0.close()};pairings.forEach {$0.close()};try stores.forEach {try $0.close()};try FileManager.default.removeItem(at:root)
    }
    private func store(_ path:URL)throws->MemoryStore {let value=try MemoryStore(root:path,recoveryReadOnly:false,nativeWriterEnvironment:environment);stores.append(value);return value}
    private func pairing(_ store:MemoryStore)throws->PersonalSyncPairing {let value=try PersonalSyncPairing(store:store,stateRoot:environment.stateRoot,machine:machine,storage:storage);pairings.append(value);return value}
    private func fixture(publish:Bool=true)throws->Fixture {
        let library=try store(root.appendingPathComponent("owner")),owner=try pairing(library)
        _=try owner.createGroup(deviceName:"Owned close desk",now:now)
        let service=try owner.prepareAnchoredService(shared:root.appendingPathComponent("provider"),createShared:true)
        try service.installNativeWriterAdmission();try library.insert(Memory(id:"canary",text:"Owned close canary"));try service.stop();service.inbox.close();service.transport.close();owner.close()
        let current=try pairing(library),peer=try pairing(store(root.appendingPathComponent("peer"))),request=try XCTUnwrap(peer.requestJoin(deviceName:"Owned close peer",now:now).request)
        let review=try current.reviewDeliveredRequest(request,now:now)
        let accounts=try library.withRoutineDatabase {db->[String] in
            let row=try db.statement("SELECT id,(SELECT value FROM store_metadata WHERE key='sync-pairing-handle-v1') FROM personal_sync_delivery_anchor");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Owned original accounts missing")}
            let handle=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(db.text(row,1).utf8)) as? [String:Any])
            return [db.text(row,0),try XCTUnwrap(handle["id"] as? String)]
        }
        current.close();let draft=try SyncMembershipPreparationOwner.approvalDraft(library:library,review:review,environment:environment,now:now),operation=draft.owner;operations.append(operation)
        if publish {try draft.prepare(clock:{self.now})}
        return .init(store:library,operation:operation,accounts:accounts,draft:draft)
    }
    private func holdStatement(_ library:MemoryStore,restricted:Bool=true)throws->OpaquePointer {
        if restricted {return try library.withMembershipDatabase {try $0.statement("SELECT 1")}}
        return try library.withRoutineDatabase {try $0.statement("SELECT 1")}
    }
    private func assertOriginalLeasesHeld(_ f:Fixture,file:StaticString=#filePath,line:UInt=#line) {
        for id in f.accounts {XCTAssertThrowsError(try SyncCredentialExclusiveLease(id:id,stateRoot:environment.stateRoot),file:file,line:line)}
    }
    private func assertOriginalLeasesReleased(_ f:Fixture)throws {
        for id in f.accounts {let lease=try SyncCredentialExclusiveLease(id:id,stateRoot:environment.stateRoot);lease.close()}
    }
    func testDraftExpiryRefusesBeforeIntentAndRetainsLeasesThroughActualBusyClose()throws {
        let f=try fixture(publish:false),saved=storage.values
        var statement:OpaquePointer?=try holdStatement(f.store,restricted:false);defer {sqlite3_finalize(statement)}
        assertOriginalLeasesHeld(f)
        XCTAssertThrowsError(try f.draft.prepare(clock:{self.now.addingTimeInterval(31_536_000)}))
        XCTAssertTrue(storage.values==saved)
        XCTAssertThrowsError(try f.draft.prepare(clock:{self.now}));XCTAssertTrue(storage.values==saved)
        XCTAssertThrowsError(try f.operation.close());XCTAssertFalse(f.store.isClosed);assertOriginalLeasesHeld(f)
        sqlite3_finalize(statement);statement=nil;try f.operation.close();try assertOriginalLeasesReleased(f)
        let fresh=try store(f.store.root),owner=try pairing(fresh)
        XCTAssertNil(try owner.lastApprovedResponse());XCTAssertNotNil(try fresh.get("canary"))
    }
    func testAmbiguousDraftIntentRetainsOriginalLeasesUntilBusyCloseAndSavedRecovery()throws {
        let f=try fixture(publish:false),originalAccounts=Set(storage.values.keys)
        var statement:OpaquePointer?=try holdStatement(f.store,restricted:false);defer {sqlite3_finalize(statement)}
        storage.failAfterReplace=true;XCTAssertThrowsError(try f.draft.prepare(clock:{self.now}));storage.failAfterReplace=false
        let saved=storage.values;XCTAssertEqual(Set(saved.keys),originalAccounts)
        XCTAssertThrowsError(try f.draft.prepare(clock:{self.now}));XCTAssertTrue(storage.values==saved)
        XCTAssertThrowsError(try f.operation.close());XCTAssertFalse(f.store.isClosed);assertOriginalLeasesHeld(f)
        XCTAssertThrowsError(try SyncMembershipPreparationOwner.open(root:f.store.root,environment:environment))
        sqlite3_finalize(statement);statement=nil;try f.operation.close();try assertOriginalLeasesReleased(f)
        XCTAssertThrowsError(try store(f.store.root))
        let recovery=try SyncMembershipPreparationOwner.open(root:f.store.root,environment:environment);operations.append(recovery)
        try recovery.applyMembership();let response=try XCTUnwrap(recovery.completedResponse());try recovery.close()
        let fresh=try store(f.store.root),owner=try pairing(fresh)
        XCTAssertEqual(try owner.lastApprovedResponse(),response);XCTAssertNotNil(try fresh.get("canary"));XCTAssertEqual(Set(storage.values.keys),originalAccounts)
    }
    func testPreparedOwnerKeepsOriginalLeasesAndFenceAfterActualBusyClose()throws {
        let f=try fixture();var statement:OpaquePointer?=try holdStatement(f.store);defer {sqlite3_finalize(statement)}
        assertOriginalLeasesHeld(f);let saved=storage.values
        XCTAssertThrowsError(try f.operation.close());XCTAssertFalse(f.store.isClosed);assertOriginalLeasesHeld(f)
        try f.operation.resumeFence();XCTAssertTrue(storage.values==saved)
        XCTAssertThrowsError(try SyncMembershipPreparationOwner.open(root:f.store.root,environment:environment))
        sqlite3_finalize(statement);statement=nil;try f.operation.close();XCTAssertTrue(f.store.isClosed);try assertOriginalLeasesReleased(f)
        let recovery=try SyncMembershipPreparationOwner.open(root:f.store.root,environment:environment);operations.append(recovery)
        try recovery.applyMembership();XCTAssertNotNil(try recovery.completedResponse());try recovery.close()
        let fresh=try store(f.store.root);XCTAssertNotNil(try fresh.get("canary"))
    }
    func testCompletedOwnerKeepsExactResponseAndOriginalLeasesUntilCloseRetrySucceeds()throws {
        let f=try fixture();try f.operation.applyMembership();let response=try XCTUnwrap(f.operation.completedResponse()),saved=storage.values
        var statement:OpaquePointer?=try holdStatement(f.store);defer {sqlite3_finalize(statement)}
        XCTAssertThrowsError(try f.operation.close());XCTAssertFalse(f.store.isClosed);assertOriginalLeasesHeld(f)
        XCTAssertEqual(try f.operation.completedResponse(),response);XCTAssertTrue(storage.values==saved)
        sqlite3_finalize(statement);statement=nil;try f.operation.close();XCTAssertTrue(f.store.isClosed);try assertOriginalLeasesReleased(f)
        let fresh=try store(f.store.root),owner=try pairing(fresh);XCTAssertEqual(try owner.lastApprovedResponse(),response);XCTAssertNotNil(try fresh.get("canary"))
    }
}

private final class MembershipCloseStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let backend=PairingTestStorage()
    var failAfterReplace=false
    var values:[String:Data] {backend.values}
    func create(id:String,bytes:Data)throws {try backend.create(id:id,bytes:bytes)}
    func read(id:String)throws->Data {try backend.read(id:id)}
    func replace(id:String,expected:Data,bytes:Data)throws {
        try backend.replace(id:id,expected:expected,bytes:bytes)
        if failAfterReplace {throw SyncCredentialStorageError.unavailable(-1)}
    }
    func remove(id:String,expected:Data)throws {try backend.remove(id:id,expected:expected)}
}
