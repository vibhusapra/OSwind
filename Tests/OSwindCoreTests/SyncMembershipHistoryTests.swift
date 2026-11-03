import XCTest
import CSQLite
@testable import OSwindCore

final class SyncMembershipHistoryTests:XCTestCase {
    private var root:URL!,stores=[MemoryStore](),owners=[PersonalSyncPairing](),storage=PairingTestStorage()
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    private let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"a",count:64))
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-membership-history-"+UUID().uuidString)}
    override func tearDownWithError()throws {owners.forEach {$0.close()};try stores.forEach {try $0.close()};try FileManager.default.removeItem(at:root)}
    private func pairer(_ name:String)throws->(MemoryStore,PersonalSyncPairing) {
        let store=try MemoryStore(root:root.appendingPathComponent(name));stores.append(store)
        return (store,try open(store))
    }
    private func open(_ store:MemoryStore)throws->PersonalSyncPairing {
        let owner=try PersonalSyncPairing(store:store,stateRoot:root.appendingPathComponent("state"),machine:machine,storage:storage);owners.append(owner);return owner
    }
    private func join(_ peer:PersonalSyncPairing,to owner:PersonalSyncPairing,name:String)throws->SyncMembershipCertificate {
        let request=try XCTUnwrap(peer.requestJoin(deviceName:name,now:now).request),response=try owner.approve(owner.reviewRequest(request,now:now),now:now)
        _=try peer.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(owner.status().rootFingerprint),now:now)
        return try peer.membershipCertificateForRefresh()
    }
    private func four()throws->(MemoryStore,PersonalSyncPairing,PersonalSyncPairing,SyncMembershipCertificate,SyncMembershipCertificate) {
        let (store,owner)=try pairer("owner");_=try owner.createGroup(deviceName:"Desk",now:now)
        let (_,peer)=try pairer("peer"),two=try join(peer,to:owner,name:"Travel")
        let (_,third)=try pairer("third"),three=try join(third,to:owner,name:"Third")
        let (_,fourth)=try pairer("fourth");_=try join(fourth,to:owner,name:"Fourth")
        return (store,owner,peer,two,three)
    }
    private func key(_ certificate:SyncMembershipCertificate)throws->String {
        SyncMembershipHistory.prefix+certificate.body.group+":"+certificate.body.epoch+":"+SyncProtocolLimits.hex(try certificate.encoded())
    }
    private func put(_ store:MemoryStore,key:String,value:String)throws {
        try store.withRoutineDatabase {db in let row=try db.statement("INSERT OR REPLACE INTO store_metadata(key,value) VALUES(?,?)");defer {sqlite3_finalize(row)};db.bind(row,1,key);db.bind(row,2,value);try db.done(row)}
    }
    func testActualPairingPersistsSeveralAdditionsAndExportsReadOnlyAfterRestart()throws {
        let (store,owner,peer,two,three)=try four();owner.close();let resumed=try open(store),head=try resumed.membershipCertificateForRefresh(),saved=storage.values
        let before=try store.withRoutineDatabase {sqlite3_total_changes64($0.handle)}
        let page=try XCTUnwrap(resumed.membershipRefresh(after:two));XCTAssertEqual(page.updateCount,2);XCTAssertEqual(try page.advance(from:two),head)
        XCTAssertEqual(try resumed.membershipRefresh(after:three)?.updateCount,1)
        XCTAssertNil(try resumed.membershipRefresh(after:head));XCTAssertEqual(try peer.membershipCertificateForRefresh(),two)
        XCTAssertEqual(try store.withRoutineDatabase {sqlite3_total_changes64($0.handle)},before)
        XCTAssertTrue(storage.values==saved,"Exporting public history changed private credentials")
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT enabled FROM personal_sync_capture")},0)
    }
    func testNativeHistoryWriteFailureCannotAdvancePrivateApproval()throws {
        let (store,owner)=try pairer("owner");_=try owner.createGroup(deviceName:"Desk",now:now)
        let (_,peer)=try pairer("peer"),request=try XCTUnwrap(peer.requestJoin(deviceName:"Travel",now:now).request),review=try owner.reviewRequest(request,now:now),before=storage.values
        try store.withRoutineDatabase {try $0.execute("CREATE TRIGGER owned_history_failure BEFORE INSERT ON store_metadata WHEN new.key LIKE 'sync-membership-certificate-v1:%' BEGIN SELECT RAISE(ABORT,'owned history fault'); END")}
        XCTAssertThrowsError(try owner.approve(review,now:now));XCTAssertTrue(storage.values==before)
        XCTAssertEqual(try owner.status().memberNames,["Desk"])
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_history_failure")}
        let response=try owner.approve(review,now:now);_=try peer.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(owner.status().rootFingerprint),now:now)
        XCTAssertEqual(try owner.status().memberNames.count,2)
    }
    func testHistoryFailureRollsBackInitialReservationAndLeavesJoinResponseRetryable()throws {
        let (store,initial)=try pairer("owner");var owner=initial
        let fault="CREATE TRIGGER owned_history_failure BEFORE INSERT ON store_metadata WHEN new.key LIKE 'sync-membership-certificate-v1:%' BEGIN SELECT RAISE(ABORT,'owned history fault'); END"
        try store.withRoutineDatabase {try $0.execute(fault)}
        XCTAssertThrowsError(try owner.createGroup(deviceName:"Desk",now:now))
        XCTAssertTrue(storage.values.isEmpty)
        XCTAssertThrowsError(try owner.status())
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key IN ('sync-pairing-library-lifetime-v1','sync-pairing-handle-v1')")},0)
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_history_failure")}
        owner.close();owner=try open(store);XCTAssertEqual(try owner.status().phase,.unconfigured)
        _=try owner.createGroup(deviceName:"Desk",now:now)
        let (peerStore,peer)=try pairer("peer"),request=try XCTUnwrap(peer.requestJoin(deviceName:"Travel",now:now).request)
        let response=try owner.approve(owner.reviewRequest(request,now:now),now:now),fingerprint=try XCTUnwrap(owner.status().rootFingerprint),before=storage.values
        try peerStore.withRoutineDatabase {try $0.execute(fault)}
        XCTAssertThrowsError(try peer.acceptResponse(response,trustedRootFingerprint:fingerprint,now:now))
        XCTAssertTrue(storage.values==before);XCTAssertEqual(try peer.status().request,request)
        XCTAssertThrowsError(try peer.membershipCertificateForRefresh())
        try peerStore.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_history_failure")}
        _=try peer.acceptResponse(response,trustedRootFingerprint:fingerprint,now:now)
        XCTAssertEqual(try peer.membershipCertificateForRefresh(),try owner.membershipCertificateForRefresh())
    }
    func testSavedHistoryRejectsBlobNoncanonicalAndOverBudgetCacheWithoutChangingPrivateHead()throws {
        let (store,owner,_,two,three)=try four(),address=try key(three),head=try owner.membershipCertificateForRefresh(),before=storage.values
        try store.withRoutineDatabase {db in
            let row=try db.statement("UPDATE store_metadata SET value=CAST(value AS BLOB) WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,address);try db.done(row)
        }
        XCTAssertThrowsError(try owner.membershipRefresh(after:two))
        let noncanonical=try three.encoded()+Data(" ".utf8)
        try put(store,key:address,value:noncanonical.base64EncodedString());XCTAssertThrowsError(try owner.membershipRefresh(after:two))
        try put(store,key:address,value:three.encoded().base64EncodedString())
        let namespace=String(address.dropLast(64))
        try store.withRoutineDatabase {db in
            try SyncChangeCapture.transaction(db) {
                let row=try db.statement("INSERT OR IGNORE INTO store_metadata(key,value) VALUES(?,?)");defer {sqlite3_finalize(row)}
                for index in 0...SyncMembershipHistory.maximumRecords {
                    sqlite3_reset(row);sqlite3_clear_bindings(row);db.bind(row,1,namespace+String(format:"%064x",index));db.bind(row,2,"ignored orphan body");try db.done(row)
                }
            }
            XCTAssertThrowsError(try SyncChangeCapture.transaction(db) {try SyncMembershipHistory.retain([head],anchoredHead:head,db:db)})
        }
        // A read follows at most the named ancestry; unrelated SQL rows cannot
        // choose a newer head or force an unbounded scan during export.
        XCTAssertEqual(try owner.membershipRefresh(after:two)?.advance(from:two),head)
        XCTAssertTrue(storage.values==before);XCTAssertEqual(try owner.membershipCertificateForRefresh(),head)
    }
    func testFailedPrivateCASLeavesHarmlessSignedForkAndRetryUsesExactPrivateHead()throws {
        let (store,owner)=try pairer("owner");_=try owner.createGroup(deviceName:"Desk",now:now);let base=try owner.membershipCertificateForRefresh()
        let (_,peer)=try pairer("uncommitted"),request=try XCTUnwrap(peer.requestJoin(deviceName:"Uncommitted",now:now).request),review=try owner.reviewRequest(request,now:now),before=storage.values
        storage.failReplace=true;XCTAssertThrowsError(try owner.approve(review,now:now));storage.failReplace=false
        XCTAssertTrue(storage.values==before);XCTAssertEqual(try owner.membershipCertificateForRefresh(),base)
        let orphan=try store.withRoutineDatabase {db->SyncMembershipCertificate in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key LIKE 'sync-membership-certificate-v1:%'");defer {sqlite3_finalize(row)}
            while sqlite3_step(row)==SQLITE_ROW {
                let bytes=try XCTUnwrap(Data(base64Encoded:db.text(row,0))),value=try SyncMembershipCertificate.decode(bytes,root:base.body.rootPublicKey)
                if value.body.revision==2 {return value}
            }
            throw OSwindError.invalid("Owned failed approval left no public candidate")
        }
        let (_,accepted)=try pairer("accepted");_=try join(accepted,to:owner,name:"Accepted")
        let head=try owner.membershipCertificateForRefresh();XCTAssertNotEqual(head,orphan)
        XCTAssertThrowsError(try owner.membershipRefresh(after:orphan))
        XCTAssertEqual(try owner.membershipRefresh(after:base)?.advance(from:base),head)
    }
    func testMissingCorruptMisaddressedAndOversizeIntermediateRefuse()throws {
        let (store,owner,_,two,three)=try four(),address=try key(three),original=try three.encoded().base64EncodedString(),head=try owner.membershipCertificateForRefresh()
        try store.withRoutineDatabase {db in let row=try db.statement("DELETE FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,address);try db.done(row)}
        XCTAssertThrowsError(try owner.membershipRefresh(after:two))
        for bad in ["not base64",try head.encoded().base64EncodedString(),String(repeating:"A",count:90_000)] {
            try put(store,key:address,value:bad);XCTAssertThrowsError(try owner.membershipRefresh(after:two))
        }
        try put(store,key:address,value:original)
        XCTAssertEqual(try owner.membershipRefresh(after:two)?.advance(from:two),head)
    }
    func testPublicCacheContainsNoPrivateMaterialAndForeignGroupCannotAdvanceIt()throws {
        let (store,owner,_,two,_)=try four(),(_,foreign)=try pairer("foreign");_=try foreign.createGroup(deviceName:"Foreign",now:now)
        XCTAssertThrowsError(try owner.membershipRefresh(after:foreign.membershipCertificateForRefresh()))
        var privateValues=[String]()
        for bytes in storage.values.values {
            let envelope=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            guard let text=envelope["material"] as? String,let material=Data(base64Encoded:text) else {continue}
            let value=try JSONSerialization.jsonObject(with:material) as! [String:Any]
            privateValues += ["signingPrivate","agreementPrivate","groupSecret","ownerPrivate"].compactMap {value[$0] as? String}
        }
        XCTAssertFalse(privateValues.isEmpty)
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key LIKE 'sync-membership-certificate-v1:%'");defer {sqlite3_finalize(row)}
            while sqlite3_step(row)==SQLITE_ROW {
                let bytes=try XCTUnwrap(Data(base64Encoded:db.text(row,0))),wire=String(decoding:bytes,as:UTF8.self)
                XCTAssertTrue(privateValues.allSatisfy {!wire.contains($0)},"Private credential reached public history")
                let object=try JSONSerialization.jsonObject(with:bytes) as! [String:Any];XCTAssertEqual(Set(object.keys),Set(["body","signature"]))
            }
        }
        XCTAssertNotNil(try owner.membershipRefresh(after:two))
    }
    func testOrphanBudgetPrunesOnlyPublicForksAndPreservesActiveAncestry()throws {
        let (store,_)=try pairer("cache"),pending=try SyncPendingJoin(name:"First",now:now),first=try SyncGroupAuthority(owner:pending.request,now:now)
        let second=try first.admitting(SyncPendingJoin(name:"Second",now:now).request,now:now),third=try second.admitting(SyncPendingJoin(name:"Third",now:now).request,now:now)
        try store.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {try SyncMembershipHistory.retain([first.certificate,second.certificate,third.certificate],anchoredHead:third.certificate,db:db)}}
        for index in 0..<260 {
            let fork=try first.admitting(SyncPendingJoin(name:"Orphan \(index)",now:now).request,now:now)
            try store.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {try SyncMembershipHistory.retain([fork.certificate],anchoredHead:third.certificate,db:db)}}
        }
        try store.withRoutineDatabase {db in
            XCTAssertLessThanOrEqual(try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key LIKE 'sync-membership-certificate-v1:%'"),SyncMembershipHistory.maximumRecords)
            let page=try XCTUnwrap(SyncMembershipHistory.page(after:first.certificate,anchoredHead:third.certificate,db:db));XCTAssertEqual(try page.advance(from:first.certificate),third.certificate)
        }
    }
    func testPortableContentRecoveryExcludesMembershipHistoryAndAuthority()throws {
        let (store,owner)=try pairer("owner");_=try owner.createGroup(deviceName:"Desk",now:now);try store.insert(Memory(id:"source",text:"Owned portable source"))
        owner.close();try store.close()
        let backup=root.appendingPathComponent("content.oswindbackup"),fresh=root.appendingPathComponent("restored")
        _=try LibraryRecovery.createBackup(from:store.root,destination:backup);_=try LibraryBackup.restore(backup,to:fresh)
        let restored=try MemoryStore(root:fresh);stores.append(restored)
        XCTAssertEqual(try restored.get("source")?.text,"Owned portable source")
        XCTAssertEqual(try restored.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key LIKE 'sync-membership-certificate-v1:%'")},0)
        XCTAssertEqual(try open(restored).status().phase,.unconfigured)
    }
    func testOwnedNativeKeychainFourLibrariesRetainExactOfflineHistoryAcrossNativeReopen()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit four-library owned Keychain history fixture; only its new accounts are accessed")}
        let backend=NativeWriterKeychainFixture(),state=root.appendingPathComponent("native-state"),mac=MacSyncMachineFingerprint()
        defer {do {try backend.cleanup()}catch {XCTFail("Owned membership history Keychain cleanup failed")}}
        func native(_ store:MemoryStore)throws->PersonalSyncPairing {
            let value=try PersonalSyncPairing(store:store,stateRoot:state,machine:mac,storage:backend);owners.append(value);return value
        }
        let store=try MemoryStore(root:root.appendingPathComponent("native-owner"));stores.append(store)
        let owner=try native(store);_=try owner.createGroup(deviceName:"Owned desk",now:now)
        var offline:SyncMembershipCertificate?
        for index in 2...4 {
            let peerStore=try MemoryStore(root:root.appendingPathComponent("native-peer-\(index)"));stores.append(peerStore)
            let peer=try native(peerStore),certificate=try join(peer,to:owner,name:"Owned Mac \(index)")
            if index==2 {offline=certificate};peer.close();try peerStore.close()
        }
        let head=try owner.membershipCertificateForRefresh(),accounts=backend.accounts
        owner.close();try store.close()
        let reopened=try MemoryStore(root:store.root,recoveryReadOnly:false,nativeWriterEnvironment:.init(stateRoot:state,machine:mac,storage:{_ in backend}));stores.append(reopened)
        let resumed=try native(reopened),page=try XCTUnwrap(resumed.membershipRefresh(after:XCTUnwrap(offline)))
        XCTAssertEqual(page.updateCount,2);XCTAssertEqual(try page.advance(from:XCTUnwrap(offline)),head)
        XCTAssertEqual(backend.accounts,accounts);XCTAssertEqual(accounts.count,4)
        resumed.close();try reopened.close();try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
    }
}
