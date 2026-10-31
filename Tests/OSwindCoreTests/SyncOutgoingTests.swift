import XCTest
import CSQLite
@testable import OSwindCore

final class SyncOutgoingTests:XCTestCase {
    var root:URL!,store:MemoryStore!,queue:SyncOutgoingWorkQueue!,cache:SyncVersionStore!
    let replica="00000000-0000-0000-0000-000000000801",group="00000000-0000-0000-0000-000000000802",epoch="00000000-0000-0000-0000-000000000803"
    let now=Date(timeIntervalSince1970:1_792_700_000)
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-sync-outgoing-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store.close();store=nil;try FileManager.default.removeItem(at:root)}
    func install(budget:Int64=SyncOutgoingWorkQueue.defaultBudget)throws {
        try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);let c=try SyncIdentityCatalog.install(db),j=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
            cache=try SyncVersionStore.install(catalog:c,journal:j);queue=try SyncOutgoingWorkQueue.install(catalog:c,budget:budget)
        }
    }
    var processor:SyncOutgoingProcessor {.init(queue:queue,cache:cache,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []})}
    func seed(_ id:String="owned",_ text:String="Alice owns Orion.")throws {try store.insert(Memory(id:id,timestamp:now,kind:.note,app:"Owned",text:text))}
    func n(_ sql:String)throws->Int64 {try store.withRoutineDatabase {db in let row=try db.statement(sql);defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return sqlite3_column_int64(row,0)}}
    func sql(_ sql:String)throws {try store.withRoutineDatabase {try $0.execute(sql)}}
    func stage(limit:Int=1)throws {while try queue.stage(limit:limit)>0 {}}
    @discardableResult func finish(_ p:SyncOutgoingProcessor?=nil,limit:Int=1)throws->Int {
        var count=0;while count<300 {count+=1;if try (p ?? processor).step(limit:limit) == .idle {return count}}
        throw OSwindError.invalid("Owned outgoing fixture failed to become idle")
    }
    func frames()throws->[String:[Data]] {
        try store.withRoutineDatabase {db in var result=[String:[Data]]()
            for table in SyncCanonicalTable.allCases {let s=try db.statement("SELECT "+table.schema.snapshot("t")+" FROM "+table.rawValue+" t ORDER BY "+table.schema.primary.joined(separator:","));defer {sqlite3_finalize(s)};var rows=[Data](),code=sqlite3_step(s)
                while code==SQLITE_ROW {rows.append(Data(bytes:sqlite3_column_blob(s,0)!,count:Int(sqlite3_column_bytes(s,0))));code=sqlite3_step(s)};guard code==SQLITE_DONE else {throw db.error()};result[table.rawValue]=rows}
            return result
        }
    }
    func records()throws->[SyncPortableRecord] {try store.withRoutineDatabase {db in let row=try db.statement("SELECT body FROM personal_sync_versions ORDER BY object_digest,content_sha");defer {sqlite3_finalize(row)};var result=[SyncPortableRecord](),code=sqlite3_step(row)
        while code==SQLITE_ROW {result.append(try .decode(Data(bytes:sqlite3_column_blob(row,0)!,count:Int(sqlite3_column_bytes(row,0)))));code=sqlite3_step(row)};guard code==SQLITE_DONE else {throw db.error()};return result}}
    func seedGraph()throws {
        try seed();var sampled=Memory(id:"owned-samples",timestamp:now,endTimestamp:now.addingTimeInterval(2),kind:.screen,app:"Owned",text:"Owned sampled text",display:AccessibilityCaptureRecord.display)
        sampled.textObservation = .init(sessionID:"00000000-0000-0000-0000-000000000804",samples:2,largestGapSeconds:2);try store.insert(sampled);try store.withRoutineDatabase {try $0.pinTextObservation(sampled)}
        let project=try store.createEntity(kind:.project,name:"Orion",aliases:["Project Orion"]);try store.linkEntity(project.id,to:"owned")
        let person=try store.createEntity(kind:.person,name:"Alice");try store.unlinkEntity(person.id,from:"owned")
        let rejected=try store.createEntity(kind:.project,name:"Pluto");try store.unlinkEntity(rejected.id,from:"owned")
        let chat=try store.createChat(title:"Owned conversation"),memory=try XCTUnwrap(store.get("owned"))
        let answer=Answer(text:"Owned source-linked answer",sources:[SearchHit(memory:memory,score:1,match:"owned",passage:.init(start:0,length:5))],provider:"owned",duration:0,warnings:[])
        _=try store.appendChatTurn(sessionID:chat.id,question:"Owned graph question",answer:answer,filter:SearchFilter(entityID:project.id));_=try store.saveRecap(answer,title:"Owned recap")
        var recipe=RoutineDefinition();recipe.id="owned-recipe";recipe.title="Owned recipe";_=try store.saveRoutine(recipe,now:now)
        let run=try XCTUnwrap(store.claimRoutine(id:recipe.id,now:now));_=try store.finishRoutine(run.run.id,status:.failed,message:"Owned failure")
    }
    func testOrdinaryOpeningDoesNotInstallOrActivateOutgoingWork()throws {
        XCTAssertEqual(try n("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'personal_sync_work%'"),0);XCTAssertEqual(try n("SELECT enabled FROM personal_sync_capture"),0)
        XCTAssertEqual(MemoryStore.schemaVersion,26)
    }
    func testSplitSupersededCaptureCoalescesWithoutStagingBodiesOrRawKeys()throws {
        try install();try seed("private-local-key","authored sensitive first body");try seed("private-local-key","authored replacement body")
        XCTAssertEqual(try queue.stage(limit:1),1);XCTAssertThrowsError(try queue.process {_ in XCTFail("Raw intents remain")})
        XCTAssertEqual(try queue.stage(limit:1),1);XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1)
        XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_work_state"),192)
        try store.withRoutineDatabase {db in let row=try db.statement("SELECT name FROM pragma_table_info('personal_sync_work') ORDER BY cid");defer {sqlite3_finalize(row)};var columns=[String]();while sqlite3_step(row)==SQLITE_ROW {columns.append(db.text(row,0))};XCTAssertEqual(columns,["ordinal","object_digest","deleted","last_seq"])}
        _=try finish();let values=try records();XCTAssertEqual(values.count,1);guard case .source(let source)=values[0].body else {return XCTFail("Missing source")};XCTAssertEqual(source.text,"authored replacement body")
        XCTAssertFalse(String(data:try values[0].encoded(),encoding:.utf8)!.contains("private-local-key"))
    }
    func testDeleteRecreateAcrossThreeBatchesJournalsDistinctLifetimes()throws {
        try install();try seed();try stage();var old:SyncObjectIdentity!;try queue.process {old=$0[0].identity}
        // Put a baseline head without consuming the future delete/recreation.
        try seed();try stage();_=try finish();old=try XCTUnwrap(records().first?.identity)
        _=try store.delete("owned");try seed("owned","Restored source");try stage()
        var work=[SyncOutgoingWork]();XCTAssertThrowsError(try queue.process {work=$0;throw OSwindError.invalid("Owned inspect rollback")})
        XCTAssertEqual(work.count,2);XCTAssertTrue(work[0].deleted);XCTAssertEqual(work[0].identity,old);XCTAssertFalse(work[1].deleted);XCTAssertNotEqual(work[1].identity,old)
        _=try finish();XCTAssertTrue(try cache.journal.state(for:old.key).isDeleted);XCTAssertEqual(try records().count,1);XCTAssertEqual(try store.get("owned")?.text,"Restored source")
    }
    func testWorkBudgetFailureRollsBackAcknowledgementAndCanBeRaisedWithoutLoss()throws {
        try install(budget:192);try seed("a");try seed("b")
        XCTAssertThrowsError(try queue.stage(limit:2));XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_changes"),2);XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_identities"),0)
        XCTAssertEqual(try queue.stage(limit:1),1);XCTAssertThrowsError(try queue.stage(limit:1));XCTAssertThrowsError(try queue.setBudget(191))
        try queue.setBudget(384);try stage();XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_work_state"),384);_=try finish();XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_work_state"),0)
    }
    func testFailedConsumerRollsBackJournalAndWorkAcknowledgement()throws {
        try install();try seed();try stage()
        XCTAssertThrowsError(try queue.process {batch in _=try self.cache.journal.delete(key:batch[0].identity.key);throw OSwindError.invalid("Owned failure")})
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1);XCTAssertTrue(try cache.journal.outbox().isEmpty);_=try finish();XCTAssertEqual(try records().count,1)
    }
    func testIdentifiedWorkFencesPeerWritesAndDirectEchoSuppressionAfterRawQueueDrains()throws {
        try install();try seed();try stage();XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_changes"),0)
        let peer=try SyncObjectIdentity(table:.source,origin:group,lifetime:epoch)
        XCTAssertThrowsError(try queue.catalog.applyPeer(peer,primary:[.text(Data("peer".utf8))]) {try self.seed("peer")})
        XCTAssertThrowsError(try queue.catalog.deletePeer(peer) {_ in XCTFail("Staged work was bypassed")})
        XCTAssertThrowsError(try SyncChangeCapture.withoutEcho(queue.database,scope:queue.catalog.scope) {XCTFail("Staged work was bypassed")})
        XCTAssertNil(try store.get("peer"));_=try finish();try queue.catalog.deletePeer(peer) {_ in}
    }
    func testReentrantProcessorAndCanonicalMutationDuringConsumerRefuseAtomically()throws {
        try install();try seed();try stage()
        XCTAssertThrowsError(try queue.process {_ in _=try self.queue.stage()})
        var reached=false;XCTAssertThrowsError(try queue.process {_ in try self.sql("DELETE FROM memories WHERE id='owned'");reached=true})
        XCTAssertTrue(reached);XCTAssertNotNil(try store.get("owned"));XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1)
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_changes"),0)
    }
    func testStagingAndTypedPreparationSurviveRestartWithoutDuplicateJournalOutput()throws {
        try install();try seed();try stage();let before=try frames();try store.close();store=try MemoryStore(root:root);try install();_=try finish()
        XCTAssertEqual(try cache.journal.outbox().count,1);try store.close();store=try MemoryStore(root:root);try install();XCTAssertEqual(try processor.step(),.idle)
        XCTAssertEqual(try cache.journal.outbox().count,1);XCTAssertEqual(try frames(),before)
    }
    func testBootstrapPreexistingThirteenTableGraphResolvesDependenciesBeyondBatchAndPreservesFrames()throws {
        try seedGraph();let before=try frames();try install();_=try finish(limit:1)
        let all=try records();XCTAssertEqual(Set(all.map(\.identity.table)),Set(SyncCanonicalTable.allCases));XCTAssertEqual(try frames(),before)
        XCTAssertEqual(try cache.journal.outbox().count,all.count)
        for record in all {try record.validateDependencies {try self.cache.resolve($0,content:$1,admit:{_ in})}}
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_identity_bootstrap WHERE complete=1"),13)
        XCTAssertEqual(try processor.step(),.idle)
    }
    func testCapturedThirteenTableGraphProcessesInSingleRowBatchesWithAllDependencies()throws {
        try install();try seedGraph();let before=try frames();_=try finish(limit:1)
        let all=try records();XCTAssertEqual(Set(all.map(\.identity.table)),Set(SyncCanonicalTable.allCases));XCTAssertEqual(try frames(),before)
        XCTAssertEqual(try cache.journal.outbox().count,all.count)
        for record in all {try record.validateDependencies {try self.cache.resolve($0,content:$1,admit:{_ in})}}
    }
    func testCurrentPolicyRefusalKeepsWorkAndPublishesNoPartialDependencyGraph()throws {
        try seedGraph();try install();while true {let step=try processor.step(limit:1);if case .bootstrapped=step {break}}
        let denied=SyncOutgoingProcessor(queue:queue,cache:cache,admitRow:{_,_ in throw OSwindError.invalid("Owned policy denial")},admitVersion:{_ in},media:{_ in []})
        XCTAssertThrowsError(try denied.step(limit:1));XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1);XCTAssertTrue(try cache.journal.outbox().isEmpty)
        _=try finish();XCTAssertGreaterThan(try records().count,13)
    }
    func testLateVersionAdmissionErasureRollsBackGraphWorkJournalAndSource()throws {
        try seed();try install();_=try processor.step();var reached=false
        let denied=SyncOutgoingProcessor(queue:queue,cache:cache,admitRow:{_,_ in},admitVersion:{_ in if !reached {try self.sql("DELETE FROM memories WHERE id='owned'");reached=true}},media:{_ in []})
        XCTAssertThrowsError(try denied.step());XCTAssertTrue(reached);XCTAssertNotNil(try store.get("owned"));XCTAssertTrue(try cache.journal.outbox().isEmpty);XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1)
    }
    func testGraphObjectAndByteBudgetsRefuseWithoutAcknowledgingOrJournaling()throws {
        try seed();try install();_=try processor.step();var small=processor;small.maximumBytes=1
        XCTAssertThrowsError(try small.step());XCTAssertTrue(try cache.journal.outbox().isEmpty);XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1)
        _=try finish();try seedGraph();try stage();small=processor;small.maximumObjects=1
        XCTAssertThrowsError(try finish(small));XCTAssertGreaterThan(try n("SELECT COUNT(*) FROM personal_sync_work"),0)
        _=try finish()
    }
    func testSourceMediaCannotBeSilentlyOmittedByPreparationCallback()throws {
        var memory=Memory(id:"owned-media",kind:.screen,text:"Owned image");memory.imagePath="images/owned.png";try store.insert(memory);try install();_=try processor.step()
        XCTAssertThrowsError(try processor.step());XCTAssertTrue(try cache.journal.outbox().isEmpty);XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1)
    }
    func testMissingAndAlteredWorkProtectionRefuseWithoutRepairOrLosingSource()throws {
        try install();try seed();try stage();try sql("DROP TRIGGER sync_work_budget")
        XCTAssertThrowsError(try processor.step());XCTAssertThrowsError(try SyncOutgoingWorkQueue.install(catalog:queue.catalog));XCTAssertNotNil(try store.get("owned"));XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1)
    }
    func testGenerationChangeDuringAdmissionRefusesAndRollsBack()throws {
        try seed();try install();_=try processor.step();var reached=false
        let changed=SyncOutgoingProcessor(queue:queue,cache:cache,admitRow:{_,_ in try self.sql("UPDATE personal_sync_capture SET generation='00000000-0000-0000-0000-000000000899'");reached=true},admitVersion:{_ in},media:{_ in []})
        XCTAssertThrowsError(try changed.step());XCTAssertTrue(reached);XCTAssertEqual(try SyncChangeCapture.scope(queue.database),queue.catalog.scope);XCTAssertTrue(try cache.journal.outbox().isEmpty)
    }
    func testBootstrapCursorBehindNewSourceStillCapturesItExactlyOnce()throws {
        try seed("b");try seed("d");try install();XCTAssertEqual(try processor.step(limit:1),.bootstrapped(.source,1));_=try processor.step(limit:1)
        try seed("a");try seed("c");_=try finish(limit:1);let all=try records();XCTAssertEqual(all.count,4);XCTAssertEqual(try cache.journal.outbox().count,4)
    }
    func testUnicodeByteDistinctPrimaryKeysHaveSeparateTypedLifetimes()throws {
        try install();try seed("é","composed");try seed("e\u{301}","decomposed");_=try finish()
        XCTAssertEqual(try records().count,2);XCTAssertEqual(Set(try records().map {try $0.identity.key.digest}).count,2)
    }
    func testConcurrentHeadsRequireExplicitResolutionWithoutImplicitOutgoingOverwrite()throws {
        try seed();try install();_=try finish();let original=try XCTUnwrap(records().first),key=try original.identity.key
        try cache.journal.allowPeer(group)
        let remote=try SyncRevision(key:key,dot:.init(replica:group,counter:1),context:.empty,mutation:.put,content:.init(data:Data("authored remote body".utf8)))
        _=try cache.journal.receive(remote,contentAvailable:{_ in true});let conflict=try cache.journal.state(for:key);XCTAssertEqual(conflict.heads.count,2)
        _=try store.setFavorite("owned",value:true);try stage();let outbox=try cache.journal.outbox()
        XCTAssertThrowsError(try processor.step());XCTAssertEqual(try cache.journal.state(for:key),conflict);XCTAssertEqual(try cache.journal.outbox(),outbox);XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1)
    }
    func testKnownRunRecipeDefinitionRemainsOriginalAcrossLaterDefinitionAndStatusEdits()throws {
        var recipe=RoutineDefinition();recipe.id="owned-history";recipe.title="Owned history";recipe.prompt="Original definition"
        let first=try store.saveRoutine(recipe,now:now),run=try XCTUnwrap(store.claimRoutine(id:recipe.id,now:now));try install();_=try finish()
        let original=try XCTUnwrap(records().first {if case .routineRun=$0.body {return true};return false})
        guard case .routineRun(let old)=original.body else {return XCTFail("Missing run")};XCTAssertNotNil(old.recipe.definition)
        recipe.prompt="Later definition";_=try store.saveRoutine(recipe,expectedRevision:first.revision,now:now);_=try store.finishRoutine(run.run.id,status:.failed,message:"Later status")
        _=try finish();let changed=try XCTUnwrap(records().first {if case .routineRun=$0.body {return true};return false})
        guard case .routineRun(let current)=changed.body else {return XCTFail("Missing run")};XCTAssertEqual(current.recipe,old.recipe);XCTAssertEqual(current.message,"Later status")
        XCTAssertNotEqual(try cache.resolve(current.recipe.routine,content:nil,admit:{_ in}).reference.content,current.recipe.definition)
        XCTAssertNotNil(try cache.record(.init(identity:old.recipe.routine,content:XCTUnwrap(old.recipe.definition)),admit:{_ in}))
    }
    func testPreEnrollmentRunDoesNotMislabelCurrentRecipeAsHistoricalDefinition()throws {
        var recipe=RoutineDefinition();recipe.id="owned-prehistory";recipe.title="Owned prehistory";recipe.prompt="Unknown original"
        let first=try store.saveRoutine(recipe,now:now);_=try store.claimRoutine(id:recipe.id,now:now)
        recipe.prompt="Current before enrollment";_=try store.saveRoutine(recipe,expectedRevision:first.revision,now:now);try install();_=try finish()
        let run=try XCTUnwrap(records().first {if case .routineRun=$0.body {return true};return false})
        guard case .routineRun(let body)=run.body else {return XCTFail("Missing run")};XCTAssertEqual(body.recipe.ordinal,1);XCTAssertNil(body.recipe.definition)
    }
    func testCanonicalSourceCascadeIsPreparedBeforeReplacementWithoutStaleCitations()throws {
        try seedGraph();try install();_=try finish();let before=try records(),old=try XCTUnwrap(before.first {if case .source(let v)=$0.body {return v.text=="Alice owns Orion."};return false})
        _=try store.delete("owned");try seed("owned","Replacement after erasure");let after=try frames();_=try finish(limit:1)
        XCTAssertEqual(try frames(),after);XCTAssertTrue(try cache.journal.state(for:old.identity.key).isDeleted)
        XCTAssertFalse(try records().contains {$0.identity==old.identity});let current=try records()
        for record in current {XCTAssertFalse(record.dependencies.contains {$0.identity==old.identity});try record.validateDependencies {try self.cache.resolve($0,content:$1,admit:{_ in})}}
        XCTAssertEqual(try n("SELECT COUNT(*) FROM chat_sources"),0)
    }
    func testBodylessErasureDoesNotInvokePrivacyOrMediaReaders()throws {
        try install();try seed();_=try store.delete("owned");try stage()
        let erase=SyncOutgoingProcessor(queue:queue,cache:cache,admitRow:{_,_ in XCTFail("Deleted row was read")},admitVersion:{_ in XCTFail("Deleted body was read")},media:{_ in XCTFail("Deleted media was read");return []})
        XCTAssertEqual(try erase.step(),.prepared(1));XCTAssertEqual(try cache.journal.outbox().map(\.mutation),[.delete]);XCTAssertEqual(try records().count,0)
    }
    func testTwoConnectionsCannotApplyPeerBetweenStagingAndTypedAcknowledgement()throws {
        try install();try seed();try stage();let second=try MemoryStore(root:root);defer {try? second.close()}
        try second.withRoutineDatabase {db in let c=try SyncIdentityCatalog.install(db);_=try SyncOutgoingWorkQueue.install(catalog:c)
            XCTAssertThrowsError(try c.deletePeer(.init(table:.source,origin:group,lifetime:epoch)) {_ in XCTFail("Second connection bypassed local work")})}
        _=try finish();try second.withRoutineDatabase {db in let c=try SyncIdentityCatalog.install(db);try c.deletePeer(.init(table:.source,origin:group,lifetime:epoch)) {_ in}}
    }
    func testCyclicAuthoredCorruptRecapRefusesWithoutRecursionOrPartialJournal()throws {
        var memory=Memory(id:"owned-cycle",timestamp:now,kind:.summary,text:"Owned invalid recap")
        try store.insert(memory);memory.recap = .init(provider:"owned",sources:[.init(id:memory.id,revision:String(repeating:"a",count:64),match:"owned",score:1,passage:nil)])
        try store.withRoutineDatabase {db in let row=try db.statement("UPDATE memories SET payload=? WHERE id='owned-cycle'");defer {sqlite3_finalize(row)};let data=try JSONEncoder().encode(memory);data.withUnsafeBytes {_ = sqlite3_bind_blob(row,1,$0.baseAddress,Int32(data.count),db.transient)};try db.done(row)}
        try install();_=try processor.step();XCTAssertThrowsError(try processor.step());XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1);XCTAssertTrue(try cache.journal.outbox().isEmpty)
    }
    func testQuietBackupRestoresCanonicalSourcesWithoutPendingWorkOrSyncAuthority()throws {
        try seed();try install();_=try processor.step();XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),1)
        let nonce=UUID().uuidString,archive=root.deletingLastPathComponent().appendingPathComponent("owned-outgoing-"+nonce+".oswindbackup"),destination=root.deletingLastPathComponent().appendingPathComponent("owned-outgoing-restored-"+nonce)
        defer {try? FileManager.default.removeItem(at:archive);try? FileManager.default.removeItem(at:destination)}
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:destination)
        let copy=try MemoryStore(root:destination);defer {try? copy.close()};XCTAssertEqual(try copy.get("owned")?.text,"Alice owns Orion.")
        try copy.withRoutineDatabase {db in let row=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'personal_sync_work%' OR name='personal_sync_local'");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),0);XCTAssertNotEqual(try SyncChangeCapture.scope(db),queue.catalog.scope)}
    }
}
