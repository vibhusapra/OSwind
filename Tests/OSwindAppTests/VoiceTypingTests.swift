import XCTest
import AppKit
@testable import OSwindCore
@testable import OSwind

@MainActor final class VoiceTypingTests:XCTestCase {
    final class Recorder:DictationRecording {
        var starts=0,finishes=0,cancels=0,full=false
        var samples=Array(repeating:Float(0.1),count:16000)
        var startError:Error?,finishError:Error?
        func start()async throws {starts+=1;if let startError {throw startError}}
        func finish()throws->[Float] {finishes+=1;if let finishError {throw finishError};return samples}
        func cancel() {cancels+=1}
    }
    final class Transport:DraftInsertionTransport {
        let target=DraftDestination(token:UUID(),app:"Owned editor",bundle:"org.oswind.owned.editor",title:"Owned document",selectionLength:0,capturedAt:ProcessInfo.processInfo.systemUptime)
        var writes=[String](),activations=0
        func capture(privacy:PrivacyPolicy)throws->DraftDestination {target}
        func activate(_ destination:DraftDestination)throws {activations+=1}
        func insert(_ text:String,at destination:DraftDestination,privacy:PrivacyPolicy)throws {writes.append(text)}
        func clear() {}
    }
    var root:URL!,app:AppModel!,model:VoiceTypingModel!,draft:ContextualDraftModel!,recorder:Recorder!,transport:Transport!
    var locked=false,allowed=true,identity=true,time=0.0,prepares=0,transcribes=0
    var context:WindowContext?=WindowContext(app:"Owned editor",bundle:"org.oswind.owned.editor",pid:123,title:"Owned document",url:nil,accessibilityText:"",secure:false)
    var prepareGate:CheckedContinuation<Void,Never>?,transcribeGate:CheckedContinuation<Void,Never>?
    var holdPreparation=false,holdTranscription=false,text="Owned speech 👩🏽‍💻 e\u{301}"
    override func setUp()async throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-voice-"+UUID().uuidString)
        recorder=Recorder();transport=Transport();draft=ContextualDraftModel(transport:transport,settle:{},copy:{_ in XCTFail("Unexpected pasteboard access")})
        app=try AppModel(root:root,startServices:false,drafting:draft,voiceSetup:{[unowned self] store,settings,draft in
            var env=VoiceTypingEnvironment(recorder:self.recorder,prepare:{[unowned self] _ in self.prepares+=1;if self.holdPreparation {await withCheckedContinuation {self.prepareGate=$0}}},transcribe:{[unowned self] samples,_ in
                self.transcribes+=1;XCTAssertEqual(samples.count,16000)
                if self.holdTranscription {await withCheckedContinuation {self.transcribeGate=$0}}
                return SpeechTranscript(text:self.text,duration:1,segments:[],model:"owned")
            })
            env.context={[unowned self] in self.context};env.identity={[unowned self] _ in self.identity};env.locked={[unowned self] in self.locked};env.now={[unowned self] in self.time};env.sleep={try await Task.sleep(for:.milliseconds(5))}
            return VoiceTypingModel(store:store,settings:settings,draft:draft,environment:env)
        })
        app.showOnboarding=false;model=app.voice
        let appAllowed=model.allowed;model.allowed={[unowned self] in self.allowed && appAllowed()}
    }
    override func tearDown()async throws {
        prepareGate?.resume();prepareGate=nil;transcribeGate?.resume();transcribeGate=nil
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();try? FileManager.default.removeItem(at:root)
        app=nil;model=nil;draft=nil;recorder=nil;transport=nil
    }
    func wait(_ condition:@escaping ()->Bool)async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(5))
        while !condition(),ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(2))};XCTAssertTrue(condition())
    }
    func record()async throws {model.start();try await wait {[self] in model.recording}}
    func finish()async throws {model.finishRecording();try await wait {[self] in !model.busy}}
    func testExplicitRecordReviewEditAndSingleInsertNeverSavesHistory()async throws {
        XCTAssertEqual(recorder.starts,0);XCTAssertEqual(prepares,0)
        draft.chooseDestination(privacy:app.settings.privacy);try await record();XCTAssertTrue(app.hasPendingExitWork);model.start();XCTAssertEqual(recorder.starts,1)
        try await finish();XCTAssertEqual(draft.text.utf8.map {$0},text.utf8.map {$0});XCTAssertEqual(draft.provider,"Local dictation");XCTAssertEqual(draft.sourceCount,0);XCTAssertTrue(draft.showing)
        XCTAssertTrue(transport.writes.isEmpty);XCTAssertEqual(try app.store.stats().count,0)
        XCTAssertNil(draft.destination,"Inference requires an explicitly renewed destination");model.cancel();draft.chooseDestination(privacy:app.settings.privacy)
        draft.text="Edited owned words";draft.insert(privacy:app.settings.privacy);try await wait {[self] in !draft.busy}
        XCTAssertEqual(transport.writes,["Edited owned words"]);XCTAssertEqual(transport.activations,1);XCTAssertEqual(transcribes,1);XCTAssertFalse(app.hasPendingExitWork)
    }
    func testBlockedOrLockedNeverPreparesOrRequestsMicrophone()async throws {
        allowed=false;model.start();XCTAssertFalse(model.busy);allowed=true;locked=true;model.start();XCTAssertFalse(model.busy)
        XCTAssertEqual(prepares,0);XCTAssertEqual(recorder.starts,0);XCTAssertEqual(transcribes,0)
    }
    func testMissingSecureExcludedAndChangedIdentityRefuseBeforeMic()async throws {
        let original=context
        context=nil;model.start();try await wait {[self] in !model.busy}
        context=original;context?.secure=true;model.start();try await wait {[self] in !model.busy}
        context=original;context?.bundle="com.apple.Passwords";model.start();try await wait {[self] in !model.busy}
        context=original;identity=false;model.start();try await wait {[self] in !model.busy}
        XCTAssertEqual(prepares,0);XCTAssertEqual(recorder.starts,0)
    }
    func testCancelPreparationRetainsBusyUntilActualReturn()async throws {
        holdPreparation=true;model.start();try await wait {[self] in prepareGate != nil}
        model.cancel();XCTAssertTrue(model.busy);model.start();XCTAssertEqual(prepares,1);XCTAssertEqual(recorder.starts,0)
        prepareGate?.resume();prepareGate=nil;try await wait {[self] in !model.busy};XCTAssertEqual(recorder.starts,0);XCTAssertTrue(draft.text.isEmpty)
    }
    func testCancelTranscriptionDrainsAndDiscardsLateText()async throws {
        holdTranscription=true;try await record();model.finishRecording();try await wait {[self] in transcribeGate != nil}
        model.cancel();XCTAssertTrue(model.busy);XCTAssertTrue(app.hasPendingExitWork);model.start();XCTAssertEqual(recorder.starts,1)
        var drained=false;let drain=Task {await model.cancelAndWait();drained=true};await Task.yield();XCTAssertFalse(drained)
        transcribeGate?.resume();transcribeGate=nil;await drain.value;XCTAssertFalse(model.busy);XCTAssertTrue(draft.text.isEmpty);XCTAssertTrue(transport.writes.isEmpty)
    }
    func testPrivacyChangeWhileRecordingStopsAndNeverTranscribes()async throws {
        try await record();context?.secure=true;try await wait {[self] in !model.busy}
        XCTAssertFalse(model.recording);XCTAssertEqual(transcribes,0);XCTAssertTrue(draft.text.isEmpty)
    }
    func testChangedPrivacyAfterTranscriptionRefusesReview()async throws {
        holdTranscription=true;try await record();model.finishRecording();try await wait {[self] in transcribeGate != nil}
        context=nil;transcribeGate?.resume();transcribeGate=nil;try await wait {[self] in !model.busy}
        XCTAssertTrue(draft.text.isEmpty);XCTAssertFalse(draft.showing);XCTAssertTrue(transport.writes.isEmpty)
    }
    func testPauseAndSettingsChangeCancelRecordingWithoutRestart()async throws {
        try await record();app.pauseAll();try await wait {[self] in !model.busy};XCTAssertEqual(transcribes,0)
        try await record();app.settings.transcriptionLanguage="auto";try await wait {[self] in !model.busy}
        XCTAssertEqual(transcribes,0);XCTAssertFalse(model.recording);XCTAssertFalse(app.audio.running);XCTAssertFalse(app.capture.running)
    }
    func testRetiredLibraryCannotRecordOrPublish()async throws {
        holdPreparation=true;model.start();try await wait {[self] in prepareGate != nil};app.prepareForLibrarySwitch()
        prepareGate?.resume();prepareGate=nil;try await wait {[self] in !model.busy};model.start();XCTAssertFalse(model.busy);XCTAssertEqual(recorder.starts,0)
    }
    func testAutomaticThirtySecondStopAndTranscriptErrors()async throws {
        try await record();time=30;try await wait {[self] in !model.busy};XCTAssertEqual(recorder.finishes,1);XCTAssertEqual(transcribes,1)
        draft.clear();text="bad\u{1b}control";time=31;try await record();try await finish();XCTAssertTrue(draft.text.isEmpty);XCTAssertTrue(model.status.contains("control"))
    }
    func testRecordingAndPermissionFailuresDoNotOfferDraft()async throws {
        recorder.startError=OSwindError.unavailable("Owned permission denied");model.start();try await wait {[self] in !model.busy};XCTAssertEqual(transcribes,0)
        recorder.startError=nil;recorder.finishError=OSwindError.unavailable("Owned device interrupted");try await record();try await finish();XCTAssertEqual(transcribes,0);XCTAssertTrue(model.status.contains("interrupted"));XCTAssertTrue(draft.text.isEmpty)
    }
    func testReviewValidationRefusesLockPrivacyAndCanonicalByteMutation()async throws {
        draft.chooseDestination(privacy:app.settings.privacy);try await record();try await finish();draft.chooseDestination(privacy:app.settings.privacy);locked=true;draft.insert(privacy:app.settings.privacy);try await wait {[self] in !draft.busy};XCTAssertEqual(transport.activations,0)
        locked=false;draft.clear();draft.chooseDestination(privacy:app.settings.privacy)
        var gate:CheckedContinuation<Void,Never>?
        draft.review(Answer(text:"e\u{301}",sources:[],provider:"owned",duration:0)) {await withCheckedContinuation {gate=$0}}
        draft.insert(privacy:app.settings.privacy);try await wait {gate != nil};draft.text="é";gate?.resume();try await wait {[self] in !draft.busy}
        XCTAssertEqual(transport.activations,0);XCTAssertTrue(transport.writes.isEmpty)
    }
    func plainSession()async throws->AppSession {
        let bootstrap=root.appendingPathComponent("bootstrap"),session=AppSession(selection:.init(url:bootstrap,requiresExisting:false,origin:"owned voice session"),defaults:UserDefaults(suiteName:"oswind-owned-voice-session-"+UUID().uuidString)!,locked:{false})
        try await wait {session.model != nil && !session.busy}
        if let initial=session.model {initial.prepareForLibrarySwitch();await initial.cancelExternalWorkAndWait();try initial.store.close()}
        session.model=app;return session
    }
    func testPlainQuitWaitsForActualLocalTranscription()async throws {
        let previous=AppSession.current;defer {AppSession.current=previous};let session=try await plainSession()
        holdTranscription=true;try await record();model.finishRecording();try await wait {[self] in transcribeGate != nil}
        let delegate=AppDelegate();var exits=0;delegate.finishTermination={_ in exits+=1}
        XCTAssertTrue(app.hasPendingExitWork);XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
        try await wait {[self] in model.status.contains("Cancelling")};XCTAssertEqual(exits,0);XCTAssertFalse(app.store.isClosed);XCTAssertTrue(model.busy)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
        transcribeGate?.resume();transcribeGate=nil;try await wait {exits==1};XCTAssertTrue(draft.text.isEmpty);XCTAssertFalse(app.hasPendingExitWork)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateNow);session.model=nil
    }
    func testLibrarySwitchDrainsPreparationBeforeSQLiteClose()async throws {
        let previous=AppSession.current;defer {AppSession.current=previous};let session=try await plainSession()
        holdPreparation=true;model.start();try await wait {[self] in prepareGate != nil}
        let destination=root.appendingPathExtension("next"),other=try MemoryStore(root:destination);try other.close();defer {try? FileManager.default.removeItem(at:destination)}
        session.open(destination,persist:false);try await wait {session.busy && session.model==nil};XCTAssertFalse(app.store.isClosed);XCTAssertTrue(model.busy)
        prepareGate?.resume();prepareGate=nil;try await wait {!session.busy};XCTAssertNil(session.failure);XCTAssertTrue(app.store.isClosed);XCTAssertEqual(recorder.starts,0)
        let next=try XCTUnwrap(session.model);next.prepareForLibrarySwitch();await next.cancelExternalWorkAndWait();try next.store.close();session.model=nil
    }
    func testReplacedRootDuringPreparationRefusesMicrophone()async throws {
        holdPreparation=true;model.start();try await wait {[self] in prepareGate != nil}
        let moved=root.appendingPathExtension("moved");try FileManager.default.moveItem(at:root,to:moved)
        defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.moveItem(at:moved,to:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        prepareGate?.resume();prepareGate=nil;try await wait {[self] in !model.busy}
        XCTAssertEqual(recorder.starts,0);XCTAssertTrue(draft.text.isEmpty);XCTAssertTrue(model.status.contains("changed"))
    }

}
