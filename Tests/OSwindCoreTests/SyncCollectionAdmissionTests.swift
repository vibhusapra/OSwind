import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private func collectionObserveFixture(_ store:MemoryStore,_ cache:SyncVersionStore,_ peer:String)throws {
        // Owned post-authentication observation boundary only. Actual peer
        // control verification/delivery is a separate unfinished integration.
        try cache.journal.allowPeer(peer)
        try store.withRoutineDatabase {db in
            let row=try db.statement("INSERT INTO personal_sync_collection_frontier VALUES(?,1)");defer {sqlite3_finalize(row)}
            db.bind(row,1,peer);try db.done(row)
        }
    }
    func testCollectionIdentityKeepsQueuedNativeBirthBeforeLearningAnotherWipe()throws {
        let (a,ac)=try endpoint("queued-era",producerID);defer {try? a.close()}
        try a.insert(Memory(id:"old-queued",kind:.note,text:"Owned old queued source"))
        try collectionObserveFixture(a,ac,receiverID)
        let queue=try SyncOutgoingWorkQueue.install(catalog:ac.catalog)
        XCTAssertGreaterThan(try queue.stage(),0)
        let identity=try ac.catalog.localIdentity(.source,primary:[.text(Data("old-queued".utf8))])
        try a.withRoutineDatabase {db in
            let history=SyncCollectionHistory(database:db,replica:producerID)
            XCTAssertEqual(try history.current(),try SyncClock([receiverID:1]))
            XCTAssertEqual(try history.objectEra(identity.key),.empty)
            XCTAssertTrue(try SyncChangeCapture.changes(db,scope:SyncChangeCapture.scope(db)).isEmpty)
        }
        XCTAssertThrowsError(try drain(a,ac),"An old queued lifetime must not be stamped as fresh at upload time")
        XCTAssertTrue(try ac.journal.outbox().isEmpty)
    }
    func testCollectionNewNativeLifetimeAfterActualWipePublishesItsOwnEra()throws {
        let (a,ac)=try endpoint("new-lifetime-era",producerID);defer {try? a.close()}
        try a.insert(Memory(id:"same-native-key",kind:.note,text:"Owned old lifetime"));try drain(a,ac)
        let old=try XCTUnwrap(ac.journal.outbox().first)
        XCTAssertEqual(old.creationEra,.empty)
        _=try a.wipeLibrary()
        try a.insert(Memory(id:"same-native-key",kind:.note,text:"Owned intentional new native lifetime"));try drain(a,ac)
        let fresh=try XCTUnwrap(ac.journal.outbox().last(where:{$0.mutation == .put}))
        XCTAssertNotEqual(fresh.key,old.key)
        XCTAssertEqual(fresh.creationEra,try SyncClock([producerID:1]))
        XCTAssertTrue(try ac.journal.state(for:old.key).isDeleted)
        XCTAssertFalse(try ac.journal.state(for:fresh.key).isDeleted)
        XCTAssertEqual(try a.get("same-native-key")?.text,"Owned intentional new native lifetime")
    }
    func testCollectionRetiredLifetimeCannotBeRenewedByAClaimedLaterEra()throws {
        let (a,ac)=try endpoint("old-producer",producerID),(b,bc)=try endpoint("wiped-receiver",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"old",kind:.note,text:"Owned unseen old lifetime"));try drain(a,ac)
        let old=try XCTUnwrap(ac.journal.outbox().first),record=try packet(old,ac)
        _=try b.wipeLibrary()
        _=try receive(old,record,b,bc,fetch:{_ in throw OSwindError.invalid("No owned source dependency")})
        let frontier=try SyncClock([receiverID:1]),renewed=try SyncRevision(key:old.key,dot:.init(replica:producerID,counter:2),context:old.clock,mutation:.put,content:old.content,creationEra:frontier)
        var bodyChecks=0,projected=false
        let result=try bc.journal.receive(renewed,contentAvailable:{_ in bodyChecks+=1;return true}) {_ in projected=true}
        XCTAssertEqual(result.applied,1);XCTAssertEqual(bodyChecks,0);XCTAssertFalse(projected)
        XCTAssertEqual(try bc.journal.cursor(for:producerID),2)
        let state=try bc.journal.state(for:old.key)
        XCTAssertTrue(state.isDeleted);XCTAssertEqual(state.collectionErasure,frontier);XCTAssertTrue(state.heads.isEmpty)
        XCTAssertEqual(try count(b,"memories"),0)
        let location=b.root;try b.close();let reopened=try MemoryStore(root:location);defer {try? reopened.close()}
        try reopened.withRoutineDatabase {db in
            let journal=try SyncJournal.install(database:db,replica:receiverID,group:group,epoch:epoch)
            XCTAssertTrue(try journal.state(for:old.key).isDeleted);XCTAssertEqual(try journal.cursor(for:producerID),2)
        }
    }
    func testCollectionFutureEraWaitsBeforeBodyAndUnknownPeerEraRefuses()throws {
        let (b,bc)=try endpoint("future-era",receiverID);defer {try? b.close()};try bc.journal.allowPeer(producerID)
        let key=try SyncObjectKey.make(kind:.source,identity:Data("owned future lifetime".utf8)),content=try SyncContentReference(data:Data("owned unavailable future body".utf8))
        let op=try SyncRevision(key:key,dot:.init(replica:producerID,counter:1),context:.empty,mutation:.put,content:content,creationEra:SyncClock([producerID:1]))
        var bodyChecks=0,projected=false
        XCTAssertEqual(try bc.journal.receive(op,contentAvailable:{_ in bodyChecks+=1;return true}) {_ in projected=true}.applied,0)
        XCTAssertEqual(bodyChecks,0);XCTAssertFalse(projected);XCTAssertEqual(try bc.journal.cursor(for:producerID),0)
        let unknown="00000000-0000-0000-0000-000000007199"
        let bad=try SyncRevision(key:key,dot:.init(replica:producerID,counter:2),context:op.clock,mutation:.put,content:content,creationEra:SyncClock([unknown:1]))
        XCTAssertThrowsError(try bc.journal.receive(bad,contentAvailable:{_ in XCTFail("Unauthorized era fetched content");return true}))
        XCTAssertEqual(try count(b,"personal_sync_pending"),1)
        XCTAssertEqual(try count(b,"personal_sync_receipts"),1)
    }
    func testCollectionKnownRetirementRequiresAdapterAndRollsBackItsFailedNativeErasure()throws {
        enum OwnedStop:Error {case afterNativeErasure}
        let (a,ac)=try endpoint("known-producer",producerID),(b,bc)=try endpoint("known-receiver",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"known",kind:.note,text:"Owned known source"));try drain(a,ac)
        let old=try XCTUnwrap(ac.journal.outbox().first),record=try packet(old,ac)
        let native=try receive(old,record,b,bc,fetch:{_ in throw OSwindError.invalid("No owned source dependencies")})
        try collectionObserveFixture(b,bc,producerID)
        let late=try SyncRevision(key:old.key,dot:.init(replica:producerID,counter:2),context:old.clock,mutation:.put,content:old.content,creationEra:.empty)
        var bodyChecks=0
        XCTAssertThrowsError(try bc.journal.receive(late,contentAvailable:{_ in bodyChecks+=1;return true}))
        XCTAssertNotNil(try b.get(native));XCTAssertEqual(try bc.journal.cursor(for:producerID),1)
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        XCTAssertThrowsError(try bc.journal.receive(late,contentAvailable:{_ in bodyChecks+=1;return true},retireCollection:{change in
            try writer.applyDeletion(change,admission:lease);throw OwnedStop.afterNativeErasure
        }))
        XCTAssertNotNil(try b.get(native));XCTAssertEqual(try bc.journal.cursor(for:producerID),1)
        XCTAssertFalse(try bc.journal.state(for:old.key).isDeleted)
        let result=try bc.journal.receive(late,contentAvailable:{_ in bodyChecks+=1;return true},retireCollection:{try writer.applyDeletion($0,admission:lease)}) {_ in XCTFail("An erased old body reached positive projection")}
        XCTAssertEqual(result.applied,1);XCTAssertEqual(bodyChecks,0);XCTAssertNil(try b.get(native))
        XCTAssertTrue(try bc.journal.state(for:old.key).isDeleted);XCTAssertEqual(try bc.journal.cursor(for:producerID),2)
    }
}

extension SyncIncomingSourceTests {
    func testCollectionLocalCopyWipeDoesNotPublishDeletionOfSharedPeerHistory()throws {
        let (a,ac)=try endpoint("shared-owner",producerID),(b,bc)=try endpoint("cleared-local-copy",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID);try ac.journal.allowPeer(receiverID)
        try a.insert(Memory(id:"shared-owned-source",kind:.note,text:"Owned shared history must remain on its other Mac"));try drain(a,ac)
        let original=try XCTUnwrap(ac.journal.outbox().first),record=try packet(original,ac)
        let local=try receive(original,record,b,bc,fetch:{_ in throw OSwindError.invalid("No owned source dependencies")})
        XCTAssertNotNil(try b.get(local))
        _=try b.wipeLibrary();try drain(b,bc)
        XCTAssertNil(try b.get(local))
        let emitted=try bc.journal.outbox()
        XCTAssertTrue(emitted.filter({$0.mutation == .delete && $0.key==original.key}).isEmpty,"Clearing this Mac's local copy must not publish a group deletion of the shared lifetime")
        for operation in emitted {try receiveDeletion(operation,a,ac)}
        XCTAssertNotNil(try a.get("shared-owned-source"),"The other Mac must retain its independent copy after a local-only clear")
    }
    func testCollectionPeerLocalFencePreservesIndependentEditsWhileWipedPeerRefusesOldHistory()throws {
        let (a,ac)=try endpoint("independent-local-history",producerID),(b,bc)=try endpoint("local-only-wipe",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID);try ac.journal.allowPeer(receiverID)
        try a.insert(Memory(id:"keep-on-a",kind:.note,text:"Owned history stays on the other Mac"));try drain(a,ac)
        let first=try XCTUnwrap(ac.journal.outbox().first)
        _=try b.wipeLibrary()
        // Stage only the verified observation of B's local fence. There is no
        // authorization to erase A's library, and no group-erasure marker.
        try a.withRoutineDatabase {db in
            let row=try db.statement("INSERT INTO personal_sync_collection_frontier VALUES(?,1)");defer {sqlite3_finalize(row)};db.bind(row,1,receiverID);try db.done(row)
        }
        try a.insert(Memory(id:"keep-on-a",kind:.note,text:"Owned edit remains allowed on A"))
        XCTAssertNoThrow(try drain(a,ac),"A peer's local wipe must not block independent history on this Mac")
        let operations=try ac.journal.outbox()
        XCTAssertEqual(operations.count,2)
        XCTAssertEqual(operations.last?.dot.counter,2)
        XCTAssertEqual(operations.last?.creationEra,.empty)
        XCTAssertEqual(try a.get("keep-on-a")?.text,"Owned edit remains allowed on A")
        XCTAssertFalse(try ac.journal.state(for:first.key).isDeleted)
        var bodyChecks=0,projected=false
        for op in operations {
            _=try bc.journal.receive(op,contentAvailable:{_ in bodyChecks+=1;return true}) {_ in projected=true}
        }
        XCTAssertEqual(bodyChecks,0);XCTAssertFalse(projected);XCTAssertEqual(try count(b,"memories"),0)
        XCTAssertEqual(try bc.journal.cursor(for:producerID),operations.last?.dot.counter)
    }
    func testCollectionStaleEraCannotRetireAKnownPostWipeNativeLifetime()throws {
        let (a,ac)=try endpoint("fresh-producer",producerID),(b,bc)=try endpoint("fresh-receiver",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        _=try a.wipeLibrary()
        try a.insert(Memory(id:"fresh-after-wipe",kind:.note,text:"Owned post-wipe history must survive"));try drain(a,ac)
        let fresh=try XCTUnwrap(ac.journal.outbox().first),record=try packet(fresh,ac)
        XCTAssertEqual(fresh.creationEra,try SyncClock([producerID:1]))
        try collectionObserveFixture(b,bc,producerID)
        let native=try receive(fresh,record,b,bc,fetch:{_ in throw OSwindError.invalid("No owned source dependencies")})
        let stale=try SyncRevision(key:fresh.key,dot:.init(replica:producerID,counter:2),context:fresh.clock,mutation:.put,content:fresh.content,creationEra:.empty)
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        var bodyChecks=0,retirements=0
        XCTAssertThrowsError(try bc.journal.receive(stale,contentAvailable:{_ in bodyChecks+=1;return true},retireCollection:{change in
            retirements+=1;try writer.applyDeletion(change,admission:lease)
        }))
        XCTAssertEqual(bodyChecks,0);XCTAssertEqual(retirements,0)
        XCTAssertNotNil(try b.get(native));XCTAssertFalse(try bc.journal.state(for:fresh.key).isDeleted)
        XCTAssertEqual(try bc.journal.cursor(for:producerID),fresh.dot.counter)
    }
}

final class SyncCollectionEraProtocolTests:XCTestCase {
    let a="00000000-0000-0000-0000-000000007201",b="00000000-0000-0000-0000-000000007202"
    func revision(_ counter:Int64,_ era:SyncClock?)throws->SyncRevision {
        try .init(key:.make(kind:.source,identity:Data("owned protocol lifetime".utf8)),dot:.init(replica:a,counter:counter),context:counter==1 ? .empty:SyncClock([a:counter-1]),mutation:.put,content:.init(data:Data("owned body".utf8)),creationEra:era)
    }
    func testLegacyMissingEraRemainsDistinctFromExplicitEmptyEraInCanonicalWire()throws {
        let legacy=try revision(1,nil),declared=try revision(1,.empty)
        XCTAssertNotEqual(try legacy.encoded(),try declared.encoded())
        XCTAssertNil(try SyncRevision.decode(legacy.encoded()).creationEra)
        XCTAssertEqual(try SyncRevision.decode(declared.encoded()).creationEra,.empty)
        XCTAssertThrowsError(try SyncRevision(key:legacy.key,dot:legacy.dot,context:.empty,mutation:.delete,creationEra:.empty))
    }
    func testContentEditsCannotChangeAnExistingLifetimesCreationEra()throws {
        let first=try revision(1,.empty);var state=SyncRegister(key:first.key);try state.integrate(first)
        XCTAssertThrowsError(try state.integrate(revision(2,SyncClock([b:1]))))
        XCTAssertEqual(state.preferred,first)
    }
    func testCollectionRetirementRoundTripsWithoutInventingAnAuthoredDeleteDot()throws {
        let first=try revision(1,.empty),frontier=try SyncClock([b:1]);var state=SyncRegister(key:first.key)
        try state.retireForCollection(first,frontier:frontier)
        let restored=try SyncRegister.decode(state.encoded())
        XCTAssertTrue(restored.isDeleted);XCTAssertEqual(restored.collectionErasure,frontier)
        XCTAssertTrue(restored.deletions.counters.isEmpty);XCTAssertEqual(restored.clock,try first.clock)
        XCTAssertTrue(restored.heads.isEmpty)
    }
}
