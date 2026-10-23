import XCTest
@testable import OSwindCore

final class SpeechRecognitionTests: XCTestCase {
    actor Gate {
        let entered=XCTestExpectation(description:"native operation suspended")
        var continuation:CheckedContinuation<Void,Never>?
        func wait() async { await withCheckedContinuation { continuation=$0; entered.fulfill() } }
        func open() { continuation?.resume(); continuation=nil }
    }
    actor Counter { var value=0; func increment() { value += 1 } }
    actor Backend:NativeSpeechBackend {
        var calls=0
        var gate:Gate?
        var invalid=false
        init(gate:Gate?=nil,invalid:Bool=false) { self.gate=gate; self.invalid=invalid }
        func transcribe(file:URL,language:String) async throws -> SpeechTranscript {
            calls += 1
            if calls==1,let gate { await gate.wait() }
            return SpeechTranscript(text:file.lastPathComponent,duration:invalid ? .nan : 1,segments:[],model:"test")
        }
    }
    func settings() -> AppSettings { var value=AppSettings(); value.speech.engine = .parakeet; value.speech.modelDirectory="/synthetic/model"; return value }
    let file=URL(fileURLWithPath:"/synthetic/first.wav")
    func waitForQueue(_ recognizer:SpeechRecognizer,count:Int) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while await recognizer.queuedRequestCount != count && ContinuousClock.now<deadline { try await Task.sleep(nanoseconds:1_000_000) }
        let actual=await recognizer.queuedRequestCount; XCTAssertEqual(actual,count)
    }
    func testLegacySettingsDefaultToWhisperAndPartialNativeSettingsDecode() throws {
        let old=try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8)); XCTAssertEqual(old.speech.engine,.whisper)
        let partial=try JSONDecoder().decode(AppSettings.self,from:Data(#"{"speech":{"engine":"parakeet"}}"#.utf8)); XCTAssertEqual(partial.speech.compute,.neuralEngine); XCTAssertEqual(partial.speech.modelDirectory,"")
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self,from:Data(#"{"speech":{"engine":"cloud"}}"#.utf8)))
    }
    func testMissingModelsFailLocallyWithoutCreatingCache() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-model-check-"+UUID().uuidString)
        var value=SpeechConfiguration(); value.modelDirectory=root.path
        XCTAssertThrowsError(try value.validateLocalModel()); XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false); defer { try? FileManager.default.removeItem(at:root) }
        XCTAssertThrowsError(try value.validateLocalModel())
        value.modelDirectory="relative/model"; XCTAssertThrowsError(try value.validateLocalModel())
    }
    func testModelReuseConfigurationChangeAndExplicitUnload() async throws {
        let count=Counter(), backend=Backend(), native=SpeechRecognizer(loader:{ _ in await count.increment(); return backend })
        try await native.prepare(settings:settings())
        let before=await backend.calls; XCTAssertEqual(before,0)
        let first=try await native.transcribe(file:file,settings:settings())
        let second=try await native.transcribe(file:URL(fileURLWithPath:"/synthetic/second.wav"),settings:settings())
        XCTAssertEqual(first.text,"first.wav"); XCTAssertEqual(second.text,"second.wav")
        var loaded=await count.value; XCTAssertEqual(loaded,1)
        var changed=settings(); changed.speech.compute = .gpu
        _ = try await native.transcribe(file:file,settings:changed); loaded=await count.value; XCTAssertEqual(loaded,2)
        try await native.unload(); _ = try await native.transcribe(file:file,settings:changed)
        loaded=await count.value; XCTAssertEqual(loaded,3)
    }
    func testFIFORequestsNeverEnterBackendConcurrently() async throws {
        let gate=Gate(), backend=Backend(gate:gate), native=SpeechRecognizer(loader:{ _ in backend })
        let first=Task { try await native.transcribe(file:file,settings:settings()) }
        await fulfillment(of:[gate.entered],timeout:5)
        let second=Task { try await native.transcribe(file:URL(fileURLWithPath:"/synthetic/second.wav"),settings:settings()) }
        try await waitForQueue(native,count:1)
        let calls=await backend.calls; XCTAssertEqual(calls,1)
        await gate.open(); _ = try await first.value; let result=try await second.value
        XCTAssertEqual(result.text,"second.wav"); let final=await backend.calls; XCTAssertEqual(final,2)
    }
    func testQueuedCancellationDoesNotTranscribeAndReleasesNextRequest() async throws {
        let gate=Gate(), backend=Backend(gate:gate), native=SpeechRecognizer(loader:{ _ in backend })
        let first=Task { try await native.transcribe(file:file,settings:settings()) }
        await fulfillment(of:[gate.entered],timeout:5)
        let cancelled=Task { try await native.transcribe(file:file,settings:settings()) }
        try await waitForQueue(native,count:1); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled queued recognition succeeded") } catch is CancellationError {} catch { throw error }
        try await waitForQueue(native,count:0)
        await gate.open(); _ = try await first.value
        _ = try await native.transcribe(file:file,settings:settings())
        let calls=await backend.calls; XCTAssertEqual(calls,2)
    }
    func testCancellationDuringModelLoadNeverCachesOrTranscribesCandidate() async throws {
        let gate=Gate(), count=Counter(), backend=Backend()
        let native=SpeechRecognizer(loader:{ _ in await count.increment(); if await count.value==1 { await gate.wait() }; return backend })
        let first=Task { try await native.transcribe(file:file,settings:settings()) }
        await fulfillment(of:[gate.entered],timeout:5); first.cancel(); await gate.open()
        do { _ = try await first.value; XCTFail("Cancelled model load succeeded") } catch is CancellationError {} catch { throw error }
        let before=await backend.calls; XCTAssertEqual(before,0)
        _ = try await native.transcribe(file:file,settings:settings())
        let loads=await count.value; XCTAssertEqual(loads,2)
    }
    func testCancellationDuringInferenceDiscardsResultAndQueueRemainsUsable() async throws {
        let gate=Gate(), backend=Backend(gate:gate), native=SpeechRecognizer(loader:{ _ in backend })
        let first=Task { try await native.transcribe(file:file,settings:settings()) }
        await fulfillment(of:[gate.entered],timeout:5); first.cancel(); await gate.open()
        do { _ = try await first.value; XCTFail("Cancelled inference returned text") } catch is CancellationError {} catch { throw error }
        _ = try await native.transcribe(file:file,settings:settings())
    }
    func testMalformedBackendOutputCannotEscapeValidation() async throws {
        let native=SpeechRecognizer(loader:{ _ in Backend(invalid:true) })
        do { _ = try await native.transcribe(file:file,settings:settings()); XCTFail("Invalid output accepted") } catch {}
        try await native.unload()
    }
    func testOverdueInferenceCannotReturnTextAndReleasesQueue() async throws {
        let gate=Gate(), backend=Backend(gate:gate), native=SpeechRecognizer(loader:{ _ in backend })
        let first=Task { try await native.transcribe(file:file,settings:settings(),timeout:0.02) }
        await fulfillment(of:[gate.entered],timeout:5)
        try await Task.sleep(nanoseconds:40_000_000); await gate.open()
        do { _ = try await first.value; XCTFail("Overdue inference succeeded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("time budget")) }
        _ = try await native.transcribe(file:file,settings:settings())
    }
    func testInvalidBudgetCannotLoadOrTranscribe() async throws {
        let count=Counter(), native=SpeechRecognizer(loader:{ _ in await count.increment(); return Backend() })
        for timeout in [0,-1,Double.nan,Double.infinity,86401] {
            do { _ = try await native.transcribe(file:file,settings:settings(),timeout:timeout); XCTFail("Invalid budget accepted") } catch {}
        }
        let loads=await count.value; XCTAssertEqual(loads,0)
    }
    func testRealNativeOfflineModelWhenExplicitlyConfigured() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let model=env["OSWIND_TEST_PARAKEET_MODEL"],let audio=env["OSWIND_TEST_SPEECH_FIXTURE"] else { throw XCTSkip("Set local model and public audio fixture paths to exercise Core ML; never downloads") }
        var config=settings(); config.speech.modelDirectory=model
        let native=SpeechRecognizer(), first=try await native.transcribe(file:URL(fileURLWithPath:audio),settings:config)
        XCTAssertTrue(first.text.lowercased().contains("country")); XCTAssertFalse(first.segments.isEmpty)
        let second=try await native.transcribe(file:URL(fileURLWithPath:audio),settings:config)
        XCTAssertEqual(first.text,second.text); XCTAssertEqual(first.segments,second.segments)
        try await native.unload()
    }
}
