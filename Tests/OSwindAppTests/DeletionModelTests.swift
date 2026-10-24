import XCTest
import OSwindCore
@testable import OSwind

@MainActor final class DeletionModelTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);app=try AppModel(root:root,startServices:false)}
    override func tearDownWithError() throws {app.prepareForLibrarySwitch();app=nil;try? FileManager.default.removeItem(at:root)}
    func testDetachedDeleteReportsSharedAndPendingMedia() async throws {
        let file=root.appendingPathComponent("images/shared");try Data([1]).write(to:file)
        let first=Memory(id:"one",text:"remove",imagePath:"images/shared"),second=Memory(id:"two",text:"keep",imagePath:"images/./shared")
        try app.store.insert(first);try app.store.insert(second);app.selected=first;app.delete(first);XCTAssertEqual(app.deletingID,"one");XCTAssertNil(app.selected)
        for _ in 0..<500 where app.deletingID != nil {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNil(app.deletingID);XCTAssertNil(app.errorMessage);XCTAssertTrue(app.deletionStatus?.contains("1 shared file kept") == true);XCTAssertEqual(try Data(contentsOf:file),Data([1]))
    }
    func testManualRetentionBusyGuardAndResultStatus() async throws {
        try app.store.insert(Memory(timestamp:Date(timeIntervalSince1970:100),text:"old source"));app.maintain();XCTAssertTrue(app.maintenanceBusy);app.maintain()
        for _ in 0..<500 where app.maintenanceBusy {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertFalse(app.maintenanceBusy);XCTAssertTrue(app.maintenanceStatus.contains("Removed 1 source ·"));XCTAssertEqual(try app.store.stats().count,0)
    }
}
