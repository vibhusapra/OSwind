import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class AnswerLifecycleTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-answer-lifecycle-"+UUID().uuidString)
        app=try AppModel(root:root,startServices:false)
        app.settings.ai.provider = .evidence;app.settings.ai.allowRemote=false
        app.settings.captureOnLaunch=false;app.settings.apiEnabled=false;app.settings.routinesEnabled=false;app.settings.automaticMaintenance=false
        app.settings.entityAutomaticIndex=false;app.showOnboarding=false
        try app.store.insert(Memory(id:"original",text:"The authored observatory launch is scheduled for Thursday."))
    }
    override func tearDown()async throws {
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait()
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while app.asking,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        try app.store.close();app=nil;try? FileManager.default.removeItem(at:root)
    }
    func ready()async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while app.hasPendingStatistics || app.refreshing,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.hasPendingStatistics);XCTAssertFalse(app.refreshing)
    }
    func testRetiredAskCannotLaunchOrPersistConversation()async throws {
        try await ready();app.prepareForLibrarySwitch();app.ask("When is the authored observatory launch?",interpretation:false)
        XCTAssertFalse(app.asking,"A retired view must not launch an answer operation")
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while app.asking,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.asking);XCTAssertNil(app.currentChatID)
        XCTAssertTrue(try app.store.chats().isEmpty,"A queued retired Ask must not persist a conversation in the old library")
        XCTAssertNil(app.answer,"A retired answer completion must not publish evidence")
    }
    func finishAnswer()async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while app.asking,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.asking)
    }
    func start(_ gate:ImportWorkerGate,phase:AppModel.AnswerOperationPhase = .started,committed:Bool=false) {
        let completion:(@Sendable ()->Void)?
        if committed {completion={try? gate.pause()}}else {completion=nil}
        app.ask("When is the authored observatory launch?",interpretation:false,observeWorker:{if !committed,$0==phase {try gate.pause()}},observeCompletion:completion)
    }
    func drain(_ phase:AppModel.AnswerOperationPhase,cancelCaller:Bool=false)async throws {
        try await ready();let gate=ImportWorkerGate();defer {gate.release()};start(gate,phase:phase)
        await fulfillment(of:[gate.entered],timeout:5);XCTAssertTrue(app.hasPendingExitWork)
        app.prepareForLibrarySwitch();var finished=false
        let drain=Task {await self.app.cancelExternalWorkAndWait();finished=true};if cancelCaller {drain.cancel()}
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(finished);XCTAssertTrue(app.asking)
        gate.release();await drain.value;try await finishAnswer()
        XCTAssertTrue(finished);XCTAssertFalse(app.hasPendingExitWork);XCTAssertTrue(try app.store.chats().isEmpty);XCTAssertNil(app.answer);XCTAssertNil(app.currentChatID)
    }
    func testDrainWaitsForActualAnswerWorkerBeforeEngineEntry()async throws {try await drain(.started)}
    func testDrainWaitsForAnswerReadyWorkerBeforeConversationAdmission()async throws {try await drain(.answerReady)}
    func testCancelledDrainCallerStillJoinsActualAnswerWorker()async throws {try await drain(.answerReady,cancelCaller:true)}
    func testExplicitCancelRetainsBusyUntilActualWorkerReturns()async throws {
        try await ready();let gate=ImportWorkerGate();defer {gate.release()};start(gate)
        await fulfillment(of:[gate.entered],timeout:5);app.cancelAnswer();await fulfillment(of:[gate.cancelled],timeout:5)
        XCTAssertTrue(app.asking);XCTAssertTrue(app.hasPendingExitWork)
        app.ask("A second request",observeWorker:{_ in XCTFail("Accepted another operation before the canceled worker returned")})
        gate.release();try await finishAnswer();XCTAssertEqual(app.answerStatus,"Answer cancelled.");XCTAssertTrue(try app.store.chats().isEmpty)
        app.ask("observatory",interpretation:false);try await finishAnswer();XCTAssertEqual(try app.store.chats().count,1);XCTAssertNotNil(app.answer);XCTAssertNil(app.answerStatus)
    }
    func committed(_ retired:Bool)async throws {
        try await ready();let gate=ImportWorkerGate();defer {gate.release()};start(gate,committed:true)
        await fulfillment(of:[gate.entered],timeout:5);let chats=try app.store.chats();XCTAssertEqual(chats.count,1)
        let id=try XCTUnwrap(chats.first?.id);XCTAssertEqual(try app.store.chatTurns(id).count,1)
        XCTAssertNil(app.currentChatID);XCTAssertNil(app.answer)
        if retired {app.prepareForLibrarySwitch()}else {app.settings.privacy.retentionDays+=1}
        let status=app.answerStatus,drain=Task {await self.app.cancelExternalWorkAndWait()}
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertTrue(app.asking)
        gate.release();await drain.value;try await finishAnswer()
        XCTAssertEqual(try app.store.chatTurns(id).count,1,"Cancellation cannot undo the actual committed turn")
        XCTAssertNil(app.currentChatID);XCTAssertNil(app.answer);XCTAssertFalse(app.hasPendingExitWork)
        if retired {XCTAssertEqual(app.answerStatus,status);XCTAssertNil(app.savedAnswerID);app.reviewSavedAnswer();XCTAssertNil(app.currentChatID)}
        else {
            XCTAssertTrue(app.answerStatus?.contains("saved before cancellation") ?? false);XCTAssertEqual(app.savedAnswerID,id)
            app.reviewSavedAnswer();XCTAssertEqual(app.currentChatID,id);XCTAssertNotNil(app.answer);XCTAssertNil(app.savedAnswerID);XCTAssertNil(app.answerStatus)
        }
    }
    func testRetiredCompletionKeepsActualCommittedTurnWithoutPublishing()async throws {try await committed(true)}
    func testCurrentPrivacyCancellationReportsAlreadyCommittedTurn()async throws {try await committed(false)}
    func testPrivacyRevocationCancelsAnswerEvenWhenSettingsSaveFails()async throws {
        try await ready();let gate=ImportWorkerGate();defer {gate.release()};start(gate,phase:.answerReady)
        await fulfillment(of:[gate.entered],timeout:5)
        let lock=root.appendingPathComponent(".settings-admission.lock"),target=root.deletingLastPathComponent().appendingPathComponent("owned-answer-marker-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:target)}
        try Data("Unchanged marker".utf8).write(to:target);try FileManager.default.removeItem(at:lock);try FileManager.default.createSymbolicLink(at:lock,withDestinationURL:target)
        app.settings.privacy.redactSecrets.toggle();await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertNotNil(app.errorMessage)
        gate.release();await app.cancelExternalWorkAndWait();XCTAssertTrue(try app.store.chats().isEmpty);XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"Unchanged marker")
    }
    func testChangedModelChoiceRevokesCapturedAnswerConfiguration()async throws {
        try await ready();let gate=ImportWorkerGate();defer {gate.release()};start(gate)
        await fulfillment(of:[gate.entered],timeout:5);app.settings.ai.model="owned-new-model-choice"
        await fulfillment(of:[gate.cancelled],timeout:5);gate.release();await app.cancelExternalWorkAndWait()
        XCTAssertTrue(try app.store.chats().isEmpty);XCTAssertNil(app.answer)
    }
    func testWipeWaitsForAnswerAndCannotBeRepopulatedByIt()async throws {
        try await ready();let gate=ImportWorkerGate();defer {gate.release()};start(gate,phase:.answerReady)
        await fulfillment(of:[gate.entered],timeout:5);app.wipeLocalLibrary()
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertTrue(app.libraryWipe.busy);XCTAssertNil(app.libraryWipe.result)
        gate.release();let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while app.libraryWipe.busy,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.libraryWipe.busy);try await SourceWorkTestJob.settle(app)
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0);XCTAssertTrue(try app.store.chats().isEmpty);XCTAssertFalse(app.hasPendingExitWork)
    }
    func testClosedLibraryRejectsAskBeforeLaunch()async throws {
        try await ready();try app.store.close();app.ask("Do not start")
        XCTAssertFalse(app.asking);XCTAssertFalse(app.libraryWork.busy);XCTAssertNil(app.answerStatus)
    }
    func testChangedEvidenceRejectsAnswerWithoutCreatingEmptyConversation()async throws {
        try await ready();let gate=ImportWorkerGate();defer {gate.release()};start(gate,phase:.answerReady)
        await fulfillment(of:[gate.entered],timeout:5);_ = try app.store.delete("original")
        gate.release();try await finishAnswer();XCTAssertNotNil(app.errorMessage)
        XCTAssertTrue(try app.store.chats().isEmpty,"Rejected evidence must not leave a newly created empty conversation")
        XCTAssertNil(app.currentChatID);XCTAssertNil(app.answer)
    }
}
