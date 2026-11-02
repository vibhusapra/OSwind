import XCTest
import Darwin
@testable import OSwindCore

private final class StorageCloseProbe:@unchecked Sendable {
    private let lock=NSLock();private var value=false
    func mark() {lock.lock();value=true;lock.unlock()}
    var completed:Bool {lock.lock();defer {lock.unlock()};return value}
}
private final class StorageTraversalPause:@unchecked Sendable {
    let entered=XCTestExpectation(description:"owned original traversal entry")
    private let lock=NSLock(),release=DispatchSemaphore(value:0)
    private var claimed=false,names=[String]()
    func observe(_ name:String)throws {
        lock.lock();names.append(name);let first = !claimed;claimed=true;lock.unlock()
        if first {entered.fulfill();guard release.wait(timeout:.now()+10) == .success else {throw OSwindError.unavailable("Owned root-move gate expired")}}
    }
    func open() {release.signal()}
    var observed:[String] {lock.lock();defer {lock.unlock()};return names}
}
final class StorageUsageTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func testLogicalSizeDeltaAndSymlinkTargetsAreNotCounted()throws {
        let initial=try store.storageUsageBytes(),file=root.appendingPathComponent("owned-file"),outside=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:outside)}
        try Data(repeating:7,count:123).write(to:file);XCTAssertEqual(try store.storageUsageBytes()-initial,123)
        try Data(repeating:9,count:4096).write(to:outside)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("owned-link"),withDestinationURL:outside)
        XCTAssertEqual(try store.storageUsageBytes()-initial,123);XCTAssertEqual(try Data(contentsOf:outside).count,4096)
    }
    func testOptionalStagingExclusionMatchesThreeRetainedBuckets()throws {
        for (bucket,count) in [("images",7),("audio",11),("video",13)] {
            let stage=root.appendingPathComponent(bucket+"/.staging");try Paths.ensure(stage);try Data(repeating:8,count:count).write(to:stage.appendingPathComponent("owned"))
        }
        XCTAssertEqual(try store.storageUsageBytes()-store.storageUsageBytes(includeStaging:false),31)
    }
    @MainActor func testCancelledEntryNeverStartsTraversal()async throws {
        let store=self.store!,operation=Task {try store.storageUsageBytes()};operation.cancel()
        do {_ = try await operation.value;XCTFail("A cancelled traversal must not return a completed estimate")}
        catch is CancellationError {}catch {XCTFail("Expected cancellation")}
        let reservation=try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:0);reservation.release()
    }
    func testActualTraversalReservationBlocksCloseAndCancellationReleasesIt()async throws {
        let store=self.store!,entered=expectation(description:"actual traversal entry"),closingStarted=expectation(description:"close attempted")
        let release=DispatchSemaphore(value:0),probe=StorageCloseProbe();defer {release.signal()}
        let worker=Task.detached {try store.measureStorageUsage(observeEntry:{_ in entered.fulfill();guard release.wait(timeout:.now()+10) == .success else {throw OSwindError.unavailable("Owned traversal gate expired")}})}
        await fulfillment(of:[entered],timeout:5)
        XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:0))
        let close=Task.detached {closingStarted.fulfill();try store.close();probe.mark()}
        await fulfillment(of:[closingStarted],timeout:5);try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(probe.completed)
        worker.cancel();release.signal()
        do {_ = try await worker.value;XCTFail("Mid-traversal cancellation must not return partial bytes")}
        catch is CancellationError {}catch {XCTFail("Expected cooperative traversal cancellation")}
        try await close.value;XCTAssertTrue(probe.completed);XCTAssertTrue(store.isClosed)
    }
    func testMovedRootReturnsNoEstimateAndDoesNotTraverseReplacement()async throws {
        let gate=StorageTraversalPause(),store=self.store!;defer {gate.open()}
        let worker=Task.detached {try store.measureStorageUsage(observeEntry:{try gate.observe($0)})}
        await fulfillment(of:[gate.entered],timeout:5)
        let moved=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString),fm=FileManager.default
        try fm.moveItem(at:root,to:moved);try fm.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? fm.removeItem(at:root);try? fm.moveItem(at:moved,to:root)}
        try Data([9]).write(to:root.appendingPathComponent("foreign"))
        gate.open()
        do {_ = try await worker.value;XCTFail("Root replacement must invalidate the completed estimate")}
        catch is CancellationError {XCTFail("Root replacement must fail without cancelling the worker")}catch {}
        XCTAssertFalse(gate.observed.contains("foreign"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("foreign")),Data([9]))
        XCTAssertThrowsError(try store.storageUsageBytes())
    }
    func testUnreadableDirectoryDoesNotReturnPartialEstimate()throws {
        guard getuid() != 0 else {throw XCTSkip("Unix permission refusal requires a non-root test user")}
        let directory=root.appendingPathComponent("owned-unreadable");try Paths.ensure(directory)
        try Data([7]).write(to:directory.appendingPathComponent("owned"));XCTAssertEqual(chmod(directory.path,0),0);defer {_=chmod(directory.path,0o700)}
        XCTAssertThrowsError(try store.storageUsageBytes())
    }
    func testClosedStoreRefusesTraversalWithoutLeakingReservation()throws {
        try store.close();XCTAssertThrowsError(try store.storageUsageBytes())
        let reservation=try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:0);reservation.release()
    }
}
