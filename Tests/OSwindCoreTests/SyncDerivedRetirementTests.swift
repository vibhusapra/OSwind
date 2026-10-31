import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func derivedDeliver(_ producer:SyncVersionStore,_ store:MemoryStore,_ cache:SyncVersionStore,after:Int64=0)throws {
        for operation in try producer.journal.outbox(after:after) {
            if operation.mutation == .put {
                let record=try packet(operation,producer)
                _=try receive(operation,record,store,cache,fetch:{ref in try XCTUnwrap(producer.record(ref,admit:{_ in}))})
            }else {try receiveDeletion(operation,store,cache)}
        }
    }
    func testDerivedRetirementSourceDeletionPublishesReceiverOnlyChildrenAndThirdReplicaBarriers()throws {
        let thirdID="00000000-0000-0000-0000-000000006105"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("third",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID);try cc.journal.allowPeer(receiverID)
        let source=Memory(id:"source",timestamp:now,kind:.note,app:"Owned source",text:"ReceiverOnlySourceCanary51");try a.insert(source);try drain(a,ac)
        try derivedDeliver(ac,b,bc);try derivedDeliver(ac,c,cc)
        let sourceID=try ac.catalog.localIdentity(.source,primary:[.text(Data(source.id.utf8))]),local=try XCTUnwrap(bc.catalog.object(sourceID)?.primary)
        guard case .text(let raw)=local[0],let key=String(data:raw,encoding:.utf8) else {return XCTFail("Missing source key")}
        let memory=try XCTUnwrap(b.get(key)),recap=try b.saveRecap(.init(text:"Receiver-only recap",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]),title:"Receiver recap")
        let chat=try b.createChat(title:"Receiver-only answer");_=try b.appendChatTurn(sessionID:chat.id,question:"Who?",answer:.init(text:"Receiver-only answer [1]",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]))
        try b.insert(Memory(id:"independent",timestamp:now,kind:.note,app:"Other",text:"Independent receiver source"));try drain(b,bc)
        let before=try bc.journal.outbox(),through=try XCTUnwrap(before.last).dot.counter
        let children=before.filter { [.source,.recapCitation,.turn,.conversationCitation,.evidencePin].contains($0.key.kind) && $0.key != (try? bc.catalog.localIdentity(.source,primary:[.text(Data("independent".utf8))]).key) }
        XCTAssertEqual(children.count,5)
        try derivedDeliver(bc,c,cc)
        let offlineOwner=try XCTUnwrap(children.first {$0.key.kind == .turn}),offline=try cc.journal.put(key:offlineOwner.key,content:XCTUnwrap(offlineOwner.content))
        _=try a.delete(source.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last)
        try receiveDeletion(deletion,b,bc)
        XCTAssertNil(try b.get(recap.id));XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertNotNil(try b.get("independent"))
        let announcements=try bc.journal.outbox(after:through)
        XCTAssertEqual(Set(announcements.map(\.key)),Set(children.map(\.key)))
        XCTAssertTrue(announcements.allSatisfy {$0.mutation == .delete && $0.content==nil && $0.key != deletion.key})
        for child in children {XCTAssertTrue(try bc.journal.state(for:child.key).isDeleted)}
        XCTAssertTrue(announcements.allSatisfy {($0.context.counters[producerID] ?? 0)>=deletion.dot.counter})
        // Native FK erasure on the third replica is not sufficient: the wire
        // lifetimes must have durable deletion barriers there as well.
        try receiveDeletion(deletion,c,cc);try derivedDeliver(bc,c,cc,after:through)
        for child in children {XCTAssertTrue(try cc.journal.state(for:child.key).isDeleted)}
        XCTAssertEqual(try count(c,"chat_turns"),0);XCTAssertTrue(try cc.journal.outbox(after:offline.dot.counter).allSatisfy {$0.mutation == .delete && Set(children.map(\.key)).contains($0.key)})
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("Late deleted content must not be admitted")},pathsFor:{_,_ in XCTFail("No media download");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        // A late put may advance the causal clock; apply the durable deleted
        // state, never the late body. No missing-content callback is needed.
        XCTAssertEqual(try bc.journal.receive(offline,contentAvailable:{_ in XCTFail("Deleted child needs no content");return false}) {change in
            XCTAssertTrue(change.after.isDeleted);try writer.applyDeletion(change,admission:lease)
        }.applied,1)
        XCTAssertTrue(try bc.journal.state(for:offlineOwner.key).isDeleted);XCTAssertEqual(try count(b,"chat_turns"),0)
        XCTAssertThrowsError(try bc.journal.put(key:offlineOwner.key,content:XCTUnwrap(offlineOwner.content)))
        let again=try bc.journal.receive(deletion,contentAvailable:{_ in true}) {_ in XCTFail("Committed parent retried")}
        XCTAssertEqual(again.applied,0);XCTAssertEqual(try bc.journal.outbox(after:through),announcements)
    }
    func testDerivedRetirementConversationKeepsIndependentSourceAndItsPin()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let chat=try a.createChat(title:"Owned parent conversation");try drain(a,ac);try derivedDeliver(ac,b,bc)
        let identity=try ac.catalog.localIdentity(.conversation,primary:[.text(Data(chat.id.utf8))])
        let native=try XCTUnwrap(b.chats().first),source=Memory(id:"independent",timestamp:now,kind:.note,app:"Other",text:"Independent source")
        try b.insert(source);_=try b.appendChatTurn(sessionID:native.id,question:"Owned child",answer:.init(text:"Owned answer [1]",sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]));try drain(b,bc)
        let before=try bc.journal.outbox(),through=try XCTUnwrap(before.last).dot.counter,children=Set(before.filter {[.turn,.conversationCitation].contains($0.key.kind)}.map(\.key))
        XCTAssertEqual(children.count,2);try a.deleteChat(chat.id);try drain(a,ac);try receiveDeletion(XCTUnwrap(ac.journal.outbox().last),b,bc)
        let announced=try bc.journal.outbox(after:through);XCTAssertEqual(Set(announced.map(\.key)),children);XCTAssertTrue(announced.allSatisfy {$0.mutation == .delete && $0.key != (try? identity.key)})
        XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertNotNil(try b.get(source.id))
        for op in before where op.key.kind == .source || op.key.kind == .evidencePin {XCTAssertFalse(try bc.journal.state(for:op.key).isDeleted)}
    }
    func testDerivedRetirementSourceUpdateRetiresReceiverMentionAndPreservesDefinition()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var source=Memory(id:"source",timestamp:now,kind:.note,app:"Owned update",text:"Mira works on Apollo");try a.insert(source);try drain(a,ac);try derivedDeliver(ac,b,bc)
        let local=try XCTUnwrap(b.timelineSample(.init(),limit:1).first),entity=try b.createEntity(kind:.person,name:"Mira")
        try b.linkEntity(entity.id,to:local.id);try drain(b,bc)
        let before=try bc.journal.outbox(),through=try XCTUnwrap(before.last).dot.counter,mention=try XCTUnwrap(before.first {$0.key.kind == .entityMention})
        source.text="An independent newer source body";try a.insert(source);try drain(a,ac)
        let update=try XCTUnwrap(ac.journal.outbox().last),record=try packet(update,ac)
        _=try receive(update,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        XCTAssertEqual(try b.get(local.id)?.text,source.text);XCTAssertEqual(try count(b,"entity_mentions"),0);XCTAssertNotNil(try b.entity(entity.id))
        let announced=try bc.journal.outbox(after:through);XCTAssertEqual(announced.map(\.key),[mention.key]);XCTAssertTrue(announced.allSatisfy {$0.mutation == .delete})
        XCTAssertTrue(announced.allSatisfy {$0.context.contains(update.dot)},"A derived barrier must observe its admitted root update before the outer receive advances its cursor")
        XCTAssertTrue(try bc.journal.state(for:mention.key).isDeleted);XCTAssertFalse(try bc.journal.state(for:update.key).isDeleted)
        for op in before where op.key.kind == .entity || op.key.kind == .entityAlias {XCTAssertFalse(try bc.journal.state(for:op.key).isDeleted)}
    }
    func testDerivedRetirementRecipeRetiresReceiverRunAndKeepsIndependentConversation()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="recipe";recipe.prompt="Owned prompt";recipe.schedule.timeZone="UTC"
        _=try a.saveRoutine(recipe,now:now);try drain(a,ac);try derivedDeliver(ac,b,bc)
        let local=try XCTUnwrap(b.routines().first?.definition.id),claim=try XCTUnwrap(b.claimRoutine(id:local,now:now));_=try b.finishRoutine(claim.run.id,status:.failed,message:"Owned history")
        let chat=try b.createChat(title:"Independent conversation")
        try b.withRoutineDatabase {db in let row=try db.statement("UPDATE routine_runs SET chat_id=? WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,chat.id);db.bind(row,2,claim.run.id);try db.done(row)}
        try drain(b,bc);let before=try bc.journal.outbox(),through=try XCTUnwrap(before.last).dot.counter,run=try bc.catalog.localIdentity(.routineRun,primary:[.text(Data(claim.run.id.utf8))])
        try a.deleteRoutine(recipe.id);try drain(a,ac);try receiveDeletion(XCTUnwrap(ac.journal.outbox().last),b,bc)
        XCTAssertEqual(try bc.journal.outbox(after:through).map(\.key),[try run.key]);XCTAssertTrue(try bc.journal.state(for:run.key).isDeleted)
        XCTAssertEqual(try b.chats().first?.id,chat.id);XCTAssertEqual(try count(b,"routine_runs"),0)
    }
    func testDerivedRetirementFailureOnSecondAnnouncementRollsBackWholeReceiptThenRetries()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let source=Memory(id:"source",timestamp:now,kind:.note,app:"Owned rollback",text:"Owned atomic deletion");try a.insert(source);try drain(a,ac);try derivedDeliver(ac,b,bc)
        let memory=try XCTUnwrap(b.timelineSample(.init(),limit:1).first),chat=try b.createChat(title:"Receiver child")
        _=try b.appendChatTurn(sessionID:chat.id,question:"Owned question",answer:.init(text:"Owned answer [1]",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]));try drain(b,bc)
        let before=try bc.journal.outbox(),through=try XCTUnwrap(before.last).dot.counter,versions=try count(b,"personal_sync_versions")
        _=try a.delete(source.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last)
        try b.withRoutineDatabase {try $0.execute("CREATE TEMP TRIGGER owned_reject_second_retirement BEFORE INSERT ON main.personal_sync_outbox WHEN new.sequence=\(through+2) BEGIN SELECT RAISE(ABORT,'Owned second announcement refusal'); END")}
        XCTAssertThrowsError(try receiveDeletion(deletion,b,bc)) {XCTAssertTrue($0.localizedDescription.contains("Owned second announcement refusal"))}
        XCTAssertEqual(try bc.journal.outbox(),before);XCTAssertFalse(try bc.journal.state(for:deletion.key).isDeleted)
        XCTAssertNotNil(try b.get(memory.id));XCTAssertEqual(try count(b,"chat_turns"),1);XCTAssertEqual(try count(b,"personal_sync_versions"),versions)
        for op in before {XCTAssertFalse(try bc.journal.state(for:op.key).isDeleted)}
        try b.withRoutineDatabase {try $0.execute("DROP TRIGGER temp.owned_reject_second_retirement")}
        try receiveDeletion(deletion,b,bc);XCTAssertNil(try b.get(memory.id));XCTAssertEqual(try count(b,"chat_turns"),0)
        XCTAssertGreaterThan(try bc.journal.outbox(after:through).count,1)
    }
    func testDerivedRetirementEntityRetiresReceiverMentionAndKeepsItsSource()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let entity=try a.createEntity(kind:.person,name:"Owned person");try drain(a,ac);try derivedDeliver(ac,b,bc)
        let native=try XCTUnwrap(b.entities(kind:.person).first),source=Memory(id:"independent",timestamp:now,kind:.note,app:"Other",text:"Independent source")
        try b.insert(source);try b.linkEntity(native.id,to:source.id);try drain(b,bc)
        let before=try bc.journal.outbox(),through=try XCTUnwrap(before.last).dot.counter,children=before.filter {$0.key.kind == .entityMention},aThrough=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        XCTAssertEqual(children.count,1);try a.deleteEntity(entity.id);try drain(a,ac);try derivedDeliver(ac,b,bc,after:aThrough)
        XCTAssertEqual(try bc.journal.outbox(after:through).map(\.key),children.map(\.key));XCTAssertTrue(try bc.journal.state(for:XCTUnwrap(children.first).key).isDeleted)
        XCTAssertNotNil(try b.get(source.id));XCTAssertEqual(try count(b,"entity_mentions"),0)
        for op in before where op.key.kind == .source {XCTAssertFalse(try bc.journal.state(for:op.key).isDeleted)}
    }
    func testDerivedRetirementUncachedNativeChildKeepsFullNULKeyBytes()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let parent=try a.createChat(title:"Owned parent");try drain(a,ac);try derivedDeliver(ac,b,bc)
        let local=try XCTUnwrap(b.chats().first?.id),independent=try b.createChat(title:"Independent conversation")
        let prefix=try b.appendChatTurn(sessionID:independent.id,question:"Independent",answer:.init(text:"Independent answer",sources:[],provider:"owned",duration:0,warnings:[]));try drain(b,bc)
        let raw=Data((prefix.id+"\0suffix").utf8),identity=try SyncObjectIdentity(table:.turn,origin:bc.catalog.scope.origin,lifetime:UUID().uuidString.lowercased())
        // Authored uncached native row: deletion must use catalog keys without
        // fetching or decoding a missing wire body, including the NUL suffix.
        try bc.catalog.applyPeer(identity,primary:[.text(raw)]) {
            let db=bc.database,row=try db.statement("INSERT INTO chat_turns(id,session_id,timestamp,payload) VALUES(?,?,1,x'7b7d')");defer {sqlite3_finalize(row)}
            raw.withUnsafeBytes {_=sqlite3_bind_text64(row,1,$0.baseAddress?.assumingMemoryBound(to:CChar.self),UInt64(raw.count),db.transient,UInt8(SQLITE_UTF8))};db.bind(row,2,local);try db.done(row)
        }
        let put=try bc.journal.put(key:identity.key,content:.init(data:Data("Uncached authored child".utf8)))
        try a.deleteChat(parent.id);try drain(a,ac);try receiveDeletion(XCTUnwrap(ac.journal.outbox().last),b,bc)
        XCTAssertEqual(try bc.journal.outbox(after:put.dot.counter).map(\.key),[try identity.key]);XCTAssertTrue(try bc.journal.state(for:identity.key).isDeleted)
        XCTAssertEqual(try count(b,"chat_turns"),1);XCTAssertEqual(try b.chatTurns(independent.id).first?.id,prefix.id)
    }
    func testDerivedRetirementTempProtectionInactiveStateAndConnectionLifetime()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let parent=try a.createChat(title:"Owned parent");try drain(a,ac);try derivedDeliver(ac,b,bc)
        try a.deleteChat(parent.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last);try receiveDeletion(deletion,b,bc)
        try b.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name GLOB 'oswind_peer_retirement*'"),0)
            XCTAssertEqual(try db.eraseCount("SELECT active FROM temp.oswind_peer_retirement_state"),0)
            try SyncChangeCapture.transaction(db) {try SyncDerivedRetirement.collect(cache:bc,root:deletion.key,body:{
                XCTAssertThrowsError(try SyncDerivedRetirement.collect(cache:bc,root:deletion.key,body:{XCTFail("Nested collector ran")},retire:{_ in XCTFail("No nested retirement")}))
                XCTAssertEqual(try db.eraseCount("SELECT active FROM temp.oswind_peer_retirement_state"),1)
            },retire:{_ in XCTFail("No derived objects")})}
            XCTAssertEqual(try db.eraseCount("SELECT active FROM temp.oswind_peer_retirement_state"),0)
        }
        let source=Memory(id:"ordinary-local",timestamp:now,kind:.note,app:"Other",text:"Ordinary local source");try b.insert(source);try drain(b,bc);let before=try bc.journal.outbox()
        _=try b.delete(source.id);XCTAssertEqual(try bc.journal.outbox(),before)
        try b.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM temp.oswind_peer_retirements"),0)}
        try drain(b,bc)
        let next=try a.createChat(title:"Guarded parent");try drain(a,ac)
        let put=try XCTUnwrap(ac.journal.outbox().last),record=try packet(put,ac);_=try receive(put,record,b,bc,fetch:{_ in record})
        let protection=try b.withRoutineDatabase {db -> String in
            let row=try db.statement("SELECT sql FROM sqlite_temp_master WHERE name='oswind_peer_retirement_chat_turns'");guard sqlite3_step(row)==SQLITE_ROW else {sqlite3_finalize(row);throw db.error()};let sql=db.text(row,0);sqlite3_finalize(row);try db.execute("DROP TRIGGER temp.oswind_peer_retirement_chat_turns");return sql
        }
        try a.deleteChat(next.id);try drain(a,ac);let guarded=try XCTUnwrap(ac.journal.outbox().last)
        XCTAssertThrowsError(try receiveDeletion(guarded,b,bc));XCTAssertFalse(try bc.journal.state(for:guarded.key).isDeleted);XCTAssertEqual(try count(b,"chat_sessions"),1)
        try b.withRoutineDatabase {try $0.execute(protection.replacingOccurrences(of:"CREATE TRIGGER ",with:"CREATE TEMP TRIGGER "))};try receiveDeletion(guarded,b,bc)
        try b.close();let reopened=try MemoryStore(root:b.root);defer {try? reopened.close()}
        try reopened.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_temp_master WHERE name GLOB 'oswind_peer_retirement*'"),0)}
    }
}
