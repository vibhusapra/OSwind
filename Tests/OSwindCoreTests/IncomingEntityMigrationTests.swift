import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

extension HistoricalErasureMigrationTests {
    func legacy29()throws->URL {
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"cached-native-schema29",withExtension:"sqlite",subdirectory:"HistoricalErasureMigration")),provenance=try XCTUnwrap(Bundle.module.url(forResource:"provenance-cached-schema29",withExtension:"json",subdirectory:"HistoricalErasureMigration"))
        let meta=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:provenance)) as? [String:Any]),bytes=try Data(contentsOf:fixture)
        XCTAssertEqual(SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined(),meta["sha256"] as? String)
        let library=root.appendingPathComponent("library29");try Paths.ensure(library);try bytes.write(to:library.appendingPathComponent("memory.sqlite"),options:.withoutOverwriting);return library
    }
    func entityFingerprint(_ db:RoutineDatabase)throws->[String:[Data]] {
        var result=try fingerprint(db)
        for table in SyncChangeCapture.tables.filter({SyncIncomingEntityWriter.tables.contains(SyncCanonicalTable(rawValue:$0.name)!) || $0.name=="routine_runs"}) {
            let row=try db.statement("SELECT "+table.snapshot("r")+" FROM "+table.name+" r ORDER BY 1");defer {sqlite3_finalize(row)};var frames=[Data](),code=sqlite3_step(row)
            while code==SQLITE_ROW {guard let p=sqlite3_column_blob(row,0) else {throw db.error()};frames.append(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))));code=sqlite3_step(row)};guard code==SQLITE_DONE else {throw db.error()};result[table.name]=frames
        }
        for (name,columns) in ["routine_run_originals":"run_id,payload,native_sha","personal_sync_versions":"object_digest,content_sha,table_name,local_key,bytes,body"] {
            let row=try db.statement("SELECT oswind_sync_row_v1("+columns+") FROM "+name+" ORDER BY 1");defer {sqlite3_finalize(row)};var frames=[Data](),code=sqlite3_step(row)
            while code==SQLITE_ROW {guard let p=sqlite3_column_blob(row,0) else {throw db.error()};frames.append(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))));code=sqlite3_step(row)};guard code==SQLITE_DONE else {throw db.error()};result[name]=frames
        };return result
    }
    func testActual29EntityMigrationPreservesNativeCorrectionsCacheAndRunOriginals()throws {
        let library=try legacy29(),before=try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),29);return try entityFingerprint(db)}
        let store=try MemoryStore(root:library);defer {try? store.close()}
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),30);XCTAssertEqual(try entityFingerprint(db),before);try SyncIncomingEntitySchema.validate(db)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM routine_run_originals"),1);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM entity_mentions"),1);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM entity_project_ignored"),1)
        }
    }
    func testAlreadyOpen29WriterRefusesEvenEmptyMutationAfterMigration()throws {
        let library=try legacy29()
        try withDB(library) {old in
            XCTAssertEqual(sqlite3_create_function_v2(old.handle,"oswind_incoming_entity_writer_v1",0,SQLITE_UTF8,nil,nil,nil,nil,nil),SQLITE_OK)
            try old.execute("UPDATE memories SET favorite=favorite")
            let store=try MemoryStore(root:library);defer {try? store.close()};let before=try entityFingerprint(old)
            for sql in ["UPDATE memories SET favorite=1","DELETE FROM memory_entities WHERE id='absent'","DELETE FROM entity_mentions WHERE memory_id='absent'","DELETE FROM routine_run_originals WHERE run_id='absent'"] {
                XCTAssertNotEqual(sqlite3_exec(old.handle,sql,nil,nil,nil),SQLITE_OK);XCTAssertTrue(String(cString:sqlite3_errmsg(old.handle)).contains("oswind_incoming_entity_writer_v1"))
            };XCTAssertEqual(try entityFingerprint(old),before)
        }
    }
    func testCurrentEntityProtectionAndSourceTriggerCannotBeSilentlyRepaired()throws {
        for name in ["entity_source_revision","incoming_entity_writer_memories_update","incoming_entity_writer_entity_mentions_delete"] {
            let library=root.appendingPathComponent(name),store=try MemoryStore(root:library);try store.close()
            try withDB(library) {try $0.execute("DROP TRIGGER "+name)}
            XCTAssertThrowsError(try MemoryStore(root:library))
            try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),30);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name='"+name+"'"),0)}
        }
    }
    func testCurrentOutgoingSequenceIndexCannotBeSilentlyRepairedAndSelectionIsIndexed()throws {
        let library=try legacy29(),store=try MemoryStore(root:library)
        try store.withRoutineDatabase {db in
            let row=try db.statement("EXPLAIN QUERY PLAN SELECT w.ordinal,w.object_digest FROM personal_sync_work w ORDER BY w.last_seq,w.ordinal LIMIT 128");var plan="",code=sqlite3_step(row)
            while code==SQLITE_ROW {plan+=db.text(row,3);code=sqlite3_step(row)};XCTAssertEqual(code,SQLITE_DONE);XCTAssertTrue(plan.contains("sync_work_sequence"));XCTAssertFalse(plan.contains("TEMP B-TREE"));sqlite3_finalize(row)
            try db.execute("DROP INDEX sync_work_sequence")
        };try store.close();XCTAssertThrowsError(try MemoryStore(root:library))
    }

}
