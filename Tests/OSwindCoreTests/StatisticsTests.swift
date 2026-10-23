import XCTest
import CSQLite
@testable import OSwindCore

final class StatisticsTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    func connection() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&db) == SQLITE_OK, let db else { throw OSwindError.database("Test database could not open") }
        return db
    }
    func execute(_ sql: String) throws {
        let db = try connection(); defer { sqlite3_close(db) }
        guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw OSwindError.database(String(cString:sqlite3_errmsg(db))) }
    }
    func assertMatchesSourceScan(file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try store.stats(includeDiskUsage:false), db = try connection(); defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT COUNT(*),COALESCE(SUM(kind='screen'),0),COALESCE(SUM(kind='audio'),0),COALESCE(SUM(embedding IS NOT NULL),0),MIN(timestamp),MAX(timestamp) FROM memories",-1,&stmt,nil),SQLITE_OK,file:file,line:line)
        XCTAssertEqual(sqlite3_step(stmt),SQLITE_ROW,file:file,line:line)
        XCTAssertEqual([value.count,value.screenshots,value.audioSegments,value.embedded],(0..<4).map { Int(sqlite3_column_int64(stmt,Int32($0))) },file:file,line:line)
        if value.count > 0 { XCTAssertEqual(value.oldest?.timeIntervalSince1970,sqlite3_column_double(stmt,4),file:file,line:line); XCTAssertEqual(value.newest?.timeIntervalSince1970,sqlite3_column_double(stmt,5),file:file,line:line) }
        else { XCTAssertNil(value.oldest,file:file,line:line); XCTAssertNil(value.newest,file:file,line:line) }
        sqlite3_finalize(stmt); stmt = nil
        XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT app,COUNT(*) FROM memories GROUP BY app",-1,&stmt,nil),SQLITE_OK,file:file,line:line)
        var apps = [String:Int]()
        while sqlite3_step(stmt) == SQLITE_ROW { apps[String(cString:sqlite3_column_text(stmt,0))] = Int(sqlite3_column_int64(stmt,1)) }
        sqlite3_finalize(stmt); XCTAssertEqual(value.apps,apps,file:file,line:line)
        XCTAssertEqual(try store.matchingCount(),value.count,file:file,line:line)
    }
    func testCountersFollowInsertOverwriteMetadataAndDeletion() throws {
        var first = Memory(id:"first",timestamp:Date(timeIntervalSince1970:100),kind:.screen,app:"Notes",text:"quartz first",embedding:[1,0],embeddingModel:"fixture")
        let second = Memory(id:"second",timestamp:Date(timeIntervalSince1970:200),kind:.audio,app:"Meeting",text:"quartz second")
        try store.insert(first); try store.insert(second); try assertMatchesSourceScan()
        first.app = "Editor"; first.kind = .note; first.embedding = nil; first.timestamp = Date(timeIntervalSince1970:300)
        try store.insert(first); try assertMatchesSourceScan()
        XCTAssertNil(try store.stats(includeDiskUsage:false).apps["Notes"])
        try store.setFavorite("first",value:true); try store.setTags("first",tags:["review"]); try assertMatchesSourceScan()
        _ = try store.saveVectors([VectorRecord(memory:first,vector:[0,1])],modelID:"additional")
        XCTAssertEqual(try store.stats(includeDiskUsage:false).embedded,0) // Legacy/built-in vectors, not every model.
        XCTAssertEqual(try store.search(SearchFilter(query:"quartz"),mode:.keyword).count,2)
        try store.delete("second"); try assertMatchesSourceScan()
        try store.deleteAll(); try assertMatchesSourceScan(); XCTAssertTrue(try store.stats(includeDiskUsage:false).apps.isEmpty)
    }
    func testImportRollbackAlsoRollsBackCounters() throws {
        try store.insert(Memory(id:"retained",app:"Notes",text:"Keep this"))
        let file = root.appendingPathComponent("invalid-import.json")
        try JSONEncoder().encode([Memory(id:"temporary",app:"Other",text:"Roll this back"),Memory(id:"",text:"Invalid identifier")]).write(to:file)
        XCTAssertThrowsError(try store.importJSON(from:file)); try assertMatchesSourceScan()
        XCTAssertEqual(try store.stats(includeDiskUsage:false).apps,["Notes":1])
    }
    func testConcurrentStoreConnectionsMaintainOneConsistentTally() throws {
        let writers = try (0..<4).map { _ in try MemoryStore(root:root) }, errorLock = NSLock(); var errors = [String]()
        DispatchQueue.concurrentPerform(iterations:4) { worker in
            do { for i in 0..<40 { try writers[worker].insert(Memory(id:"w\(worker)-\(i)",kind:i%2 == 0 ? .audio : .screen,app:"App \(worker%2)",text:"quartz writer")) } }
            catch { errorLock.lock(); errors.append(error.localizedDescription); errorLock.unlock() }
        }
        XCTAssertTrue(errors.isEmpty,errors.joined(separator:"; ")); try assertMatchesSourceScan()
        XCTAssertEqual(try store.stats(includeDiskUsage:false).count,160)
        XCTAssertEqual(try store.matchingCount(SearchFilter(app:"App 0")),80)
    }
    func testSchemaFourMigrationPreservesSourceChatAndNativeCache() async throws {
        let memory = Memory(id:"migrated",app:"Notes",text:"quartz migration",embedding:[1,0],embeddingModel:"fixture")
        try store.insert(memory); let chat = try store.createChat()
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Migration?",answer:Answer(text:"Recorded [1]",sources:[SearchHit(memory:memory,score:1,match:"fixture")],provider:"fixture",duration:0))
        _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:2)
        let manifests = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("indexes"),includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" }
        let manifest = try XCTUnwrap(manifests.first), data = try Data(contentsOf:manifest)
        store = nil
        try execute("DROP TRIGGER statistics_insert; DROP TRIGGER statistics_update; DROP TRIGGER statistics_delete; DROP TABLE memory_statistics; DROP TABLE application_statistics; PRAGMA user_version=4;")
        store = try MemoryStore(root:root); try assertMatchesSourceScan()
        XCTAssertEqual(try store.chatTurns(chat.id).count,1)
        XCTAssertEqual(try store.search(SearchFilter(query:"quartz"),mode:.keyword).first?.id,memory.id)
        _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:2)
        XCTAssertEqual(try Data(contentsOf:manifest),data)
    }
    func testMissingOrInconsistentDerivedCountsRepairOnReopen() throws {
        try store.insert(Memory(id:"a",app:"A",text:"quartz")); try store.insert(Memory(id:"b",app:"B",text:"quartz")); store = nil
        try execute("DELETE FROM memory_statistics")
        store = try MemoryStore(root:root); try assertMatchesSourceScan(); store = nil
        try execute("DELETE FROM application_statistics WHERE app='A'")
        store = try MemoryStore(root:root); try assertMatchesSourceScan()
        XCTAssertEqual(try store.stats(includeDiskUsage:false).count,2)
    }
}
