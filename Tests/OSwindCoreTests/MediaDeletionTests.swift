import XCTest
import CSQLite
@testable import OSwindCore

private final class DeletionTraceCounter:@unchecked Sendable {
    let lock=NSLock();var value=0
    func next()->Int {lock.lock();defer {lock.unlock()};value+=1;return value}
}

final class MediaDeletionTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    @discardableResult func add(_ id:String,at:Double,path:String,app:String="Notes") throws -> Memory {let m=Memory(id:id,timestamp:Date(timeIntervalSince1970:at),app:app,text:"owned "+id,imagePath:path);try store.insert(m);return m}
    func testSingleDeletionPreservesDotAliasSharedByLiveSource() throws {
        let file=root.appendingPathComponent("images/shared");try Data([1,2]).write(to:file)
        try add("delete",at:100,path:"images/shared");try add("keep",at:200,path:"images/./shared")
        try store.delete("delete");XCTAssertEqual(try Data(contentsOf:file),Data([1,2]));XCTAssertNotNil(try store.get("keep"))
        try store.delete("keep");XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testTimeRetentionDoesNotRemoveMediaReferencedByNewerFavorite() throws {
        let file=root.appendingPathComponent("images/shared");try Data([3]).write(to:file)
        try add("old",at:100,path:"images/./shared");try add("new",at:200,path:"images/shared");try store.setFavorite("new",value:true)
        XCTAssertEqual(try store.prune(before:Date(timeIntervalSince1970:150)),1);XCTAssertEqual(try Data(contentsOf:file),Data([3]));XCTAssertNotNil(try store.get("new"))
    }
    func testDurableTriggerRollsBackWithSourceAndStagesDirectSQLDeletion() throws {
        let file=root.appendingPathComponent("images/owned");try Data([6]).write(to:file);try add("one",at:100,path:"images/owned")
        try store.withRoutineDatabase {db in
            try db.execute("BEGIN IMMEDIATE; DELETE FROM memories WHERE id='one'");XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM erasure_assets"),1)
            try db.execute("ROLLBACK");XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM erasure_assets"),0)
            try db.execute("DELETE FROM memories WHERE id='one'");XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM erasure_assets"),1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path));XCTAssertEqual(store.retryErasureCleanup().removedMedia,1)
    }
    func testNonregularAssetReportsCommittedDeletionAndRetriesAfterRepair() throws {
        let folder=root.appendingPathComponent("images/folder");try Paths.ensure(folder);try Data([7]).write(to:folder.appendingPathComponent("keep"));try add("one",at:100,path:"images/folder")
        let result=try store.delete("one");XCTAssertEqual(result.sources,1);XCTAssertEqual(result.pendingMedia,1);XCTAssertFalse(result.warnings.isEmpty);XCTAssertNil(try store.get("one"));XCTAssertTrue(FileManager.default.fileExists(atPath:folder.path))
        store=nil;store=try MemoryStore(root:root);try FileManager.default.removeItem(at:folder);XCTAssertEqual(store.retryErasureCleanup().pendingMedia,0)
    }
    func testPendingMediaFailureStopsBudgetFromSacrificingUnrelatedHistory() throws {
        for i in 0..<40 {try store.insert(Memory(id:"keep-\(i)",timestamp:Date(timeIntervalSince1970:100),text:"keep source"))}
        try store.withRoutineDatabase {try $0.execute("INSERT INTO erasure_assets VALUES('../outside')")}
        let result=try store.pruneHistory(before:Date(timeIntervalSince1970:0),maxBytes:1)
        XCTAssertEqual(result.erasure.sources,0);XCTAssertEqual(result.erasure.pendingMedia,1);XCTAssertEqual(result.budgetMet,false);XCTAssertEqual(try store.stats().count,40);XCTAssertFalse(result.erasure.warnings.isEmpty)
    }
    func testBudgetDropsDisposableGraphBeforeSourceEvidence() throws {
        try store.insert(Memory(id:"keep",text:"source evidence"));let cache=root.appendingPathComponent("indexes");try Paths.ensure(cache);try Data(repeating:8,count:2_000_000).write(to:cache.appendingPathComponent("owned"))
        let result=try store.pruneHistory(before:Date(timeIntervalSince1970:0),maxBytes:store.diskBytes()-1_000_000)
        XCTAssertEqual(result.erasure.sources,0);XCTAssertEqual(result.budgetMet,true);XCTAssertNotNil(try store.get("keep"));XCTAssertFalse(FileManager.default.fileExists(atPath:cache.path))
    }
    func testInvalidRetentionInputsDoNotMutateSources() throws {
        try store.insert(Memory(text:"keep"));XCTAssertThrowsError(try store.pruneHistory(before:Date(timeIntervalSince1970:.infinity)));XCTAssertThrowsError(try store.pruneHistory(before:Date(),maxBytes:0));XCTAssertEqual(try store.stats().count,1)
    }
    func testCancellationBeforeRetentionCommitRollsBack() async throws {
        let file=root.appendingPathComponent("images/keep");try Data([1]).write(to:file);try add("keep",at:100,path:"images/keep");let local=store!
        let worker=Task.detached {withUnsafeCurrentTask {$0?.cancel()};return try local.pruneHistory(before:Date(timeIntervalSince1970:200))}
        do {_=try await worker.value;XCTFail("Cancelled prune succeeded")} catch is CancellationError {} catch {XCTFail("Wrong error \(error)")}
        XCTAssertEqual(try store.stats().count,1);XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }

    func testAllRetainedAssetKindsStageAtTheSQLBoundary() throws {
        for path in ["images/picture","audio/sound","video/clip"] {try Data([9]).write(to:root.appendingPathComponent(path))}
        let visual=VisualRecording(duration:1,width:320,height:180,codec:"h264",hardwareRequired:false,frames:[VisualFrame(time:0,text:"owned frame")])
        var m=Memory(id:"all",text:visual.text,imagePath:"images/picture",audioPath:"audio/sound");m.videoPath="video/clip";m.visualRecording=visual;try store.insert(m)
        let result=try store.delete(m.id);XCTAssertEqual(result.removedMedia,3);XCTAssertEqual(result.pendingMedia,0);XCTAssertTrue(result.warnings.isEmpty)
    }
    func testSchemaThirteenUpgradeInstallsUniversalQueueWithoutChangingIdentity() throws {
        let file=root.appendingPathComponent("images/old");try Data([8]).write(to:file);try add("old",at:100,path:"images/old")
        var identity=""
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='identity'");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);identity=db.text(row,0)
            try db.execute("DROP TRIGGER erasure_stage_assets; PRAGMA user_version=13")
        }
        store=nil;store=try MemoryStore(root:root)
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='identity'");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(db.text(row,0),identity)
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),MemoryStore.schemaVersion)
            try db.execute("DELETE FROM memories WHERE id='old'");XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM erasure_assets"),1)
        }
        XCTAssertEqual(store.retryErasureCleanup().removedMedia,1)
    }
    func testTimeRetentionScansLiveMediaOnceForManySources() throws {
        for i in 0..<40 {let path="images/\(i)";try Data([1]).write(to:root.appendingPathComponent(path));try add(String(i),at:Double(i),path:path)}
        let counter=DeletionTraceCounter(),context=Unmanaged.passUnretained(counter).toOpaque()
        try store.withRoutineDatabase {db in sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,sql in
            if let context,let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("SELECT path FROM (") {_=Unmanaged<DeletionTraceCounter>.fromOpaque(context).takeUnretainedValue().next()}
            return 0
        },context)}
        let result=try store.pruneHistory(before:Date(timeIntervalSince1970:20));try store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}
        XCTAssertEqual(result.erasure.sources,20);XCTAssertEqual(result.erasure.removedMedia,20);XCTAssertEqual(counter.next()-1,1);XCTAssertEqual(try store.stats().count,20)
    }
    func testCancellationAfterBudgetCommitReportsActualPartialWork() async throws {
        for i in 0..<40 {try store.insert(Memory(id:"source-\(i)",timestamp:Date(timeIntervalSince1970:100),text:String(repeating:"owned text ",count:1000)))}
        let counter=DeletionTraceCounter(),context=Unmanaged.passUnretained(counter).toOpaque(),local=store!
        try store.withRoutineDatabase {db in sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,sql in
            if let context,let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("DELETE FROM temp.erasure_live_assets"),Unmanaged<DeletionTraceCounter>.fromOpaque(context).takeUnretainedValue().next()==3 {withUnsafeCurrentTask {$0?.cancel()}}
            return 0
        },context)}
        let worker=Task.detached {try local.pruneHistory(before:Date(timeIntervalSince1970:0),maxBytes:1)}
        let result=try await worker.value;try store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}
        XCTAssertTrue(result.cancelled);XCTAssertEqual(result.erasure.sources,16);XCTAssertEqual(try store.stats().count,24);XCTAssertEqual(result.budgetMet,false);XCTAssertFalse(result.erasure.warnings.isEmpty)
    }

}
