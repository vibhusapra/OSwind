import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

extension HistoricalErasureMigrationTests {
    func legacy30()throws->URL {
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"cached-native-schema30",withExtension:"sqlite",subdirectory:"HistoricalErasureMigration")),provenance=try XCTUnwrap(Bundle.module.url(forResource:"provenance-cached-schema30",withExtension:"json",subdirectory:"HistoricalErasureMigration"))
        let meta=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:provenance)) as? [String:Any]),bytes=try Data(contentsOf:fixture)
        XCTAssertEqual(SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined(),meta["sha256"] as? String)
        let library=root.appendingPathComponent("library30");try Paths.ensure(library);try bytes.write(to:library.appendingPathComponent("memory.sqlite"),options:.withoutOverwriting);return library
    }
    func testActual30ErasureMigrationPreservesNativeCacheOriginalsAndCorrections()throws {
        let library=try legacy30(),before=try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),30);return try entityFingerprint(db)}
        let store=try MemoryStore(root:library);defer {try? store.close()}
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),31);XCTAssertEqual(try entityFingerprint(db),before)
            try SyncIncomingSourceErasureSchema.validate(db)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name GLOB 'source_erasure_writer_*'"),45)
            XCTAssertEqual(try db.eraseCount("SELECT oswind_incoming_source_erasure_v1()"),0)
        }
    }
    func testAlreadyOpen30WriterRefusesEvenEmptyMutationAfterErasureMigration()throws {
        let library=try legacy30()
        try withDB(library) {old in
            XCTAssertEqual(sqlite3_create_function_v2(old.handle,"oswind_source_erasure_writer_v1",0,SQLITE_UTF8,nil,nil,nil,nil,nil),SQLITE_OK)
            try old.execute("UPDATE memories SET favorite=favorite")
            let store=try MemoryStore(root:library);defer {try? store.close()};let before=try entityFingerprint(old)
            for sql in ["UPDATE memories SET favorite=1","DELETE FROM memory_entities WHERE id='absent'","DELETE FROM historical_evidence WHERE handle='absent'","DELETE FROM routine_run_originals WHERE run_id='absent'","DELETE FROM chat_turns WHERE id='absent'"] {
                XCTAssertNotEqual(sqlite3_exec(old.handle,sql,nil,nil,nil),SQLITE_OK);XCTAssertTrue(String(cString:sqlite3_errmsg(old.handle)).contains("oswind_source_erasure_writer_v1"))
            }
            XCTAssertEqual(try entityFingerprint(old),before)
        }
    }
    func testCurrentSourceDeleteAndErasureGuardsCannotBeSilentlyRepaired()throws {
        for name in ["entity_source_delete","source_erasure_writer_memories_delete","source_erasure_writer_historical_evidence_delete","source_erasure_writer_routine_run_originals_update"] {
            let library=root.appendingPathComponent(name),store=try MemoryStore(root:library);try store.close()
            let before=try withDB(library) {db in try db.execute("DROP TRIGGER "+name);return try fingerprint(db)}
            XCTAssertThrowsError(try MemoryStore(root:library))
            try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),31);XCTAssertEqual(try fingerprint(db),before);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name='"+name+"'"),0)}
        }
    }
    func testAlteredActual30SourceDeleteRefusesErasureMigrationAtomically()throws {
        let library=try legacy30(),before=try withDB(library) {db in
            try db.execute("DROP TRIGGER entity_source_delete; CREATE TRIGGER entity_source_delete AFTER DELETE ON memories BEGIN SELECT 1; END")
            return try entityFingerprint(db)
        }
        XCTAssertThrowsError(try MemoryStore(root:library))
        try withDB(library) {db in
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),30);XCTAssertEqual(try entityFingerprint(db),before)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name GLOB 'source_erasure_writer_*'"),0)
        }
    }
    func testSourceErasurePermitIsConnectionBoundNonDeterministicAndResetsAfterFailure()throws {
        let a=try MemoryStore(root:root.appendingPathComponent("a")),b=try MemoryStore(root:root.appendingPathComponent("b"));defer {try? a.close();try? b.close()}
        let permit=SyncIncomingSourceErasure()
        try a.withRoutineDatabase {db in
            try SyncIncomingSourceErasure.register(db,permit:permit)
            XCTAssertEqual(try db.eraseCount("SELECT oswind_incoming_source_erasure_v1()"),0)
            XCTAssertEqual(try db.eraseCount("SELECT flags & 2048 FROM pragma_function_list WHERE name='oswind_incoming_source_erasure_v1'"),0)
            XCTAssertThrowsError(try permit.eraseSelected(db,revokingObject:String(repeating:"a",count:64)))
            XCTAssertEqual(try db.eraseCount("SELECT oswind_incoming_source_erasure_v1()"),0)
            try b.withRoutineDatabase {other in
                XCTAssertThrowsError(try SyncIncomingSourceErasure.register(other,permit:permit))
                XCTAssertThrowsError(try permit.eraseSelected(other,revokingObject:String(repeating:"a",count:64)))
                XCTAssertEqual(try other.eraseCount("SELECT oswind_incoming_source_erasure_v1()"),0)
            }
        }
    }
}
