import XCTest
@testable import OSwindCore
@testable import OSwind

final class LibraryRecoveryTransferTests:XCTestCase {
    @MainActor func testUnavailableLibraryOffersContentRecoveryWithoutOpeningNormalStore() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recovery-transfer-"+UUID().uuidString)
        try Paths.ensure(root);defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("library"),store=try MemoryStore(root:source)
        try store.insert(Memory(id:"owned",text:"Recovery through the app"));try store.close()
        let suite="com.oswind.tests.recovery."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let session=AppSession(selection:.init(url:source,requiresExisting:true,origin:"owned"),defaults:defaults,locked:{false},openStore:{_ in throw OSwindError.unavailable("Owned missing sync authority")})
        for _ in 0..<500 where session.busy {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(session.busy);XCTAssertNil(session.model);XCTAssertNotNil(session.failure);XCTAssertTrue(session.canRecoverContent)
        let output=root.appendingPathComponent("Recovered.oswindbackup")
        session.recoveryTransfer.recover(source:source,destination:output)
        for _ in 0..<1000 where session.recoveryTransfer.busy {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(session.recoveryTransfer.busy);XCTAssertNil(session.recoveryTransfer.error)
        XCTAssertEqual(session.recoveryTransfer.archive,output);XCTAssertEqual(try LibraryBackup.inspect(output).memories,1)
        let terminated=await session.lockForTermination();XCTAssertTrue(terminated)
        session.recoveryTransfer.recover(source:source,destination:root.appendingPathComponent("after-quit"))
        XCTAssertFalse(session.recoveryTransfer.busy)
    }
    @MainActor func testTerminationJoinsRecoveryReaderEvenWhenCancellationIsDelayed() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recovery-drain-"+UUID().uuidString)
        try Paths.ensure(root);defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("library"),store=try MemoryStore(root:source)
        try store.insert(Memory(id:"owned",text:"Owned pending recovery"));try store.close()
        let entered=expectation(description:"Recovery source is open"),gate=RecoveryTransferGate(entered:entered)
        defer {gate.release.signal()}
        let transfer=LibraryTransferModel(recovery:{source,destination,relay in
            try LibraryRecovery.createBackup(from:source,destination:destination,progress:{progress in relay.set(progress);gate.waitOnce()})
        })
        let suite="com.oswind.tests.recovery."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let session=AppSession(selection:.init(url:source,requiresExisting:true,origin:"owned"),defaults:defaults,locked:{false},openStore:{_ in throw OSwindError.unavailable("Owned unavailable library")},recoveryTransfer:transfer)
        for _ in 0..<500 where session.busy {try await Task.sleep(for:.milliseconds(10))}
        let output=root.appendingPathComponent("Cancelled.oswindbackup")
        transfer.recover(source:source,destination:output)
        await fulfillment(of:[entered],timeout:10)
        var finished=false
        let quit=Task {let result=await session.lockForTermination();finished=true;return result}
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(finished);XCTAssertTrue(transfer.busy)
        gate.release.signal()
        let result=await quit.value;XCTAssertTrue(result);XCTAssertTrue(finished);XCTAssertFalse(transfer.busy)
        XCTAssertNil(transfer.archive);XCTAssertNil(transfer.inspected);XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        XCTAssertTrue(transfer.status.hasPrefix("Cancelled"))
    }
}

private final class RecoveryTransferGate:@unchecked Sendable {
    let release=DispatchSemaphore(value:0)
    private let entered:XCTestExpectation,lock=NSLock()
    private var used=false
    init(entered:XCTestExpectation) {self.entered=entered}
    func waitOnce() {
        lock.lock();let wait = !used;used=true;lock.unlock()
        guard wait else {return};entered.fulfill();release.wait()
    }
}
