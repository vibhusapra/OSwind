import XCTest
@testable import OSwindCore

final class IndexedRetrievalTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    func seed() throws {
        for i in 0..<256 {
            var memory = Memory(id:"row-\(i)",timestamp:Date(timeIntervalSince1970:Double(i)),kind:i%2 == 0 ? .note : .audio,app:i%4 == 0 ? "A" : "B",text:"Fixture \(i)",favorite:i%3 == 0,tags:i%5 == 0 ? ["work"] : [])
            memory.embedding = VectorScalingEvaluation.vector(row:i,dimensions:32); memory.embeddingModel = "fixture"; try store.insert(memory)
        }
    }
    func testIndexedResultsMatchExactWithEveryScopeIncludingFavoritesOnly() async throws {
        try seed(); _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:32)
        let query = VectorScalingEvaluation.vector(row:42,dimensions:32)
        let scopes = [SearchFilter(query:"meaning",limit:5),SearchFilter(query:"meaning",favoritesOnly:true,limit:5),SearchFilter(query:"meaning",app:"A",limit:5),SearchFilter(query:"meaning",kind:.audio,start:Date(timeIntervalSince1970:50),end:Date(timeIntervalSince1970:200),limit:5),SearchFilter(query:"meaning",tag:"work",limit:5)]
        for scope in scopes {
            let exact = try store.search(scope,mode:.semantic,vector:query,modelID:"fixture",minimumSimilarity:-1)
            var strategy = ""
            let indexed = try store.search(scope,mode:.semantic,vector:query,modelID:"fixture",minimumSimilarity:-1,indexPolicy:.indexed) { strategy = $0.strategy }
            XCTAssertEqual(indexed.map(\.id),exact.map(\.id)); XCTAssertEqual(strategy,"ann-exact-rerank")
        }
        XCTAssertEqual(try store.vectorCount(modelID:"fixture",filter:SearchFilter(favoritesOnly:true)),86)
    }
    func testLiveSQLRejectsStaleGraphRowsAndSearchesUnreplayedUpdatesExactly() async throws {
        try seed(); _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:32)
        let query = VectorScalingEvaluation.vector(row:42,dimensions:32), scorer = try XCTUnwrap(CosineScorer(query))
        let other = try MemoryStore(root:root)
        // Bypass public erasure's deliberate cache invalidation to exercise the live SQL
        // guard against an unreplayed external mutation. No media is attached to this fixture.
        try other.withRoutineDatabase {try $0.execute("DELETE FROM memories WHERE id='row-42'")}
        var fresh = Memory(id:"fresh",text:"New evidence after the cache snapshot"); fresh.embedding = query; fresh.embeddingModel = "fixture"; try other.insert(fresh)
        var revised = try XCTUnwrap(other.get("row-12")); revised.embedding = query.map { -$0 }; revised.text = "Changed after cache snapshot"; try other.insert(revised)
        // Deliberately use the old graph without its normal prepare/replay pass.
        let candidates = try XCTUnwrap(store.indexedCandidates(SearchFilter(query:"meaning",limit:5),modelID:"fixture",dimensions:32,scorer:scorer,minimumSimilarity:0.15,limit:100))
        XCTAssertEqual(candidates.first?.id,"fresh"); XCTAssertFalse(candidates.contains { $0.id == "row-42" || $0.id == "row-12" })
    }
    func testStoreIdentityPreventsUsingAnErasedGraphWithoutReplay() async throws {
        try seed(); _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:32)
        let other = try MemoryStore(root:root); try other.deleteAll()
        let scorer = try XCTUnwrap(CosineScorer(VectorScalingEvaluation.vector(row:42,dimensions:32)))
        XCTAssertNil(try store.indexedCandidates(SearchFilter(query:"meaning"),modelID:"fixture",dimensions:32,scorer:scorer,minimumSimilarity:-1,limit:100))
    }
    func testLargeUnreplayedBackfillRequestsExactFallback() async throws {
        try seed(); _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:32)
        let vector = VectorScalingEvaluation.vector(row:42,dimensions:32)
        for i in 0..<5001 { var memory = Memory(id:"new-\(i)",text:"New evidence"); memory.embedding = vector; memory.embeddingModel = "fixture"; try store.insert(memory) }
        XCTAssertNil(try store.indexedCandidates(SearchFilter(query:"meaning"),modelID:"fixture",dimensions:32,scorer:try XCTUnwrap(CosineScorer(vector)),minimumSimilarity:-1,limit:100))
    }
    func testRepeatedIdenticalCapturesIncludeNewestSources() async throws {
        let vector = VectorScalingEvaluation.vector(row:42,dimensions:32)
        for i in 0..<300 { var memory = Memory(id:"same-\(i)",timestamp:Date(timeIntervalSince1970:Double(i)),text:"Identical capture"); memory.embedding = vector; memory.embeddingModel = "fixture"; try store.insert(memory) }
        _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:32)
        let hits = try store.search(SearchFilter(query:"meaning",limit:5),mode:.semantic,vector:vector,modelID:"fixture",indexPolicy:.indexed)
        XCTAssertEqual(hits.map(\.id),["same-299","same-298","same-297","same-296","same-295"])
    }
    func testIndexPowerPolicyDefersHeavyWork() {
        XCTAssertNotNil(IndexPowerPolicy.blockedReason(lowPower:true,thermal:.nominal,allowLowPower:false))
        XCTAssertNil(IndexPowerPolicy.blockedReason(lowPower:true,thermal:.nominal,allowLowPower:true))
        XCTAssertNotNil(IndexPowerPolicy.blockedReason(lowPower:false,thermal:.serious,allowLowPower:true))
        XCTAssertNil(IndexPowerPolicy.blockedReason(lowPower:false,thermal:.fair,allowLowPower:false))
    }
    func testPublicErasureInvalidatesOldGraphThenRebuildRestoresIndexedResults() async throws {
        try seed();_ = try await store.buildSearchIndex(modelID:"fixture",dimensions:32)
        let query=VectorScalingEvaluation.vector(row:42,dimensions:32),scorer=try XCTUnwrap(CosineScorer(query)),other=try MemoryStore(root:root)
        XCTAssertTrue(try other.delete("row-42").searchCacheRemoved)
        XCTAssertNil(try store.indexedCandidates(SearchFilter(query:"meaning",limit:5),modelID:"fixture",dimensions:32,scorer:scorer,minimumSimilarity:-1,limit:100))
        let fallback=try store.search(.init(query:"meaning",limit:5),mode:.semantic,vector:query,modelID:"fixture",minimumSimilarity:-1,indexPolicy:.indexed)
        XCTAssertFalse(fallback.contains {$0.id=="row-42"})
        _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:32)
        let ready=try XCTUnwrap(store.indexedCandidates(SearchFilter(query:"meaning",limit:5),modelID:"fixture",dimensions:32,scorer:scorer,minimumSimilarity:-1,limit:100))
        XCTAssertFalse(ready.contains {$0.id=="row-42"});XCTAssertFalse(ready.isEmpty)
    }

}
