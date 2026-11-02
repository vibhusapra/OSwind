import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class SourceReadLifecycleTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-read-lifetime-"+UUID().uuidString);app=try AppModel(root:root,startServices:false)}
    override func tearDown()async throws {
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait()
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while app.hasPendingStatistics,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        try app.store.close();app=nil;try? FileManager.default.removeItem(at:root)
    }
    func settle()async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while app.hasPendingStatistics,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.hasPendingStatistics)
    }
    func read(_ storage:Bool)async throws {
        try await settle()
        let gate=ImportWorkerGate(),done=XCTestExpectation(description:"actual read worker returned");defer {gate.release()}
        let beforeCount=app.stats.count,beforeBytes=app.stats.bytes
        try app.store.insert(Memory(id:"owned",text:"Added after previous UI snapshot"))
        if storage {
            app.invalidateStorageEstimate();app.refreshStatistics(force:true,observeStorage:{try gate.pause()},storageCompleted:{done.fulfill()})
        } else {app.refreshStatistics(force:true,observeWorker:{try gate.pause()},statisticsCompleted:{done.fulfill()})}
        await fulfillment(of:[gate.entered],timeout:5)
        if storage {try Data(repeating:7,count:65536).write(to:root.appendingPathComponent("owned-size-change"))}
        XCTAssertTrue(app.hasPendingExitWork,"A real unreserved reader must participate in exit ownership")
        app.prepareForLibrarySwitch();if storage {app.invalidateStorageEstimate()}
        var finished=false
        let drain=Task {await self.app.cancelExternalWorkAndWait();finished=true}
        try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(finished,"Drain cannot acknowledge before the actual reader returns")
        gate.release();await fulfillment(of:[done],timeout:5);await drain.value;try await settle()
        if storage {XCTAssertEqual(app.stats.bytes,beforeBytes,"Retirement must not restart traversal or publish bytes from the old root")}
        else {XCTAssertEqual(app.stats.count,beforeCount,"Retirement must not publish a late statistics snapshot")}
    }
    func testStatisticsDrainOwnsActualReaderAndSuppressesRetiredSnapshot()async throws {try await read(false)}
    func testStorageDrainOwnsActualTraversalAndCannotRestartAfterRetirement()async throws {try await read(true)}
    func cancelledDrain(_ storage:Bool)async throws {
        try await settle();let gate=ImportWorkerGate();defer {gate.release()}
        if storage {app.invalidateStorageEstimate();app.refreshStatistics(force:true,observeStorage:{try gate.pause()})}
        else {app.refreshStatistics(force:true,observeWorker:{try gate.pause()})}
        await fulfillment(of:[gate.entered],timeout:5)
        var finished=false;let drain=Task {await self.app.cancelExternalWorkAndWait();finished=true};drain.cancel()
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(finished)
        app.addNote("Cannot enter during drain",observeWorker:{XCTFail("Drain admitted a new writer")})
        app.refreshStatistics(force:true,observeWorker:{XCTFail("Drain admitted a new reader")})
        gate.release();await drain.value;XCTAssertTrue(finished);XCTAssertFalse(app.hasPendingStatistics)
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
        app.refreshStatistics(force:true);try await settle();XCTAssertEqual(app.stats.count,0)
    }
    func testCancelledStatisticsDrainCallerStillWaitsAndRejectsNewWork()async throws {try await cancelledDrain(false)}
    func testCancelledStorageDrainCallerStillWaitsAndRejectsNewWork()async throws {try await cancelledDrain(true)}
    func testStorageFailureKeepsLastGoodEstimateAndCanRetry()async throws {
        try await settle();let bytes=app.stats.bytes;app.invalidateStorageEstimate()
        app.refreshStatistics(force:true,observeStorage:{throw OSwindError.unavailable("Owned traversal failure")})
        try await settle();XCTAssertEqual(app.stats.bytes,bytes);XCTAssertNil(app.storageUpdatedAt)
        XCTAssertEqual(app.errorMessage,"Owned traversal failure")
        try Data(repeating:3,count:65536).write(to:root.appendingPathComponent("owned-growth"))
        app.refreshStatistics(force:true);try await settle();XCTAssertGreaterThan(app.stats.bytes,bytes);XCTAssertNotNil(app.storageUpdatedAt)
    }
}
