import XCTest
@testable import OSwindCore
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
    @MainActor func testHistoricalOnlyPreviewCanApplyAndPreservesCurrentOwner() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()};let model=HistoryErasureModel(),origin="00000000-0000-0000-0000-000000005901"
        let current=Memory(id:"owner",kind:.note,app:"Notes",title:"Current",text:"New current owner");try store.insert(current)
        let old=Memory(id:"old",kind:.screen,app:"Safari",title:"Old original",text:"Old original body"),body=try SyncSourceBody(memory:old,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No parents")}
        let packet=try SyncPortableRecord(identity:.init(table:.source,origin:origin,lifetime:UUID().uuidString.lowercased()),body:.source(body))
        let handle=UUID().uuidString.lowercased();try store.withRoutineDatabase {try HistoricalEvidenceStore(database:$0).insert(handle:handle,source:current.id,record:packet,paths:[:],parents:[])}
        model.inspect(store:store,scope:.init(app:"Safari"))
        for _ in 0..<500 where model.busy {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertEqual(model.preview?.sources,0);XCTAssertEqual(model.preview?.historicalVersions,1);XCTAssertTrue(model.preview?.canErase==true)
        var complete=false;model.apply(store:store) {complete=true}
        for _ in 0..<500 where model.busy {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertTrue(complete);XCTAssertNil(model.error);XCTAssertEqual(model.result?.historicalVersions,1);XCTAssertEqual(model.result?.sources,0)
        XCTAssertEqual(try store.get(current.id),current);XCTAssertThrowsError(try store.historicalMemory(handle))
    }

}
