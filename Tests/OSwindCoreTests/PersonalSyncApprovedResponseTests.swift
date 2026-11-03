import XCTest
@testable import OSwindCore

final class PersonalSyncApprovedResponseTests:XCTestCase {
    var root:URL!,a:MemoryStore!,b:MemoryStore!
    private var storage:ApprovalSaveStorage!
    var owners=[PersonalSyncPairing]()
    let now=Date(timeIntervalSince1970:1_800_000_000)
    let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"a",count:64))
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-approval-response-"+UUID().uuidString)
        a=try MemoryStore(root:root.appendingPathComponent("a"));b=try MemoryStore(root:root.appendingPathComponent("b"));storage=ApprovalSaveStorage()
    }
    override func tearDownWithError()throws {owners.forEach {$0.close()};try a.close();try b.close();try FileManager.default.removeItem(at:root)}
    func open(_ store:MemoryStore)throws->PersonalSyncPairing {
        let owner=try PersonalSyncPairing(store:store,stateRoot:root.appendingPathComponent("state"),machine:machine,storage:storage);owners.append(owner);return owner
    }
    func fixture()throws->(PersonalSyncPairing,PersonalSyncPairing,PersonalSyncPairingReview) {
        let owner=try open(a),joiner=try open(b);_=try owner.createGroup(deviceName:"Desk Mac",now:now)
        let text=try XCTUnwrap(joiner.requestJoin(deviceName:"Travel Mac",now:now).request)
        return (owner,joiner,try owner.reviewRequest(text,now:now))
    }
    func ownerEnvelope()throws->(String,Data,[String:Any]) {
        for (id,bytes) in storage.backend.values {
            let object=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            if let encoded=object["material"] as? String,let raw=Data(base64Encoded:encoded),try SyncCredentialMaterial.decodeFromKeychain(raw).owner != nil {return (id,bytes,object)}
        }
        throw OSwindError.unavailable("Missing owned fixture owner")
    }
    func inboxPath()throws->URL {
        let (_,_,object)=try ownerEnvelope(),raw=try XCTUnwrap(Data(base64Encoded:object["material"] as! String))
        return a.root.appendingPathComponent("images/device-sync-"+(try SyncCredentialMaterial.decodeFromKeychain(raw).joined.replica))
    }
    func testApprovalAndReceiptCommitTogetherAndRestartReturnsExactCiphertext()throws {
        let (owner,joiner,review)=try fixture(),response=try owner.approve(review,now:now),accounts=Set(storage.backend.values.keys),saved=storage.backend.values
        XCTAssertTrue(try owner.status().lastResponseAvailable);XCTAssertNil(try joiner.lastApprovedResponse())
        XCTAssertEqual(try owner.approve(review,now:now),response);XCTAssertTrue(storage.backend.values==saved,"Original private accounts changed")
        owner.close();let reopened=try open(a),recovered=try XCTUnwrap(reopened.lastApprovedResponse())
        XCTAssertEqual(recovered.response,response);XCTAssertEqual(recovered.deviceName,"Travel Mac");XCTAssertEqual(recovered.requestFingerprint,review.requestFingerprint)
        XCTAssertEqual(recovered.approvedAt,now);XCTAssertEqual(recovered.expires,review.expires)
        XCTAssertEqual(Set(storage.backend.values.keys),accounts);XCTAssertTrue(storage.backend.values==saved,"Original private accounts changed")
        _=try joiner.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(reopened.status().rootFingerprint),now:now)
        let (_,raw,object)=try ownerEnvelope();XCTAssertLessThanOrEqual(raw.count,SyncCredentialStorageLimits.maximumBytes)
        XCTAssertNotNil(object["initialApproval"]);XCTAssertNil(object["response"])
    }
    func testFailedPrivateSaveDoesNotAdmitAndAmbiguousSavedSuccessRecoversExactResponse()throws {
        let (owner,joiner,review)=try fixture(),before=storage.backend.values
        storage.failBefore=true;XCTAssertThrowsError(try owner.approve(review,now:now));XCTAssertTrue(storage.backend.values==before,"Original private accounts changed")
        XCTAssertEqual(try owner.status().memberNames.count,1);XCTAssertNil(try owner.lastApprovedResponse())
        storage.failBefore=false;storage.failAfter=true
        XCTAssertThrowsError(try owner.approve(review,now:now));XCTAssertEqual(try owner.status().memberNames.count,2)
        let persisted=try XCTUnwrap(owner.lastApprovedResponse()).response,after=storage.backend.values
        owner.close();storage.failAfter=false;let reopened=try open(a)
        XCTAssertEqual(try reopened.lastApprovedResponse()?.response,persisted);XCTAssertEqual(try reopened.approve(review,now:now),persisted)
        XCTAssertTrue(storage.backend.values==after,"Committed private accounts changed")
        _=try joiner.acceptResponse(persisted,trustedRootFingerprint:XCTUnwrap(reopened.status().rootFingerprint),now:now)
    }
    func testExpiredRecoveryIsExactButNeitherNewApprovalNorJoinerAcceptanceExtendsExpiry()throws {
        let (owner,joiner,review)=try fixture(),response=try owner.approve(review,now:now),later=now.addingTimeInterval(701)
        owner.close();let reopened=try open(a)
        XCTAssertEqual(try reopened.lastApprovedResponse()?.response,response)
        XCTAssertThrowsError(try reopened.approve(review,now:later))
        XCTAssertThrowsError(try joiner.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(reopened.status().rootFingerprint),now:later))
        XCTAssertEqual(try reopened.lastApprovedResponse()?.expires,review.expires)
    }
    func testMissingOrCorruptSavedPlanRefusesWithoutReplacementOrNewAccounts()throws {
        let (owner,_,review)=try fixture();_=try owner.approve(review,now:now)
        let before=storage.backend.values,path=try inboxPath(),objects=path.appendingPathComponent("objects")
        let files=FileManager.default.enumerator(at:objects,includingPropertiesForKeys:[.isRegularFileKey])!.allObjects.compactMap {$0 as? URL}
        let file=try XCTUnwrap(files.first {((try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true)})
        try Data("corrupt-owned-ciphertext".utf8).write(to:file)
        XCTAssertThrowsError(try owner.lastApprovedResponse());XCTAssertThrowsError(try owner.approve(review,now:now));XCTAssertTrue(storage.backend.values==before,"Original private accounts changed")
        try FileManager.default.removeItem(at:path)
        XCTAssertThrowsError(try owner.lastApprovedResponse());XCTAssertThrowsError(try owner.approve(review,now:now));XCTAssertTrue(storage.backend.values==before,"Original private accounts changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
    }
    func testFailedEncryptedPlanWriteLeavesMembershipAndPrivateAccountUnchanged()throws {
        let (owner,_,review)=try fixture(),before=storage.backend.values,path=try inboxPath()
        try Data("owned-file-blocks-inbox-directory".utf8).write(to:path)
        XCTAssertThrowsError(try owner.approve(review,now:now));XCTAssertTrue(storage.backend.values==before,"Original private accounts changed")
        XCTAssertEqual(try owner.status().memberNames.count,1);XCTAssertNil(try owner.lastApprovedResponse())
    }
    func testExpiryIsCheckedAgainAtActualPrivateReplacementBoundary()throws {
        let (owner,_,review)=try fixture(),before=storage.backend.values
        var observations=0
        XCTAssertThrowsError(try owner.approve(review,clock:{
            observations+=1;return observations==1 ? self.now:self.now.addingTimeInterval(701)
        }))
        XCTAssertGreaterThanOrEqual(observations,2)
        XCTAssertTrue(storage.backend.values==before,"Expired approval advanced private membership")
        XCTAssertEqual(try owner.status().memberNames.count,1);XCTAssertNil(try owner.lastApprovedResponse())
    }
    func testReviewCannotSilentlyApproveAfterAnotherDeviceChangesOwnerState()throws {
        let (owner,_,review)=try fixture(),third=try MemoryStore(root:root.appendingPathComponent("c"));defer {try? third.close()}
        let other=try open(third),request=try XCTUnwrap(other.requestJoin(deviceName:"Other Mac",now:now).request)
        _=try owner.approve(owner.reviewRequest(request,now:now),now:now)
        let before=storage.backend.values
        XCTAssertThrowsError(try owner.approve(review,now:now));XCTAssertTrue(storage.backend.values==before,"Original private accounts changed")
        XCTAssertEqual(Set(try owner.status().memberNames),["Desk Mac","Other Mac"])
        other.close()
    }
    func testLegacyAlreadyAdmittedResponseReissueIsExplicitAndDoesNotAddMember()throws {
        let (owner,joiner,review)=try fixture();_=try owner.approve(review,now:now)
        let originalRequest=try XCTUnwrap(joiner.status().request)
        let (id,bytes,object)=try ownerEnvelope();var legacy=object;legacy.removeValue(forKey:"initialApproval")
        try storage.backend.replace(id:id,expected:bytes,bytes:JSONSerialization.data(withJSONObject:legacy,options:[.sortedKeys,.withoutEscapingSlashes]))
        owner.close();let reopened=try open(a)
        XCTAssertFalse(try reopened.status().lastResponseAvailable);XCTAssertNil(try reopened.lastApprovedResponse())
        let reissuedReview=try reopened.reviewRequest(originalRequest,now:now)
        XCTAssertTrue(reissuedReview.alreadyAdmitted)
        let response=try reopened.approve(reissuedReview,now:now)
        XCTAssertEqual(try reopened.status().memberNames.count,2);XCTAssertEqual(try reopened.lastApprovedResponse()?.response,response)
    }
    func testDeliveryReservationPreservesExactResponseWithoutAvailableProvider()throws {
        let (owner,joiner,review)=try fixture(),response=try owner.approve(review,now:now)
        _=try joiner.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(owner.status().rootFingerprint),now:now)
        let shared=root.appendingPathComponent("shared"),service=try owner.prepareAnchoredService(shared:shared,createShared:true)
        try service.stop();service.inbox.close();service.transport.close();try FileManager.default.moveItem(at:shared,to:root.appendingPathComponent("offline-provider"))
        let before=storage.backend.values
        XCTAssertTrue(try owner.status().deliveryPrepared);XCTAssertEqual(try owner.lastApprovedResponse()?.response,response)
        XCTAssertThrowsError(try owner.approve(review,now:now));XCTAssertTrue(storage.backend.values==before,"Original private accounts changed")
    }
    func testRetirementClearsReceiptAndDoesNotRecreateIdentity()throws {
        let (owner,_,review)=try fixture();_=try owner.approve(review,now:now)
        XCTAssertEqual(try owner.retire().phase,.retired);XCTAssertNil(try owner.lastApprovedResponse())
        let (_,_,object)=try ownerEnvelopeForRetired();XCTAssertNil(object["initialApproval"])
    }
    func testExactInitialResponseSurvivesInternalNativeMembershipHandover()throws {
        let (owner,joiner,review)=try fixture(),response=try owner.approve(review,now:now)
        _=try joiner.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(owner.status().rootFingerprint),now:now)
        let (_,_,before)=try ownerEnvelope(),raw=try XCTUnwrap(Data(base64Encoded:before["material"] as! String)),material=try SyncCredentialMaterial.decodeFromKeychain(raw)
        let authority=try XCTUnwrap(material.owner),pending=try SyncPendingJoin(name:"Internal later peer",now:now),next=try authority.admitting(pending.request,now:now)
        let proof=try SyncMembershipRefresh(base:authority.certificate,updates:[next.certificate])
        let service=try owner.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:true)
        defer {try? service.stop();service.inbox.close();service.transport.close()}
        try service.installNativeWriterAdmission();try a.insert(Memory(id:"canary",text:"Owned response handover evidence"))
        try service.stop();service.inbox.close();service.transport.close();owner.close()
        let backend=storage!,environment=SyncNativeWriterEnvironment(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{_ in backend})
        let operation=try SyncMembershipPreparationOwner.prepare(library:a,proof:proof,environment:environment);defer {try? operation.close()}
        try operation.applyMembership();try operation.close()
        a=try MemoryStore(root:a.root,recoveryReadOnly:false,nativeWriterEnvironment:environment)
        let reopened=try open(a),recovered=try XCTUnwrap(reopened.lastApprovedResponse())
        XCTAssertEqual(recovered.response,response);XCTAssertEqual(recovered.requestFingerprint,review.requestFingerprint)
        XCTAssertEqual(try reopened.status().memberNames.count,3);XCTAssertNotNil(try a.get("canary"))
        let (_,_,after)=try ownerEnvelope(),oldKeys=try JSONSerialization.jsonObject(with:raw) as! [String:Any],newRaw=try XCTUnwrap(Data(base64Encoded:after["material"] as! String)),newKeys=try JSONSerialization.jsonObject(with:newRaw) as! [String:Any]
        for key in ["signingPrivate","agreementPrivate","groupSecret","ownerPrivate"] {XCTAssertTrue((oldKeys[key] as? String)==(newKeys[key] as? String),"Handover changed original private keys")}
        XCTAssertEqual(Set(storage.backend.values.keys).count,3)
    }
    private func ownerEnvelopeForRetired()throws->(String,Data,[String:Any]) {
        for (id,bytes) in storage.backend.values {let object=try JSONSerialization.jsonObject(with:bytes) as! [String:Any];if object["retired"] as? Bool==true {return(id,bytes,object)}}
        throw OSwindError.unavailable("Missing owned retirement fixture")
    }
}

private final class ApprovalSaveStorage:SyncCredentialStorage,@unchecked Sendable {
    let backend=PairingTestStorage(),protection:SyncCredentialProtection = .loginKeychain
    var failBefore=false,failAfter=false
    func create(id:String,bytes:Data)throws {try backend.create(id:id,bytes:bytes)}
    func read(id:String)throws->Data {try backend.read(id:id)}
    func replace(id:String,expected:Data,bytes:Data)throws {
        if failBefore {throw SyncCredentialStorageError.unavailable(-99)}
        try backend.replace(id:id,expected:expected,bytes:bytes)
        if failAfter {throw SyncCredentialStorageError.unavailable(-98)}
    }
    func remove(id:String,expected:Data)throws {try backend.remove(id:id,expected:expected)}
}
