import XCTest
import Combine
@testable import OSwindCore
@testable import OSwind

private actor VisualSetupGate {
    let entered=XCTestExpectation(description:"visual model preparation entered")
    var continuation:CheckedContinuation<Void,Never>?
    var calls=0
    func wait() async {calls+=1;await withCheckedContinuation {continuation=$0;entered.fulfill()}}
    func release(){continuation?.resume();continuation=nil}
}
@MainActor final class VisualModelSetupTests:XCTestCase {
    func wait(_ model:VisualModelSetupModel) async throws {for _ in 0..<500 where model.busy {try await Task.sleep(for:.milliseconds(10))};XCTAssertFalse(model.busy)}
    func testSuccessPublishesOneVerifiedSelectionAndBusyGuardBlocksSecondJob() async throws {
        let gate=VisualSetupGate(),model=VisualModelSetupModel(installer:{progress in progress(.init(phase:"Fixture download",completedBytes:1,totalBytes:10,completedFiles:0,totalFiles:1,file:nil));await gate.wait();return .init(directory:URL(fileURLWithPath:"/owned/model"),modelID:"fixture",bytes:10,reused:false)})
        let published=XCTestExpectation(description:"owned preparation progress published")
        let observation=model.$progress.compactMap {$0}.first().sink {_ in published.fulfill()};defer {observation.cancel()}
        var completions=0;model.start {_ in completions+=1};model.start {_ in completions+=100}
        await fulfillment(of:[gate.entered,published],timeout:10)
        XCTAssertTrue(model.busy);XCTAssertEqual(model.progress?.phase,"Fixture download");await gate.release();try await wait(model)
        XCTAssertEqual(completions,1);let calls=await gate.calls;XCTAssertEqual(calls,1);XCTAssertNil(model.error)
    }
    func testLibrarySwitchCancelsPreparationAndDiscardsLateSuccessfulResult() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-visual-setup-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let gate=VisualSetupGate(),model=VisualModelSetupModel(installer:{_ in await gate.wait();return .init(directory:root.appendingPathComponent("late"),modelID:"fixture",bytes:10,reused:false)}),app=try AppModel(root:root,startServices:false,visualSetup:model)
        var selected=false;model.start {_ in selected=true};await fulfillment(of:[gate.entered],timeout:5)
        app.prepareForLibrarySwitch();XCTAssertTrue(model.cancelling);XCTAssertTrue(model.busy)
        await gate.release();try await wait(model);XCTAssertFalse(selected);XCTAssertTrue(model.status.contains("Cancelled"));XCTAssertEqual(app.settings.search.visual.modelDirectory,"")
    }
    func testSelectingPreparedModelsPreservesDisabledChoiceAndTextIndexing() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-model-selection-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let app=try AppModel(root:root,startServices:false);defer {app.prepareForLibrarySwitch()}
        app.indexing=true;app.indexStatus="Text job active";app.settings.search.visual.enabled=false
        app.selectPreparedVisualModel(.init(directory:root.appendingPathComponent("prepared"),modelID:"fixture",bytes:10,reused:false))
        XCTAssertFalse(app.settings.search.visual.enabled);XCTAssertTrue(app.indexing);XCTAssertEqual(app.indexStatus,"Text job active")
        XCTAssertEqual(app.settings.search.visual.modelDirectory,root.appendingPathComponent("prepared").path)
        XCTAssertTrue(app.visualIndexStatus.contains("Enable visual memory"))
        try app.store.close();app.selectPreparedVisualModel(.init(directory:root.appendingPathComponent("late"),modelID:"fixture",bytes:10,reused:false))
        XCTAssertEqual(app.settings.search.visual.modelDirectory,root.appendingPathComponent("prepared").path)
    }
    func testFailedPreparationReportsErrorAndCanRetry() async throws {
        let model=VisualModelSetupModel(installer:{_ in throw OSwindError.network("Owned fixture download failed")})
        model.start {_ in XCTFail("Failure became installed")};try await wait(model)
        XCTAssertTrue(model.error?.contains("Owned fixture download failed")==true);XCTAssertFalse(model.cancelling)
        model.start {_ in XCTFail("Failure became installed")};XCTAssertTrue(model.busy);try await wait(model)
    }
}
