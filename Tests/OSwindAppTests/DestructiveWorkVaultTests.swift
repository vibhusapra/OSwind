import XCTest
@testable import OSwindCore
@testable import OSwind

extension VaultSessionTests {
    func destructiveLock(_ deletion:Bool)async throws {
        try native()
        let package=root.appendingPathComponent("Destructive.oswindvault"),secret=UUID().uuidString
        let session=AppSession(selection:.init(url:root.appendingPathComponent("plain"),requiresExisting:false,origin:"owned-test"),defaults:defaults,locked:{false})
        try await finish(session)
        session.createVault(at:package,name:"Owned destructive work",capacityGiB:1,passphrase:secret,copyHistory:false,remember:false);try await finish(session)
        XCTAssertNil(session.failure)
        let model=try XCTUnwrap(session.model),gate=ImportWorkerGate();defer {gate.release()}
        model.settings.privacy.retentionDays=1
        let note=Memory(id:"keep",timestamp:Date().addingTimeInterval(-60*86400),kind:.note,text:"Owned encrypted source retained after pre-SQL cancellation")
        try model.store.insert(note)
        if deletion {model.delete(note,observeWorker:{try gate.pause()})}else {model.maintain(observeWorker:{try gate.pause()})}
        await fulfillment(of:[gate.entered],timeout:5);session.requestLock()
        await fulfillment(of:[gate.cancelled],timeout:5)
        XCTAssertTrue(session.busy);XCTAssertNil(session.model);XCTAssertFalse(model.store.isClosed)
        let whileHeld=try await LibraryVault(package:package).status();XCTAssertTrue(whileHeld.imageAttached);XCTAssertTrue(whileHeld.volumeMounted)
        gate.release();try await finish(session)
        XCTAssertNil(session.failure);XCTAssertTrue(model.store.isClosed);XCTAssertFalse(model.hasPendingExitWork)
        XCTAssertEqual(session.vaultStatus?.state,.locked);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
        session.unlock(passphrase:secret,remember:false);try await finish(session)
        XCTAssertNil(session.failure);XCTAssertEqual(try session.model?.store.get("keep")?.text,note.text)
        session.requestLock();try await finish(session);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
    }
    func testNativeLockWaitsForUnreservedDeletionWorkerAndPreservesSource()async throws {try await destructiveLock(true)}
    func testNativeLockWaitsForUnreservedMaintenanceWorkerAndPreservesSource()async throws {try await destructiveLock(false)}
}
