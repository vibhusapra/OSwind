import XCTest
@testable import OSwindCore

final class SyncCredentialMaterialTests:XCTestCase {
    func fixture()throws->(SyncCredentialMaterial,SyncCredentialMaterial) {
        let first=try SyncPendingJoin(name:"Owned persistent sender"),second=try SyncPendingJoin(name:"Owned persistent receiver")
        let owner=try SyncGroupAuthority(owner:first.request).admitting(second.request)
        let a=try first.accept(owner.response(to:first.request),expectedRootFingerprint:owner.fingerprint)
        let b=try second.accept(owner.response(to:second.request),expectedRootFingerprint:owner.fingerprint)
        return (try .init(joined:a,owner:owner),try .init(joined:b))
    }
    func changed(_ bytes:Data,_ change:(inout [String:Any])throws->Void)throws->Data {
        var value=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any]);try change(&value)
        return try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])
    }
    func testReloadedKeysReadExistingEncryptedSpaceAndAuthenticateOriginalDevice()throws {
        let (a,b)=try fixture(),restoredA=try SyncCredentialMaterial.decodeFromKeychain(a.encodedForKeychain()),restoredB=try SyncCredentialMaterial.decodeFromKeychain(b.encodedForKeychain())
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-sync-key-material-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let original=try a.joined.createTransport(at:root);defer {original.close()}
        let reopened=try restoredB.joined.openTransport(at:root);defer {reopened.close()}
        let bytes=Data("Owned persisted original body".utf8),reference=try SyncContentReference(data:bytes)
        let operation=try SyncRevision(key:.make(kind:.source,identity:Data("owned-persisted".utf8)),dot:.init(replica:a.joined.replica,counter:1),context:.empty,mutation:.put,content:reference)
        try original.publishContent(bytes,reference:reference);try original.publishRevision(operation)
        XCTAssertEqual(try reopened.revision(replica:a.joined.replica,sequence:1),operation);XCTAssertEqual(try reopened.content(reference),bytes)
        let descriptor=Data("owned persisted packet".utf8),packet=try restoredA.joined.packetAuthority().seal(bytes,purpose:.operation,descriptor:descriptor,replica:a.joined.replica)
        XCTAssertEqual(try b.joined.packetAuthority().open(packet,purpose:.operation,descriptor:descriptor,replica:a.joined.replica),bytes)
        XCTAssertEqual(restoredA.joined.certificate,a.joined.certificate);XCTAssertNil(restoredB.owner)
    }
    func testReloadedOwnerCanAdmitAndSealResponseUnderOriginalRoot()throws {
        let (a,_)=try fixture(),restored=try SyncCredentialMaterial.decodeFromKeychain(a.encodedForKeychain()),owner=try XCTUnwrap(restored.owner)
        let next=try SyncPendingJoin(name:"Owned third device"),updated=try owner.admitting(next.request)
        try updated.certificate.requireSuccessor(of:a.joined.certificate)
        let joined=try next.accept(updated.response(to:next.request),expectedRootFingerprint:owner.fingerprint)
        XCTAssertEqual(joined.certificate.body.group,a.joined.certificate.body.group);XCTAssertEqual(joined.certificate.body.members.count,3)
        XCTAssertEqual(try owner.fingerprint,try XCTUnwrap(a.owner).fingerprint)
    }
    func testAnotherMemberCannotPersistOwnerAuthority()throws {
        let (a,b)=try fixture()
        XCTAssertThrowsError(try SyncCredentialMaterial(joined:b.joined,owner:XCTUnwrap(a.owner)))
    }
    func testMalformedSavedKeysNeverYieldAnAuthorityOrExposeSecretInError()throws {
        let (a,_)=try fixture(),bytes=try a.encodedForKeychain()
        for field in ["signingPrivate","agreementPrivate","groupSecret","ownerPrivate","replica","format","version"] {
            let bad=try changed(bytes) {value in
                switch field {
                case "replica":value[field]=UUID().uuidString.lowercased()
                case "format":value[field]="secret-marker-do-not-echo"
                case "version":value[field]=2
                case "ownerPrivate":value[field]=Data(repeating:5,count:32).base64EncodedString()
                default:value[field]=Data(repeating:8,count:31).base64EncodedString()
                }
            }
            do {_=try SyncCredentialMaterial.decodeFromKeychain(bad);XCTFail("Accepted invalid saved material: \(field)")}
            catch {XCTAssertFalse(error.localizedDescription.contains("secret-marker"))}
        }
        let mismatched=try changed(bytes) {$0["signingPrivate"]=Data(repeating:2,count:32).base64EncodedString()}
        XCTAssertThrowsError(try SyncCredentialMaterial.decodeFromKeychain(mismatched))
    }
    func testCanonicalBoundAndDiagnosticRedactionApplyToPrivateMaterial()throws {
        let (a,b)=try fixture(),bytes=try a.encodedForKeychain()
        XCTAssertThrowsError(try SyncCredentialMaterial.decodeFromKeychain(bytes+Data([10])))
        XCTAssertThrowsError(try SyncCredentialMaterial.decodeFromKeychain(changed(bytes){$0["unknown"]="refused"}))
        XCTAssertThrowsError(try SyncCredentialMaterial.decodeFromKeychain(Data(repeating:32,count:SyncCredentialStorageLimits.maximumBytes+1)))
        XCTAssertThrowsError(try SyncCredentialMaterial.decodeFromKeychain(Data()))
        for material in [a,b] {
            XCTAssertTrue(String(reflecting:material).contains("redacted"))
            for child in Mirror(reflecting:material).children {XCTAssertEqual(child.value as? String,"redacted")}
        }
    }
}
