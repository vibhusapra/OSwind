import XCTest
import CSQLite
@testable import OSwindCore

final class FullTextIdentityTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    func sql(_ sql:String) throws {try store.withRoutineDatabase {try $0.execute(sql)}}
    func scalar(_ sql:String) throws -> String {try store.withRoutineDatabase {db in let row=try db.statement(sql);defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);return db.text(row,0)}}
    func aligned() throws {
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM memories m LEFT JOIN memory_fts_keys k ON k.memory_id=m.id LEFT JOIN memory_fts f ON f.rowid=k.key WHERE f.id IS NOT m.id OR f.title IS NOT m.title OR f.app IS NOT m.app OR f.text IS NOT m.text"),"0")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM memory_fts f LEFT JOIN memory_fts_keys k ON k.key=f.rowid LEFT JOIN memories m ON m.id=k.memory_id WHERE m.id IS NULL"),"0")
    }
    func testInsertUpdateDeleteReuseAndQuotedSearchStayAligned() throws {
        for i in 0..<50 {try store.insert(Memory(id:"\(i)",app:"Notes",text:"alpha beta \(i)"))}
        try aligned()
        var edited=try XCTUnwrap(store.get("25"));edited.title="Changed";edited.text="new phrase";try store.insert(edited);try store.setFavorite("25",value:true);try store.setTags("25",tags:["keep"])
        XCTAssertEqual(try store.search(.init(query:#""new phrase""#),mode:.keyword).map(\.id),["25"]);try aligned()
        for i in stride(from:0,to:50,by:2) {try store.delete(String(i))}
        for i in 50..<80 {try store.insert(Memory(id:"\(i)",text:"replacement"))};try aligned()
        try store.deleteAll();try store.insert(Memory(id:"fresh",text:"fresh text"));try aligned();XCTAssertEqual(try scalar("SELECT COUNT(*) FROM memory_fts"),"1")
    }
    func testOldUnalignedCacheRebuildPreservesSourcesVectorsIdentityAndScope() throws {
        try store.insert(Memory(id:"first",text:"current phrase",embedding:[1,0],embeddingModel:"fixture"));try store.insert(Memory(id:"second",text:"second"))
        let identity=try scalar("SELECT value FROM store_metadata WHERE key='identity'"),scope=try scalar("SELECT hex(revision) FROM search_scope_revision"),keys=try scalar("SELECT group_concat(key) FROM vector_keys"),before=try XCTUnwrap(store.get("first"))
        try sql("DROP TRIGGER memory_insert; DROP TRIGGER memory_delete; DROP TRIGGER memory_update; DELETE FROM store_metadata WHERE key='fts_rowid_version'; DELETE FROM memory_fts; INSERT INTO memory_fts(rowid,id,title,app,text) SELECT rowid+100,id,title,app,'obsolete text' FROM memories")
        store=nil;store=try MemoryStore(root:root);try aligned()
        XCTAssertEqual(try store.get("first"),before);XCTAssertEqual(try scalar("SELECT value FROM store_metadata WHERE key='identity'"),identity);XCTAssertEqual(try scalar("SELECT hex(revision) FROM search_scope_revision"),scope);XCTAssertEqual(try scalar("SELECT group_concat(key) FROM vector_keys"),keys)
        XCTAssertEqual(try store.search(.init(query:#""current phrase""#),mode:.keyword).map(\.id),["first"]);XCTAssertEqual(try store.semanticIndexes()["fixture"],1)
    }
    func testUnexpectedLegacyTriggerForcesCacheRepairEvenWithMarker() throws {
        try store.insert(Memory(id:"one",text:"original"))
        try sql("DROP TRIGGER memory_update; CREATE TRIGGER memory_update AFTER UPDATE OF text ON memories BEGIN DELETE FROM memory_fts WHERE id=old.id; INSERT INTO memory_fts(id,title,app,text) VALUES(new.id,new.title,new.app,new.text); END")
        try store.insert(Memory(id:"one",text:"changed"))
        store=nil;store=try MemoryStore(root:root);try aligned()
        XCTAssertEqual(try scalar("SELECT sql FROM sqlite_master WHERE name='memory_update'"),FullTextIdentitySchema.triggers["memory_update"])
    }
    func testCurrentCacheDoesNotRebuildOrReplaceTriggersOnReopen() throws {
        try store.insert(Memory(id:"one",text:"alpha"))
        // Count writes to the FTS shadow docsize table: a normal reopen must leave it alone.
        let before=try scalar("SELECT rootpage FROM sqlite_master WHERE name='memory_fts_docsize'"),trigger=try scalar("SELECT sql FROM sqlite_master WHERE name='memory_update'")
        store=nil;store=try MemoryStore(root:root);try aligned()
        XCTAssertEqual(try scalar("SELECT rootpage FROM sqlite_master WHERE name='memory_fts_docsize'"),before);XCTAssertEqual(try scalar("SELECT sql FROM sqlite_master WHERE name='memory_update'"),trigger)
        // Installing an identical cache inside a reserved transaction emits no mutation SQL.
        try store.withRoutineDatabase {db in
            try db.execute("BEGIN IMMEDIATE")
            let total=sqlite3_total_changes(db.handle);try FullTextIdentitySchema.install(db);XCTAssertEqual(sqlite3_total_changes(db.handle),total);try db.execute("ROLLBACK")
        }
    }
    func testMaintenancePlanUsesRowidRatherThanUnindexedIdentifier() throws {
        try store.insert(Memory(id:"one",text:"fixture"))
        let plan=try store.withRoutineDatabase {db -> String in let row=try db.statement("EXPLAIN QUERY PLAN DELETE FROM memory_fts WHERE rowid=?");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return db.text(row,3)}
        XCTAssertTrue(plan.contains("="),plan)
        for name in ["memory_delete","memory_update"] {XCTAssertTrue(try scalar("SELECT sql FROM sqlite_master WHERE name='\(name)'").contains("rowid=(SELECT key FROM memory_fts_keys"))}
    }
    func testSourceRowidRenumberAndVacuumCannotInvalidateFTSKeys() throws {
        for i in 0..<12 {try store.insert(Memory(id:"row-\(i)",text:"alpha \(i)"))}
        let keys=try scalar("SELECT group_concat(key) FROM memory_fts_keys ORDER BY key")
        try sql("UPDATE memories SET rowid=rowid+10000; VACUUM")
        XCTAssertEqual(try scalar("SELECT group_concat(key) FROM memory_fts_keys ORDER BY key"),keys);try aligned()
        var m=try XCTUnwrap(store.get("row-5"));m.text="changed phrase";try store.insert(m);try store.delete("row-7");try aligned()
        XCTAssertEqual(try store.search(.init(query:#""changed phrase""#),mode:.keyword).map(\.id),["row-5"])
        store=nil;store=try MemoryStore(root:root);try aligned()
    }

}
