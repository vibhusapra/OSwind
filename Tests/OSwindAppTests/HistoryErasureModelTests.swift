import XCTest
import OSwindCore
@testable import OSwind

final class HistoryErasureModelTests:XCTestCase {
    @MainActor func testPreviewApplyRefreshAndBusyGuard() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),model=HistoryErasureModel();try store.insert(Memory(app:"Safari",text:"owned"));try store.insert(Memory(app:"Notes",text:"keep"))
        model.inspect(store:store,scope:.init(app:"Safari"));XCTAssertTrue(model.busy);model.inspect(store:store,scope:.init(app:"Notes"))
        for _ in 0..<200 where model.busy {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.preview?.sources,1);XCTAssertEqual(model.preview?.scope.app,"Safari");XCTAssertEqual(try store.stats().count,2)
        var completed=false;model.apply(store:store) {completed=true};XCTAssertTrue(model.busy)
        for _ in 0..<200 where model.busy {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(completed);XCTAssertNil(model.error);XCTAssertNil(model.preview);XCTAssertEqual(model.result?.sources,1);XCTAssertEqual(try store.stats().count,1)
        model.invalidate();XCTAssertNil(model.result)
    }
    @MainActor func testStalePreviewReportsNoEraseAndCanRetry() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),model=HistoryErasureModel();try store.insert(Memory(id:"one",app:"Safari",text:"owned"))
        model.inspect(store:store,scope:.init(app:"Safari"));for _ in 0..<200 where model.busy {try await Task.sleep(nanoseconds:10_000_000)}
        try store.setFavorite("one",value:true);model.apply(store:store) {XCTFail("Stale deletion completed")}
        for _ in 0..<200 where model.busy {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNotNil(model.error);XCTAssertNil(model.result);XCTAssertEqual(try store.stats().count,1)
        model.inspect(store:store,scope:.init(app:"Safari"));for _ in 0..<200 where model.busy {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNil(model.error);XCTAssertEqual(model.preview?.sources,1)
    }
}
