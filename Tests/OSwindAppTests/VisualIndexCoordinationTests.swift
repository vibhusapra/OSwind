import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class VisualIndexCoordinationTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-visual-coordination-"+UUID().uuidString);app=try AppModel(root:root,startServices:false)}
    override func tearDownWithError() throws {app.prepareForLibrarySwitch();app=nil;try? FileManager.default.removeItem(at:root)}
    func testVisualConfigurationCancelsVisualWorkWithoutInterruptingTextIndexing() async throws {
        app.indexing=true;app.indexStatus="Text indexing in progress"
        let generation=app.visualGeneration,worker=Task {do {try await Task.sleep(for:.seconds(60))}catch{}}
        app.visualIndexTask=worker;app.visualIndexing=true
        app.settings.search.visual.retention = .afterUse
        XCTAssertTrue(worker.isCancelled);await worker.value
        XCTAssertNotEqual(app.visualGeneration,generation);XCTAssertFalse(app.visualIndexing)
        XCTAssertTrue(app.indexing);XCTAssertEqual(app.indexStatus,"Text indexing in progress")
        XCTAssertEqual(AppSettings.load(root:root).search.visual.retention,.afterUse)
    }
    func testTextModelChangeStillInterruptsItsOwnIndexWithoutCancellingVisualWork() async throws {
        app.indexing=true;app.indexStatus="Text indexing in progress"
        let generation=app.visualGeneration,worker=Task {do {try await Task.sleep(for:.seconds(60))}catch{}}
        app.visualIndexTask=worker;app.visualIndexing=true
        app.settings.search.model="different-local-embedding-model"
        XCTAssertFalse(app.indexing);XCTAssertEqual(app.indexStatus,"Search settings changed; prepare the selected index")
        XCTAssertFalse(worker.isCancelled);XCTAssertEqual(app.visualGeneration,generation);XCTAssertTrue(app.visualIndexing)
        app.cancelVisualIndexing();await worker.value
    }
    func testScopedErasureCancelsBothVisualReadersReleasesMediaAndPreventsWakeRestart() async throws {
        app.settings.search.visual.enabled=true
        let memory=Memory(id:"erase",app:"Owned fixture",text:"",imagePath:"images/one.dat")
        try Data("Owned fixture image bytes".utf8).write(to:root.appendingPathComponent(memory.imagePath!));try app.store.insert(memory)
        let first=try XCTUnwrap(VisualImageSnapshot.make(store:app.store,id:memory.id)),second=try XCTUnwrap(VisualImageSnapshot.make(store:app.store,id:memory.id))
        let entered=XCTestExpectation(description:"Both visual readers entered");entered.expectedFulfillmentCount=2
        let manual=Task.detached {defer {first.release()};entered.fulfill();do {try await Task.sleep(for:.seconds(60))}catch{}}
        let automatic=Task.detached {defer {second.release()};entered.fulfill();do {try await Task.sleep(for:.seconds(60))}catch{}}
        app.visualIndexTask=manual;app.visualAutomaticTask=automatic;app.visualIndexing=true;app.visualAutomaticIndexing=true;app.pendingVisualIDs=[memory.id]
        await fulfillment(of:[entered],timeout:5)
        app.pauseForHistoryErasure();XCTAssertTrue(manual.isCancelled);XCTAssertTrue(automatic.isCancelled)
        await manual.value;await automatic.value
        XCTAssertFalse(app.visualIndexing);XCTAssertFalse(app.visualAutomaticIndexing);XCTAssertTrue(app.pendingVisualIDs.isEmpty)
        XCTAssertFalse(app.visualAutoResumeAllowed);app.resumeAutomaticVisualIndex();XCTAssertFalse(app.visualIndexing)
        XCTAssertThrowsError(try first.validatedMemory());XCTAssertThrowsError(try second.validatedMemory())
        let model=HistoryErasureModel();model.inspect(store:app.store,scope:.init(app:"Owned fixture"))
        for _ in 0..<500 where model.busy {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(model.busy);XCTAssertEqual(model.preview?.sources,1)
        model.apply(store:app.store) {}
        for _ in 0..<500 where model.busy {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(model.busy);XCTAssertNil(model.error);XCTAssertEqual(model.result?.sources,1)
        XCTAssertNil(try app.store.get(memory.id));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(memory.imagePath!).path))
        XCTAssertFalse(app.isCapturing);XCTAssertFalse(app.audio.running)
    }
}
