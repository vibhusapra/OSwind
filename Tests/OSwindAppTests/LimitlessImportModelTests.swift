import XCTest
import OSwindCore
@testable import OSwind

@MainActor final class LimitlessImportModelTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-limitless-app-"+UUID().uuidString);app=try AppModel(root:root,startServices:false)}
    override func tearDownWithError()throws {app.prepareForLibrarySwitch();app=nil;try? FileManager.default.removeItem(at:root)}
    func fixture()throws->URL {
        let data=Data(#"{"data":{"lifelogs":[{"id":"owned-app-note","title":"Private browsing fixture","markdown":"Excluded authored note","startTime":"2026-10-27T12:00:00Z","endTime":"2026-10-27T12:01:00Z"},{"id":"owned-admitted","title":"Owned note","markdown":"Maya owns Aurora","startTime":"2026-10-27T12:00:00Z","endTime":"2026-10-27T12:01:00Z"}]},"meta":{"lifelogs":{"count":2,"nextCursor":"next-owned-page"}}}"#.utf8)
        let file=root.appendingPathComponent("api.json");try data.write(to:file);return file
    }
    func waitForImport()async throws {for _ in 0..<2000 where app.importingJSON {try await Task.sleep(for:.milliseconds(5))};XCTAssertFalse(app.importingJSON)}
    func testModelWorkerReportsExclusionsAndIncompletePageWithoutStartingServices()async throws {
        let file=try fixture();app.importJSONFile(file,limitlessAPI:true);XCTAssertTrue(app.importingJSON);app.importJSONFile(file,limitlessAPI:true)
        try await waitForImport();XCTAssertNil(app.errorMessage);XCTAssertTrue(app.importStatus.contains("1 Limitless text notes"));XCTAssertTrue(app.importStatus.contains("1 excluded"));XCTAssertTrue(app.importStatus.contains("another page"))
        XCTAssertEqual(try app.store.stats().count,1);XCTAssertFalse(app.isCapturing);XCTAssertFalse(app.settings.captureOnLaunch);XCTAssertFalse(app.settings.apiEnabled)
    }
    func testLibrarySwitchSuppressesLateStatusFromImport()async throws {
        app.importJSONFile(try fixture(),limitlessAPI:true);app.prepareForLibrarySwitch();try await waitForImport()
        XCTAssertFalse(app.importStatus.hasPrefix("Imported"));XCTAssertNil(app.selected)
    }
    func testUnsupportedFileReportsFailureAndLeavesLibraryEmpty()async throws {
        let file=root.appendingPathComponent("unsupported.json");try Data(#"{"data":{"archive":"unsupported"}}"#.utf8).write(to:file)
        app.importJSONFile(file,limitlessAPI:true);try await waitForImport();XCTAssertNotNil(app.errorMessage);XCTAssertTrue(app.importStatus.hasPrefix("Import did not complete:"));XCTAssertEqual(try app.store.stats().count,0)
    }
    func testMalformedSavedPolicyRefusesWithoutPublication() async throws {
        let file=try fixture(),settings=root.appendingPathComponent("settings.json")
        try Data("{malformed".utf8).write(to:settings);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:settings.path)
        app.importJSONFile(file,limitlessAPI:true)
        try await waitForImport()
        XCTAssertFalse(app.importingJSON);XCTAssertTrue(app.importStatus.contains("malformed"));XCTAssertNotNil(app.errorMessage);XCTAssertEqual(try app.store.stats().count,0)
    }
    func testUnsavedInMemoryPolicyDoesNotSilentlyUseDifferentDiskPolicy() async throws {
        let file=try fixture();var disk=app.settings;disk.privacy.redactSecrets.toggle();try disk.save(root:root)
        app.importJSONFile(file,limitlessAPI:true)
        try await waitForImport()
        XCTAssertFalse(app.importingJSON);XCTAssertTrue(app.importStatus.contains("no longer match"));XCTAssertEqual(try app.store.stats().count,0)
    }
}
