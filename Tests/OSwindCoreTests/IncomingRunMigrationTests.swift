import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

extension HistoricalErasureMigrationTests {
    func legacy28()throws->URL {
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"original-source-schema28",withExtension:"sqlite",subdirectory:"HistoricalErasureMigration")),provenance=try XCTUnwrap(Bundle.module.url(forResource:"provenance-schema28",withExtension:"json",subdirectory:"HistoricalErasureMigration"))
        let meta=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:provenance)) as? [String:Any]),bytes=try Data(contentsOf:fixture)
        XCTAssertEqual(SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined(),meta["sha256"] as? String)
        let library=root.appendingPathComponent("library28");try Paths.ensure(library);try bytes.write(to:library.appendingPathComponent("memory.sqlite"),options:.withoutOverwriting);return library
    }
    func testActual28RunProtectionMigrationPreservesExistingNativeAndCachedOriginals()throws {
        let library=try legacy28(),before=try withDB(library) {db in
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),28)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name='routine_run_originals'"),0)
            return try fingerprint(db)
        }
        let store=try MemoryStore(root:library);defer {try? store.close()}
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),30);XCTAssertEqual(try fingerprint(db),before)
            try RoutineRunOriginalSchema.validate(db);try SyncIncomingSourceSchema.validate(db)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM routine_run_originals"),0)

        }
        XCTAssertEqual(try store.get("source")?.text,"Newer independent current body")
        XCTAssertEqual(try store.recapEvidence("linked-recap").first?.memory.text,"Original private source body")
    }
    func testActual28InstalledVersionCacheReceivesExactRunProtectionMigration()throws {
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"cached-native-schema28",withExtension:"sqlite",subdirectory:"HistoricalErasureMigration")),provenance=try XCTUnwrap(Bundle.module.url(forResource:"provenance-cached-schema28",withExtension:"json",subdirectory:"HistoricalErasureMigration")),meta=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:provenance)) as? [String:Any]),bytes=try Data(contentsOf:fixture)
        XCTAssertEqual(SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined(),meta["sha256"] as? String)
        let library=root.appendingPathComponent("cached28");try Paths.ensure(library);try bytes.write(to:library.appendingPathComponent("memory.sqlite"),options:.withoutOverwriting)
        let before=try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),28);return try fingerprint(db)}
        let store=try MemoryStore(root:library);defer {try? store.close()}
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try fingerprint(db),before);try RoutineRunOriginalSchema.validate(db)
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name='sync_versions_routine_runs_change'");defer {sqlite3_finalize(row)}
            XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertTrue(db.text(row,0).contains("oswind_incoming_run_projection_v1"))
            XCTAssertGreaterThan(try db.eraseCount("SELECT count(*) FROM personal_sync_versions"),0)
        }
    }
    func testAlreadyOpen28WriterAndEmptyDeleteRefuseNewRunMarker()throws {
        let library=try legacy28()
        try withDB(library) {old in
            XCTAssertEqual(sqlite3_create_function_v2(old.handle,"oswind_run_original_writer_v1",0,SQLITE_UTF8,nil,nil,nil,nil,nil),SQLITE_OK)
            try old.execute("UPDATE memories SET favorite=1 WHERE id='source'")
            let store=try MemoryStore(root:library);defer {try? store.close()};let before=try fingerprint(old)
            for sql in ["UPDATE memories SET favorite=0 WHERE id='source'","DELETE FROM memories WHERE id='absent-owned-id'","DELETE FROM routine_runs WHERE id='absent-owned-id'"] {
                XCTAssertNotEqual(sqlite3_exec(old.handle,sql,nil,nil,nil),SQLITE_OK)
                XCTAssertTrue(String(cString:sqlite3_errmsg(old.handle)).contains("oswind_run_original_writer_v1"))
            }
            XCTAssertEqual(try fingerprint(old),before)
        }
    }
    func testMissingCurrentRunOriginalProtectionRefusesWithoutRepair()throws {
        for name in ["routine_original_delete","run_original_writer_routine_runs_update","routine_run_originals"] {
            let library=root.appendingPathComponent(name),store=try MemoryStore(root:library);try store.close()
            try withDB(library) {db in try db.execute((name=="routine_run_originals" ? "DROP TABLE ":"DROP TRIGGER ")+name)}
            XCTAssertThrowsError(try MemoryStore(root:library))
            try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),30)}
        }
    }
}
