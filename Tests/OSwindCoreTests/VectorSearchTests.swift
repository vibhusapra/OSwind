import XCTest
@testable import OSwindCore

final class VectorSearchTests: XCTestCase {
    func testBoundedHeapMatchesFullSortAcrossInsertionOrdersAndTies() {
        let items = (0..<1200).map { SemanticCandidate(id:String(format:"%04d",$0),similarity:Double($0%17),timestamp:Double($0%31)) }
        let expected = Array(items.sorted(by:SemanticCandidate.better).prefix(100)).map(\.id)
        for order in [items,Array(items.reversed())] {
            var top = SemanticTopK(capacity:100)
            for item in order { top.offer(item); XCTAssertLessThanOrEqual(top.heap.count,100) }
            XCTAssertEqual(top.sorted.map(\.id),expected)
        }
    }
    func testPointerCosineMatchesReferenceAndRejectsInvalidVectors() throws {
        let query = [Float](arrayLiteral:3,4), stored = [Float](arrayLiteral:4,3)
        let scorer = try XCTUnwrap(CosineScorer(query))
        let score = stored.withUnsafeBufferPointer { scorer.score($0.baseAddress!,count:$0.count) }
        XCTAssertEqual(score,LocalEmbedder.cosine(query,stored),accuracy:0.000001)
        XCTAssertNil(CosineScorer([0,0])); XCTAssertNil(CosineScorer([.nan,1])); XCTAssertNil(CosineScorer([]))
        XCTAssertEqual(stored.withUnsafeBufferPointer { scorer.score($0.baseAddress!,count:1) },-.infinity)
        XCTAssertEqual([Float](repeating:0,count:2).withUnsafeBufferPointer { scorer.score($0.baseAddress!,count:2) },-.infinity)
    }
    func testStoreTopKMatchesBruteForceWithFilters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root), query = VectorScalingEvaluation.vector(row:777,dimensions:32)
        var expected = [(String,Double)](), pending = [VectorRecord]()
        for i in 0..<500 {
            let vector = VectorScalingEvaluation.vector(row:i,dimensions:32), memory = Memory(id:"row-\(i)",timestamp:Date(timeIntervalSince1970:Double(i)),app:i%2 == 0 ? "A" : "B",text:"Fixture")
            try store.insert(memory); pending.append(VectorRecord(memory:memory,vector:vector))
            if i%2 == 0 && i >= 100 && i < 400 { expected.append((memory.id,LocalEmbedder.cosine(query,vector))) }
        }
        _ = try store.saveVectors(pending,modelID:"fixture")
        let actual = try store.search(SearchFilter(query:"query",app:"A",start:Date(timeIntervalSince1970:100),end:Date(timeIntervalSince1970:400),limit:25),mode:.semantic,vector:query,modelID:"fixture",minimumSimilarity:-1)
        XCTAssertEqual(actual.map(\.id),expected.sorted { $0.1 > $1.1 }.prefix(25).map(\.0))
    }
    func testUpdatedIndexOverridesLegacyVectorWithoutDuplicateRanks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root); var first = Memory(id:"first",text:"First"); first.embedding = [1,0]; first.embeddingModel = "same"
        try store.insert(first); _ = try store.saveVectors([VectorRecord(memory:first,vector:[0,1])],modelID:"same")
        let second = Memory(id:"second",text:"Second"); try store.insert(second); _ = try store.saveVectors([VectorRecord(memory:second,vector:[1,0])],modelID:"same")
        let hits = try store.search(SearchFilter(query:"meaning"),mode:.semantic,vector:[1,0],modelID:"same")
        XCTAssertEqual(hits.map(\.id),["second"])
    }
    func testTopKSelectsNewestWhenScoresTie() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root)
        for i in 0..<150 { var memory = Memory(id:"row-\(i)",timestamp:Date(timeIntervalSince1970:Double(i)),text:"Fixture"); memory.embedding = [1,0]; memory.embeddingModel = "same"; try store.insert(memory) }
        let hits = try store.search(SearchFilter(query:"meaning",limit:5),mode:.semantic,vector:[1,0],modelID:"same")
        XCTAssertEqual(hits.map(\.id),["row-149","row-148","row-147","row-146","row-145"])
    }
}
