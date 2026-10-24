import XCTest
import CSQLite
@testable import OSwindCore

final class LibraryWipeTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    func write(_ path:String) throws {let file=root.appendingPathComponent(path);try Paths.ensure(file.deletingLastPathComponent());try Data(path.utf8).write(to:file)}
    func count(_ sql:String) throws -> Int {try store.withRoutineDatabase {try $0.eraseCount(sql)}}
    func testCompleteWipeIncludesOrphanFilesAndNestedDirectoriesAndCounts() throws {
        try write("images/source");try write("audio/nested/orphan");try write("video/orphan")
        let parent=Memory(id:"parent",text:"Owner",imagePath:"images/source");try store.insert(parent)
        let answer=Answer(text:"Owner [1]",sources:[.init(memory:parent,score:1,match:"fixture")],provider:"fixture",duration:0)
        _=try store.saveRecap(answer);let chat=try store.createChat();_=try store.appendChatTurn(sessionID:chat.id,question:"Owner?",answer:answer);_=try store.saveRoutine(RoutineDefinition())
        let result=try store.wipeLibrary();XCTAssertEqual(result.erasure.sources,2);XCTAssertEqual(result.erasure.conversationTurns,1);XCTAssertEqual(result.conversations,1);XCTAssertEqual(result.routines,1)
        XCTAssertEqual(result.erasure.removedMedia,3);XCTAssertTrue(result.cleanupComplete);XCTAssertTrue(result.compacted);XCTAssertFalse(result.cancelled)
        for bucket in ["images","audio","video"] {XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent(bucket).path).isEmpty)}
        XCTAssertEqual(try count("SELECT COUNT(*) FROM store_metadata WHERE key='library_wipe_dirty'"),0)
        try store.insert(Memory(text:"Fresh searchable history"));XCTAssertEqual(try store.search(.init(query:"searchable"),mode:.keyword).count,1)
    }
    func testUnsafeOrphanIsDurableAndRetryPreservesNewMedia() throws {
        let outside=root.appendingPathComponent("outside");try Data([9]).write(to:outside)
        let link=root.appendingPathComponent("images/link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        try store.insert(Memory(text:"old"));let result=try store.wipeLibrary()
        XCTAssertEqual(result.erasure.sources,1);XCTAssertEqual(result.erasure.pendingMedia,1);XCTAssertFalse(result.cleanupComplete);XCTAssertEqual(try Data(contentsOf:outside),Data([9]))
        store=nil;store=try MemoryStore(root:root);XCTAssertEqual(try store.retryLibraryWipeCleanup().erasure.pendingMedia,1)
        try FileManager.default.removeItem(at:link);try write("images/link");try write("audio/new-orphan")
        try store.insert(Memory(id:"fresh",text:"new",imagePath:"images/link"))
        let retry=try store.retryLibraryWipeCleanup();XCTAssertTrue(retry.cleanupComplete);XCTAssertEqual(retry.erasure.sharedMedia,1);XCTAssertEqual(retry.erasure.sources,0)
        XCTAssertNotNil(try store.get("fresh"));XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("audio/new-orphan").path));XCTAssertEqual(try Data(contentsOf:outside),Data([9]))
    }
    func testCancellationDuringInventoryRollsBackWithoutRemovingFiles() async throws {
        try store.insert(Memory(id:"old",text:"keep"));try write("images/orphan");let local=store!
        let worker=Task.detached {try local.wipeLibrary {if $0.phase=="Deleting local history" {withUnsafeCurrentTask {$0?.cancel()}}}}
        do {_=try await worker.value;XCTFail("Expected cancellation")} catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        XCTAssertNotNil(try store.get("old"));XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),0);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("images/orphan")),Data("images/orphan".utf8))
    }
    func testCancellationAfterCommitKeepsQueueAndReportsActualDeletion() async throws {
        let parent=Memory(text:"old");try store.insert(parent)
        _=try store.saveRecap(.init(text:"Old [1]",sources:[.init(memory:parent,score:1,match:"fixture")],provider:"fixture",duration:0))
        try write("audio/orphan");let local=store!
        let worker=Task.detached {try local.wipeLibrary {if $0.phase=="Removing retained media" {withUnsafeCurrentTask {$0?.cancel()}}}}
        let result=try await worker.value;XCTAssertEqual(result.erasure.sources,2);XCTAssertTrue(result.cancelled);XCTAssertFalse(result.cleanupComplete);XCTAssertEqual(result.erasure.pendingMedia,1)
        // A kill immediately after COMMIT leaves the recap cache marker as well as the wipe queue.
        try store.withRoutineDatabase {try $0.execute("INSERT INTO store_metadata(key,value) VALUES('recap_cache_dirty','1') ON CONFLICT(key) DO UPDATE SET value='1'")}
        XCTAssertEqual(try store.stats().count,0);store=nil;store=try MemoryStore(root:root)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),1);XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("audio/orphan").path))
        XCTAssertTrue(try store.retryLibraryWipeCleanup().cleanupComplete)
    }
    func testPartialMediaCancellationReturnsCommittedCountsAndCanResume() async throws {
        try store.insert(Memory(text:"old"));for i in 0..<3 {try write("images/orphan-\(i)")}
        try store.withRoutineDatabase {db in sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,_,_,sql in
            if let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("DELETE FROM erasure_assets WHERE path") {withUnsafeCurrentTask {$0?.cancel()}};return 0
        },nil)}
        let local=store!,result=try await Task.detached {try local.wipeLibrary()}.value
        try store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}
        XCTAssertEqual(result.erasure.sources,1);XCTAssertEqual(result.erasure.removedMedia,1);XCTAssertEqual(result.erasure.pendingMedia,2);XCTAssertTrue(result.cancelled)
        XCTAssertTrue(try store.retryLibraryWipeCleanup().cleanupComplete)
    }
    func testActiveMediaWriterDelaysWipeWithoutBlockingDatabaseReads() async throws {
        try store.insert(Memory(text:"old"));let lease=try store.mediaWriteLease(),local=store!
        let started=expectation(description:"wipe started"),completed=expectation(description:"wipe completed");completed.isInverted=true
        let worker=Task.detached {let result=try local.wipeLibrary {if $0.phase=="Waiting for active media writers" {started.fulfill()}};completed.fulfill();return result}
        await fulfillment(of:[started],timeout:1);await fulfillment(of:[completed],timeout:0.1);XCTAssertEqual(try store.stats().count,1)
        lease.release();let result=try await worker.value;XCTAssertEqual(result.erasure.sources,1)
    }
    func testActiveReaderMakesCompactionExplicitAndRetryable() throws {
        try store.insert(Memory(text:"old"));var reader:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&reader),SQLITE_OK);defer {sqlite3_close(reader)}
        XCTAssertEqual(sqlite3_exec(reader,"BEGIN; SELECT * FROM memories",nil,nil,nil),SQLITE_OK)
        try store.withRoutineDatabase {sqlite3_busy_timeout($0.handle,20)}
        let result=try store.wipeLibrary();XCTAssertEqual(result.erasure.sources,1);XCTAssertFalse(result.compacted);XCTAssertFalse(result.cleanupComplete);XCTAssertEqual(try store.stats().count,0)
        XCTAssertEqual(sqlite3_exec(reader,"ROLLBACK",nil,nil,nil),SQLITE_OK);XCTAssertTrue(try store.retryLibraryWipeCleanup().cleanupComplete)
    }
    func testSymlinkBucketFailsBeforeLogicalDeletionAndPreservesTarget() throws {
        let outside=root.appendingPathComponent("outside");try Paths.ensure(outside);try Data([1]).write(to:outside.appendingPathComponent("keep"))
        try FileManager.default.removeItem(at:root.appendingPathComponent("images"));try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("images"),withDestinationURL:outside)
        try store.insert(Memory(text:"keep"));XCTAssertThrowsError(try store.wipeLibrary());XCTAssertEqual(try store.stats().count,1);XCTAssertEqual(try Data(contentsOf:outside.appendingPathComponent("keep")),Data([1]))
    }
    func testChangedLibraryRootCannotWipeAnUnrelatedReplacementDirectory() throws {
        let previous=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString);try FileManager.default.moveItem(at:root,to:previous);defer {try? FileManager.default.removeItem(at:previous)}
        try write("images/keep");XCTAssertThrowsError(try store.wipeLibrary());XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("images/keep").path));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".media-admission.lock").path))
    }
    func testRootReplacementAfterCommitPreservesReplacementAndDurableQueue() throws {
        let original=root!,moved=original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString),replacement=original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try write("images/old");try store.insert(Memory(text:"old",imagePath:"images/old"));try Paths.ensure(replacement.appendingPathComponent("images"));try Data([9]).write(to:replacement.appendingPathComponent("images/keep"))
        defer {try? FileManager.default.removeItem(at:moved);try? FileManager.default.removeItem(at:replacement)}
        let result=try store.wipeLibrary {state in if state.phase=="Removing retained media" {try? FileManager.default.moveItem(at:original,to:moved);try? FileManager.default.moveItem(at:replacement,to:original)}}
        XCTAssertEqual(result.erasure.sources,1);XCTAssertEqual(result.erasure.pendingMedia,1);XCTAssertFalse(result.cleanupComplete);XCTAssertFalse(result.erasure.searchCacheRemoved)
        XCTAssertEqual(try Data(contentsOf:original.appendingPathComponent("images/keep")),Data([9]));XCTAssertTrue(FileManager.default.fileExists(atPath:moved.appendingPathComponent("images/old").path))
        store=nil;let reopened=try MemoryStore(root:moved);XCTAssertTrue(try reopened.retryLibraryWipeCleanup().cleanupComplete)
    }
    func testMediaLockSymlinkIsRefused() throws {
        let target=root.appendingPathComponent("outside");try Data([1]).write(to:target);try FileManager.default.createSymbolicLink(at:root.appendingPathComponent(".media-admission.lock"),withDestinationURL:target)
        XCTAssertThrowsError(try store.mediaWriteLease());XCTAssertThrowsError(try store.wipeLibrary());XCTAssertEqual(try Data(contentsOf:target),Data([1]))
    }
}
