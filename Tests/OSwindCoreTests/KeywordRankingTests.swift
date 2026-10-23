import XCTest
import CSQLite
@testable import OSwindCore

final class KeywordRankingTests: XCTestCase {
    func testRankCursorMatchesOriginalWeightedBM25AcrossScopesAndLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root)
        for i in 0..<400 {
            try store.insert(Memory(id:"row-\(i)",timestamp:Date(timeIntervalSince1970:Double(i)),kind:i%2 == 0 ? .note : .audio,app:i%3 == 0 ? "A" : "B",title:i%4 == 0 ? "rare comet" : "Status",text:i%5 == 0 ? "A comet with a rare tail" : "Ordinary comet observation \(i)",favorite:i%7 == 0,tags:i%11 == 0 ? ["work"] : []))
        }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&database,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        defer { sqlite3_close(database) }
        let scopes: [(SearchFilter,String)] = [(SearchFilter(),"1=1"),(SearchFilter(app:"A"),"m.app='A'"),(SearchFilter(kind:.audio),"m.kind='audio'"),(SearchFilter(start:Date(timeIntervalSince1970:100),end:Date(timeIntervalSince1970:300)),"m.timestamp>=100 AND m.timestamp<300"),(SearchFilter(favoritesOnly:true),"m.favorite=1"),(SearchFilter(tag:"work"),"EXISTS (SELECT 1 FROM json_each(CAST(m.payload AS TEXT),'$.tags') WHERE value='work')")]
        for query in ["comet","rare comet","ordinary","rare+comet","noSuchTerm"] {
            for (scope,predicate) in scopes { for limit in [1,5,100] {
                let sql = "SELECT m.id FROM memory_fts f JOIN memories m ON m.id=f.id WHERE memory_fts MATCH ? AND \(predicate) ORDER BY bm25(memory_fts,0,3,1,1) LIMIT ?"
                var statement: OpaquePointer?
                XCTAssertEqual(sqlite3_prepare_v2(database,sql,-1,&statement,nil),SQLITE_OK)
                defer { sqlite3_finalize(statement) }
                let text = MemoryStore.ftsQuery(query)
                text.withCString { sqlite3_bind_text(statement,1,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
                sqlite3_bind_int(statement,2,Int32(limit))
                var expected = [String](), status = sqlite3_step(statement)
                while status == SQLITE_ROW { expected.append(String(cString:sqlite3_column_text(statement,0))); status = sqlite3_step(statement) }
                XCTAssertEqual(status,SQLITE_DONE)
                var filter = scope; filter.query = query; filter.limit = limit
                XCTAssertEqual(try store.search(filter,mode:.keyword).map(\.id),expected,"Query \(query), scope \(predicate), limit \(limit)")
            } }
        }
    }
}
