import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

final class NativeMediaSchemaTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-media-schema-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    func raw<T>(_ body:(OpaquePointer)throws->T)throws->T {
        var handle:OpaquePointer?;guard sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&handle,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK,let handle else {throw OSwindError.invalid("Cannot open owned raw reader")};defer {sqlite3_close(handle)};return try body(handle)
    }
    func testNativeMediaCurrentQueuePreservesIdempotentInsertUpdateDeleteAndUnicodeBytes()throws {
        try store.withRoutineDatabase {db in
            try NativeMediaSchema.validate(db)
            let row=try db.statement("INSERT OR IGNORE INTO erasure_assets VALUES(?)");defer {sqlite3_finalize(row)}
            for value in ["images/é","images/e\u{301}","images/é"] {sqlite3_reset(row);sqlite3_clear_bindings(row);db.bind(row,1,value);try db.done(row)}
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM erasure_assets"),2)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM erasure_assets_v33"),2)
            try db.execute("UPDATE erasure_assets SET path='images/next' WHERE hex(path)=hex('images/é'); DELETE FROM erasure_assets WHERE path='images/next'")
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM erasure_assets"),1)
            let query=try db.statement("SELECT hex(path) FROM erasure_assets");defer {sqlite3_finalize(query)};XCTAssertEqual(sqlite3_step(query),SQLITE_ROW);XCTAssertEqual(db.text(query,0),Data("images/e\u{301}".utf8).map{String(format:"%02X",$0)}.joined())
        }
    }
    func testNativeMediaUnregisteredConnectionCannotReadQueueEvenWhenEmpty()throws {
        try raw {db in
            var query:OpaquePointer?;defer {sqlite3_finalize(query)}
            XCTAssertNotEqual(sqlite3_prepare_v2(db,"SELECT count(*) FROM erasure_assets",-1,&query,nil),SQLITE_OK)
            XCTAssertTrue(String(cString:sqlite3_errmsg(db)).contains(NativeMediaSchema.function))
        }
    }
    func testNativeMediaMetadataGuardStopsStaleInitializerBeforeIgnoredInsert()throws {
        try raw {db in
            XCTAssertNotEqual(sqlite3_exec(db,"INSERT OR IGNORE INTO store_metadata(key,value) VALUES('identity','stale')",nil,nil,nil),SQLITE_OK)
            XCTAssertTrue(String(cString:sqlite3_errmsg(db)).contains(NativeMediaSchema.function))
        }
        try store.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),33);try NativeMediaSchema.validate(db)}
    }
    func testNativeMediaDamagedViewStopsCleanupBeforeFileOrCacheRemoval()throws {
        let file=root.appendingPathComponent("images/owned"),cache=root.appendingPathComponent(NativeMediaSchema.cacheDirectory+"/owned")
        try Data([1,2]).write(to:file);try Paths.ensure(cache.deletingLastPathComponent());try Data([3]).write(to:cache)
        try store.withRoutineDatabase {db in try db.execute("INSERT INTO erasure_assets VALUES('images/owned'); DROP VIEW erasure_assets; CREATE VIEW erasure_assets AS SELECT path FROM erasure_assets_v33 WHERE 0")}
        let result=store.retryErasureCleanup();XCTAssertEqual(result.pendingMedia,-1);XCTAssertFalse(result.searchCacheRemoved);XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf:file),Data([1,2]));XCTAssertEqual(try Data(contentsOf:cache),Data([3]))
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM erasure_assets_v33")},1)
    }
    func testNativeMediaMissingMetadataGuardRefusesReopenWithoutNativeLoss()throws {
        try store.insert(Memory(id:"keep",text:"Owned native evidence"))
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER store_metadata_media_v33_insert")};try store.close()
        XCTAssertThrowsError(try MemoryStore(root:root))
        try raw {db in var row:OpaquePointer?;defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT count(*) FROM memories WHERE id='keep'",-1,&row,nil),SQLITE_OK);XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),1)}
    }
    func testNativeMediaMissingBackingRefusesReopenRatherThanFabricatingEmptyQueue()throws {
        try store.withRoutineDatabase {try $0.execute("INSERT INTO erasure_assets VALUES('images/owned'); DROP TABLE erasure_assets_v33")};try store.close()
        XCTAssertThrowsError(try MemoryStore(root:root))
        try raw {db in var row:OpaquePointer?;defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&row,nil),SQLITE_OK);XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),33)}
    }
}
