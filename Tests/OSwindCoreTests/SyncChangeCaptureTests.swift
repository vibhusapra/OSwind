import XCTest
import CSQLite
@testable import OSwindCore

private final class CaptureTestFailures:@unchecked Sendable {
    private let lock=NSLock();private var value=0
    func append(){lock.lock();value+=1;lock.unlock()}
    var count:Int {lock.lock();defer{lock.unlock()};return value}
}
final class SyncChangeCaptureTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-change-capture-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store.close();store=nil;try FileManager.default.removeItem(at:root)}
    func activate(_ budget:Int64=SyncChangeCapture.defaultQueueBytes)throws->SyncCaptureScope {try store.withRoutineDatabase {try SyncChangeCapture.activate($0,budget:budget)}}
    func changes(_ scope:SyncCaptureScope)throws->[SyncCapturedChange] {try store.withRoutineDatabase {try SyncChangeCapture.changes($0,scope:scope)}}
    func scalar(_ sql:String)throws->Int64 {try store.withRoutineDatabase {db in let s=try db.statement(sql);defer {sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_ROW else {throw db.error()};return sqlite3_column_int64(s,0)}}
    func testDisabledByDefaultAndSchemaFence()throws {
        try store.insert(Memory(id:"owned",text:"no implicit enrollment"));XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_changes"),0)
        XCTAssertEqual(try scalar("PRAGMA user_version"),26);XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_capture_%'"),43)
    }
    func testOrdinaryMutationsRetainCurrentExactSnapshotsAndPurgeSupersededBodies()throws {
        let scope=try activate(),original=Memory(id:"owned",timestamp:Date(timeIntervalSince1970:Double.pi),text:"original")
        try store.insert(original)
        let first=try XCTUnwrap(changes(scope).first)
        XCTAssertEqual(try SyncRowSnapshot.decode(XCTUnwrap(first.afterRow)).cells[1],.real(original.timestamp.timeIntervalSince1970.bitPattern))
        var changed=original;changed.text="updated";try store.insert(changed)
        let updated=try changes(scope);XCTAssertTrue(updated[0].superseded);XCTAssertNil(updated[0].afterRow)
        XCTAssertEqual(try SyncRowSnapshot.decode(XCTUnwrap(updated[1].afterRow)).cells[6],.text(Data("updated".utf8)))
        try store.withRoutineDatabase {try $0.execute("DELETE FROM memories WHERE id='owned'")}
        try store.close();store=try MemoryStore(root:root)
        let items=try changes(scope);XCTAssertEqual(items.count,3);XCTAssertEqual(items.map(\.sequence),[1,2,3])
        XCTAssertTrue(items.allSatisfy {$0.afterRow==nil});XCTAssertTrue(items.prefix(2).allSatisfy(\.superseded));XCTAssertFalse(items[2].superseded)
        XCTAssertTrue(items.allSatisfy {($0.beforeKey?.count ?? 32)==32 && ($0.afterKey?.count ?? 32)==32})
        XCTAssertEqual(try scalar("SELECT used_bytes FROM personal_sync_capture"),Int64(items.reduce(0){$0+$1.bytes}))
    }
    func testAlreadyOpenSecondConnectionAutomaticallyPreparesAfterActivation()throws {
        let other=try MemoryStore(root:root);defer {try? other.close()};let scope=try activate()
        try other.insert(Memory(id:"second",text:"other connection"));XCTAssertEqual(try changes(scope).count,1)
        try other.withRoutineDatabase {db in let s=try db.statement("PRAGMA synchronous");defer {sqlite3_finalize(s)};XCTAssertEqual(sqlite3_step(s),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(s,0),2)}
    }
    func testQueueAndSourceRollBackTogetherIncludingNestedSavepoint()throws {
        enum Stop:Error {case expected}
        let scope=try activate()
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {try store.insert(Memory(id:"rolled",text:"must not commit"));throw Stop.expected}})
        XCTAssertNil(try store.get("rolled"));XCTAssertTrue(try changes(scope).isEmpty);XCTAssertEqual(try scalar("SELECT used_bytes FROM personal_sync_capture"),0)
    }
    func testBudgetRefusesSourceMutationWithoutPartialQueueAndAcknowledgementIsTransactional()throws {
        let scope=try activate(1024);try store.insert(Memory(id:"first",text:"small authored note"));let before=try changes(scope)
        XCTAssertThrowsError(try store.insert(Memory(id:"oversized",text:String(repeating:"owned",count:500))))
        XCTAssertNil(try store.get("oversized"));XCTAssertEqual(try changes(scope),before)
        enum Stop:Error {case expected}
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try SyncChangeCapture.acknowledge(db,scope:scope,through:before.last!.sequence)})
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {try SyncChangeCapture.acknowledge(db,scope:scope,through:before.last!.sequence);throw Stop.expected}})
        XCTAssertEqual(try changes(scope),before)
        try store.withRoutineDatabase {db in try db.transaction {try SyncChangeCapture.acknowledge(db,scope:scope,through:before.last!.sequence)}}
        XCTAssertTrue(try changes(scope).isEmpty);XCTAssertEqual(try scalar("SELECT used_bytes FROM personal_sync_capture"),0)
        try store.insert(Memory(id:"next",text:"next"));XCTAssertGreaterThan(try XCTUnwrap(changes(scope).first).sequence,before.last!.sequence)
    }
    func testRemoteApplySuppressesOnlyItsTransactionAndRollsBackOnFailure()throws {
        enum Stop:Error {case expected}
        let scope=try activate()
        try store.withRoutineDatabase {db in try SyncChangeCapture.withoutEcho(db,scope:scope) {try store.insert(Memory(id:"remote",text:"remote authored fixture"))}}
        XCTAssertTrue(try changes(scope).isEmpty);XCTAssertNotNil(try store.get("remote"))
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try SyncChangeCapture.withoutEcho(db,scope:scope) {try store.insert(Memory(id:"rollback",text:"refused"));throw Stop.expected}})
        XCTAssertNil(try store.get("rollback"));XCTAssertEqual(try scalar("SELECT suppressed FROM personal_sync_capture"),0)
        try store.insert(Memory(id:"local",text:"must be captured"));XCTAssertEqual(try changes(scope).count,1)
    }
    func testEmbeddingOnlyAndNoOpUpdatesDoNotCreateSourceIntents()throws {
        try store.insert(Memory(id:"owned",text:"source"));let scope=try activate()
        try store.withRoutineDatabase {try $0.execute("UPDATE memories SET embedding=x'00000000',embedding_model='fixture' WHERE id='owned'; UPDATE memories SET text=text WHERE id='owned'")}
        XCTAssertTrue(try changes(scope).isEmpty)
    }
    func testRawUnpreparedConnectionCannotSilentlyMissCapture()throws {
        let scope=try activate();var handle:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&handle),SQLITE_OK);let db=RoutineDatabase(handle:try XCTUnwrap(handle));defer {sqlite3_close(handle)}
        XCTAssertThrowsError(try db.execute("INSERT INTO chat_sessions VALUES('raw','raw',1,1)"))
        try SyncChangeCapture.register(on:db);try db.execute("PRAGMA synchronous=NORMAL")
        XCTAssertThrowsError(try db.execute("INSERT INTO chat_sessions VALUES('raw','raw',1,1)"))
        try SyncChangeCapture.prepare(db);try db.execute("INSERT INTO chat_sessions VALUES('raw','raw',1,1)")
        XCTAssertEqual(try changes(scope).count,1)
    }
    func testTamperedOrMissingTriggerRefusesReopenWithoutRepairingIt()throws {
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER sync_capture_memories_insert")};try store.close()
        XCTAssertThrowsError(try MemoryStore(root:root))
    }
    func testEveryCanonicalTableCapturesInsertUpdateAndCascadingDelete()throws {
        // Independent structural fixture, not a claim these raw payloads pass
        // the future typed peer adapter. Public graph operations are tested below.
        let expected:Set<String>=["memories","chat_sessions","chat_turns","chat_sources","recap_sources","routines","routine_runs","memory_entities","entity_aliases","entity_mentions","entity_ignored","entity_project_ignored","text_observation_pins"]
        let scope=try activate()
        for id in ["source","summary","pin-next"] {try store.insert(Memory(id:id,kind:id=="summary" ? .summary:.note,text:"authored structural fixture"))}
        try store.withRoutineDatabase {db in try db.transaction {try db.execute("""
        INSERT INTO chat_sessions VALUES('session','authored title',1,1);
        INSERT INTO chat_turns VALUES('turn','session',1,x'7b7d');
        INSERT INTO chat_sources(turn_id,memory_id,ordinal,score,match,passage_start,passage_length) VALUES('turn','source',0,1,'fixture',NULL,NULL);
        INSERT INTO recap_sources(recap_id,source_id,ordinal,revision,score,match,passage_start,passage_length) VALUES('summary','source',0,'fixture-revision',1,'fixture',NULL,NULL);
        INSERT INTO routines VALUES('routine',1,0,1,x'7b7d');
        INSERT INTO routine_runs VALUES('run','routine',1,1,1,2,'manual','completed','session',NULL,x'7b7d');
        INSERT INTO memory_entities VALUES('entity','project','Authored entity','',1,1),('next-entity','project','Other entity','',1,1);
        INSERT INTO entity_aliases VALUES('entity','project','authored','Authored');
        INSERT INTO entity_mentions VALUES('source','entity','manual','fixture-revision',-1,0,'','manual');
        INSERT INTO entity_ignored VALUES('source','person','ignored');
        INSERT INTO entity_project_ignored VALUES('source','entity');
        """)}}
        let inserted=try changes(scope);XCTAssertEqual(Set(inserted.map(\.table)),expected)
        let last=try XCTUnwrap(inserted.last).sequence
        try store.withRoutineDatabase {db in try db.transaction {try db.execute("""
        UPDATE memories SET favorite=1 WHERE id='source';
        UPDATE chat_sessions SET title='new title' WHERE id='session';
        UPDATE chat_turns SET timestamp=2 WHERE id='turn';
        UPDATE chat_sources SET match='new match' WHERE turn_id='turn';
        UPDATE recap_sources SET match='new match' WHERE recap_id='summary';
        UPDATE routines SET revision=2 WHERE id='routine';
        UPDATE routine_runs SET message='new message' WHERE id='run';
        UPDATE memory_entities SET detail='new detail' WHERE id='entity';
        UPDATE entity_aliases SET label='New label' WHERE entity_id='entity';
        UPDATE entity_mentions SET method='structural-fixture' WHERE memory_id='source';
        UPDATE entity_ignored SET key='new-key' WHERE memory_id='source';
        UPDATE entity_project_ignored SET entity_id='next-entity' WHERE memory_id='source';
        UPDATE text_observation_pins SET memory_id='pin-next' WHERE memory_id='source';
        """)}}
        let updated=try store.withRoutineDatabase {try SyncChangeCapture.changes($0,scope:scope,after:last)}
        XCTAssertEqual(Set(updated.filter {$0.beforeKey != nil && $0.afterKey != nil}.map(\.table)),expected)
        XCTAssertNotEqual(updated.first {$0.table=="entity_ignored"}?.beforeKey,updated.first {$0.table=="entity_ignored"}?.afterKey)
        try store.withRoutineDatabase {db in try db.transaction {try db.execute("DELETE FROM memories; DELETE FROM chat_sessions; DELETE FROM routines; DELETE FROM memory_entities")}}
        let deleted=try changes(scope);XCTAssertEqual(Set(deleted.filter {$0.beforeKey != nil && $0.afterKey==nil}.map(\.table)),expected)
        XCTAssertTrue(deleted.allSatisfy {$0.afterRow==nil})
        XCTAssertEqual(try scalar("SELECT used_bytes FROM personal_sync_capture"),Int64(deleted.reduce(0){$0+$1.bytes}))
    }
    func testPublicSourceDeletionPurgesQueuedSourceChatRecapAndTitleBodies()throws {
        let scope=try activate(),secret="OwnedDeletionCanary7q92"
        let memory=Memory(id:"source",kind:.note,app:"Owned",title:secret,text:secret);try store.insert(memory)
        let chat=try store.createChat(title:secret),answer=Answer(text:secret,sources:[.init(memory:memory,score:1,match:"fixture")],provider:"fixture",duration:0)
        _=try store.appendChatTurn(sessionID:chat.id,question:secret,answer:answer)
        let recap=try store.saveRecap(answer,title:secret)
        XCTAssertTrue(try changes(scope).contains {$0.afterRow?.range(of:Data(secret.utf8)) != nil})
        _=try store.delete(memory.id)
        XCTAssertNil(try store.get(recap.id));XCTAssertTrue(try store.chatTurns(chat.id).isEmpty);XCTAssertEqual(try store.chat(chat.id)?.title,"Conversation")
        XCTAssertTrue(try changes(scope).allSatisfy {$0.afterRow?.range(of:Data(secret.utf8))==nil})
    }
    func testRawUnicodeKeysAreOpaqueDistinctAndCurrentSnapshotsKeepOriginalBytes()throws {
        let scope=try activate()
        for id in ["é","e\u{301}"] {try store.insert(Memory(id:id,text:"owned"))}
        let rows=try changes(scope);XCTAssertEqual(rows.count,2);XCTAssertEqual(Set(rows.compactMap(\.afterKey)).count,2)
        XCTAssertTrue(rows.allSatisfy {$0.afterKey?.count==32})
        XCTAssertEqual(try rows.map {try SyncRowSnapshot.decode(XCTUnwrap($0.afterRow)).cells.first},[.text(Data("é".utf8)),.text(Data("e\u{301}".utf8))])
    }
    func testWithoutEchoRefusesPendingLocalChangesAndReadBudgetsAreBounded()throws {
        let scope=try activate();try store.insert(Memory(id:"local",text:"pending"))
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try SyncChangeCapture.withoutEcho(db,scope:scope) {try store.insert(Memory(id:"remote",text:"must not overwrite pending local state"))}})
        XCTAssertNil(try store.get("remote"))
        XCTAssertThrowsError(try store.withRoutineDatabase {try SyncChangeCapture.changes($0,scope:scope,byteLimit:1)})
        let other=SyncCaptureScope(origin:scope.origin,generation:UUID().uuidString.lowercased())
        XCTAssertThrowsError(try changes(other))
        XCTAssertThrowsError(try store.withRoutineDatabase {try SyncChangeCapture.changes($0,scope:scope,limit:257)})
    }
    func testMissingStateIdentityAndWrongPrimaryDefinitionCannotBeSilentlyRecreated()throws {
        try store.withRoutineDatabase {try $0.execute("DELETE FROM personal_sync_capture")};try store.close()
        XCTAssertThrowsError(try MemoryStore(root:root))
    }

    func testTwoConcurrentConnectionsCommitEverySourceAndIntentOnce()throws {
        let other=try MemoryStore(root:root);defer {try? other.close()}
        let scope=try activate(),stores=[store!,other],failures=CaptureTestFailures()
        DispatchQueue.concurrentPerform(iterations:2) {writer in
            for index in 0..<30 {do {try stores[writer].insert(Memory(id:"writer-\(writer)-\(index)",text:"authored parallel note"))}catch{failures.append()}}
        }
        XCTAssertEqual(failures.count,0);XCTAssertEqual(try store.stats().count,60)
        let rows=try changes(scope);XCTAssertEqual(rows.count,60);XCTAssertEqual(rows.map(\.sequence),(1...60).map(Int64.init))
    }
    func testPrimaryKeyChangesReplaceAndAliasRemovalDoNotLeaveQueuedLabelBodies()throws {
        let scope=try activate(),privateLabel="OwnedAliasErasureCanary4j81"
        try store.withRoutineDatabase {db in
            try db.execute("INSERT INTO memory_entities VALUES('entity','person','Authored','',1,1)")
            let row=try db.statement("INSERT INTO entity_aliases VALUES('entity','person',?,?)");defer {sqlite3_finalize(row)};db.bind(row,1,privateLabel);db.bind(row,2,privateLabel);try db.done(row)
            try db.execute("DELETE FROM entity_aliases; INSERT INTO entity_aliases VALUES('entity','person','replacement','replacement')")
        }
        let rows=try changes(scope);XCTAssertTrue(rows.allSatisfy {$0.afterRow?.range(of:Data(privateLabel.utf8))==nil})
        XCTAssertTrue(rows.filter {$0.table=="entity_aliases"}.allSatisfy {($0.beforeKey?.count ?? 32)==32 && ($0.afterKey?.count ?? 32)==32})
        try store.withRoutineDatabase {try $0.execute("INSERT OR REPLACE INTO memory_entities VALUES('entity','person','Replaced','',1,1)")}
        let replacements=try changes(scope).filter {$0.table=="memory_entities"};XCTAssertTrue(replacements.contains {$0.beforeKey != nil && $0.afterKey==nil})
    }
    func testChangedOrDroppedCanonicalCaptureTriggerRefusesUpgrade()throws {
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER sync_capture_memories_update; CREATE TRIGGER sync_capture_memories_update AFTER UPDATE OF nonexistent ON memories BEGIN SELECT 1; END")}
        try store.close();XCTAssertThrowsError(try MemoryStore(root:root))
    }
    func testReopenPreparesActiveCaptureBeforeRebuildingMissingEvidencePins()throws {
        let memory=Memory(id:"source",text:"owned source");try store.insert(memory)
        let chat=try store.createChat(),answer=Answer(text:"owned answer",sources:[.init(memory:memory,score:1,match:"fixture")],provider:"fixture",duration:0)
        _=try store.appendChatTurn(sessionID:chat.id,question:"owned question",answer:answer)
        let scope=try activate()
        try store.withRoutineDatabase {try $0.execute("DELETE FROM text_observation_pins")};try store.close();store=try MemoryStore(root:root)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM text_observation_pins"),1)
        XCTAssertTrue(try changes(scope).contains {$0.table=="text_observation_pins" && $0.afterRow != nil})
    }

    func testColdPinTableRepairReinstallsOnlyItsMissingHooksAndCapturesRecoveredPins()throws {
        let memory=Memory(id:"source",text:"owned");try store.insert(memory)
        let chat=try store.createChat(),answer=Answer(text:"owned",sources:[.init(memory:memory,score:1,match:"fixture")],provider:"fixture",duration:0)
        _=try store.appendChatTurn(sessionID:chat.id,question:"owned",answer:answer)
        let scope=try activate()
        try store.withRoutineDatabase {try $0.execute("DROP TABLE text_observation_pins")};try store.close();store=try MemoryStore(root:root)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM text_observation_pins"),1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_capture_text_observation_pins_%'"),3)
        XCTAssertEqual(try changes(scope).filter {$0.table=="text_observation_pins" && $0.afterRow != nil}.count,1)
    }

    func testActiveCaptureBackupRestoresQuietlyWithoutReplayingPendingChanges()throws {
        let scope=try activate();try store.insert(Memory(id:"owned",text:"current authored source"))
        let archive=root.appendingPathComponent("../capture-backup-"+UUID().uuidString+".oswindbackup"),restored=root.appendingPathComponent("../capture-restored-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:archive);try? FileManager.default.removeItem(at:restored)}
        let info=try LibraryBackup.create(store:store,destination:archive);XCTAssertEqual(info.sourceSchema,26)
        _=try LibraryBackup.restore(archive,to:restored)
        let copy=try MemoryStore(root:restored);defer {try? copy.close()}
        XCTAssertEqual(try copy.get("owned")?.text,"current authored source")
        try copy.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM personal_sync_changes"),0)
            XCTAssertEqual(try db.eraseCount("SELECT enabled FROM personal_sync_capture WHERE singleton=1"),0)
        }
        XCTAssertEqual(try changes(scope).count,1)
    }
    func testFullWipeLeavesNoQueuedOriginalBodies()throws {
        let scope=try activate(),canary="OwnedWholeWipeCanary8j31"
        try store.insert(Memory(id:"wipe",text:canary));let chat=try store.createChat(title:canary)
        _=try store.appendChatTurn(sessionID:chat.id,question:canary,answer:.init(text:canary,sources:[.init(memory:try XCTUnwrap(store.get("wipe")),score:1,match:"owned")],provider:"fixture",duration:0))
        let result=try store.deleteAll();XCTAssertEqual(result.erasure.sources,1);XCTAssertTrue(result.cleanupComplete)
        XCTAssertTrue(try changes(scope).allSatisfy {$0.afterRow==nil})
        XCTAssertEqual(try store.stats().count,0)
    }

}
