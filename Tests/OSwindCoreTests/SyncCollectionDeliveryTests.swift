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
    func testCollectionDisabledOwnerCannotPublishEvenOpaqueDeletionHeaders()throws {
        let (a,ac)=try endpoint("disabled-header-owner",producerID);defer {try? a.close()}
        try a.insert(Memory(id:"deleted",kind:.note,text:"Owned data erased before sync was disabled"));try drain(a,ac)
        _=try a.delete("deleted");try drain(a,ac)
        try a.withRoutineDatabase {try $0.execute("UPDATE personal_sync_capture SET enabled=0 WHERE singleton=1")}
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("disabled-header-space"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        XCTAssertThrowsError(try deliverySender(a,ac,inbox).publish(),"A deactivated owner cannot export a prepared deletion")
        XCTAssertNil(try inbox.revision(replica:producerID,sequence:1))
        XCTAssertNil(try inbox.revision(replica:producerID,sequence:2))
    }
    func testCollectionDisabledOwnerCannotApplyAnAuthenticatedPeerControl()throws {
        let (a,ac)=try endpoint("active-control-owner",producerID),(b,bc)=try endpoint("disabled-control-peer",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        _=try a.wipeLibrary();_=try approveDeliveryWipe(a,ac)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("disabled-receiver-space"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        _=try deliverySender(a,ac,inbox).publish()
        try b.withRoutineDatabase {try $0.execute("UPDATE personal_sync_capture SET enabled=0 WHERE singleton=1")}
        var retirements=0
        let receiver=SyncCollectionReceiver(library:b,cache:bc,inbox:inbox,retire:{_,_ in retirements+=1})
        XCTAssertThrowsError(try receiver.receive(creator:producerID,counter:1))
        XCTAssertEqual(retirements,0)
        XCTAssertEqual(try count(b,"personal_sync_collection_received_controls"),0)
    }
    func testCollectionReplacedOrSuppressedOwnerCannotPublishPreparedPackets()throws {
        for (name,update) in [("replaced","generation='11111111-2222-4333-8444-555555555555'"),("suppressed","suppressed=1")] {
            let (a,ac)=try endpoint("\(name)-header-owner",producerID);defer {try? a.close()}
            try a.insert(Memory(id:"deleted",kind:.note,text:"Owned old prepared note"));try drain(a,ac)
            _=try a.delete("deleted");try drain(a,ac)
            try a.withRoutineDatabase {try $0.execute("UPDATE personal_sync_capture SET \(update) WHERE singleton=1")}
            let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("\(name)-header-space"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
            XCTAssertThrowsError(try deliverySender(a,ac,inbox).publish(),name)
            XCTAssertNil(try inbox.revision(replica:producerID,sequence:1),name)
            XCTAssertNil(try inbox.revision(replica:producerID,sequence:2),name)
        }
    }
    func testCollectionReplacedOrSuppressedReceiverCannotRetireAndActiveRetryWorks()throws {
        let (a,ac)=try endpoint("context-control-owner",producerID);defer {try? a.close()}
        _=try a.wipeLibrary();_=try approveDeliveryWipe(a,ac)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("context-control-space"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        _=try deliverySender(a,ac,inbox).publish()
        for (name,update) in [("replaced","generation='11111111-2222-4333-8444-555555555555'"),("suppressed","suppressed=1")] {
            let (b,bc)=try endpoint("\(name)-control-peer",receiverID);defer {try? b.close()};try bc.journal.allowPeer(producerID)
            let scope=bc.catalog.scope
            try b.withRoutineDatabase {try $0.execute("UPDATE personal_sync_capture SET \(update) WHERE singleton=1")}
            var retirements=0
            let receiver=SyncCollectionReceiver(library:b,cache:bc,inbox:inbox,retire:{_,_ in retirements+=1})
            XCTAssertThrowsError(try receiver.receive(creator:producerID,counter:1),name)
            XCTAssertEqual(retirements,0,name);XCTAssertEqual(try count(b,"personal_sync_collection_received_controls"),0,name)
            // Restore only this owned fixture's original capture state. A failed
            // attempt must not consume its authenticated receipt or cutoff.
            try b.withRoutineDatabase {try $0.execute("UPDATE personal_sync_capture SET generation='\(scope.generation)',suppressed=0 WHERE singleton=1")}
            XCTAssertEqual(try receiver.receive(creator:producerID,counter:1),.applied,name)
            XCTAssertEqual(retirements,1,name);XCTAssertEqual(try count(b,"personal_sync_collection_received_controls"),1,name)
        }
    }
    func testCollectionFinalAdmissionCannotExportAfterItDeactivatesTheOwner()throws {
        let (a,ac)=try endpoint("final-disabled-owner",producerID);defer {try? a.close()}
        try a.insert(Memory(id:"owned",kind:.note,text:"Owned body must stay local after deactivation"));try drain(a,ac)
        let revision=try XCTUnwrap(ac.journal.outbox().first),content=try XCTUnwrap(revision.content)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("final-disabled-space"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        var admissions=0
        let sender=SyncLibrarySender(library:a,cache:ac,inbox:inbox,admit:{_ in
            admissions+=1
            if admissions==2 {try a.withRoutineDatabase {try $0.execute("UPDATE personal_sync_capture SET enabled=0 WHERE singleton=1")}}
        },supplementalContent:{_ in XCTFail("Owned note has no media");return nil})
        XCTAssertThrowsError(try sender.publish());XCTAssertEqual(admissions,2)
        XCTAssertNil(try inbox.content(content),"A later header refusal cannot undo an exported private body")
        XCTAssertNil(try inbox.revision(replica:producerID,sequence:revision.dot.counter))
    }
    func testCollectionFinalAdmissionCannotExportAfterReentrantNativeSourceRetirement()throws {
        let (a,ac)=try endpoint("final-erased-owner",producerID);defer {try? a.close()}
        try a.insert(Memory(id:"owned",kind:.note,text:"Owned source retired during its last policy check"));try drain(a,ac)
        let revision=try XCTUnwrap(ac.journal.outbox().first),content=try XCTUnwrap(revision.content)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("final-erased-space"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        var admissions=0
        let sender=SyncLibrarySender(library:a,cache:ac,inbox:inbox,admit:{_ in
            admissions+=1
            if admissions==2 {_=try a.delete("owned");XCTAssertNil(try a.get("owned"))}
        },supplementalContent:{_ in XCTFail("Owned note has no media");return nil})
        XCTAssertThrowsError(try sender.publish());XCTAssertEqual(admissions,2)
        XCTAssertNil(try inbox.content(content),"Current native retirement must win before file publication")
        XCTAssertNil(try inbox.revision(replica:producerID,sequence:revision.dot.counter))
    }
    func testCollectionFinalAdmissionCannotPublishRecapAfterItsExactEvidenceIsRetired()throws {
        let (a,ac)=try endpoint("final-recap-owner",producerID);defer {try? a.close()}
        let source=Memory(id:"evidence",kind:.note,text:"Owned exact evidence retired after dependency publication")
        try a.insert(source)
        let recap=try a.saveRecap(.init(text:"Owned dependent recap",sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0),title:"Owned recap");try drain(a,ac)
        let identity=try ac.catalog.localIdentity(.source,primary:[.text(Data(recap.id.utf8))])
        let key=try identity.key,revision=try XCTUnwrap(ac.journal.outbox().first {$0.key==key}),content=try XCTUnwrap(revision.content)
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("final-recap-space"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        var admissions=0
        let sender=SyncLibrarySender(library:a,cache:ac,inbox:inbox,admit:{record in
            if record.identity==identity {admissions+=1;if admissions==2 {_=try a.delete(source.id);XCTAssertNil(try a.get(source.id))}}
        },supplementalContent:{_ in XCTFail("Owned recap has no media");return nil})
        XCTAssertThrowsError(try sender.publish(after:revision.dot.counter-1,limit:1));XCTAssertEqual(admissions,2)
        XCTAssertNil(try inbox.content(content),"Already-read recap bytes do not authorize retired evidence")
        XCTAssertNil(try inbox.revision(replica:producerID,sequence:revision.dot.counter))
    }
    func testCollectionFailedFinalAdmissionRollsBackItsOwnedMutationAndAllowsAnExactRetry()throws {
        for mode in ["disable","retire","wipe-intent"] {
            let (a,ac)=try endpoint("late-rollback-"+mode,producerID);defer {try? a.close()}
            try a.insert(Memory(id:"owned",kind:.note,text:"Owned source remains after a rejected reentrant callback"));try drain(a,ac)
            let revision=try XCTUnwrap(ac.journal.outbox().first),content=try XCTUnwrap(revision.content)
            let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("late-rollback-space-"+mode),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
            var admissions=0
            let sender=SyncLibrarySender(library:a,cache:ac,inbox:inbox,admit:{_ in
                admissions+=1
                if admissions==2 {
                    if mode=="retire" {_=try a.delete("owned")}
                    else {try a.withRoutineDatabase {db in
                        try db.execute(mode=="disable" ? "UPDATE personal_sync_capture SET enabled=0 WHERE singleton=1":"INSERT INTO store_metadata(key,value) VALUES('library_wipe_dirty','1') ON CONFLICT(key) DO UPDATE SET value='1'")
                    }}
                }
            },supplementalContent:{_ in XCTFail("Owned note has no media");return nil})
            XCTAssertThrowsError(try sender.publish(),mode);XCTAssertEqual(admissions,2,mode)
            XCTAssertNil(try inbox.content(content),mode);XCTAssertNil(try inbox.revision(replica:producerID,sequence:revision.dot.counter),mode)
            XCTAssertNotNil(try a.get("owned"),"Rejected callback mutations share the publication transaction")
            try a.withRoutineDatabase {db in
                _=try SyncChangeCapture.scope(db,requireActive:true)
                XCTAssertEqual(try SyncCollectionHistory(database:db,replica:producerID).current(),.empty)
            }
            _=try deliverySender(a,ac,inbox).publish()
            XCTAssertEqual(try inbox.revision(replica:producerID,sequence:revision.dot.counter),revision,mode)
            XCTAssertNotNil(try inbox.content(content),mode)
        }
    }
    func testCollectionGraphHeaderRechecksEarlierOwnersAfterEveryPolicyCallback()throws {
        let (a,ac)=try endpoint("late-graph-owner",producerID);defer {try? a.close()}
        let source=Memory(id:"evidence",kind:.note,text:"Owned independent evidence stays live")
        try a.insert(source)
        let recap=try a.saveRecap(.init(text:"Owned recap removed by a later dependency callback",sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0),title:"Owned recap");try drain(a,ac)
        let owner=try ac.catalog.localIdentity(.source,primary:[.text(Data(recap.id.utf8))]),child=try ac.catalog.localIdentity(.source,primary:[.text(Data(source.id.utf8))])
        let ownerKey=try owner.key,revision=try XCTUnwrap(ac.journal.outbox().first {$0.key==ownerKey})
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("late-graph-space"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {inbox.close()}
        var childAdmissions=0,retired=false
        let sender=SyncLibrarySender(library:a,cache:ac,inbox:inbox,admit:{record in
            if record.identity==child {
                childAdmissions+=1
                if childAdmissions==3 {
                    // Run the actual logical phase used by native deletion in
                    // this existing admission transaction; never touch files
                    // before commit. The independent child remains valid.
                    try a.withRoutineDatabase {db in
                        defer {try? db.clearErasureSelection()}
                        try db.prepareCanonicalErasure(recap.id)
                        let erased=try db.eraseSelectedHistory();XCTAssertEqual(erased.sources,1)
                    }
                    XCTAssertNil(try a.get(recap.id));XCTAssertNotNil(try a.get(source.id));retired=true
                }
            }
        },supplementalContent:{_ in XCTFail("Owned recap has no media");return nil})
        XCTAssertThrowsError(try sender.publish(after:revision.dot.counter-1,limit:1))
        XCTAssertEqual(childAdmissions,3);XCTAssertTrue(retired)
        XCTAssertNil(try inbox.revision(replica:producerID,sequence:revision.dot.counter),"A later callback invalidated the already-checked root")
    }
}
