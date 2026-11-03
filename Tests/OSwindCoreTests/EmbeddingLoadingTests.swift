import XCTest
import NaturalLanguage
@testable import OSwindCore

final class EmbeddingLoadingTests:XCTestCase {
    func testConstructionAndBlankInputDoNotLoadAModel() {
        let calls=EmbeddingLoadCounter(),embedder=LocalEmbedder(loadModel:{calls.increment();return nil})
        XCTAssertEqual(embedder.modelID,"apple-nl-sentence-en-v1")
        XCTAssertNil(embedder.embed(" \n\t"));XCTAssertEqual(calls.value,0)
    }
    func testConcurrentFirstUseLoadsUnavailableModelExactlyOnce() {
        let calls=EmbeddingLoadCounter(),embedder=LocalEmbedder(loadModel:{calls.increment();return nil})
        DispatchQueue.concurrentPerform(iterations:32) {index in
            if index.isMultiple(of:2) {XCTAssertFalse(embedder.available)}
            else {XCTAssertNil(embedder.embed("Owned sentence"))}
        }
        XCTAssertEqual(calls.value,1)
        XCTAssertFalse(embedder.available);XCTAssertEqual(calls.value,1)
    }
    func testActualKeywordAndEmptyBrowseNeverResolveSentenceModel()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-lazy-embedding-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        try store.insert(Memory(id:"source",text:"Owned retrieval canary"))
        let calls=EmbeddingLoadCounter(),embedder=LocalEmbedder(loadModel:{calls.increment();return nil}),engine=RetrievalEngine(store:store,apple:embedder)
        let keyword=try await engine.search(.init(query:"canary"),mode:.keyword)
        let browse=try await engine.search(.init(query:""),mode:.hybrid)
        XCTAssertEqual(keyword.hits.map(\.id),["source"]);XCTAssertEqual(browse.hits.map(\.id),["source"])
        XCTAssertTrue(keyword.warnings.isEmpty);XCTAssertTrue(browse.warnings.isEmpty);XCTAssertEqual(calls.value,0)
    }
    func testExistingNativeSentenceModelRemainsAvailableWithNormalizedVectors()throws {
        guard let model=NLEmbedding.sentenceEmbedding(for:.english) else {throw XCTSkip("Existing English sentence model unavailable; no asset download")}
        let calls=EmbeddingLoadCounter(),embedder=LocalEmbedder(loadModel:{calls.increment();return model})
        XCTAssertEqual(calls.value,0);XCTAssertTrue(embedder.available)
        let vector=try XCTUnwrap(embedder.embed("An authored sentence about a release checklist."))
        XCTAssertEqual(vector.count,model.dimension);XCTAssertTrue(vector.allSatisfy(\.isFinite))
        XCTAssertEqual(vector.reduce(0.0) {$0+Double($1)*Double($1)},1,accuracy:0.00001)
        XCTAssertTrue(embedder.available);XCTAssertEqual(calls.value,1)
    }
}
private final class EmbeddingLoadCounter:@unchecked Sendable {
    private let lock=NSLock();private var count=0
    func increment() {lock.lock();count+=1;lock.unlock()}
    var value:Int {lock.lock();defer {lock.unlock()};return count}
}
