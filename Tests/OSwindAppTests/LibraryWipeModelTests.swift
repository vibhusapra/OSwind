import XCTest
import OSwindCore
@testable import OSwind

@MainActor final class LibraryWipeModelTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);app=try AppModel(root:root,startServices:false)}
    override func tearDownWithError() throws {app.prepareForLibrarySwitch();app=nil;try? FileManager.default.removeItem(at:root)}
    func finish() async throws {for _ in 0..<1000 where app.libraryWipe.busy {try await Task.sleep(nanoseconds:10_000_000)};XCTAssertFalse(app.libraryWipe.busy)}
    func testNativeWipeStopsServicesGuardsBusyAndReportsCommittedCounts() async throws {
        try app.store.insert(Memory(text:"old"));app.settings.captureOnLaunch=true;app.settings.apiEnabled=true;app.settings.routinesEnabled=true
        app.wipeLocalLibrary();XCTAssertTrue(app.libraryWipe.busy);app.wipeLocalLibrary();app.addNote("must not enter during wipe");app.importJSONFile(root.appendingPathComponent("missing"));app.toggleCapture();app.startAPI()
        XCTAssertFalse(app.settings.captureOnLaunch);XCTAssertFalse(app.settings.apiEnabled);XCTAssertFalse(app.settings.routinesEnabled);XCTAssertFalse(app.isCapturing);XCTAssertFalse(app.importingJSON)
        try await finish();XCTAssertEqual(app.libraryWipe.result?.erasure.sources,1);XCTAssertTrue(app.libraryWipe.result?.cleanupComplete == true);XCTAssertFalse(app.libraryWipe.pendingCleanup);XCTAssertEqual(try app.store.stats().count,0)
        let persisted=AppSettings.load(root:root);XCTAssertFalse(persisted.captureOnLaunch);XCTAssertFalse(persisted.apiEnabled);XCTAssertFalse(persisted.routinesEnabled)
    }
    func testPendingCleanupIsVisibleOnReopenAndRetryPreservesNewHistory() async throws {
        let outside=root.appendingPathComponent("owned-target"),link=root.appendingPathComponent("images/link");try Data([7]).write(to:outside);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        try app.store.insert(Memory(text:"old"));app.wipeLocalLibrary();try await finish()
        XCTAssertTrue(app.libraryWipe.pendingCleanup);XCTAssertEqual(app.libraryWipe.result?.erasure.sources,1);XCTAssertEqual(app.libraryWipe.result?.erasure.pendingMedia,1)
        app.prepareForLibrarySwitch();app=try AppModel(root:root,startServices:false);XCTAssertTrue(app.libraryWipe.pendingCleanup)
        try FileManager.default.removeItem(at:link);try app.store.insert(Memory(id:"fresh",text:"new history"));app.wipeLocalLibrary(retry:true);try await finish()
        XCTAssertFalse(app.libraryWipe.pendingCleanup);XCTAssertTrue(app.libraryWipe.result?.cleanupComplete == true);XCTAssertNotNil(try app.store.get("fresh"));XCTAssertEqual(try Data(contentsOf:outside),Data([7]))
    }
    func testStopWhileWaitingLeavesHistoryAndHasAccurateStatus() async throws {
        try app.store.insert(Memory(id:"old",text:"keep"));let lease=try app.store.mediaWriteLease();defer {lease.release()}
        app.wipeLocalLibrary();XCTAssertTrue(app.libraryWipe.busy);app.libraryWipe.cancel();try await finish()
        XCTAssertNil(app.libraryWipe.result);XCTAssertTrue(app.libraryWipe.status.contains("before history deletion committed"));XCTAssertNotNil(try app.store.get("old"))
    }
    func testOldNoteWorkerCannotRepopulateAfterNativeWipe() async throws {
        app.addNote(String(repeating:"Earlier note ",count:200));app.wipeLocalLibrary();try await finish();try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(try app.store.stats().count,0);XCTAssertNil(app.selected)
    }
}
