import XCTest
import CSQLite
@testable import OSwindCore

final class NativeEntityScopeRetirementTests:XCTestCase {
    private var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-scope-retirement-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try? store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    private func derived(_ id:String="source")throws->(Memory,MemoryEntity) {
        let memory=Memory(id:id,kind:.note,app:"Owned",text:"Maya Chen owns Apollo Launch.");try store.insert(memory)
        try store.saveEntityExtraction(memory:memory,plan:store.entityIndexPlan(),result:.init(candidates:[.init(kind:.person,name:"Maya Chen",start:0,length:9)]))
        return (memory,try XCTUnwrap(store.entities(kind:.person).first))
    }
    private func history(_ entity:String)throws->String {
        let chat=try store.createChat(title:"Owned saved answer")
        _=try store.appendChatTurn(sessionID:chat.id,question:"Where is Cafe\u{301}? 👩🏽‍💻",answer:.init(text:"Exact answer e\u{301} / 👩🏽‍💻",sources:[],provider:"owned",duration:1.25),filter:.init(app:"Owned",entityID:entity))
        return chat.id
    }
    private func check(_ chat:String,active:String?=nil)throws {
        let turn=try XCTUnwrap(store.chatTurns(chat).first)
        XCTAssertEqual(Data(turn.question.utf8),Data("Where is Cafe\u{301}? 👩🏽‍💻".utf8));XCTAssertEqual(Data(turn.answer.text.utf8),Data("Exact answer e\u{301} / 👩🏽‍💻".utf8))
        XCTAssertEqual(turn.answer.provider,"owned");XCTAssertEqual(turn.answer.duration,1.25);XCTAssertEqual(turn.filter.app,"Owned");XCTAssertEqual(turn.filter.entityID,active)
        if active==nil {XCTAssertNotNil(turn.filter.unavailableEntityScope);XCTAssertThrowsError(try store.search(turn.filter,mode:.keyword))}
        else {XCTAssertNil(turn.filter.unavailableEntityScope)}
    }
    func testExplicitDeletionPreservesAnswerAndUnavailableScopeAcrossRestart()throws {
        let entity=try store.createEntity(kind:.project,name:"Owned project"),chat=try history(entity.id)
        try store.deleteEntity(entity.id);try check(chat);try store.close();store=try MemoryStore(root:root);try check(chat)
    }
    func testMergeDoesNotSilentlyRetargetSavedScopeToSurvivor()throws {
        let from=try store.createEntity(kind:.person,name:"M. Chen"),to=try store.createEntity(kind:.person,name:"Maya Chen"),chat=try history(from.id),control=try history(to.id)
        try store.mergeEntity(from.id,into:to.id);try check(chat);try check(control,active:to.id)
    }
    func testUnlinkingLastSuggestedMentionRetiresScope()throws {
        let (memory,entity)=try derived(),chat=try history(entity.id)
        try store.unlinkEntity(entity.id,from:memory.id);XCTAssertNil(try store.entity(entity.id));try check(chat)
    }
    func testReplacingExtractionRetiresOnlyActuallyPrunedDefinition()throws {
        let (memory,entity)=try derived(),chat=try history(entity.id)
        try store.saveEntityExtraction(memory:memory,plan:store.entityIndexPlan(),result:.init(candidates:[]));XCTAssertNil(try store.entity(entity.id));try check(chat)
    }
    func testSourceRevisionRetiresLastSuggestedScope()throws {
        var (memory,entity)=try derived();let chat=try history(entity.id)
        memory.text="Different content";try store.insert(memory);XCTAssertNil(try store.entity(entity.id));try check(chat)
    }
    func testDeletingLastSourceRetiresScopeWithoutDeletingIndependentAnswer()throws {
        let (memory,entity)=try derived(),chat=try history(entity.id)
        try store.delete(memory.id);XCTAssertNil(try store.entity(entity.id));try check(chat)
    }
    func testPreviewedErasureRetiresScopeAndPreservesIndependentAnswer()throws {
        let (_,entity)=try derived(),chat=try history(entity.id),scope=HistoryErasureScope(app:"Owned")
        let preview=try store.previewErasure(scope);_=try store.eraseHistory(scope,expectedToken:preview.token)
        XCTAssertNil(try store.entity(entity.id));try check(chat)
    }
    func testRemainingSourceAndCuratedDefinitionsDoNotRetire()throws {
        let (a,entity)=try derived("a");_=try derived("b");let chat=try history(entity.id)
        try store.delete(a.id);try check(chat,active:entity.id)
        try store.editEntity(entity.id,name:entity.name,detail:"Explicit curation",aliases:[entity.name]);try store.delete("b");try check(chat,active:entity.id)
    }
    func testRetirementCrossesTurnAndRunBatchBoundariesIncludingMinimumRowID()throws {
        let entity=try store.createEntity(kind:.project,name:"Batch scope"),chat=try history(entity.id)
        for _ in 1..<130 {_=try store.appendChatTurn(sessionID:chat,question:"Owned batch",answer:.init(text:"Exact batch answer",sources:[],provider:"owned",duration:0),filter:.init(entityID:entity.id))}
        var recipe=RoutineDefinition();recipe.id="owned-batch-routine";_=try store.saveRoutine(recipe)
        let claim=try XCTUnwrap(store.claimRoutine(id:recipe.id,now:Date()));_=try store.finishRoutine(claim.run.id,status:.failed,message:"Owned authored history")
        // Routine definitions do not expose entity scopes. This owned SQL
        // fixture exercises stored run filters without inventing that API.
        try store.withRoutineDatabase {db in try db.transaction {
            let row=try db.statement("UPDATE routine_runs SET scope=? WHERE id=?");defer {sqlite3_finalize(row)};try db.bind(row,1,json:SearchFilter(entityID:entity.id));db.bind(row,2,claim.run.id);try db.done(row)
            let clone=try db.statement("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<129) INSERT INTO routine_runs(id,routine_id,revision,scheduled_at,started,finished,trigger,status,chat_id,message,scope) SELECT printf('owned-scope-batch-%03d',x),r.routine_id,r.revision,r.scheduled_at+x,r.started+x,r.finished+x,'manual',r.status,r.chat_id,r.message,r.scope FROM n CROSS JOIN routine_runs r WHERE r.id=?");defer {sqlite3_finalize(clone)};db.bind(clone,1,claim.run.id);try db.done(clone)
            for table in ["chat_turns","routine_runs"] {try db.execute("UPDATE "+table+" SET rowid=-9223372036854775808 WHERE rowid=(SELECT min(rowid) FROM "+table+")")}
            for (table,column,path,index) in [("chat_turns","payload","$.filter.entityID","entity_scope_turn"),("routine_runs","scope","$.entityID","entity_scope_run")] {
                let plan=try db.statement("EXPLAIN QUERY PLAN SELECT rowid,id FROM "+table+" INDEXED BY "+index+" WHERE json_type(CAST("+column+" AS TEXT),'"+path+"')='text' AND json_extract(CAST("+column+" AS TEXT),'"+path+"')=? ORDER BY rowid LIMIT 128");defer {sqlite3_finalize(plan)};db.bind(plan,1,entity.id);var details="";while sqlite3_step(plan)==SQLITE_ROW {details+=db.text(plan,3)};XCTAssertTrue(details.contains(index));XCTAssertFalse(details.contains("USE TEMP B-TREE"))
            }
        }}
        try store.deleteEntity(entity.id)
        let turns=try store.chatTurns(chat,limit:200),runs=try store.routineRuns(limit:200)
        XCTAssertEqual(turns.count,130);XCTAssertEqual(runs.count,130);XCTAssertTrue(turns.allSatisfy {$0.filter.entityID==nil && $0.filter.unavailableEntityScope != nil});XCTAssertTrue(runs.allSatisfy {$0.filter.entityID==nil && $0.filter.unavailableEntityScope != nil && $0.message=="Owned authored history"})
    }
    func testFailedNativeDeletionRollsBackScopeBeforeSuccessfulRetry()throws {
        let entity=try store.createEntity(kind:.project,name:"Rollback scope"),chat=try history(entity.id),before=try store.chatTurns(chat).first?.filter
        try store.withRoutineDatabase {try $0.execute("CREATE TEMP TRIGGER owned_scope_refuse BEFORE DELETE ON memory_entities BEGIN SELECT RAISE(ABORT,'owned refusal'); END")}
        XCTAssertThrowsError(try store.deleteEntity(entity.id));XCTAssertNotNil(try store.entity(entity.id));XCTAssertEqual(try store.chatTurns(chat).first?.filter,before);try check(chat,active:entity.id)
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_scope_refuse")};try store.deleteEntity(entity.id);try check(chat)
    }
    func testUnavailableScopeSurvivesQuietBackupRestore()throws {
        let entity=try store.createEntity(kind:.project,name:"Backup scope"),chat=try history(entity.id);try store.deleteEntity(entity.id)
        let parent=root.deletingLastPathComponent().appendingPathComponent("owned-unavailable-transfer-"+UUID().uuidString);try Paths.ensure(parent);defer {try? FileManager.default.removeItem(at:parent)}
        let archive=parent.appendingPathComponent("archive.oswindbackup"),restored=parent.appendingPathComponent("restored");_=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:restored)
        let copy=try MemoryStore(root:restored);defer {try? copy.close()};let turn=try XCTUnwrap(copy.chatTurns(chat).first)
        XCTAssertNotNil(turn.filter.unavailableEntityScope);XCTAssertNil(turn.filter.entityID);XCTAssertThrowsError(try copy.search(turn.filter,mode:.keyword));XCTAssertEqual(Data(turn.answer.text.utf8),Data("Exact answer e\u{301} / 👩🏽‍💻".utf8))
    }
    func testCurrentScopeIndexesCannotBeSilentlyRepaired()throws {
        for name in EntityScopeSchema.indexes.keys.sorted() {
            for altered in [false,true] {
                let library=root.appendingPathComponent(name+(altered ? "-altered":"-missing")),owned=try MemoryStore(root:library);try owned.close()
                var handle:OpaquePointer?;XCTAssertEqual(sqlite3_open(library.appendingPathComponent("memory.sqlite").path,&handle),SQLITE_OK);let db=RoutineDatabase(handle:try XCTUnwrap(handle));defer {sqlite3_close(handle)}
                try db.execute("DROP INDEX "+name);if altered {try db.execute("CREATE INDEX "+name+" ON "+(name=="entity_scope_turn" ? "chat_turns(session_id)":"routine_runs(routine_id)"))}
                let before=try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name='"+name+"'")
                XCTAssertThrowsError(try MemoryStore(root:library));XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),33);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name='"+name+"'"),before)
                XCTAssertThrowsError(try EntityScopeSchema.validate(db))
            }
        }
    }
    func testCurrentScopeWriterGuardsCannotBeSilentlyRepaired()throws {
        for name in ["unavailable_scope_writer_memories_update","unavailable_scope_writer_chat_turns_insert","unavailable_scope_writer_routine_run_originals_delete"] {
            let library=root.appendingPathComponent(name),owned=try MemoryStore(root:library);try owned.close()
            var handle:OpaquePointer?;XCTAssertEqual(sqlite3_open(library.appendingPathComponent("memory.sqlite").path,&handle),SQLITE_OK);let db=RoutineDatabase(handle:try XCTUnwrap(handle));defer {sqlite3_close(handle)}
            try db.execute("DROP TRIGGER "+name);XCTAssertThrowsError(try MemoryStore(root:library))
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),33);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name='"+name+"'"),0)
        }
    }
    func testCancellationAfterNativeScopeRewriteRollsBackAndNextDeletionSucceeds()throws {
        let entity=try store.createEntity(kind:.project,name:"Cancelled scope"),chat=try history(entity.id)
        try store.withRoutineDatabase {db in
            guard sqlite3_create_function_v2(db.handle,"owned_cancel_scope",0,SQLITE_UTF8,nil,{context,_,_ in withUnsafeCurrentTask {$0?.cancel()};sqlite3_result_int(context,1)},nil,nil,nil)==SQLITE_OK else {throw db.error()}
            try db.execute("CREATE TEMP TRIGGER owned_scope_cancel BEFORE DELETE ON memory_entities BEGIN SELECT owned_cancel_scope(); END")
        }
        let finished=expectation(description:"Owned cancellation unwinds")
        Task.detached {
            defer {finished.fulfill()}
            do {try self.store.deleteEntity(entity.id);XCTFail("Cancelled deletion must refuse")}
            catch {XCTAssertTrue(error is CancellationError,"Unexpected cancellation: \(error)")}
        };wait(for:[finished],timeout:10)
        try check(chat,active:entity.id);XCTAssertNotNil(try store.entity(entity.id))
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_scope_cancel")};try store.deleteEntity(entity.id);try check(chat)
    }
}
