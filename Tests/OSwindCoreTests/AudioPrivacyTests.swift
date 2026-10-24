import XCTest
import Combine
@testable import OSwindCore

private func ownedAudioContext(secure:Bool=false,bundle:String="org.fixture")->WindowContext {WindowContext(app:"Owned",bundle:bundle,pid:8123,title:"Owned",accessibilityText:"",secure:secure)}
@MainActor private final class AudioContextGate {
    var continuation:CheckedContinuation<WindowContext?,Never>?
    let entered=XCTestExpectation(description:"owned audio context suspended")
    func read() async ->WindowContext? {await withCheckedContinuation {continuation=$0;entered.fulfill()}}
    func resolve(_ value:WindowContext?=ownedAudioContext()){continuation?.resume(returning:value);continuation=nil}
}
private struct OwnedAudioBackend:NativeSpeechBackend {
    var operation:@Sendable (URL) async throws ->SpeechTranscript
    func transcribe(file:URL,language:String) async throws ->SpeechTranscript {try await operation(file)}
}
@MainActor private final class OwnedSystemAudio:AudioSystemCapture {
    var active=false,starts=0,stops=0
    var sink:AudioAccumulator?
    func start() async throws {starts+=1;active=true}
    func stop() async throws {stops+=1;active=false}
}
@MainActor final class AudioPrivacyTests:XCTestCase {
    private struct Fixture {var root:URL,store:MemoryStore,audio:AudioController,capture:OwnedSystemAudio}
    nonisolated private static func transcript(_ text:String="Owned words")->SpeechTranscript {.init(text:text,duration:1,segments:[.init(start:0,end:1,text:text)],model:"owned")}
    private func fixture(launches:AnyPublisher<String,Never>=Empty().eraseToAnyPublisher(),context:@escaping () async ->WindowContext?={ownedAudioContext()},identity:@escaping (WindowContext)->Bool={_ in true},locked:@escaping ()->Bool={false},backend:@escaping @Sendable (URL) async throws ->SpeechTranscript={_ in AudioPrivacyTests.transcript()}) throws ->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-audio-privacy-"+UUID().uuidString);try Paths.ensure(root)
        let models=root.appendingPathComponent("synthetic-model");try Paths.ensure(models)
        for name in ["Preprocessor.mlmodelc","Encoder.mlmodelc","Decoder.mlmodelc","JointDecisionv3.mlmodelc"] {try Paths.ensure(models.appendingPathComponent(name))}
        try Data("{}".utf8).write(to:models.appendingPathComponent("parakeet_vocab.json"))
        var settings=AppSettings();settings.systemAudioEnabled=true;settings.speech.engine = .parakeet;settings.speech.modelDirectory=models.path;settings.retainAudio=true
        let capture=OwnedSystemAudio(),store=try MemoryStore(root:root.appendingPathComponent("library"))
        let environment=AudioStartupEnvironment(locked:locked,context:context,identityCurrent:identity,privacyInterval:3600,authorizeMicrophone:{XCTFail("Never request real microphone access");return false},makeEngine:{throw OSwindError.unavailable("Never construct hardware")},systemAvailable:{true},makeSystemCapture:{_,sink in capture.sink=sink;return capture},applicationLaunches:launches)
        let recognizer=SpeechRecognizer(loader:{_ in OwnedAudioBackend(operation:backend)})
        return Fixture(root:root,store:store,audio:AudioController(store:store,embedder:LocalEmbedder(),settings:settings,startup:environment,recognizer:recognizer),capture:capture)
    }
    private func wait(_ condition:()->Bool) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while !condition(),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(2))};XCTAssertTrue(condition())
    }
    private func cleanup(_ f:Fixture) async throws {f.audio.stop();try await wait {!f.audio.hasActiveWork};try f.store.close();try FileManager.default.removeItem(at:f.root)}
    private func wavFiles(_ root:URL)->[URL] {(FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []).filter {$0.pathExtension=="wav"}}
    private func feed(_ sink:AudioAccumulator,count:Int) {
        var left=count
        while left>0 {let size=min(left,AudioAccumulator.maximumCallbackSamples);sink.add(Array(repeating:Float(0.05),count:size));left-=size}
    }
    func testExcludedApplicationLaunchStopsSystemCaptureThroughInjectedPublisher() async throws {
        let launches=PassthroughSubject<String,Never>(),f=try fixture(launches:launches.eraseToAnyPublisher())
        await f.audio.start();let sink=try XCTUnwrap(f.capture.sink)
        launches.send("org.allowed.application");await Task.yield();XCTAssertTrue(f.audio.running)
        launches.send("COM.APPLE.PASSWORDS")
        try await wait {!f.audio.hasActiveWork && !f.capture.active}
        XCTAssertTrue(f.audio.status.contains("Excluded application started"));feed(sink,count:480000)
        XCTAssertEqual(sink.snapshot.partialSamples,0);XCTAssertEqual(try f.store.stats(includeDiskUsage:false).count,0)
        await f.audio.start();XCTAssertTrue(f.audio.running);XCTAssertEqual(f.capture.starts,2);try await cleanup(f)
    }
    func testExcludedApplicationLaunchLeavesIdleOrAlreadyStoppedControllerUnchanged() async throws {
        let f=try fixture();f.audio.applicationLaunched("com.apple.Passwords");XCTAssertEqual(f.audio.status,"Audio off")
        await f.audio.start();f.audio.settings.systemAudioEnabled=false
        // The settings change already stops the system source. A later launch
        // must not replace this reason or start a resource.
        let status=f.audio.status;f.audio.applicationLaunched("COM.APPLE.PASSWORDS");XCTAssertEqual(f.audio.status,status);XCTAssertEqual(f.capture.starts,1)
        try await cleanup(f)
    }
    func testIngressFailureStopsItsResourceAndLateOldSinkCannotStopRestart() async throws {
        let f=try fixture();await f.audio.start();let old=try XCTUnwrap(f.capture.sink)
        old.fail("Owned stream interrupted · start to retry")
        try await wait {!f.audio.running && !f.capture.active}
        XCTAssertEqual(f.audio.status,"Owned stream interrupted · start to retry")
        await f.audio.start();XCTAssertTrue(f.audio.running)
        let fresh=try XCTUnwrap(f.capture.sink);XCTAssertFalse(old === fresh)
        old.fail("Late old error");feed(old,count:480000)
        XCTAssertTrue(f.audio.running);XCTAssertTrue(f.capture.active);XCTAssertEqual(old.snapshot.partialSamples,0)
        fresh.fail("New format changed")
        try await wait {!f.audio.running && !f.capture.active};XCTAssertEqual(f.audio.status,"New format changed");try await cleanup(f)
    }
    func testExplicitFinishTransfersActualIngressPendingSegmentBeforeClearingSink() async throws {
        let f=try fixture();await f.audio.start();let sink=try XCTUnwrap(f.capture.sink)
        feed(sink,count:480000+16000)
        XCTAssertEqual(sink.snapshot.waitingSegments,1);XCTAssertEqual(sink.snapshot.partialSamples,16000)
        f.audio.finish();try await wait {!f.audio.hasActiveWork}
        XCTAssertEqual(try f.store.stats(includeDiskUsage:false).count,2)
        XCTAssertTrue(sink.finish().isEmpty);try await cleanup(f)
    }
    func testIngressOverloadReportsDroppedDurationAndNewRunClearsHealth() async throws {
        let f=try fixture();await f.audio.start();let sink=try XCTUnwrap(f.capture.sink)
        feed(sink,count:480000*6)
        XCTAssertEqual(sink.snapshot.waitingSegments,3);XCTAssertEqual(sink.snapshot.droppedSamples,480000*3)
        f.audio.finish();try await wait {!f.audio.hasActiveWork && !sink.snapshot.deliveryScheduled}
        XCTAssertTrue(f.audio.ingressStatus.contains("90.0 s dropped"));XCTAssertEqual(try f.store.stats(includeDiskUsage:false).count,3)
        await f.audio.start();XCTAssertEqual(f.audio.ingressStatus,"");try await cleanup(f)
    }
    func testSuspendedStartupKeepsMainActorResponsiveAndStopPreventsHardware() async throws {
        let gate=AudioContextGate(),f=try fixture(context:{await gate.read()})
        let task=Task {await f.audio.start()};await fulfillment(of:[gate.entered],timeout:5)
        let tick=Task {@MainActor in 42},value=await tick.value;XCTAssertEqual(value,42);XCTAssertEqual(f.capture.starts,0)
        f.audio.stop();gate.resolve();await task.value;XCTAssertEqual(f.capture.starts,0);XCTAssertFalse(f.audio.running);XCTAssertTrue(wavFiles(f.root).isEmpty);try await cleanup(f)
    }
    func testUnavailableSecureExcludedAndStaleStartupNeverAcquireHardware() async throws {
        var browser=ownedAudioContext(bundle:"org.fixture.safari");browser.url=nil
        for context in [WindowContext?.none,ownedAudioContext(secure:true),ownedAudioContext(bundle:"com.apple.keychainaccess"),browser] {
            let f=try fixture(context:{context});await f.audio.start();XCTAssertEqual(f.capture.starts,0);XCTAssertFalse(f.audio.running);XCTAssertTrue(wavFiles(f.root).isEmpty);try await cleanup(f)
        }
        let stale=try fixture(identity:{_ in false});await stale.audio.start();XCTAssertEqual(stale.capture.starts,0);XCTAssertFalse(stale.audio.running);try await cleanup(stale)
    }
    func testOldContextCompletionCannotStopNewAttempt() async throws {
        let gate=AudioContextGate();var reads=0
        let f=try fixture(context:{reads+=1;return reads==1 ? await gate.read():ownedAudioContext()})
        let old=Task {await f.audio.start()};await fulfillment(of:[gate.entered],timeout:5);f.audio.stop()
        await f.audio.start();XCTAssertTrue(f.audio.running);XCTAssertTrue(f.capture.active)
        gate.resolve(ownedAudioContext(secure:true));await old.value;XCTAssertTrue(f.audio.running);XCTAssertTrue(f.capture.active);try await cleanup(f)
    }
    func testPrivacyPollCoalescesAndStopsOnUnknownContext() async throws {
        let gate=AudioContextGate();var hold=false,reads=0
        let f=try fixture(context:{reads+=1;return hold ? await gate.read():ownedAudioContext()});await f.audio.start();let before=reads;hold=true
        for _ in 0..<30 {f.audio.requestPrivacyCheck()}
        await fulfillment(of:[gate.entered],timeout:5);XCTAssertEqual(reads,before+1)
        gate.resolve(nil);try await wait {!f.audio.running};XCTAssertTrue(f.audio.status.contains("context unavailable"));try await cleanup(f)
    }
    func testNoWAVOrRecognizerBeforeFreshPreprocessingContext() async throws {
        let gate=AudioContextGate();var hold=false,calls=0
        let f=try fixture(context:{hold ? await gate.read():ownedAudioContext()},backend:{_ in await MainActor.run {calls+=1};return AudioPrivacyTests.transcript()})
        await f.audio.start();hold=true;f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"System audio")
        await fulfillment(of:[gate.entered],timeout:5);XCTAssertEqual(calls,0);XCTAssertTrue(wavFiles(f.root).isEmpty)
        f.audio.stop();gate.resolve();try await wait {!f.audio.hasActiveWork};XCTAssertEqual(calls,0);XCTAssertEqual(try f.store.stats(includeDiskUsage:false).count,0);try await cleanup(f)
    }
    func testDirectoryReplacementWhilePrivacyIsSuspendedCannotWriteWAVInReplacement() async throws {
        let gate=AudioContextGate();var hold=false
        let f=try fixture(context:{hold ? await gate.read():ownedAudioContext()});await f.audio.start();hold=true
        f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"System audio");await fulfillment(of:[gate.entered],timeout:5)
        let original=f.store.root,moved=f.root.appendingPathComponent("moved-library");try FileManager.default.moveItem(at:original,to:moved);try Paths.ensure(original)
        gate.resolve();try await wait {!f.audio.hasActiveWork}
        XCTAssertTrue(f.audio.status.contains("Library moved"));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:original.path).isEmpty);XCTAssertEqual(try f.store.stats(includeDiskUsage:false).count,0);try await cleanup(f)
    }
    func testPostTranscriptionPrivacyRecheckRejectsStopLockSettingsSecureUnknownAndStaleIdentity() async throws {
        for action in 0..<8 {
            let gate=AudioContextGate();var reads=0,holdAt=Int.max,locked=false,identity=true
            let f=try fixture(context:{reads+=1;return reads==holdAt ? await gate.read():ownedAudioContext()},identity:{_ in identity},locked:{locked})
            await f.audio.start();holdAt=reads+2
            f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"System audio")
            await fulfillment(of:[gate.entered],timeout:5);XCTAssertEqual(try f.store.stats(includeDiskUsage:false).count,0)
            var result:WindowContext?=ownedAudioContext()
            switch action {
            case 0:f.audio.stop()
            case 1:locked=true
            case 2:f.audio.settings.privacy.excludedApps.append("org.fixture")
            case 3:result=ownedAudioContext(secure:true)
            case 4:result=nil
            case 5:identity=false
            case 6:result=ownedAudioContext(bundle:"com.apple.keychainaccess")
            default:try FileManager.default.moveItem(at:f.store.root,to:f.root.appendingPathComponent("moved"));try Paths.ensure(f.store.root)
            }
            gate.resolve(result);try await wait {!f.audio.hasActiveWork};XCTAssertEqual(try f.store.stats(includeDiskUsage:false).count,0);XCTAssertTrue(wavFiles(f.root).isEmpty);try await cleanup(f)
        }
    }
    func testSafeExplicitFinishRetainsPendingTranscriptWithItsSessionAndPrivateAudio() async throws {
        let f=try fixture();await f.audio.start();let saved=XCTestExpectation(description:"Owned final source saved");f.audio.onCapture={_ in saved.fulfill()}
        f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"System audio");f.audio.finish()
        await fulfillment(of:[saved],timeout:5);let result=try XCTUnwrap(f.store.search(.init(),mode:.keyword).first)
        XCTAssertEqual(result.memory.text,"Owned words");XCTAssertNotNil(result.memory.audioSessionID);XCTAssertNotNil(result.memory.audioPath);XCTAssertEqual(f.audio.transcribed,1);try await cleanup(f)
    }
    func testRecognizerFailureDoesNotDisableOtherwiseAllowedCapture() async throws {
        var calls=0
        let f=try fixture(backend:{_ in let n=await MainActor.run {calls+=1;return calls};if n==1 {throw OSwindError.unavailable("Owned recognizer failure")};return AudioPrivacyTests.transcript()})
        await f.audio.start();f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"System audio")
        try await wait {f.audio.status.contains("Owned recognizer failure")};XCTAssertTrue(f.audio.running)
        let saved=XCTestExpectation(description:"Retry segment saved");f.audio.onCapture={_ in saved.fulfill()};f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"System audio")
        await fulfillment(of:[saved],timeout:5);XCTAssertEqual(f.audio.transcribed,1);XCTAssertTrue(f.audio.running);try await cleanup(f)
    }
    func testRestartDuringFinishingCannotRelabelOldQueuedAudioAsTheNewSession() async throws {
        let gate=AudioContextGate();var calls=0
        let f=try fixture(backend:{_ in let n=await MainActor.run {calls+=1;return calls};if n==1 {_=await gate.read()};return AudioPrivacyTests.transcript(n==1 ? "Old words":"New words")})
        await f.audio.start();f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"Old source")
        await fulfillment(of:[gate.entered],timeout:5)
        f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"Old queued source");f.audio.finish()
        let restart=Task {await f.audio.start()};try await wait {f.audio.running};gate.resolve();await restart.value
        let saved=XCTestExpectation(description:"Only new session source saved");f.audio.onCapture={_ in saved.fulfill()}
        f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"New source")
        await fulfillment(of:[saved],timeout:5)
        let hits=try f.store.search(.init(),mode:.keyword);XCTAssertEqual(hits.count,1);XCTAssertEqual(hits.first?.memory.text,"New words");XCTAssertEqual(hits.first?.memory.app,"New source");try await cleanup(f)
    }
    func testBackpressureRetainsAtMostThreeWaitingChunks() async throws {
        let gate=AudioContextGate();var calls=0
        let f=try fixture(backend:{_ in let n=await MainActor.run {calls+=1;return calls};if n==1 {_=await gate.read()};return AudioPrivacyTests.transcript()})
        await f.audio.start();f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"System audio");await fulfillment(of:[gate.entered],timeout:5)
        for _ in 0..<10 {f.audio.enqueue(Array(repeating:0.05,count:16000),date:Date(),source:"System audio")}
        XCTAssertTrue(f.audio.status.contains("backpressure"));gate.resolve();try await wait {f.audio.transcribed==4};XCTAssertEqual(calls,4);try await cleanup(f)
    }
}
