import XCTest
import CSQLite
@testable import OSwindCore

extension SyncNativeWriterAdmissionTests {
    func testCommittedWriterRetirementRejectsAlreadyAdmittedPreparedSQL()throws {
        try prepare();try service!.installNativeWriterAdmission();try ready()
        let stale=try reopen();defer {try? stale.close()}
        let row=try stale.withRoutineDatabase {try $0.statement("UPDATE memories SET title='Stale prepared writer' WHERE id='owned'")}
        defer {sqlite3_finalize(row)}
        let accounts=storage.values
        try service!.retireNativeWriters()
        XCTAssertNotEqual(storage.values,accounts,"Writer retirement must advance its external checkpoint")
        XCTAssertNotEqual(sqlite3_step(row),SQLITE_DONE,"The persistent generation check must reject already-prepared admitted SQL")
        XCTAssertThrowsError(try stale.insert(Memory(id:"stale-generation",text:"Must reopen")))
        XCTAssertNil(try library.get("stale-generation"))
        try library.insert(Memory(id:"current-generation",text:"Retirement owner remains admitted"))
        let fresh=try reopen();defer {try? fresh.close()}
        try fresh.insert(Memory(id:"reopened-generation",text:"Fresh verified admission"))
        XCTAssertNotNil(try library.get("reopened-generation"));try ready()
    }
    func testFailedExternalWriterRetirementRollsBackGenerationAndPoisonsOwner()throws {
        try prepare();try service!.installNativeWriterAdmission();try ready()
        let other=try reopen();defer {try? other.close()}
        let before=try other.withRoutineDatabase {db -> String in
            let row=try db.statement("SELECT epoch FROM personal_sync_native_writer_epoch");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);return db.text(row,0)
        }
        storage.failReplacement=true;XCTAssertThrowsError(try service!.retireNativeWriters());storage.failReplacement=false
        XCTAssertThrowsError(try library.insert(Memory(id:"poisoned-generation",text:"No ambiguous regrant")))
        let after=try other.withRoutineDatabase {db -> String in
            let row=try db.statement("SELECT epoch FROM personal_sync_native_writer_epoch");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);return db.text(row,0)
        }
        XCTAssertEqual(after,before)
        try other.insert(Memory(id:"unchanged-generation",text:"Uncommitted retirement cannot invalidate another writer"))
        XCTAssertThrowsError(try stop());try library.close();library=try reopen()
        XCTAssertNotNil(try library.get("unchanged-generation"));XCTAssertNil(try library.get("poisoned-generation"))
    }
    func testOrdinaryNativeWriterCannotRotateOrDeleteTheGeneration()throws {
        try prepare();try service!.installNativeWriterAdmission()
        XCTAssertThrowsError(try library.withRoutineDatabase {db in try db.execute("UPDATE personal_sync_native_writer_epoch SET epoch=lower(hex(randomblob(16)))")})
        XCTAssertThrowsError(try library.withRoutineDatabase {try $0.execute("DELETE FROM personal_sync_native_writer_epoch")})
        XCTAssertThrowsError(try library.withRoutineDatabase {try library.nativeWriterAdmission.rotateForRetirement($0)})
        try library.insert(Memory(id:"still-admitted",text:"Rejected unauthorized transitions preserve writer"))
        XCTAssertNotNil(try library.get("still-admitted"))
    }
    func testVerifiedHistorical34GuardContractMigratesWithoutChangingDeliveryAccount()throws {
        try prepare();try stop()
        // Authored fixture for the exact released-in-PR140 native34 SQL
        // contract. It is separate from an actual frozen executable receipt.
        try library.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
            let row=try db.statement("SELECT name FROM pragma_table_list WHERE schema='main' AND type='table' AND name NOT LIKE 'sqlite_%'");defer {sqlite3_finalize(row)}
            var tables=[String](),code=sqlite3_step(row)
            while code==SQLITE_ROW {tables.append(db.text(row,0));code=sqlite3_step(row)};XCTAssertEqual(code,SQLITE_DONE)
            for table in tables {
                XCTAssertTrue(table.utf8.allSatisfy({(97...122).contains($0)||(48...57).contains($0)||$0==95}))
                for op in ["insert","update","delete"] {
                    try db.execute("CREATE TRIGGER sync_native_writer_\(table)_\(op) BEFORE \(op.uppercased()) ON \(table) BEGIN SELECT CASE WHEN oswind_native_sync_writer_v1()<>1 THEN RAISE(ABORT,'Reopen OSwind to verify device sync writer admission') END; END")
                }
            }
            try db.execute("PRAGMA user_version=34")
        }}
        try library.close();let accounts=storage.values
        library=try reopen()
        XCTAssertEqual(storage.values,accounts,"Schema-only guard migration must retain the original external account and checkpoint")
        XCTAssertEqual(try library.withRoutineDatabase {try $0.eraseCount("PRAGMA user_version")},35)
        try library.insert(Memory(id:"migrated-guard",text:"Current native generation after exact legacy contract migration"))
        XCTAssertNotNil(try library.get("migrated-guard"))
    }
}
