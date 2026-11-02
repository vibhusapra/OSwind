import XCTest
import CSQLite
@testable import OSwindCore

final class SyncNativeReceivedRetirementTests:XCTestCase {
    var root:URL!,a:MemoryStore!,b:MemoryStore!,pa:PersonalSyncPairing!,pb:PersonalSyncPairing!,sa:SyncLibraryService!,sb:SyncLibraryService!
    let storage=DeliveryTestStorage(),machine=SyncCredentialBindingTests.Machine(value:String(repeating:"a",count:64))
    var environment:SyncNativeWriterEnvironment {.init(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{[storage] _ in storage})}
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-received-retirement-"+UUID().uuidString)
        a=try MemoryStore(root:root.appendingPathComponent("a"));b=try MemoryStore(root:root.appendingPathComponent("b"))
        try a.insert(Memory(id:"a-old",text:"Owned sender old history"));try b.insert(Memory(id:"b-old",text:"Owned receiver old history"))
        pa=try pairing(a);pb=try pairing(b);_=try pa.createGroup(deviceName:"Owned sender")
        let request=try XCTUnwrap(pb.requestJoin(deviceName:"Owned receiver").request)
        let response=try pa.approve(pa.reviewRequest(request));_=try pb.acceptResponse(response,trustedRootFingerprint:pa.status().rootFingerprint!)
        sa=try pa.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:true)
        sb=try pb.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:false)
        try sa.installNativeWriterAdmission();try sb.installNativeWriterAdmission()
        for _ in 0..<4 {_=try ready(sa);_=try ready(sb)}
        XCTAssertEqual(try a.stats(includeDiskUsage:false).count,2);XCTAssertEqual(try b.stats(includeDiskUsage:false).count,2)
    }
    override func tearDownWithError()throws {
        for service in [sa,sb].compactMap({$0}) {try? service.stop();service.inbox.close();service.transport.close()}
        pa?.close();pb?.close();try a?.close();try b?.close();try FileManager.default.removeItem(at:root)
    }
    func pairing(_ library:MemoryStore)throws->PersonalSyncPairing {try PersonalSyncPairing(store:library,stateRoot:environment.stateRoot,machine:machine,storage:storage)}
    func ready(_ service:SyncLibraryService)throws->SyncLibraryServiceStep {
        for _ in 0..<100 {
            let value=try service.tick(limit:64)
            if case .preparing=value {continue};if case .reviewingPolicy=value {continue};return value
        };throw OSwindError.unavailable("Owned service did not finish preparation")
    }
    func reopenA()throws {
        try sa.stop();sa.inbox.close();sa.transport.close();pa.close();try a.close()
        a=try MemoryStore(root:a.root,recoveryReadOnly:false,nativeWriterEnvironment:environment);pa=try pairing(a)
        sa=try pa.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:false)
    }
    func reopenB()throws {
        try sb.stop();sb.inbox.close();sb.transport.close();pb.close();try b.close()
        b=try MemoryStore(root:b.root,recoveryReadOnly:false,nativeWriterEnvironment:environment);pb=try pairing(b)
        sb=try pb.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:false)
    }
    func publishedErase()throws->SyncCollectionControl {
        let staged=try sa.stageLocalRetirement();XCTAssertTrue(try sa.cleanupRetirement().cleanupComplete)
        let control=try sa.completeLocalRetirement(pairing:pa);XCTAssertEqual(control,staged.control)
        try reopenA()
        guard case .needsGroupReview(let reviewed)=try ready(sa) else {throw OSwindError.invalid("Review the owned local erase first")}
        XCTAssertEqual(reviewed,control);try sa.approveLocalGroupErase(control);_=try ready(sa)
        return control
    }
    func count(_ library:MemoryStore,_ table:String)throws->Int {
        var db:OpaquePointer?,row:OpaquePointer?;XCTAssertEqual(sqlite3_open_v2(library.root.appendingPathComponent("memory.sqlite").path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil),SQLITE_OK);defer {sqlite3_finalize(row);sqlite3_close(db)}
        guard sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM "+table,-1,&row,nil)==SQLITE_OK else {throw OSwindError.database("Owned receiver read: "+String(cString:sqlite3_errmsg(db)))}
        XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);return Int(sqlite3_column_int(row,0))
    }
    func testSignedPeerRetirementReopensRenewsAndTransfersNewHistoryWithoutEcho()throws {
        let orphan=b.root.appendingPathComponent("audio/owned-orphan");try Data("Owned receiver orphan".utf8).write(to:orphan)
        let control=try publishedErase()
        guard case .needsNativeCollectionRetirement(let found)=try ready(sb) else {return XCTFail("Signed peer head must yield to the native erase owner")}
        XCTAssertEqual(found,control)
        var observed=false
        storage.afterReplacement={do {observed=try self.count(self.b,"memories")==2}catch {XCTFail("Owned WAL boundary reader failed")}}
        let result=try sb.stageReceivedRetirement(found);storage.afterReplacement=nil
        XCTAssertTrue(observed);XCTAssertEqual(result.counts.sources,2);XCTAssertEqual(result.control,control)
        XCTAssertEqual(try count(b,"memories"),0);XCTAssertEqual(try count(b,"personal_sync_collection_controls"),0,"Receiving cannot author a second local erase")
        XCTAssertTrue(FileManager.default.fileExists(atPath:orphan.path));XCTAssertThrowsError(try b.insert(Memory(id:"too-early",text:"Wait for exact cleanup")))
        try sb.stop();sb.inbox.close();sb.transport.close();pb.close();try b.close()
        let recovery=try SyncRetirementCleanupOwner.open(root:b.root,environment:environment);defer {try? recovery.close()}
        XCTAssertTrue(try recovery.cleanup().cleanupComplete);XCTAssertEqual(try recovery.completeRetirement(),control);try recovery.close()
        b=try MemoryStore(root:b.root,recoveryReadOnly:false,nativeWriterEnvironment:environment);pb=try pairing(b)
        sb=try pb.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.path))
        try a.insert(Memory(id:"a-new",text:"Owned sender after erase"));try b.insert(Memory(id:"b-new",text:"Owned receiver after erase"))
        for _ in 0..<4 {_=try ready(sa);_=try ready(sb)}
        for library in [a!,b!] {
            XCTAssertEqual(try library.stats(includeDiskUsage:false).count,2)
            XCTAssertEqual(try library.search(.init(query:"after erase",limit:20),mode:.keyword).count,2)
            XCTAssertEqual(try count(library,"personal_sync_collection_approvals"),library===a ? 1:0)
        }
        XCTAssertEqual(try sa.cache.journal.outbox().count,2);XCTAssertEqual(try sb.cache.journal.outbox().count,2)
        let before=storage.values
        XCTAssertThrowsError(try sb.stageReceivedRetirement(control));XCTAssertEqual(storage.values,before)
        XCTAssertNotNil(try b.get("b-new"));XCTAssertNotNil(try a.get("a-new"))
    }
    func testMissingSignedControlCannotEraseOrCloseTheActiveReceiver()throws {
        let control=try publishedErase(),missing=try SyncCollectionControl(group:control.group,epoch:control.epoch,creator:control.creator,counter:2,era:.init([control.creator:2]))
        let accounts=storage.values
        XCTAssertThrowsError(try sb.stageReceivedRetirement(missing));XCTAssertEqual(storage.values,accounts)
        XCTAssertEqual(try b.stats(includeDiskUsage:false).count,2)
        let staged=try sb.stageReceivedRetirement(control);XCTAssertEqual(staged.control,control)
        XCTAssertTrue(try sb.cleanupRetirement().cleanupComplete);XCTAssertEqual(try sb.completeReceivedRetirement(pairing:pb),control)
    }
    func testFailedReceivedExternalSaveRollsBackDataReceiptAndWriterGeneration()throws {
        let control=try publishedErase(),accounts=storage.values
        storage.failReplacement=true;XCTAssertThrowsError(try sb.stageReceivedRetirement(control));storage.failReplacement=false
        XCTAssertEqual(storage.values,accounts);XCTAssertEqual(try count(b,"memories"),2);XCTAssertEqual(try count(b,"personal_sync_collection_received_controls"),0)
        XCTAssertThrowsError(try b.insert(Memory(id:"poisoned-receiver",text:"Must reopen")))
        try reopenB();XCTAssertEqual(try b.stats(includeDiskUsage:false).count,2)
        _=try sb.stageReceivedRetirement(control);XCTAssertTrue(try sb.cleanupRetirement().cleanupComplete)
        XCTAssertEqual(try sb.completeReceivedRetirement(pairing:pb),control)
    }
    func testReceivedRetirementPreservesUnapprovedLocalReviewAcrossRenewal()throws {
        let local=try sb.stageLocalRetirement().control
        XCTAssertTrue(try sb.cleanupRetirement().cleanupComplete)
        XCTAssertEqual(try sb.completeLocalRetirement(pairing:pb),local)
        try reopenB()
        guard case .needsGroupReview(let pending)=try ready(sb) else {return XCTFail("Local review must remain explicit")}
        XCTAssertEqual(pending,local)
        try b.insert(Memory(id:"between-erasures",text:"Owned data after unapproved local erase"))
        let peer=try publishedErase()
        guard case .needsNativeCollectionRetirement(let found)=try ready(sb) else {return XCTFail("A peer erase must not starve behind local review")}
        XCTAssertEqual(found,peer)
        _=try sb.stageReceivedRetirement(found);XCTAssertTrue(try sb.cleanupRetirement().cleanupComplete)
        XCTAssertEqual(try sb.completeReceivedRetirement(pairing:pb),peer)
        try reopenB()
        guard case .needsGroupReview(let retained)=try ready(sb) else {return XCTFail("Receiving a peer erase cannot approve this Mac's erase")}
        XCTAssertEqual(retained,local);XCTAssertEqual(try count(b,"personal_sync_collection_approvals"),0)
        XCTAssertEqual(try b.stats(includeDiskUsage:false).count,0)
        try sb.approveLocalGroupErase(retained)
        for _ in 0..<4 {
            _=try ready(sb)
            if case .needsNativeCollectionRetirement(let remote)=try ready(sa) {
                _=try sa.stageReceivedRetirement(remote);XCTAssertTrue(try sa.cleanupRetirement().cleanupComplete)
                _=try sa.completeReceivedRetirement(pairing:pa);try reopenA()
            }
        }
        try a.insert(Memory(id:"concurrent-a",text:"Owned converged history"))
        for _ in 0..<4 {_=try ready(sa);_=try ready(sb)}
        XCTAssertEqual(try a.stats(includeDiskUsage:false).count,1);XCTAssertEqual(try b.stats(includeDiskUsage:false).count,1)
    }
}
