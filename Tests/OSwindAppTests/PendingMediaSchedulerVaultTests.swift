import XCTest
@testable import OSwindCore
@testable import OSwind

extension VaultSessionTests {
    func pendingCleanupLock(_ committed:Bool)async throws {
        try native()
        let package=root.appendingPathComponent("Pending.oswindvault"),secret=UUID().uuidString
        let session=AppSession(selection:.init(url:root.appendingPathComponent("plain"),requiresExisting:false,origin:"owned-test"),defaults:defaults,locked:{false})
        try await finish(session);session.createVault(at:package,name:"Owned pending cleanup",capacityGiB:1,passphrase:secret,copyHistory:false,remember:false);try await finish(session)
        XCTAssertNil(session.failure)
        let model=try XCTUnwrap(session.model),gate=ImportWorkerGate();defer {gate.release()}
        await model.pendingMediaCleanup.cancelAndWait()
        let file=model.store.root.appendingPathComponent("images/owned-pending")
        try Data([31,41,59]).write(to:file)
        try model.store.insert(Memory(id:"erase",text:"Already committed deletion",imagePath:"images/owned-pending"))
        try model.store.insert(Memory(id:"keep",text:"Unrelated encrypted source"))
        let lease=try model.store.mediaWriteLease();XCTAssertEqual(try model.store.delete("erase").pendingMedia,1);lease.release()
        if committed {model.pendingMediaCleanup=PendingMediaCleanupModel(store:model.store,afterAttempt:{try? gate.pause()})}
        else {model.pendingMediaCleanup=PendingMediaCleanupModel(store:model.store,beforeAttempt:{try gate.pause()})}
        model.pendingMediaCleanup.start();await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertEqual(FileManager.default.fileExists(atPath:file.path),!committed)
        let status=model.pendingMediaCleanup.status;session.requestLock();await fulfillment(of:[gate.cancelled],timeout:5)
        XCTAssertTrue(session.busy);XCTAssertNil(session.model);XCTAssertFalse(model.store.isClosed)
        let held=try await LibraryVault(package:package).status();XCTAssertTrue(held.imageAttached);XCTAssertTrue(held.volumeMounted)
        gate.release();try await finish(session);XCTAssertNil(session.failure)
        XCTAssertTrue(model.store.isClosed);XCTAssertFalse(model.hasPendingExitWork);XCTAssertEqual(model.pendingMediaCleanup.status,status)
        XCTAssertEqual(session.vaultStatus?.state,.locked);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
        session.unlock(passphrase:secret,remember:false);try await finish(session);XCTAssertNil(session.failure)
        let reopened=try XCTUnwrap(session.model);XCTAssertNotNil(try reopened.store.get("keep"));XCTAssertNil(try reopened.store.get("erase"))
        XCTAssertEqual(reopened.store.retryErasureCleanup().pendingMedia,0);XCTAssertFalse(FileManager.default.fileExists(atPath:reopened.store.root.appendingPathComponent("images/owned-pending").path))
        session.requestLock();try await finish(session);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
    }
    func testNativeLockJoinsUnreservedPendingMediaWorkerBeforeSQL()async throws {try await pendingCleanupLock(false)}
    func testNativeLockJoinsPendingMediaWorkerAfterActualCleanupCommit()async throws {try await pendingCleanupLock(true)}
}
