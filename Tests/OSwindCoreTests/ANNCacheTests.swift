import XCTest
import CSQLite
@testable import OSwindCore

final class ANNCacheTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    func seed(_ count: Int = 128, dimensions: Int = 32) throws {
        for i in 0..<count { var memory = Memory(id:"row-\(i)",text:"Synthetic evidence \(i)"); memory.embedding = VectorScalingEvaluation.vector(row:i,dimensions:dimensions); memory.embeddingModel = "fixture"; try store.insert(memory) }
    }
    func hits(_ cache: ANNCache, row: Int = 42) throws -> [UInt64] {
        let state = try VectorIndexSource(root:root,modelID:"fixture",dimensions:32).state()
        return try cache.withReady(modelID:"fixture",dimensions:32,identity:state.identity,snapshotHead:state.head) { native,_ in try native.search(VectorScalingEvaluation.vector(row:row,dimensions:32),count:10,include:{_ in true}) } ?? []
    }
    func testNativeFilterPersistenceAndDimensionsGuard() throws {
        let index = try NativeANN(dimensions:32); try index.reserve(128)
        let records = (0..<128).map { IndexedVector(key:UInt64($0),revision:0,vector:VectorScalingEvaluation.vector(row:$0,dimensions:32)) }
        try index.addBatch(records)
        let result = try index.search(VectorScalingEvaluation.vector(row:42,dimensions:32),count:10,include:{$0%2 == 0})
        XCTAssertEqual(result.first,42); XCTAssertTrue(result.allSatisfy { $0%2 == 0 })
        let file = root.appendingPathComponent("native.usearch"); try index.save(file)
        let loaded = try NativeANN(dimensions:32); try loaded.load(file); try loaded.remove(42)
        XCTAssertFalse(try loaded.search(VectorScalingEvaluation.vector(row:42,dimensions:32),count:10,include:{_ in true}).contains(42))
        XCTAssertThrowsError(try NativeANN(dimensions:4).load(file))
    }
    func testCacheSurvivesReopenAndReplaysDeletionAndReplacement() async throws {
        try seed(); let cache = ANNCache(root:root)
        cache.prepare(modelID:"fixture",dimensions:32,count:128,force:true); _ = try await cache.waitForBuild()
        let originalKey = try XCTUnwrap(hits(cache).first)
        let reopened = ANNCache(root:root); XCTAssertEqual(reopened.prepare(modelID:"fixture",dimensions:32,count:128).state,"ready")
        XCTAssertEqual(try hits(reopened).first,originalKey)
        let other = try MemoryStore(root:root); try other.delete("row-42")
        reopened.prepare(modelID:"fixture",dimensions:32,count:127)
        _ = try await reopened.waitForBuild() // Public erasure removes disposable files and changes identity.
        XCTAssertFalse(try hits(reopened).contains(originalKey))
        var replacement = Memory(id:"row-42",text:"Replacement"); replacement.embedding = VectorScalingEvaluation.vector(row:42,dimensions:32); replacement.embeddingModel = "fixture"; try other.insert(replacement)
        reopened.prepare(modelID:"fixture",dimensions:32,count:128)
        _ = try await reopened.waitForBuild()
        XCTAssertNotEqual(try hits(reopened).first,originalKey); XCTAssertFalse(try hits(reopened).isEmpty)
    }
    func testCorruptSnapshotIsRebuiltBeforeNativeLoading() async throws {
        try seed(); let cache = ANNCache(root:root); cache.prepare(modelID:"fixture",dimensions:32,count:128,force:true); _ = try await cache.waitForBuild()
        let folder = root.appendingPathComponent("indexes"), files = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
        let graph = try XCTUnwrap(files.first { $0.pathExtension == "usearch" }); try Data("invalid native graph".utf8).write(to:graph,options:.atomic)
        let rebuilt = ANNCache(root:root); rebuilt.prepare(modelID:"fixture",dimensions:32,count:128); _ = try await rebuilt.waitForBuild()
        XCTAssertFalse(try hits(rebuilt).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath:folder.path); XCTAssertEqual(attributes[.posixPermissions] as? Int,0o700)
        let valid = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "usearch" }
        XCTAssertEqual(valid.count,1); XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:valid[0].path)[.posixPermissions] as? Int,0o600)
    }
    func testDeleteAllInvalidatesOtherProcessSnapshotAndCacheFiles() async throws {
        try seed(); _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:32)
        let reader = try VectorIndexSource(root:root,modelID:"fixture",dimensions:32), before = try reader.state()
        let otherCache = ANNCache(root:root); otherCache.prepare(modelID:"fixture",dimensions:32,count:128)
        try store.deleteAll(); let after = try reader.state()
        XCTAssertNotEqual(after.identity,before.identity); XCTAssertEqual(after.count,0)
        XCTAssertEqual(store.searchIndexStatus.state,"idle"); XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("indexes").path))
        XCTAssertNil(otherCache.withReady(modelID:"fixture",dimensions:32,identity:after.identity,snapshotHead:after.head) { _,_ in true })
    }
    func testBudgetEvictsDisposableCacheBeforeEvidence() throws {
        try seed(3); let directory = root.appendingPathComponent("indexes"); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data(repeating:0,count:2_000_000).write(to:directory.appendingPathComponent("synthetic-cache"))
        let deleted = try store.prune(before:.distantPast,maxBytes:1_000_000)
        XCTAssertEqual(deleted,0); XCTAssertEqual(try store.stats().count,3); XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
    }
    func testBusyCheckpointRetainsEvidenceUntilReaderReleasesSnapshot() throws {
        try seed(3)
        let directory=root.appendingPathComponent("indexes")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data(repeating:0,count:2_000_000).write(to:directory.appendingPathComponent("synthetic-cache"))
        var reader:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&reader,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        defer {sqlite3_close(reader)}
        XCTAssertEqual(sqlite3_exec(reader,"BEGIN; SELECT id FROM memories",nil,nil,nil),SQLITE_OK)
        try store.setFavorite("row-0",value:true) // Leave committed frames beyond the held read snapshot.
        try store.withRoutineDatabase {db in try db.execute("PRAGMA busy_timeout=25")}
        defer {try? store.withRoutineDatabase {db in try db.execute("PRAGMA busy_timeout=5000")}}
        let blocked=try store.pruneHistory(before:.distantPast,maxBytes:1_000_000)
        XCTAssertEqual(blocked.erasure.sources,0);XCTAssertEqual(try store.stats().count,3)
        XCTAssertEqual(try store.vectorCount(modelID:"fixture"),3)
        XCTAssertFalse(blocked.erasure.warnings.isEmpty);XCTAssertEqual(blocked.budgetMet,false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
        XCTAssertEqual(sqlite3_exec(reader,"ROLLBACK",nil,nil,nil),SQLITE_OK)
        let resumed=try store.pruneHistory(before:.distantPast,maxBytes:1_000_000)
        XCTAssertEqual(resumed.erasure.sources,0);XCTAssertEqual(resumed.budgetMet,true)
        XCTAssertTrue(resumed.erasure.warnings.isEmpty);XCTAssertEqual(try store.stats().count,3)
        XCTAssertEqual(try store.vectorCount(modelID:"fixture"),3)
        XCTAssertTrue(try XCTUnwrap(store.get("row-0")).favorite)
    }
    func testManualPauseSurvivesSearchPreparationUntilExplicitResume() async throws {
        try seed(); let cache = ANNCache(root:root)
        cache.prepare(modelID:"fixture",dimensions:32,count:128,force:true)
        cache.cancel(pauseAutomatic:true); _ = try? await cache.waitForBuild()
        XCTAssertEqual(cache.prepare(modelID:"fixture",dimensions:32,count:128,force:true).state,"paused")
        XCTAssertEqual(try store.vectorCount(modelID:"fixture"),128)
        cache.prepare(modelID:"fixture",dimensions:32,count:128,force:true,resumeBuild:true)
        let resumed = try await cache.waitForBuild(); XCTAssertEqual(resumed.state,"ready")
        XCTAssertFalse(try hits(cache).isEmpty)
    }
}
