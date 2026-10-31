import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

final class HistoricalErasureMigrationTests:XCTestCase {
    var root:URL!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("owned-scope-migration-"+UUID().uuidString);try Paths.ensure(root)}
    override func tearDownWithError() throws {try FileManager.default.removeItem(at:root)}
    func legacy() throws -> URL {
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"original-scope-schema26",withExtension:"sqlite",subdirectory:"HistoricalErasureMigration")),provenance=try XCTUnwrap(Bundle.module.url(forResource:"provenance",withExtension:"json",subdirectory:"HistoricalErasureMigration"))
        let meta=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:provenance)) as? [String:Any]),data=try Data(contentsOf:fixture)
        XCTAssertEqual(SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined(),meta["sha256"] as? String)
        let library=root.appendingPathComponent("library");try Paths.ensure(library);try data.write(to:library.appendingPathComponent("memory.sqlite"),options:.withoutOverwriting);return library
    }
    func withDB<T>(_ library:URL,_ body:(RoutineDatabase)throws->T)throws->T {
        // Foundation can render /private/var back as /var. Keep POSIX's actual
        // resolved bytes through the SQLite call so NOFOLLOW still applies.
        let file=library.appendingPathComponent("memory.sqlite")
        guard let path=realpath(file.path,nil) else {throw OSwindError.invalid("Missing owned legacy fixture")};defer {free(path)}
        var handle:OpaquePointer?;let code=sqlite3_open_v2(path,&handle,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)
        guard code==SQLITE_OK,let handle else {let message=String(cString:sqlite3_errmsg(handle)),extended=sqlite3_extended_errcode(handle);sqlite3_close(handle);throw OSwindError.invalid("Cannot open owned legacy fixture: \(message); code=\(code)/\(extended); exists=\(FileManager.default.fileExists(atPath:file.path)); path=\(file.path)")};defer {sqlite3_close(handle)}
        let db=RoutineDatabase(handle:handle);try SyncChangeCapture.register(on:db);try db.execute("PRAGMA foreign_keys=ON; PRAGMA recursive_triggers=ON; PRAGMA synchronous=FULL");return try body(db)
    }
    func fingerprint(_ db:RoutineDatabase)throws->[String:[Data]] {
        var result=[String:[Data]]()
        for (name,columns) in ["memories":"id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model","chat_sessions":"id,title,created,updated","chat_turns":"id,session_id,timestamp,payload","chat_sources":"turn_id,memory_id,ordinal,score,match,passage_start,passage_length,owner_id,historical_handle","recap_sources":"recap_id,source_id,ordinal,revision,score,match,passage_start,passage_length,owner_id,historical_handle","historical_evidence":"handle,source_id,object_digest,content_sha,body,paths,parents,projection_sha","historical_evidence_state":"singleton,used_bytes,budget,revision","text_observation_pins":"memory_id","personal_sync_capture":"singleton,origin,generation,enabled,suppressed,used_bytes,budget","personal_sync_changes":"seq,table_name,before_key,after_key,after_row,superseded"] {
            let row=try db.statement("SELECT oswind_sync_row_v1("+columns+") FROM "+name+" ORDER BY 1");defer {sqlite3_finalize(row)};var items=[Data](),code=sqlite3_step(row)
            while code==SQLITE_ROW {guard let p=sqlite3_column_blob(row,0) else {throw db.error()};items.append(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))));code=sqlite3_step(row)}
            guard code==SQLITE_DONE else {throw db.error()};result[name]=items
        };return result
    }
    func testActualSchema26MigrationKeepsOriginalBodiesBindingsAndCaptureState() throws {
        let library=try legacy(),before=try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),26);return try fingerprint(db)}
        let store=try MemoryStore(root:library);defer {try? store.close()}
        try store.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),28);XCTAssertEqual(try fingerprint(db),before);try HistoricalErasureSchema.validate(db)}
        let p=try store.previewErasure(.init(app:"Safari"));XCTAssertEqual(p.historicalVersions,1);XCTAssertEqual(p.sources,1);XCTAssertEqual(p.conversationTurns,1)
        let result=try store.eraseHistory(p.scope,expectedToken:p.token);XCTAssertEqual(result.historicalVersions,1);XCTAssertEqual(try store.get("source")?.text,"Newer independent current body")
    }
    func testAlreadyOpen26WriterAndEvenEmptyLegacyDeleteRefuseNewMarker() throws {
        let library=try legacy()
        try withDB(library) {old in
            XCTAssertEqual(sqlite3_create_function_v2(old.handle,"oswind_historical_scope_writer_v1",0,SQLITE_UTF8,nil,nil,nil,nil,nil),SQLITE_OK)
            try old.execute("UPDATE memories SET favorite=1 WHERE id='source'")
            let store=try MemoryStore(root:library);defer {try? store.close()}
            for sql in ["UPDATE memories SET favorite=0 WHERE id='source'","DELETE FROM memories WHERE id IN (SELECT id FROM memories WHERE app='Safari')"] {
                XCTAssertNotEqual(sqlite3_exec(old.handle,sql,nil,nil,nil),SQLITE_OK);XCTAssertTrue(String(cString:sqlite3_errmsg(old.handle)).contains("oswind_historical_scope_writer_v1"))
            }
            XCTAssertEqual(try old.eraseCount("SELECT favorite FROM memories WHERE id='source'"),1)
            XCTAssertEqual(try old.eraseCount("SELECT count(*) FROM historical_evidence"),1)
        }
    }
    func testCorruptLegacyBodyRefusesAtomicIndexMigrationWithoutChangingData() throws {
        let library=try legacy()
        let before=try withDB(library) {db in
            let row=try db.statement("SELECT body FROM historical_evidence");guard sqlite3_step(row)==SQLITE_ROW,let p=sqlite3_column_blob(row,0) else {sqlite3_finalize(row);throw db.error()}
            let old=Data(bytes:p,count:Int(sqlite3_column_bytes(row,0)));sqlite3_finalize(row)
            let text=String(decoding:old,as:UTF8.self),replacement=Data(text.replacingOccurrences(of:"Original private source body",with:"Tampered private source body").utf8);XCTAssertEqual(replacement.count,old.count);XCTAssertNotEqual(replacement,old)
            try db.execute("DROP TRIGGER historical_immutable")
            let change=try db.statement("UPDATE historical_evidence SET body=?");defer {sqlite3_finalize(change)};replacement.withUnsafeBytes {_=sqlite3_bind_blob(change,1,$0.baseAddress,Int32(replacement.count),db.transient)};try db.done(change)
            try db.execute(HistoricalEvidenceStore.schemas["historical_immutable"]!);return try fingerprint(db)
        }
        XCTAssertThrowsError(try MemoryStore(root:library)) {XCTAssertTrue($0.localizedDescription.contains("Historical source integrity differs during scope migration"))}
        try withDB(library) {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),26);XCTAssertEqual(try fingerprint(db),before);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name GLOB 'historical_scope_*'"),0)}
    }
    func testMissingCurrentProtectionIsNotSilentlyRebuilt() throws {
        let library=try legacy(),store=try MemoryStore(root:library);try store.close()
        let before=try withDB(library) {db in try db.execute("DROP INDEX historical_scope_app");return try fingerprint(db)}
        XCTAssertThrowsError(try MemoryStore(root:library)) {XCTAssertTrue($0.localizedDescription.contains("Historical erasure scope protection is missing"))}
        try withDB(library) {db in XCTAssertEqual(try fingerprint(db),before);XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),28)}
    }
    func testOldPreviewAndResultJSONDecodeWithZeroOriginalCounts() throws {
        let preview=Data(#"{"scope":{"app":"Safari","includeSubdomains":true},"token":"old","sources":1,"conversationTurns":2,"mediaReferences":3,"matchedSources":1,"samples":[]}"#.utf8)
        let p=try JSONDecoder().decode(HistoryErasurePreview.self,from:preview);XCTAssertEqual(p.historicalVersions,0);XCTAssertEqual(p.matchedHistoricalVersions,0);XCTAssertTrue(p.historicalSamples.isEmpty);XCTAssertTrue(p.canErase)
        let result=Data(#"{"sources":1,"conversationTurns":2,"removedMedia":3,"sharedMedia":0,"pendingMedia":0,"searchCacheRemoved":true,"warnings":[]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(HistoryErasureResult.self,from:result).historicalVersions,0)
    }
}
