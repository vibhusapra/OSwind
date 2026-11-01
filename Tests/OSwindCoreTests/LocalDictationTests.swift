import XCTest
import AVFoundation
import Darwin
@testable import OSwindCore

@MainActor final class LocalDictationTests:XCTestCase {
    func add(_ samples:[Float],to buffer:DictationPCMBuffer) {samples.withUnsafeBufferPointer {buffer.add($0,at:Date())}}
    func wait(_ condition:@escaping ()->Bool)async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(5))
        while !condition(),ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(2))};XCTAssertTrue(condition())
    }
    func testConcurrentCallbacksCapPCMAndFinishTransfersExactlyOnce() throws {
        let buffer=DictationPCMBuffer(),input=Array(repeating:Float(0.1),count:1000)
        DispatchQueue.concurrentPerform(iterations:1000) {_ in input.withUnsafeBufferPointer {buffer.add($0,at:Date())}}
        XCTAssertTrue(buffer.full);let samples=try buffer.finish();XCTAssertEqual(samples.count,480000);XCTAssertTrue(samples.allSatisfy {$0==0.1})
        add(input,to:buffer);XCTAssertTrue(try buffer.finish().isEmpty)
    }
    func testInvalidCallbackAndCancelDiscardBufferedAudio() throws {
        for bad in [[],[Float.nan],[Float.infinity],Array(repeating:Float(0.1),count:32769)] {
            let buffer=DictationPCMBuffer();add([0.1,0.2],to:buffer);add(bad,to:buffer);XCTAssertThrowsError(try buffer.finish())
        }
        let buffer=DictationPCMBuffer();add([0.1],to:buffer);buffer.cancel();add([0.2],to:buffer);XCTAssertTrue(try buffer.finish().isEmpty)
    }
    func testDeniedMicrophoneNeverCreatesEngine()async throws {
        var made=0
        let recorder=LocalDictationRecorder(authorize:{false},makeEngine:{made+=1;throw OSwindError.invalid("Unexpected microphone")})
        do {try await recorder.start();XCTFail("Permission denial accepted")}catch {XCTAssertTrue(error.localizedDescription.contains("Microphone"))}
        XCTAssertEqual(made,0);XCTAssertFalse(recorder.full)
    }
    func testCancelledPermissionWaitCannotOpenOrStartAnotherMicrophone()async throws {
        var continuation:CheckedContinuation<Bool,Never>?,made=0,requests=0
        let recorder=LocalDictationRecorder(authorize:{requests+=1;return await withCheckedContinuation {continuation=$0}},makeEngine:{made+=1;throw OSwindError.invalid("Unexpected microphone")})
        let task=Task {try await recorder.start()};try await wait {continuation != nil};recorder.cancel()
        do {try await recorder.start();XCTFail("Second pending permission request")}catch {}
        XCTAssertEqual(requests,1);continuation?.resume(returning:true)
        do {try await task.value;XCTFail("Late permission opened microphone")}catch is CancellationError {}catch {XCTFail("Unexpected error \(error)")}
        XCTAssertEqual(made,0)
    }
    func testFinishDuringPendingAuthorizationRevokesLateMicrophoneStart()async throws {
        var continuation:CheckedContinuation<Bool,Never>?,made=0
        let recorder=LocalDictationRecorder(authorize:{await withCheckedContinuation {continuation=$0}},makeEngine:{made+=1;throw OSwindError.invalid("Owned late engine attempt")})
        let task=Task {try await recorder.start()};try await wait {continuation != nil}
        XCTAssertThrowsError(try recorder.finish(),"Finish without active PCM reports no recording, while revoking pending authorization")
        continuation?.resume(returning:true)
        do {try await task.value;XCTFail("Late microphone start after finish")}catch is CancellationError {}catch {XCTFail("Expected revoked startup, got \(error)")}
        XCTAssertEqual(made,0,"Finish must not let a late permission response create an engine")
    }
    func testPrivateWorkspaceWAVAndCleanupWithoutSavingHistory()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-dictation-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        var owned:URL?
        let result=try await LocalDictation.transcribe(samples:Array(repeating:0.1,count:16000),store:store) {file,parent in
            owned=parent
            let path=try XCTUnwrap(realpath(root.path,nil));defer {free(path)}
            let expected=URL(fileURLWithPath:String(cString:path)).appendingPathComponent("audio/.staging",isDirectory:true).pathComponents
            XCTAssertEqual(Array(file.pathComponents.prefix(expected.count)),expected,"actual owned WAV: \(file.path)")
            XCTAssertEqual(file.deletingLastPathComponent(),parent)
            let attrs=try FileManager.default.attributesOfItem(atPath:file.path);XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue,0o600)
            XCTAssertEqual(try Data(contentsOf:file).count,32044)
            return SpeechTranscript(text:"Owned speech",duration:1,segments:[.init(start:0,end:1,text:"Owned speech")],model:"owned")
        }
        XCTAssertEqual(result.text,"Owned speech");XCTAssertEqual(try store.stats().count,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(owned).path))
    }
    func testCancelledRecognizerKeepsWorkspaceUntilActualReturnAndDropsResult()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-dictation-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        var continuation:CheckedContinuation<Void,Never>?,owned:URL?
        let task=Task {try await LocalDictation.transcribe(samples:Array(repeating:0.1,count:16000),store:store) {file,parent in
            owned=parent;await withCheckedContinuation {continuation=$0};XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
            return SpeechTranscript(text:"Late speech",duration:1,segments:[],model:"owned")
        }}
        try await wait {continuation != nil};task.cancel();XCTAssertTrue(FileManager.default.fileExists(atPath:try XCTUnwrap(owned).path))
        continuation?.resume();do {_ = try await task.value;XCTFail("Cancelled text admitted")}catch is CancellationError {}catch {XCTFail("Unexpected error \(error)")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(owned).path));XCTAssertEqual(try store.stats().count,0)
    }
    func testSilenceInvalidAndOversizeNeverReachRecognizer()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-dictation-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        for samples in [Array(repeating:Float(0),count:16000),Array(repeating:Float(0.1),count:1599),Array(repeating:Float(0.1),count:480001),[Float.nan]] {
            do {_ = try await LocalDictation.transcribe(samples:samples,store:store) {_,_ in XCTFail("Invalid PCM reached recognizer");throw CancellationError()};XCTFail("Invalid PCM accepted")}catch {}
        }
    }
}

/// Explicit local-model gate; no microphones, downloads, network or user corpus.
@MainActor final class OwnedDictationASRTests:XCTestCase {
    func testOwnedPublicSpeechThroughProductionDictation()async throws {
        let env=ProcessInfo.processInfo.environment
        guard let model=env["OSWIND_TEST_DICTATION_ASR_MODEL"],let path=env["OSWIND_TEST_DICTATION_ASR_FIXTURE"] else {throw XCTSkip("Set an owned/public 16 kHz mono WAV and local Parakeet model to exercise dictation Core ML")}
        let file=try AVAudioFile(forReading:URL(fileURLWithPath:path))
        guard file.length>=1600,file.length<=480000,file.processingFormat.sampleRate==16000,file.processingFormat.channelCount==1,let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)) else {throw OSwindError.invalid("Owned speech fixture must be 0.1–30 seconds of 16 kHz mono audio")}
        try file.read(into:buffer);let samples=Array(UnsafeBufferPointer(start:try XCTUnwrap(buffer.floatChannelData?[0]),count:Int(buffer.frameLength)))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-native-dictation-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        var settings=AppSettings();settings.speech.engine=SpeechEngine(rawValue:env["OSWIND_TEST_DICTATION_ENGINE"] ?? "parakeet") ?? .parakeet;settings.speech.modelDirectory=model
        if settings.speech.engine == .whisper {
            settings.whisperModel=model
            guard let binary=env["OSWIND_TEST_DICTATION_WHISPER_BINARY"] else {throw OSwindError.invalid("Explicit Whisper dictation test needs its local binary")};settings.whisperBinary=binary
        };settings.speech.compute=SpeechCompute(rawValue:env["OSWIND_TEST_DICTATION_COMPUTE"] ?? "neuralEngine") ?? .neuralEngine
        let recognizer=SpeechRecognizer();try await recognizer.prepare(settings:settings)
        let first=try await LocalDictation.transcribe(samples:samples,store:store,settings:settings,recognizer:recognizer)
        let second=try await LocalDictation.transcribe(samples:samples,store:store,settings:settings,recognizer:recognizer)
        XCTAssertTrue(first.text.lowercased().contains("country"));XCTAssertEqual(first.text,second.text);XCTAssertFalse(first.segments.isEmpty);XCTAssertEqual(try store.stats().count,0)
        let stage=root.appendingPathComponent("audio/.staging")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:stage.path).isEmpty)
        try await recognizer.unload()
    }
}
