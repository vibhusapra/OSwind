import XCTest
import CSQLite
@testable import OSwindCore

final class SyncDeliveryOwnerResponseTests:XCTestCase {
    private var root:URL!,stores=[MemoryStore](),pairings=[PersonalSyncPairing](),operations=[SyncMembershipPreparationOwner]()
    private var storage=DeliveryApprovalStorage()
    private var serial=0
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    private let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"a",count:64))
    private var environment:SyncNativeWriterEnvironment {.init(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{[storage] _ in storage})}
    private struct Fixture {
        let store:MemoryStore,pending:PersonalSyncPairing,review:PersonalSyncPairingReview
        let pairingID:String,deliveryID:String,initialResponse:String?,fingerprint:String,inbox:URL,request:String
    }
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-delivery-response-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)}
    override func tearDownWithError()throws {
        storage.failAt=nil;storage.didReplace=nil;try operations.forEach {try $0.close()};pairings.forEach {$0.close()};try stores.forEach {try $0.close()};try FileManager.default.removeItem(at:root)
    }
    private func store(_ path:URL)throws->MemoryStore {let value=try MemoryStore(root:path,recoveryReadOnly:false,nativeWriterEnvironment:environment);stores.append(value);return value}
    private func pair(_ value:MemoryStore)throws->PersonalSyncPairing {let result=try PersonalSyncPairing(store:value,stateRoot:environment.stateRoot,machine:machine,storage:storage);pairings.append(result);return result}
    private func object(_ data:Data)throws->[String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])}
    private func encoded(_ value:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    private func fixture(initialPeer:Bool=true)throws->Fixture {
        serial+=1;let base=root.appendingPathComponent("fixture-\(serial)"),library=try store(base.appendingPathComponent("owner")),owner=try pair(library)
        _=try owner.createGroup(deviceName:"Owned response desk",now:now);let fingerprint=try XCTUnwrap(owner.status().rootFingerprint)
        var initial:String?
        if initialPeer {
            let peer=try pair(store(base.appendingPathComponent("first"))),text=try XCTUnwrap(peer.requestJoin(deviceName:"Owned first peer",now:now).request)
            initial=try owner.approve(owner.reviewRequest(text,now:now),now:now)
            _=try peer.acceptResponse(XCTUnwrap(initial),trustedRootFingerprint:fingerprint,now:now);peer.close()
        }
        let service=try owner.prepareAnchoredService(shared:base.appendingPathComponent("provider"),createShared:true)
        try service.installNativeWriterAdmission();try library.insert(Memory(id:"canary",text:"Owned source before approval"))
        try service.stop();service.inbox.close();service.transport.close();owner.close()
        let current=try pair(library),pending=try pair(store(base.appendingPathComponent("new-peer"))),text=try XCTUnwrap(pending.requestJoin(deviceName:"Owned new peer",now:now).request)
        let review=try current.reviewDeliveredRequest(text,now:now)
        let ids=try library.withRoutineDatabase {db->(String,String) in
            let row=try db.statement("SELECT id,(SELECT value FROM store_metadata WHERE key='sync-pairing-handle-v1') FROM personal_sync_delivery_anchor");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Owned fixture account missing")}
            return (try XCTUnwrap(object(Data(db.text(row,1).utf8))["id"] as? String),db.text(row,0))
        }
        let value=try object(XCTUnwrap(storage.values[ids.0])),raw=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(value["material"] as? String))),material=try SyncCredentialMaterial.decodeFromKeychain(raw)
        current.close()
        return .init(store:library,pending:pending,review:review,pairingID:ids.0,deliveryID:ids.1,initialResponse:initial,fingerprint:fingerprint,inbox:library.root.appendingPathComponent("images/device-sync-"+material.joined.replica),request:text)
    }
    private func prepare(_ f:Fixture,clock:(()->Date)?=nil)throws->SyncMembershipPreparationOwner {
        let value=try SyncMembershipPreparationOwner.prepareApproval(library:f.store,review:f.review,environment:environment,clock:clock ?? {self.now});operations.append(value);return value
    }
    private func recover(_ f:Fixture)throws->SyncMembershipPreparationOwner {let value=try SyncMembershipPreparationOwner.open(root:f.store.root,environment:environment);operations.append(value);return value}
    private func preparation(_ f:Fixture)throws->SyncMembershipPreparation {
        let value=try object(XCTUnwrap(storage.values[f.deliveryID]));return try SyncPairingFormat.decode(SyncMembershipPreparation.self,encoded(XCTUnwrap(value["membershipPreparation"] as? [String:Any])),limit:8192)
    }
    private func savedPlan(_ f:Fixture,_ reference:SyncDeliveryApprovalReference)throws->SyncOwnerApprovalPlan {
        let value=try object(XCTUnwrap(storage.values[f.pairingID])),raw=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(value["material"] as? String))),material=try SyncCredentialMaterial.decodeFromKeychain(raw)
        let inbox=try material.joined.openPrivateInbox(at:f.inbox);defer {inbox.close()}
        return try SyncOwnerApprovalPlan.decode(XCTUnwrap(inbox.content(reference.approval.content)))
    }
    private func completed(_ f:Fixture)throws->SyncDeliveryApprovalReference {
        let value=try object(XCTUnwrap(storage.values[f.deliveryID]));return try SyncPairingFormat.decode(SyncDeliveryApprovalReference.self,encoded(XCTUnwrap(value["completedApproval"] as? [String:Any])),limit:2048)
    }
    private func files(_ path:URL)throws->Set<String> {
        let e=try XCTUnwrap(FileManager.default.enumerator(at:path,includingPropertiesForKeys:[.isRegularFileKey]));return Set(try e.allObjects.compactMap {item->String? in guard let file=item as? URL,try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true else {return nil};return file.path})
    }
    func testFinalClearAtomicallyKeepsExactResponseAndFreshOwnerRecoversLatest()throws {
        let f=try fixture(),before=storage.values,accounts=Set(before.keys),op=try prepare(f),record=try preparation(f),reference=try XCTUnwrap(record.approval),plan=try savedPlan(f,reference)
        XCTAssertNotEqual(reference.publicationLifetime,reference.approval.lifetime)
        XCTAssertTrue(storage.values[f.pairingID]==before[f.pairingID]);XCTAssertThrowsError(try op.completedResponse())
        try op.applyMembership();let response=try XCTUnwrap(op.completedResponse())
        XCTAssertEqual(response.response,String(decoding:plan.response,as:UTF8.self));XCTAssertEqual(response.requestFingerprint,f.review.requestFingerprint);XCTAssertEqual(response.expires,f.review.expires)
        let after=try object(XCTUnwrap(storage.values[f.deliveryID]));XCTAssertNil(after["membershipPreparation"]);XCTAssertTrue(try completed(f)==reference)
        try op.close();let fresh=try store(f.store.root),owner=try pair(fresh)
        XCTAssertEqual(try owner.lastApprovedResponse()?.response,response.response);XCTAssertNotEqual(response.response,f.initialResponse)
        XCTAssertTrue(try owner.status().lastResponseAvailable);XCTAssertNotNil(try fresh.get("canary"));XCTAssertEqual(Set(storage.values.keys),accounts)
        _=try f.pending.acceptResponse(response.response,trustedRootFingerprint:f.fingerprint,now:now)
    }
    func testFirstPostDeliveryApprovalMakesResponseAvailableWithoutInitialReceipt()throws {
        let f=try fixture(initialPeer:false),op=try prepare(f);try op.applyMembership();let response=try XCTUnwrap(op.completedResponse());try op.close()
        let fresh=try store(f.store.root),owner=try pair(fresh);XCTAssertTrue(try owner.status().lastResponseAvailable)
        XCTAssertEqual(try owner.lastApprovedResponse()?.response,response.response)
    }
    func testExpiryAtIntentRefusesWithoutChangingPrivateAuthorityOrNativeFloor()throws {
        let f=try fixture(),before=storage.values;var checks=0
        XCTAssertThrowsError(try prepare(f,clock:{checks+=1;return checks==1 ? self.now:self.now.addingTimeInterval(701)}))
        XCTAssertGreaterThanOrEqual(checks,2);XCTAssertTrue(storage.values==before)
        XCTAssertEqual(try f.store.withRoutineDatabase {try $0.eraseCount("PRAGMA user_version")},35);XCTAssertNotNil(try f.store.get("canary"))
    }
    func testMissingLatestPlanRefusesInsteadOfReturningValidInitialResponse()throws {
        let f=try fixture(),before=try files(f.inbox.appendingPathComponent("objects")),op=try prepare(f)
        try op.applyMembership();XCTAssertNotNil(try op.completedResponse());try op.close()
        let after=try files(f.inbox.appendingPathComponent("objects"));XCTAssertGreaterThan(after.count,before.count)
        for path in after.subtracting(before) {try FileManager.default.removeItem(atPath:path)}
        let fresh=try store(f.store.root),owner=try pair(fresh),saved=storage.values
        XCTAssertThrowsError(try owner.lastApprovedResponse());XCTAssertTrue(storage.values==saved);XCTAssertNotNil(f.initialResponse)
    }
    func testExactExpiredResponseCanRecoverButCannotRenewJoinerExpiry()throws {
        let f=try fixture(),op=try prepare(f);try op.applyMembership();let original=try XCTUnwrap(op.completedResponse());try op.close()
        let owner=try pair(store(f.store.root));XCTAssertEqual(try owner.lastApprovedResponse()?.response,original.response)
        XCTAssertThrowsError(try f.pending.acceptResponse(original.response,trustedRootFingerprint:f.fingerprint,now:now.addingTimeInterval(701)))
        XCTAssertEqual(try owner.lastApprovedResponse()?.expires,f.review.expires)
    }
    func testPreparationOptionalFieldKeepsCanonicalLegacyBytesAndDecisionPointer()throws {
        let f=try fixture(),op=try prepare(f),record=try preparation(f),approval=try XCTUnwrap(record.approval)
        XCTAssertTrue(try record.applying(1).approval==approval);XCTAssertTrue(record.cancelling().approval==approval)
        var legacy=try object(SyncProtocolLimits.encode(record));legacy.removeValue(forKey:"approval");let bytes=try encoded(legacy)
        let decoded=try SyncPairingFormat.decode(SyncMembershipPreparation.self,bytes,limit:8192);XCTAssertNil(decoded.approval);XCTAssertTrue(try SyncProtocolLimits.encode(decoded)==bytes)
        let legacyPublication=SyncDeliveryApprovalReference(approval:approval.approval,publicationLifetime:String(repeating:"a",count:32));XCTAssertNoThrow(try legacyPublication.validate())
        XCTAssertThrowsError(try legacyPublication.require(pairingID:f.pairingID,head:record.headAfter,publicationLifetime:approval.publicationLifetime))
        try op.cancelBeforeHandover();try op.close()
    }
    func testEveryPrivateSaveFailureRecoversOriginalSavedCiphertextWithoutNewAccounts()throws {
        for boundary in 1...5 {for after in [false,true] {
            let f=try fixture(),accounts=Set(storage.values.keys),start=storage.attempts
            storage.failAt=start+boundary;storage.failAfter=after
            if boundary==1 {XCTAssertThrowsError(try prepare(f));try f.store.close()}
            else {let op=try prepare(f);XCTAssertThrowsError(try op.applyMembership());try op.close()}
            storage.failAt=nil
            let saved=try object(XCTUnwrap(storage.values[f.deliveryID])),response:String
            if saved["membershipPreparation"] != nil {
                let record=try preparation(f),expected=try savedPlan(f,XCTUnwrap(record.approval)).response
                let resumed=try recover(f);try resumed.applyMembership()
                response=try XCTUnwrap(resumed.completedResponse()).response
                XCTAssertEqual(response,String(decoding:expected,as:UTF8.self));try resumed.close()
            } else if boundary==1 {
                let fresh=try store(f.store.root),op=try SyncMembershipPreparationOwner.prepareApproval(library:fresh,review:f.review,environment:environment,clock:{self.now});operations.append(op)
                try op.applyMembership();response=try XCTUnwrap(op.completedResponse()).response;try op.close()
            } else {
                XCTAssertEqual(boundary,5);XCTAssertTrue(after)
                let expected=try savedPlan(f,completed(f)).response,owner=try pair(store(f.store.root))
                response=try XCTUnwrap(owner.lastApprovedResponse()).response
                XCTAssertEqual(response,String(decoding:expected,as:UTF8.self));owner.close()
            }
            let fresh=try store(f.store.root),owner=try pair(fresh)
            XCTAssertEqual(try owner.lastApprovedResponse()?.response,response);XCTAssertNotNil(try fresh.get("canary"));XCTAssertEqual(Set(storage.values.keys),accounts)
            _=try f.pending.acceptResponse(response,trustedRootFingerprint:f.fingerprint,now:now)
            owner.close()
        }}
    }
    func testCancellingLaterApprovalKeepsPreviousCompletedReceipt()throws {
        let f=try fixture(),op=try prepare(f);try op.applyMembership();let first=try XCTUnwrap(op.completedResponse()).response;try op.close()
        let fresh=try store(f.store.root),owner=try pair(fresh),later=try pair(store(root.appendingPathComponent("cancel-later")))
        let request=try XCTUnwrap(later.requestJoin(deviceName:"Owned later cancelled peer",now:now).request),review=try owner.reviewDeliveredRequest(request,now:now),original=try completed(f)
        owner.close();let cancelled=try SyncMembershipPreparationOwner.prepareApproval(library:fresh,review:review,environment:environment,clock:{self.now});operations.append(cancelled)
        try cancelled.cancelBeforeHandover();try cancelled.close()
        XCTAssertTrue(try completed(f)==original)
        let reopened=try pair(store(f.store.root));XCTAssertEqual(try reopened.lastApprovedResponse()?.response,first)
        XCTAssertFalse(try reopened.status().memberNames.contains("Owned later cancelled peer"))
    }
    func testCompletedReceiptSurvivesLaterSignedHeadAndLegacyFloorUpgrade()throws {
        let f=try fixture(),op=try prepare(f);try op.applyMembership();let first=try XCTUnwrap(op.completedResponse()).response;try op.close()
        let fresh=try store(f.store.root),value=try object(XCTUnwrap(storage.values[f.pairingID])),raw=try XCTUnwrap(Data(base64Encoded:XCTUnwrap(value["material"] as? String))),material=try SyncCredentialMaterial.decodeFromKeychain(raw)
        let pending=try SyncPendingJoin(name:"Owned later signed member",now:now),authority=try XCTUnwrap(material.owner),next=try authority.admitting(pending.request,now:now)
        let proof=try SyncMembershipRefresh(base:authority.certificate,updates:[next.certificate]),advance=try SyncMembershipPreparationOwner.prepare(library:fresh,proof:proof,environment:environment);operations.append(advance)
        try advance.applyMembership();try advance.close()
        let current=try store(f.store.root)
        // Author the already-cleared format1 state used by historical previews.
        // Current supported writes reject this downgrade; this is a test fixture.
        try current.withRoutineDatabase {db in try current.nativeWriterAdmission.withMembershipMutation(db) {try SyncChangeCapture.transaction(db) {
            let head=try SyncNativeMembershipState.read(db).head,row=try db.statement("UPDATE store_metadata SET value=? WHERE key=?");defer {sqlite3_finalize(row)}
            db.bind(row,1,String(decoding:try SyncProtocolLimits.encode(SyncNativeMembershipState.Value.active(head,version:1)),as:UTF8.self));db.bind(row,2,SyncNativeMembershipState.stateKey);try db.done(row)
        }}}
        try current.close();let legacy=try store(f.store.root),floor=try SyncMembershipFloorOwner.prepare(library:legacy,environment:environment);defer {try? floor.close()}
        XCTAssertTrue(floor.requiresUpgrade);try floor.complete();try floor.close()
        let owner=try pair(store(f.store.root));XCTAssertEqual(try owner.lastApprovedResponse()?.response,first)
    }
    func testPublicGuardAndAlreadyAdmittedOrChangedReviewsStayRefused()throws {
        let f=try fixture(),op=try prepare(f);try op.applyMembership();try op.close()
        let fresh=try store(f.store.root),owner=try pair(fresh),text=f.request
        XCTAssertThrowsError(try owner.reviewRequest(text,now:now));XCTAssertThrowsError(try owner.approve(f.review,now:now))
        let admitted=try owner.reviewDeliveredRequest(text,now:now);XCTAssertTrue(admitted.alreadyAdmitted);owner.close();let saved=storage.values
        XCTAssertThrowsError(try SyncMembershipPreparationOwner.prepareApproval(library:fresh,review:admitted,environment:environment,clock:{self.now}))
        XCTAssertThrowsError(try SyncMembershipPreparationOwner.prepareApproval(library:fresh,review:f.review,environment:environment,clock:{self.now}))
        XCTAssertTrue(storage.values==saved)
    }
    func testLocalRetirementClearsCompletedReceiptBeforeRemovingPublicationLifetime()async throws {
        let f=try fixture(),op=try prepare(f);try op.applyMembership();try op.close()
        let fresh=try store(f.store.root),owner=try pair(fresh);var sawRetirement=false
        storage.didReplace={bytes in
            guard let value=try? self.object(bytes),value["retirement"] != nil else {return}
            sawRetirement=true;XCTAssertNil(value["completedApproval"])
        }
        let erasure=try owner.prepareLocalErasure();let result=try await erasure.erase();await erasure.stop();storage.didReplace=nil
        XCTAssertTrue(result.cleanupComplete);XCTAssertTrue(sawRetirement)
    }
    func testLatestResponseRecoveryDoesNotNeedAvailableProviderFolder()async throws {
        let f=try fixture(),op=try prepare(f);try op.applyMembership();let reply=try XCTUnwrap(op.completedResponse());try op.close()
        let provider=f.store.root.deletingLastPathComponent().appendingPathComponent("provider")
        let savedOwner=try pair(store(f.store.root)),session=try savedOwner.prepareSession(sharedFolder:provider)
        try await session.stop()
        let fresh=try store(f.store.root),owner=try pair(fresh)
        XCTAssertEqual(try owner.savedSessionFolder()?.standardizedFileURL,provider.standardizedFileURL)
        try FileManager.default.removeItem(at:provider)
        let saved=storage.values
        XCTAssertEqual(try owner.lastApprovedResponse()?.response,reply.response)
        XCTAssertThrowsError(try owner.prepareSavedSession())
        XCTAssertEqual(try owner.lastApprovedResponse()?.response,reply.response);XCTAssertTrue(storage.values==saved)
    }
    func testLiveSessionRefusesApprovalUntilExactSessionStops()async throws {
        let f=try fixture(),owner=try pair(f.store),session=try owner.prepareSession(sharedFolder:f.store.root.deletingLastPathComponent().appendingPathComponent("provider")),saved=storage.values
        XCTAssertThrowsError(try prepare(f));XCTAssertTrue(storage.values==saved)
        try await session.stop()
        let op=try prepare(f);try op.applyMembership();XCTAssertNotNil(try op.completedResponse());try op.close()
    }
    func testForgedPublicationLifetimeOrUnknownReferenceFieldsRefuse()throws {
        let f=try fixture(),op=try prepare(f);try op.applyMembership();try op.close()
        let original=try XCTUnwrap(storage.values[f.deliveryID]),value=try object(original),reference=try XCTUnwrap(value["completedApproval"] as? [String:Any])
        for key in ["publicationLifetime","unknownField"] {
            var altered=value,changed=reference;changed[key]=key=="publicationLifetime" ? UUID().uuidString.lowercased():"unrecognized";altered["completedApproval"]=changed
            storage.overwrite(f.deliveryID,bytes:try encoded(altered));XCTAssertThrowsError(try store(f.store.root));storage.overwrite(f.deliveryID,bytes:original)
        }
        let owner=try pair(store(f.store.root));XCTAssertNotNil(try owner.lastApprovedResponse())
    }
}

private final class DeliveryApprovalStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let backend=PairingTestStorage(),lock=NSLock()
    private var count=0
    var failAt:Int?,failAfter=false
    var didReplace:((Data)->Void)?
    var values:[String:Data] {backend.values}
    var attempts:Int {lock.lock();defer {lock.unlock()};return count}
    func create(id:String,bytes:Data)throws {try backend.create(id:id,bytes:bytes)}
    func read(id:String)throws->Data {try backend.read(id:id)}
    func replace(id:String,expected:Data,bytes:Data)throws {
        lock.lock();count+=1;let fail=count==failAt,after=failAfter;lock.unlock()
        if fail && !after {throw SyncCredentialStorageError.unavailable(-1)}
        try backend.replace(id:id,expected:expected,bytes:bytes);didReplace?(bytes)
        if fail && after {throw SyncCredentialStorageError.unavailable(-1)}
    }
    func remove(id:String,expected:Data)throws {try backend.remove(id:id,expected:expected)}
    func overwrite(_ id:String,bytes:Data) {let old=backend.values[id]!;try! backend.replace(id:id,expected:old,bytes:bytes)}
}
