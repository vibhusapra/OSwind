import XCTest
@testable import OSwindCore

final class PendingMediaCleanupTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    let relative="images/owned-pending",bytes=Data([31,41,59])
    var file:URL {root.appendingPathComponent(relative)}
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func seed()throws {
        try bytes.write(to:file)
        try store.insert(Memory(id:"erase",text:"Owned queued media",imagePath:relative))
        try store.insert(Memory(id:"keep",timestamp:Date(timeIntervalSince1970:100),text:"Unrelated old source"))
    }
    func testIdleAttemptLeavesSourcesAndValidCacheUntouched()throws {
        try seed();let cache=root.appendingPathComponent(NativeMediaSchema.cacheDirectory+"/owned-cache")
        try Paths.ensure(cache.deletingLastPathComponent());try bytes.write(to:cache)
        let result=try store.resumePendingMediaCleanup()
        XCTAssertEqual(result.disposition,.idle);XCTAssertNil(result.result)
        XCTAssertEqual(try Data(contentsOf:file),bytes);XCTAssertEqual(try Data(contentsOf:cache),bytes);XCTAssertEqual(try store.stats().count,2)
    }
    func testBusyReservationDefersThenOnlyCommittedMediaIsCleaned()throws {
        try seed();let lease=try store.mediaWriteLease();defer {lease.release()}
        XCTAssertEqual(try store.delete("erase").pendingMedia,1)
        let deferred=try store.resumePendingMediaCleanup();XCTAssertEqual(deferred.disposition,.waitingForWriters);XCTAssertNil(deferred.result)
        XCTAssertEqual(try Data(contentsOf:file),bytes);lease.release()
        let finished=try store.resumePendingMediaCleanup();XCTAssertEqual(finished.disposition,.finished);XCTAssertEqual(finished.result?.sources,0)
        XCTAssertEqual(finished.result?.removedMedia,1);XCTAssertEqual(finished.result?.pendingMedia,0)
        XCTAssertNotNil(try store.get("keep"));XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        XCTAssertEqual(try store.resumePendingMediaCleanup().disposition,.idle)
    }
    func testPendingWipeRetainsItsOwnRetryAndFreshSource()throws {
        try seed();let outside=root.appendingPathComponent("owned-target"),link=root.appendingPathComponent("images/owned-link")
        try bytes.write(to:outside);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        let wiped=try store.wipeLibrary();XCTAssertFalse(wiped.cleanupComplete);XCTAssertTrue(try store.hasPendingLibraryWipeCleanup())
        try store.insert(Memory(id:"fresh",text:"Recorded after prior wipe"))
        let attempt=try store.resumePendingMediaCleanup();XCTAssertEqual(attempt.disposition,.libraryWipe);XCTAssertNil(attempt.result)
        XCTAssertTrue(try store.hasPendingLibraryWipeCleanup());XCTAssertEqual(try Data(contentsOf:outside),bytes);XCTAssertNotNil(try store.get("fresh"))
        try FileManager.default.removeItem(at:link);XCTAssertTrue(try store.retryLibraryWipeCleanup().cleanupComplete);XCTAssertNotNil(try store.get("fresh"))
    }
    func testStructuralPendingPathNeedsAttentionWithoutFollowingSymlink()throws {
        let outside=root.appendingPathComponent("owned-target")
        try bytes.write(to:outside);try bytes.write(to:file)
        try store.insert(Memory(id:"erase",text:"Owned reference",imagePath:relative))
        try FileManager.default.removeItem(at:file);try FileManager.default.createSymbolicLink(at:file,withDestinationURL:outside)
        let lease=try store.mediaWriteLease();defer {lease.release()};XCTAssertEqual(try store.delete("erase").pendingMedia,1);lease.release()
        let attempt=try store.resumePendingMediaCleanup();XCTAssertEqual(attempt.disposition,.needsAttention);XCTAssertEqual(attempt.result?.pendingMedia,1)
        XCTAssertFalse(attempt.result?.warnings.isEmpty ?? true);XCTAssertEqual(try Data(contentsOf:outside),bytes)
    }
    func testChangedRootCannotCleanupEitherDirectory()throws {
        try seed();let lease=try store.mediaWriteLease();XCTAssertEqual(try store.delete("erase").pendingMedia,1);lease.release()
        let moved=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString),fm=FileManager.default
        try fm.moveItem(at:root,to:moved);try fm.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? fm.removeItem(at:root);try? fm.moveItem(at:moved,to:root)}
        try fm.createDirectory(at:root.appendingPathComponent("images"),withIntermediateDirectories:false);try Data([7]).write(to:file)
        XCTAssertThrowsError(try store.resumePendingMediaCleanup())
        XCTAssertEqual(try Data(contentsOf:file),Data([7]));XCTAssertEqual(try Data(contentsOf:moved.appendingPathComponent(relative)),bytes)
    }
    func testSupportedPendingAndReleaseNotificationsStayScopedToRoot()async throws {
        try seed();let lease=try store.mediaWriteLease();defer {lease.release()}
        let pending=expectation(description:"owned durable pending hint"),released=expectation(description:"actual owned writer release")
        pending.assertForOverFulfill=false;released.assertForOverFulfill=false
        let observer=try store.observePendingMediaCleanup {event in if event == .pending {pending.fulfill()}else {released.fulfill()}};defer {observer.cancel()}
        let otherRoot=root.appendingPathComponent("another-library"),other=try MemoryStore(root:otherRoot);defer {try? other.close()}
        let unrelated=expectation(description:"another root must not receive these hints");unrelated.isInverted=true
        let separate=try other.observePendingMediaCleanup {_ in unrelated.fulfill()};defer {separate.cancel()}
        XCTAssertEqual(try store.delete("erase").pendingMedia,1);lease.release()
        await fulfillment(of:[pending,released,unrelated],timeout:0.5)
    }
}
