import XCTest
@testable import OSwindCore
@testable import OSwind

actor AudioImportGate {
    let entered=XCTestExpectation(description:"Owned actual import phase entered")
    let cancelled=XCTestExpectation(description:"Owned actual import observed cancellation")
    private var continuation:CheckedContinuation<Void,Never>?
    private var released=false,reportedCancellation=false
    func wait()async {
        await withTaskCancellationHandler {
            await withCheckedContinuation {continuation in
                entered.fulfill()
                if released {continuation.resume()}else {self.continuation=continuation}
            }
        } onCancel:{Task {await self.noteCancellation()}}
    }
    private func noteCancellation() {if !reportedCancellation {reportedCancellation=true;cancelled.fulfill()}}
    func open() {released=true;continuation?.resume();continuation=nil}
}
actor AuthoredImportBackend:NativeSpeechBackend {
    let gate:AudioImportGate?
    private(set) var input:URL?
    init(gate:AudioImportGate?=nil) {self.gate=gate}
    func transcribe(file:URL,language:String)async throws->SpeechTranscript {
        guard FileManager.default.fileExists(atPath:file.path),file.lastPathComponent=="speech.wav" else {throw OSwindError.invalid("Owned normalized decoder input is missing")}
        input=file;if let gate {await gate.wait()}
        return .init(text:"Authored local decoder fixture transcript.",duration:1,segments:[.init(start:0,end:1,text:"Authored local decoder fixture transcript.")],model:"owned fake inference; not a quality measurement")
    }
}
actor AuthoredSpeakerBackend:SpeakerDiarizationBackend {
    let gate:AudioImportGate?
    init(gate:AudioImportGate?=nil) {self.gate=gate}
    func turns(file:URL)async throws->[SpeakerTurn] {
        guard FileManager.default.fileExists(atPath:file.path) else {throw OSwindError.invalid("Owned speaker input is unavailable")}
        if let gate {await gate.wait()};return [.init(start:0,end:1,speaker:"owned-recording-local-id")]
    }
}

@MainActor final class AudioImportLifecycleTests:XCTestCase {
    var root:URL!,file:URL!,app:AppModel!,gates=[AudioImportGate]()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-audio-import-lifecycle-"+UUID().uuidString);try Paths.ensure(root)
        file=root.appendingPathComponent("authored.wav");try WAV.data(samples:Array(repeating:0.05,count:16000)).write(to:file)
        app=try AppModel(root:root.appendingPathComponent("library"),startServices:false)
        app.settings.captureOnLaunch=false;app.settings.apiEnabled=false;app.settings.automaticMaintenance=false;app.settings.routinesEnabled=false;app.settings.entityAutomaticIndex=false
        app.settings.speech.engine = .parakeet;app.settings.speech.modelDirectory="/synthetic/authored-decoder";app.settings.diarization.enabled=false;app.settings.retainAudio=true
    }
    override func tearDown()async throws {
        for gate in gates {await gate.open()}
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait()
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while app.importingAudio,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        guard !app.importingAudio else {XCTFail("Actual import still owns fixture; preserved without closing its store");return}
        try app.store.close();app=nil;try? FileManager.default.removeItem(at:root)
    }
    func ready()async throws {try await SourceWorkTestJob.settle(app)}
    func finishImport()async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while app.importingAudio,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.importingAudio)
    }
    func testActualDecoderAndClipRemainOwnedUntilRetiredDrainCompletes()async throws {
        try await ready();let gate=AudioImportGate();gates.append(gate)
        let backend=AuthoredImportBackend(gate:gate),recognizer=SpeechRecognizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer);await fulfillment(of:[gate.entered],timeout:5)
        let input=await backend.input;XCTAssertNotNil(input);XCTAssertNotEqual(input,file)
        XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:app.store.root,exclusive:true,timeout:0))
        XCTAssertTrue(app.hasPendingExitWork,"Actual file import must participate in plain Quit ownership")
        let status=app.audioImportStatus;app.prepareForLibrarySwitch();var finished=false
        let drain=Task {await self.app.cancelExternalWorkAndWait();finished=true}
        await fulfillment(of:[gate.cancelled],timeout:5);try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(finished,"Drain must wait for actual noncooperating inference and clip cleanup")
        await gate.open();await drain.value;try await finishImport()
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0);XCTAssertEqual(app.audioImportStatus,status,"Retired import must not publish a late completion")
        let lease=try MediaAdmissionLease.acquire(root:app.store.root,exclusive:true,timeout:0);lease.release()
        if let input {XCTAssertFalse(FileManager.default.fileExists(atPath:input.path))}
    }
    func testRetiredDrainOwnsActualCommittedImportAndSuppressesLateStatus()async throws {
        try await ready();let gate=AudioImportGate();gates.append(gate)
        let backend=AuthoredImportBackend(),recognizer=SpeechRecognizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer,observeCompletion:{await gate.wait()})
        await fulfillment(of:[gate.entered],timeout:5);XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1)
        XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:app.store.root,exclusive:true,timeout:0))
        XCTAssertTrue(app.hasPendingExitWork);let status=app.audioImportStatus
        app.prepareForLibrarySwitch();var finished=false
        let drain=Task {await self.app.cancelExternalWorkAndWait();finished=true}
        await fulfillment(of:[gate.cancelled],timeout:5);try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(finished)
        await gate.open();await drain.value;try await finishImport()
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1,"Cancellation does not undo the actual committed transcript")
        XCTAssertEqual(app.audioImportStatus,status,"Retired committed completion must not republish status")
    }
    func testActualAudioAdmissionRunsOffMainThreadAndPreservesRetainedInput()async throws {
        try await ready();let backend=AuthoredImportBackend(),recognizer=SpeechRecognizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer,observeAdmission:{XCTAssertFalse(Thread.isMainThread,"Blocking admission, embedding and retained-file IO must run off the UI thread")})
        try await finishImport();XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1)
        let memories=try app.store.search(SearchFilter(query:"",limit:10));let memory=try XCTUnwrap(memories.first?.memory)
        let retained=try XCTUnwrap(memory.audioPath);XCTAssertEqual(try Data(contentsOf:app.store.root.appendingPathComponent(retained)),try Data(contentsOf:file))
    }
    func testCancelledDrainCallerStillWaitsBeforeClipAdmissionAndRejectsAnotherImport()async throws {
        try await ready();let gate=AudioImportGate();gates.append(gate)
        let backend=AuthoredImportBackend(),recognizer=SpeechRecognizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer,observePhase:{if $0 == .started {await gate.wait()}})
        await fulfillment(of:[gate.entered],timeout:5);XCTAssertTrue(app.hasPendingExitWork)
        var finished=false;let drain=Task {await self.app.cancelExternalWorkAndWait();finished=true};drain.cancel()
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(finished);XCTAssertTrue(app.importingAudio)
        app.importAudioFile(file,recognizer:recognizer,observePhase:{_ in XCTFail("Admitted an import while its drain was held")})
        await gate.open();await drain.value;try await finishImport();XCTAssertTrue(finished)
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0);XCTAssertFalse(app.hasPendingExitWork)
        app.importAudioFile(file,recognizer:recognizer);try await finishImport();XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1)
    }
    func testExplicitCancelKeepsBusyUntilActualInferenceReturns()async throws {
        try await ready();let gate=AudioImportGate();gates.append(gate)
        let backend=AuthoredImportBackend(gate:gate),recognizer=SpeechRecognizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer);await fulfillment(of:[gate.entered],timeout:5)
        app.cancelAudioImport();await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertTrue(app.importingAudio);XCTAssertTrue(app.hasPendingExitWork)
        await gate.open();try await finishImport();XCTAssertEqual(app.audioImportStatus,"Import cancelled");XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
    }
    func testPrivacyChangeCancelsActualDecoderEvenWhenSettingsSaveFails()async throws {
        try await ready();let gate=AudioImportGate();gates.append(gate)
        let backend=AuthoredImportBackend(gate:gate),recognizer=SpeechRecognizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer);await fulfillment(of:[gate.entered],timeout:5)
        let lock=app.store.root.appendingPathComponent(".settings-admission.lock"),marker=root.appendingPathComponent("unchanged-marker")
        try Data([7]).write(to:marker);try FileManager.default.removeItem(at:lock);try FileManager.default.createSymbolicLink(at:lock,withDestinationURL:marker)
        app.settings.privacy.redactSecrets.toggle();await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertNotNil(app.errorMessage)
        await gate.open();await app.cancelExternalWorkAndWait();try await finishImport()
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0);XCTAssertEqual(try Data(contentsOf:marker),Data([7]))
    }
    func testRetainChoiceRevokesOldImportAndNextImportRespectsNoRetention()async throws {
        try await ready();let gate=AudioImportGate();gates.append(gate)
        let backend=AuthoredImportBackend(),recognizer=SpeechRecognizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer,observePhase:{if $0 == .beforeAdmission {await gate.wait()}})
        await fulfillment(of:[gate.entered],timeout:5);app.settings.retainAudio=false
        await fulfillment(of:[gate.cancelled],timeout:5);await gate.open();try await finishImport()
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
        app.importAudioFile(file,recognizer:recognizer);try await finishImport()
        let source=try XCTUnwrap(app.store.search(SearchFilter(query:"",limit:10)).first?.memory)
        XCTAssertNil(source.audioPath);XCTAssertNotNil(source.transcript);XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1)
    }
    func testIndependentAnswerModelChoiceDoesNotCancelAcceptedAudio()async throws {
        try await ready();let gate=AudioImportGate();gates.append(gate)
        let backend=AuthoredImportBackend(gate:gate),recognizer=SpeechRecognizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer);await fulfillment(of:[gate.entered],timeout:5)
        app.settings.ai.model="owned-other-answer-model";await gate.open();try await finishImport()
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1);XCTAssertTrue(app.audioImportStatus.hasPrefix("Transcript saved ·"))
    }
    func testCurrentCancellationReportsActualCommittedTranscript()async throws {
        try await ready();let gate=AudioImportGate();gates.append(gate)
        let backend=AuthoredImportBackend(),recognizer=SpeechRecognizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer,observeCompletion:{await gate.wait()})
        await fulfillment(of:[gate.entered],timeout:5);XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1)
        app.cancelAudioImport();await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertTrue(app.importingAudio)
        await gate.open();await app.cancelExternalWorkAndWait();try await finishImport()
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1);XCTAssertTrue(app.audioImportStatus.contains("saved before cancellation"));XCTAssertFalse(app.hasPendingExitWork)
    }
    func testRetiredFileEntryCannotLaunchDecoder()async throws {
        try await ready();app.prepareForLibrarySwitch()
        let recognizer=SpeechRecognizer(loader:{_ in XCTFail("Retired import loaded a backend");return AuthoredImportBackend()})
        app.importAudioFile(file,recognizer:recognizer);XCTAssertFalse(app.importingAudio);XCTAssertFalse(app.libraryWork.busy)
    }
    func testClosedFileEntryCannotLaunchDecoder()async throws {
        try await ready();try app.store.close()
        let recognizer=SpeechRecognizer(loader:{_ in XCTFail("Closed import loaded a backend");return AuthoredImportBackend()})
        app.importAudioFile(file,recognizer:recognizer);XCTAssertFalse(app.importingAudio);XCTAssertFalse(app.libraryWork.busy)
    }
    func testWipeWaitsForActualDecoderAndClipCleanup()async throws {
        try await ready();let gate=AudioImportGate();gates.append(gate)
        let backend=AuthoredImportBackend(gate:gate),recognizer=SpeechRecognizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer);await fulfillment(of:[gate.entered],timeout:5)
        let input=await backend.input;app.wipeLocalLibrary();await fulfillment(of:[gate.cancelled],timeout:5)
        XCTAssertTrue(app.libraryWipe.busy);XCTAssertNil(app.libraryWipe.result)
        await gate.open();let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while app.libraryWipe.busy,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.libraryWipe.busy);try await SourceWorkTestJob.settle(app)
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0);XCTAssertFalse(app.hasPendingExitWork)
        let original=WAV.data(samples:Array(repeating:Float(0.05),count:16000))
        XCTAssertEqual(try Data(contentsOf:file),original)
        if let input {XCTAssertFalse(FileManager.default.fileExists(atPath:input.path))}
    }
    func speakerModels()throws {
        guard SpeakerDiarizer.supported else {throw XCTSkip("Speaker pipeline requires supported macOS; fixture never changes system state")}
        let folder=root.appendingPathComponent("authored-speaker-structure");try Paths.ensure(folder)
        for name in ["Segmentation.mlmodelc","FBank.mlmodelc","Embedding.mlmodelc","PldaRho.mlmodelc"] {try Paths.ensure(folder.appendingPathComponent(name))}
        try Data("{}".utf8).write(to:folder.appendingPathComponent("plda-parameters.json"));app.settings.diarization.modelDirectory=folder.path;app.settings.diarization.enabled=true
    }
    func testActualSpeakerWrapperAndClipAreJoinedThroughCancellation()async throws {
        try await ready();try speakerModels();let gate=AudioImportGate();gates.append(gate)
        let asr=AuthoredImportBackend(),recognizer=SpeechRecognizer(loader:{_ in asr}),backend=AuthoredSpeakerBackend(gate:gate),speakers=SpeakerDiarizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer,speakers:speakers);await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:app.store.root,exclusive:true,timeout:0))
        app.prepareForLibrarySwitch();var finished=false;let drain=Task {await self.app.cancelExternalWorkAndWait();finished=true}
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(finished)
        await gate.open();await drain.value;try await finishImport();XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
        let lease=try MediaAdmissionLease.acquire(root:app.store.root,exclusive:true,timeout:0);lease.release()
    }
    func testSpeakerPipelinePersistsRecordingLocalLabelsFromAuthoredBackend()async throws {
        try await ready();try speakerModels();let asr=AuthoredImportBackend(),recognizer=SpeechRecognizer(loader:{_ in asr}),backend=AuthoredSpeakerBackend(),speakers=SpeakerDiarizer(loader:{_ in backend})
        app.importAudioFile(file,recognizer:recognizer,speakers:speakers);try await finishImport()
        let source=try XCTUnwrap(app.store.search(SearchFilter(query:"",limit:10)).first?.memory)
        XCTAssertEqual(source.transcript?.segments.first?.speaker,"Speaker 1");XCTAssertEqual(source.transcript?.diarization?.detectedSpeakers,1);XCTAssertNotNil(source.audioSessionID)
    }
}
