import XCTest
import CSQLite
@testable import OSwindCore

private final class TagInstallationGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"owned tag backfill prepared")
    private let condition=NSCondition()
    private var released=false,didEnter=false
    func wait() {
        condition.lock();defer {condition.unlock()};guard !didEnter else {return};didEnter=true;entered.fulfill()
        let deadline=Date().addingTimeInterval(10)
        while !released {if !condition.wait(until:deadline) {break}}
    }
    func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
}

final class TagIndexTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-tags-"+UUID().uuidString);store=try MemoryStore(root:root.appendingPathComponent("library"))}
    override func tearDownWithError() throws {try? store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func sql(_ value:String) throws {try store.withRoutineDatabase {try $0.execute(value)}}
    func scalar(_ value:String) throws -> String {try store.withRoutineDatabase {db in let row=try db.statement(value);defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return db.text(row,0)}}
    func add(_ id:String="owned",tags:[String]=["release"],app:String="Notes",kind:MemoryKind = .note,favorite:Bool=false) throws {
        try store.insert(Memory(id:id,timestamp:try QueryScopeResolver.instant("2024-03-10T12:00:00Z"),kind:kind,app:app,text:"Owned quartz source",favorite:favorite,tags:tags))
    }
    func aligned(file:StaticString=#filePath,line:UInt=#line) throws {
        let columns="memory_id,tag,timestamp,app,kind,favorite",oracle="SELECT DISTINCT m.id,t.value,m.timestamp,m.app,m.kind,m.favorite FROM memories m,json_each(CAST(m.payload AS TEXT),'$.tags') t WHERE t.type='text'"
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM (SELECT \(columns) FROM memory_tags EXCEPT \(oracle))"),"0",file:file,line:line)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM (\(oracle) EXCEPT SELECT \(columns) FROM memory_tags)"),"0",file:file,line:line)
    }
    func testExactTagsDuplicatesEmptyUnicodeAndSQLCharacters() throws {
        let tags=["release","release","Release","","é","e\u{301}","x'); DROP TABLE memories; --"]
        try add(tags:tags);try aligned();XCTAssertEqual(try scalar("SELECT COUNT(*) FROM memory_tags"),"6")
        for tag in tags {XCTAssertEqual(try store.matchingCount(SearchFilter(tag:tag)),1)}
        XCTAssertEqual(try store.matchingCount(SearchFilter(tag:"RELEASE")),0)
        XCTAssertEqual(try store.search(SearchFilter(query:"quartz",tag:tags.last),mode:.keyword).map(\.id),["owned"])
    }
    func testMetadataSourceReplacementDeleteAndIdentifierReuseStayAligned() throws {
        try add(favorite:true);try store.setTags("owned",tags:["work","review","work"]);try aligned()
        try store.setFavorite("owned",value:false);var source=try XCTUnwrap(store.get("owned"));source.timestamp=source.timestamp.addingTimeInterval(86400);source.app="Editor";source.kind = .screen;try store.insert(source);try aligned()
        XCTAssertEqual(try store.activityCalendar(.init(month:"2024-03",filter:SearchFilter(app:"Editor",kind:.screen,tag:"work"))).days[10].sources,1)
        try store.delete("owned");try aligned();XCTAssertEqual(try scalar("SELECT COUNT(*) FROM memory_tags"),"0")
        try add(tags:["new"]);XCTAssertEqual(try store.matchingCount(.init(tag:"work")),0);try aligned()
        try store.deleteAll();XCTAssertEqual(try scalar("SELECT COUNT(*) FROM memory_tags"),"0");try aligned()
    }
    func testRollbackAndFailedImportCannotPublishTagRows() throws {
        try add();XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {try self.add("temporary",tags:["not-committed"]);throw CancellationError()}})
        let input=root.appendingPathComponent("invalid.json");try JSONEncoder().encode([Memory(id:"temporary",text:"Owned",tags:["discard"]),Memory(id:"",text:"Invalid")]).write(to:input)
        XCTAssertThrowsError(try store.importJSON(from:input));XCTAssertEqual(try store.matchingCount(.init(tag:"discard")),0);XCTAssertEqual(try scalar("SELECT COUNT(*) FROM memory_tags"),"1");try aligned()
    }
    func testIndependentConcurrentWritersAndExternalDeletesMaintainProjection() throws {
        let writers=try (0..<4).map {_ in try MemoryStore(root:store.root)},lock=NSLock();var failures=[String]()
        defer {writers.forEach {try? $0.close()}}
        DispatchQueue.concurrentPerform(iterations:4) {worker in
            do {for i in 0..<25 {let id="w\(worker)-\(i)";try writers[worker].insert(Memory(id:id,app:"App \(worker)",text:"Owned",tags:["work","\(worker)"]));try writers[worker].setFavorite(id,value:true);if i%3==0 {try writers[worker].setTags(id,tags:["revised"])}}}
            catch {lock.lock();failures.append(error.localizedDescription);lock.unlock()}
        }
        XCTAssertTrue(failures.isEmpty,failures.joined(separator:"; "));try aligned()
        try sql("PRAGMA foreign_keys=OFF; DELETE FROM memories WHERE app='App 0'; PRAGMA foreign_keys=ON");try aligned()
    }
    func testSchema20UpgradePreservesSourcesVectorsChatAndIdentity() throws {
        try add();let before=try store.get("owned"),identity=try scalar("SELECT value FROM store_metadata WHERE key='identity'")
        _=try store.saveVectors([VectorRecord(memory:try XCTUnwrap(before),vector:[1,0])],modelID:"fixture")
        let chat=try store.createChat();_=try store.appendChatTurn(sessionID:chat.id,question:"What?",answer:Answer(text:"Owned [1]",sources:[SearchHit(memory:try XCTUnwrap(before),score:1,match:"fixture")],provider:"fixture",duration:0))
        try removeProjection();try store.close();store=try MemoryStore(root:store.root)
        XCTAssertEqual(try store.get("owned"),before);XCTAssertEqual(try scalar("PRAGMA user_version"),"20");XCTAssertEqual(try scalar("SELECT value FROM store_metadata WHERE key='identity'"),identity)
        XCTAssertEqual(try store.vectorCount(modelID:"fixture"),1);XCTAssertEqual(try store.chatTurns(chat.id).count,1);try aligned()
    }
    func removeProjection() throws {
        try sql("DROP TRIGGER tag_index_insert; DROP TRIGGER tag_index_delete; DROP TRIGGER tag_index_update; DROP TABLE memory_tags; DELETE FROM store_metadata WHERE key='tag_index_version'; DROP INDEX memories_activity_time")
    }
    func testMissingReadinessOrChangedTriggerRebuildsFromAuthoritativePayload() throws {
        try add();try sql("DELETE FROM memory_tags; DELETE FROM store_metadata WHERE key='tag_index_version'");try store.close();store=try MemoryStore(root:store.root);try aligned()
        try sql("DROP TRIGGER tag_index_update; CREATE TRIGGER tag_index_update AFTER UPDATE ON memories BEGIN SELECT 1; END; DELETE FROM memory_tags")
        try store.close();store=try MemoryStore(root:store.root);try aligned();XCTAssertEqual(try scalar("SELECT sql FROM sqlite_master WHERE name='tag_index_update'"),TagIndexSchema.triggers["tag_index_update"])
    }
    func testCurrentInstallationDoesNotRebuildOrMutateOnReopen() throws {
        try add();try store.withRoutineDatabase {db in let changes=sqlite3_total_changes64(db.handle);try db.transaction {try TagIndexSchema.install(db)};XCTAssertEqual(sqlite3_total_changes64(db.handle),changes)}
        try store.close();store=try MemoryStore(root:store.root);try aligned()
    }
    func testTagAndCombinedCalendarAndCountNeverReadSourcePayloadOrText() throws {
        try add(app:"Notes",kind:.screen,favorite:true)
        _=try store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,{_,action,table,column,_,_ in
            if action==SQLITE_READ,let table,let column,String(cString:table)=="memories",["text","payload","embedding","embedding_model"].contains(String(cString:column)) {return SQLITE_DENY};return SQLITE_OK
        },nil)}
        defer {_=try? store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)}}
        for tag in [String?.none,"release"] {
            let filter=SearchFilter(app:"Notes",kind:.screen,favoritesOnly:true,tag:tag)
            XCTAssertEqual(try store.activityCalendar(.init(month:"2024-03",filter:filter)).totalSources,1);XCTAssertEqual(try store.matchingCount(filter),1)
        }
    }
    func testTaggedCalendarCannotReadTheSourceTableAtAll() throws {
        try add(app:"Notes",kind:.screen,favorite:true)
        _=try store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,{_,action,table,_,_,_ in
            if action==SQLITE_READ,let table,String(cString:table)=="memories" {return SQLITE_DENY};return SQLITE_OK
        },nil)}
        defer {_=try? store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)}}
        let request=ActivityCalendarRequest(month:"2024-03",timeZone:TimeZone(identifier:"America/New_York")!,selectedDay:"2024-03-10",filter:.init(app:"Notes",kind:.screen,favoritesOnly:true,tag:"release"))
        let value=try store.activityCalendar(request);XCTAssertEqual(value.totalSources,1);XCTAssertEqual(value.hours.reduce(0){$0+$1.sources},1)
    }
    func testRestoreRebuildsTagsInsteadOfTrustingArchivedProjection() throws {
        try add();try sql("UPDATE memory_tags SET tag='poisoned-cache'")
        let backup=root.appendingPathComponent("Owned.oswindbackup"),destination=root.appendingPathComponent("restored")
        _=try LibraryBackup.create(store:store,destination:backup)
        _=try LibraryBackup.restore(backup,to:destination)
        let restored=try MemoryStore(root:destination);defer {try? restored.close()}
        XCTAssertEqual(try restored.matchingCount(.init(tag:"release")),1);XCTAssertEqual(try restored.matchingCount(.init(tag:"poisoned-cache")),0)
        XCTAssertEqual(try restored.activityCalendar(.init(month:"2024-03",filter:.init(tag:"release"))).totalSources,1)
    }
    func testCancelledInstallationRollsBackCacheAndReadinessBeforeRetry() async throws {
        try add();try removeProjection();let gate=TagInstallationGate(),store=self.store!
        _=try store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,{pointer,action,table,_,_,_ in
            if action==SQLITE_INSERT,let table,String(cString:table)=="memory_tags",let pointer {Unmanaged<TagInstallationGate>.fromOpaque(pointer).takeUnretainedValue().wait()};return SQLITE_OK
        },Unmanaged.passUnretained(gate).toOpaque())}
        let job=Task.detached {try store.withRoutineDatabase {db in try db.transaction {try TagIndexSchema.install(db)}}}
        await fulfillment(of:[gate.entered],timeout:5);job.cancel();gate.release()
        do {_=try await job.value;XCTFail("Cancelled installation published")}catch is CancellationError {}catch {XCTFail("Unexpected \(error)")}
        _=try store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)}
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='memory_tags'"),"0");XCTAssertEqual(try scalar("SELECT COUNT(*) FROM store_metadata WHERE key='tag_index_version'"),"0")
        try store.withRoutineDatabase {db in try db.transaction {try TagIndexSchema.install(db)}};try aligned()
    }
}
