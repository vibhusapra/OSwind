import XCTest
import CSQLite
import Darwin
@testable import OSwindCore

final class SyncMembershipBackfillTests:XCTestCase {
    private var root:URL!,stores=[MemoryStore](),pairings=[PersonalSyncPairing](),services=[SyncLibraryService](),owners=[SyncMembershipFloorOwner]()
    private var storage=FloorBackfillStorage(),serial=0
    private let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"a",count:64))
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    private var environment:SyncNativeWriterEnvironment {.init(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{[storage] _ in storage})}
    private struct Fixture {let library:MemoryStore,deliveryID:String,pairingID:String,shared:URL}
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-membership-backfill-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
    override func tearDownWithError()throws {
        storage.didReplace=nil;storage.didRead=nil;try owners.forEach {try $0.close()};services.forEach {try? $0.stop();$0.inbox.close();$0.transport.close()};pairings.forEach {$0.close()};try stores.forEach {try $0.close()};try FileManager.default.removeItem(at:root)
    }
    private func store(_ url:URL)throws->MemoryStore {let value=try MemoryStore(root:url,recoveryReadOnly:false,nativeWriterEnvironment:environment);stores.append(value);return value}
    private func pair(_ library:MemoryStore)throws->PersonalSyncPairing {let value=try PersonalSyncPairing(store:library,stateRoot:environment.stateRoot,machine:machine,storage:storage);pairings.append(value);return value}
    private func object(_ data:Data)throws->[String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])}
    private func encoded(_ object:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])}
    private func fixture()throws->Fixture {
        serial+=1;let base=root.appendingPathComponent("case-\(serial)"),a=try store(base.appendingPathComponent("owner")),b=try store(base.appendingPathComponent("peer")),c=try store(base.appendingPathComponent("third")),owner=try pair(a),peer=try pair(b),third=try pair(c)
        _=try owner.createGroup(deviceName:"Owned backfill desk",now:now)
        func join(_ peer:PersonalSyncPairing,_ name:String)throws {
            let request=try XCTUnwrap(peer.requestJoin(deviceName:name,now:now).request),response=try owner.approve(owner.reviewRequest(request,now:now),now:now)
            _=try peer.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(owner.status().rootFingerprint),now:now)
        }
        try join(peer,"Owned backfill travel");let prior=try peer.membershipCertificateForRefresh();try join(third,"Owned backfill third")
        let proof=try XCTUnwrap(owner.membershipRefresh(after:prior)),shared=base.appendingPathComponent("shared"),service=try peer.prepareAnchoredService(shared:shared,createShared:true)
        services.append(service);try service.installNativeWriterAdmission();try b.insert(Memory(id:"canary",text:"Existing capture before preview migration"));_=try SyncOutgoingTests().serviceReady(service,limit:2)
        try service.stop();service.inbox.close();service.transport.close();peer.close()
        let operation=try SyncMembershipPreparationOwner.prepare(library:b,proof:proof,environment:environment);defer {try? operation.close()};try operation.applyMembership();try operation.close()
        let fresh=try store(b.root)
        let ids=try fresh.withRoutineDatabase {db->(String,String) in
            let row=try db.statement("SELECT id,(SELECT value FROM store_metadata WHERE key='sync-pairing-handle-v1') FROM personal_sync_delivery_anchor");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Owned fixture account missing")}
            return (db.text(row,0),try XCTUnwrap(object(Data(db.text(row,1).utf8))["id"] as? String))
        }
        // Author an already-cleared old652 format1 snapshot. The supported
        // current writer refuses this downgrade; it is not a migration API.
        try fresh.withRoutineDatabase {db in try fresh.nativeWriterAdmission.withMembershipMutation(db) {try SyncChangeCapture.transaction(db) {
            let current=try SyncNativeMembershipState.read(db),row=try db.statement("UPDATE store_metadata SET value=? WHERE key=?");defer {sqlite3_finalize(row)}
            db.bind(row,1,String(decoding:try SyncProtocolLimits.encode(SyncNativeMembershipState.Value.active(current.head,version:1)),as:UTF8.self));db.bind(row,2,SyncNativeMembershipState.stateKey);try db.done(row)
        }}}
        try fresh.close();let legacy=try store(b.root)
        XCTAssertGreaterThan(try legacy.withRoutineDatabase {Int64(try $0.eraseCount("SELECT sent FROM personal_sync_service_state"))},0)
        XCTAssertEqual(try legacy.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-membership-replay-v1'")},1)
        return .init(library:legacy,deliveryID:ids.0,pairingID:ids.1,shared:shared)
    }
    private func prepare(_ f:Fixture)throws->SyncMembershipFloorOwner {let owner=try SyncMembershipFloorOwner.prepare(library:f.library,environment:environment);owners.append(owner);return owner}
    private func recover(_ f:Fixture)throws->SyncMembershipFloorOwner {let owner=try SyncMembershipFloorOwner.open(root:f.library.root,environment:environment);owners.append(owner);return owner}
    private func finish(_ f:Fixture,_ owner:SyncMembershipFloorOwner)throws->MemoryStore {try owner.complete();try owner.close();return try store(f.library.root)}
    private func files(_ url:URL)throws->[String:String] {
        let enumerator=try XCTUnwrap(FileManager.default.enumerator(at:url,includingPropertiesForKeys:[.isRegularFileKey]));var result=[String:String]()
        for case let path as URL in enumerator where try path.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true {result[String(path.path.dropFirst(url.path.count+1))]=SyncProtocolLimits.hex(try Data(contentsOf:path))};return result
    }
    private func token(_ object:[String:Any])throws->SyncDeliveryAnchor.Token {try SyncPairingFormat.decode(SyncDeliveryAnchor.Token.self,JSONSerialization.data(withJSONObject:XCTUnwrap(object["token"]),options:[.sortedKeys,.withoutEscapingSlashes]),limit:1024)}
    func testBackfillFencesCachedWritersPreservesReplayCredentialsAndProviderAndIsNoopAtTwo()throws {
        let f=try fixture(),accounts=storage.values,provider=try files(f.shared),before=try object(XCTUnwrap(accounts[f.deliveryID])),original=try token(before),stale=try store(f.library.root)
        let row=try stale.withRoutineDatabase {try $0.statement("UPDATE memories SET title='stale-after-backfill' WHERE id='canary'")};defer {sqlite3_finalize(row)}
        let replay=try f.library.withRoutineDatabase {db->String in let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-membership-replay-v1'");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Owned replay missing")};return db.text(row,0)}
        let owner=try prepare(f);XCTAssertTrue(owner.requiresUpgrade);XCTAssertThrowsError(try f.library.get("canary"));XCTAssertThrowsError(try store(f.library.root));XCTAssertNotEqual(sqlite3_step(row),SQLITE_DONE)
        let pending=try object(XCTUnwrap(storage.values[f.deliveryID]));XCTAssertNotNil(pending["membershipFloor"]);XCTAssertEqual(try token(pending).serial,original.serial+1)
        let fresh=try finish(f,owner),after=try object(XCTUnwrap(storage.values[f.deliveryID]))
        XCTAssertNil(after["membershipFloor"]);XCTAssertEqual(try token(after),try token(pending));XCTAssertTrue(storage.values[f.pairingID]==accounts[f.pairingID]);XCTAssertTrue((after["material"] as? String)==(before["material"] as? String));XCTAssertEqual(storage.values.count,accounts.count)
        XCTAssertEqual(try fresh.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2);XCTAssertNotNil(try fresh.get("canary"));XCTAssertThrowsError(try stale.insert(Memory(id:"stale",text:"Must refuse")))
        XCTAssertEqual(try fresh.withRoutineDatabase {db->String in let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-membership-replay-v1'");defer {sqlite3_finalize(row)};_ = sqlite3_step(row);return db.text(row,0)},replay)
        let saved=storage.values,attempts=storage.attempts,epoch=try fresh.withRoutineDatabase {try fresh.nativeWriterAdmission.membershipEpoch($0)},noOp=try SyncMembershipFloorOwner.prepare(library:fresh,environment:environment);owners.append(noOp)
        XCTAssertFalse(noOp.requiresUpgrade);try noOp.complete();try noOp.complete();try noOp.close();XCTAssertTrue(storage.values==saved);XCTAssertEqual(storage.attempts,attempts)
        let reopened=try store(fresh.root);XCTAssertEqual(try reopened.withRoutineDatabase {try reopened.nativeWriterAdmission.membershipEpoch($0)},epoch);XCTAssertEqual(try files(f.shared),provider)
        let pairing=try pair(reopened),service=try pairing.prepareAnchoredService(shared:f.shared,createShared:false);services.append(service);_=try SyncOutgoingTests().serviceReady(service,limit:2)
        XCTAssertEqual(try reopened.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-membership-replay-v1'")},0)
    }
    func testRejectedCommitRecoversExactTargetAndPreservesPreFenceCapture()throws {
        let f=try fixture(),stale=try store(f.library.root),handle=try f.library.withRoutineDatabase {$0.handle},gate=FloorBackfillCommitGate(),provider=try files(f.shared),accounts=storage.values
        storage.didReplace={_ in sqlite3_commit_hook(handle,FloorBackfillCommitGate.callback,Unmanaged.passUnretained(gate).toOpaque())}
        XCTAssertThrowsError(try prepare(f));storage.didReplace=nil;sqlite3_commit_hook(handle,nil,nil);XCTAssertEqual(gate.rejections,1)
        let pending=try object(XCTUnwrap(storage.values[f.deliveryID])),attempts=storage.attempts
        try stale.insert(Memory(id:"pre-fence",text:"Legitimate capture after rejected native COMMIT"));try f.library.close();XCTAssertThrowsError(try store(f.library.root))
        let resumed=try recover(f),fresh=try finish(f,resumed)
        XCTAssertEqual(storage.attempts,attempts+1);XCTAssertEqual(try token(object(XCTUnwrap(storage.values[f.deliveryID]))),try token(pending))
        XCTAssertNotNil(try fresh.get("pre-fence"));XCTAssertThrowsError(try stale.insert(Memory(id:"after-fence",text:"Refuse")));XCTAssertNotNil(try fresh.get("canary"));XCTAssertTrue(storage.values[f.pairingID]==accounts[f.pairingID]);XCTAssertEqual(try files(f.shared),provider)
    }
    func testAmbiguousIntentAndClearSavesRecoverWithoutExtraCheckpointOrAccounts()throws {
        for boundary in [1,2] {for afterPersistence in [false,true] {
            let f=try fixture(),before=storage.values,initial=try token(object(XCTUnwrap(before[f.deliveryID]))),start=storage.attempts
            storage.failAt=start+boundary;storage.failAfter=afterPersistence
            if boundary==1 {XCTAssertThrowsError(try prepare(f));try f.library.close()}
            else {let owner=try prepare(f);XCTAssertThrowsError(try owner.complete());try owner.close()}
            storage.failAt=nil
            let saved=try object(XCTUnwrap(storage.values[f.deliveryID])),fresh:MemoryStore
            if saved["membershipFloor"] != nil {fresh=try finish(f,recover(f))}
            else if boundary==1 {let normal=try store(f.library.root),owner=try SyncMembershipFloorOwner.prepare(library:normal,environment:environment);owners.append(owner);fresh=try finish(f,owner)}
            else {fresh=try store(f.library.root)}
            XCTAssertEqual(try token(object(XCTUnwrap(storage.values[f.deliveryID]))).serial,initial.serial+1)
            if boundary==2 || afterPersistence {XCTAssertEqual(try token(object(XCTUnwrap(storage.values[f.deliveryID]))),try token(saved))}
            XCTAssertTrue(storage.values[f.pairingID]==before[f.pairingID]);XCTAssertEqual(storage.values.count,before.count);XCTAssertNotNil(try fresh.get("canary"));XCTAssertEqual(try fresh.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2)
        }}
    }
    func testPendingFloorRejectsClonesChangedPairingAndMissingOriginalAccount()throws {
        let f=try fixture(),owner=try prepare(f);try owner.close();let saved=storage.values
        let clone=root.appendingPathComponent("cloned-library");try FileManager.default.copyItem(at:f.library.root,to:clone);XCTAssertThrowsError(try SyncMembershipFloorOwner.open(root:clone,environment:environment))
        storage.removeFixture(f.pairingID);XCTAssertThrowsError(try recover(f));storage.overwrite(f.pairingID,bytes:try XCTUnwrap(saved[f.pairingID]))
        var pairing=try object(XCTUnwrap(saved[f.pairingID]));pairing["consumedRequest"]=String(repeating:"e",count:64);storage.overwrite(f.pairingID,bytes:try encoded(pairing));XCTAssertThrowsError(try recover(f));storage.overwrite(f.pairingID,bytes:try XCTUnwrap(saved[f.pairingID]))
        let attempts=storage.attempts;let fresh=try finish(f,recover(f));XCTAssertNotNil(try fresh.get("canary"));XCTAssertEqual(storage.attempts,attempts+1)
    }
    func testPendingRecordRejectsInvalidExactTargetAndOperationOverlap()throws {
        let f=try fixture(),owner=try prepare(f);try owner.close();let saved=try XCTUnwrap(storage.values[f.deliveryID]),envelope=try object(saved),pending=try XCTUnwrap(envelope["membershipFloor"] as? [String:Any]),attempts=storage.attempts
        var mutations=[[String:Any]]()
        for key in ["format","operation","pairingID","pairingDigest","materialDigest","head","epochBefore","epochAfter"] {var bad=pending;bad[key]="invalid";mutations.append(bad)}
        var sameEpoch=pending;sameEpoch["epochAfter"]=pending["epochBefore"];mutations.append(sameEpoch)
        var sameToken=pending;sameToken["tokenAfter"]=pending["tokenBefore"];mutations.append(sameToken)
        for bad in mutations {var changed=envelope;changed["membershipFloor"]=bad;storage.overwrite(f.deliveryID,bytes:try encoded(changed));XCTAssertThrowsError(try recover(f));XCTAssertThrowsError(try store(f.library.root))}
        let floor=try SyncPairingFormat.decode(SyncMembershipFloorPreparation.self,encoded(pending),limit:4096)
        let conflicting=SyncMembershipPreparation(format:"OSwind.sync.membership-preparation",version:1,operation:UUID().uuidString.lowercased(),plan:try SyncContentReference(data:Data("conflicting proof".utf8)),pairingID:floor.pairingID,pairingBefore:floor.pairingDigest,pairingAfter:String(repeating:"b",count:64),materialBefore:floor.materialDigest,materialAfter:String(repeating:"c",count:64),headBefore:floor.head,headAfter:String(repeating:"d",count:64),nativeBefore:36,epochBefore:floor.epochBefore,epochPrepared:floor.epochAfter,tokenBefore:floor.tokenBefore,tokenPrepared:floor.tokenAfter,disposition:.preparing,stateVersionBefore:1)
        try conflicting.validate();var overlap=envelope;overlap["membershipPreparation"]=try object(SyncProtocolLimits.encode(conflicting));storage.overwrite(f.deliveryID,bytes:try encoded(overlap));XCTAssertThrowsError(try recover(f))
        storage.overwrite(f.deliveryID,bytes:saved);XCTAssertEqual(storage.attempts,attempts);_=try finish(f,recover(f))
    }
    func testCancellationBeforeIntentDoesNotChangeNativeOrExternalHistory()async throws {
        let f=try fixture(),saved=storage.values,attempts=storage.attempts,env=environment,gate=FloorBackfillCancellationGate()
        let worker=Task.detached {()->Bool in
            gate.block()
            do {let owner=try SyncMembershipFloorOwner.prepare(library:f.library,environment:env);try owner.close();return false}
            catch is CancellationError {return true}
            catch {return false}
        }
        await fulfillment(of:[gate.reached],timeout:10);worker.cancel();gate.release();let cancelled=await worker.value
        XCTAssertTrue(cancelled);XCTAssertTrue(storage.values==saved);XCTAssertEqual(storage.attempts,attempts)
        XCTAssertEqual(try f.library.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},1);try f.library.insert(Memory(id:"after-cancel",text:"Capture after pre-intent cancellation"));XCTAssertNotNil(try f.library.get("after-cancel"))
    }
    func testCancellationAfterDurableIntentFinishesForwardChoiceAndClosesOwner()async throws {
        let f=try fixture(),env=environment,gate=FloorBackfillCancellationGate(),attempts=storage.attempts
        storage.didReplace={ordinal in if ordinal==attempts+1 {gate.block()}}
        let worker=Task.detached {()->Bool in
            let upgraded=try await SyncMembershipFloorOwner.upgrade(library:f.library,environment:env)
            return upgraded && Task.isCancelled
        }
        await fulfillment(of:[gate.reached],timeout:10);worker.cancel();gate.release();let ignoredAfterIntent=try await worker.value;storage.didReplace=nil
        XCTAssertTrue(ignoredAfterIntent);XCTAssertTrue(f.library.isClosed);XCTAssertEqual(storage.attempts,attempts+2)
        let fresh=try store(f.library.root);XCTAssertEqual(try fresh.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2);XCTAssertNil(try object(XCTUnwrap(storage.values[f.deliveryID]))["membershipFloor"]);XCTAssertNotNil(try fresh.get("canary"))
    }
    func testAsyncCancellationBeforeIntentJoinsWorkerAndClosesTransferredStore()async throws {
        let f=try fixture(),env=environment,saved=storage.values,attempts=storage.attempts,gate=FloorBackfillReadGate()
        storage.didRead={gate.blockOnce()}
        let worker=Task.detached {()->Bool in
            do {_=try await SyncMembershipFloorOwner.upgrade(library:f.library,environment:env);return false}
            catch is CancellationError {return true}
            catch {return false}
        }
        await fulfillment(of:[gate.reached],timeout:10);worker.cancel();gate.release();let cancelled=await worker.value;storage.didRead=nil
        XCTAssertTrue(cancelled);XCTAssertTrue(f.library.isClosed);XCTAssertTrue(storage.values==saved);XCTAssertEqual(storage.attempts,attempts)
        let fresh=try store(f.library.root);XCTAssertEqual(try fresh.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},1);XCTAssertNotNil(try fresh.get("canary"))
    }
    func testAsyncCancelledAmbiguousFailureJoinsBeforeReturningAndLeavesExactRecovery()async throws {
        let f=try fixture(),env=environment,gate=FloorBackfillCancellationGate(),probe=FloorBackfillCompletionProbe(),attempts=storage.attempts
        storage.failAt=attempts+1;storage.failAfter=true;storage.didReplace={ordinal in if ordinal==attempts+1 {gate.block()}}
        let worker=Task.detached {()->Bool in
            defer {probe.markCompleted()}
            do {_=try await SyncMembershipFloorOwner.upgrade(library:f.library,environment:env);return false}
            catch is CancellationError {return false}
            catch {return true}
        }
        await fulfillment(of:[gate.reached],timeout:10);worker.cancel()
        try await Task.sleep(for:.milliseconds(100));XCTAssertFalse(probe.completed,"Cancellation must keep joining the blocked worker")
        gate.release();let failed=await worker.value;storage.didReplace=nil;storage.failAt=nil
        XCTAssertTrue(failed);XCTAssertTrue(probe.completed);XCTAssertTrue(f.library.isClosed)
        let saved=try object(XCTUnwrap(storage.values[f.deliveryID])),target=try token(saved);XCTAssertNotNil(saved["membershipFloor"])
        let fresh=try finish(f,recover(f));XCTAssertEqual(try token(object(XCTUnwrap(storage.values[f.deliveryID]))),target);XCTAssertNotNil(try fresh.get("canary"))
    }
    func testRecoveryRejectsMismatchedNativeEpochTokenPhaseAndAccountWithoutRepair()throws {
        for field in ["epochAfter","tokenAfter","head"] {
            let f=try fixture(),owner=try prepare(f);try owner.close();let original=try XCTUnwrap(storage.values[f.deliveryID]);var envelope=try object(original),floor=try XCTUnwrap(envelope["membershipFloor"] as? [String:Any])
            if field=="tokenAfter" {var token=try XCTUnwrap(floor[field] as? [String:Any]);token["nonce"]=String(repeating:"e",count:32);floor[field]=token;envelope["token"]=token}
            else {floor[field]=String(repeating:"e",count:field=="head" ? 64:32)}
            envelope["membershipFloor"]=floor;let attempts=storage.attempts;storage.overwrite(f.deliveryID,bytes:try encoded(envelope));XCTAssertThrowsError(try recover(f));XCTAssertEqual(storage.attempts,attempts);storage.overwrite(f.deliveryID,bytes:original);_=try finish(f,recover(f))
        }
    }
}

private final class FloorBackfillCancellationGate:@unchecked Sendable {
    let reached=XCTestExpectation(description:"Owned floor cancellation gate reached")
    private let permit=DispatchSemaphore(value:0)
    func block() {reached.fulfill();permit.wait()}
    func release() {permit.signal()}
}

private final class FloorBackfillStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection=SyncCredentialProtection.loginKeychain
    private let lock=NSLock();private var saved=[String:Data](),count=0
    var failAt:Int?,failAfter=false,didReplace:((Int)->Void)?,didRead:(()->Void)?
    var values:[String:Data] {lock.lock();defer {lock.unlock()};return saved}
    var attempts:Int {lock.lock();defer {lock.unlock()};return count}
    func create(id:String,bytes:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==nil else {throw SyncCredentialStorageError.alreadyExists};saved[id]=bytes}
    func read(id:String)throws->Data {lock.lock();guard let bytes=saved[id] else {lock.unlock();throw SyncCredentialStorageError.missing};let callback=didRead;lock.unlock();callback?();return bytes}
    func replace(id:String,expected:Data,bytes:Data)throws {
        lock.lock();count+=1;let ordinal=count,fail=ordinal==failAt,after=failAfter
        if fail && !after {lock.unlock();throw SyncCredentialStorageError.unavailable(-1)}
        guard saved[id]==expected else {lock.unlock();throw SyncCredentialStorageError.changed};saved[id]=bytes;lock.unlock();didReplace?(ordinal)
        if fail && after {throw SyncCredentialStorageError.unavailable(-1)}
    }
    func remove(id:String,expected:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved.removeValue(forKey:id)}
    func overwrite(_ id:String,bytes:Data) {lock.lock();saved[id]=bytes;lock.unlock()}
    func removeFixture(_ id:String) {lock.lock();saved.removeValue(forKey:id);lock.unlock()}
}
private final class FloorBackfillCommitGate {
    private(set) var rejections=0
    static let callback:@convention(c) (UnsafeMutableRawPointer?)->Int32 = {pointer in
        let gate=Unmanaged<FloorBackfillCommitGate>.fromOpaque(pointer!).takeUnretainedValue();if gate.rejections==0 {gate.rejections+=1;return 1};return 0
    }
}

private final class FloorBackfillReadGate:@unchecked Sendable {
    let reached=XCTestExpectation(description:"Owned floor read gate reached")
    private let lock=NSLock(),permit=DispatchSemaphore(value:0);private var entered=false
    func blockOnce() {lock.lock();let first = !entered;entered=true;lock.unlock();if first {reached.fulfill();permit.wait()}}
    func release() {permit.signal()}
}
private final class FloorBackfillCompletionProbe:@unchecked Sendable {
    private let lock=NSLock();private var done=false
    var completed:Bool {lock.lock();defer {lock.unlock()};return done}
    func markCompleted() {lock.lock();done=true;lock.unlock()}
}
