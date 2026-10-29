import XCTest
import OSwindCore
@testable import OSwind

@MainActor final class AccessibilityCaptureSetupTests:XCTestCase {
    func testSavedTextModeLoadsQuietlyAndSettingsBindingPersistsExplicitModeChanges() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-ax-setup-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var settings=AppSettings();settings.visualCaptureMode = .accessibility;settings.captureOnLaunch=true;settings.automaticMaintenance=false
        try settings.save(root:root)
        let model=try AppModel(root:root,startServices:false)
        defer {model.prepareForLibrarySwitch();try? model.store.close()}
        XCTAssertEqual(model.settings.visualCaptureMode,.accessibility);XCTAssertEqual(model.capture.settings.visualCaptureMode,.accessibility)
        XCTAssertFalse(model.capture.running);XCTAssertEqual(try model.store.stats().count,0)
        model.settings.visualCaptureMode = .snapshots
        XCTAssertEqual(AppSettings.load(root:root).visualCaptureMode,.snapshots);XCTAssertEqual(model.capture.settings.visualCaptureMode,.snapshots)
        model.settings.visualCaptureMode = .accessibility
        XCTAssertEqual(AppSettings.load(root:root).visualCaptureMode,.accessibility);XCTAssertFalse(model.capture.running)
    }
    func testFailedSettingsSaveSurfacesErrorAndLeavesExplicitModeInMemoryWithoutStartingCapture() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-ax-setup-save-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var settings=AppSettings();settings.automaticMaintenance=false;try settings.save(root:root)
        let model=try AppModel(root:root,startServices:false)
        defer {model.prepareForLibrarySwitch();try? model.store.close()}
        let file=root.appendingPathComponent("settings.json"),owned=root.appendingPathComponent("owned-policy-copy.json"),original=try Data(contentsOf:file)
        try FileManager.default.moveItem(at:file,to:owned);try FileManager.default.createSymbolicLink(at:file,withDestinationURL:owned)
        model.settings.visualCaptureMode = .accessibility
        XCTAssertEqual(model.capture.settings.visualCaptureMode,.accessibility);XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf:owned),original);XCTAssertFalse(model.capture.running);XCTAssertEqual(try model.store.stats().count,0)
    }
}
