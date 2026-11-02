import XCTest
import AVFoundation
@testable import OSwindCore

/// No test requests TCC authorization or constructs an audio device. The factory
/// throws as soon as production code would attempt hardware acquisition.
@MainActor final class AudioLifecycleTests: XCTestCase {
    private final class Gate {
        var continuation: CheckedContinuation<Bool,Never>?
        let entered = XCTestExpectation(description:"authorization suspended")
        func authorize() async -> Bool {
            await withCheckedContinuation { continuation in
                self.continuation=continuation; entered.fulfill()
            }
        }
        func resolve(_ granted: Bool = true) { continuation?.resume(returning:granted); continuation=nil }
    }
    private func fixture(_ gate: Gate, locked: @escaping () -> Bool = { false },
                         context: @escaping () -> WindowContext? = {WindowContext(app:"Owned",bundle:"org.fixture",pid:8123,title:"Owned",accessibilityText:"",secure:false)},
                         recognizer:SpeechRecognizer?=nil,
                         configure: (inout AudioStartupEnvironment) -> Void = { _ in },
                         acquire: @escaping () -> Void) throws -> (AudioController, URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-audio-lifecycle-"+UUID().uuidString)
        try Paths.ensure(root)
        var settings=AppSettings(); settings.audioEnabled=true
        settings.whisperBinary="/usr/bin/true"; settings.whisperModel=root.appendingPathComponent("fixture-model").path
        try Data("not a real model".utf8).write(to:URL(fileURLWithPath:settings.whisperModel))
        var environment=AudioStartupEnvironment(locked:locked,context:{context()},identityCurrent:{_ in true},authorizeMicrophone:{ await gate.authorize() },makeEngine:{ acquire(); throw OSwindError.unavailable("test stops before device acquisition") })
        configure(&environment)
        return (AudioController(store:try MemoryStore(root:root.appendingPathComponent("library")),embedder:LocalEmbedder(),settings:settings,startup:environment,recognizer:recognizer ?? SpeechRecognizer()),root)
    }
    func testBackgroundExcludedAppDoesNotStopMicrophoneOnlyAuthorization() async throws {
        let gate=Gate();var acquired=0
        let (audio,root)=try fixture(gate) {acquired+=1};defer {audio.stop();try? FileManager.default.removeItem(at:root)}
        let attempt=Task {await audio.start()};await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertFalse(audio.settings.systemAudioEnabled);audio.applicationLaunched("COM.APPLE.PASSWORDS")
        XCTAssertTrue(audio.running);XCTAssertEqual(audio.status,"Starting local audio…")
        audio.stop();gate.resolve();await attempt.value;XCTAssertEqual(acquired,0)
    }
    func testStopDuringAuthorizationCannotAcquireDevice() async throws {
        let gate=Gate(); var acquired=0
        let (audio,root)=try fixture(gate) { acquired += 1 }; defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        let attempt=Task { await audio.start() }
        await fulfillment(of:[gate.entered],timeout:5)
        audio.stop(); gate.resolve(); await attempt.value
        XCTAssertEqual(acquired,0); XCTAssertFalse(audio.running); XCTAssertEqual(audio.status,"Audio off")
    }
    func testCancelledOverlappingDrainsJoinLateAuthorizationAndRejectNewStartup()async throws {
        let gate=Gate();var acquired=0,firstDone=false,secondDone=false
        let (audio,root)=try fixture(gate) {acquired+=1};defer {audio.stop();try? FileManager.default.removeItem(at:root)}
        let attempt=Task {await audio.start()};await fulfillment(of:[gate.entered],timeout:5)
        let first=Task {await audio.cancelAndWait();firstDone=true}
        let second=Task {await audio.cancelAndWait();secondDone=true};second.cancel()
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertFalse(firstDone);XCTAssertFalse(secondDone)
        await audio.start();XCTAssertFalse(audio.running);XCTAssertEqual(acquired,0)
        gate.resolve();await attempt.value;await first.value;await second.value
        XCTAssertTrue(firstDone);XCTAssertTrue(secondDone);XCTAssertEqual(acquired,0)
    }
    func testFinishDuringAuthorizationCancelsStartup() async throws {
        let gate=Gate(); var acquired=0
        let (audio,root)=try fixture(gate) { acquired += 1 }; defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        let attempt=Task { await audio.start() }; await fulfillment(of:[gate.entered],timeout:5)
        audio.finish(); gate.resolve(); await attempt.value
        XCTAssertEqual(acquired,0); XCTAssertFalse(audio.running); XCTAssertEqual(audio.status,"Audio off")
    }
    func testLockAfterAuthorizationRequestPreventsAcquisition() async throws {
        let gate=Gate(); var acquired=0, locked=false
        let (audio,root)=try fixture(gate,locked:{locked}) { acquired += 1 }; defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        let attempt=Task { await audio.start() }; await fulfillment(of:[gate.entered],timeout:5)
        locked=true; gate.resolve(); await attempt.value
        XCTAssertEqual(acquired,0); XCTAssertFalse(audio.running); XCTAssertTrue(audio.status.contains("Locked"))
    }
    func testExcludedForegroundAfterAuthorizationRequestPreventsAcquisition() async throws {
        let gate=Gate(); var acquired=0; var context:WindowContext?=WindowContext(app:"Owned",bundle:"org.fixture",pid:8123,title:"Owned",accessibilityText:"",secure:false)
        let (audio,root)=try fixture(gate,context:{context}) { acquired += 1 }; defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        let attempt=Task { await audio.start() }; await fulfillment(of:[gate.entered],timeout:5)
        context=WindowContext(app:"Synthetic excluded",bundle:"com.apple.keychainaccess",pid:0,title:"Fixture",accessibilityText:"",secure:false)
        gate.resolve(); await attempt.value
        XCTAssertEqual(acquired,0); XCTAssertFalse(audio.running); XCTAssertTrue(audio.status.contains("Excluded application"))
    }
    func testSourceAndPrivacyChangesCancelSuspendedStartup() async throws {
        for change in 0..<3 {
            let gate=Gate(); var acquired=0
            let (audio,root)=try fixture(gate) { acquired += 1 }; defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
            let attempt=Task { await audio.start() }; await fulfillment(of:[gate.entered],timeout:5)
            switch change {
            case 0: audio.settings.audioEnabled=false
            case 1: audio.settings.privacy.excludedApps.append("synthetic.app")
            default: audio.settings.transcriptionLanguage="fr"
            }
            XCTAssertFalse(audio.running)
            gate.resolve(); await attempt.value
            XCTAssertEqual(acquired,0); XCTAssertEqual(audio.status,"Audio settings changed · start to resume")
        }
    }
    func testRetentionChangeDoesNotCancelStartupButStopStillDoes() async throws {
        let gate=Gate(); var acquired=0
        let (audio,root)=try fixture(gate) { acquired += 1 }; defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        let attempt=Task { await audio.start() }; await fulfillment(of:[gate.entered],timeout:5)
        audio.settings.retainAudio=true; XCTAssertTrue(audio.running)
        audio.stop(); gate.resolve(); await attempt.value
        XCTAssertEqual(acquired,0); XCTAssertEqual(audio.status,"Audio off")
    }
    func testTaskCancellationCannotAcquireDevice() async throws {
        let gate=Gate(); var acquired=0
        let (audio,root)=try fixture(gate) { acquired += 1 }; defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        let attempt=Task { await audio.start() }; await fulfillment(of:[gate.entered],timeout:5)
        attempt.cancel(); gate.resolve(); await attempt.value
        XCTAssertEqual(acquired,0); XCTAssertFalse(audio.running)
    }
    func testOldPermissionDenialCannotStopNewAttempt() async throws {
        let old=Gate(), new=Gate(); var count=0,acquired=0
        let (audio,root)=try fixture(old,configure:{ env in env.authorizeMicrophone={ count += 1; return await (count==1 ? old : new).authorize() } }) { acquired += 1 }
        defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        let first=Task { await audio.start() }; await fulfillment(of:[old.entered],timeout:5)
        audio.stop()
        let second=Task { await audio.start() }; await fulfillment(of:[new.entered],timeout:5)
        old.resolve(false); await first.value
        XCTAssertTrue(audio.running); XCTAssertEqual(audio.status,"Starting local audio…"); XCTAssertEqual(acquired,0)
        audio.stop(); new.resolve(); await second.value; XCTAssertEqual(acquired,0)
    }
    private final class FakeCapture: AudioSystemCapture {
        var active=false, starts=0, stops=0
        var gate:Gate?,stopGate:Gate?
        init(gate:Gate?=nil) { self.gate=gate }
        func start() async throws { starts += 1; if let gate { _ = await gate.authorize() }; active=true }
        func stop() async throws { stops += 1; if let stopGate {_=await stopGate.authorize()};active=false }
    }
    func testDrainJoinsAsynchronousDeviceStopAfterItsPublicHandleWasReleased()async throws {
        let unused=Gate(),stopGate=Gate(),capture=FakeCapture();capture.stopGate=stopGate
        let (audio,root)=try fixture(unused,configure:{env in
            env.systemAvailable={true};env.makeSystemCapture={_,_ in capture}
        },acquire:{XCTFail("No microphone in this fixture")})
        defer {stopGate.resolve();audio.stop();try? FileManager.default.removeItem(at:root)}
        audio.settings.audioEnabled=false;audio.settings.systemAudioEnabled=true
        await audio.start();XCTAssertTrue(capture.active)
        audio.stop();await fulfillment(of:[stopGate.entered],timeout:5)
        var finished=false
        let drain=Task {await audio.cancelAndWait();finished=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(30));XCTAssertFalse(finished);XCTAssertTrue(capture.active)
        stopGate.resolve();await drain.value
        XCTAssertTrue(finished);XCTAssertFalse(capture.active);XCTAssertEqual(capture.stops,1)
    }
    func testStopDuringContentLookupCannotStartStream() async throws {
        let gate=Gate(), capture=FakeCapture()
        let (audio,root)=try fixture(gate,configure:{ env in
            env.systemAvailable={true}; env.makeSystemCapture={ _,_ in _ = await gate.authorize(); return capture }
        },acquire:{ XCTFail("No microphone in this test") })
        defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        audio.settings.audioEnabled=false; audio.settings.systemAudioEnabled=true
        let attempt=Task { await audio.start() }; await fulfillment(of:[gate.entered],timeout:5)
        audio.stop(); gate.resolve(); await attempt.value
        XCTAssertEqual(capture.starts,0); XCTAssertFalse(capture.active); XCTAssertFalse(audio.running)
    }
    func testLateStreamStartStopsItsOwnResourceAndPreservesNewRun() async throws {
        let gate=Gate(), old=FakeCapture(), new=FakeCapture(); old.gate=gate; var count=0
        let (audio,root)=try fixture(gate,configure:{ env in
            env.systemAvailable={true}; env.makeSystemCapture={ _,_ in count += 1; return count==1 ? old : new }
        },acquire:{ XCTFail("No microphone in this test") })
        defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        audio.settings.audioEnabled=false; audio.settings.systemAudioEnabled=true
        let first=Task { await audio.start() }; await fulfillment(of:[gate.entered],timeout:5)
        audio.stop(); await audio.start()
        XCTAssertTrue(audio.running); XCTAssertTrue(new.active)
        gate.resolve(); await first.value
        XCTAssertFalse(old.active); XCTAssertGreaterThan(old.stops,0)
        XCTAssertTrue(new.active); XCTAssertEqual(new.stops,0); XCTAssertTrue(audio.running)
        XCTAssertEqual(audio.status,"Transcribing locally · 30 s segments")
        audio.settings.systemAudioEnabled=false
        // stop() releases an asynchronous ScreenCaptureKit resource on its own task.
        for _ in 0..<100 where new.active { await Task.yield() }
        XCTAssertFalse(audio.running); XCTAssertFalse(new.active)
    }

    private struct PreparedBackend:NativeSpeechBackend {
        func transcribe(file:URL,language:String) async throws -> SpeechTranscript { SpeechTranscript(text:"Synthetic",duration:1,segments:[],model:"test") }
    }
    private func enableNative(_ audio:AudioController,root:URL) throws {
        let models=root.appendingPathComponent("synthetic-compiled-model")
        try Paths.ensure(models)
        for name in ["Preprocessor.mlmodelc","Encoder.mlmodelc","Decoder.mlmodelc","JointDecisionv3.mlmodelc"] { try Paths.ensure(models.appendingPathComponent(name)) }
        try Data("{}".utf8).write(to:models.appendingPathComponent("parakeet_vocab.json"))
        audio.settings.speech.engine = .parakeet; audio.settings.speech.modelDirectory=models.path
    }
    func testStopLockAndSourceChangesDuringNativePreparationNeverRequestMicrophone() async throws {
        for action in 0..<3 {
            let model=Gate(), authorization=Gate(); var requested=0,locked=false
            let recognizer=SpeechRecognizer(loader:{ _ in _ = await model.authorize(); return PreparedBackend() })
            let (audio,root)=try fixture(authorization,locked:{locked},recognizer:recognizer,configure:{ env in env.authorizeMicrophone={ requested += 1; return false } },acquire:{ XCTFail("Never acquire a device") })
            defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
            try enableNative(audio,root:root)
            let attempt=Task { await audio.start() }; await fulfillment(of:[model.entered],timeout:5)
            switch action { case 0: audio.stop(); case 1: locked=true; default: audio.settings.audioEnabled=false }
            model.resolve(); await attempt.value
            XCTAssertEqual(requested,0); XCTAssertFalse(audio.running)
        }
    }
    func testOldPreparationCompletionCannotClearNewAttemptsCancellationHandle() async throws {
        let old=Gate(), new=Gate(), authorization=Gate(); var loads=0,requested=0
        let recognizer=SpeechRecognizer(loader:{ _ in
            let gate=await MainActor.run { loads += 1; return loads==1 ? old : new }
            _ = await gate.authorize(); return PreparedBackend()
        })
        let (audio,root)=try fixture(authorization,recognizer:recognizer,configure:{ env in env.authorizeMicrophone={ requested += 1; return false } },acquire:{ XCTFail("Never acquire a device") })
        defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        try enableNative(audio,root:root)
        let first=Task { await audio.start() }; await fulfillment(of:[old.entered],timeout:5)
        audio.stop(); let second=Task { await audio.start() }
        old.resolve(); await fulfillment(of:[new.entered],timeout:5); await first.value
        XCTAssertTrue(audio.running); audio.stop(); new.resolve(); await second.value
        XCTAssertEqual(requested,0); XCTAssertFalse(audio.running); XCTAssertEqual(audio.status,"Audio off")
    }

}
