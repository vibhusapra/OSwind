import XCTest
import CryptoKit
@testable import OSwindCore

final class SyncPairingTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1793630000)
    func changed(_ data:Data,_ body:(inout [String:Any])throws->Void)throws->Data {
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);try body(&object)
        return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
    }
    func fixture()throws->(SyncPendingJoin,SyncGroupAuthority,SyncPendingJoin,SyncGroupAuthority) {
        let owner=try SyncPendingJoin(name:"Office Mac",now:now),authority=try SyncGroupAuthority(owner:owner.request,now:now)
        let join=try SyncPendingJoin(name:"Travel Mac",now:now),admitted=try authority.admitting(join.request,now:now)
        return (owner,authority,join,admitted)
    }
    func testPairingDeliversExactSignedMembershipOnlyToJoiningMac()throws {
        let (_,prior,join,admitted)=try fixture(),response=try admitted.response(to:join.request,now:now)
        let decoded=try SyncJoinRequest.decode(join.request.encoded(),now:now)
        XCTAssertEqual(decoded,join.request)
        let joined=try join.accept(response,expectedRootFingerprint:admitted.fingerprint,now:now)
        XCTAssertEqual(joined.replica,join.request.body.replica);XCTAssertEqual(joined.certificate,admitted.certificate)
        try joined.certificate.requireSuccessor(of:prior.certificate)
        XCTAssertEqual(joined.certificate.body.members.count,2);XCTAssertEqual(joined.certificate.body.revision,2)
        let wire=String(decoding:response,as:UTF8.self)
        XCTAssertFalse(wire.contains("Travel Mac"));XCTAssertFalse(wire.contains("groupSecret"));XCTAssertFalse(wire.contains(join.request.body.replica))
        XCTAssertNotEqual(try admitted.response(to:join.request,now:now),response,"Each response uses fresh agreement and AEAD nonce")
    }
    func testOwnerMustAdmitExactRequestBeforeProducingResponse()throws {
        let (_,prior,join,admitted)=try fixture()
        XCTAssertThrowsError(try prior.response(to:join.request,now:now))
        let idempotent=try admitted.admitting(join.request,now:now)
        XCTAssertEqual(idempotent.certificate,admitted.certificate)
        let other=try SyncPendingJoin(name:"Travel Mac",now:now)
        XCTAssertThrowsError(try admitted.response(to:other.request,now:now))
    }
    func testWrongFingerprintRecipientAndRequestCannotAcceptResponse()throws {
        let (_,_,join,authority)=try fixture(),response=try authority.response(to:join.request,now:now)
        XCTAssertThrowsError(try join.accept(response,expectedRootFingerprint:String(repeating:"0",count:64),now:now))
        let wrong=try SyncPendingJoin(name:"Travel Mac",now:now)
        XCTAssertThrowsError(try wrong.accept(response,expectedRootFingerprint:authority.fingerprint,now:now))
        XCTAssertThrowsError(try join.accept(response,expectedRootFingerprint:"",now:now))
    }
    func testRequestProofOfPossessionBindsIdentityNameKeysAndCapabilities()throws {
        let request=try SyncPendingJoin(name:"Owned Mac",now:now).request,encoded=try request.encoded()
        for field in ["replica","name","signingPublicKey","agreementPublicKey","capabilities","request","expires"] {
            let tampered=try changed(encoded) {object in
                var body=try XCTUnwrap(object["body"] as? [String:Any])
                switch field {
                case "replica","request":body[field]=UUID().uuidString.lowercased()
                case "name":body[field]="Changed Mac"
                case "signingPublicKey","agreementPublicKey":body[field]=Data(repeating:7,count:32).base64EncodedString()
                case "capabilities":body[field]=SyncServiceHead.supported
                default:body[field]=Int64(self.now.timeIntervalSince1970)+300
                };object["body"]=body
            }
            XCTAssertThrowsError(try SyncJoinRequest.decode(tampered,now:now),field)
        }
    }
    func testRequestExpiryFutureTimeAndUnsafeNamesAreRejected()throws {
        let join=try SyncPendingJoin(name:"Owned Mac",now:now),bytes=try join.request.encoded()
        _=try SyncJoinRequest.decode(bytes,now:now.addingTimeInterval(600))
        XCTAssertThrowsError(try SyncJoinRequest.decode(bytes,now:now.addingTimeInterval(601)))
        XCTAssertThrowsError(try SyncJoinRequest.decode(bytes,now:now.addingTimeInterval(-61)))
        XCTAssertThrowsError(try SyncGroupAuthority(owner:join.request,now:now.addingTimeInterval(601)))
        for name in [""," Mac","Mac ","Mac\nOwner","Mac\0Owner","Mac\u{202E}Owner",String(repeating:"a",count:81)] {
            XCTAssertThrowsError(try SyncPendingJoin(name:name,now:now))
        }
        XCTAssertThrowsError(try SyncPendingJoin(name:"Mac",now:Date(timeIntervalSince1970:.infinity)))
    }
    func testResponseExpiryCannotBeBypassedWithPreviouslyValidCiphertext()throws {
        let (_,_,join,authority)=try fixture(),response=try authority.response(to:join.request,now:now)
        XCTAssertThrowsError(try join.accept(response,expectedRootFingerprint:authority.fingerprint,now:now.addingTimeInterval(601)))
        XCTAssertThrowsError(try authority.response(to:join.request,now:now.addingTimeInterval(601)))
        XCTAssertThrowsError(try authority.admitting(join.request,now:now.addingTimeInterval(601)))
    }
    func testMembershipSignatureBindsRootGroupEpochOwnerHistoryAndDevices()throws {
        let (_,prior,_,authority)=try fixture(),encoded=try authority.certificate.encoded(),root=authority.certificate.body.rootPublicKey
        for field in ["group","epoch","owner","previous","revision","rootPublicKey","members","capabilities"] {
            let tampered=try changed(encoded) {object in
                var body=try XCTUnwrap(object["body"] as? [String:Any])
                switch field {
                case "group","epoch","owner":body[field]=UUID().uuidString.lowercased()
                case "previous":body[field]=String(repeating:"0",count:64)
                case "revision":body[field]=3
                case "rootPublicKey":body[field]=Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
                case "members":body[field]=Array((body[field] as! [[String:Any]]).dropLast())
                default:body[field]=SyncServiceHead.supported
                };object["body"]=body
            }
            XCTAssertThrowsError(try SyncMembershipCertificate.decode(tampered,root:root),field)
        }
        XCTAssertThrowsError(try authority.certificate.verify(root:Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertThrowsError(try prior.certificate.requireSuccessor(of:authority.certificate))
        XCTAssertThrowsError(try authority.certificate.requireSuccessor(of:authority.certificate))
    }
    func testMembershipRejectsAlternateHistoryAndSkippedRevisions()throws {
        let (owner,prior,join,authority)=try fixture(),other=try SyncGroupAuthority(owner:owner.request,now:now)
        XCTAssertThrowsError(try authority.certificate.requireSuccessor(of:other.certificate))
        let third=try SyncPendingJoin(name:"Studio Mac",now:now),next=try authority.admitting(third.request,now:now)
        try next.certificate.requireSuccessor(of:authority.certificate)
        XCTAssertThrowsError(try next.certificate.requireSuccessor(of:prior.certificate))
        let branch=try prior.admitting(third.request,now:now)
        XCTAssertThrowsError(try next.certificate.requireSuccessor(of:branch.certificate))
        let recovered=try join.accept(next.response(to:join.request,now:now),expectedRootFingerprint:prior.fingerprint,now:now)
        XCTAssertEqual(recovered.certificate.body.members.count,3)
    }
    func testResponseSignatureBindsCiphertextEphemeralKeyAndExactRequest()throws {
        let (_,_,join,authority)=try fixture(),response=try authority.response(to:join.request,now:now)
        for field in ["sealed","signature","ephemeralPublicKey","rootPublicKey","requestDigest","format","version"] {
            let tampered=try changed(response) {object in
                if field=="signature" {object[field]=Data(repeating:0,count:64).base64EncodedString();return}
                var body=try XCTUnwrap(object["body"] as? [String:Any])
                if field=="sealed" {
                    var sealed=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(body[field] as? String)));sealed[sealed.count-1] ^= 1;body[field]=sealed.base64EncodedString()
                }else {
                    var context=try XCTUnwrap(body["context"] as? [String:Any])
                    switch field {
                    case "ephemeralPublicKey":context[field]=Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
                    case "rootPublicKey":context[field]=Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
                    case "requestDigest":context[field]=String(repeating:"0",count:64)
                    case "format":context[field]="other"
                    default:context[field]=2
                    };body["context"]=context
                };object["body"]=body
            }
            XCTAssertThrowsError(try join.accept(tampered,expectedRootFingerprint:authority.fingerprint,now:now),field)
        }
    }
    func testCanonicalMessagesRejectUnknownFieldsWhitespaceTruncationAndOversize()throws {
        let (_,_,join,authority)=try fixture(),request=try join.request.encoded(),cert=try authority.certificate.encoded(),response=try authority.response(to:join.request,now:now)
        for bytes in [try changed(request){$0["extra"]="rejected"},request+Data([10]),request.dropLast(),Data(repeating:32,count:SyncPairingFormat.requestLimit+1)] {
            XCTAssertThrowsError(try SyncJoinRequest.decode(bytes,now:now))
        }
        for bytes in [try changed(cert){$0["extra"]="rejected"},cert+Data([10]),cert.dropLast(),Data(repeating:32,count:SyncPairingFormat.certificateLimit+1)] {
            XCTAssertThrowsError(try SyncMembershipCertificate.decode(bytes,root:authority.certificate.body.rootPublicKey))
        }
        for bytes in [try changed(response){$0["extra"]="rejected"},response+Data([10]),response.dropLast(),Data(repeating:32,count:SyncPairingFormat.responseLimit+1)] {
            XCTAssertThrowsError(try join.accept(bytes,expectedRootFingerprint:authority.fingerprint,now:now))
        }
    }
    func testMembershipBoundAndDistinctDeviceKeysHoldAtCapacity()throws {
        let owner=try SyncPendingJoin(name:"Owner",now:now)
        var authority=try SyncGroupAuthority(owner:owner.request,now:now)
        for index in 1..<SyncProtocolLimits.peers {
            authority=try authority.admitting(SyncPendingJoin(name:"Mac \(index)",now:now).request,now:now)
        }
        XCTAssertEqual(authority.certificate.body.members.count,64)
        XCTAssertLessThan(try authority.certificate.encoded().count,SyncPairingFormat.certificateLimit)
        XCTAssertThrowsError(try authority.admitting(SyncPendingJoin(name:"Overflow",now:now).request,now:now))
        let response=try authority.response(to:owner.request,now:now)
        XCTAssertLessThan(response.count,SyncPairingFormat.responseLimit)
        _=try owner.accept(response,expectedRootFingerprint:authority.fingerprint,now:now)
    }
    func testDistinctReplicaCannotReuseAnExistingDevicesPrivateKeys()throws {
        let keys=SyncDeviceKeys(),first=try SyncJoinRequest(keys:keys,name:"First identity",now:now),second=try SyncJoinRequest(keys:keys,name:"Cloned keys",now:now)
        let authority=try SyncGroupAuthority(owner:first,now:now)
        XCTAssertNotEqual(first.body.replica,second.body.replica)
        XCTAssertThrowsError(try authority.admitting(second,now:now))
    }
    func testPrivateAuthorityPendingAndJoinedValuesHaveRedactedDiagnostics()throws {
        let (_,_,join,authority)=try fixture(),joined=try join.accept(authority.response(to:join.request,now:now),expectedRootFingerprint:authority.fingerprint,now:now)
        for value:Any in [SyncDeviceKeys(),join,authority,joined,try joined.packetAuthority()] {
            let diagnostic=String(reflecting:value)
            XCTAssertTrue(diagnostic.contains("redacted"));XCTAssertFalse(diagnostic.contains("Travel Mac"))
            for child in Mirror(reflecting:value).children {XCTAssertEqual(child.value as? String,"redacted")}
        }
    }
}
