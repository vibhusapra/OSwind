import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private var erasureImage:Data {Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM3sAAAAASUVORK5CYII=")!}
    private func sourceEraseDeliver(_ producer:SyncVersionStore,_ store:MemoryStore,_ cache:SyncVersionStore,after:Int64=0,media:[SyncMediaRole:String]=[:])throws {
        for op in try producer.journal.outbox(after:after) {
            if op.mutation == .put {let record=try packet(op,producer);_=try receive(op,record,store,cache,media:media,fetch:{ref in try XCTUnwrap(producer.record(ref,admit:{_ in}))})}
            else {try receiveDeletion(op,store,cache)}
        }
    }
    func testIncomingSourceErasureRemovesCurrentOriginalsRecapsAnswersAndQueuesMediaUntilAfterCommit()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try erasureImage.write(to:a.root.appendingPathComponent("images/owned.png"));try erasureImage.write(to:b.root.appendingPathComponent("images/received.png"))
        var memory=Memory(id:"source",timestamp:now,kind:.screen,app:"Owned erasure",text:"OwnedOriginalCanary41 Mira owns Apollo",imagePath:"images/owned.png");try a.insert(memory);try drain(a,ac)
        let first=try XCTUnwrap(ac.journal.outbox().last),old=try packet(first,ac),local=try receive(first,old,b,bc,media:[.image:"images/received.png"],fetch:{_ in old}),native=try XCTUnwrap(b.get(local))
        let recap=try b.saveRecap(.init(text:"Owned recap from original",sources:[.init(memory:native,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]),title:"Owned recap")
        let chat=try b.createChat(title:"Owned original answer");_=try b.appendChatTurn(sessionID:chat.id,question:"Who owned Apollo?",answer:.init(text:"Mira [1]",sources:[.init(memory:native,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]));try b.insert(Memory(id:"independent",timestamp:now,kind:.note,app:"Other",text:"Independent source"));try drain(b,bc)
        memory.text="OwnedNewerCanary42 Bob owns Apollo";try a.insert(memory);try drain(a,ac);let update=try XCTUnwrap(ac.journal.outbox().last),new=try packet(update,ac)
        _=try receive(update,new,b,bc,media:[.image:"images/received.png"],fetch:{ref in guard try ref==old.reference else {throw OSwindError.invalid("Unexpected source version")};return old})
        let original=try XCTUnwrap(b.recapEvidence(recap.id).first?.memory),handle=try XCTUnwrap(original.originalEvidence?.handle)
        XCTAssertGreaterThan(try count(b,"historical_evidence"),0);let before=try bc.journal.outbox(),through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        _=try a.delete(memory.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox(after:through).first {$0.key.kind == .source}),lease=try b.mediaWriteLease()
        do {
            defer {lease.release()}
            let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("Source tombstone must not fetch a deleted body")},pathsFor:{_,_ in XCTFail("No incoming media download");return [:]},admitMedia:{_,_,_ in XCTFail("No incoming media")})
            let receipt=try bc.journal.receive(deletion,contentAvailable:{_ in true}) {try writer.applyDeletion($0,admission:lease)};XCTAssertEqual(receipt.applied,1)
            XCTAssertNil(try b.get(local));XCTAssertNil(try b.get(recap.id));XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertEqual(try count(b,"historical_evidence"),0)
            XCTAssertThrowsError(try b.historicalMemory(handle));XCTAssertNotNil(try b.get("independent"));XCTAssertTrue(FileManager.default.fileExists(atPath:b.root.appendingPathComponent("images/received.png").path));XCTAssertGreaterThan(try count(b,"erasure_assets"),0)
            XCTAssertEqual(try b.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM personal_sync_versions WHERE instr(CAST(body AS TEXT),'OwnedOriginalCanary41')>0 OR instr(CAST(body AS TEXT),'OwnedNewerCanary42')>0")},0)
        }
        let cleanup=b.retryErasureCleanup();XCTAssertEqual(cleanup.pendingMedia,0);XCTAssertFalse(FileManager.default.fileExists(atPath:b.root.appendingPathComponent("images/received.png").path));let after=try bc.journal.outbox();XCTAssertEqual(Array(after.prefix(before.count)),before)
        let independent=try bc.catalog.localIdentity(.source,primary:[.text(Data("independent".utf8))]),independentKey=try independent.key
        let children=Set(before.filter {[.source,.recapCitation,.turn,.conversationCitation,.evidencePin].contains($0.key.kind) && $0.key != independentKey}.map(\.key))
        XCTAssertEqual(Set(after.dropFirst(before.count).map(\.key)),children)
        XCTAssertTrue(after.dropFirst(before.count).allSatisfy {$0.mutation == .delete && $0.key != deletion.key})
        XCTAssertFalse(try bc.journal.state(for:independentKey).isDeleted)
        let duplicate=try bc.journal.receive(deletion,contentAvailable:{_ in true}) {_ in XCTFail("Committed erasure ran again")};XCTAssertEqual(duplicate.applied,0)
    }
    func testIncomingSourceErasurePreservesSharedAssetUntilItsIndependentOwnerIsDeleted()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try erasureImage.write(to:a.root.appendingPathComponent("images/owned.png"));try erasureImage.write(to:b.root.appendingPathComponent("images/shared.png"))
        let memory=Memory(id:"source",timestamp:now,kind:.screen,app:"Owned",text:"Owned source",imagePath:"images/owned.png");try a.insert(memory);try drain(a,ac);try sourceEraseDeliver(ac,b,bc,media:[.image:"images/shared.png"])
        try b.insert(Memory(id:"independent",timestamp:now,kind:.screen,app:"Independent",text:"Independent asset owner",imagePath:"images/shared.png"));try drain(b,bc)
        let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter;_=try a.delete(memory.id);try drain(a,ac);try sourceEraseDeliver(ac,b,bc,after:through)
        let cleanup=b.retryErasureCleanup();XCTAssertEqual(cleanup.pendingMedia,0);XCTAssertGreaterThan(cleanup.sharedMedia,0);XCTAssertTrue(FileManager.default.fileExists(atPath:b.root.appendingPathComponent("images/shared.png").path));XCTAssertNotNil(try b.get("independent"))
        _=try b.delete("independent");XCTAssertFalse(FileManager.default.fileExists(atPath:b.root.appendingPathComponent("images/shared.png").path))
    }
    func testIncomingSourceErasureKeepsIndependentUncuratedEntityForDeferredOtherSource()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let one=Memory(id:"one",timestamp:now,kind:.note,app:"Owned",text:"Mira"),two=Memory(id:"two",timestamp:now,kind:.note,app:"Owned",text:"Mira")
        for memory in [one,two] {try a.insert(memory);try a.saveEntityExtraction(memory:memory,plan:a.entityIndexPlan(),result:.init(candidates:[.init(kind:.person,name:"Mira",start:0,length:4)]))};try drain(a,ac)
        let other=try ac.catalog.localIdentity(.source,primary:[.text(Data(two.id.utf8))]);var deferred=[SyncPortableRecord](),entity:SyncPortableRecord?
        for op in try ac.journal.outbox() {
            let record=try packet(op,ac);var later=false
            if case .source=record.body {later=record.identity==other};if case .entityMention(let link)=record.body {later=link.source.identity==other}
            if later {XCTAssertEqual(try bc.journal.receive(op,contentAvailable:{_ in true}) {_ in}.applied,1);deferred.append(record)}
            else {_=try receive(op,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}
            if case .entity=record.body {entity=record}
        }
        let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter;_=try a.delete(one.id);try drain(a,ac)
        for op in try ac.journal.outbox(after:through) {
            if op.key.kind == .entityMention {XCTAssertEqual(try bc.journal.receive(op,contentAvailable:{_ in true}) {_ in}.applied,1)}else{try receiveDeletion(op,b,bc)}
        }
        let wire=try XCTUnwrap(entity);XCTAssertEqual(try count(b,"memories"),0);XCTAssertEqual(try count(b,"memory_entities"),1);XCTAssertEqual(try count(b,"entity_aliases"),1);XCTAssertEqual(try count(b,"entity_mentions"),0);XCTAssertEqual(try bc.resolve(wire.identity,content:nil,admit:{_ in}),wire)
        let lease=try b.mediaWriteLease();defer {lease.release()};let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        for record in deferred {_=try writer.apply(record,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}
        XCTAssertEqual(try b.entities(kind:.person).first?.sourceCount,1);XCTAssertEqual(try count(b,"memories"),1);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }
    func testIncomingSourceErasureStagesCacheOnlyOriginalMediaBeforeProjectionRemoval()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        for name in ["current","cache-only"] {try erasureImage.write(to:b.root.appendingPathComponent("images/"+name+".png"))};try erasureImage.write(to:a.root.appendingPathComponent("images/owned.png"))
        let memory=Memory(id:"source",timestamp:now,kind:.screen,app:"Owned cache-only",text:"CacheOnlyErasureCanary43",imagePath:"images/owned.png");try a.insert(memory);try drain(a,ac)
        let put=try XCTUnwrap(ac.journal.outbox().last),record=try packet(put,ac);_=try receive(put,record,b,bc,media:[.image:"images/current.png"],fetch:{_ in record})
        let originals=try SyncOriginalEvidenceStore.install(cache:bc),original=try originals.prepare(record.reference,pathsFor:{_,_ in [.image:"images/cache-only.png"]},admit:{_ in},admitMedia:{_,_,_ in})
        XCTAssertEqual(try count(b,"personal_sync_evidence"),1);XCTAssertEqual(try count(b,"historical_evidence"),0)
        _=try a.delete(memory.id);try drain(a,ac);try receiveDeletion(XCTUnwrap(ac.journal.outbox().last),b,bc)
        XCTAssertEqual(try count(b,"personal_sync_evidence"),0);XCTAssertEqual(try count(b,"personal_sync_versions"),0);XCTAssertEqual(try count(b,"erasure_assets"),2)
        XCTAssertThrowsError(try originals.read(original.handle,admit:{_ in},admitMedia:{_,_,_ in}));XCTAssertEqual(b.retryErasureCleanup().pendingMedia,0)
        for name in ["current","cache-only"] {XCTAssertFalse(FileManager.default.fileExists(atPath:b.root.appendingPathComponent("images/"+name+".png").path))}
        XCTAssertEqual(try b.withRoutineDatabase {try $0.eraseCount("SELECT oswind_incoming_source_erasure_v1()")},0)
    }
    func testIncomingSourceErasureFindsInactiveLifetimeOriginalsWithoutErasingReusedNativeOwner()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned inactive lifetime",text:"InactiveOriginalCanary44");try a.insert(memory);try drain(a,ac)
        let put=try XCTUnwrap(ac.journal.outbox().last),record=try packet(put,ac),local=try receive(put,record,b,bc,fetch:{_ in record})
        let original=try b.withRoutineDatabase {db in try HistoricalEvidenceStore(database:db).adopt(record.reference,cache:bc,pathsFor:{_,_ in [:]},admit:{_ in},verifyMedia:{_,_,_ in})}
        // Authored partial-restoration state: retired opaque mapping, retained
        // original/cache data, and a replacement lifetime at the same local key.
        try b.withRoutineDatabase {db in let row=try db.statement("UPDATE personal_sync_identities SET deleted=1,key_frame=NULL WHERE object_digest=?");defer {sqlite3_finalize(row)};db.bind(row,1,try record.identity.key.digest);try db.done(row)}
        let replacement=try SyncObjectIdentity(table:.source,origin:bc.catalog.scope.origin,lifetime:UUID().uuidString.lowercased());var current=try XCTUnwrap(b.get(local));current.text="IndependentReplacementCanary45"
        try bc.catalog.applyPeer(replacement,primary:[.text(Data(local.utf8))]) {try b.insertIncomingSource(current)}
        XCTAssertEqual(try b.historicalMemory(original.handle).text,memory.text)
        _=try a.delete(memory.id);try drain(a,ac);try receiveDeletion(XCTUnwrap(ac.journal.outbox().last),b,bc)
        XCTAssertEqual(try b.get(local)?.text,current.text);XCTAssertEqual(try bc.catalog.localIdentity(.source,primary:[.text(Data(local.utf8))]),replacement)
        XCTAssertEqual(try count(b,"historical_evidence"),0);XCTAssertThrowsError(try b.historicalMemory(original.handle));XCTAssertEqual(try count(b,"personal_sync_versions"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }

    func testIncomingSourceErasureInvalidLeaseAndDamagedGuardRollbackThenRetry()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned retry",text:"Owned source retry canary");try a.insert(memory);try drain(a,ac)
        let put=try XCTUnwrap(ac.journal.outbox().last),record=try packet(put,ac),local=try receive(put,record,b,bc,fetch:{_ in record})
        _=try a.delete(memory.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last),own=try b.mediaWriteLease(),foreign=try a.mediaWriteLease(),released=try b.mediaWriteLease();released.release();defer {own.release();foreign.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("No deleted body")},pathsFor:{_,_ in XCTFail("No media download");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        for lease in [foreign,released] {
            XCTAssertThrowsError(try bc.journal.receive(deletion,contentAvailable:{_ in true}) {try writer.applyDeletion($0,admission:lease)})
            XCTAssertNotNil(try b.get(local));XCTAssertFalse(try bc.journal.state(for:deletion.key).isDeleted)
        }
        try b.withRoutineDatabase {try $0.execute("DROP TRIGGER source_erasure_writer_memories_delete")}
        XCTAssertThrowsError(try bc.journal.receive(deletion,contentAvailable:{_ in true}) {try writer.applyDeletion($0,admission:own)})
        XCTAssertNotNil(try b.get(local));XCTAssertFalse(try bc.journal.state(for:deletion.key).isDeleted);XCTAssertFalse(try XCTUnwrap(bc.catalog.object(record.identity)).deleted)
        try b.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT oswind_incoming_source_erasure_v1()"),0)
            try db.execute(SyncIncomingSourceErasureSchema.schemas["source_erasure_writer_memories_delete"]!)
        }
        XCTAssertEqual(try bc.resolve(record.identity,content:nil,admit:{_ in}),record)
        XCTAssertEqual(try bc.journal.receive(deletion,contentAvailable:{_ in true}) {try writer.applyDeletion($0,admission:own)}.applied,1)
        XCTAssertNil(try b.get(local));XCTAssertEqual(try count(b,"personal_sync_versions"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }

    func testIncomingSourceErasureRemovesCachedCitingAnswerWhenNativeCitationProjectionDiffers()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned cached answer",text:"CachedCitationSourceCanary46");try a.insert(memory)
        let chat=try a.createChat(title:"Private derived answer"),turn=try a.appendChatTurn(sessionID:chat.id,question:"CachedCitationQuestionCanary47",answer:.init(text:"CachedCitationAnswerCanary48 [1]",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]));try drain(a,ac)
        var citation:SyncPortableRecord?
        for op in try ac.journal.outbox() {let record=try packet(op,ac);_=try receive(op,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))});if case .conversationCitation=record.body {citation=record}}
        let oldCitation=try XCTUnwrap(citation),turnIdentity=try ac.catalog.localIdentity(.turn,primary:[.text(Data(turn.id.utf8))]),nativeTurn=try XCTUnwrap(bc.catalog.object(turnIdentity)?.primary)
        guard case .text(let key)=nativeTurn[0],let local=String(data:key,encoding:.utf8) else {return XCTFail("Missing turn")}
        try b.insert(Memory(id:"independent",timestamp:now,kind:.note,app:"Independent",text:"Independent source"));try drain(b,bc)
        // Authored partial projection: native citation no longer names the
        // target, but a valid admitted wire head still does. The answer body
        // must not escape erasure merely because these layers disagree.
        try b.withRoutineDatabase {db in try SyncChangeCapture.withoutEcho(db,scope:bc.catalog.scope) {let row=try db.statement("UPDATE chat_sources SET memory_id='independent',owner_id=NULL,historical_handle=NULL WHERE turn_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,local);try db.done(row)}}
        _=try bc.retain(oldCitation,admit:{_ in})
        let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter;_=try a.delete(memory.id);try drain(a,ac)
        for op in try ac.journal.outbox(after:through) {if op.key.kind == .source {try receiveDeletion(op,b,bc)}else{XCTAssertEqual(try bc.journal.receive(op,contentAvailable:{_ in true}) {_ in}.applied,1)}}
        XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertNotNil(try b.get("independent"))
        XCTAssertEqual(try b.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM personal_sync_versions WHERE instr(CAST(body AS TEXT),'CachedCitationQuestionCanary47')>0 OR instr(CAST(body AS TEXT),'CachedCitationAnswerCanary48')>0")},0)
    }

}
