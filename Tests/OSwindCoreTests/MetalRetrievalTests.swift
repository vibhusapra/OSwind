import XCTest
@testable import OSwindCore

final class MetalRetrievalTests: XCTestCase {
    private func metal(dimensions: Int = 32, budget: Int? = nil) throws -> MetalFlatIndex {
        guard MetalFlatIndex.canFit(dimensions:dimensions,count:1024) else { throw XCTSkip("Unified-memory Metal device unavailable") }
        return try MetalFlatIndex(dimensions:dimensions,byteBudget:budget)
    }
    func testExhaustiveNonselfRecallFilteredAndUnfiltered() throws {
        let index = try metal(); try index.reserve(1024)
        let vectors = (0..<1024).map { VectorScalingEvaluation.vector(row:$0,dimensions:32) }
        try index.addBatch(vectors.enumerated().map { IndexedVector(key:UInt64($0.offset+1),revision:0,vector:$0.element) })
        for seed in 1031..<1039 {
            let query = VectorScalingEvaluation.vector(row:seed,dimensions:32), scorer = try XCTUnwrap(CosineScorer(query))
            for filtered in [false,true] {
                let scores = vectors.map { values in values.withUnsafeBufferPointer { scorer.score($0.baseAddress!,count:32) } }
                let expected = vectors.indices.filter { !filtered || $0%3 == 0 }.sorted { scores[$0] > scores[$1] }.prefix(10).map {UInt64($0+1)}
                // Product requests 200 candidates and reranks originals in SQL.
                let found = try index.search(query,count:200,include:{ !filtered || ($0-1)%3 == 0 })
                XCTAssertTrue(Set(expected).isSubset(of:Set(found)))
            }
        }
    }
    func testReplacementDeletionHolesGrowthAndPersistence() throws {
        let index = try metal(); let query = VectorScalingEvaluation.vector(row:17,dimensions:32)
        for i in 1...80 { try index.add(UInt64(i),vector:VectorScalingEvaluation.vector(row:i,dimensions:32)) }
        try index.add(17,vector:query.map { -$0 }); try index.remove(19); try index.remove(19)
        try index.add(1001,vector:query)
        XCTAssertEqual(index.count,80); XCTAssertEqual(try index.search(query,count:5).first,1001)
        XCTAssertFalse(try index.search(query,count:200).contains(19))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:url) }
        try index.save(url); let loaded = try metal(); try loaded.load(url)
        XCTAssertEqual(loaded.count,80); XCTAssertEqual(try loaded.search(query,count:200),try index.search(query,count:200))
        try loaded.remove(1001); XCTAssertFalse(try loaded.search(query,count:200).contains(1001))
        XCTAssertThrowsError(try metal(dimensions:64).load(url))
        var data = try Data(contentsOf:url); data.removeLast(); try data.write(to:url)
        XCTAssertThrowsError(try metal().load(url))
    }
    func testInvalidVectorsAndBudgetFailWithoutPartialInsertion() throws {
        let index = try metal(budget:4096)
        XCTAssertThrowsError(try index.reserve(Int.max)); XCTAssertEqual(index.count,0)
        XCTAssertThrowsError(try index.add(0,vector:Array(repeating:1,count:32)))
        XCTAssertThrowsError(try index.add(UInt64.max,vector:Array(repeating:1,count:32)))
        XCTAssertThrowsError(try index.add(1,vector:Array(repeating:0,count:32)))
        XCTAssertThrowsError(try index.add(1,vector:Array(repeating:.infinity,count:32)))
        XCTAssertThrowsError(try index.search([1],count:10)); XCTAssertEqual(index.count,0)
        try index.add(1,vector:Array(repeating:1,count:32)); XCTAssertEqual(try index.search(Array(repeating:1,count:32),count:10),[1])
        // File sizes are checked before large allocations and reads.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:url) }
        try Data([255,255,255,255]).write(to:url); XCTAssertThrowsError(try index.load(url))
    }
    func testCancelledSearchDoesNotChangeIndex() async throws {
        let index = try metal(), vector = VectorScalingEvaluation.vector(row:17,dimensions:32)
        try index.add(1,vector:vector)
        // Cancel before the backend guard without depending on scheduler order.
        let gate = DispatchSemaphore(value:0)
        let guarded = Task.detached { gate.wait(); return try index.search(vector,count:10) }
        guarded.cancel(); gate.signal()
        do { _ = try await guarded.value; XCTFail("Expected backend cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(index.count,1)
    }
    func testCacheRejectsRepeatedKeysBeforeUsingVectors() throws {
        let index = try metal(); try index.add(1,vector:Array(repeating:1,count:32)); try index.add(2,vector:Array(repeating:2,count:32))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:url) }
        try index.save(url)
        var data = try Data(contentsOf:url)
        let length = data.withUnsafeBytes { Int(UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self))) }, first = 4+length
        data.replaceSubrange((first+8)..<(first+16),with:data[first..<(first+8)])
        try data.write(to:url); XCTAssertThrowsError(try metal().load(url))
    }
    func testProductCacheUsesMetalAndLiveMetadataFromOtherConnection() async throws {
        _ = try metal()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root), model = "metal-fixture", query = VectorScalingEvaluation.vector(row:21317,dimensions:32)
        for i in 0..<20_000 {
            var memory = Memory(id:"row-\(i)",timestamp:Date(timeIntervalSince1970:Double(i)),kind:i%2 == 0 ? .note : .audio,app:i%3 == 0 ? "A" : "B",text:"Metal fixture \(i)",favorite:i%7 == 0,tags:i%5 == 0 ? ["work"] : [])
            memory.embedding = VectorScalingEvaluation.vector(row:i,dimensions:32); memory.embeddingModel = model; try store.insert(memory)
        }
        _ = try await store.buildSearchIndex(modelID:model,dimensions:32)
        let graphs = try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("indexes").path)
        XCTAssertEqual(graphs.filter {$0.hasSuffix(".metal")}.count,1)
        func compare(_ source: MemoryStore,_ scope: SearchFilter) throws -> [SearchHit] {
            let exact = try source.search(scope,mode:.semantic,vector:query,modelID:model,minimumSimilarity:-1,indexPolicy:.exact)
            var strategy = ""
            let found = try source.search(scope,mode:.semantic,vector:query,modelID:model,minimumSimilarity:-1,indexPolicy:.indexed) { strategy = $0.strategy }
            XCTAssertEqual(strategy,"metal-exact-rerank"); XCTAssertEqual(found.map(\.id),exact.map(\.id)); return found
        }
        let all = SearchFilter(query:"meaning",limit:10), before = try compare(store,all), target = try XCTUnwrap(before.first?.id)
        let other = try MemoryStore(root:root)
        try other.setFavorite(target,value:true); try other.setTags(target,tags:["changed"])
        XCTAssertEqual(try compare(store,SearchFilter(query:"meaning",favoritesOnly:true,tag:"changed",limit:10)).first?.id,target)
        try other.setFavorite(target,value:false)
        XCTAssertTrue(try compare(store,SearchFilter(query:"meaning",favoritesOnly:true,tag:"changed",limit:10)).isEmpty)
        _ = try compare(store,SearchFilter(query:"meaning",app:"A",kind:.note,start:Date(timeIntervalSince1970:100),end:Date(timeIntervalSince1970:15000),tag:"work",limit:10))
        try other.delete(target)
        var fresh = Memory(id:"new",text:"New vector from another connection"); fresh.embedding = query; fresh.embeddingModel = model; try other.insert(fresh)
        XCTAssertEqual(try compare(store,all).first?.id,"new")
        let reopened = try MemoryStore(root:root)
        XCTAssertEqual(try compare(reopened,all).first?.id,"new")
        try other.deleteAll()
        XCTAssertTrue(try store.search(all,mode:.semantic,vector:query,modelID:model,minimumSimilarity:-1,indexPolicy:.indexed).isEmpty)
    }
}
