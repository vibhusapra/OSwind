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
