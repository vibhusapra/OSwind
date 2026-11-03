import XCTest
import AppKit
@testable import OSwindCore

@MainActor final class CaptureStartReadinessTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-start-owned-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try? store.close();try? FileManager.default.removeItem(at:root)}
    private func environment()->SnapshotCaptureEnvironment {
        var e=SnapshotCaptureEnvironment();e.locked={false};e.permitted={true};e.accessibilityPermitted={true};e.idleSeconds={121}
        e.context={_ in XCTFail("Invalid or idle start read an app context");return nil}
        e.frames={_,_ in XCTFail("Invalid start discovered pixel sources");return []};return e
    }
    func testBlockedStartNeverClaimsRunningOrChecksPermissionsAcrossModes()async throws {
        for mode in VisualCaptureMode.allCases {
            var settings=AppSettings();settings.visualCaptureMode=mode;settings.snapshotRegions = .disabled
            var e=environment();e.permitted={XCTFail("Invalid scope checked screen access");return false};e.accessibilityPermitted={XCTFail("Invalid scope checked AX access");return false}
            let c=CaptureController(store:store,embedder:LocalEmbedder(),settings:settings,snapshots:e)
            c.start();XCTAssertFalse(c.running);XCTAssertTrue(c.status.contains("Invalid capture area"));await c.cancelAndWait();XCTAssertEqual(c.metrics.saved,0)
        }
        XCTAssertEqual(try store.stats().count,0)
    }
    func testEmptyDisplaySelectionRefusesStartForPixelModes()async throws {
        for mode in [VisualCaptureMode.snapshots,.replay] {
            var settings=AppSettings();settings.visualCaptureMode=mode;settings.allDisplays=true;settings.snapshotRegions.selectedDisplays=[]
            let c=CaptureController(store:store,embedder:LocalEmbedder(),settings:settings,snapshots:environment())
            c.start();XCTAssertFalse(c.running);XCTAssertTrue(c.status.contains("No displays selected"));await c.cancelAndWait()
        }
    }
    func testTextOnlyDisplayAndCropScopeRefuseStart()async throws {
        for display in [true,false] {
            var settings=AppSettings();settings.visualCaptureMode = .accessibility
            if display {settings.allDisplays=true}else {settings.snapshotRegions.focusedWindowCrop=SnapshotRegion(x:0.5,width:0.5)}
            let c=CaptureController(store:store,embedder:LocalEmbedder(),settings:settings,snapshots:environment())
            c.start();XCTAssertFalse(c.running);XCTAssertTrue(c.status.contains(display ? "focused-window":"cannot apply a screen crop"));await c.cancelAndWait()
        }
    }
    func testValidScopeStillRequiresOnlyItsOwnPermission()async throws {
        for mode in VisualCaptureMode.allCases {
            var settings=AppSettings();settings.visualCaptureMode=mode;var e=environment()
            if mode == .accessibility {e.accessibilityPermitted={false};e.permitted={XCTFail("Text-only start checked pixel access");return true}}
            else {e.permitted={false};e.accessibilityPermitted={XCTFail("Pixel start checked AX access");return true}}
            let c=CaptureController(store:store,embedder:LocalEmbedder(),settings:settings,snapshots:e)
            c.start();XCTAssertFalse(c.running);XCTAssertTrue(c.status.contains("permission required"));await c.cancelAndWait()
        }
    }
    func testInvalidSettingsStopActiveControllerAndRepairRequiresExplicitResume()async throws {
        var settings=AppSettings();settings.profile = .light
        let c=CaptureController(store:store,embedder:LocalEmbedder(),settings:settings,snapshots:environment())
        c.start();XCTAssertTrue(c.running);await Task.yield()
        c.settings.snapshotRegions = .disabled;XCTAssertFalse(c.running);XCTAssertTrue(c.status.contains("Invalid capture area"))
        c.settings.snapshotRegions=SnapshotRegionSettings();await Task.yield();XCTAssertFalse(c.running);XCTAssertEqual(c.status,"Paused")
        c.start();XCTAssertTrue(c.running);await Task.yield();await c.cancelAndWait();XCTAssertFalse(c.running);XCTAssertEqual(c.metrics.saved,0);XCTAssertEqual(try store.stats().count,0)
    }
    func testInvalidationCancelsInFlightContextAndRejectsLateEvidence()async throws {
        let entered=XCTestExpectation(description:"Owned context started");var resume:CheckedContinuation<WindowContext?,Never>?
        var e=environment();e.idleSeconds={0};e.context={_ in await withCheckedContinuation {resume=$0;entered.fulfill()}}
        let c=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:e)
        c.start();await fulfillment(of:[entered],timeout:5);XCTAssertTrue(c.running)
        c.settings.snapshotRegions = .disabled;XCTAssertFalse(c.running);XCTAssertTrue(c.status.contains("Invalid capture area"))
        resume?.resume(returning:WindowContext(app:"Owned",bundle:"org.oswind.fixture",pid:8123,title:"Owned",url:nil,accessibilityText:"late text",secure:false))
        // Join the actual cancelled context worker before closing the store.
        await c.cancelAndWait();XCTAssertEqual(c.metrics.saved,0);XCTAssertEqual(try store.stats().count,0)
    }
}
