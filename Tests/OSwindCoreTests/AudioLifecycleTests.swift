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
                         context: @escaping () -> WindowContext? = { nil },
                         configure: (inout AudioStartupEnvironment) -> Void = { _ in },
                         acquire: @escaping () -> Void) throws -> (AudioController, URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-audio-lifecycle-"+UUID().uuidString)
        try Paths.ensure(root)
        var settings=AppSettings(); settings.audioEnabled=true
        settings.whisperBinary="/usr/bin/true"; settings.whisperModel=root.appendingPathComponent("fixture-model").path
        try Data("not a real model".utf8).write(to:URL(fileURLWithPath:settings.whisperModel))
        var environment=AudioStartupEnvironment(locked:locked,context:context,authorizeMicrophone:{ await gate.authorize() },makeEngine:{ acquire(); throw OSwindError.unavailable("test stops before device acquisition") })
        configure(&environment)
        return (AudioController(store:try MemoryStore(root:root.appendingPathComponent("library")),embedder:LocalEmbedder(),settings:settings,startup:environment),root)
    }
    func testStopDuringAuthorizationCannotAcquireDevice() async throws {
        let gate=Gate(); var acquired=0
        let (audio,root)=try fixture(gate) { acquired += 1 }; defer { audio.stop(); try? FileManager.default.removeItem(at:root) }
        let attempt=Task { await audio.start() }
        await fulfillment(of:[gate.entered],timeout:5)
        audio.stop(); gate.resolve(); await attempt.value
        XCTAssertEqual(acquired,0); XCTAssertFalse(audio.running); XCTAssertEqual(audio.status,"Audio off")
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
        let gate=Gate(); var acquired=0; var context:WindowContext?
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
        var streamID:ObjectIdentifier? { nil }
        var active=false, starts=0, stops=0
        var gate:Gate?
        init(gate:Gate?=nil) { self.gate=gate }
        func start() async throws { starts += 1; if let gate { _ = await gate.authorize() }; active=true }
        func stop() async throws { stops += 1; active=false }
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

}
