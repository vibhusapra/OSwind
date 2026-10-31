import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private func lateGraphPut(_ operation:SyncRevision,_ record:SyncPortableRecord,retiring:Bool,store:MemoryStore,cache:SyncVersionStore,producer:SyncVersionStore)throws {
        let lease=try store.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:store,cache:cache,admit:{_ in if retiring {XCTFail("Erased evidence must not be readmitted")}},pathsFor:{_,_ in XCTFail("No fixture media");return [:]},admitMedia:{_,_,_ in XCTFail("No fixture media")})
        let receipt=try cache.journal.receive(operation,contentAvailable:{_ in true}) {change in
            if change.after.isDeleted {try writer.applyDeletion(change,admission:lease)}
            else {
                let local=try writer.apply(record,admission:lease,fetchExactSource:{reference in
                    if retiring {XCTFail("Known-erased evidence must not be fetched");throw OSwindError.invalid("Unexpected erased dependency fetch")}
                    return try XCTUnwrap(producer.record(reference,admit:{_ in}))
                })
                if retiring {XCTAssertEqual(local,"")}
            }
        }
        XCTAssertTrue(receipt.inserted);XCTAssertEqual(receipt.applied,1)
        if retiring {XCTAssertTrue(try cache.journal.state(for:operation.key).isDeleted)}
    }
    private func lateSourceEntityRecords(kind:EntityKind,corrections:Bool)throws {
        let thirdID="00000000-0000-0000-0000-000000006151"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        let source=Memory(id:"owned-source",timestamp:now,kind:.note,app:"Owned late graph",text:"Mira owns Orion.")
        try a.insert(source);try drain(a,ac);let initial=try XCTUnwrap(ac.journal.outbox().first),definition=try packet(initial,ac)
        _=try receive(initial,definition,b,bc,fetch:{_ in definition});let local=try receive(initial,definition,c,cc,fetch:{_ in definition})
        let entity=try c.createEntity(kind:kind,name:kind == .person ? "Mira":"Orion")
        try c.linkEntity(entity.id,to:local)
        if corrections {try c.unlinkEntity(entity.id,from:local)}
        try drain(c,cc)
        let retiringKinds:Set<SyncObjectKind> = corrections ? [.entityRejection,.projectRejection]:[.entityMention]
        let children=try cc.journal.outbox().filter {$0.mutation == .put && retiringKinds.contains($0.key.kind)}
        XCTAssertEqual(children.count,1)
        _=try c.createChat(title:"Independent later graph record");try drain(c,cc)
        _=try a.delete(source.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last)
        try receiveDeletion(deletion,b,bc);let before=try bc.journal.outbox().last?.dot.counter ?? 0
        let operations=try cc.journal.outbox()
        for operation in operations {
            if operation.mutation == .delete {try receiveDeletion(operation,b,bc)}
            else {try lateGraphPut(operation,packet(operation,cc),retiring:retiringKinds.contains(operation.key.kind),store:b,cache:bc,producer:cc)}
        }
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),operations.last?.dot.counter)
        XCTAssertEqual(try count(b,"memories"),0);XCTAssertEqual(try count(b,"entity_mentions"),0)
        XCTAssertEqual(try count(b,"entity_ignored"),0);XCTAssertEqual(try count(b,"entity_project_ignored"),0)
        let kept=try b.entities(kind:kind);XCTAssertEqual(kept.count,1);XCTAssertTrue(try XCTUnwrap(kept.first).curated)
        XCTAssertEqual(try b.chats().map(\.title),["Independent later graph record"])
        let announcements=try bc.journal.outbox(after:before)
        XCTAssertEqual(Set(announcements.map(\.key)),Set(children.map(\.key)))
        for announcement in announcements {
            let origin=try XCTUnwrap(children.first {$0.key==announcement.key})
            XCTAssertEqual(announcement.mutation,.delete);XCTAssertNil(announcement.content)
            XCTAssertTrue(announcement.context.contains(origin.dot));XCTAssertTrue(announcement.context.contains(deletion.dot))
        }
        for operation in operations where operation.key.kind == .entity || operation.key.kind == .entityAlias {XCTAssertFalse(try bc.journal.state(for:operation.key).isDeleted)}
        XCTAssertEqual(try count(b,"personal_sync_pending"),0);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }
    func testLateSourceMentionRetiresWithoutDeletingCuratedDefinition()throws {try lateSourceEntityRecords(kind:.person,corrections:false)}
    func testLateSourceNameCorrectionRetiresWithoutDeletingCuratedDefinition()throws {try lateSourceEntityRecords(kind:.person,corrections:true)}
    func testLateSourceProjectCorrectionsRetireWithoutDeletingCuratedDefinition()throws {try lateSourceEntityRecords(kind:.project,corrections:true)}
    func testLateRecapAndCitationRetireWithoutBlockingLaterSenderRecord()throws {
        let thirdID="00000000-0000-0000-0000-000000006152"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        let source=Memory(id:"recap-evidence",timestamp:now,kind:.note,app:"Owned recap",text:"Owned evidence for offline recap")
        try a.insert(source);try drain(a,ac);try derivedDeliver(ac,b,bc);try derivedDeliver(ac,c,cc)
        let memory=try XCTUnwrap(c.timelineSample(.init(),limit:1).first)
        _=try c.saveRecap(.init(text:"Offline recap body [1]",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]),title:"Offline recap")
        try drain(c,cc);let children=try cc.journal.outbox()
        XCTAssertEqual(children.map(\.key.kind),[.source,.recapCitation,.evidencePin])
        _=try c.createChat(title:"Independent after late recap");try drain(c,cc)
        _=try a.delete(source.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last);try receiveDeletion(deletion,b,bc)
        for operation in try cc.journal.outbox() {
            try lateGraphPut(operation,packet(operation,cc),retiring:operation.key.kind != .conversation,store:b,cache:bc,producer:cc)
        }
        XCTAssertEqual(try count(b,"memories"),0);XCTAssertEqual(try count(b,"recap_sources"),0)
        XCTAssertEqual(try b.chats().map(\.title),["Independent after late recap"])
        XCTAssertEqual(Set(try bc.journal.outbox().map(\.key)),Set(children.map(\.key)))
        for child in children {
            let barrier=try XCTUnwrap(bc.journal.outbox().first {$0.key==child.key})
            XCTAssertTrue(barrier.context.contains(child.dot));XCTAssertTrue(barrier.context.contains(deletion.dot))
        }
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),4)
    }
    func testLateEvidencePinRetiresWithoutReadingDeletedOriginal()throws {
        let thirdID="00000000-0000-0000-0000-000000006153"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        var source=Memory(id:"pin-evidence",timestamp:now,endTimestamp:now.addingTimeInterval(2),kind:.screen,app:"Owned pin",text:"Owned sampled evidence",display:AccessibilityCaptureRecord.display)
        source.textObservation = .init(sessionID:"00000000-0000-0000-0000-000000006154",samples:2,largestGapSeconds:2)
        try a.insert(source);try drain(a,ac);try derivedDeliver(ac,b,bc);try derivedDeliver(ac,c,cc)
        let memory=try XCTUnwrap(c.timelineSample(.init(),limit:1).first)
        try c.withRoutineDatabase {try $0.pinTextObservation(memory)};try drain(c,cc)
        let pin=try XCTUnwrap(cc.journal.outbox().first);XCTAssertEqual(pin.key.kind,.evidencePin)
        _=try c.createChat(title:"Independent after late pin");try drain(c,cc)
        _=try a.delete(source.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last);try receiveDeletion(deletion,b,bc)
        for operation in try cc.journal.outbox() {
            try lateGraphPut(operation,packet(operation,cc),retiring:operation.key.kind == .evidencePin,store:b,cache:bc,producer:cc)
        }
        XCTAssertEqual(try count(b,"memories"),0);XCTAssertEqual(try count(b,"text_observation_pins"),0)
        XCTAssertEqual(try b.chats().map(\.title),["Independent after late pin"])
        let barrier=try XCTUnwrap(bc.journal.outbox().last);XCTAssertEqual(barrier.key,pin.key)
        XCTAssertTrue(barrier.context.contains(pin.dot));XCTAssertTrue(barrier.context.contains(deletion.dot))
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),2)
    }
    func testLateAliasRetiresAfterDefinitionDeletionAndSenderProgresses()throws {
        let thirdID="00000000-0000-0000-0000-000000006155"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        let entity=try a.createEntity(kind:.person,name:"Owned alias parent");try drain(a,ac)
        let initialThrough=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        try derivedDeliver(ac,b,bc);try derivedDeliver(ac,c,cc)
        let local=try XCTUnwrap(c.entities(kind:.person).first)
        try c.withRoutineDatabase {db in
            let row=try db.statement("INSERT INTO entity_aliases(entity_id,kind,key,label) VALUES(?,?,?,?)");defer {sqlite3_finalize(row)}
            db.bind(row,1,local.id);db.bind(row,2,"person");db.bind(row,3,"late alternate");db.bind(row,4,"Late alternate");try db.done(row)
        }
        try drain(c,cc);let alias=try XCTUnwrap(cc.journal.outbox().first);XCTAssertEqual(alias.key.kind,.entityAlias)
        _=try c.createChat(title:"Independent after late alias");try drain(c,cc)
        try a.deleteEntity(entity.id);try drain(a,ac);try derivedDeliver(ac,b,bc,after:initialThrough)
        let deletion=try XCTUnwrap(ac.journal.outbox(after:initialThrough).first {$0.key.kind == .entity}),before=try bc.journal.outbox().last?.dot.counter ?? 0
        for operation in try cc.journal.outbox() {
            try lateGraphPut(operation,packet(operation,cc),retiring:operation.key.kind == .entityAlias,store:b,cache:bc,producer:cc)
        }
        XCTAssertEqual(try count(b,"memory_entities"),0);XCTAssertEqual(try count(b,"entity_aliases"),0)
        XCTAssertEqual(try b.chats().map(\.title),["Independent after late alias"])
        let announcements=try bc.journal.outbox(after:before);XCTAssertEqual(announcements.map(\.key),[alias.key])
        let barrier=try XCTUnwrap(announcements.first);XCTAssertTrue(barrier.context.contains(alias.dot));XCTAssertTrue(barrier.context.contains(deletion.dot))
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),2)
    }
    func testLateAnswerCitationRetiresOwnerAtomicallyAndSenderProgresses()throws {
        let thirdID="00000000-0000-0000-0000-000000006156"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        let source=Memory(id:"answer-evidence",timestamp:now,kind:.note,app:"Owned answer",text:"Owned offline answer evidence")
        try a.insert(source);try drain(a,ac);try derivedDeliver(ac,b,bc);try derivedDeliver(ac,c,cc)
        let memory=try XCTUnwrap(c.timelineSample(.init(),limit:1).first),chat=try c.createChat(title:"Offline answer conversation")
        _=try c.appendChatTurn(sessionID:chat.id,question:"Owned offline question",answer:.init(text:"Owned offline answer [1]",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]));try drain(c,cc)
        let operations=try cc.journal.outbox(),citation=try XCTUnwrap(operations.first {$0.key.kind == .conversationCitation}),turn=try XCTUnwrap(operations.first {$0.key.kind == .turn})
        _=try c.createChat(title:"Independent after late citation");try drain(c,cc)
        _=try a.delete(source.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last);try receiveDeletion(deletion,b,bc)
        for operation in operations where operation.dot.counter<citation.dot.counter {try lateGraphPut(operation,packet(operation,cc),retiring:false,store:b,cache:bc,producer:cc)}
        let before=try bc.journal.outbox(),cursor=try XCTUnwrap(bc.journal.cursor(for:thirdID)),versions=try count(b,"personal_sync_versions")
        XCTAssertEqual(try count(b,"chat_turns"),1)
        // The root retirement succeeds first; rejection of the following owner
        // announcement must roll back both barriers and the incoming receipt.
        try b.withRoutineDatabase {try $0.execute("CREATE TEMP TRIGGER owned_late_owner_reject BEFORE INSERT ON main.personal_sync_outbox WHEN json_extract(CAST(new.revision AS TEXT),'$.key.kind')='turn' BEGIN SELECT RAISE(ABORT,'Owned late owner refusal'); END")}
        XCTAssertThrowsError(try lateGraphPut(citation,packet(citation,cc),retiring:true,store:b,cache:bc,producer:cc)) {XCTAssertTrue($0.localizedDescription.contains("Owned late owner refusal"))}
        XCTAssertEqual(try bc.journal.outbox(),before);XCTAssertEqual(try bc.journal.cursor(for:thirdID),cursor)
        XCTAssertEqual(try count(b,"personal_sync_versions"),versions);XCTAssertEqual(try count(b,"chat_turns"),1)
        XCTAssertFalse(try bc.journal.state(for:turn.key).isDeleted);XCTAssertFalse(try bc.journal.state(for:citation.key).isDeleted)
        try b.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_late_owner_reject")}
        for operation in try cc.journal.outbox(after:cursor) {try lateGraphPut(operation,packet(operation,cc),retiring:operation.key.kind == .conversationCitation,store:b,cache:bc,producer:cc)}
        XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertEqual(try count(b,"chat_sources"),0)
        XCTAssertEqual(Set(try b.chats().map(\.title)),["Owned offline question","Independent after late citation"])
        let announcements=try bc.journal.outbox();XCTAssertEqual(Set(announcements.map(\.key)),Set(operations.filter {[.turn,.conversationCitation,.evidencePin].contains($0.key.kind)}.map(\.key)))
        for barrier in announcements {XCTAssertTrue(barrier.context.contains(citation.dot));XCTAssertTrue(barrier.context.contains(deletion.dot))}
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),5)
    }
    func testLateDerivedRecapRowCannotEraseIndependentNamedSource()throws {
        let thirdID="00000000-0000-0000-0000-000000006157"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        let source=Memory(id:"old-evidence",timestamp:now,kind:.note,app:"Owned stale edge",text:"Owned evidence subsequently erased")
        try a.insert(source);try drain(a,ac);let original=try packet(XCTUnwrap(ac.journal.outbox().first),ac)
        try derivedDeliver(ac,b,bc);try derivedDeliver(ac,c,cc)
        let independent=Memory(id:"independent-plain-note",timestamp:now,kind:.note,app:"Owned independent",text:"Independent note must survive stale derived row")
        try c.insert(independent);try drain(c,cc);try derivedDeliver(cc,b,bc)
        let independentOperation=try XCTUnwrap(cc.journal.outbox().first),owner=try packet(independentOperation,cc).identity
        let identity=try SyncObjectIdentity(table:.recapCitation,origin:thirdID,lifetime:"00000000-0000-0000-0000-000000006158")
        let row=try SyncPortableRecord(identity:identity,body:.recapCitation(.init(owner:owner,ordinal:0,link:.init(source:original.reference,score:1,match:"owned",passage:nil))))
        // This is an authenticated admitted head with its own content hash,
        // rather than a checksum mismatch against a different packet.
        let stale=try cc.journal.put(key:identity.key,content:row.reference.content)
        _=try c.createChat(title:"Independent after stale derived row");try drain(c,cc)
        _=try a.delete(source.id);try drain(a,ac);try receiveDeletion(XCTUnwrap(ac.journal.outbox().last),b,bc)
        try lateGraphPut(stale,row,retiring:true,store:b,cache:bc,producer:cc)
        for operation in try cc.journal.outbox(after:stale.dot.counter) {try lateGraphPut(operation,packet(operation,cc),retiring:false,store:b,cache:bc,producer:cc)}
        XCTAssertFalse(try bc.journal.state(for:independentOperation.key).isDeleted)
        XCTAssertEqual(try b.timelineSample(.init(),limit:10).map(\.text),[independent.text])
        XCTAssertEqual(try b.chats().map(\.title),["Independent after stale derived row"])
        XCTAssertEqual(try bc.journal.outbox().map(\.key),[stale.key]);XCTAssertEqual(try bc.journal.cursor(for:thirdID),3)
    }
}
