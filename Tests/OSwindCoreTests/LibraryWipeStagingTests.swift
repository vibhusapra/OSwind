import XCTest
import CSQLite
@testable import OSwindCore

extension LibraryWipeTests {
    private func installStagingLedger() throws {
        try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db)
            _=try SyncJournal.install(database:db,replica:"00000000-0000-0000-0000-000000008001",group:"00000000-0000-0000-0000-000000008002",epoch:"00000000-0000-0000-0000-000000008003")
        }
    }
    func testLogicalWipeRequiresOwningTransactionAndActiveExclusiveLibraryLease() throws {
        try store.insert(Memory(id:"keep",text:"Owned staging refusal"));try write("images/keep")
        let shared=try store.mediaWriteLease()
        XCTAssertThrowsError(try store.stageLibraryWipe(reservation:shared))
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {try store.stageLibraryWipe(reservation:shared)}})
        shared.release()
        let other=try MemoryStore(root:root.appendingPathComponent("foreign"));defer {try? other.close()}
        let foreign=try MediaAdmissionLease.acquire(root:other.root,exclusive:true,expectedRoot:other.mediaRootIdentity);defer {foreign.release()}
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {try store.stageLibraryWipe(reservation:foreign)}})
        let owned=try MediaAdmissionLease.acquire(root:root,exclusive:true,expectedRoot:store.mediaRootIdentity)
        XCTAssertThrowsError(try store.stageLibraryWipe(reservation:owned));owned.release()
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {try store.stageLibraryWipe(reservation:owned)}})
        XCTAssertNotNil(try store.get("keep"));XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),0)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("images/keep")),Data("images/keep".utf8))
    }
    func testLogicalWipeRollsBackNativeGraphAndInventoryWithoutRemovingFilesOrAuthoringIntent() throws {
        try installStagingLedger();let parent=Memory(id:"parent",text:"Owned rollback evidence",imagePath:"images/source");try store.insert(parent)
        try write("images/source");try write("audio/nested/orphan")
        let answer=Answer(text:"Owned answer",sources:[.init(memory:parent,score:1,match:"owned")],provider:"owned",duration:0)
        _=try store.saveRecap(answer);let chat=try store.createChat();_=try store.appendChatTurn(sessionID:chat.id,question:"Owned question",answer:answer)
        let now=Date(timeIntervalSince1970:1_792_700_000);var routine=RoutineDefinition();routine.id="owned-stage";_=try store.saveRoutine(routine,now:now)
        let run=try XCTUnwrap(store.claimRoutine(id:routine.id,now:now));_=try store.finishRoutine(run.run.id,status:.failed,message:"Owned finished run")
        let raw=try count("SELECT COUNT(*) FROM personal_sync_changes")
        let lease=try MediaAdmissionLease.acquire(root:root,exclusive:true,expectedRoot:store.mediaRootIdentity);defer {lease.release()}
        enum Rollback:Error {case owned}
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {
            let counts=try store.stageLibraryWipe(reservation:lease)
            XCTAssertEqual(counts.sources,2);XCTAssertEqual(counts.turns,1);XCTAssertEqual(counts.chats,1)
            XCTAssertEqual(counts.routines,1);XCTAssertEqual(counts.runs,1);XCTAssertEqual(counts.originals,0)
            XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM memories"),0)
            XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM erasure_assets"),2)
            XCTAssertEqual(try db.eraseCount("SELECT counter FROM personal_sync_collection_local"),0)
            XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("images/source").path))
            throw Rollback.owned
        }}) {XCTAssertTrue($0 is Rollback)}
        XCTAssertEqual(try count("SELECT COUNT(*) FROM memories"),2);XCTAssertEqual(try count("SELECT COUNT(*) FROM chat_turns"),1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM routine_runs"),1);XCTAssertEqual(try count("SELECT COUNT(*) FROM personal_sync_changes"),raw)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),0);XCTAssertFalse(try store.hasPendingLibraryWipeCleanup())
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("audio/nested/orphan")),Data("audio/nested/orphan".utf8))
    }
    func testCommittedLogicalWipeLeavesDurableCleanupAndRetryPreservesLaterMediaWithoutLocalIntent() throws {
        try installStagingLedger();try store.insert(Memory(id:"old",text:"Owned committed evidence",imagePath:"images/source"))
        try write("images/source");try write("audio/nested/orphan")
        let lease=try MediaAdmissionLease.acquire(root:root,exclusive:true,expectedRoot:store.mediaRootIdentity);defer {lease.release()}
        try store.withRoutineDatabase {db in try db.transaction {
            let counts=try store.stageLibraryWipe(reservation:lease);XCTAssertEqual(counts.sources,1)
            try db.execute("INSERT INTO store_metadata(key,value) VALUES('owned-staging-receipt','committed')")
        }}
        XCTAssertEqual(try count("SELECT COUNT(*) FROM memories"),0);XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),2)
        XCTAssertEqual(try count("SELECT counter FROM personal_sync_collection_local"),0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("images/source").path));lease.release()
        try store.close();store=try MemoryStore(root:root)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),2)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM store_metadata WHERE key='owned-staging-receipt' AND value='committed'"),1)
        try write("video/later");try store.insert(Memory(id:"later",text:"Owned later evidence",imagePath:"video/later"))
        let cleanup=try store.retryLibraryWipeCleanup();XCTAssertTrue(cleanup.cleanupComplete);XCTAssertEqual(cleanup.erasure.removedMedia,2)
        XCTAssertNotNil(try store.get("later"));XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("video/later")),Data("video/later".utf8))
        XCTAssertEqual(try count("SELECT counter FROM personal_sync_collection_local"),0)
        _=try store.wipeLibrary();XCTAssertEqual(try count("SELECT counter FROM personal_sync_collection_local"),1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM personal_sync_collection_controls"),1)
    }
}
