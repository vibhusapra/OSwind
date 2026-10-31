import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private func deletionDeliver(_ producer:SyncVersionStore,_ receiver:MemoryStore,_ cache:SyncVersionStore,after:Int64=0)throws {
        for operation in try producer.journal.outbox(after:after) {
            if operation.mutation == .put {let record=try packet(operation,producer);_=try receive(operation,record,receiver,cache,fetch:{ref in try XCTUnwrap(producer.record(ref,admit:{_ in}))})}
            else {try receiveDeletion(operation,receiver,cache)}
        }
    }
    private func deletionSQL(_ store:MemoryStore,_ sql:String,_ value:String)throws {
        try store.withRoutineDatabase {db in let row=try db.statement(sql);defer {sqlite3_finalize(row)};db.bind(row,1,value);try db.done(row)}
    }
    func testIncomingDeletionConversationAndTurnCascadesKeepIndependentSources()throws {
        for target in ["conversation","turn","citation"] {
            let (a,ac)=try endpoint("producer-"+target,producerID),(b,bc)=try endpoint("receiver-"+target,receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
            let memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned deletion fixture",text:"Mira owns Apollo.");try a.insert(memory)
            let chat=try a.createChat(title:"Owned answer"),turn=try a.appendChatTurn(sessionID:chat.id,question:"Who owns Apollo?",answer:.init(text:"Mira [1]",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]))
            try drain(a,ac);try deletionDeliver(ac,b,bc);let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
            XCTAssertEqual(try count(b,"historical_evidence"),1)
            if target=="conversation" {try a.deleteChat(chat.id)}
            else if target=="turn" {try deletionSQL(a,"DELETE FROM chat_turns WHERE id=?",turn.id)}
            else {try deletionSQL(a,"DELETE FROM chat_sources WHERE turn_id=?",turn.id)}
            try drain(a,ac);try deletionDeliver(ac,b,bc,after:through)
            XCTAssertEqual(try count(b,"chat_sessions"),target=="conversation" ? 0:1)
            XCTAssertEqual(try count(b,"chat_turns"),target=="citation" ? 1:0);XCTAssertEqual(try count(b,"chat_sources"),0)
            XCTAssertEqual(try count(b,"memories"),1);XCTAssertEqual(try count(b,"historical_evidence"),1)
            XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
        }
    }
    func testIncomingDeletionRecipeAndRunPurgeOriginalsWithoutDeletingIndependentConversation()throws {
        for target in ["recipe","run"] {
            let (a,ac)=try endpoint("producer-"+target,producerID),(b,bc)=try endpoint("receiver-"+target,receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
            var recipe=RoutineDefinition();recipe.id="recipe";recipe.prompt="Owned exact prompt";recipe.schedule.timeZone="UTC"
            _=try a.saveRoutine(recipe,now:now);let claim=try XCTUnwrap(a.claimRoutine(id:recipe.id,now:now));_=try a.finishRoutine(claim.run.id,status:.failed,message:"Owned failure")
            try drain(a,ac);try deletionDeliver(ac,b,bc);let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
            let chat=try b.createChat(title:"Independent receiver conversation"),localRecipe=try XCTUnwrap(b.routines().first?.definition.id)
            if target=="recipe" {
                let local=try XCTUnwrap(b.claimRoutine(id:localRecipe,now:now.addingTimeInterval(60)));_=try b.finishRoutine(local.run.id,status:.failed,message:"Receiver local history")
                try b.withRoutineDatabase {db in let row=try db.statement("UPDATE routine_runs SET chat_id=? WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,chat.id);db.bind(row,2,local.run.id);try db.done(row)}
            }
            try drain(b,bc);let before=try bc.journal.outbox();XCTAssertEqual(try count(b,"routine_run_originals"),1)
            if target=="recipe" {try a.deleteRoutine(recipe.id)}else{try deletionSQL(a,"DELETE FROM routine_runs WHERE id=?",claim.run.id)}
            try drain(a,ac);try deletionDeliver(ac,b,bc,after:through)
            XCTAssertEqual(try count(b,"routines"),target=="recipe" ? 0:1);XCTAssertEqual(try count(b,"routine_runs"),0);XCTAssertEqual(try count(b,"routine_run_originals"),0)
            XCTAssertEqual(try b.chats().first?.id,chat.id)
            let after=try bc.journal.outbox();XCTAssertEqual(Array(after.prefix(before.count)),before)
            // A future graph-epoch layer may publish genuine derived child
            // tombstones; it must never echo the peer recipe or delete the chat.
            XCTAssertTrue(after.dropFirst(before.count).allSatisfy {$0.mutation == .delete && $0.key.kind == .routineRun})
            XCTAssertEqual(try count(b,"personal_sync_changes"),0)
        }
    }
    func testIncomingDeletionEvidencePinKeepsItsSourceAndOriginalWireHead()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var memory=Memory(id:"source",timestamp:now,endTimestamp:now.addingTimeInterval(2),kind:.screen,app:"Owned sampled text",text:"Owned sample",display:AccessibilityCaptureRecord.display)
        memory.textObservation = .init(sessionID:"00000000-0000-0000-0000-000000006112",samples:2,largestGapSeconds:2);try a.insert(memory);try a.withRoutineDatabase {try $0.pinTextObservation(memory)}
        try drain(a,ac);try deletionDeliver(ac,b,bc);let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter,sourceIdentity=try ac.catalog.localIdentity(.source,primary:[.text(Data(memory.id.utf8))]),source=try bc.resolve(sourceIdentity,content:nil,admit:{_ in})
        XCTAssertEqual(try count(b,"text_observation_pins"),1)
        try deletionSQL(a,"DELETE FROM text_observation_pins WHERE memory_id=?",memory.id);try drain(a,ac);try deletionDeliver(ac,b,bc,after:through)
        XCTAssertEqual(try count(b,"text_observation_pins"),0);XCTAssertEqual(try count(b,"memories"),1);XCTAssertEqual(try bc.resolve(sourceIdentity,content:nil,admit:{_ in}),source)
        XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }
    func testIncomingDeletionUnknownKeysAcrossAllCanonicalKindsNeedNoBodyOrNativeOwner()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        for table in SyncCanonicalTable.allCases {
            let identity=try SyncObjectIdentity(table:table,origin:producerID,lifetime:UUID().uuidString.lowercased()),operation=try ac.journal.delete(key:identity.key)
            try receiveDeletion(operation,b,bc);XCTAssertTrue(try bc.journal.state(for:identity.key).isDeleted);XCTAssertNil(try bc.catalog.object(identity))
        }
        for table in SyncCanonicalTable.allCases {XCTAssertEqual(try count(b,table.rawValue),0)};XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }
    func testIncomingDeletionDamagedProtectionRollsBackReceiptAndCanRetryAfterExactRepair()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let chat=try a.createChat(title:"Owned guarded deletion");try drain(a,ac);try deletionDeliver(ac,b,bc)
        let identity=try ac.catalog.localIdentity(.conversation,primary:[.text(Data(chat.id.utf8))]),before=try bc.resolve(identity,content:nil,admit:{_ in}),through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        try a.deleteChat(chat.id);try drain(a,ac);let operation=try XCTUnwrap(ac.journal.outbox(after:through).first),lease=try b.mediaWriteLease();defer {lease.release()}
        let sql=try b.withRoutineDatabase {db -> String in let row=try db.statement("SELECT sql FROM sqlite_master WHERE name='sync_versions_chat_sessions_delete'");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return db.text(row,0)}
        try b.withRoutineDatabase {try $0.execute("DROP TRIGGER sync_versions_chat_sessions_delete")}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("A tombstone must not fetch or admit a deleted body")},pathsFor:{_,_ in XCTFail("A metadata tombstone has no media");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {try writer.applyDeletion($0,admission:lease)})
        XCTAssertFalse(try bc.journal.state(for:identity.key).isDeleted);XCTAssertEqual(try count(b,"chat_sessions"),1);XCTAssertFalse(try XCTUnwrap(bc.catalog.object(identity)).deleted)
        try b.withRoutineDatabase {try $0.execute(sql)};XCTAssertEqual(try bc.resolve(identity,content:nil,admit:{_ in}),before)
        let receipt=try bc.journal.receive(operation,contentAvailable:{_ in true}) {try writer.applyDeletion($0,admission:lease)};XCTAssertEqual(receipt.applied,1)
        XCTAssertEqual(try count(b,"chat_sessions"),0);XCTAssertTrue(try bc.journal.state(for:identity.key).isDeleted);XCTAssertTrue(try bc.journal.outbox().isEmpty)
        let duplicate=try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in XCTFail("Committed tombstone retried its adapter")};XCTAssertEqual(duplicate.applied,0)
    }
    func testIncomingDeletionUsesCompleteNativeKeyBytesWithoutRequiringCachedBody()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let chat=try a.createChat(title:"Owned byte-key metadata"),bytes=Data("prefix\0suffix".utf8);try drain(a,ac)
        let put=try XCTUnwrap(ac.journal.outbox().first),record=try packet(put,ac)
        try b.withRoutineDatabase {db in try SyncChangeCapture.withoutEcho(db,scope:bc.catalog.scope) {try db.execute("INSERT INTO chat_sessions VALUES('prefix','Independent prefix',1,1)")}}
        let first=try bc.journal.receive(put,contentAvailable:{_ in true}) {_ in
            try bc.catalog.applyPeer(record.identity,primary:[.text(bytes)]) {
                let db=bc.database,row=try db.statement("INSERT INTO chat_sessions VALUES(?,'Owned exact bytes',1,1)");defer {sqlite3_finalize(row)}
                bytes.withUnsafeBytes {_=sqlite3_bind_text64(row,1,$0.baseAddress?.assumingMemoryBound(to:CChar.self),UInt64(bytes.count),db.transient,UInt8(SQLITE_UTF8))};try db.done(row)
            }
        };XCTAssertEqual(first.applied,1);XCTAssertEqual(try count(b,"personal_sync_versions"),0);XCTAssertEqual(try count(b,"chat_sessions"),2)
        try a.deleteChat(chat.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox(after:put.dot.counter).first);try receiveDeletion(deletion,b,bc)
        XCTAssertEqual(try count(b,"chat_sessions"),1);XCTAssertEqual(try b.chat("prefix")?.title,"Independent prefix");XCTAssertTrue(try XCTUnwrap(bc.catalog.object(record.identity)).deleted)
        XCTAssertEqual(try count(b,"personal_sync_versions"),0);XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }

    func testIncomingDeletionForeignReleasedAndWrongConnectionAdmissionPreserveOwnerAndReceipt()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(other,oc)=try endpoint("foreign",UUID().uuidString.lowercased());defer {try? a.close();try? b.close();try? other.close()};try bc.journal.allowPeer(producerID)
        let chat=try a.createChat(title:"Owned lease guarded chat");try drain(a,ac);try deletionDeliver(ac,b,bc)
        try a.deleteChat(chat.id);try drain(a,ac);let operation=try XCTUnwrap(ac.journal.outbox().last),own=try b.mediaWriteLease(),foreign=try other.mediaWriteLease(),released=try b.mediaWriteLease();released.release();defer {own.release();foreign.release()}
        let regular=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("No deleted body")},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in}),wrong=SyncIncomingConversationWriter(library:b,cache:oc,admit:{_ in XCTFail("No deleted body")},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        for (writer,lease) in [(regular,foreign),(regular,released),(wrong,own)] {
            XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {try writer.applyDeletion($0,admission:lease)})
            XCTAssertFalse(try bc.journal.state(for:operation.key).isDeleted);XCTAssertEqual(try count(b,"chat_sessions"),1);XCTAssertTrue(try bc.journal.outbox().isEmpty)
        }
        try receiveDeletion(operation,b,bc);XCTAssertEqual(try count(b,"chat_sessions"),0);XCTAssertEqual(try count(other,"chat_sessions"),0)
    }
    func testIncomingDeletionDirectOldRetirementCannotDeleteReplacementAtSameNativeKey()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let first=try a.createChat(title:"First lifetime");try drain(a,ac);let put=try XCTUnwrap(ac.journal.outbox().last),record=try packet(put,ac),lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in},newID:{_ in "reused-native-key"})
        _=try bc.journal.receive(put,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("No dependencies")})}
        try a.deleteChat(first.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last);var old:SyncJournalChange?
        _=try bc.journal.receive(deletion,contentAvailable:{_ in true}) {change in old=change;try writer.applyDeletion(change,admission:lease)}
        _=try a.createChat(title:"Replacement lifetime");try drain(a,ac);let replacement=try XCTUnwrap(ac.journal.outbox().last),body=try packet(replacement,ac)
        _=try bc.journal.receive(replacement,contentAvailable:{_ in true}) {_ in _=try writer.apply(body,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("No dependencies")})}
        try writer.applyDeletion(XCTUnwrap(old),admission:lease)
        XCTAssertEqual(try b.chat("reused-native-key")?.title,"Replacement lifetime");XCTAssertEqual(try count(b,"chat_sessions"),1);XCTAssertEqual(try bc.resolve(body.identity,content:nil,admit:{_ in}),body);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }

}
