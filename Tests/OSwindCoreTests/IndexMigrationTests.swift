import XCTest
import CSQLite
@testable import OSwindCore

final class IndexMigrationTests: XCTestCase {
    func testActualSchemaThreeRowsAreBackfilledWithoutLosingEitherVectorModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Paths.ensure(root); defer { try? FileManager.default.removeItem(at:root) }
        var connection: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&connection),SQLITE_OK)
        let schema = """
        CREATE TABLE memories(id TEXT PRIMARY KEY,timestamp REAL NOT NULL,kind TEXT NOT NULL,app TEXT NOT NULL,title TEXT NOT NULL,url TEXT,text TEXT NOT NULL,favorite INTEGER NOT NULL DEFAULT 0,payload BLOB NOT NULL,embedding BLOB,embedding_model TEXT);
        CREATE VIRTUAL TABLE memory_fts USING fts5(id UNINDEXED,title,app,text,tokenize='unicode61 remove_diacritics 2');
        CREATE TABLE semantic_vectors(memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,model TEXT NOT NULL,dimension INTEGER NOT NULL,vector BLOB NOT NULL,content_hash TEXT NOT NULL,PRIMARY KEY(memory_id,model));
        PRAGMA user_version=3;
        """
        XCTAssertEqual(sqlite3_exec(connection,schema,nil,nil,nil),SQLITE_OK)
        var memory = Memory(id:"legacy",kind:.note,app:"Notes",title:"Legacy decision",text:"The legacy release is Friday"); memory.embeddingModel = "legacy-model"
        let payload = try JSONEncoder().encode(memory), transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        var stmt: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(connection,"INSERT INTO memories VALUES('legacy',100,'note','Notes','Legacy decision',NULL,'The legacy release is Friday',0,?,?,'legacy-model')",-1,&stmt,nil),SQLITE_OK)
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(stmt,1,$0.baseAddress,Int32(payload.count),transient) }
        _ = [Float](arrayLiteral:1,0).withUnsafeBytes { sqlite3_bind_blob(stmt,2,$0.baseAddress,Int32($0.count),transient) }
        XCTAssertEqual(sqlite3_step(stmt),SQLITE_DONE); sqlite3_finalize(stmt)
        XCTAssertEqual(sqlite3_exec(connection,"INSERT INTO memory_fts VALUES('legacy','Legacy decision','Notes','The legacy release is Friday')",nil,nil,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_prepare_v2(connection,"INSERT INTO semantic_vectors VALUES('legacy','gpu-model',2,?,?)",-1,&stmt,nil),SQLITE_OK)
        _ = [Float](arrayLiteral:0,1).withUnsafeBytes { sqlite3_bind_blob(stmt,1,$0.baseAddress,Int32($0.count),transient) }; sqlite3_bind_text(stmt,2,memory.contentHash,-1,transient)
        XCTAssertEqual(sqlite3_step(stmt),SQLITE_DONE); sqlite3_finalize(stmt); sqlite3_close(connection)
        let store = try MemoryStore(root:root)
        XCTAssertEqual(try store.get("legacy")?.text,memory.text); XCTAssertEqual(try store.search(SearchFilter(query:"legacy"),mode:.keyword).first?.id,"legacy")
        XCTAssertEqual(try store.vectorCount(modelID:"legacy-model"),1); XCTAssertEqual(try store.vectorCount(modelID:"gpu-model"),1)
        let source = try VectorIndexSource(root:root,modelID:"gpu-model",dimensions:2), state = try source.state()
        XCTAssertEqual(state.head,0); XCTAssertEqual(try source.page(after:0,through:state.highKey).first?.vector,[0,1])
        _ = try await store.buildSearchIndex(modelID:"gpu-model",dimensions:2)
        let hits = try store.search(SearchFilter(query:"meaning"),mode:.semantic,vector:[0,1],modelID:"gpu-model",indexPolicy:.indexed)
        XCTAssertEqual(hits.first?.id,"legacy")
    }
}

extension IndexMigrationTests {
    func testSchemaFivePreservesKeysDeletedHighwaterChatsAndPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        var store: MemoryStore? = try MemoryStore(root:root)
        let original = Memory(id:"source",app:"Notes",text:"Synthetic migration evidence")
        try store!.insert(original); _ = try store!.saveVectors([VectorRecord(memory:original,vector:[1,0])],modelID:"fixture")
        let chat = try store!.createChat(); _ = try store!.appendChatTurn(sessionID:chat.id,question:"What happened?",answer:Answer(text:"Evidence [1]",sources:[SearchHit(memory:original,score:1,match:"semantic")],provider:"evidence",duration:0))
        store = nil
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK)
        let old = """
        PRAGMA foreign_keys=OFF;
        DROP TRIGGER vector_key_deleted; DROP TRIGGER vector_legacy_insert; DROP TRIGGER vector_legacy_update;
        DROP TRIGGER vector_extra_insert; DROP TRIGGER vector_extra_update; DROP TRIGGER vector_extra_delete;
        DROP TRIGGER vector_statistics_insert; DROP TRIGGER vector_statistics_delete;
        DROP TRIGGER passage_insert; DROP TRIGGER passage_delete; DROP TRIGGER passage_content_update; DROP TRIGGER passage_base_removed;
        DROP TABLE semantic_passages; DROP TABLE passage_manifests; DROP TABLE vector_statistics;
        ALTER TABLE vector_keys RENAME TO temporary_keys;
        CREATE TABLE vector_keys(key INTEGER PRIMARY KEY AUTOINCREMENT,memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,model TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,UNIQUE(memory_id,model));
        INSERT INTO vector_keys(key,memory_id,model,revision) SELECT key,memory_id,model,revision FROM temporary_keys;
        DROP TABLE temporary_keys;
        CREATE INDEX vector_keys_model ON vector_keys(model,key); CREATE INDEX vector_keys_revision ON vector_keys(model,revision);
        INSERT INTO vector_keys(key,memory_id,model) VALUES(900,'source','deleted'); DELETE FROM vector_keys WHERE key=900;
        ALTER TABLE chat_sources DROP COLUMN passage_start; ALTER TABLE chat_sources DROP COLUMN passage_length;
        UPDATE store_metadata SET value='old-identity' WHERE key='identity'; PRAGMA user_version=5;
        """
        XCTAssertEqual(sqlite3_exec(db,old,nil,nil,nil),SQLITE_OK,String(cString:sqlite3_errmsg(db))); sqlite3_close(db)
        store = try MemoryStore(root:root)
        XCTAssertEqual(try store!.get(original.id)?.text,original.text); XCTAssertEqual(try store!.chatTurns(chat.id).count,1)
        XCTAssertEqual(try store!.vectorCount(modelID:"fixture"),1)
        let reader = try VectorIndexSource(root:root,modelID:"fixture",dimensions:2), state = try reader.state()
        XCTAssertNotEqual(state.identity,"old-identity"); XCTAssertEqual(try reader.page(after:0,through:state.highKey).first?.key,1)
        _ = try store!.saveVectors([VectorRecord(memory:original,vector:[0,1])],modelID:"second")
        let next = try VectorIndexSource(root:root,modelID:"second",dimensions:2).state()
        XCTAssertGreaterThan(next.highKey,900)
        XCTAssertEqual(try store!.search(SearchFilter(query:"migration"),mode:.keyword).first?.id,"source")
        store = nil
        let reopened = try MemoryStore(root:root); XCTAssertEqual(try reopened.chatTurns(chat.id).count,1); XCTAssertEqual(try reopened.vectorCount(modelID:"second"),1)
    }
    func testEmptySchemaFivePreservesDeletedOnlyHighwater() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        var store: MemoryStore? = try MemoryStore(root:root); store = nil
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK)
        // A minimal authentic old registry with no surviving rows.
        let old = """
        DROP TRIGGER vector_key_deleted; DROP TRIGGER vector_legacy_insert; DROP TRIGGER vector_legacy_update;
        DROP TRIGGER vector_extra_insert; DROP TRIGGER vector_extra_update; DROP TRIGGER vector_extra_delete;
        DROP TRIGGER vector_statistics_insert; DROP TRIGGER vector_statistics_delete;
        DROP TRIGGER passage_insert; DROP TRIGGER passage_delete; DROP TRIGGER passage_content_update; DROP TRIGGER passage_base_removed;
        DROP TABLE semantic_passages; DROP TABLE passage_manifests; DROP TABLE vector_statistics; DROP TABLE vector_keys;
        CREATE TABLE vector_keys(key INTEGER PRIMARY KEY AUTOINCREMENT,memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,model TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,UNIQUE(memory_id,model));
        INSERT INTO vector_keys(key,memory_id,model) VALUES(700,'deleted','fixture'); DELETE FROM vector_keys;
        PRAGMA user_version=5;
        """
        XCTAssertEqual(sqlite3_exec(db,old,nil,nil,nil),SQLITE_OK,String(cString:sqlite3_errmsg(db))); sqlite3_close(db)
        store = try MemoryStore(root:root); let memory = Memory(id:"new",text:"New evidence"); try store!.insert(memory)
        _ = try store!.saveVectors([VectorRecord(memory:memory,vector:[1,0])],modelID:"fixture")
        let state = try VectorIndexSource(root:root,modelID:"fixture",dimensions:2).state(); XCTAssertGreaterThan(state.highKey,700)
    }
}


extension IndexMigrationTests {
    func testSchemaSixUpgradePreservesStoreIdentityAndExistingVectorKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        var store: MemoryStore? = try MemoryStore(root:root)
        let memory = Memory(id:"six",text:"Schema six source"); try store!.insert(memory)
        _ = try store!.saveVectors([VectorRecord(memory:memory,vector:[1,0])],modelID:"fixture")
        let original = try VectorIndexSource(root:root,modelID:"fixture",dimensions:2).state(); store = nil
        var handle: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&handle),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle,"PRAGMA user_version=6",nil,nil,nil),SQLITE_OK); sqlite3_close(handle)
        store = try MemoryStore(root:root)
        let upgraded = try VectorIndexSource(root:root,modelID:"fixture",dimensions:2).state()
        XCTAssertEqual(upgraded.identity,original.identity); XCTAssertEqual(upgraded.highKey,original.highKey)
        XCTAssertEqual(try store!.get(memory.id)?.text,memory.text)
    }
}
