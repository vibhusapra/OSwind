import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

extension HistoricalErasureMigrationTests {
    func legacy27()throws->URL {
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"original-source-schema27",withExtension:"sqlite",subdirectory:"HistoricalErasureMigration")),provenance=try XCTUnwrap(Bundle.module.url(forResource:"provenance-schema27",withExtension:"json",subdirectory:"HistoricalErasureMigration"))
        let meta=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:provenance)) as? [String:Any]),bytes=try Data(contentsOf:fixture)
        XCTAssertEqual(SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined(),meta["sha256"] as? String)
        let library=root.appendingPathComponent("library27");try Paths.ensure(library);try bytes.write(to:library.appendingPathComponent("memory.sqlite"),options:.withoutOverwriting);return library
    }
    func testActual27MigrationPreservesOriginalBodiesRecapAnswerAndCaptureState()throws {
        let library=try legacy27(),before=try withDB(library) {db in
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),27)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name GLOB 'incoming_source_writer_*'"),0)
            return try fingerprint(db)
        }
        let store=try MemoryStore(root:library);defer {try? store.close()}
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),32);XCTAssertEqual(try fingerprint(db),before)
            try HistoricalErasureSchema.validate(db);try SyncIncomingSourceSchema.validate(db)
        }
        XCTAssertEqual(try store.get("source")?.text,"Newer independent current body")
        XCTAssertEqual(try store.recapEvidence("linked-recap").first?.memory.text,"Original private source body")
        let preview=try store.previewErasure(.init(app:"Safari"));XCTAssertEqual(preview.historicalVersions,1);XCTAssertEqual(preview.conversationTurns,1)
    }
    func testAlreadyOpen27WriterEvenEmptyDeleteRefusesIncomingMarker()throws {
        let library=try legacy27()
        try withDB(library) {old in
            XCTAssertEqual(sqlite3_create_function_v2(old.handle,"oswind_incoming_source_writer_v1",0,SQLITE_UTF8,nil,nil,nil,nil,nil),SQLITE_OK)
            try old.execute("UPDATE memories SET favorite=1 WHERE id='source'")
            let store=try MemoryStore(root:library);defer {try? store.close()}
            let before=try fingerprint(old)
            for sql in ["UPDATE memories SET favorite=0 WHERE id='source'","DELETE FROM memories WHERE id='absent-owned-id'","DELETE FROM recap_sources WHERE recap_id='absent-owned-id'"] {
                XCTAssertNotEqual(sqlite3_exec(old.handle,sql,nil,nil,nil),SQLITE_OK)
                XCTAssertTrue(String(cString:sqlite3_errmsg(old.handle)).contains("oswind_incoming_source_writer_v1"))
            }
            XCTAssertEqual(try fingerprint(old),before)
        }
    }
    func testActual27UnexpectedOwnerGuardRefusesMigrationAtomically()throws {
        let library=try legacy27(),before=try withDB(library) {db in
            try db.execute("DROP TRIGGER historical_owner_revision; CREATE TRIGGER historical_owner_revision BEFORE UPDATE ON memories BEGIN SELECT 1; END")
            return try fingerprint(db)
        }
        XCTAssertThrowsError(try MemoryStore(root:library))
        try withDB(library) {db in
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),27);XCTAssertEqual(try fingerprint(db),before)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name GLOB 'incoming_source_writer_*'"),0)
        }
    }
    func testMissingCurrentIncomingProtectionIsNotSilentlyRepaired()throws {
        let library=try legacy27(),store=try MemoryStore(root:library);try store.close()
        let before=try withDB(library) {db in try db.execute("DROP TRIGGER incoming_source_writer_chat_sources_update");return try fingerprint(db)}
        XCTAssertThrowsError(try MemoryStore(root:library)) {XCTAssertTrue($0.localizedDescription.contains("Incoming source writer protection is missing"))}
        try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),32);XCTAssertEqual(try fingerprint(db),before)}
    }
}
