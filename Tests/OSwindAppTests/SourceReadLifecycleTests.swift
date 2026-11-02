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
}
