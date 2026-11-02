import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class SearchIndexLifecycleTests:XCTestCase {
    var root:URL!,app:AppModel!
    var gates=[AudioImportGate]()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-search-index-lifetime-"+UUID().uuidString)
        app=try AppModel(root:root,startServices:false)
        app.settings.captureOnLaunch=false;app.settings.apiEnabled=false;app.settings.routinesEnabled=false;app.settings.automaticMaintenance=false;app.settings.entityAutomaticIndex=false
        app.settings.search.indexOnLowPower=true;app.settings.search.visual.enabled=true;app.settings.search.visual.automaticIndex=true;app.settings.search.visual.modelDirectory=root.path
        app.showOnboarding=false
        try Data("Owned fixture image bytes".utf8).write(to:root.appendingPathComponent("images/owned.dat"))
        try app.store.insert(Memory(id:"owned",kind:.screen,text:"Owned source",imagePath:"images/owned.dat"))
    }
    override func tearDown()async throws {
        for gate in gates {await gate.open()}
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();app=nil
        try? FileManager.default.removeItem(at:root)
    }
    func start(_ phase:AppModel.SearchWorkPhase)async throws {
        switch phase {
        case .query,.queryRead:app.query="Owned";app.refresh()
        case .textRebuild:app.rebuildIndex()
        case .fastIndex:app.prepareFastIndex()
        case .automaticText:app.addNote(String(repeating:"Owned long source sentence. ",count:160))
        case .visualRebuild:
            guard app.visualPowerAllowed else {throw XCTSkip("Visual fixture requires current thermal policy to permit work")}
            app.rebuildVisualIndex()
        case .automaticVisual:
            guard app.visualPowerAllowed else {throw XCTSkip("Visual fixture requires current thermal policy to permit work")}
            app.pendingVisualIDs=["owned"];app.visualAutoResumeAllowed=true;app.startAutomaticVisualIndex()
        }
    }
    func held(_ phase:AppModel.SearchWorkPhase,cancelDrain:Bool=false)async throws {
        try await SourceWorkTestJob.settle(app)
        let gate=AudioImportGate(),done=expectation(description:"Actual search/index task returned");gates.append(gate)
        app.searchWorkObserver={if $0==phase {await gate.wait()}}
        app.searchWorkCompleted={if $0==phase {done.fulfill()}}
        try await start(phase);await fulfillment(of:[gate.entered],timeout:10)
        try await SourceWorkTestJob.settleForIndexFixture(app,queryHeld:phase == .query)
        XCTAssertTrue(app.hasPendingExitWork,"Actual pre-reservation search/index work must own exit")
        app.prepareForLibrarySwitch();let indexStatus=app.indexStatus,visualStatus=app.visualIndexStatus
        var drained=false;let drain=Task {await self.app.cancelExternalWorkAndWait();drained=true};if cancelDrain {drain.cancel()}
        await fulfillment(of:[gate.cancelled],timeout:5)
        try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(drained,"Drain must not acknowledge before actual task returns")
        await gate.open();await fulfillment(of:[done],timeout:10);await drain.value
        XCTAssertEqual(app.indexStatus,indexStatus,"Retired text/fast index cannot publish status")
        XCTAssertEqual(app.visualIndexStatus,visualStatus,"Retired visual index cannot publish status")
        XCTAssertFalse(app.hasPendingExitWork)
    }
    func retired(_ phase:AppModel.SearchWorkPhase)async throws {
        try await SourceWorkTestJob.settle(app);app.prepareForLibrarySwitch()
        let done=XCTestExpectation(description:"No queued retired job"),before=app.indexStatus,visualBefore=app.visualIndexStatus
        app.searchWorkObserver={if $0==phase {XCTFail("Retired workspace admitted search/index work")}}
        app.searchWorkCompleted={if $0==phase {done.fulfill()}}
        try await start(phase)
        if phase == .visualRebuild {XCTAssertFalse(app.visualIndexing)}else {XCTAssertFalse(app.indexing)}
        // Current implementation starts the task; completion is observed so no
        // fixture is removed while that original task is still running.
        if app.indexing || app.visualIndexing {await fulfillment(of:[done],timeout:10)}else {done.isInverted=true;await fulfillment(of:[done],timeout:0.05)}
        XCTAssertEqual(app.indexStatus,before);XCTAssertEqual(app.visualIndexStatus,visualBefore)
    }
    func testQueryDrainOwnsActualPreQueryTaskUntilItReturns()async throws {try await held(.query)}
    func testTextRebuildDrainOwnsActualTaskAndSuppressesRetiredStatus()async throws {try await held(.textRebuild)}
    func testFastPreparationDrainOwnsActualTaskAndSuppressesRetiredStatus()async throws {try await held(.fastIndex)}
    func testManualVisualRebuildDrainOwnsActualPreModelTask()async throws {try await held(.visualRebuild)}
    func testAutomaticTextIndexDrainOwnsActualCapturedSourceTask()async throws {try await held(.automaticText)}
    func testAutomaticVisualIndexDrainOwnsActualCapturedSourceTask()async throws {try await held(.automaticVisual)}
    func testRetiredTextRebuildCannotStartOrPublish()async throws {try await retired(.textRebuild)}
    func testRetiredFastPreparationCannotStartOrPublish()async throws {try await retired(.fastIndex)}
    func testRetiredVisualRebuildCannotStartOrPublish()async throws {try await retired(.visualRebuild)}
    func testRetiredVisualCaptureEventCannotRestartAutomaticIndex()async throws {
        guard app.visualPowerAllowed else {throw XCTSkip("Current thermal policy blocks visual fixture")}
        try await SourceWorkTestJob.settle(app);let memory=try XCTUnwrap(app.store.get("owned"))
        app.prepareForLibrarySwitch();let done=XCTestExpectation(description:"Original automatic visual task returned")
        app.searchWorkObserver={if $0 == .automaticVisual {XCTFail("Retired event admitted automatic visual work")}}
        app.searchWorkCompleted={if $0 == .automaticVisual {done.fulfill()}}
        app.queueVisualIndex(memory)
        XCTAssertFalse(app.visualAutoResumeAllowed);XCTAssertFalse(app.visualAutomaticIndexing)
        if app.visualAutomaticIndexing {await fulfillment(of:[done],timeout:10)}else {done.isInverted=true;await fulfillment(of:[done],timeout:0.05)}
    }
}
extension SourceWorkTestJob {
    @MainActor static func settleForIndexFixture(_ app:AppModel,queryHeld:Bool)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while app.hasPendingStatistics || (!queryHeld && app.refreshing),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.hasPendingStatistics);if !queryHeld {XCTAssertFalse(app.refreshing)}
    }
}

extension SearchIndexLifecycleTests {
    func testCancelledQueryDrainCallerStillJoinsActualTask()async throws {try await held(.query,cancelDrain:true)}
    func testCancelledTextRebuildDrainCallerStillJoinsActualTask()async throws {try await held(.textRebuild,cancelDrain:true)}
    func testCancelledFastPreparationDrainCallerStillJoinsActualTask()async throws {try await held(.fastIndex,cancelDrain:true)}
    func testCancelledAutomaticTextDrainCallerStillJoinsActualTask()async throws {try await held(.automaticText,cancelDrain:true)}
    func testCancelledVisualRebuildDrainCallerStillJoinsActualTask()async throws {try await held(.visualRebuild,cancelDrain:true)}
    func testCancelledAutomaticVisualDrainCallerStillJoinsActualTask()async throws {try await held(.automaticVisual,cancelDrain:true)}
    func waitForExitIdle()async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while app.hasPendingExitWork,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(2))}
        XCTAssertFalse(app.hasPendingExitWork)
    }
    func explicitCancel(_ phase:AppModel.SearchWorkPhase)async throws {
        try await SourceWorkTestJob.settle(app);let gate=AudioImportGate(),done=expectation(description:"Cancelled current index actually returned");gates.append(gate)
        app.searchWorkObserver={if $0==phase {await gate.wait()}};app.searchWorkCompleted={if $0==phase {done.fulfill()}}
        try await start(phase);await fulfillment(of:[gate.entered],timeout:5)
        if phase == .visualRebuild || phase == .automaticVisual {app.cancelVisualIndexing()}else {app.cancelIndexing()}
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertTrue(app.hasPendingExitWork)
        app.searchWorkObserver={_ in XCTFail("Explicit cancellation admitted overlapping current index work")}
        if phase == .visualRebuild {XCTAssertTrue(app.visualIndexing);app.rebuildVisualIndex()}
        else if phase == .automaticVisual {XCTAssertTrue(app.visualAutomaticIndexing);app.startAutomaticVisualIndex()}
        else {XCTAssertTrue(app.indexing);app.rebuildIndex();app.prepareFastIndex()}
        await gate.open();await fulfillment(of:[done],timeout:5);try await waitForExitIdle()
        XCTAssertFalse(app.indexing);XCTAssertFalse(app.visualIndexing);XCTAssertFalse(app.visualAutomaticIndexing)
    }
    func testCurrentTextCancellationKeepsBusyUntilActualWorkerReturns()async throws {try await explicitCancel(.textRebuild)}
    func testCurrentFastCancellationKeepsBusyUntilActualWorkerReturns()async throws {try await explicitCancel(.fastIndex)}
    func testCurrentVisualCancellationKeepsBusyUntilActualWorkerReturns()async throws {try await explicitCancel(.visualRebuild)}
    func testCurrentAutomaticVisualCancellationKeepsBusyUntilActualWorkerReturns()async throws {try await explicitCancel(.automaticVisual)}
    func activeDrain(_ phase:AppModel.SearchWorkPhase)async throws {
        try await SourceWorkTestJob.settle(app);let gate=AudioImportGate(),done=expectation(description:"Current external drain worker completed");gates.append(gate)
        app.searchWorkObserver={if $0==phase {await gate.wait()}};app.searchWorkCompleted={if $0==phase {done.fulfill()}}
        try await start(phase);await fulfillment(of:[gate.entered],timeout:5)
        let drain=Task {await self.app.cancelExternalWorkAndWait()}
        await fulfillment(of:[gate.cancelled],timeout:5);await gate.open();await fulfillment(of:[done],timeout:5);await drain.value
        XCTAssertFalse(app.indexing);XCTAssertFalse(app.visualIndexing);XCTAssertFalse(app.visualAutomaticIndexing)
        let message=phase == .visualRebuild ? app.visualIndexStatus:app.indexStatus
        XCTAssertFalse(message.hasPrefix("Stopping"),"An active workspace must stop claiming a completed drain is still stopping")
    }
    func testActiveTextDrainClearsItsStoppingStatusAfterActualReturn()async throws {try await activeDrain(.textRebuild)}
    func testActiveVisualDrainClearsItsStoppingStatusAfterActualReturn()async throws {try await activeDrain(.visualRebuild)}
    func testDrainRejectsEveryNewQueryIndexAndCapturedSourceEntry()async throws {
        try await SourceWorkTestJob.settle(app);let gate=AudioImportGate(),done=expectation(description:"Held query returned");gates.append(gate)
        app.searchWorkObserver={if $0 == .query {await gate.wait()}};app.searchWorkCompleted={if $0 == .query {done.fulfill()}}
        try await start(.query);await fulfillment(of:[gate.entered],timeout:5)
        let drain=Task {await self.app.cancelExternalWorkAndWait()};drain.cancel();await fulfillment(of:[gate.cancelled],timeout:5)
        app.searchWorkObserver={_ in XCTFail("Drain admitted another search/index task")}
        app.refresh();app.rebuildIndex();app.prepareFastIndex();app.rebuildVisualIndex();app.queueVisualIndex(try XCTUnwrap(app.store.get("owned")));app.addNote("Cannot publish during drain")
        XCTAssertFalse(app.refreshing);XCTAssertFalse(app.indexing);XCTAssertFalse(app.visualIndexing);XCTAssertFalse(app.visualAutomaticIndexing);XCTAssertFalse(app.visualAutoResumeAllowed)
        await gate.open();await fulfillment(of:[done],timeout:5);await drain.value;XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1)
    }
}

extension SearchIndexLifecycleTests {
    func testPrivacyPauseRejectsActualAlreadyReadQueryAcrossErasure()async throws {
        app.mode = .keyword;try await SourceWorkTestJob.settle(app)
        app.hits=[];app.resolvedSearch=nil
        let gate=AudioImportGate(),done=expectation(description:"Query with real previously read source returned");gates.append(gate)
        app.searchWorkObserver={if $0 == .queryRead {await gate.wait()}}
        app.searchWorkCompleted={if $0 == .query {done.fulfill()}}
        try await start(.query);await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertNotNil(try app.store.get("owned"))
        app.pauseForHistoryErasure();try app.store.delete("owned")
        XCTAssertNil(try app.store.get("owned"));XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
        await gate.open();await fulfillment(of:[done],timeout:5);try await waitForExitIdle()
        XCTAssertTrue(app.hits.isEmpty,"Privacy pause must not publish a query's real erased source after its read already completed")
        XCTAssertNil(app.resolvedSearch,"Retired pre-erasure query resolution must not replace the privacy view")
    }
}

extension SearchIndexLifecycleTests {
    func testPrivacyPauseCancelsPendingNoteBeforeItsActualAdmission()async throws {
        try await SourceWorkTestJob.settle(app)
        let gate=ImportWorkerGate();defer {gate.release()}
        app.addNote("Owned pending privacy note",observeWorker:{try? gate.pause();return})
        await fulfillment(of:[gate.entered],timeout:5)
        app.pauseForHistoryErasure();try app.store.delete("owned")
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
        gate.release();try await waitForExitIdle()
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0,"Privacy review must revoke an earlier pending source admission")
    }
}

extension SearchIndexLifecycleTests {
    func pendingImportPrivacy(_ audio:Bool)async throws {
        try await SourceWorkTestJob.settle(app);let gate=ImportWorkerGate();defer {gate.release()}
        if audio {try SourceWorkTestJob.audioImport.start(app,gate:gate)}
        else {
            let file=root.appendingPathComponent("pending-owned.json")
            try JSONEncoder().encode([Memory(id:"pending-import",kind:.note,text:"Owned pending JSON privacy source")]).write(to:file)
            app.importJSONFile(file,observeWorker:{if $0 == .started {try? gate.pause()}})
        }
        await fulfillment(of:[gate.entered],timeout:5)
        app.pauseForHistoryErasure();try app.store.delete("owned");XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
        gate.release();try await waitForExitIdle()
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0,"Privacy review must revoke an earlier pending file admission")
    }
    func testPrivacyPauseCancelsPendingAudioBeforeActualClipReservation()async throws {try await pendingImportPrivacy(true)}
    func testPrivacyPauseCancelsPendingJSONBeforeActualFileReservation()async throws {try await pendingImportPrivacy(false)}
}

extension SearchIndexLifecycleTests {
    func testSuccessfulWipeStillOwnsItsActualFreshQueryUntilReturn()async throws {
        try await SourceWorkTestJob.settle(app)
        let gate=AudioImportGate(),done=expectation(description:"Actual post-wipe query returned");gates.append(gate)
        app.searchWorkObserver={if $0 == .query {await gate.wait()}};app.searchWorkCompleted={if $0 == .query {done.fulfill()}}
        app.wipeLocalLibrary();await fulfillment(of:[gate.entered],timeout:10)
        XCTAssertFalse(app.libraryWipe.busy);XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
        XCTAssertTrue(app.hasPendingExitWork,"A completed wipe cannot acknowledge a separately held fresh reader")
        var drained=false;let drain=Task {await self.app.cancelExternalWorkAndWait();drained=true};drain.cancel()
        await fulfillment(of:[gate.cancelled],timeout:5);try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(drained)
        await gate.open();await fulfillment(of:[done],timeout:5);await drain.value
        XCTAssertFalse(app.hasPendingExitWork);XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
    }
    func testClosedStoreRetainsActualQueryOwnershipAndRejectsNewWrites()async throws {
        try await SourceWorkTestJob.settle(app)
        let gate=AudioImportGate(),done=expectation(description:"Actual query against now-closed store returned");gates.append(gate)
        app.searchWorkObserver={if $0 == .query {await gate.wait()}};app.searchWorkCompleted={if $0 == .query {done.fulfill()}}
        try await start(.query);await fulfillment(of:[gate.entered],timeout:5)
        try app.store.close();app.addNote("Closed workspace cannot admit this note")
        XCTAssertTrue(app.hasPendingExitWork,"Closing SQLite does not acknowledge a still-held app task")
        var drained=false;let drain=Task {await self.app.cancelExternalWorkAndWait();drained=true}
        await fulfillment(of:[gate.cancelled],timeout:5);try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(drained)
        await gate.open();await fulfillment(of:[done],timeout:5);await drain.value
        XCTAssertFalse(app.hasPendingExitWork);XCTAssertNil(app.errorMessage)
        let reopened=try MemoryStore(root:root);defer {try? reopened.close()}
        XCTAssertEqual(try reopened.stats(includeDiskUsage:false).count,1);XCTAssertNotNil(try reopened.get("owned"))
    }
}
