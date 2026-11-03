import XCTest
@testable import OSwindCore

final class SyncOwnerApprovalTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    let account="11111111-1111-4111-8111-111111111111",lifetime="22222222-2222-4222-8222-222222222222"
    func fixture()throws->(SyncGroupAuthority,SyncGroupAuthority,SyncPendingJoin,SyncOwnerApprovalPlan) {
        let first=try SyncPendingJoin(name:"Desk Mac",now:now),owner=try SyncGroupAuthority(owner:first.request,now:now)
        let joiner=try SyncPendingJoin(name:"Travel Mac",now:now),next=try owner.admitting(joiner.request,now:now)
        return (owner,next,joiner,try next.approvalPlan(to:joiner.request,prior:owner.certificate,pairingID:account,lifetime:lifetime,now:now))
    }
    func testSignedPlanRoundTripAndExactRecipientAcceptance()throws {
        let (_,next,joiner,plan)=try fixture(),bytes=try plan.encoded(),saved=try SyncOwnerApprovalPlan.decode(bytes),reference=try plan.reference()
        XCTAssertEqual(saved,plan);XCTAssertTrue(reference.content.matches(bytes));XCTAssertEqual(plan.binding.purpose,.addition)
        try saved.require(reference,current:next.certificate,pairingID:account,lifetime:lifetime)
        let accepted=try joiner.accept(saved.response,expectedRootFingerprint:next.fingerprint,now:now)
        XCTAssertEqual(accepted.certificate,next.certificate)
    }
    func testRecoveryRetainsOriginalTimeAndDoesNotExtendJoinerExpiry()throws {
        let (owner,next,joiner,plan)=try fixture(),later=now.addingTimeInterval(701)
        XCTAssertEqual(try SyncOwnerApprovalPlan.decode(plan.encoded()).response,plan.response)
        XCTAssertEqual(plan.binding.approvedAt,Int64(now.timeIntervalSince1970))
        XCTAssertThrowsError(try joiner.accept(plan.response,expectedRootFingerprint:next.fingerprint,now:later))
        XCTAssertThrowsError(try next.approvalPlan(to:joiner.request,prior:owner.certificate,pairingID:account,lifetime:lifetime,now:later))
    }
    func testReferenceAccountLifetimeRootAndContentSwapsRefuse()throws {
        let (_,next,_,plan)=try fixture(),reference=try plan.reference()
        XCTAssertThrowsError(try plan.require(reference,current:next.certificate,pairingID:lifetime,lifetime:lifetime))
        XCTAssertThrowsError(try plan.require(reference,current:next.certificate,pairingID:account,lifetime:account))
        let alien=try SyncGroupAuthority(owner:SyncPendingJoin(name:"Other",now:now).request,now:now)
        XCTAssertThrowsError(try plan.require(reference,current:alien.certificate,pairingID:account,lifetime:lifetime))
        let bad=SyncOwnerApprovalReference(content:try .init(data:Data("swapped".utf8)),requestDigest:reference.requestDigest,head:reference.head,pairingID:account,lifetime:lifetime,approvedAt:reference.approvedAt)
        XCTAssertThrowsError(try plan.require(bad,current:next.certificate,pairingID:account,lifetime:lifetime))
    }
    func testTamperedRequestCiphertextCertificateAndAttestationRefuse()throws {
        let (_,_,_,plan)=try fixture(),bytes=try plan.encoded()
        for key in ["request","prior","certificate","response","binding","signature"] {
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
            switch key {
            case "response","signature":object[key]=Data(repeating:0,count:64).base64EncodedString()
            case "binding":var value=object[key] as! [String:Any];value["approvedAt"]=Int64(now.timeIntervalSince1970)+1000;object[key]=value
            default:
                var value=object[key] as! [String:Any];value["signature"]=Data(repeating:0,count:64).base64EncodedString();object[key]=value
            }
            let bad=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
            XCTAssertThrowsError(try SyncOwnerApprovalPlan.decode(bad),key)
        }
    }
    func testUnknownFieldsAndOversizeCanonicalEnvelopeRefuse()throws {
        let (_,_,_,plan)=try fixture(),bytes=try plan.encoded()
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any]);object["unexpected"]=true
        XCTAssertThrowsError(try SyncOwnerApprovalPlan.decode(JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])))
        XCTAssertThrowsError(try SyncOwnerApprovalPlan.decode(bytes+Data(" ".utf8)))
        XCTAssertThrowsError(try SyncOwnerApprovalPlan.decode(Data(repeating:32,count:Int(SyncOwnerApprovalPlan.maximumBytes)+1)))
        let ref=try plan.reference(),oversize=SyncOwnerApprovalReference(content:try .init(sha256:ref.content.sha256,bytes:SyncOwnerApprovalPlan.maximumBytes+1),requestDigest:ref.requestDigest,head:ref.head,pairingID:account,lifetime:lifetime,approvedAt:ref.approvedAt)
        XCTAssertThrowsError(try oversize.validate())
    }
    func testLegacyReissueHasExplicitPurposeAndIdenticalMembership()throws {
        let (_,next,joiner,_)=try fixture(),plan=try next.approvalPlan(to:joiner.request,prior:next.certificate,pairingID:account,lifetime:lifetime,now:now)
        XCTAssertEqual(plan.binding.purpose,.legacyReissue);XCTAssertEqual(plan.prior,plan.certificate)
        XCTAssertEqual(try joiner.accept(plan.response,expectedRootFingerprint:next.fingerprint,now:now).certificate,next.certificate)
    }
    func testAdditionCannotReturnAnAlreadyAdmittedRequestWhileAddingAnotherDevice()throws {
        let first=try SyncPendingJoin(name:"Desk Mac",now:now),owner=try SyncGroupAuthority(owner:first.request,now:now)
        let newDevice=try SyncPendingJoin(name:"Travel Mac",now:now),next=try owner.admitting(newDevice.request,now:now)
        XCTAssertThrowsError(try next.approvalPlan(to:first.request,prior:owner.certificate,pairingID:account,lifetime:lifetime,now:now))
        let legacy=try owner.approvalPlan(to:first.request,prior:owner.certificate,pairingID:account,lifetime:lifetime,now:now)
        XCTAssertEqual(legacy.binding.purpose,.legacyReissue)
        XCTAssertEqual(try first.accept(legacy.response,expectedRootFingerprint:owner.fingerprint,now:now).certificate,owner.certificate)
    }
    func testLargestMembershipPlanFitsBoundAndResponseAccepts()throws {
        let first=try SyncPendingJoin(name:"Owner",now:now);var owner=try SyncGroupAuthority(owner:first.request,now:now)
        for index in 1..<(SyncProtocolLimits.peers-1) {owner=try owner.admitting(SyncPendingJoin(name:"Mac \(index)",now:now).request,now:now)}
        let joiner=try SyncPendingJoin(name:String(repeating:"X",count:80),now:now),next=try owner.admitting(joiner.request,now:now),plan=try next.approvalPlan(to:joiner.request,prior:owner.certificate,pairingID:account,lifetime:lifetime,now:now)
        let bytes=try plan.encoded();XCTAssertEqual(next.certificate.body.members.count,64);XCTAssertLessThanOrEqual(bytes.count,Int(SyncOwnerApprovalPlan.maximumBytes));print("OWNED_APPROVAL_MAXIMUM members=64 bytes=\(bytes.count) limit=\(SyncOwnerApprovalPlan.maximumBytes)")
        XCTAssertEqual(try joiner.accept(plan.response,expectedRootFingerprint:next.fingerprint,now:now).certificate,next.certificate)
    }
}
