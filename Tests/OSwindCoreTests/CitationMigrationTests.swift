import XCTest
import CryptoKit
import CSQLite
@testable import OSwindCore

final class CitationMigrationTests:XCTestCase {
    var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-citation-migration-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
    override func tearDownWithError()throws {try FileManager.default.removeItem(at:root)}
    func fixture(_ name:String="producer")throws {
        let expected=name=="producer" ? "166e2b8380f5b7091c60c8e48d32177d485489a795a3f032de2fdf59fa079527":"d65063d0f2934dbee488b21e83464d89b2c9316e31d3a5a4c919f655ea39b7a1"
        let source=try XCTUnwrap(Bundle.module.url(forResource:name+"-schema25",withExtension:"sqlite",subdirectory:"HistoricalCitationMigration")),data=try Data(contentsOf:source)
        XCTAssertEqual(SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined(),expected)
        try data.write(to:root.appendingPathComponent("memory.sqlite"),options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent("memory.sqlite").path)
    }
    func connection()throws->OpaquePointer {
        var handle:OpaquePointer?;guard sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&handle,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK,let handle else {throw OSwindError.database("Cannot open owned migration fixture")}
        let db=RoutineDatabase(handle:handle)
        do {try SyncRowSnapshot.register(on:db);try db.execute("PRAGMA foreign_keys=ON; PRAGMA recursive_triggers=ON; PRAGMA synchronous=FULL");return handle}
        catch {sqlite3_close(handle);throw error}
    }
    func withDB<T>(_ body:(RoutineDatabase)throws->T)throws->T {let handle=try connection();defer {sqlite3_close(handle)};return try body(RoutineDatabase(handle:handle))}
    func bytes(_ row:OpaquePointer,_ column:Int32)throws->Data {let n=Int(sqlite3_column_bytes(row,column));guard n>0,let p=sqlite3_column_blob(row,column) else {throw OSwindError.database("Missing owned migration bytes")};return Data(bytes:p,count:n)}
    func packets(_ db:RoutineDatabase)throws->[SyncPortableRecord] {
        let row=try db.statement("SELECT body FROM personal_sync_versions ORDER BY table_name,object_digest,content_sha");defer {sqlite3_finalize(row)};var values=[SyncPortableRecord](),code=sqlite3_step(row)
        while code==SQLITE_ROW {values.append(try .decode(bytes(row,0)));code=sqlite3_step(row)};guard code==SQLITE_DONE else {throw db.error()};return values
    }
    func cache(_ store:MemoryStore)throws->SyncVersionStore {
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT replica,group_id,epoch FROM personal_sync_local WHERE singleton=1");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()}
            let replica=db.text(row,0),group=db.text(row,1),epoch=db.text(row,2),catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
            return try .install(catalog:catalog,journal:journal)
        }
    }
    func fingerprint(_ db:RoutineDatabase)throws->[String:[Data]] {
        var result=[String:[Data]]()
        for (name,sql) in ["version":"SELECT CAST(user_version AS BLOB) FROM pragma_user_version","schema":"SELECT CAST(name||char(0)||COALESCE(sql,'') AS BLOB) FROM sqlite_master ORDER BY name","source":"SELECT payload FROM memories ORDER BY id","outbox":"SELECT revision FROM personal_sync_outbox ORDER BY sequence","packets":"SELECT body FROM personal_sync_versions ORDER BY object_digest,content_sha","pending":"SELECT oswind_sync_row_v1(seq,table_name,before_key,after_key,after_row,superseded) FROM personal_sync_changes ORDER BY seq","capture":"SELECT oswind_sync_row_v1(origin,generation,enabled,suppressed,used_bytes,budget) FROM personal_sync_capture","projection":"SELECT oswind_sync_row_v1(object_digest,content_sha,row_digest,evidence,entity_revision) FROM personal_sync_version_projection ORDER BY object_digest"] {
            let row=try db.statement(sql);defer {sqlite3_finalize(row)};var values=[Data](),code=sqlite3_step(row)
            while code==SQLITE_ROW {values.append(try bytes(row,0));code=sqlite3_step(row)};guard code==SQLITE_DONE else {throw db.error()};result[name]=values
        };return result
    }
    func replayHistoricalReceiver(_ store:MemoryStore,_ current:SyncVersionStore)throws {
        let admission=try store.mediaWriteLease();defer {admission.release()}
        let records=try store.withRoutineDatabase {try packets($0)},source=try XCTUnwrap(records.first {packet in if case .source(let body)=packet.body {return body.text=="Original Alice owns Orion."};return false})
        let writer=SyncIncomingConversationWriter(library:store,cache:current,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        for table in [SyncCanonicalTable.conversation,.turn,.conversationCitation,.evidencePin] {
            let packet=try XCTUnwrap(records.first {$0.identity.table==table});_=try writer.apply(packet,admission:admission,fetchExactSource:{ref in guard try source.reference==ref else {throw OSwindError.invalid("Unexpected owned original")};return source})
        }
    }
    func testActualSchema25GraphKeepsBodiesCurrentBindingsAndJournalThroughMigration()throws {
        try fixture();let before=try withDB {try fingerprint($0)},old=try withDB {try packets($0)};XCTAssertEqual(old.count,5)
        let store=try MemoryStore(root:root);defer {try? store.close()};let current=try cache(store)
        for packet in old {let resolved=try current.resolve(packet.identity,content:nil,admit:{_ in});XCTAssertEqual(try resolved.encoded(),try packet.encoded())}
        let after=try store.withRoutineDatabase {try fingerprint($0)}
        for key in ["source","outbox","packets","pending","capture"] {XCTAssertEqual(after[key],before[key],key)}
        XCTAssertEqual(try store.chatTurns(store.chats().first!.id).first?.answer.sources.first?.memory.text,"Original Alice owns Orion.")
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("PRAGMA user_version"),26);XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM pragma_table_info('chat_sources')"),9);XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM pragma_table_info('recap_sources')"),10)
            XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM personal_sync_changes"),0);XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM historical_evidence"),0)
            let fk=try db.statement("PRAGMA foreign_key_check");defer {sqlite3_finalize(fk)};XCTAssertEqual(sqlite3_step(fk),SQLITE_DONE)
        }
    }
    func testPendingLegacyCitationFrameSurvivesAndProcessesWithExactNewScore()throws {
        try fixture();let original=try withDB {db -> Data in try db.execute("UPDATE chat_sources SET score=score+0.125,passage_start=0,passage_length=8");let row=try db.statement("SELECT after_row FROM personal_sync_changes WHERE table_name='chat_sources' AND after_row IS NOT NULL");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return try bytes(row,0)}
        XCTAssertEqual(try SyncRowSnapshot.decode(original).cells.count,7)
        let store=try MemoryStore(root:root);defer {try? store.close()}
        let changed=try store.withRoutineDatabase {db -> Data in let row=try db.statement("SELECT after_row FROM personal_sync_changes WHERE table_name='chat_sources' AND after_row IS NOT NULL");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return try bytes(row,0)}
        let cells=try SyncRowSnapshot.decode(changed).cells;XCTAssertEqual(Array(cells.prefix(7)),try SyncRowSnapshot.decode(original).cells);XCTAssertEqual(Array(cells.suffix(2)),[.null,.null])
        let current=try cache(store),prior=try current.journal.outbox().count,processor=SyncOutgoingProcessor(queue:try .install(catalog:current.catalog),cache:current,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []})
        var finished=false;for _ in 0..<80 {if try processor.step() == .idle {finished=true;break}};XCTAssertTrue(finished);XCTAssertEqual(try current.journal.outbox().count,prior+1)
        let citation=try XCTUnwrap(store.withRoutineDatabase {try packets($0).first {$0.identity.table == .conversationCitation}})
        guard case .conversationCitation(let body)=citation.body else {return XCTFail("Missing migrated citation")};XCTAssertEqual(body.link.score,1.125);XCTAssertEqual(body.link.passage,.init(start:0,length:8))
        try store.withRoutineDatabase {XCTAssertEqual(try $0.eraseCount("SELECT COUNT(*) FROM personal_sync_changes"),0)}
    }
    func testFullLegacyQueueRefusesUpgradeWithoutLosingItsOriginalFrameOrBindings()throws {
        try fixture();let before=try withDB {db in try db.execute("UPDATE chat_sources SET score=score+0.125; UPDATE personal_sync_capture SET budget=used_bytes");return try fingerprint(db)}
        XCTAssertThrowsError(try MemoryStore(root:root));XCTAssertEqual(try withDB {try fingerprint($0)},before)
    }
    func testMissingLegacyCaptureProtectionRefusesRatherThanRepairingItDuringUpgrade()throws {
        try fixture();let before=try withDB {db in try db.execute("DROP TRIGGER sync_capture_chat_sources_insert");return try fingerprint(db)}
        XCTAssertThrowsError(try MemoryStore(root:root));XCTAssertEqual(try withDB {try fingerprint($0)},before)
    }
    func testAlreadyOpenOlderReaderCannotJoinHistoricalCitationToCurrentTextAndWriterRefuses()throws {
        try fixture("receiver");let older=try connection();defer {sqlite3_close(older)}
        XCTAssertEqual(sqlite3_create_function_v2(older,"oswind_historical_writer_v1",0,SQLITE_UTF8,nil,nil,nil,nil,nil),SQLITE_OK)
        let old=RoutineDatabase(handle:older);try old.execute("BEGIN IMMEDIATE; UPDATE memories SET favorite=favorite; ROLLBACK")
        let oldQuery=try old.statement("SELECT m.text FROM chat_sources s JOIN memories m ON m.id=s.memory_id");defer {sqlite3_finalize(oldQuery)}
        let store=try MemoryStore(root:root);defer {try? store.close()};let current=try cache(store);try replayHistoricalReceiver(store,current)
        XCTAssertEqual(try store.get("receiver-source")?.text,"Receiver current text");XCTAssertEqual(try store.chatTurns("receiver-chat").first?.answer.sources.first?.memory.text,"Original Alice owns Orion.")
        XCTAssertEqual(sqlite3_step(oldQuery),SQLITE_DONE,"The old compiled join must not substitute current source text")
        XCTAssertNotEqual(sqlite3_exec(older,"UPDATE memories SET favorite=1",nil,nil,nil),SQLITE_OK);XCTAssertTrue(String(cString:sqlite3_errmsg(older)).contains("oswind_historical_writer_v1"))
        XCTAssertEqual(try store.get("receiver-source")?.favorite,false)
    }
    func testMalformedLegacyPendingFrameRefusesWithoutPartialMigration()throws {
        try fixture();let before=try withDB {db in
            try db.execute("UPDATE chat_sources SET score=score+0.125")
            let data=try SyncRowSnapshot([.text(Data("owned invalid frame".utf8))]).encoded(),row=try db.statement("UPDATE personal_sync_changes SET after_row=? WHERE table_name='chat_sources'");defer {sqlite3_finalize(row)}
            data.withUnsafeBytes {_ = sqlite3_bind_blob(row,1,$0.baseAddress,Int32(data.count),db.transient)};try db.done(row);return try fingerprint(db)
        }
        XCTAssertThrowsError(try MemoryStore(root:root));XCTAssertEqual(try withDB {try fingerprint($0)},before)
    }
    func testExisting26CitationColumnsDoNotExcuseMissingForeignKeyProtection()throws {
        try fixture();let store=try MemoryStore(root:root);try store.close()
        let before=try withDB {db in
            let bad=CitationSchema.chat("chat_sources_bad").replacingOccurrences(of:"historical_handle TEXT REFERENCES historical_evidence(handle) ON DELETE CASCADE",with:"historical_handle TEXT")
            try db.execute("PRAGMA legacy_alter_table=ON")
            try db.execute(bad);try db.execute(CitationSchema.recap("recap_sources_same"))
            try db.execute("INSERT INTO chat_sources_bad SELECT * FROM chat_sources; INSERT INTO recap_sources_same SELECT * FROM recap_sources; DROP TABLE chat_sources; DROP TABLE recap_sources; ALTER TABLE chat_sources_bad RENAME TO chat_sources; ALTER TABLE recap_sources_same RENAME TO recap_sources; PRAGMA legacy_alter_table=OFF")
            for (name,sql) in HistoricalEvidenceStore.schemas where name.hasPrefix("historical_writer_chat_sources_") || name.hasPrefix("historical_writer_recap_sources_") {try db.execute(sql)}
            try SyncChangeCapture.install(on:db,sourceVersion:26,repairCitationUpgrade:true)
            try SyncVersionStore.repairCitationUpgradeTriggers(db)
            try TextObservationSchema.install(db,sourceVersion:26)
            return try fingerprint(db)
        }
        XCTAssertThrowsError(try MemoryStore(root:root)) {XCTAssertTrue(String(describing:$0).lowercased().contains("citation"))}
        XCTAssertEqual(try withDB {try fingerprint($0)},before)
    }
    func testColdPinRepairKeepsExactVersionAndLifetimeWithoutOutgoingEcho()throws {
        try fixture("receiver");var store=try MemoryStore(root:root);defer {try? store.close()};var current=try cache(store);try replayHistoricalReceiver(store,current)
        let pin=try current.catalog.localIdentity(.evidencePin,primary:[.text(Data("receiver-source".utf8))]),original=try current.resolve(pin,content:nil,admit:{_ in}),before=try current.journal.outbox()
        let handle=try XCTUnwrap(store.chatTurns("receiver-chat").first?.answer.sources.first?.memory.originalEvidence?.handle)
        try store.withRoutineDatabase {try $0.execute("DROP TABLE text_observation_pins")};try store.close();store=try MemoryStore(root:root);current=try cache(store)
        try assertCaptureAccounting(store)
        XCTAssertEqual(try current.catalog.localIdentity(.evidencePin,primary:[.text(Data("receiver-source".utf8))]),pin)
        XCTAssertEqual(try store.chatTurns("receiver-chat").first?.answer.sources.first?.memory.originalEvidence?.handle,handle)
        let processor=SyncOutgoingProcessor(queue:try .install(catalog:current.catalog),cache:current,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []})
        var done=false;for _ in 0..<80 {if try processor.step() == .idle {done=true;break}};XCTAssertTrue(done)
        XCTAssertEqual(try current.journal.outbox(),before);XCTAssertEqual(try current.resolve(pin,content:nil,admit:{_ in}).encoded(),try original.encoded())
    }

    func testColdPinRepairHonorsPendingDeleteAndRecreateInsteadOfResurrectingOldLifetime()throws {
        try fixture();var store=try MemoryStore(root:root);defer {try? store.close()};var current=try cache(store)
        let old=try current.catalog.localIdentity(.evidencePin,primary:[.text(Data("authored-source".utf8))]),count=try current.journal.outbox().count
        try store.withRoutineDatabase {try $0.execute("DELETE FROM text_observation_pins; INSERT INTO text_observation_pins VALUES('authored-source'); DROP TABLE text_observation_pins")}
        try store.close();store=try MemoryStore(root:root);current=try cache(store)
        try assertCaptureAccounting(store)
        let processor=SyncOutgoingProcessor(queue:try .install(catalog:current.catalog),cache:current,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []})
        var done=false;for _ in 0..<80 {if try processor.step() == .idle {done=true;break}};XCTAssertTrue(done)
        let replacement=try current.catalog.localIdentity(.evidencePin,primary:[.text(Data("authored-source".utf8))]);XCTAssertNotEqual(replacement,old)
        XCTAssertTrue(try current.journal.state(for:old.key).isDeleted);XCTAssertEqual(try current.journal.outbox().count,count+2)
    }
    func testColdPinRepairUsesQueuedInsertBeforeIdentityCatalogExists()throws {
        var store=try MemoryStore(root:root);defer {try? store.close()}
        let memory=Memory(id:"queued-source",timestamp:Date(timeIntervalSince1970:1700000000),kind:.note,text:"Owned queued pin")
        try store.insert(memory);try store.withRoutineDatabase {_=try SyncChangeCapture.activate($0)}
        let chat=try store.createChat();_=try store.appendChatTurn(sessionID:chat.id,question:"Owned question",answer:.init(text:"Owned answer",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0))
        try store.withRoutineDatabase {try $0.execute("DROP TABLE text_observation_pins")};try store.close();store=try MemoryStore(root:root)
        try assertCaptureAccounting(store)
        let current=try store.withRoutineDatabase {db in
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:"00000000-0000-0000-0000-000000001101",group:"00000000-0000-0000-0000-000000001102",epoch:"00000000-0000-0000-0000-000000001103")
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        }
        let processor=SyncOutgoingProcessor(queue:try .install(catalog:current.catalog),cache:current,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []})
        var done=false;for _ in 0..<80 {if try processor.step() == .idle {done=true;break}};XCTAssertTrue(done)
        XCTAssertEqual(try current.journal.outbox().filter {$0.key.kind == .evidencePin}.count,1)
        XCTAssertEqual(try store.chatTurns(chat.id).first?.answer.sources.first?.memory.text,memory.text)
    }
    func assertCaptureAccounting(_ store:MemoryStore,file:StaticString=#filePath,line:UInt=#line)throws {
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT used_bytes=(SELECT COALESCE(SUM(128+COALESCE(length(before_key),0)+COALESCE(length(after_key),0)+COALESCE(length(after_row),0)),0) FROM personal_sync_changes) FROM personal_sync_capture WHERE singleton=1"),1,file:file,line:line)
        }
    }

}
