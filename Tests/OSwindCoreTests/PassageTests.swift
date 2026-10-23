import XCTest
import CSQLite
@testable import OSwindCore

final class PassageTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    func long(_ id: String = "long", app: String = "Safari") -> Memory { Memory(id:id,app:app,title:"Synthetic passage fixture",text:String(repeating:"Archive background. ",count:900)+"Elian owns credential renewal Thursday."+String(repeating:" More background.",count:300)) }
    func save(_ memory: Memory, model: String = "fixture", vector: [Float] = [1,0]) throws {
        try store.insert(memory); _ = try store.saveVectors([VectorRecord(memory:memory,vector:[0,1])],modelID:model)
        _ = try store.savePassages(memory:memory,modelID:model,records:SemanticPassagePlan.make(memory).map { PassageVector(range:$0.range,vector:vector) })
    }
    func testFullCoverageUnicodeOverlapAndStableRanges() throws {
        let text = String(repeating:"👩🏽‍💻e\u{301}界🇺🇸\n",count:1800), memory = Memory(text:text), plan = SemanticPassagePlan.make(memory)
        XCTAssertGreaterThan(plan.count,3); var covered = 0
        for passage in plan {
            let body = try XCTUnwrap(passage.range.text(in:text))
            XCTAssertLessThanOrEqual(body.count,1200); XCTAssertTrue(passage.input.hasSuffix(body))
            XCTAssertLessThanOrEqual(passage.range.start,covered); covered = max(covered,passage.range.start+passage.range.length)
        }
        XCTAssertEqual(covered,text.utf16.count); XCTAssertEqual(plan.map(\.range),SemanticPassagePlan.make(memory).map(\.range))
        XCTAssertNil(PassageRange(start:1,length:1).text(in:"😀")); XCTAssertNil(PassageRange(start:Int.max,length:5).text(in:text)); XCTAssertNil(PassageRange(start:0,length:Int.max).text(in:text))
        let million = Memory(text:String(repeating:"a",count:1_000_000)); let full = SemanticPassagePlan.make(million)
        XCTAssertGreaterThan(full.count,64); XCTAssertEqual(full.last!.range.start+full.last!.range.length,1_000_000)
    }
    func testBestPassagePerParentExactAndNativeIndex() async throws {
        let memory = long(); try store.insert(memory); _ = try store.saveVectors([VectorRecord(memory:memory,vector:[0,1])],modelID:"fixture")
        let plan = SemanticPassagePlan.make(memory)
        let records = plan.enumerated().map { PassageVector(range:$0.element.range,vector:$0.offset == plan.count-1 ? [1,0] : [0.6,0.8]) }
        XCTAssertTrue(try store.savePassages(memory:memory,modelID:"fixture",records:records))
        let other = long("other",app:"Mail"); try save(other,vector:[0.8,0.6])
        let filter = SearchFilter(query:"meaning",limit:2)
        let exact = try store.search(filter,mode:.semantic,vector:[1,0],modelID:"fixture")
        XCTAssertEqual(exact.map(\.id),[memory.id,other.id]); XCTAssertEqual(exact[0].passage,plan.last!.range)
        XCTAssertEqual(try store.vectorCount(modelID:"fixture"),2); XCTAssertGreaterThan(try store.vectorEntityCount(modelID:"fixture"),2)
        _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:2,allowLowPower:true)
        let indexed = try store.search(filter,mode:.semantic,vector:[1,0],modelID:"fixture",indexPolicy:.indexed,allowIndexOnLowPower:true)
        XCTAssertEqual(indexed.map(\.id),exact.map(\.id)); XCTAssertEqual(indexed[0].passage,exact[0].passage)
        XCTAssertEqual(try store.search(SearchFilter(query:"meaning",app:"Mail"),mode:.semantic,vector:[1,0],modelID:"fixture",indexPolicy:.indexed,allowIndexOnLowPower:true).map(\.id),["other"])
    }
    func testSourceEditsDeletionMetadataAndStaleBatchCannotRevivePassages() throws {
        let memory = long(); try save(memory)
        let source = try VectorIndexSource(root:root,modelID:"fixture",dimensions:2), state = try source.state()
        XCTAssertTrue(try store.passagesCurrent(memory,modelID:"fixture")); XCTAssertEqual(try store.passageBacklog(modelID:"fixture",filter:SearchFilter()),0)
        let page = try source.page(after:0,through:state.highKey)
        XCTAssertEqual(Set(page.map(\.parentKey)).count,1)
        try store.setFavorite(memory.id,value:true); try store.setTags(memory.id,tags:["saved"])
        XCTAssertEqual(try source.state().head,state.head); XCTAssertTrue(try store.passagesCurrent(memory,modelID:"fixture"))
        var changed = memory; changed.text += " Revised."; try store.insert(changed)
        XCTAssertEqual(try store.vectorCount(modelID:"fixture"),0); XCTAssertTrue(try source.changes(after:state.head).records.allSatisfy {$0.vector == nil})
        let stale = SemanticPassagePlan.make(memory).map { PassageVector(range:$0.range,vector:[1,0]) }
        XCTAssertFalse(try store.savePassages(memory:memory,modelID:"fixture",records:stale)); XCTAssertEqual(try store.vectorEntityCount(modelID:"fixture"),0)
        try save(changed); let current = try source.state(); try store.delete(memory.id)
        XCTAssertEqual(try source.state().count,0); XCTAssertTrue(try source.changes(after:current.head).records.allSatisfy {$0.vector == nil})
        XCTAssertFalse(try store.savePassages(memory:memory,modelID:"fixture",records:stale))
    }
    func testInvalidIncompleteAndWrongDimensionBatchesLeavePreviousPassages() throws {
        let memory = long(); try save(memory); let before = try store.vectorEntityCount(modelID:"fixture")
        let plan = SemanticPassagePlan.make(memory)
        XCTAssertThrowsError(try store.savePassages(memory:memory,modelID:"fixture",records:[]))
        XCTAssertThrowsError(try store.savePassages(memory:memory,modelID:"fixture",records:plan.map { PassageVector(range:$0.range,vector:[1,0,0]) }))
        XCTAssertThrowsError(try store.savePassages(memory:memory,modelID:"fixture",records:plan.map { PassageVector(range:$0.range,vector:[0,0]) }))
        XCTAssertEqual(try store.vectorEntityCount(modelID:"fixture"),before)
        XCTAssertTrue(try store.passagesCurrent(memory,modelID:"fixture"))
    }
    func testSemanticExcerptUsesMatchedRangeAndOldHitsDecode() throws {
        let memory = long(), target = (memory.text as NSString).range(of:"Elian owns credential renewal Thursday.")
        let hit = SearchHit(memory:memory,score:1,match:"semantic",passage:PassageRange(start:target.location,length:target.length))
        XCTAssertTrue(hit.excerpt(query:"Who rotates depot certificates?",budget:100).contains("Elian"))
        let data = try JSONEncoder().encode(SearchHit(memory:memory,score:1,match:"semantic"))
        XCTAssertNil(try JSONDecoder().decode(SearchHit.self,from:data).passage)
    }
    func testParentTopKMatchesFullDeduplicatedOracle() {
        var items = [SemanticCandidate]()
        for i in 0..<3000 { items.append(SemanticCandidate(id:String(i%117),similarity:Double((i*31)%99),timestamp:Double(i%117))) }
        let groups: [String:[SemanticCandidate]] = Dictionary(grouping:items,by: { $0.id })
        let best = groups.values.compactMap { $0.sorted(by:SemanticCandidate.better).first }
        let expected = Array(best.sorted(by:SemanticCandidate.better).prefix(17))
        for sequence in [items,Array(items.reversed())] {
            var top = SemanticTopK(capacity:17); for item in sequence { top.offer(item) }
            XCTAssertEqual(top.sorted.map(\.id),expected.map(\.id)); XCTAssertEqual(top.sorted.map(\.similarity),expected.map(\.similarity))
        }
    }
    func testMetalDiversifiesParentsBeforeCandidateCutoffAndPersistsGroups() throws {
        guard MetalFlatIndex.canFit(dimensions:2,count:1024) else { throw XCTSkip("Metal unavailable") }
        let index = try MetalFlatIndex(dimensions:2)
        try index.addBatch((1...600).map { IndexedVector(key:UInt64($0),revision:0,vector:[1,0],parentKey:1) })
        for id in 601...610 { try index.add(UInt64(id),vector:[0.8,0.6],parentKey:UInt64(id)) }
        let keys = try index.search([1,0],count:10)
        XCTAssertEqual(keys.count,10); XCTAssertEqual(keys.filter {$0<=600}.count,1)
        let path = root.appendingPathComponent("parent.metal"); try index.save(path)
        let restored = try MetalFlatIndex(dimensions:2); try restored.load(path)
        XCTAssertEqual(try restored.search([1,0],count:10),keys)
        XCTAssertEqual(try restored.search([1,0],count:10,include:{$0>=601}).count,10)
    }
    func testAppleRebuildIndexesTailAndResumesWithoutNewKeys() async throws {
        let apple = LocalEmbedder(); guard apple.available else { throw XCTSkip("Apple English embedding unavailable") }
        let memory = long(); try store.insert(memory)
        let engine = RetrievalEngine(store:store,apple:apple)
        let final = try await engine.rebuild(configuration:SearchConfiguration()) { _ in }
        XCTAssertEqual(final.indexed,1); XCTAssertTrue(try store.passagesCurrent(memory,modelID:apple.modelID))
        let source = try VectorIndexSource(root:root,modelID:apple.modelID,dimensions:try XCTUnwrap(apple.embed("test")).count), state = try source.state()
        _ = try await engine.rebuild(configuration:SearchConfiguration()) { _ in }
        XCTAssertEqual(try source.state().head,state.head)
        let last = try XCTUnwrap(SemanticPassagePlan.make(memory).last), query = try XCTUnwrap(apple.embed(last.input))
        let hits = try store.search(SearchFilter(query:"tail"),mode:.semantic,vector:query,modelID:apple.modelID)
        XCTAssertEqual(hits.first?.id,memory.id); XCTAssertNotNil(hits.first?.passage)
    }
}

extension PassageTests {
    func testDimensionReplacementInvalidatesPassagesAndCounters() throws {
        let memory = long(); try save(memory)
        _ = try store.saveVectors([VectorRecord(memory:memory,vector:[1,0,0])],modelID:"fixture")
        XCTAssertEqual(try store.vectorEntityCount(modelID:"fixture"),1); XCTAssertEqual(try store.vectorCount(modelID:"fixture"),1)
        XCTAssertFalse(try store.passagesCurrent(memory,modelID:"fixture")); XCTAssertEqual(try store.passageBacklog(modelID:"fixture",filter:SearchFilter()),1)
    }
    func testImportBuildsApplePassagesAndPreservesParentCounts() throws {
        let apple = LocalEmbedder(); guard apple.available else { throw XCTSkip("Apple English unavailable") }
        let memory = long(); let path = root.appendingPathComponent("import.json"); try JSONEncoder().encode([memory]).write(to:path)
        XCTAssertEqual(try store.importJSON(from:path,embedder:apple),1)
        XCTAssertTrue(try store.passagesCurrent(memory,modelID:apple.modelID)); XCTAssertEqual(try store.vectorCount(modelID:apple.modelID),1)
        let entities = try store.vectorEntityCount(modelID:apple.modelID); XCTAssertGreaterThan(entities,1)
        let reopened = try MemoryStore(root:root); XCTAssertEqual(try reopened.vectorEntityCount(modelID:apple.modelID),entities)
        try reopened.deleteAll(); XCTAssertEqual(try store.vectorEntityCount(modelID:apple.modelID),0)
    }
    func testScopedBacklogUsesCurrentMetadataAndCompletion() throws {
        let a = long("a",app:"Safari"), b = long("b",app:"Mail"); try store.insert(a); try store.insert(b)
        XCTAssertEqual(try store.passageBacklog(modelID:"fixture",filter:SearchFilter(app:"Safari")),1)
        try save(a); XCTAssertEqual(try store.passageBacklog(modelID:"fixture",filter:SearchFilter(app:"Safari")),0)
        XCTAssertEqual(try store.passageBacklog(modelID:"fixture",filter:SearchFilter(app:"Mail")),1)
        try store.delete(b.id); XCTAssertEqual(try store.passageBacklog(modelID:"fixture",filter:SearchFilter()),0)
    }
}

extension PassageTests {
    func testRemovingOnlyLegacyBaseCannotLeaveOrphanPassages() throws {
        var memory = long(); memory.embedding = [1,0]; memory.embeddingModel = "fixture"; try store.insert(memory)
        let records = SemanticPassagePlan.make(memory).map { PassageVector(range:$0.range,vector:[1,0]) }
        XCTAssertTrue(try store.savePassages(memory:memory,modelID:"fixture",records:records))
        memory.embedding = nil; memory.embeddingModel = nil; try store.insert(memory)
        XCTAssertEqual(try store.vectorEntityCount(modelID:"fixture"),0); XCTAssertFalse(try store.passagesCurrent(memory,modelID:"fixture"))
        XCTAssertTrue(try store.search(SearchFilter(query:"meaning"),mode:.semantic,vector:[1,0],modelID:"fixture").isEmpty)
    }
}
