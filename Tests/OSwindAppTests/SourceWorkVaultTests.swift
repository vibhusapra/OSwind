import XCTest
@testable import OSwindCore
@testable import OSwind

extension VaultSessionTests {
    func sourceWorkLock(_ kind:SourceWorkTestJob,committed:Bool=false)async throws {
        try native();let package=root.appendingPathComponent("SourceWork.oswindvault"),secret=UUID().uuidString
        _=try await LibraryVault.create(at:package,name:"Owned source work",capacityGiB:1,passphrase:Data(secret.utf8))
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"owned-test"),defaults:defaults,locked:{false});try await finish(session)
        session.unlock(passphrase:secret,remember:false);try await finish(session);let model=try XCTUnwrap(session.model)
        model.settings.automaticMaintenance=false;model.settings.entityAutomaticIndex=false
        try await SourceWorkTestJob.settle(model);try model.store.insert(Memory(id:"keep",text:"Owned encrypted original"))
        let gate=ImportWorkerGate();defer {gate.release()}
        try kind.start(model,gate:gate,committed:committed);await fulfillment(of:[gate.entered],timeout:10)
        let expected=committed ? 2:1
        XCTAssertEqual(try model.store.stats(includeDiskUsage:false).count,expected)
        session.requestLock();await fulfillment(of:[gate.cancelled],timeout:10)
        XCTAssertTrue(session.busy);XCTAssertNil(session.model);XCTAssertFalse(model.store.isClosed)
        // A sibling statistics job may legitimately publish before requestLock
        // retires the model. Compare only across the observed retired boundary.
        let priorRecapStatus=model.recapSaveStatus,priorCount=model.stats.count,priorBytes=model.stats.bytes
        let held=try await LibraryVault(package:package).status();XCTAssertTrue(held.imageAttached);XCTAssertTrue(held.volumeMounted)
        gate.release();try await finish(session)
        XCTAssertNil(session.failure);XCTAssertTrue(model.store.isClosed);XCTAssertFalse(model.hasPendingExitWork)
        XCTAssertEqual(session.vaultStatus?.state,.locked);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
        XCTAssertEqual(model.recapSaveStatus,priorRecapStatus);XCTAssertEqual(model.stats.count,priorCount);XCTAssertEqual(model.stats.bytes,priorBytes)
        session.unlock(passphrase:secret,remember:false);try await finish(session)
        XCTAssertNil(session.failure);XCTAssertEqual(try session.model?.store.stats(includeDiskUsage:false).count,expected)
        XCTAssertNotNil(try session.model?.store.get("keep"));session.requestLock();try await finish(session)
        XCTAssertNil(session.failure);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
    }
    func testNativeLockWaitsForActualUnreservedNoteWorker()async throws {try await sourceWorkLock(.note)}
    func testNativeLockWaitsForActualUnreservedRecapWorker()async throws {try await sourceWorkLock(.recap)}
    func testNativeLockWaitsForActualUnreservedStatisticsWorker()async throws {try await sourceWorkLock(.statistics)}
    func testNativeLockWaitsForActualUnreservedStorageWorker()async throws {try await sourceWorkLock(.storage)}
    func testNativeLockJoinsAlreadyCommittedNoteWithoutLosingIt()async throws {try await sourceWorkLock(.note,committed:true)}
    func testNativeLockJoinsAlreadyCommittedRecapWithoutLosingIt()async throws {try await sourceWorkLock(.recap,committed:true)}
}
