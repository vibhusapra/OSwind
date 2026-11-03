import XCTest
@testable import OSwindCore

final class SyncMembershipRefreshTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_793_630_000)
    private func history(count:Int=5)throws->(SyncPendingJoin,[SyncGroupAuthority]) {
        let pending=try SyncPendingJoin(name:"Owned first Mac",now:now)
        var authorities=[try SyncGroupAuthority(owner:pending.request,now:now)]
        for index in 1..<count {
            let request=try SyncPendingJoin(name:String(repeating:"M",count:72)+String(index),now:now)
            authorities.append(try authorities.last!.admitting(request.request,now:now))
        }
        return (pending,authorities)
    }
    func testOfflineDeviceAdvancesSeveralSignedAdditionsWithoutChangingItsPrivateKeys()throws {
        let (pending,history)=try self.history(),first=history[0],last=history.last!
        let original=try pending.accept(first.response(to:pending.request,now:now),expectedRootFingerprint:first.fingerprint,now:now)
        XCTAssertThrowsError(try original.withCertificate(last.certificate),"A direct update cannot skip signed history")
        let refresh=try SyncMembershipRefresh(base:first.certificate,updates:history.dropFirst().map(\.certificate))
        let restored=try SyncMembershipRefresh.decode(refresh.encoded()),updated=try original.withMembershipRefresh(restored)
        XCTAssertEqual(updated.certificate,last.certificate);XCTAssertEqual(updated.replica,original.replica)
        let before=try JSONSerialization.jsonObject(with:SyncCredentialMaterial(joined:original).encodedForKeychain()) as! [String:Any]
        let after=try JSONSerialization.jsonObject(with:SyncCredentialMaterial(joined:updated).encodedForKeychain()) as! [String:Any]
        for key in ["replica","signingPrivate","agreementPrivate","groupSecret"] {let a=try XCTUnwrap(before[key] as? String),b=try XCTUnwrap(after[key] as? String);XCTAssertTrue(a==b,key)}
        let decoded=try SyncCredentialMaterial.decodeFromKeychain(SyncCredentialMaterial(joined:updated).encodedForKeychain())
        XCTAssertEqual(decoded.joined.certificate,last.certificate)
        let wire=String(decoding:try refresh.encoded(),as:UTF8.self)
        for key in ["signingPrivate","agreementPrivate","groupSecret","ownerPrivate"] {XCTAssertFalse(wire.contains(key))}
        XCTAssertEqual(String(reflecting:refresh),"<redacted membership refresh>")
    }
    func testExactOverlapAndRetryWorkButStalePagesCannotRollBack()throws {
        let (_,history)=try self.history(),refresh=try SyncMembershipRefresh(base:history[0].certificate,updates:Array(history[1...3]).map(\.certificate))
        for index in 0...3 {XCTAssertEqual(try refresh.advance(from:history[index].certificate),history[3].certificate)}
        XCTAssertThrowsError(try refresh.advance(from:history[4].certificate))
    }
    func testSignedForkUnknownRootGapReorderAndDuplicateRefuse()throws {
        let (_,history)=try self.history(),base=history[0],refresh=try SyncMembershipRefresh(base:base.certificate,updates:history.dropFirst().map(\.certificate))
        let other=try SyncPendingJoin(name:"Owned fork Mac",now:now),fork=try base.admitting(other.request,now:now)
        XCTAssertThrowsError(try refresh.advance(from:fork.certificate),"The same root and revision cannot authorize a different branch")
        let (_,unrelated)=try self.history(count:2)
        XCTAssertThrowsError(try refresh.advance(from:unrelated[0].certificate))
        for invalid in [[history[2].certificate],[history[1].certificate,history[3].certificate],[history[2].certificate,history[1].certificate],[history[1].certificate,history[1].certificate],[fork.certificate,history[2].certificate]] {
            XCTAssertThrowsError(try SyncMembershipRefresh(base:base.certificate,updates:invalid))
        }
        XCTAssertThrowsError(try SyncMembershipRefresh(base:base.certificate,updates:[]))
    }
    func testCanonicalBoundsFormatAndCertificateTamperingRefuse()throws {
        let (_,history)=try self.history(count:2),refresh=try SyncMembershipRefresh(base:history[0].certificate,updates:[history[1].certificate]),encoded=try refresh.encoded()
        XCTAssertThrowsError(try SyncMembershipRefresh.decode(Data(repeating:32,count:SyncMembershipRefresh.maximumBytes+1)))
        XCTAssertThrowsError(try SyncMembershipRefresh.decode(encoded+Data([32])))
        for field in ["format","version","unknown","signature"] {
            var object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
            switch field {
            case "format":object[field]="untrusted"
            case "version":object[field]=2
            case "unknown":object[field]=true
            default:
                var updates=object["updates"] as! [[String:Any]];updates[0]["signature"]=Data(repeating:0,count:64).base64EncodedString();object["updates"]=updates
            }
            let bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
            XCTAssertThrowsError(try SyncMembershipRefresh.decode(bytes),field)
        }
    }
    func testBoundedPagesReachAllSixtyFourMembersAndValidateTheUnsentTail()throws {
        let (_,history)=try self.history(count:64),certificates=history.map(\.certificate)
        XCTAssertThrowsError(try SyncMembershipRefresh(base:certificates[0],updates:Array(certificates.dropFirst())))
        var current=certificates[0],remaining=Array(certificates.dropFirst()),pages=0
        while !remaining.isEmpty {
            let page=try SyncMembershipRefresh.boundedPrefix(base:current,updates:remaining),bytes=try page.encoded()
            XCTAssertLessThanOrEqual(bytes.count,SyncMembershipRefresh.maximumBytes);XCTAssertGreaterThan(page.updateCount,0)
            current=try SyncMembershipRefresh.decode(bytes).advance(from:current);remaining.removeFirst(page.updateCount);pages+=1
            XCTAssertLessThanOrEqual(pages,63)
        }
        XCTAssertGreaterThan(pages,1);XCTAssertEqual(current,certificates.last);XCTAssertEqual(current.body.members.count,64)
        let forkRequest=try SyncPendingJoin(name:"Owned late fork",now:now),fork=try history[0].admitting(forkRequest.request,now:now)
        var corruptedTail=Array(certificates.dropFirst());corruptedTail[corruptedTail.count-1]=fork.certificate
        XCTAssertThrowsError(try SyncMembershipRefresh.boundedPrefix(base:certificates[0],updates:corruptedTail))
    }
}
