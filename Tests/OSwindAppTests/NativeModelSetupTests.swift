import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class NativeModelSetupTests:XCTestCase {
    actor Gate {
        let entered=XCTestExpectation(description:"model installer suspended");var continuation:CheckedContinuation<Void,Never>?
        func wait() async {await withCheckedContinuation{continuation=$0;entered.fulfill()}}
        func open(){continuation?.resume();continuation=nil}
    }
    actor Count {var value=0;func add(){value += 1}}
    var root:URL!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try Paths.ensure(root)}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    func result(_ kind:NativeModelKind) throws -> NativeModelInstallation {
        let catalog=try kind.catalog();return NativeModelInstallation(kind:kind,directory:root.appendingPathComponent(kind.rawValue),revision:catalog.revision,files:catalog.files.count,bytes:catalog.bytes,reused:false)
    }
    func idle(_ model:NativeModelSetupModel) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while model.busy && ContinuousClock.now<deadline {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertFalse(model.busy)
    }
    func testSuccessAndFailureHaveConcreteTerminalStates() async throws {
        let expected=try result(.parakeet),setup=NativeModelSetupModel(installer:{_,_,_,progress in progress(NativeModelProgress(phase:"Downloading",completedBytes:1,totalBytes:2,completedFiles:0,totalFiles:1));return expected})
        var applied=false;setup.start(.parakeet){_ in applied=true};try await idle(setup)
        XCTAssertTrue(applied);XCTAssertEqual(setup.installed[.parakeet],expected);XCTAssertNil(setup.errors[.parakeet]);XCTAssertNil(setup.progress)
        let failed=NativeModelSetupModel(installer:{_,_,_,_ in throw OSwindError.network("Synthetic offline failure")})
        failed.start(.speakers){_ in XCTFail("Failed installation applied")};try await idle(failed)
        XCTAssertTrue(failed.errors[.speakers]?.contains("offline")==true);XCTAssertNil(failed.installed[.speakers])
    }
    func testCancelCannotApplyLateSuccessfulInstallerAndDoesNotStartAnotherUntilFinished() async throws {
        let gate=Gate(),count=Count(),expected=try result(.parakeet)
        let setup=NativeModelSetupModel(installer:{_,_,_,_ in await count.add();await gate.wait();return expected})
        setup.start(.parakeet){_ in XCTFail("Cancelled completion applied")};await fulfillment(of:[gate.entered],timeout:5)
        setup.cancel();XCTAssertTrue(setup.cancelling);setup.start(.parakeet){_ in XCTFail("Concurrent setup started")}
        await gate.open();try await idle(setup)
        let calls=await count.value;XCTAssertEqual(calls,1);XCTAssertNil(setup.installed[.parakeet]);XCTAssertTrue(setup.status[.parakeet]?.contains("Cancelled")==true)
    }
    func testUnexpectedModelCannotBeSelected() async throws {
        let expected=try result(.speakers),setup=NativeModelSetupModel(installer:{_,_,_,_ in expected})
        setup.start(.parakeet){_ in XCTFail("Unexpected model selected")};try await idle(setup)
        XCTAssertNil(setup.installed[.parakeet]);XCTAssertTrue(setup.errors[.parakeet]?.contains("unexpected")==true)
    }
    func testAppAppliesReadyModelWithoutStartingCaptureOrLosingPrivacyEdits() async throws {
        let gate=Gate(),expected=try result(.parakeet),setup=NativeModelSetupModel(installer:{_,_,_,_ in await gate.wait();return expected})
        let app=try AppModel(root:root.appendingPathComponent("library"),startServices:false,nativeModelSetup:setup);defer{app.prepareForLibrarySwitch()}
        app.installNativeModel(.parakeet);await fulfillment(of:[gate.entered],timeout:5)
        app.settings.privacy.retentionDays=7;await gate.open();try await idle(setup)
        XCTAssertEqual(app.settings.speech.engine,.parakeet);XCTAssertEqual(app.settings.speech.modelDirectory,expected.directory.path);XCTAssertEqual(app.settings.privacy.retentionDays,7)
        XCTAssertFalse(app.audio.running);XCTAssertFalse(app.capture.running)
        XCTAssertEqual(AppSettings.load(root:app.store.root).speech,app.settings.speech)
    }
    func testAppManualModelEditDuringDownloadIsPreserved() async throws {
        let gate=Gate(),expected=try result(.parakeet),setup=NativeModelSetupModel(installer:{_,_,_,_ in await gate.wait();return expected})
        let app=try AppModel(root:root.appendingPathComponent("library"),startServices:false,nativeModelSetup:setup);defer{app.prepareForLibrarySwitch()}
        app.installNativeModel(.parakeet);await fulfillment(of:[gate.entered],timeout:5)
        app.settings.speech.modelDirectory="/manually-chosen/model";app.settings.speech.compute = .gpu
        await gate.open();try await idle(setup)
        XCTAssertEqual(app.settings.speech.modelDirectory,"/manually-chosen/model");XCTAssertEqual(app.settings.speech.engine,.whisper);XCTAssertEqual(app.settings.speech.compute,.gpu)
        XCTAssertEqual(setup.installed[.parakeet],expected)
        app.useNativeModel(expected);XCTAssertEqual(app.settings.speech.compute,.gpu);XCTAssertEqual(app.settings.speech.modelDirectory,expected.directory.path)
    }
    func testImportInProgressDefersModelApplication() async throws {
        let expected=try result(.parakeet),setup=NativeModelSetupModel(installer:{_,_,_,_ in expected})
        let app=try AppModel(root:root.appendingPathComponent("library"),startServices:false,nativeModelSetup:setup);defer{app.importingAudio=false;app.prepareForLibrarySwitch()}
        app.importingAudio=true;app.installNativeModel(.parakeet);try await idle(setup)
        XCTAssertEqual(app.settings.speech.engine,.whisper);XCTAssertEqual(setup.installed[.parakeet],expected)
        app.importingAudio=false;app.useNativeModel(expected);XCTAssertEqual(app.settings.speech.engine,.parakeet)
    }
    func testLibrarySwitchCancelsAndCannotApplyLateResults() async throws {
        let gate=Gate(),expected=try result(.parakeet),setup=NativeModelSetupModel(installer:{_,_,_,_ in await gate.wait();return expected})
        let app=try AppModel(root:root.appendingPathComponent("library"),startServices:false,nativeModelSetup:setup)
        app.installNativeModel(.parakeet);await fulfillment(of:[gate.entered],timeout:5)
        app.prepareForLibrarySwitch();await gate.open();try await idle(setup)
        XCTAssertEqual(app.settings.speech.engine,.whisper);XCTAssertNil(setup.installed[.parakeet])
    }
    func testRealVerifiedNativeModelsApplyWhenExplicitCacheIsConfigured() async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_MODEL_CACHE"] else {throw XCTSkip("Set the native model cache explicitly; no downloads")}
        let app=try AppModel(root:root.appendingPathComponent("library"),startServices:false);defer{app.prepareForLibrarySwitch()}
        for kind in NativeModelKind.allCases where kind != .speakers || SpeakerDiarizer.supported {
            app.installNativeModel(kind,cache:URL(fileURLWithPath:path),verifyOnly:true);try await idle(app.nativeModels)
            XCTAssertNil(app.nativeModels.errors[kind]);XCTAssertNotNil(app.nativeModels.installed[kind])
        }
        XCTAssertEqual(app.settings.speech.engine,.parakeet);XCTAssertFalse(app.audio.running);XCTAssertFalse(app.capture.running)
        if SpeakerDiarizer.supported {XCTAssertTrue(app.settings.diarization.enabled)}
    }

}
