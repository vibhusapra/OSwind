import XCTest
import CSQLite
@testable import OSwindCore

final class SearchScopeTests: XCTestCase {
    func testCoverageCacheTracksSourcesVectorsAndMetadataAcrossConnections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root), other = try MemoryStore(root:root), filter = SearchFilter(query:"ignored",app:"A",favoritesOnly:true,tag:"work")
        func compare() throws {
            let coverage = try store.indexCoverage(modelID:"fixture",filter:filter)
            XCTAssertEqual(coverage.indexed,try store.vectorCount(modelID:"fixture",filter:filter))
            XCTAssertEqual(coverage.total,try store.matchingCount(filter))
        }
        try compare()
        let memory = Memory(id:"source",kind:.note,app:"A",text:"Coverage fixture",favorite:true,tags:["work"])
        try other.insert(memory); try compare()
        XCTAssertEqual(try store.indexCoverage(modelID:"fixture",filter:filter).indexed,0)
        _ = try other.saveVectors([VectorRecord(memory:memory,vector:Array(repeating:1,count:32))],modelID:"fixture"); try compare()
        XCTAssertEqual(try store.indexCoverage(modelID:"fixture",filter:filter).indexed,1)
        try other.setFavorite("source",value:false); try compare()
        XCTAssertEqual(try store.indexCoverage(modelID:"fixture",filter:filter).total,0)
        try other.setFavorite("source",value:true); try other.setTags("source",tags:["different"]); try compare()
        try other.setTags("source",tags:["work"]); try compare()
        try other.deleteAll(); try compare()
        XCTAssertEqual(try store.indexCoverage(modelID:"fixture",filter:filter).indexed,0)
    }
    func testTransactionalNonceTracksEveryScopeFieldAcrossWritersAndRollback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root), other = try MemoryStore(root:root)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&raw),SQLITE_OK)
        defer { sqlite3_close(raw) }
        try SyncChangeCapture.register(on:RoutineDatabase(handle:try XCTUnwrap(raw)))
        func execute(_ sql: String) throws { guard sqlite3_exec(raw,sql,nil,nil,nil) == SQLITE_OK else { throw OSwindError.database(String(cString:sqlite3_errmsg(raw))) } }
        func nonce() throws -> String {
            var query: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(raw,"SELECT hex(revision) FROM search_scope_revision WHERE singleton=1",-1,&query,nil),SQLITE_OK)
            defer { sqlite3_finalize(query) }; XCTAssertEqual(sqlite3_step(query),SQLITE_ROW)
            return String(cString:sqlite3_column_text(query,0))
        }
        var previous = try nonce(); XCTAssertEqual(previous.count,32)
        try store.insert(Memory(id:"source",kind:.note,app:"A",text:"Scope fixture"))
        var current = try nonce(); XCTAssertNotEqual(previous,current); previous = current
        for change in ["app='B'","kind='audio'","timestamp=1792700000","favorite=1","payload=CAST(json_set(CAST(payload AS TEXT),'$.tags',json('[\"changed\"]')) AS BLOB)"] {
            try execute("UPDATE memories SET \(change) WHERE id='source'")
            current = try nonce(); XCTAssertNotEqual(previous,current); previous = current
        }
        try execute("BEGIN; UPDATE memories SET app='rollback' WHERE id='source'; ROLLBACK")
        XCTAssertEqual(try nonce(),previous)
        try other.setFavorite("source",value:false)
        current = try nonce(); XCTAssertNotEqual(previous,current); previous = current
        try other.setTags("source",tags:["different"])
        current = try nonce(); XCTAssertNotEqual(previous,current); previous = current
        try other.delete("source"); XCTAssertNotEqual(try nonce(),previous)
    }
}
