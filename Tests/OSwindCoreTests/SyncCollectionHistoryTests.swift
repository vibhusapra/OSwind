import XCTest
import CSQLite
import CryptoKit
import Darwin
@testable import OSwindCore

final class SyncCollectionHistoryTests:XCTestCase {
    let replica="00000000-0000-0000-0000-000000007101",peer="00000000-0000-0000-0000-000000007102"
    let group="00000000-0000-0000-0000-000000007103",epoch="00000000-0000-0000-0000-000000007104"
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-collection-history-"+UUID().uuidString)
        store=try MemoryStore(root:root)
        try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db)
            _=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
        }
    }
    override func tearDownWithError()throws {try store.close();store=nil;try FileManager.default.removeItem(at:root)}
    func ledger<T>(_ body:(SyncCollectionHistory)throws->T)throws->T {
        try store.withRoutineDatabase {try body(SyncCollectionHistory(database:$0,replica:replica))}
    }
    func changes()throws->[SyncCapturedChange] {
        try store.withRoutineDatabase {try SyncChangeCapture.changes($0,scope:SyncChangeCapture.scope($0))}
    }
    func observeOwnedPeerFrontier()throws {
        // Only stages the future authenticated-control observation boundary.
        // This fixture does not claim peer control verification or erasure.
        try store.withRoutineDatabase {db in
            try SyncJournal(database:db,replica:replica,group:group,epoch:epoch).allowPeer(peer)
            let s=try db.statement("INSERT INTO personal_sync_collection_frontier VALUES(?,1)");defer {sqlite3_finalize(s)}
            db.bind(s,1,peer);try db.done(s)
        }
    }
    func testQueuedNativeBirthKeepsItsOriginalEraAcrossActualWipeAndReopen()throws {
        try store.insert(Memory(id:"before",kind:.note,text:"Owned queued pre-wipe source"))
        let old=try XCTUnwrap(changes().first(where:{$0.table=="memories" && $0.afterRow != nil}))
        XCTAssertEqual(try ledger {try $0.captured(sequence:old.sequence)},.empty)
        _=try store.wipeLibrary()
        let expected=try SyncClock([replica:1])
        XCTAssertEqual(try ledger {try $0.current()},expected)
        XCTAssertEqual(try ledger {try $0.pendingWipes().map(\.era)},[expected])
        try store.insert(Memory(id:"after",kind:.note,text:"Owned new post-wipe source"))
        let fresh=try XCTUnwrap(changes().last(where:{$0.table=="memories" && $0.afterRow != nil}))
        XCTAssertEqual(try ledger {try $0.captured(sequence:old.sequence)},.empty)
        XCTAssertEqual(try ledger {try $0.captured(sequence:fresh.sequence)},expected)
        try store.close();store=try MemoryStore(root:root)
        try store.withRoutineDatabase {_=try SyncJournal.install(database:$0,replica:replica,group:group,epoch:epoch)}
        XCTAssertEqual(try ledger {try $0.captured(sequence:old.sequence)},.empty)
        XCTAssertEqual(try ledger {try $0.captured(sequence:fresh.sequence)},expected)
        XCTAssertEqual(try ledger {try $0.pendingWipes().map(\.counter)},[1])
        XCTAssertNotNil(try store.get("after"));XCTAssertNil(try store.get("before"))
    }
    func testObservedFrontierDoesNotRelabelAnExistingNativeUpsert()throws {
        try store.insert(Memory(id:"existing",kind:.note,text:"Owned original"))
        let original=try XCTUnwrap(changes().last(where:{$0.table=="memories" && $0.afterRow != nil}))
        try observeOwnedPeerFrontier()
        XCTAssertEqual(try ledger {try $0.current()},try SyncClock([peer:1]))
        try store.insert(Memory(id:"existing",kind:.note,text:"Owned later edit"))
        let edit=try XCTUnwrap(changes().last(where:{$0.table=="memories" && $0.afterRow != nil}))
        XCTAssertGreaterThan(edit.sequence,original.sequence)
        XCTAssertEqual(try ledger {try $0.captured(sequence:edit.sequence)},.empty)
        XCTAssertEqual(try ledger {try $0.birth(table:"memories",key:XCTUnwrap(edit.afterKey))},.empty)
        try store.insert(Memory(id:"fresh",kind:.note,text:"Owned genuinely new lifetime"))
        let fresh=try XCTUnwrap(changes().last(where:{$0.table=="memories" && $0.afterRow != nil}))
        XCTAssertEqual(try ledger {try $0.captured(sequence:fresh.sequence)},try SyncClock([peer:1]))
    }
    func testDeleteReinsertCreatesNewEraWithoutRewritingQueuedOldClaim()throws {
        try store.insert(Memory(id:"reused",kind:.note,text:"Owned old lifetime"))
        let old=try XCTUnwrap(changes().first(where:{$0.table=="memories" && $0.afterRow != nil}))
        try observeOwnedPeerFrontier();_=try store.delete("reused")
        try store.insert(Memory(id:"reused",kind:.note,text:"Owned replacement lifetime"))
        let replacement=try XCTUnwrap(changes().last(where:{$0.table=="memories" && $0.afterRow != nil}))
        XCTAssertEqual(try ledger {try $0.captured(sequence:old.sequence)},.empty)
        XCTAssertEqual(try ledger {try $0.captured(sequence:replacement.sequence)},try SyncClock([peer:1]))
    }
    func testNativeWipeEraAndControlRollBackWithActualWipeTransaction()throws {
        try store.insert(Memory(id:"preserve",kind:.note,text:"Owned rollback source"))
        let before=try changes()
        try store.withRoutineDatabase {try $0.execute("CREATE TRIGGER owned_collection_abort AFTER INSERT ON store_metadata WHEN new.key='library_wipe_dirty' BEGIN SELECT RAISE(ABORT,'Owned wipe rollback'); END")}
        XCTAssertThrowsError(try store.wipeLibrary())
        XCTAssertNotNil(try store.get("preserve"));XCTAssertEqual(try changes(),before)
        XCTAssertEqual(try ledger {try $0.current()},.empty)
        XCTAssertTrue(try ledger {try $0.pendingWipes().isEmpty})
    }
    func testNativeBirthStampRollsBackWithFailedSourceAdmission()throws {
        try store.withRoutineDatabase {try $0.execute("CREATE TRIGGER owned_collection_source_abort AFTER INSERT ON memories BEGIN SELECT RAISE(ABORT,'Owned admission rollback'); END")}
        XCTAssertThrowsError(try store.insert(Memory(id:"failed",kind:.note,text:"Owned rejected source")))
        XCTAssertNil(try store.get("failed"));XCTAssertTrue(try changes().isEmpty)
        try store.withRoutineDatabase {db in
            for table in ["personal_sync_collection_births","personal_sync_collection_changes"] {
                let s=try db.statement("SELECT COUNT(*) FROM "+table);defer {sqlite3_finalize(s)}
                XCTAssertEqual(sqlite3_step(s),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(s,0),0)
            }
        }
    }
    func testMissingCollectionTriggerRefusesReinstallWithoutSilentRepair()throws {
        try store.withRoutineDatabase {db in
            try db.execute("DROP TRIGGER sync_collection_capture_era")
            XCTAssertThrowsError(try SyncCollectionHistory.install(db,replica:replica))
            let row=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE name='sync_collection_capture_era'");defer {sqlite3_finalize(row)}
            XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),0)
        }
    }
    func testMissedNativeWipeHookCannotLeaveASeeminglyValidOldFrontier()throws {
        try store.insert(Memory(id:"before-missed-hook",kind:.note,text:"Owned source before a damaged collection hook"))
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER sync_collection_native_wipe_insert")}
        _=try store.wipeLibrary()
        XCTAssertNil(try store.get("before-missed-hook"))
        XCTAssertThrowsError(try ledger {try $0.current()},"A native identity changed by a wipe must invalidate an unstamped collection frontier")
        XCTAssertThrowsError(try ledger {try $0.pendingWipes()},"A missed hook must not look like a verified empty erasure history")
    }
    func testAlreadyOpenNativeWriterRecordsActualWipeAndNewBirth()throws {
        let location=root.appendingPathComponent("already-open-writer"),a=try MemoryStore(root:location),b=try MemoryStore(root:location)
        defer {try? a.close();try? b.close()}
        try a.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);_=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
        }
        _=try b.wipeLibrary();try b.insert(Memory(id:"after",kind:.note,text:"Owned post-wipe other connection"))
        try a.withRoutineDatabase {db in
            let history=SyncCollectionHistory(database:db,replica:replica)
            XCTAssertEqual(try history.current(),try SyncClock([replica:1]))
            XCTAssertEqual(try history.pendingWipes().map(\.counter),[1])
            let change=try XCTUnwrap(SyncChangeCapture.changes(db,scope:SyncChangeCapture.scope(db)).last(where:{$0.table=="memories" && $0.afterRow != nil}))
            XCTAssertEqual(try history.captured(sequence:change.sequence),try SyncClock([replica:1]))
        }
    }
    func testExistingNativeRowsBeforeLedgerInstallationRemainLegacyAfterAnEdit()throws {
        let location=root.appendingPathComponent("legacy-before-ledger"),legacy=try MemoryStore(root:location)
        defer {try? legacy.close()}
        try legacy.insert(Memory(id:"legacy",kind:.note,text:"Owned before sync installation"))
        try legacy.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);_=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
            try SyncJournal(database:db,replica:replica,group:group,epoch:epoch).allowPeer(peer)
            let s=try db.statement("INSERT INTO personal_sync_collection_frontier VALUES(?,1)");defer {sqlite3_finalize(s)};db.bind(s,1,peer);try db.done(s)
        }
        try legacy.insert(Memory(id:"legacy",kind:.note,text:"Owned edit after frontier observation"))
        try legacy.withRoutineDatabase {db in
            let history=SyncCollectionHistory(database:db,replica:replica),change=try XCTUnwrap(SyncChangeCapture.changes(db,scope:SyncChangeCapture.scope(db)).last(where:{$0.table=="memories" && $0.afterRow != nil}))
            XCTAssertNil(try history.birth(table:"memories",key:XCTUnwrap(change.afterKey)))
            XCTAssertEqual(try history.captured(sequence:change.sequence),.empty)
        }
    }
    func testRepeatedActualWipesAdvanceButCleanupRetryPreservesCurrentEra()throws {
        _=try store.wipeLibrary();_=try store.retryLibraryWipeCleanup()
        XCTAssertEqual(try ledger {try $0.current()},try SyncClock([replica:1]))
        XCTAssertEqual(try ledger {try $0.pendingWipes().map(\.counter)},[1])
        try store.insert(Memory(id:"new-between",kind:.note,text:"Owned between actual wipes"))
        _=try store.wipeLibrary();_=try store.retryLibraryWipeCleanup()
        XCTAssertEqual(try ledger {try $0.current()},try SyncClock([replica:2]))
        XCTAssertEqual(try ledger {try $0.pendingWipes().map(\.counter)},[1,2])
        XCTAssertNil(try store.get("new-between"))
    }
    func testQueueAcknowledgementRemovesOnlyItsAssociatedEraClaims()throws {
        try store.insert(Memory(id:"one",kind:.note,text:"Owned first queued birth"))
        let first=try XCTUnwrap(changes().last(where:{$0.table=="memories" && $0.afterRow != nil}))
        try store.insert(Memory(id:"two",kind:.note,text:"Owned second queued birth"))
        let second=try XCTUnwrap(changes().last(where:{$0.table=="memories" && $0.afterRow != nil}))
        try store.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {try SyncChangeCapture.acknowledge(db,scope:SyncChangeCapture.scope(db),through:first.sequence)}}
        XCTAssertNil(try ledger {try $0.captured(sequence:first.sequence)})
        XCTAssertEqual(try ledger {try $0.captured(sequence:second.sequence)},.empty)
        XCTAssertNotNil(try store.get("one"));XCTAssertNotNil(try store.get("two"))
    }
    func testFrozenPrior33CLIRecordsWipeAndPostWipeBirthThroughInstalledSQL()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_COLLECTION_PRIOR33_CLI"] else {throw XCTSkip("Explicit frozen prior33 CLI required; this is separate from current-source behavior")}
        let binary=URL(fileURLWithPath:path),digest=SHA256.hash(data:try Data(contentsOf:binary)).map {String(format:"%02x",$0)}.joined()
        guard digest=="6580f0db8534063df2fbf04115eb4142af9eb33ef2e2df098d177f6988013c92" else {throw OSwindError.invalid("Frozen prior33 CLI bytes differ")}
        for (name,args) in [("wipe",["wipe","--confirm","DELETE-ALL","--json"]),("note",["note","Owned prior33 post-wipe source"])] {
            let process=Process(),log=root.appendingPathComponent("prior33-"+name+".log")
            XCTAssertTrue(FileManager.default.createFile(atPath:log.path,contents:nil))
            let handle=try FileHandle(forWritingTo:log);defer {try? handle.close()}
            process.executableURL=binary;process.arguments=["--data",root.path]+args;process.standardOutput=handle;process.standardError=handle
            process.environment=ProcessInfo.processInfo.environment.merging(["OSWIND_DATA_DIR":root.path]) {_,owned in owned}
            try process.run();let deadline=Date().addingTimeInterval(30)
            while process.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.01)}
            if process.isRunning {_=Darwin.kill(process.processIdentifier,SIGKILL);process.waitUntilExit();throw OSwindError.unavailable("Owned prior33 CLI timed out")}
            process.waitUntilExit();let output=try String(contentsOf:log,encoding:.utf8)
            XCTAssertEqual(process.terminationStatus,0,output)
        }
        XCTAssertEqual(try ledger {try $0.current()},try SyncClock([replica:1]))
        XCTAssertEqual(try ledger {try $0.pendingWipes().map(\.counter)},[1])
        let change=try XCTUnwrap(changes().last(where:{$0.table=="memories" && $0.afterRow != nil}))
        XCTAssertEqual(try ledger {try $0.captured(sequence:change.sequence)},try SyncClock([replica:1]))
    }
}
