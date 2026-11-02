import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private func deliverySender(_ store:MemoryStore,_ cache:SyncVersionStore,_ inbox:SyncObjectFolder)->SyncLibrarySender {
        .init(library:store,cache:cache,inbox:inbox,admit:{try $0.validate()},supplementalContent:{_ in throw OSwindError.invalid("Owned note fixture has no manifest or media")})
    }
    private func approveDeliveryWipe(_ store:MemoryStore,_ cache:SyncVersionStore)throws->SyncCollectionControl {
        try store.withRoutineDatabase {db in
            let history=SyncCollectionHistory(database:db,replica:cache.journal.replica)
            guard case .needsGroupReview(let proposal)=try history.reviewState(journal:cache.journal) else {throw OSwindError.invalid("Owned fixture has no wipe to review")}
            return try history.approveGroupErase(journal:cache.journal,counter:proposal.counter,expectedEra:proposal.era)
        }
    }
    func testSupersessionKeepsOldHeaderAndRecoversExactSuccessorAcrossRestartWithoutOldBody()throws {
        let (a,ac)=try endpoint("lagging-source",producerID),(b,bc)=try endpoint("lagging-destination",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"edited",kind:.note,text:"Owned obsolete text must not be retransmitted"));try drain(a,ac)
        let old=try XCTUnwrap(ac.journal.outbox().first),oldRecord=try packet(old,ac)
        try a.insert(Memory(id:"edited",kind:.note,text:"Owned current edited text"));try drain(a,ac)
        let current=try XCTUnwrap(ac.journal.outbox().last)
        XCTAssertNil(try ac.record(oldRecord.reference,admit:{_ in}))
        let secret=SyncGroupSecret(),inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("supersession-transport"),secret:secret,group:group,epoch:epoch);defer {inbox.close()}
        _=try deliverySender(a,ac,inbox).publish()
        XCTAssertEqual(try inbox.revision(replica:producerID,sequence:1),old)
        XCTAssertEqual(try inbox.revision(replica:producerID,sequence:2),current)
        XCTAssertNil(try inbox.content(XCTUnwrap(old.content)))
        XCTAssertEqual(try inbox.supersedingRevision(for:old),current)
        var projected=false
        let first=try bc.journal.receive(old,contentAvailable:{try inbox.content($0) != nil},supersededBy:{try inbox.supersedingRevision(for:$0)}) {_ in projected=true}
        XCTAssertEqual(first.applied,1);XCTAssertFalse(projected);XCTAssertEqual(try bc.journal.cursor(for:producerID),1)
        XCTAssertEqual(try count(b,"memories"),0)
        XCTAssertEqual(try bc.journal.expectedOperation(replica:producerID,sequence:2),current)
        let operationCipher=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.operation)
        let token=try operationCipher.token(for:Data("OSwind.sync.operation.v1\0\(producerID)\0\(current.dot.counter)".utf8))
        try FileManager.default.removeItem(at:inbox.root.appendingPathComponent("objects/\(token.prefix(2))/\(token)"))
        XCTAssertNil(try inbox.revision(replica:producerID,sequence:2))
        XCTAssertEqual(try inbox.supersedingRevision(for:old),current)
        let location=b.root;try b.close();let reopened=try MemoryStore(root:location);defer {try? reopened.close()}
        let cache=try reopened.withRoutineDatabase {db in
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:receiverID,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        }
        let recovered=try XCTUnwrap(cache.journal.expectedOperation(replica:producerID,sequence:2))
        XCTAssertEqual(recovered,current)
        let fork=try SyncRevision(key:current.key,dot:current.dot,context:current.context,mutation:.put,content:SyncContentReference(data:Data("Owned forged replacement".utf8)),creationEra:current.creationEra)
        XCTAssertThrowsError(try cache.journal.receive(fork,contentAvailable:{_ in XCTFail("A forked expected header fetched content");return true}))
        XCTAssertEqual(try cache.journal.cursor(for:producerID),1)
        let bytes=try XCTUnwrap(inbox.content(XCTUnwrap(recovered.content))),record=try SyncPortableRecord.decode(bytes)
        let local=try receive(recovered,record,reopened,cache,fetch:{_ in throw OSwindError.invalid("Owned note has no dependencies")})
        XCTAssertEqual(try reopened.get(local)?.text,"Owned current edited text")
        XCTAssertEqual(try cache.journal.cursor(for:producerID),2)
        XCTAssertNil(try cache.journal.expectedOperation(replica:producerID,sequence:2))
    }
    func testSupersessionRejectsConflictingFutureProofAndLeavesItsEarlierCheckpoint()throws {
        let (b,bc)=try endpoint("conflicting-proof",receiverID);defer {try? b.close()}
        let third="00000000-0000-0000-0000-000000007299"
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(third)
        let key=try SyncObjectKey.make(kind:.source,identity:Data("owned proof object".utf8)),body=try SyncContentReference(data:Data("owned obsolete body".utf8))
        let oldA=try SyncRevision(key:key,dot:.init(replica:producerID,counter:1),context:.empty,mutation:.put,content:body,creationEra:.empty)
        let oldC=try SyncRevision(key:key,dot:.init(replica:third,counter:1),context:.empty,mutation:.put,content:body,creationEra:.empty)
        let context=try SyncClock([producerID:2,third:1])
        let successor=try SyncRevision(key:key,dot:.init(replica:producerID,counter:3),context:context,mutation:.put,content:SyncContentReference(data:Data("owned chosen successor".utf8)),creationEra:.empty)
        let fork=try SyncRevision(key:key,dot:successor.dot,context:context,mutation:.put,content:SyncContentReference(data:Data("owned conflicting successor".utf8)),creationEra:.empty)
        XCTAssertEqual(try bc.journal.receive(oldA,contentAvailable:{_ in false},supersededBy:{_ in successor}) {_ in XCTFail("An unavailable old body was projected")}.applied,1)
        XCTAssertThrowsError(try bc.journal.receive(oldC,contentAvailable:{_ in false},supersededBy:{_ in fork}) {_ in XCTFail("A conflicting proof projected content")})
        XCTAssertEqual(try bc.journal.cursor(for:third),0)
        XCTAssertEqual(try bc.journal.expectedOperation(replica:producerID,sequence:3),successor)
        XCTAssertEqual(try count(b,"memories"),0)
    }
    func testCollectionUnreviewedClearRequiresLatestExactCutoffAndSurvivesReopen()throws {
        let (a,ac)=try endpoint("review-state",producerID);defer {try? a.close()}
        _=try a.wipeLibrary()
        let proposal=try a.withRoutineDatabase {db->SyncCollectionControl in
            let history=SyncCollectionHistory(database:db,replica:producerID)
            guard case .needsGroupReview(let proposal)=try history.reviewState(journal:ac.journal) else {throw OSwindError.invalid("Missing review")}
            XCTAssertThrowsError(try history.approveGroupErase(journal:ac.journal,counter:proposal.counter,expectedEra:.empty))
            XCTAssertEqual(try count(a,"personal_sync_collection_approvals"),0)
            return try history.approveGroupErase(journal:ac.journal,counter:proposal.counter,expectedEra:proposal.era)
        }
        let location=a.root;try a.close();let reopened=try MemoryStore(root:location);defer {try? reopened.close()}
        let journal=try reopened.withRoutineDatabase {db in try SyncJournal.install(database:db,replica:producerID,group:group,epoch:epoch)}
        try reopened.withRoutineDatabase {db in XCTAssertEqual(try SyncCollectionHistory(database:db,replica:producerID).reviewState(journal:journal),.ready)}
        _=try reopened.wipeLibrary()
        try reopened.withRoutineDatabase {db in
            let history=SyncCollectionHistory(database:db,replica:producerID)
            XCTAssertThrowsError(try history.approveGroupErase(journal:journal,counter:proposal.counter,expectedEra:proposal.era))
            guard case .needsGroupReview(let latest)=try history.reviewState(journal:journal) else {return XCTFail("A later local wipe needs its own group decision")}
            XCTAssertEqual(latest.counter,2)
        }
    }
    func testCollectionReviewedControlPrecedesPeerDeletionAndDuplicatePreservesLaterSource()throws {
        let (a,ac)=try endpoint("reviewed-owner",producerID),(b,bc)=try endpoint("reviewed-clear",receiverID)
        defer {try? a.close();try? b.close()};try ac.journal.allowPeer(receiverID);try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"old-shared",kind:.note,text:"Owned shared pre-clear source"));try drain(a,ac)
        let original=try XCTUnwrap(ac.journal.outbox().first)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("reviewed-transport"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        _=try deliverySender(a,ac,inbox).publish()
        let bytes=try XCTUnwrap(inbox.content(XCTUnwrap(original.content)))
        _=try receive(original,SyncPortableRecord.decode(bytes),b,bc,fetch:{_ in throw OSwindError.invalid("Owned note has no dependencies")})
        _=try b.wipeLibrary();try drain(b,bc)
        try b.insert(Memory(id:"new-after-clear",kind:.note,text:"Owned later source survives group erase"));try drain(b,bc)
        guard case .needsGroupReview=try deliverySender(b,bc,inbox).publish() else {return XCTFail("No implicit group erase approval")}
        let approved=try approveDeliveryWipe(b,bc)
        var admissions=0
        let sender=SyncLibrarySender(library:b,cache:bc,inbox:inbox,admit:{record in
            admissions+=1;XCTAssertEqual(try inbox.collectionControl(creator:self.receiverID,counter:1),approved);try record.validate()
        },supplementalContent:{_ in throw OSwindError.invalid("Owned note has no supplements")})
        _=try sender.publish();XCTAssertGreaterThan(admissions,0)
        let receiver=SyncCollectionReceiver(library:a,cache:ac,inbox:inbox,retire:{frontier,lease in
            let writer=SyncIncomingConversationWriter(library:a,cache:ac,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
            _=try ac.journal.retireKnownCollectionObject(original.key,frontier:frontier) {try writer.applyDeletion($0,admission:lease)}
        })
        XCTAssertEqual(try receiver.receive(creator:receiverID,counter:1),.applied)
        XCTAssertNil(try a.get("old-shared"))
        var imported=""
        for operation in try bc.journal.outbox() {
            let wire=try XCTUnwrap(inbox.revision(replica:receiverID,sequence:operation.dot.counter))
            if wire.mutation == .delete {try receiveDeletion(wire,a,ac)}
            else {
                let data=try XCTUnwrap(inbox.content(XCTUnwrap(wire.content)))
                imported=try receive(wire,SyncPortableRecord.decode(data),a,ac,fetch:{_ in throw OSwindError.invalid("Owned note has no dependencies")})
            }
        }
        XCTAssertEqual(try a.get(imported)?.text,"Owned later source survives group erase")
        XCTAssertEqual(try receiver.receive(creator:receiverID,counter:1),.unchanged)
        XCTAssertNotNil(try a.get(imported))
    }
    func testCollectionApprovedErasePublishesOldHeaderWithoutItsPrunedBody()throws {
        let (a,ac)=try endpoint("erased-old-body",producerID),(b,bc)=try endpoint("empty-control-receiver",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"old-private",kind:.note,text:"Owned erased text must never upload"));try drain(a,ac)
        let old=try XCTUnwrap(ac.journal.outbox().first)
        _=try a.wipeLibrary();try drain(a,ac)
        try a.insert(Memory(id:"fresh",kind:.note,text:"Owned fresh post-control note"));try drain(a,ac)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("header-only-control"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        _=try approveDeliveryWipe(a,ac);_=try deliverySender(a,ac,inbox).publish()
        XCTAssertNil(try inbox.content(XCTUnwrap(old.content)))
        XCTAssertEqual(try inbox.revision(replica:producerID,sequence:old.dot.counter),old)
        let receiver=SyncCollectionReceiver(library:b,cache:bc,inbox:inbox,retire:{_,_ in XCTAssertEqual(try self.count(b,"memories"),0)})
        XCTAssertEqual(try receiver.receive(creator:producerID,counter:1),.applied)
        var imported=""
        for op in try ac.journal.outbox() {
            let wire=try XCTUnwrap(inbox.revision(replica:producerID,sequence:op.dot.counter))
            if wire.key==old.key && wire.mutation == .put {
                XCTAssertEqual(try bc.journal.receive(wire,contentAvailable:{_ in XCTFail("Erased body was requested");return false}) {_ in XCTFail("Erased source was projected")}.applied,1)
            } else if wire.mutation == .delete {try receiveDeletion(wire,b,bc)}
            else {let data=try XCTUnwrap(inbox.content(XCTUnwrap(wire.content)));imported=try receive(wire,SyncPortableRecord.decode(data),b,bc,fetch:{_ in throw OSwindError.invalid("No dependencies")})}
        }
        XCTAssertEqual(try b.get(imported)?.text,"Owned fresh post-control note")
        XCTAssertEqual(try count(b,"memories"),1)
    }
    func testOrdinaryDeletionPublishesBarrierBeforeUnavailableOldBodyWithoutGroupControl()throws {
        let (a,ac)=try endpoint("ordinary-delete",producerID),(b,bc)=try endpoint("ordinary-delete-peer",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"removed",kind:.note,text:"Owned ordinary erased source"));try drain(a,ac)
        let old=try XCTUnwrap(ac.journal.outbox().first)
        _=try a.delete("removed");try drain(a,ac)
        let deletion=try XCTUnwrap(ac.journal.outbox().last)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("ordinary-erasure-transport"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        _=try deliverySender(a,ac,inbox).publish()
        XCTAssertNil(try inbox.content(XCTUnwrap(old.content)));XCTAssertNil(try inbox.collectionControl(creator:producerID,counter:1))
        XCTAssertEqual(try inbox.revision(replica:producerID,sequence:2),deletion)
        _=try bc.journal.receive(deletion,contentAvailable:{_ in XCTFail("Deletion fetched content");return false}) {_ in}
        XCTAssertEqual(try bc.journal.receive(old,contentAvailable:{_ in XCTFail("Erased obsolete body was fetched");return false}) {_ in XCTFail("Erased source was projected")}.applied,2)
        XCTAssertEqual(try bc.journal.cursor(for:producerID),2);XCTAssertEqual(try count(b,"memories"),0)
    }
    func testCollectionPurposeAuthenticationOrderAndReplayDoNotInventForeignWipes()throws {
        let (b,bc)=try endpoint("control-authentication",receiverID);defer {try? b.close()};try bc.journal.allowPeer(producerID)
        let secret=SyncGroupSecret(),inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("control-authentication-space"),secret:secret,group:group,epoch:epoch);defer {inbox.close()}
        let control=try SyncCollectionControl(group:group,epoch:epoch,creator:producerID,counter:3,era:SyncClock([producerID:3,receiverID:1]))
        try inbox.publishCollectionControl(control)
        var retirements=0
        let receiver=SyncCollectionReceiver(library:b,cache:bc,inbox:inbox,retire:{frontier,_ in
            retirements+=1;XCTAssertEqual(frontier[self.producerID],3);XCTAssertEqual(frontier[self.receiverID],0)
            XCTAssertEqual(try self.count(b,"memories"),0)
        })
        XCTAssertEqual(try receiver.receive(creator:producerID,counter:3),.applied)
        XCTAssertEqual(try bc.journal.cursor(for:producerID),0,"Wipe counters must not advance ordinary record cursors")
        try b.insert(Memory(id:"after-control",kind:.note,text:"Owned later native data"));try drain(b,bc)
        XCTAssertEqual(try receiver.receive(creator:producerID,counter:3),.unchanged)
        let older=try SyncCollectionControl(group:group,epoch:epoch,creator:producerID,counter:1,era:SyncClock([producerID:1]))
        try inbox.publishCollectionControl(older);XCTAssertEqual(try receiver.receive(creator:producerID,counter:1),.unchanged)
        XCTAssertEqual(retirements,1);XCTAssertNotNil(try b.get("after-control"))
        let fork=try SyncCollectionControl(group:group,epoch:epoch,creator:producerID,counter:3,era:SyncClock([producerID:3,receiverID:2]))
        XCTAssertThrowsError(try inbox.publishCollectionControl(fork))
        try b.withRoutineDatabase {db in
            XCTAssertThrowsError(try SyncCollectionHistory(database:db,replica:receiverID).observeVerifiedGroupControl(fork,journal:bc.journal,retire:{_ in XCTFail("Fork applied erasure")}))
        }
        let local=try SyncCollectionControl(group:group,epoch:epoch,creator:producerID,counter:4,era:SyncClock([producerID:4]))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:local.encoded()) as? [String:Any]);object["purpose"]="local-only"
        let invalid=try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
        let cipher=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.collectionControl)
        let packet=try cipher.seal(invalid,descriptor:SyncCollectionControl.descriptor(creator:producerID,counter:4))
        let path=inbox.root.appendingPathComponent("objects/\(packet.token.prefix(2))/\(packet.token)")
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try packet.bytes.write(to:path,options:.withoutOverwriting)
        XCTAssertThrowsError(try receiver.receive(creator:producerID,counter:4))
        let wrongPurpose=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.operation)
        XCTAssertThrowsError(try wrongPurpose.open(packet.bytes,expectedToken:packet.token))
        XCTAssertThrowsError(try SyncObjectFolder.open(at:inbox.root,secret:SyncGroupSecret(),group:group,epoch:epoch))
        XCTAssertEqual(retirements,1);XCTAssertNotNil(try b.get("after-control"))
        try b.withRoutineDatabase {db in XCTAssertEqual(try SyncCollectionHistory(database:db,replica:receiverID).current()[producerID],3)}
    }
    func testCollectionControlPassesFullOrdinaryPendingQueueAndItsFailedAdapterRollsBack()throws {
        enum OwnedFailure:Error {case afterNativeMutation}
        let (a,ac)=try endpoint("pressure-control-owner",producerID),(b,bc)=try endpoint("pressure-control-peer",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let key=try SyncObjectKey.make(kind:.source,identity:Data("owned withheld ordinary stream".utf8)),body=try SyncContentReference(data:Data("owned unavailable old body".utf8))
        for counter in 2...Int64(SyncJournal.pendingLimit+1) {
            let op=try SyncRevision(key:key,dot:.init(replica:producerID,counter:counter),context:SyncClock([producerID:counter-1]),mutation:.put,content:body,creationEra:.empty)
            _=try bc.journal.receive(op,contentAvailable:{_ in XCTFail("Missing predecessor must not fetch content");return false}) {_ in XCTFail("Missing predecessor projected a record")}
        }
        XCTAssertEqual(try count(b,"personal_sync_pending"),SyncJournal.pendingLimit)
        _=try a.wipeLibrary();_=try approveDeliveryWipe(a,ac)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("pressure-control-space"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        _=try deliverySender(a,ac,inbox).publish()
        let failing=SyncCollectionReceiver(library:b,cache:bc,inbox:inbox,retire:{_,_ in
            try b.insert(Memory(id:"rolled-back",kind:.note,text:"Owned transaction probe"));throw OwnedFailure.afterNativeMutation
        })
        XCTAssertThrowsError(try failing.receive(creator:producerID,counter:1))
        XCTAssertNil(try b.get("rolled-back"));XCTAssertEqual(try count(b,"personal_sync_collection_received_controls"),0)
        try b.withRoutineDatabase {db in XCTAssertEqual(try SyncCollectionHistory(database:db,replica:receiverID).current(),.empty)}
        let receiver=SyncCollectionReceiver(library:b,cache:bc,inbox:inbox,retire:{_,_ in XCTAssertEqual(try self.count(b,"memories"),0)})
        XCTAssertEqual(try receiver.receive(creator:producerID,counter:1),.applied)
        XCTAssertEqual(try count(b,"personal_sync_pending"),SyncJournal.pendingLimit)
        let first=try SyncRevision(key:key,dot:.init(replica:producerID,counter:1),context:.empty,mutation:.put,content:body,creationEra:.empty)
        _=try bc.journal.receive(first,contentAvailable:{_ in XCTFail("Erased old body was fetched");return false}) {_ in XCTFail("Erased source was projected")}
        for _ in 0..<8 {
            if try bc.journal.drain(limit:1024,contentAvailable:{_ in XCTFail("Old queued body was fetched");return false}) {_ in XCTFail("Old queued source was projected")}==0 {break}
        }
        XCTAssertEqual(try bc.journal.cursor(for:producerID),Int64(SyncJournal.pendingLimit+1))
        XCTAssertEqual(try count(b,"personal_sync_pending"),0);XCTAssertEqual(try count(b,"memories"),0)
    }
    func testCollectionSenderPolicyFailureDoesNotPublishARecordOrItsBody()throws {
        enum OwnedDenied:Error {case currentPolicy}
        let (a,ac)=try endpoint("policy-denied-send",producerID);defer {try? a.close()}
        try a.insert(Memory(id:"denied",kind:.note,text:"Owned private body must stay local"));try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().first)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("denied-send-space"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        let sender=SyncLibrarySender(library:a,cache:ac,inbox:inbox,admit:{_ in throw OwnedDenied.currentPolicy},supplementalContent:{_ in XCTFail("Denied source loaded supplements");return nil})
        XCTAssertThrowsError(try sender.publish())
        XCTAssertNil(try inbox.revision(replica:producerID,sequence:operation.dot.counter))
        XCTAssertNil(try inbox.content(XCTUnwrap(operation.content)))
        XCTAssertNotNil(try a.get("denied"))
    }
}
