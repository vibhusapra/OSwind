import XCTest
@testable import OSwindCore
@testable import OSwind

extension SourceOpeningTests {
    func waitForPIIStatus()async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while app.selectedPIIScan==nil && app.selectedPIIScanError==nil,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(2))}
        XCTAssertNotNil(app.selectedPIIScan);XCTAssertNil(app.selectedPIIScanError)
    }
    func testOpeningSourceLoadsPrivacyMetadataSeparatelyAndClearsItOnDismiss()async throws {
        let memory=Memory(id:"owned-privacy",kind:.note,text:"Owned source");try app.store.insert(memory)
        app.openMemory(memory,query:"");try await finish();try await waitForPIIStatus()
        XCTAssertEqual(app.selectedPIIScan?.state,.notRecorded);XCTAssertEqual(app.selectedPIIScan?.memoryID,memory.id)
        app.selected=nil;XCTAssertNil(app.selectedPIIScan);XCTAssertNil(app.selectedPIIScanError)
    }
    func testLateStatusCannotReplaceAnotherSelectedSource()async throws {
        let first=Memory(id:"first-privacy",kind:.note,text:"First"),second=Memory(id:"second-privacy",kind:.note,text:"Second")
        try app.store.insert(first);try app.store.insert(second);app.selected=first
        let gate=ImportWorkerGate();defer {gate.release()}
        let stale=app.refreshSelectedPIIScan(read:{memory in
            do {try gate.pause()} catch {} // Deliberately return despite cancellation.
            return .init(memoryID:memory.id,state:.notRecorded,record:nil)
        })
        await fulfillment(of:[gate.entered],timeout:10)
        app.selected=second;try await waitForPIIStatus();XCTAssertEqual(app.selectedPIIScan?.memoryID,second.id)
        gate.release();await stale?.value;XCTAssertEqual(app.selectedPIIScan?.memoryID,second.id)
    }
    func testLibraryDepartureCannotPublishLateStatus()async throws {
        let memory=Memory(id:"departing-privacy",kind:.note,text:"Owned source");try app.store.insert(memory);app.selected=memory
        let gate=ImportWorkerGate();defer {gate.release()}
        let stale=app.refreshSelectedPIIScan(read:{memory in
            do {try gate.pause()} catch {}
            return .init(memoryID:memory.id,state:.notRecorded,record:nil)
        })
        await fulfillment(of:[gate.entered],timeout:10);app.prepareForLibrarySwitch();gate.release();await stale?.value
        XCTAssertNil(app.selected);XCTAssertNil(app.selectedPIIScan);XCTAssertNil(app.selectedPIIScanError)
    }
    func testStatusFailureNeverBecomesAnUncheckedFallbackClaim()async throws {
        let memory=Memory(id:"failure-privacy",kind:.note,text:"Owned source");try app.store.insert(memory);app.selected=memory
        let task=app.refreshSelectedPIIScan(read:{_ in throw OSwindError.database("Owned read failure")});await task?.value
        XCTAssertNil(app.selectedPIIScan);XCTAssertNotNil(app.selectedPIIScanError)
    }
}
