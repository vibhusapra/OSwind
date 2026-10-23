import XCTest
import FluidAudio
@testable import OSwindCore

final class SpeakerRuntimeTests:XCTestCase {
    actor Gate {
        let entered=XCTestExpectation(description:"speaker backend suspended")
        var continuation:CheckedContinuation<Void,Never>?
        func wait() async { await withCheckedContinuation { continuation=$0; entered.fulfill() } }
        func open() { continuation?.resume();continuation=nil }
    }
    actor Counter { var count=0;func increment(){count += 1} }
    actor Backend:SpeakerDiarizationBackend {
        var calls=0
        var gate:Gate?
        init(gate:Gate?=nil) { self.gate=gate }
        func turns(file:URL) async throws -> [SpeakerTurn] { calls += 1; if calls==1,let gate { await gate.wait() };return [SpeakerTurn(start:0,end:1,speaker:"arbitrary-local-id")] }
    }
    actor EmptyOrFailedBackend:SpeakerDiarizationBackend {
        let noSpeech:Bool
        init(noSpeech:Bool) {self.noSpeech=noSpeech}
        func turns(file:URL) async throws -> [SpeakerTurn] {
            if noSpeech {throw OfflineDiarizationError.noSpeechDetected}
            throw OSwindError.unavailable("Fixture hard failure")
        }
    }
    var root:URL!,config:DiarizationConfiguration!
    let input=SpeechTranscript(text:"Synthetic",duration:1,segments:[TranscriptSegment(start:0,end:1,text:"Synthetic")],model:"fixture")
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try Paths.ensure(root)
        for name in ["Segmentation.mlmodelc","FBank.mlmodelc","Embedding.mlmodelc","PldaRho.mlmodelc"] { try Paths.ensure(root.appendingPathComponent(name)) }
        try Data("{}".utf8).write(to:root.appendingPathComponent("plda-parameters.json"))
        config=DiarizationConfiguration();config.enabled=true;config.modelDirectory=root.path
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    func queue(_ runtime:SpeakerDiarizer,count:Int) async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(5))
        while await runtime.queuedRequestCount != count && ContinuousClock.now<end { try await Task.sleep(nanoseconds:1_000_000) }
        let actual=await runtime.queuedRequestCount;XCTAssertEqual(actual,count)
    }
    func testDisabledUnsupportedAndInvalidModelsNeverLoad() async throws {
        let count=Counter(),runtime=SpeakerDiarizer(loader:{_ in await count.increment();return Backend()},supported:{false})
        var disabled=config!;disabled.enabled=false
        let unchanged=try await runtime.annotate(input,file:root,configuration:disabled);XCTAssertEqual(unchanged,input)
        do { _ = try await runtime.annotate(input,file:root,configuration:config);XCTFail("Unsupported OS accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("macOS 15")) }
        let loads=await count.count;XCTAssertEqual(loads,0)
    }
    func testResidentReuseAndUnload() async throws {
        let count=Counter(),runtime=SpeakerDiarizer(loader:{_ in await count.increment();return Backend()})
        for _ in 0..<2 { let result=try await runtime.annotate(input,file:root,configuration:config);XCTAssertEqual(result.segments[0].speaker,"Speaker 1") }
        var loads=await count.count;XCTAssertEqual(loads,1)
        try await runtime.unload();_ = try await runtime.annotate(input,file:root,configuration:config)
        loads=await count.count;XCTAssertEqual(loads,2)
    }
    func testRawTimelineAndWordAttributionShareResidentBackend() async throws {
        let count=Counter(),runtime=SpeakerDiarizer(loader:{_ in await count.increment();return Backend()})
        let timeline=try await runtime.timeline(file:root,duration:1,configuration:config)
        XCTAssertEqual(timeline.turns,[SpeakerTurn(start:0,end:1,speaker:"arbitrary-local-id")]);XCTAssertEqual(timeline.scope,"recording")
        let transcript=try await runtime.annotate(input,file:root,configuration:config)
        XCTAssertEqual(transcript.segments[0].speaker,"Speaker 1")
        let loads=await count.count;XCTAssertEqual(loads,1)
        var disabled=config!;disabled.enabled=false
        do {_ = try await runtime.timeline(file:root,duration:1,configuration:disabled);XCTFail("A disabled timeline must not be scored as silence")} catch {XCTAssertTrue(error.localizedDescription.contains("Enable"))}
        do {_ = try await runtime.timeline(file:root,duration:.infinity,configuration:config);XCTFail("Invalid duration accepted")} catch {}
        try await runtime.unload()
    }
    func testNoDetectedSpeechIsEmptyButActualFailuresStillThrow() async throws {
        let empty=SpeakerDiarizer(loader:{_ in EmptyOrFailedBackend(noSpeech:true)})
        let timeline=try await empty.timeline(file:root,duration:1,configuration:config);XCTAssertTrue(timeline.turns.isEmpty)
        let transcript=try await empty.annotate(input,file:root,configuration:config)
        XCTAssertEqual(transcript.text,input.text);XCTAssertNil(transcript.segments[0].speaker);XCTAssertEqual(transcript.diarization?.detectedSpeakers,0);XCTAssertEqual(transcript.diarization?.unassignedSegments,1)
        let failed=SpeakerDiarizer(loader:{_ in EmptyOrFailedBackend(noSpeech:false)})
        do {_ = try await failed.timeline(file:root,duration:1,configuration:config);XCTFail("Actual failure became an empty score")} catch {XCTAssertTrue(error.localizedDescription.contains("Fixture hard failure"))}
    }
    func testQueuedCancellationAndInferenceCancellationDoNotReturnLabels() async throws {
        let gate=Gate(),backend=Backend(gate:gate),runtime=SpeakerDiarizer(loader:{_ in backend})
        let first=Task { try await runtime.annotate(input,file:root,configuration:config) };await fulfillment(of:[gate.entered],timeout:5)
        let second=Task { try await runtime.annotate(input,file:root,configuration:config) };try await queue(runtime,count:1);second.cancel()
        do { _ = try await second.value;XCTFail("Queued cancellation ignored") } catch is CancellationError {} catch { throw error }
        first.cancel();await gate.open()
        do { _ = try await first.value;XCTFail("Inference cancellation ignored") } catch is CancellationError {} catch { throw error }
        _ = try await runtime.annotate(input,file:root,configuration:config)
        let calls=await backend.calls;XCTAssertEqual(calls,2)
    }
    func testCancelledModelLoadIsNotReused() async throws {
        let gate=Gate(),count=Counter(),runtime=SpeakerDiarizer(loader:{_ in await count.increment();if await count.count==1 { await gate.wait() };return Backend()})
        let first=Task { try await runtime.annotate(input,file:root,configuration:config) };await fulfillment(of:[gate.entered],timeout:5);first.cancel();await gate.open()
        do { _ = try await first.value;XCTFail("Load cancellation ignored") } catch is CancellationError {} catch { throw error }
        _ = try await runtime.annotate(input,file:root,configuration:config)
        let loads=await count.count;XCTAssertEqual(loads,2)
    }
    func testOverdueResultsAreDiscardedAndRuntimeCanBeReused() async throws {
        let gate=Gate(),backend=Backend(gate:gate),runtime=SpeakerDiarizer(loader:{_ in backend})
        let first=Task { try await runtime.annotate(input,file:root,configuration:config,timeout:0.02) };await fulfillment(of:[gate.entered],timeout:5)
        try await Task.sleep(nanoseconds:40_000_000);await gate.open()
        do { _ = try await first.value;XCTFail("Overdue speaker result returned") } catch { XCTAssertTrue(error.localizedDescription.contains("time budget")) }
        _ = try await runtime.annotate(input,file:root,configuration:config)
    }
    func testPLDAParametersAreBoundedTypedAndFinite() throws {
        func write(_ value:Float,shape:[Int]=[128]) throws {
            var data=Data();for _ in 0..<128 { var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits){data.append(contentsOf:$0)} }
            try JSONSerialization.data(withJSONObject:["tensors":["psi":["shape":shape,"dtype":"float32","data_base64":data.base64EncodedString()]]]).write(to:root.appendingPathComponent("plda-parameters.json"))
        }
        try write(1);XCTAssertEqual(try SpeakerModelParameters.psi(in:root),Array(repeating:1,count:128))
        for value:Float in [.nan,.infinity,0,-1] { try write(value);XCTAssertThrowsError(try SpeakerModelParameters.psi(in:root)) }
        try write(1,shape:[127]);XCTAssertThrowsError(try SpeakerModelParameters.psi(in:root))
        try Data(repeating:0,count:1024*1024+1).write(to:root.appendingPathComponent("plda-parameters.json"));XCTAssertThrowsError(try SpeakerModelParameters.psi(in:root))
    }
    func testSpeakerRenamesPersistAndRefuseMergesMissingRecordsAndSecrets() throws {
        let store=try MemoryStore(root:root.appendingPathComponent("library"))
        var memory=Memory(kind:.audio,text:"Synthetic");memory.transcript=input;memory.transcript?.segments[0].speaker="Speaker 1";memory.transcript?.segments.append(TranscriptSegment(start:0,end:1,text:"Synthetic",speaker:"Speaker 2"));try store.insert(memory)
        let updated=try store.renameAudioSpeaker(memory.id,from:"Speaker 1",to:"Maya");XCTAssertEqual(updated.transcript?.segments[0].speaker,"Maya")
        XCTAssertEqual(try store.get(memory.id)?.transcript,updated.transcript)
        XCTAssertThrowsError(try store.renameAudioSpeaker(memory.id,from:"Maya",to:"Speaker 2"))
        XCTAssertThrowsError(try store.renameAudioSpeaker(memory.id,from:"missing",to:"Other"))
        XCTAssertThrowsError(try store.renameAudioSpeaker(memory.id,from:"Maya",to:"password=synthetic123"))
        try store.delete(memory.id);XCTAssertThrowsError(try store.renameAudioSpeaker(memory.id,from:"Maya",to:"Other"))
    }
    func testRealOfflineSpeakersWhenExplicitlyConfigured() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let model=env["OSWIND_TEST_SPEAKER_MODEL"],let file=env["OSWIND_TEST_SPEAKER_FIXTURE"] else { throw XCTSkip("Set local model and public synthetic fixture paths; never downloads") }
        var config=DiarizationConfiguration();config.enabled=true;config.modelDirectory=model
        let source=SpeechTranscript(text:"First and second synthetic voices",duration:32.225,segments:[TranscriptSegment(start:1,end:2,text:"first"),TranscriptSegment(start:9,end:10,text:"second"),TranscriptSegment(start:18,end:19,text:"first"),TranscriptSegment(start:26,end:27,text:"second")],model:"fixture")
        let runtime=SpeakerDiarizer(),result=try await runtime.annotate(source,file:URL(fileURLWithPath:file),configuration:config)
        XCTAssertEqual(result.diarization?.detectedSpeakers,2);XCTAssertEqual(result.segments.map(\.speaker),["Speaker 1","Speaker 2","Speaker 1","Speaker 2"])
        try await runtime.unload()
    }
}
