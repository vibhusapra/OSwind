import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class SelectedReadLifecycleTests:XCTestCase {
    func testPIIMetadataReaderOwnsExitAndDrainBeforeItsActualReadReturns()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-selected-read-"+UUID().uuidString)
        let app=try AppModel(root:root,startServices:false),gate=ImportWorkerGate()
        defer {gate.release();try? FileManager.default.removeItem(at:root)}
        let memory=Memory(id:"owned-selected-read",kind:.note,text:"Owned source")
        try app.store.insert(memory);app.selected=memory
        try await SourceWorkTestJob.settle(app)
        let store=app.store
        let pending=app.refreshSelectedPIIScan(read:{memory in
            try? gate.pause() // Deliberately hold actual worker despite cancellation.
            return try store.piiScanStatus(memory.id,matching:memory)
        })
        await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertTrue(app.hasPendingExitWork,"Actual selected-source reader must own exit before any library reservation")
        app.prepareForLibrarySwitch()
        var drained=false
        let drain=Task {await app.cancelExternalWorkAndWait();drained=true}
        await fulfillment(of:[gate.cancelled],timeout:5)
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertFalse(drained,"External drain cannot acknowledge while actual selected-source reader is held")
        gate.release();await pending?.value;await drain.value
        XCTAssertNil(app.selected);XCTAssertNil(app.selectedPIIScan)
        try app.store.close()
    }
}

@MainActor final class SelectedReadOwnershipTests:XCTestCase {
    var app:AppModel!,root:URL!
    var gates=[ImportWorkerGate]()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-selected-ownership-"+UUID().uuidString)
        app=try AppModel(root:root,startServices:false)
        try app.store.insert(Memory(id:"first",kind:.note,text:"First source"))
        try app.store.insert(Memory(id:"second",kind:.note,text:"Second source"))
    }
    override func tearDown()async throws {
        for gate in gates {gate.release()}
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();app=nil
        try? FileManager.default.removeItem(at:root)
    }
    func gate()->ImportWorkerGate {let value=ImportWorkerGate();gates.append(value);return value}
    func settle()async throws {try await SourceWorkTestJob.settle(app)}
    func testOpeningReaderOwnsExitAndRetiredDrainUntilActualHydrationReturns()async throws {
        try await settle();let gate=gate(),memory=try XCTUnwrap(app.store.get("first"))
        app.openMemory(memory,query:"first",observeRead:{try? gate.pause()})
        await fulfillment(of:[gate.entered],timeout:5);XCTAssertTrue(app.hasPendingExitWork)
        app.prepareForLibrarySwitch();var drained=false
        let drain=Task {await self.app.cancelExternalWorkAndWait();drained=true}
        await fulfillment(of:[gate.cancelled],timeout:5);try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(drained)
        gate.release();await drain.value;XCTAssertNil(app.selected);XCTAssertNil(app.openingMemoryID);XCTAssertNil(app.errorMessage)
    }
    func testNewSelectionCannotForgetOlderHeldMetadataWorker()async throws {
        app.selected=try app.store.get("first");try await settle();let gate=gate(),store=app.store
        let old=app.refreshSelectedPIIScan(read:{memory in try? gate.pause();return try store.piiScanStatus(memory.id,matching:memory)})
        await fulfillment(of:[gate.entered],timeout:5)
        app.selected=try app.store.get("second")
        let fresh=app.refreshSelectedPIIScan();await fresh?.value
        XCTAssertEqual(app.selectedPIIScan?.memoryID,"second");XCTAssertTrue(app.hasPendingExitWork)
        gate.release();await old?.value;XCTAssertEqual(app.selectedPIIScan?.memoryID,"second")
        try await settle();XCTAssertFalse(app.hasPendingExitWork)
    }
    func testCancelledMetadataObserverStillJoinsActualWorker()async throws {
        app.selected=try app.store.get("first");try await settle();let gate=gate(),store=app.store
        let observer=app.refreshSelectedPIIScan(read:{memory in try? gate.pause();return try store.piiScanStatus(memory.id,matching:memory)})
        await fulfillment(of:[gate.entered],timeout:5);observer?.cancel()
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertTrue(app.hasPendingExitWork)
        gate.release();await observer?.value;XCTAssertNil(app.selectedPIIScan);XCTAssertNil(app.selectedPIIScanError)
    }
    func testCancelledDrainStillJoinsOpeningAndRejectsNewReaders()async throws {
        try await settle();let gate=gate(),memory=try XCTUnwrap(app.store.get("first"))
        app.openMemory(memory,query:"first",observeRead:{try? gate.pause()})
        await fulfillment(of:[gate.entered],timeout:5);var drained=false
        let drain=Task {await self.app.cancelExternalWorkAndWait();drained=true};drain.cancel()
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(drained)
        app.openMemory(memory,query:"late",observeRead:{XCTFail("Drain admitted another reader")})
        app.selected=memory;XCTAssertNil(app.refreshSelectedPIIScan(read:{_ in XCTFail("Drain admitted metadata");throw CancellationError()}))
        gate.release();await drain.value;XCTAssertNil(app.selectedPIIScan);XCTAssertNil(app.openingMemoryID)
    }
    func testNewOpeningSuppressesOldHeldHydrationWithoutLosingItsOwnership()async throws {
        try await settle();let gate=gate(),first=try XCTUnwrap(app.store.get("first")),second=try XCTUnwrap(app.store.get("second"))
        app.openMemory(first,query:"first",observeRead:{try? gate.pause()})
        await fulfillment(of:[gate.entered],timeout:5);app.openMemory(second,query:"second")
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while app.openingMemoryID != nil,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(2))}
        XCTAssertEqual(app.selected?.id,"second");XCTAssertTrue(app.hasPendingExitWork)
        gate.release();await app.cancelExternalWorkAndWait();XCTAssertEqual(app.selected?.id,"second");XCTAssertEqual(app.selectedEvidenceQuery,"second")
    }
}

extension RecapModelTests {
    func testSelectedHistoricalValidationOwnsActualReadButNotItsIdleTimer()async throws {
        let (_,original)=try historicalRecap();app.selected=original
        app.watchSelectedOriginal(interval:10_000_000_000)
        try await SourceWorkTestJob.settle(app);try await Task.sleep(for:.milliseconds(50))
        XCTAssertFalse(app.hasPendingExitWork,"Idle validation timer is not ongoing library work")
        let gate=ImportWorkerGate(),store=app.store
        defer {gate.release()}
        app.watchSelectedOriginal(interval:10_000_000_000,read:{memory in try? gate.pause();return try store.hydrate(memory)})
        await fulfillment(of:[gate.entered],timeout:5);XCTAssertTrue(app.hasPendingExitWork)
        app.prepareForLibrarySwitch();var drained=false
        let drain=Task {await self.app.cancelExternalWorkAndWait();drained=true}
        await fulfillment(of:[gate.cancelled],timeout:5);try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(drained)
        gate.release();await drain.value;XCTAssertNil(app.selected);XCTAssertNil(app.deletionStatus)
    }
}

private final class SelectedReadCounter:@unchecked Sendable {
    private let lock=NSLock();private var value=0
    func next()->Int {lock.lock();defer {lock.unlock()};value+=1;return value}
    var count:Int {lock.lock();defer {lock.unlock()};return value}
}
extension RecapModelTests {
    func testExternalDrainStopsHistoricalValidationFromRestartingAfterReturn()async throws {
        let (_,original)=try historicalRecap();app.selected=original
        let gate=ImportWorkerGate(),calls=SelectedReadCounter(),store=app.store
        defer {gate.release()}
        app.watchSelectedOriginal(interval:1_000_000,read:{memory in
            if calls.next()==1 {try? gate.pause()}
            return try store.hydrate(memory)
        })
        await fulfillment(of:[gate.entered],timeout:5)
        let drain=Task {await self.app.cancelExternalWorkAndWait()}
        await fulfillment(of:[gate.cancelled],timeout:5)
        gate.release();await drain.value;try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(calls.count,1);XCTAssertEqual(app.selected,original);XCTAssertFalse(app.hasPendingExitWork)
    }
}
