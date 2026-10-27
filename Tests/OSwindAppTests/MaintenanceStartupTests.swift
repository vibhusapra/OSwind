import XCTest
import OSwindCore
@testable import OSwind

@MainActor final class MaintenanceStartupTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-maintenance-startup-"+UUID().uuidString)
        app=try AppModel(root:root,startServices:false)
        app.settings.privacy.retentionDays=1;app.settings.automaticMaintenance=true
        try app.store.insert(Memory(id:"owned-old-source",timestamp:Date().addingTimeInterval(-60*86400),kind:.note,title:"Owned historical import",text:"Owned synthetic historical source. Keep until automatic maintenance is explicitly active."))
    }
    override func tearDownWithError()throws {app.prepareForLibrarySwitch();try app.store.close();app=nil;try? FileManager.default.removeItem(at:root)}
    func waitForMaintenance()async throws {for _ in 0..<2000 where app.maintenanceBusy {try await Task.sleep(for:.milliseconds(5))};XCTAssertFalse(app.maintenanceBusy)}
    func testQuietPreparationDoesNotApplyAutomaticRetention()async throws {
        app.showOnboarding=false;app.maintain(automatic:true);try await waitForMaintenance()
        XCTAssertNotNil(try app.store.get("owned-old-source"));XCTAssertEqual(try app.store.stats().count,1)
    }
    func testOnboardingBlocksAutomaticRetentionEvenAfterStartupRequested()async throws {
        app.showOnboarding=true;app.startConfiguredServices();app.maintain(automatic:true);try await waitForMaintenance()
        XCTAssertNotNil(try app.store.get("owned-old-source"))
    }
    func testQueuedAutomaticCallbackAfterLibrarySwitchCannotPruneOldStore()async throws {
        app.showOnboarding=false;app.startConfiguredServices();app.prepareForLibrarySwitch();app.maintain(automatic:true);try await waitForMaintenance()
        XCTAssertNotNil(try app.store.get("owned-old-source"))
    }
    func testConfiguredActiveLibraryStillAppliesItsRetentionPolicy()async throws {
        app.showOnboarding=false;app.startConfiguredServices();app.maintain(automatic:true);try await waitForMaintenance()
        XCTAssertNil(try app.store.get("owned-old-source"));XCTAssertTrue(app.maintenanceStatus.contains("Removed 1 source"))
    }
    func testExplicitManualCleanupRemainsAvailableDuringQuietPreparation()async throws {
        app.showOnboarding=true;app.maintain();try await waitForMaintenance()
        XCTAssertNil(try app.store.get("owned-old-source"));XCTAssertTrue(app.maintenanceStatus.contains("Removed 1 source"))
    }
    func testRequestedMaintenanceWaitsForOnboardingAndSuspendsWhenItReopens()async throws {
        app.showOnboarding=true;app.startConfiguredServices();XCTAssertFalse(app.housekeepingActive)
        app.showOnboarding=false;XCTAssertTrue(app.housekeepingActive)
        app.showOnboarding=true;XCTAssertFalse(app.housekeepingActive)
        app.maintain(automatic:true);try await waitForMaintenance();XCTAssertNotNil(try app.store.get("owned-old-source"))
        app.showOnboarding=false;XCTAssertTrue(app.housekeepingActive)
        app.maintain(automatic:true);try await waitForMaintenance();XCTAssertNil(try app.store.get("owned-old-source"))
    }
    func testExplicitCleanupResumeDoesNotStartConfiguredAPIOrCapture()async throws {
        app.showOnboarding=false;app.settings.apiEnabled=true
        XCTAssertFalse(app.housekeepingActive);XCTAssertEqual(app.apiStatus,"API off")
        app.configureAutomaticMaintenance(true)
        XCTAssertTrue(app.housekeepingActive);XCTAssertTrue(app.settings.apiEnabled);XCTAssertEqual(app.apiStatus,"API off");XCTAssertFalse(app.isCapturing)
        app.maintain(automatic:true);try await waitForMaintenance();XCTAssertNil(try app.store.get("owned-old-source"))
    }
    func testDisabledRetentionOnAnActiveSchedulerKeepsHistoricalSources()async throws {
        app.showOnboarding=false;app.startConfiguredServices();app.configureAutomaticMaintenance(false)
        XCTAssertTrue(app.housekeepingActive);app.maintain(automatic:true);try await waitForMaintenance()
        XCTAssertNotNil(try app.store.get("owned-old-source"));XCTAssertEqual(app.maintenanceStatus,"Automatic retention is off.")
    }
}
