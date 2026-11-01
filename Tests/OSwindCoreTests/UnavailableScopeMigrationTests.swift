import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

extension HistoricalErasureMigrationTests {
    private func legacy31Scope()throws->URL {
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"cached-native-schema31",withExtension:"sqlite",subdirectory:"HistoricalErasureMigration")),provenance=try XCTUnwrap(Bundle.module.url(forResource:"provenance-cached-schema31",withExtension:"json",subdirectory:"HistoricalErasureMigration"))
        let metadata=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:provenance)) as? [String:Any]),bytes=try Data(contentsOf:fixture)
        XCTAssertEqual(SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined(),metadata["sha256"] as? String)
        let generator=try XCTUnwrap(Bundle.module.url(forResource:"generation-schema31",withExtension:"swift.txt",subdirectory:"HistoricalErasureMigration"))
        XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:generator)).map {String(format:"%02x",$0)}.joined(),metadata["probeSHA256"] as? String)
        let library=root.appendingPathComponent("library31");try Paths.ensure(library);try bytes.write(to:library.appendingPathComponent("memory.sqlite"),options:.withoutOverwriting);return library
    }
    func testActual31ScopeMigrationPreservesNativeHistoryLifetimesJournalAndCache()throws {
        let library=try legacy31Scope(),before=try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),31);return try entityFingerprint(db)}
        let store=try MemoryStore(root:library);defer {try? store.close()}
        try store.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),32);XCTAssertEqual(try entityFingerprint(db),before);try EntityScopeSchema.validate(db);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name GLOB 'unavailable_scope_writer_*'"),45)}
        let entity=try XCTUnwrap(store.entities().first),chat=try XCTUnwrap(store.chats().first),turn=try XCTUnwrap(store.chatTurns(chat.id).first)
        XCTAssertEqual(Data(turn.question.utf8),Data("Original e\u{301} question".utf8));XCTAssertEqual(turn.answer.text,"Original 👩🏽‍💻 answer");XCTAssertEqual(turn.filter.entityID,entity.id)
        try store.deleteEntity(entity.id);let retired=try XCTUnwrap(store.chatTurns(chat.id).first)
        XCTAssertEqual(Data(retired.question.utf8),Data(turn.question.utf8));XCTAssertEqual(retired.answer.text,turn.answer.text);XCTAssertNil(retired.filter.entityID);XCTAssertNotNil(retired.filter.unavailableEntityScope);XCTAssertThrowsError(try store.search(retired.filter,mode:.keyword))
    }
    func testAlreadyOpen31StyleWriterRefusesEvenEmptyStatementsAfter32Migration()throws {
        let library=try legacy31Scope()
        try withDB(library) {old in
            // Current fixture registration supplies all known names. Remove
            // the new name to model an already-open schema31 connection; the
            // separately retained frozen31 process probe tests the real binary.
            XCTAssertEqual(sqlite3_create_function_v2(old.handle,"oswind_unavailable_scope_writer_v1",0,SQLITE_UTF8,nil,nil,nil,nil,nil),SQLITE_OK)
            try old.execute("UPDATE chat_turns SET timestamp=timestamp WHERE id='absent-owned-id'")
            let store=try MemoryStore(root:library);defer {try? store.close()};let before=try entityFingerprint(old)
            for sql in ["UPDATE chat_turns SET timestamp=timestamp WHERE id='absent-owned-id'","DELETE FROM memories WHERE id='absent-owned-id'","DELETE FROM routine_run_originals WHERE run_id='absent-owned-id'"] {
                XCTAssertNotEqual(sqlite3_exec(old.handle,sql,nil,nil,nil),SQLITE_OK);XCTAssertTrue(String(cString:sqlite3_errmsg(old.handle)).contains("oswind_unavailable_scope_writer_v1"))
            };XCTAssertEqual(try entityFingerprint(old),before)
        }
    }
    func testAlteredActual31TurnProtectionRefuses32MigrationAtomically()throws {
        let library=try legacy31Scope(),before=try withDB(library) {db in try db.execute("DROP TRIGGER sync_versions_chat_turns_change; CREATE TRIGGER sync_versions_chat_turns_change BEFORE UPDATE ON chat_turns BEGIN SELECT 1; END");return try entityFingerprint(db)}
        XCTAssertThrowsError(try MemoryStore(root:library))
        try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),31);XCTAssertEqual(try entityFingerprint(db),before);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name IN ('entity_scope_turn','entity_scope_run') OR name GLOB 'unavailable_scope_writer_*'"),0)}
    }
}
