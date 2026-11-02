import XCTest
@testable import OSwindCore

extension SyncNativeReceivedRetirementTests {
    func session(_ service:SyncLibraryService,pairing:PersonalSyncPairing)throws->PersonalSyncSession {
        try .init(service:service,pairing:pairing,schedule:.init(activeSeconds:0.005,idleSeconds:0.02,retrySeconds:0.02))
    }
    func wait(_ session:PersonalSyncSession,phase:PersonalSyncStatus.Phase)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(15))
        while ContinuousClock.now<deadline {
            if await session.status().phase==phase {return}
            try await Task.sleep(for:.milliseconds(5))
        }
        let current=await session.status()
        throw OSwindError.unavailable("Owned session expected \(phase), observed \(current.phase)")
    }
    func testEnrolledSessionOwnsLocalEraseCountsCredentialsAndTerminalStop()async throws {
        let connection=try session(sa,pairing:pa)
        try await connection.setProcessingEnabled(true);try await wait(connection,phase:.upToDate)
        let result=try await connection.retireHistory(received:false)
        XCTAssertEqual(result.erasure.sources,2);XCTAssertTrue(result.cleanupComplete)
        XCTAssertTrue(sa.transport.isClosed);XCTAssertTrue(sa.inbox.isClosed)
        XCTAssertThrowsError(try pa.status(),"The consumed session must release its pairing owner")
        let status=await connection.status();XCTAssertEqual(status.phase,.stopped)
        try await connection.stop();try await connection.stop()
        try reopenA()
        guard case .needsGroupReview=try ready(sa) else {return XCTFail("Session erasure cannot approve group deletion")}
        XCTAssertEqual(try a.stats(includeDiskUsage:false).count,0)
    }
    func testEnrolledSessionAppliesOnlyItsYieldedSignedPeerErase()async throws {
        _=try publishedErase()
        let connection=try session(sb,pairing:pb)
        try await connection.setProcessingEnabled(true);try await wait(connection,phase:.needsReceivedErase)
        let result=try await connection.retireHistory(received:true)
        XCTAssertTrue(result.cleanupComplete);XCTAssertEqual(result.erasure.sources,2)
        try await connection.stop();try reopenB()
        XCTAssertEqual(try b.stats(includeDiskUsage:false).count,0)
        try b.insert(Memory(id:"session-renewed",text:"Owned session renewed after peer erase"))
        for _ in 0..<4 {_=try ready(sb);_=try ready(sa)}
        XCTAssertEqual(try a.search(.init(query:"Owned session renewed after peer erase"),mode:.keyword).count,1)
        XCTAssertEqual(try count(b,"personal_sync_collection_approvals"),0)
    }
    func testSessionStopJoinsCancelledLogicalEraseBeforeReleasingCredentials()async throws {
        let connection=try session(sa,pairing:pa),gate=SyncSessionEraseGate(),finished=SyncSessionStopProbe(),accounts=storage.values
        defer {gate.release()}
        let erase=Task {try await connection.retireHistory(received:false,progress:{value in
            if value.phase=="Inventorying retained media" {gate.pause()}
        })}
        await fulfillment(of:[gate.entered],timeout:10)
        let stop=Task {try await connection.stop();finished.mark()};stop.cancel()
        await fulfillment(of:[gate.cancelled],timeout:10)
        XCTAssertFalse(finished.value);XCTAssertFalse(sa.transport.isClosed)
        XCTAssertEqual(try count(a,"memories"),2,"Native deletion has not committed while its inventory is held")
        gate.release()
        do {_=try await erase.value;XCTFail("Canceled logical retirement should roll back")}catch {}
        try await stop.value
        XCTAssertTrue(finished.value);XCTAssertTrue(sa.transport.isClosed);XCTAssertEqual(storage.values,accounts)
        try reopenA();XCTAssertEqual(try a.stats(includeDiskUsage:false).count,2)
    }
    func testSessionStopAfterLogicalCommitLeavesRestrictedRetryableCleanup()async throws {
        let orphan=a.root.appendingPathComponent("audio/session-owned-orphan");try Data("Owned cleanup cancellation".utf8).write(to:orphan)
        let connection=try session(sa,pairing:pa),gate=SyncSessionEraseGate(),finished=SyncSessionStopProbe()
        defer {gate.release()}
        let erase=Task {try await connection.retireHistory(received:false,progress:{value in
            if value.phase=="Retrying retained-media cleanup" {gate.pause()}
        })}
        await fulfillment(of:[gate.entered],timeout:10)
        let stop=Task {try await connection.stop();finished.mark()}
        await fulfillment(of:[gate.cancelled],timeout:10)
        XCTAssertFalse(finished.value);XCTAssertFalse(sa.transport.isClosed)
        XCTAssertEqual(try count(a,"memories"),0);XCTAssertTrue(FileManager.default.fileExists(atPath:orphan.path))
        gate.release();let result=try await erase.value;try await stop.value
        XCTAssertFalse(result.cleanupComplete);XCTAssertTrue(result.cancelled);XCTAssertEqual(result.erasure.sources,2)
        XCTAssertThrowsError(try a.insert(Memory(id:"pending-session",text:"No normal grant before cleanup")))
        try a.close()
        let recovery=try SyncRetirementCleanupOwner.open(root:a.root,environment:environment);defer {try? recovery.close()}
        XCTAssertTrue(try recovery.cleanup().cleanupComplete);_=try recovery.completeRetirement();try recovery.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.path))
        try reopenA();XCTAssertEqual(try a.stats(includeDiskUsage:false).count,0)
    }
}

final class SyncSessionEraseGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"Native erasure reached owned gate")
    let cancelled=XCTestExpectation(description:"Actual native erasure observed cancellation")
    private let condition=NSCondition();private var released=false,reported=false
    func pause() {
        condition.lock();defer {condition.unlock()};entered.fulfill()
        let deadline=Date().addingTimeInterval(20)
        while !released,Date()<deadline {
            if Task.isCancelled,!reported {reported=true;cancelled.fulfill()}
            _=condition.wait(until:Date().addingTimeInterval(0.01))
        }
    }
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
}
final class SyncSessionStopProbe:@unchecked Sendable {
    private let lock=NSLock();private var finished=false
    var value:Bool {lock.lock();defer {lock.unlock()};return finished}
    func mark() {lock.lock();finished=true;lock.unlock()}
}
