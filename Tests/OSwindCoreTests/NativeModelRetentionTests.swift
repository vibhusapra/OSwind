import XCTest
@testable import OSwindCore

final class NativeModelRetentionTests:XCTestCase {
    actor Counter {var value=0;func increment(){value += 1}}
    actor Clock {
        var intervals=[Double]();var continuations=[CheckedContinuation<Void,Never>?]()
        func sleep(_ seconds:Double) async {await withCheckedContinuation {continuations.append($0);intervals.append(seconds)}}
        func fire(_ index:Int) {continuations[index]?.resume();continuations[index]=nil}
        func finish() {for i in continuations.indices {fire(i)}}
    }
    actor Work {
        var calls=0;var suspended=false
        var gate:CheckedContinuation<Void,Never>?
        let blockSecond:Bool
        init(blockSecond:Bool){self.blockSecond=blockSecond}
        func run() async {calls += 1;if blockSecond && calls==2 {await withCheckedContinuation {gate=$0;suspended=true}}}
        func resume(){gate?.resume();gate=nil;suspended=false}
    }
    struct Speech:NativeSpeechBackend {
        let work:Work
        func transcribe(file:URL,language:String) async throws -> SpeechTranscript {await work.run();return SpeechTranscript(text:"fixture",duration:1,segments:[],model:"fixture")}
    }
    struct Speaker:SpeakerDiarizationBackend {
        let work:Work
        func turns(file:URL) async throws -> [SpeakerTurn] {await work.run();return [SpeakerTurn(start:0,end:1,speaker:"local")]}
    }
    struct Harness {
        var operation:@Sendable () async throws -> Void
        var policy:@Sendable (NativeModelRetention) async -> Void
        var resident:@Sendable () async -> Bool
        var queued:@Sendable () async -> Int
        var unload:@Sendable () async throws -> Void
    }
    var model:URL!
    override func setUpWithError() throws {
        model=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try Paths.ensure(model)
        for name in ["Segmentation.mlmodelc","FBank.mlmodelc","Embedding.mlmodelc","PldaRho.mlmodelc"] {try Paths.ensure(model.appendingPathComponent(name))}
        try Data("{}".utf8).write(to:model.appendingPathComponent("plda-parameters.json"))
    }
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:model)}
    func harness(speaker:Bool,clock:Clock,loads:Counter,work:Work) -> Harness {
        let file=model!
        if speaker {
            var config=DiarizationConfiguration();config.enabled=true;config.modelDirectory=file.path;let configuration=config
            let runtime=SpeakerDiarizer(loader:{_ in await loads.increment();return Speaker(work:work)},idleSleep:{await clock.sleep($0)})
            return Harness(operation:{_ = try await runtime.timeline(file:file,duration:1,configuration:configuration)},policy:{await runtime.setRetention($0)},resident:{await runtime.modelResident},queued:{await runtime.queuedRequestCount},unload:{try await runtime.unload()})
        }
        var config=AppSettings();config.speech.engine = .parakeet;let settings=config
        let runtime=SpeechRecognizer(loader:{_ in await loads.increment();return Speech(work:work)},idleSleep:{await clock.sleep($0)})
        return Harness(operation:{_ = try await runtime.transcribe(file:file,settings:settings)},policy:{await runtime.setRetention($0)},resident:{await runtime.modelResident},queued:{await runtime.queuedRequestCount},unload:{try await runtime.unload()})
    }
    func eventually(_ predicate:@escaping () async -> Bool,file:StaticString=#filePath,line:UInt=#line) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !(await predicate()) && ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(1))}
        let passed=await predicate();XCTAssertTrue(passed,file:file,line:line)
    }
    func testLegacyDefaultsAndPolicyRoundTrip() throws {
        let old=try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8));XCTAssertEqual(old.nativeModelRetention,.twoMinutes)
        for policy in NativeModelRetention.allCases {
            var settings=old;settings.nativeModelRetention=policy
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings)).nativeModelRetention,policy)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self,from:Data(#"{"nativeModelRetention":"invalid"}"#.utf8)))
    }
    func testAfterUseReloadAndUntilQuitManualReleaseForBothRuntimes() async throws {
        for speaker in [false,true] {
            let clock=Clock(),loads=Counter(),work=Work(blockSecond:false),h=harness(speaker:speaker,clock:clock,loads:loads,work:work)
            await h.policy(.afterUse)
            try await h.operation();try await h.operation()
            let count=await loads.value,resident=await h.resident();XCTAssertEqual(count,2);XCTAssertFalse(resident)
            await h.policy(.untilQuit);try await h.operation();try await h.operation()
            let kept=await h.resident(),reused=await loads.value,timers=await clock.intervals;XCTAssertTrue(kept);XCTAssertEqual(reused,3);XCTAssertTrue(timers.isEmpty)
            try await h.unload();let released=await h.resident();XCTAssertFalse(released)
        }
    }
    func testActualIdleExpiryReloadAndPolicyRescheduleForBothRuntimes() async throws {
        for speaker in [false,true] {
            let clock=Clock(),loads=Counter(),work=Work(blockSecond:false),h=harness(speaker:speaker,clock:clock,loads:loads,work:work)
            try await h.operation();try await eventually {await clock.intervals.count==1}
            let first=await clock.intervals;XCTAssertEqual(first,[120]);await clock.fire(0)
            try await eventually {!(await h.resident())};try await h.operation()
            try await eventually {await clock.intervals.count==2};await h.policy(.tenMinutes)
            try await eventually {await clock.intervals.count==3};let values=await clock.intervals;XCTAssertEqual(values,[120,120,600])
            // The canceled previous sleep deliberately ignores cancellation.
            await clock.fire(1);try await Task.sleep(for:.milliseconds(5));let still=await h.resident();XCTAssertTrue(still)
            await clock.fire(2);try await eventually {!(await h.resident())}
            let count=await loads.value;XCTAssertEqual(count,2);await clock.finish()
        }
    }
    func testOldExpiryAndChangedPolicyNeverDropActiveOrQueuedModels() async throws {
        for speaker in [false,true] {
            let clock=Clock(),loads=Counter(),work=Work(blockSecond:true),h=harness(speaker:speaker,clock:clock,loads:loads,work:work)
            try await h.operation();try await eventually {await clock.intervals.count==1}
            let active=Task {try await h.operation()};try await eventually {await work.suspended}
            let queued=Task {try await h.operation()};try await eventually {await h.queued()==1}
            await h.policy(.afterUse);await clock.fire(0);try await Task.sleep(for:.milliseconds(5))
            let busyResident=await h.resident();XCTAssertTrue(busyResident)
            await work.resume();try await active.value;try await queued.value
            let count=await loads.value,resident=await h.resident(),calls=await work.calls
            XCTAssertEqual(count,1);XCTAssertEqual(calls,3);XCTAssertFalse(resident);await clock.finish()
        }
    }
    func testKeepResidentCancelsPendingExpiryForBothRuntimes() async throws {
        for speaker in [false,true] {
            let clock=Clock(),loads=Counter(),work=Work(blockSecond:false),h=harness(speaker:speaker,clock:clock,loads:loads,work:work)
            try await h.operation();try await eventually {await clock.intervals.count==1}
            await h.policy(.untilQuit);await clock.fire(0);try await Task.sleep(for:.milliseconds(5))
            let resident=await h.resident();XCTAssertTrue(resident);try await h.unload();await clock.finish()
        }
    }
    @MainActor func testAudioControllerAppliesPersistedAndChangedPolicyWithoutStartingCapture() async throws {
        let store=try MemoryStore(root:model.appendingPathComponent("library")),clock=Clock(),loads=Counter(),work=Work(blockSecond:false)
        let speech=SpeechRecognizer(loader:{_ in await loads.increment();return Speech(work:work)},idleSleep:{await clock.sleep($0)})
        var settings=AppSettings();settings.nativeModelRetention = .afterUse;settings.speech.engine = .parakeet
        let controller=AudioController(store:store,embedder:LocalEmbedder(),settings:settings,startup:AudioStartupEnvironment(),recognizer:speech)
        try await eventually {await speech.retentionPolicy == .afterUse}
        try await speech.prepare(settings:settings);let released=await speech.modelResident;XCTAssertFalse(released)
        controller.settings.nativeModelRetention = .untilQuit
        let speakers=controller.speakers
        try await eventually {let a=await speech.retentionPolicy,b=await speakers.retentionPolicy;return a == .untilQuit && b == .untilQuit}
        let speakerPolicy=await controller.speakers.retentionPolicy;XCTAssertEqual(speakerPolicy,.untilQuit)
        try await speech.prepare(settings:settings);let kept=await speech.modelResident;XCTAssertTrue(kept)
        XCTAssertFalse(controller.running);XCTAssertFalse(controller.hasActiveWork)
        try await speech.unload();await clock.finish()
    }
    func testRealNativeWeightsExpireAndReloadWhenExplicitlyConfigured() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let speechModel=env["OSWIND_TEST_PARAKEET_MODEL"],let speakerModel=env["OSWIND_TEST_SPEAKER_MODEL"],let audio=env["OSWIND_TEST_SPEECH_FIXTURE"],env["OSWIND_TEST_REAL_IDLE"]=="1" else {throw XCTSkip("Opt in to a real 120-second idle/model-reload check with local models and a public fixture; never downloads")}
        let speech=SpeechRecognizer(),speaker=SpeakerDiarizer(),clip=try await AudioClipSnapshot.prepare(URL(fileURLWithPath:audio))
        defer {withExtendedLifetime(clip){}}
        var settings=AppSettings();settings.speech.engine = .parakeet;settings.speech.compute = .gpu;settings.speech.modelDirectory=speechModel
        var config=DiarizationConfiguration();config.enabled=true;config.modelDirectory=speakerModel
        let first=try await speech.transcribe(file:clip.speechFile,settings:settings)
        let timeline=try await speaker.timeline(file:clip.speechFile,duration:clip.duration,configuration:config)
        let speechReady=await speech.modelResident,speakerReady=await speaker.modelResident
        XCTAssertTrue(speechReady);XCTAssertTrue(speakerReady)
        let started=ContinuousClock.now
        while ContinuousClock.now-started < .seconds(130) {
            let speechAlive=await speech.modelResident,speakerAlive=await speaker.modelResident
            if !speechAlive && !speakerAlive {break}
            try await Task.sleep(for:.seconds(1))
        }
        let speechExpired=await speech.modelResident,speakerExpired=await speaker.modelResident
        XCTAssertFalse(speechExpired);XCTAssertFalse(speakerExpired)
        // Observe actual default timers, then select a different policy and
        // exercise complete reload. No model files/cache eviction is requested.
        await speech.setRetention(.untilQuit);await speaker.setRetention(.untilQuit)
        let second=try await speech.transcribe(file:clip.speechFile,settings:settings)
        let secondTimeline=try await speaker.timeline(file:clip.speechFile,duration:clip.duration,configuration:config)
        XCTAssertEqual(first,second);XCTAssertEqual(timeline,secondTimeline)
        await speech.setRetention(.afterUse);await speaker.setRetention(.afterUse)
        let speechReleased=await speech.modelResident,speakerReleased=await speaker.modelResident
        XCTAssertFalse(speechReleased);XCTAssertFalse(speakerReleased)
        print("Real local weights: both default idle timers expired; reloaded ASR/timelines equal; after-use policy releases both runtimes. GPU requested, per-operation placement and power unmeasured.")
    }

}
