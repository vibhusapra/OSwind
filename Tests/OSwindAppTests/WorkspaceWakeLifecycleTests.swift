import XCTest
import AppKit
@testable import OSwindCore
@testable import OSwind

@MainActor final class WorkspaceWakeLifecycleTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-wake-"+UUID().uuidString)
        app=try AppModel(root:root,startServices:false);app.showOnboarding=false
        try app.store.insert(Memory(id:"owned-wake-source",kind:.note,title:"Owned wake fixture",text:"Mira Chen owns the Atlas retrieval benchmark."))
        app.settings.routinesEnabled=true;app.settings.entityAutomaticIndex=true
        app.settings.search.visual.enabled=true;app.settings.search.visual.automaticIndex=true;app.settings.search.indexOnLowPower=true
    }
    override func tearDownWithError()throws {app.prepareForLibrarySwitch();try app.store.close();app=nil;try? FileManager.default.removeItem(at:root)}
    func settle()async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while app.routines.busy || app.entityMemory.indexing || app.visualIndexing {
            guard ContinuousClock.now<deadline else {XCTFail("Owned automatic jobs did not settle");return}
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    func wake(){NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.didWakeNotification,object:nil)}
    func assertNoWakeRequest(file:StaticString=#filePath,line:UInt=#line) {
        let entityStatus=app.entityMemory.status,visualGeneration=app.visualGeneration
        wake()
        XCTAssertFalse(app.routines.busy,"Wake started routine work",file:file,line:line)
        XCTAssertFalse(app.entityMemory.indexing,"Wake started entity indexing",file:file,line:line)
        XCTAssertEqual(app.entityMemory.status,entityStatus,"Wake requested a deferred entity build",file:file,line:line)
        XCTAssertEqual(app.visualGeneration,visualGeneration,"Wake requested visual catch-up",file:file,line:line)
    }
    func testQuietPreparationIgnoresWakeEvenWithSavedAutomaticPreferences()async throws {
        assertNoWakeRequest();try await settle();XCTAssertNotNil(try app.store.get("owned-wake-source"))
    }
    func testOnboardingDefersConfiguredStartupAndWake()async throws {
        app.showOnboarding=true;app.startConfiguredServices()
        XCTAssertFalse(app.routines.busy,"Configured startup ran routines during onboarding")
        XCTAssertFalse(app.entityMemory.indexing,"Configured startup indexed during onboarding")
        assertNoWakeRequest();try await settle();XCTAssertFalse(app.isCapturing)
    }
    func testSwitchPreparationRevokesLaterWakeRequests()async throws {
        app.startConfiguredServices();try await settle();app.prepareForLibrarySwitch();try await settle()
        assertNoWakeRequest();try await settle();XCTAssertNotNil(try app.store.get("owned-wake-source"))
    }
    func testDismissedOnboardingDoesNotAuthorizeQuietPreparation()async throws {
        app.showOnboarding=true;app.showOnboarding=false;assertNoWakeRequest();try await settle()
    }
    func testConfiguredActiveWorkspaceStillResumesRoutineWorkOnWake()async throws {
        app.startConfiguredServices();try await settle();wake();XCTAssertTrue(app.routines.busy);try await settle()
    }
    func testQuietWorkspaceStillAllowsExplicitEntityBuild()async throws {
        let before=app.entityMemory.status;app.entityMemory.build()
        XCTAssertTrue(app.entityMemory.indexing || app.entityMemory.status != before)
        try await settle();XCTAssertNotNil(try app.store.get("owned-wake-source"))
    }
    func testQuietPowerAndSessionCallbacksDoNotRequestVisualCatchup()async throws {
        guard !SessionState.locked,app.visualPowerAllowed else {throw XCTSkip("Visual admission requires an unlocked session and allowed thermal state; never changes device settings")}
        let generation=app.visualGeneration
        NotificationCenter.default.post(name:.NSProcessInfoPowerStateDidChange,object:nil)
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.sessionDidBecomeActiveNotification,object:nil)
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(app.visualGeneration,generation,"Power/session callbacks requested work for quiet preparation")
        try await settle()
    }
    func testQueuedPowerCallbackCannotRestartAfterSwitchPreparation()async throws {
        app.startConfiguredServices();try await settle()
        NotificationCenter.default.post(name:.NSProcessInfoPowerStateDidChange,object:nil)
        app.prepareForLibrarySwitch();let generation=app.visualGeneration
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(app.visualGeneration,generation);try await settle()
    }
    func testRequestedStartupWaitsForOnboardingAndSuspendsWhenItReopens()async throws {
        app.showOnboarding=true;app.startConfiguredServices();XCTAssertFalse(app.configuredServicesActive)
        app.showOnboarding=false;XCTAssertTrue(app.configuredServicesActive);XCTAssertTrue(app.routines.busy);try await settle()
        app.showOnboarding=true;XCTAssertFalse(app.configuredServicesActive);try await settle();assertNoWakeRequest();try await settle()
        app.showOnboarding=false;XCTAssertTrue(app.configuredServicesActive);XCTAssertTrue(app.routines.busy);try await settle()
    }
    func testSwitchRevokesStartupRequestedDuringOnboarding()async throws {
        app.showOnboarding=true;app.startConfiguredServices();app.prepareForLibrarySwitch();app.showOnboarding=false
        XCTAssertFalse(app.configuredServicesActive);XCTAssertFalse(app.housekeepingActive);assertNoWakeRequest();try await settle()
    }
    func testPendingCleanupCannotArmAutomaticWorkAndRequiresExplicitRetry()async throws {
        app.libraryWipe.pendingCleanup=true;app.startConfiguredServices();XCTAssertFalse(app.configuredServicesActive);assertNoWakeRequest()
        app.libraryWipe.pendingCleanup=false;assertNoWakeRequest();XCTAssertFalse(app.configuredServicesActive)
        app.startConfiguredServices();XCTAssertTrue(app.configuredServicesActive);try await settle()
    }
    func testConfiguredAPIPreferenceDoesNotCreateCredentialDuringOnboarding()async throws {
        app.settings.apiEnabled=true;app.showOnboarding=true;app.startConfiguredServices()
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(app.apiStatus,"API off");XCTAssertTrue(app.settings.apiEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("api-token").path));assertNoWakeRequest();try await settle()
    }
    func testExplicitAPIWhileQuietCanStopWithoutLateStatusPublication()async throws {
        app.startAPI();XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("api-token").path))
        app.stopAPI();try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(app.apiStatus,"API off");XCTAssertFalse(app.settings.apiEnabled);XCTAssertFalse(app.configuredServicesActive)
    }
    func testQuietWorkspaceStillAllowsExplicitVisualBuildRequest()async throws {
        let generation=app.visualGeneration,status=app.visualIndexStatus
        app.rebuildVisualIndex()
        XCTAssertTrue(app.visualGeneration != generation || app.visualIndexStatus != status)
        try await settle();XCTAssertNotNil(try app.store.get("owned-wake-source"))
    }
    func testExplicitScheduleResumeWhileQuietDoesNotActivateOtherServices()async throws {
        app.settings.apiEnabled=true;let status=app.entityMemory.status,generation=app.visualGeneration
        app.configureRoutineScheduling(true);XCTAssertTrue(app.routines.schedulingActive);XCTAssertFalse(app.configuredServicesActive);try await settle()
        wake();XCTAssertTrue(app.routines.busy);try await settle()
        XCTAssertEqual(app.entityMemory.status,status);XCTAssertEqual(app.visualGeneration,generation)
        XCTAssertEqual(app.apiStatus,"API off");XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("api-token").path));XCTAssertFalse(app.isCapturing)
        app.configureRoutineScheduling(false);XCTAssertFalse(app.routines.schedulingActive);assertNoWakeRequest();try await settle()
    }
    func testExplicitScheduleControlCannotStartDuringOnboarding()async throws {
        app.showOnboarding=true;app.configureRoutineScheduling(true)
        XCTAssertTrue(app.settings.routinesEnabled);XCTAssertFalse(app.routines.schedulingActive);XCTAssertFalse(app.routines.busy)
        app.showOnboarding=false;XCTAssertFalse(app.routines.schedulingActive)
        app.configureRoutineScheduling(true);XCTAssertTrue(app.routines.schedulingActive);try await settle()
    }
    func testDisabledSchedulesDoNotCreatePollingTimerOnConfiguredStartup()async throws {
        app.settings.routinesEnabled=false;app.startConfiguredServices();XCTAssertTrue(app.configuredServicesActive);XCTAssertFalse(app.routines.schedulingActive);try await settle()
    }
}
