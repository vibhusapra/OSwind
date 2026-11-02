import XCTest
import CSQLite
@testable import OSwindCore

extension SyncNativeWriterAdmissionTests {
    private func retirementCount(_ table:String)throws->Int64 {
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open_v2(library.root.appendingPathComponent("memory.sqlite").path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil),SQLITE_OK);defer {sqlite3_close(db)}
        var row:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM "+table,-1,&row,nil)==SQLITE_OK else {throw OSwindError.database("Owned retirement reader \(table): "+String(cString:sqlite3_errmsg(db)))};defer {sqlite3_finalize(row)}
        XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);return sqlite3_column_int64(row,0)
    }
    func testLogicalEraseSavesRetiringAuthorityBeforeVisibilityAndKeepsPhysicalCleanupPending()throws {
        let bytes=Data("Owned retained media pending cleanup".utf8),file=library.root.appendingPathComponent("images/owned.jpg")
        try bytes.write(to:file);try library.insert(Memory(id:"owned",text:"Owned source retained through recovery",imagePath:"images/owned.jpg"))
        try prepare();try service!.installNativeWriterAdmission();try ready()
        let stale=try reopen();defer {try? stale.close()}
        let row=try stale.withRoutineDatabase {try $0.statement("UPDATE store_metadata SET value=value WHERE key='identity'")};defer {sqlite3_finalize(row)}
        var observedBeforeCommit=false
        storage.afterReplacement={do {observedBeforeCommit=try self.retirementCount("memories")==1}catch{XCTFail("Owned separate native reader failed")}}
        let result=try service!.stageLocalRetirement();storage.afterReplacement=nil
        XCTAssertTrue(observedBeforeCommit);XCTAssertEqual(result.counts.sources,1);XCTAssertEqual(result.control.counter,1)
        for table in SyncCanonicalTable.allCases {XCTAssertEqual(try retirementCount(table.rawValue),0,table.rawValue)}
        XCTAssertEqual(try retirementCount("personal_sync_versions"),0);XCTAssertEqual(try retirementCount("historical_evidence"),0)
        XCTAssertEqual(try retirementCount("personal_sync_collection_approvals"),0,"Local deletion must not automatically approve a group erase")
        XCTAssertGreaterThan(try retirementCount(NativeMediaSchema.backing),0);XCTAssertEqual(try Data(contentsOf:file),bytes,"Logical deletion must not claim or perform physical cleanup")
        XCTAssertNotEqual(sqlite3_step(row),SQLITE_DONE);XCTAssertThrowsError(try library.get("owned"));XCTAssertThrowsError(try reopen())
        let saved=try XCTUnwrap(storage.values[deliveryID()]),authority=try XCTUnwrap(JSONSerialization.jsonObject(with:saved) as? [String:Any])
        XCTAssertNotNil(authority["retirement"]);XCTAssertNil((authority["binding"] as? [String:Any])?["publicationLifetime"])
        let exported=root.appendingPathComponent("erased-recovery.oswindbackup")
        let info=try LibraryRecovery.createBackup(from:library.root,destination:exported);XCTAssertEqual(info.memories,0)
        XCTAssertThrowsError(try service!.tick());try stop()
    }
    func testFailedExternalLogicalEraseRollsBackNativeContentAndDoesNotUnlinkMedia()throws {
        let bytes=Data("Owned rollback media".utf8),file=library.root.appendingPathComponent("images/rollback.jpg")
        try bytes.write(to:file);try library.insert(Memory(id:"owned",text:"Owned rollback source",imagePath:"images/rollback.jpg"))
        try prepare();try service!.installNativeWriterAdmission();try ready()
        let accounts=storage.values;storage.failReplacement=true
        XCTAssertThrowsError(try service!.stageLocalRetirement());storage.failReplacement=false
        XCTAssertEqual(storage.values,accounts);XCTAssertEqual(try retirementCount("memories"),1);XCTAssertEqual(try Data(contentsOf:file),bytes)
        XCTAssertThrowsError(try library.insert(Memory(id:"poisoned-erase",text:"Refuse ambiguous owner")))
        try stop();try library.close();library=try reopen()
        XCTAssertEqual(try library.get("owned")?.text,"Owned rollback source")
        XCTAssertEqual(try retirementCount("personal_sync_collection_controls"),0)
    }
    func testCancellationDuringLogicalEraseRollsBackGenerationAndContent()async throws {
        try prepare();try service!.installNativeWriterAdmission();try ready()
        let original=try library.withRoutineDatabase {db -> String in
            let row=try db.statement("SELECT epoch FROM personal_sync_native_writer_epoch");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);return db.text(row,0)
        }
        let entered=expectation(description:"Logical retirement before commit"),release=DispatchSemaphore(value:0)
        let active=service!,worker=Task.detached {
            try active.stageLocalRetirement(progress:{event in if event.phase=="Deleting local history" {entered.fulfill();release.wait()}})
        }
        defer {release.signal()}
        await fulfillment(of:[entered],timeout:10);worker.cancel();release.signal()
        do {_=try await worker.value;XCTFail("Canceled logical retirement committed")}catch {XCTAssertTrue(error is CancellationError)}
        XCTAssertEqual(try library.get("owned")?.text,"Owned source retained through recovery")
        let current=try library.withRoutineDatabase {db -> String in
            let row=try db.statement("SELECT epoch FROM personal_sync_native_writer_epoch");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);return db.text(row,0)
        }
        XCTAssertEqual(current,original);try library.insert(Memory(id:"after-cancelled-retirement",text:"Rollback restored the owner generation"))
    }
}
