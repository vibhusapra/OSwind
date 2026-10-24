import XCTest
import CSQLite
@testable import OSwindCore

final class HistoryErasureTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    @discardableResult func add(_ id:String,at:Double=100,end:Double?=nil,app:String="Safari",bundle:String="com.apple.Safari",url:String?=nil,path:String?=nil) throws -> Memory {
        let m=Memory(id:id,timestamp:Date(timeIntervalSince1970:at),endTimestamp:end.map {Date(timeIntervalSince1970:$0)},app:app,bundleID:bundle,title:"Title "+id,url:url,text:"unique "+id,imagePath:path,embedding:[1,0],embeddingModel:"fixture");try store.insert(m);return m
    }
    func erase(_ scope:HistoryErasureScope) throws -> HistoryErasureResult {let p=try store.previewErasure(scope);return try store.eraseHistory(scope,expectedToken:p.token)}
    func count(_ sql:String) throws -> Int {try store.withRoutineDatabase {db in let row=try db.statement(sql);defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);return Int(sqlite3_column_int(row,0))}}
    func testEmptyInvalidSelectorsAndDatesNeverBecomeWholeLibraryErase() throws {
        for scope in [HistoryErasureScope(),.init(app:""),.init(bundleID:" \n"),.init(start:Date(timeIntervalSince1970:200),end:Date(timeIntervalSince1970:100)),.init(start:Date(timeIntervalSince1970:.infinity)),.init(domain:"https://example.com"),.init(domain:"example.com/path"),.init(domain:"*.example.com"),.init(domain:".example.com"),.init(domain:"example..com"),.init(domain:"user@example.com"),.init(domain:"example.com:80"),.init(domain:"bad_host"),.init(domain:"example.com?x")] {XCTAssertThrowsError(try store.previewErasure(scope))}
        try add("one");XCTAssertEqual(try store.stats().count,1)
    }
    func testHalfOpenTimeOverlapsWholeRecordingsAndKeepsBoundaries() throws {
        try add("before",at:10,end:20);try add("overlap",at:10,end:21);try add("instant",at:20);try add("inside",at:29,end:40);try add("end",at:30);try add("old",at:19)
        let scope=HistoryErasureScope(start:Date(timeIntervalSince1970:20),end:Date(timeIntervalSince1970:30));let p=try store.previewErasure(scope)
        XCTAssertEqual(p.sources,3);XCTAssertEqual(Set(p.samples.map(\.id)),["overlap","instant","inside"]);XCTAssertEqual(try store.stats().count,6)
        XCTAssertEqual(try erase(scope).sources,3);XCTAssertEqual(try store.stats().count,3);XCTAssertNotNil(try store.get("before"));XCTAssertNotNil(try store.get("end"))
    }
    func testDomainNormalizationSubdomainsAndLookalikeBoundaries() throws {
        for (id,url) in [("base","https://EXAMPLE.com./private"),("sub","https://www.example.com:443/a"),("lookalike","https://notexample.com"),("suffix","https://example.com.evil.test"),("userinfo","https://example.com@evil.test"),("otherScheme","file://example.com/a")] {try add(id,url:url)}
        try add("missing");let scope=HistoryErasureScope(domain:"Example.COM.");XCTAssertEqual(try store.previewErasure(scope).sources,2)
        XCTAssertEqual(try erase(.init(domain:"example.com",includeSubdomains:false)).sources,1)
        XCTAssertEqual(try erase(scope).sources,1);XCTAssertEqual(try store.stats().count,5)
        XCTAssertEqual(try HistoryErasureScope(domain:"bücher.de").validated().domain,"xn--bcher-kva.de")
    }
    func testAppBundleKindAndTimeIntersectAndMatchLiteralNames() throws {
        try add("a",url:"https://example.com");try add("b",app:"safari",url:"https://example.com");try add("c",bundle:"com.other",url:"https://example.com");try add("d",at:200,url:"https://example.com")
        let scope=HistoryErasureScope(end:Date(timeIntervalSince1970:150),app:"Safari",bundleID:"com.apple.Safari",domain:"example.com",kind:.screen)
        XCTAssertEqual(try erase(scope).sources,1);XCTAssertNil(try store.get("a"));XCTAssertEqual(try store.stats().count,3)
        XCTAssertEqual(try store.previewErasure(.init(app:"Safari' OR 1=1 --")).sources,0)
    }
    func testSourceOrCitedAnswerMutationInvalidatesTokenAcrossConnections() throws {
        let m=try add("a"),scope=HistoryErasureScope(app:"Safari"),p=try store.previewErasure(scope),other=try MemoryStore(root:root)
        try other.setFavorite(m.id,value:true)
        XCTAssertThrowsError(try store.eraseHistory(scope,expectedToken:p.token));XCTAssertNotNil(try store.get(m.id))
        let next=try store.previewErasure(scope),chat=try other.createChat()
        _=try other.appendChatTurn(sessionID:chat.id,question:"Private title?",answer:.init(text:"Source [1]",sources:[.init(memory:try XCTUnwrap(other.get(m.id)),score:1,match:"test")],provider:"fixture",duration:0))
        XCTAssertThrowsError(try store.eraseHistory(scope,expectedToken:next.token));XCTAssertEqual(try store.chatTurns(chat.id).count,1)
    }
    func testTokensAreBoundToScopeAndLibraryAndCanBeRepreviewedAfterFailure() throws {
        try add("a");let p=try store.previewErasure(.init(app:"Safari"))
        XCTAssertThrowsError(try store.eraseHistory(.init(bundleID:"com.apple.Safari"),expectedToken:p.token))
        let second=root.appendingPathComponent("second"),other=try MemoryStore(root:second);try other.insert(Memory(id:"a",app:"Safari",text:"x"))
        XCTAssertThrowsError(try other.eraseHistory(.init(app:"Safari"),expectedToken:p.token));XCTAssertEqual(try erase(.init(app:"Safari")).sources,1)
    }
    func testDependentTurnsAndIndexesRemovedWhileUnrelatedConversationSurvives() throws {
        let a=try add("a"),b=try add("b",app:"Notes"),chat=try store.createChat()
        func answer(_ m:Memory)->Answer {.init(text:"Evidence [1]",sources:[.init(memory:m,score:1,match:"fixture")],provider:"test",duration:0)}
        _=try store.appendChatTurn(sessionID:chat.id,question:"Sensitive question?",answer:answer(a));_=try store.appendChatTurn(sessionID:chat.id,question:"Keep?",answer:answer(b))
        let p=try store.previewErasure(.init(app:"Safari"));XCTAssertEqual(p.conversationTurns,1)
        let r=try store.eraseHistory(p.scope,expectedToken:p.token);XCTAssertEqual(r.conversationTurns,1);XCTAssertEqual(try store.chatTurns(chat.id).map(\.question),["Keep?"]);XCTAssertEqual(try store.chat(chat.id)?.title,"Conversation")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM memory_fts WHERE id='a'"),0);XCTAssertEqual(try count("SELECT COUNT(*) FROM vector_keys WHERE memory_id='a'"),0)
        XCTAssertEqual(try store.search(.init(query:"unique a",app:"Safari"),mode:.semantic,vector:[1,0],modelID:"fixture",minimumSimilarity:-1).count,0)
        XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Late?",answer:answer(a)))
    }
    func testSharedMediaPreservedAndUniqueMediaDeletedAndCacheDiscarded() throws {
        for name in ["shared","unique"] {try Data(name.utf8).write(to:root.appendingPathComponent("images/"+name))}
        try add("a",path:"images/shared");try add("b",app:"Notes",path:"images/shared");try add("c",path:"images/unique")
        let cache=root.appendingPathComponent("indexes");try Paths.ensure(cache);try Data([1]).write(to:cache.appendingPathComponent("fixture"))
        let p=try store.previewErasure(.init(app:"Safari"));XCTAssertEqual(p.mediaReferences,2);let r=try store.eraseHistory(p.scope,expectedToken:p.token)
        XCTAssertEqual(r.removedMedia,1);XCTAssertEqual(r.sharedMedia,1);XCTAssertEqual(r.pendingMedia,0);XCTAssertTrue(r.searchCacheRemoved);XCTAssertTrue(r.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("images/shared").path));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("images/unique").path));XCTAssertFalse(FileManager.default.fileExists(atPath:cache.path))
    }
    func testInvalidPendingPathRetainedWithoutTraversingEvenDuringFullWipe() throws {
        try store.withRoutineDatabase {try $0.execute("INSERT INTO erasure_assets VALUES('../outside')")}
        let r=store.retryErasureCleanup();XCTAssertEqual(r.pendingMedia,1);XCTAssertFalse(r.warnings.isEmpty)
        store=nil;store=try MemoryStore(root:root);XCTAssertEqual(store.retryErasureCleanup().pendingMedia,1)
        let result=try store.deleteAll();XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),1);XCTAssertEqual(result.erasure.pendingMedia,1);XCTAssertFalse(result.cleanupComplete)
    }
    func testRetryDoesNotRemoveAReusedLivePathAndMissingFileIsSuccessful() throws {
        try Data([1]).write(to:root.appendingPathComponent("images/live"));try add("live",app:"Notes",path:"images/live")
        try store.withRoutineDatabase {try $0.execute("INSERT INTO erasure_assets VALUES('images/live'),('images/missing')")}
        let r=store.retryErasureCleanup();XCTAssertEqual(r.sharedMedia,1);XCTAssertEqual(r.pendingMedia,0);XCTAssertTrue(r.warnings.isEmpty);XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("images/live").path))
    }
    func testPreviewFailureLeavesConnectionUsableAndPreviewBoundedAtFive() throws {
        for i in 0..<8 {try add(String(i))};let p=try store.previewErasure(.init(app:"Safari"));XCTAssertEqual(p.sources,8);XCTAssertEqual(p.samples.count,5)
        XCTAssertThrowsError(try store.eraseHistory(p.scope,expectedToken:String(repeating:"0",count:64)));XCTAssertEqual(try store.previewErasure(p.scope).sources,8)
    }
    func testCancellationBeforeCommitPreservesEverything() async throws {
        try add("a");let p=try store.previewErasure(.init(app:"Safari"));let local=store!
        let task=Task {withUnsafeCurrentTask {$0?.cancel()};return try local.eraseHistory(p.scope,expectedToken:p.token)}
        do {_=try await task.value;XCTFail("Cancelled erase succeeded")} catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        XCTAssertEqual(try store.stats().count,1);XCTAssertEqual(try store.previewErasure(p.scope).sources,1)
    }
    func testSQLCancellationDuringDeleteRollsBackAndNextQueryWorks() async throws {
        for i in 0..<1000 {try add("cancel-\(i)")}
        let p=try store.previewErasure(.init(app:"Safari")),local=store!
        try store.withRoutineDatabase {db in sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,_,_,sql in
            if let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("DELETE FROM memories WHERE id IN") {withUnsafeCurrentTask {$0?.cancel()}}
            return 0
        },nil)}
        let worker=Task.detached {try local.eraseHistory(p.scope,expectedToken:p.token)}
        do {_=try await worker.value;XCTFail("SQL cancellation succeeded")} catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        try store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}
        XCTAssertEqual(try store.stats().count,1000);XCTAssertEqual(try store.previewErasure(p.scope).sources,1000);XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),0)
        XCTAssertEqual(try erase(p.scope).sources,1000)
    }
    func testQueueSurvivesUnfinishedCleanupAndRefusesDirectoryOrSymlink() throws {
        let directory=root.appendingPathComponent("images/folder"),outside=root.appendingPathComponent("outside")
        try Paths.ensure(directory);try Data([9]).write(to:directory.appendingPathComponent("keep"));try Data([7]).write(to:outside)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("images/link"),withDestinationURL:outside)
        try store.withRoutineDatabase {try $0.execute("INSERT INTO erasure_assets VALUES('images/folder'),('images/link')")}
        store=nil;store=try MemoryStore(root:root)
        let first=store.retryErasureCleanup();XCTAssertEqual(first.pendingMedia,2);XCTAssertFalse(first.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf:outside),Data([7]));XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("keep").path))
        try FileManager.default.removeItem(at:root.appendingPathComponent("images/link"));try FileManager.default.removeItem(at:directory)
        let second=store.retryErasureCleanup();XCTAssertEqual(second.pendingMedia,0);XCTAssertTrue(second.warnings.isEmpty)
    }

    func testDotPathAliasKeepsSharedFileUntilLastReferenceIsErased() throws {
        let file=root.appendingPathComponent("images/alias");try Data([3]).write(to:file)
        try add("selected",path:"images/alias");try add("keep",app:"Notes",path:"images/./alias")
        let first=try erase(.init(app:"Safari"));XCTAssertEqual(first.sharedMedia,1);XCTAssertEqual(first.removedMedia,0);XCTAssertEqual(try Data(contentsOf:file),Data([3]))
        XCTAssertEqual(try erase(.init(app:"Notes")).removedMedia,1);XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testCaseAliasOnInsensitiveVolumeKeepsSharedFile() throws {
        let file=root.appendingPathComponent("images/MiXeD");try Data([4]).write(to:file)
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("images/mixed").path) else {throw XCTSkip("Volume is case sensitive")}
        try add("selected",path:"images/MiXeD");try add("keep",app:"Notes",path:"images/mixed")
        let first=try erase(.init(app:"Safari"));XCTAssertEqual(first.sharedMedia,1);XCTAssertEqual(first.removedMedia,0);XCTAssertEqual(try Data(contentsOf:file),Data([4]))
        XCTAssertEqual(try erase(.init(app:"Notes")).removedMedia,1)
    }

    func testSeparateHardLinkEntryCanBeRemovedWithoutDeletingOtherEntry() throws {
        let selected=root.appendingPathComponent("images/selected"),keep=root.appendingPathComponent("images/keep")
        try Data([5]).write(to:selected);try FileManager.default.linkItem(at:selected,to:keep)
        try add("selected",path:"images/selected");try add("keep",app:"Notes",path:"images/keep")
        let result=try erase(.init(app:"Safari"));XCTAssertEqual(result.removedMedia,1);XCTAssertEqual(result.sharedMedia,0);XCTAssertFalse(FileManager.default.fileExists(atPath:selected.path));XCTAssertEqual(try Data(contentsOf:keep),Data([5]))
    }

}
