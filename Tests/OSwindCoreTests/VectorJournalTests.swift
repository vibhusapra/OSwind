import XCTest
@testable import OSwindCore

final class VectorJournalTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    func source(_ model: String = "fixture") throws -> VectorIndexSource { try VectorIndexSource(root:root,modelID:model,dimensions:2) }
    func memory(_ id: String = "a", model: String = "fixture") -> Memory { var memory = Memory(id:id,text:"Original evidence"); memory.embedding = [1,0]; memory.embeddingModel = model; return memory }
    func testLegacyJournalTracksOverwriteAndNeverReusesDeletedKey() throws {
        let reader = try source(); let original = memory(); try store.insert(original)
        let first = try reader.state(), page = try reader.page(after:0,through:first.highKey)
        XCTAssertEqual(first.count,1); XCTAssertEqual(page[0].vector,[1,0])
        var revised = original; revised.embedding = [0,1]; try store.insert(revised)
        let changes = try reader.changes(after:first.head); XCTAssertEqual(changes.records[0].key,page[0].key); XCTAssertEqual(changes.records[0].vector,[0,1])
        try store.delete(original.id); let deleted = try reader.changes(after:changes.sequence)
        XCTAssertEqual(deleted.records[0].key,page[0].key); XCTAssertNil(deleted.records[0].vector)
        try store.insert(original); XCTAssertGreaterThan(try reader.state().highKey,first.highKey)
    }
    func testAdditionalVectorsOverrideLegacyAndFallbackWhenRemovedByContentEdit() throws {
        let original = memory(); try store.insert(original); _ = try store.saveVectors([VectorRecord(memory:original,vector:[0,1])],modelID:"fixture")
        let reader = try source(), before = try reader.state()
        XCTAssertEqual(before.count,1); XCTAssertEqual(try reader.page(after:0,through:before.highKey)[0].vector,[0,1])
        var changed = original; changed.text = "Revised evidence"; changed.embedding = [0.6,0.8]; try store.insert(changed)
        let changes = try reader.changes(after:before.head)
        XCTAssertEqual(changes.records.count,1); XCTAssertEqual(changes.records[0].vector,[0.6,0.8]); XCTAssertGreaterThan(changes.records[0].revision,before.head)
    }
    func testGPUOnlyVectorIsRemovedOnSourceEditAndDelete() throws {
        let original = Memory(id:"gpu",text:"Evidence"); try store.insert(original); _ = try store.saveVectors([VectorRecord(memory:original,vector:[1,0])],modelID:"fixture")
        let reader = try source(), before = try reader.state()
        try store.insert(Memory(id:"gpu",text:"Different evidence"))
        let changes = try reader.changes(after:before.head); XCTAssertEqual(changes.records.count,1); XCTAssertNil(changes.records[0].vector)
        XCTAssertEqual(try reader.state().count,0)
    }
    func testJournalIsVisibleAcrossConnectionsAndIgnoresMetadataEdits() throws {
        let original = memory(); try store.insert(original); let reader = try source(), initial = try reader.state()
        let other = try MemoryStore(root:root); try other.setFavorite("a",value:true); XCTAssertEqual(try reader.state().head,initial.head)
        try other.delete("a"); XCTAssertNil(try reader.changes(after:initial.head).records.first?.vector)
        XCTAssertEqual(try reader.state().count,0)
    }
    func testChangesAdvanceAcrossOtherModelsAndInvalidShapesAreNotIndexed() throws {
        try store.insert(memory(model:"other")); let reader = try source(), state = try reader.state()
        let changes = try reader.changes(after:0); XCTAssertTrue(changes.records.isEmpty); XCTAssertEqual(changes.sequence,state.head)
        var wrong = memory(); wrong.embedding = [1,0,0]; try store.insert(wrong)
        let records = try reader.changes(after:state.head).records; XCTAssertEqual(records.count,1); XCTAssertNil(records[0].vector)
    }
}
