import XCTest
import CSQLite
@testable import OSwindCore

private final class IdentityTestResults:@unchecked Sendable {
    private let lock=NSLock();private var identities=Set<String>();private var failed=0
    func record(_ values:[SyncIdentifiedChange]) {lock.lock();defer {lock.unlock()};for v in values {if let x=v.after,let key=try? x.key {if !identities.insert(key.digest).inserted {failed+=1}}}}
    func fail(){lock.lock();failed+=1;lock.unlock()}
    var result:(Int,Int) {lock.lock();defer {lock.unlock()};return(identities.count,failed)}
}
final class SyncIdentityCatalogTests:XCTestCase {
    let foreign="00000000-0000-0000-0000-000000000001",life="00000000-0000-0000-0000-000000000002"
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-sync-identities-"+UUID().uuidString);store=try MemoryStore(root:root)
        try store.withRoutineDatabase {db in _=try SyncChangeCapture.activate(db);_=try SyncIdentityCatalog.install(db)}
    }
    override func tearDownWithError()throws {try store.close();store=nil;try FileManager.default.removeItem(at:root)}
    func catalog<T>(_ body:(SyncIdentityCatalog)throws->T)throws->T {try store.withRoutineDatabase {db in try SyncChangeCapture.prepare(db);return try body(.init(database:db,scope:SyncChangeCapture.scope(db)))}}
    func primary(_ id:String)->[SyncRowCell] {[.text(Data(id.utf8))]}
    func peer(_ table:SyncCanonicalTable = .source,_ lifetime:String?=nil)throws->SyncObjectIdentity {try .init(table:table,origin:foreign,lifetime:lifetime ?? life)}
    func pending()throws->[SyncCapturedChange] {try store.withRoutineDatabase {try SyncChangeCapture.changes($0,scope:SyncChangeCapture.scope($0))}}
    func scalar(_ sql:String)throws->Int64 {try store.withRoutineDatabase {db in let s=try db.statement(sql);defer {sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_ROW else {throw db.error()};return sqlite3_column_int64(s,0)}}
    func drain()throws->[SyncIdentifiedChange] {var result=[SyncIdentifiedChange]();try catalog {_ = try $0.process(limit:256) {result=$0}};return result}
    func testAllThirteenTablesHaveDistinctCanonicalObjectKindsAndValidatedWireIdentity()throws {
        XCTAssertEqual(Set(SyncCanonicalTable.allCases.map(\.rawValue)),Set(SyncChangeCapture.tables.map(\.name)))
        XCTAssertEqual(Set(SyncCanonicalTable.allCases.map(\.kind)).count,13)
        let keys=try SyncCanonicalTable.allCases.map {try peer($0).key};XCTAssertEqual(Set(keys).count,13)
        let identity=try peer();XCTAssertEqual(try JSONDecoder().decode(SyncObjectIdentity.self,from:SyncProtocolLimits.encode(identity)),identity)
        XCTAssertThrowsError(try SyncObjectIdentity(table:.source,origin:"00000000-0000-0000-0000-00000000000A",lifetime:life))
        XCTAssertThrowsError(try SyncObjectIdentity(table:.source,origin:foreign,lifetime:"bad"))
        XCTAssertThrowsError(try JSONDecoder().decode(SyncObjectIdentity.self,from:Data("{\"table\":\"unknown\",\"origin\":\"\(foreign)\",\"lifetime\":\"\(life)\"}".utf8)))
    }
    func testSupersededSplitBatchesKeepOneLifetimeAndReopenRetainsRawPrimary()throws {
        var value=Memory(id:"owned\0source",text:"first");try store.insert(value);value.text="second";try store.insert(value)
        var first:SyncObjectIdentity!,second:SyncObjectIdentity!
        try catalog {c in XCTAssertEqual(try c.process(limit:1) {batch in XCTAssertTrue(batch[0].captured.superseded);XCTAssertNil(batch[0].captured.afterRow);first=batch[0].after},1)}
        try store.close();store=try MemoryStore(root:root)
        try catalog {c in XCTAssertEqual(try c.process {batch in second=batch[0].after;XCTAssertEqual(batch[0].before,first)},1);XCTAssertEqual(first,second);XCTAssertEqual(try c.object(second)?.primary,primary(value.id))}
        XCTAssertTrue(try pending().isEmpty);XCTAssertEqual(try scalar("SELECT used_bytes FROM personal_sync_capture"),0)
    }
    func testDeleteRecreateGetsFreshLifetimeAndLatePeerDeleteCannotTargetReplacement()throws {
        try store.insert(Memory(id:"reused",text:"old"));let old=try XCTUnwrap(drain().first?.after)
        try store.withRoutineDatabase {try $0.execute("DELETE FROM memories WHERE id='reused'")};try store.insert(Memory(id:"reused",text:"new"))
        let batch=try drain(),fresh=try XCTUnwrap(batch.last?.after);XCTAssertEqual(batch.first?.before,old);XCTAssertNotEqual(fresh,old)
        try catalog {c in XCTAssertTrue(try XCTUnwrap(c.object(old)).deleted);XCTAssertNil(try c.object(old)?.primary)
            try c.deletePeer(old) {XCTAssertNil($0)}
            XCTAssertThrowsError(try c.applyPeer(old,primary:primary("reused")) {XCTFail("Deleted lifetime admitted")})
            XCTAssertFalse(try XCTUnwrap(c.object(fresh)).deleted)
        }
        XCTAssertEqual(try store.get("reused")?.text,"new");XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identities WHERE deleted=1 AND key_frame IS NOT NULL"),0)
    }
    func testFailedConsumerRollsBackCatalogJournalSourceAndQueueAcknowledgement()throws {
        enum Stop:Error {case expected}
        let replica=UUID().uuidString.lowercased(),group=UUID().uuidString.lowercased(),epoch=UUID().uuidString.lowercased()
        try store.withRoutineDatabase {_=try SyncJournal.install(database:$0,replica:replica,group:group,epoch:epoch)}
        try store.insert(Memory(id:"kept",text:"source"));let before=try pending();var attempted:SyncObjectIdentity!
        XCTAssertThrowsError(try catalog {c in try c.process {batch in attempted=batch[0].after
            let journal=try SyncJournal(database:c.database,replica:replica,group:group,epoch:epoch)
            try journal.put(key:attempted.key,content:SyncContentReference(data:Data("authored typed content".utf8)))
            try store.insert(Memory(id:"rollback",text:"not committed"));throw Stop.expected
        }})
        XCTAssertEqual(try pending(),before);XCTAssertNil(try store.get("rollback"));XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identities"),0);XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_outbox"),0)
        let recovered=try drain();XCTAssertEqual(recovered.count,1);XCTAssertNotNil(recovered[0].after)
    }
    func testOuterRollbackAndReentrantProcessorDoNotAdvanceOrLoseIntents()throws {
        enum Stop:Error {case expected}
        try store.insert(Memory(id:"owned",text:"source"));let before=try pending()
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {
            let c=SyncIdentityCatalog(database:db,scope:try SyncChangeCapture.scope(db));try c.process {_ in};throw Stop.expected
        }})
        XCTAssertEqual(try pending(),before);XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identities"),0)
        try catalog {c in XCTAssertEqual(try c.process {_ in XCTAssertThrowsError(try c.process {_ in XCTFail("Reentrant callback")})},1)}
        XCTAssertTrue(try pending().isEmpty);XCTAssertEqual(try scalar("SELECT processing FROM personal_sync_identity_state"),0)
    }
    func testBootstrapUsesExactUnicodeAndNULKeysAndRefusesPendingMissingOrInvalidRows()throws {
        let ids=["e\u{301}","é","source\0suffix"]
        for id in ids {try store.insert(Memory(id:id,text:"authored \(id)"))}
        XCTAssertThrowsError(try catalog {try $0.registerExisting(.source,primary:primary(ids[0]))})
        _=try drain();var identities=[SyncObjectIdentity]()
        try catalog {c in
            for id in ids {let identity=try c.registerExisting(.source,primary:primary(id));identities.append(identity);XCTAssertEqual(try c.object(identity)?.primary,primary(id))}
            XCTAssertThrowsError(try c.registerExisting(.source,primary:primary("missing")))
            XCTAssertThrowsError(try c.registerExisting(.source,primary:[.null]))
            XCTAssertThrowsError(try c.registerExisting(.source,primary:[.text(Data())]))
            XCTAssertThrowsError(try c.registerExisting(.source,primary:[.text(Data(repeating:65,count:65537))]))
            XCTAssertThrowsError(try c.registerExisting(.source,primary:[.integer(1),.integer(2)]))
        }
        XCTAssertEqual(Set(try identities.map {try $0.key}).count,3)
    }
    func testPeerApplyIsAtomicSuppressesEchoAndLocalEditsKeepItsOrigin()throws {
        let identity=try peer()
        try catalog {c in try c.applyPeer(identity,primary:primary("imported")) {try store.insert(Memory(id:"imported",text:"remote authored source"))}}
        XCTAssertTrue(try pending().isEmpty)
        var value=try XCTUnwrap(store.get("imported"));value.text="local edit";try store.insert(value)
        let change=try XCTUnwrap(drain().first);XCTAssertEqual(change.before,identity);XCTAssertEqual(change.after,identity)
        try catalog {c in try c.deletePeer(identity) {mapping in XCTAssertEqual(mapping?.primary,primary("imported"));try c.database.execute("DELETE FROM memories WHERE id='imported'")}}
        XCTAssertNil(try store.get("imported"));XCTAssertTrue(try pending().isEmpty)
    }
    func testFailedPeerAdapterAndMissingSourceCannotPublishMappingOrPartialData()throws {
        enum Stop:Error {case expected}
        let identity=try peer()
        XCTAssertThrowsError(try catalog {c in try c.applyPeer(identity,primary:primary("owned")) {try store.insert(Memory(id:"owned",text:"rollback"));throw Stop.expected}})
        XCTAssertNil(try store.get("owned"));XCTAssertTrue(try pending().isEmpty)
        try catalog {c in XCTAssertNil(try c.object(identity));XCTAssertThrowsError(try c.applyPeer(identity,primary:primary("owned")) {});XCTAssertNil(try c.object(identity))}
        XCTAssertEqual(try scalar("SELECT suppressed FROM personal_sync_capture"),0)
    }
    func testUnknownEarlyDeletePersistsAndCannotResurrectButNewLifetimeCanUseTheLocalKey()throws {
        let old=try peer(),fresh=try peer(.source,UUID().uuidString.lowercased())
        try catalog {c in try c.deletePeer(old) {XCTAssertNil($0)}}
        try store.close();store=try MemoryStore(root:root)
        try catalog {c in
            XCTAssertThrowsError(try c.applyPeer(old,primary:primary("local")) {XCTFail("Early tombstone resurrected")})
            try c.applyPeer(fresh,primary:primary("local")) {try store.insert(Memory(id:"local",text:"new lifetime"))}
            try c.deletePeer(old) {XCTAssertNil($0)}
            XCTAssertTrue(try XCTUnwrap(c.object(old)).deleted);XCTAssertFalse(try XCTUnwrap(c.object(fresh)).deleted)
        }
        XCTAssertEqual(try store.get("local")?.text,"new lifetime")
    }
    func testPeerIdentityAndLocalKeyCollisionsRefuseBeforeCallingAdapter()throws {
        let identity=try peer(),other=try peer(.source,UUID().uuidString.lowercased())
        try catalog {c in try c.applyPeer(identity,primary:primary("owned")) {try store.insert(Memory(id:"owned",text:"first"))}
            XCTAssertThrowsError(try c.applyPeer(identity,primary:primary("other")) {XCTFail("Global object remapped")})
            XCTAssertThrowsError(try c.applyPeer(other,primary:primary("owned")) {XCTFail("Live local object overwritten")})
            XCTAssertThrowsError(try c.applyPeer(peer(.conversation),primary:primary("session")) {XCTFail("Origin/lifetime reused across tables")})
        }
        XCTAssertEqual(try store.get("owned")?.text,"first");XCTAssertNil(try store.get("other"));XCTAssertTrue(try pending().isEmpty)
    }
    func testFailedPeerDeleteKeepsMappingSourceAndRawKeyUntilSuccessfulRetry()throws {
        let identity=try peer()
        try catalog {c in try c.applyPeer(identity,primary:primary("owned")) {try store.insert(Memory(id:"owned",text:"source"))}
            XCTAssertThrowsError(try c.deletePeer(identity) {_ in})
            XCTAssertFalse(try XCTUnwrap(c.object(identity)).deleted);XCTAssertNotNil(try c.object(identity)?.primary)
        }
        XCTAssertNotNil(try store.get("owned"));XCTAssertTrue(try pending().isEmpty)
    }
    func testLocalPrimaryKeyMoveRetiresTheOldLifetimeAndMapsTheNewKey()throws {
        try store.withRoutineDatabase {try $0.execute("INSERT INTO chat_sessions VALUES('old','owned',1,1)")};let old=try XCTUnwrap(drain().first?.after)
        try store.withRoutineDatabase {try $0.execute("UPDATE chat_sessions SET id='new' WHERE id='old'")}
        let change=try XCTUnwrap(drain().first);XCTAssertEqual(change.before,old);XCTAssertNotEqual(change.after,old)
        try catalog {c in XCTAssertTrue(try XCTUnwrap(c.object(old)).deleted);XCTAssertEqual(try c.object(XCTUnwrap(change.after))?.primary,primary("new"))}
    }
    func testActualCapturedRowsAcrossAllTablesMapCompositeKeysAndCascadeTombstones()throws {
        // Authored structural rows exercise local identity mapping, not typed peer admission.
        for id in ["source","summary"] {try store.insert(Memory(id:id,kind:id=="summary" ? .summary:.note,text:"authored structural source"))}
        try store.withRoutineDatabase {db in try db.transaction {try db.execute("""
        INSERT INTO chat_sessions VALUES('session','authored title',1,1);
        INSERT INTO chat_turns VALUES('turn','session',1,x'7b7d');
        INSERT INTO chat_sources(turn_id,memory_id,ordinal,score,match,passage_start,passage_length) VALUES('turn','source',0,1,'fixture',NULL,NULL),('turn','summary',2,1,'fixture',NULL,NULL),('turn','source',10,1,'fixture',NULL,NULL);
        INSERT INTO recap_sources(recap_id,source_id,ordinal,revision,score,match,passage_start,passage_length) VALUES('summary','source',0,'fixture-revision',1,'fixture',NULL,NULL);
        INSERT INTO routines VALUES('routine',1,0,1,x'7b7d');
        INSERT INTO routine_runs VALUES('run','routine',1,1,1,2,'manual','completed','session',NULL,x'7b7d');
        INSERT INTO memory_entities VALUES('entity','project','Authored entity','',1,1);
        INSERT INTO entity_aliases VALUES('entity','project','authored','Authored'),('entity','project','next','Next');
        INSERT INTO entity_mentions VALUES('source','entity','manual','fixture-revision',-1,0,'','manual');
        INSERT INTO entity_ignored VALUES('source','person','ignored');
        INSERT INTO entity_project_ignored VALUES('source','entity');
        """)}}
        let inserted=try drain();XCTAssertEqual(Set(inserted.map {$0.captured.table}),Set(SyncCanonicalTable.allCases.map(\.rawValue)))
        try catalog {c in for value in inserted {if let identity=value.after,let frame=value.captured.afterRow {
            let cells=try SyncRowSnapshot.decode(frame).cells,table=identity.table.schema
            XCTAssertEqual(try c.object(identity)?.primary,table.primary.map {cells[table.columns.firstIndex(of:$0)!]})
        }}}
        var bootstrapCount=0
        try catalog {c in for table in SyncCanonicalTable.allCases {
            while try !c.bootstrap(table,limit:1,consume:{batch in
                for value in batch {XCTAssertEqual(try c.object(value.identity)?.primary,value.primary);XCTAssertTrue(inserted.contains {$0.after==value.identity});bootstrapCount+=1}
            }).complete {}
        }}
        XCTAssertEqual(Int64(bootstrapCount),try scalar("SELECT COUNT(*) FROM personal_sync_identities"))
        try store.withRoutineDatabase {db in try db.transaction {try db.execute("DELETE FROM memories; DELETE FROM chat_sessions; DELETE FROM routines; DELETE FROM memory_entities")}}
        let deleted=try drain();XCTAssertEqual(Set(deleted.compactMap {$0.before?.table}),Set(SyncCanonicalTable.allCases))
        try catalog {c in for value in deleted {if let identity=value.before {XCTAssertTrue(try XCTUnwrap(c.object(identity)).deleted);XCTAssertNil(try c.object(identity)?.primary)}}}
    }
    func testScopeDurabilityAndTamperedCurrentMappingRefuseWithoutAcknowledging()throws {
        for id in ["first","second"] {try store.insert(Memory(id:id,text:id))};let values=try drain()
        let first=try XCTUnwrap(values.first?.after),second=try XCTUnwrap(values.last?.after)
        try store.withRoutineDatabase {db in
            try db.execute("UPDATE personal_sync_identity_current SET object_digest='\(try second.key.digest)' WHERE object_digest='\(try first.key.digest)'")
        }
        var value=try XCTUnwrap(store.get("first"));value.text="update";try store.insert(value);let pendingBefore=try pending()
        XCTAssertThrowsError(try drain());XCTAssertEqual(try pending(),pendingBefore)
        try store.withRoutineDatabase {db in let c=SyncIdentityCatalog(database:db,scope:try SyncChangeCapture.scope(db));try db.execute("PRAGMA synchronous=NORMAL");XCTAssertThrowsError(try c.process {_ in});try SyncChangeCapture.prepare(db)
            try db.execute("UPDATE personal_sync_identity_state SET generation='\(UUID().uuidString.lowercased())'");XCTAssertThrowsError(try c.object(first))
        }
    }
    func testUnknownWireDeletionUsesSameTransactionJournalBarrierWithoutIdentityMetadata()throws {
        let replica=UUID().uuidString.lowercased(),group=UUID().uuidString.lowercased(),epoch=UUID().uuidString.lowercased(),old=try peer()
        let content=try SyncContentReference(data:Data("missing old body".utf8))
        let put=try SyncRevision(key:old.key,dot:.init(replica:foreign,counter:1),context:.empty,mutation:.put,content:content)
        let deletion=try SyncRevision(key:old.key,dot:.init(replica:foreign,counter:2),context:.init([foreign:1]),mutation:.delete)
        try store.withRoutineDatabase {db in
            let j=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch),c=SyncIdentityCatalog(database:db,scope:try SyncChangeCapture.scope(db));try j.allowPeer(foreign)
            XCTAssertThrowsError(try c.deletePeerKey(old.key,journal:j) {_ in XCTFail("No deletion barrier")})
            let early=try j.receive(deletion,contentAvailable:{_ in false}) {change in
                XCTAssertTrue(change.after.isDeleted);try c.deletePeerKey(change.revision.key,journal:j) {XCTAssertNil($0)}
            };XCTAssertEqual(early.applied,0)
            XCTAssertEqual(try j.receive(put,contentAvailable:{_ in XCTFail("Deleted body was requested");return false}) {change in
                XCTAssertTrue(change.after.isDeleted);try c.deletePeerKey(change.revision.key,journal:j) {XCTAssertNil($0)}
            }.applied,2)
            XCTAssertTrue(try j.state(for:old.key).isDeleted);XCTAssertNil(try c.object(old))
        }
        try store.close();store=try MemoryStore(root:root)
        try catalog {c in let j=try SyncJournal(database:c.database,replica:replica,group:group,epoch:epoch)
            XCTAssertFalse(try j.receive(put,contentAvailable:{_ in true}) {_ in XCTFail("Duplicate resurrected source")}.inserted)
            let fresh=try peer(.source,UUID().uuidString.lowercased()),reference=try SyncContentReference(data:Data("new source".utf8))
            let next=try SyncRevision(key:fresh.key,dot:.init(replica:foreign,counter:3),context:.empty,mutation:.put,content:reference)
            XCTAssertEqual(try j.receive(next,contentAvailable:{_ in true}) {change in
                XCTAssertEqual(change.revision.key,try fresh.key);try c.applyPeer(fresh,primary:primary("imported")) {try store.insert(Memory(id:"imported",text:"new lifetime"))}
            }.applied,1)
        }
        XCTAssertEqual(try store.get("imported")?.text,"new lifetime");XCTAssertTrue(try pending().isEmpty)
    }
    func testMissingOrChangedCatalogSchemaRefusesWithoutRepairOrQueueAcknowledgement()throws {
        try store.insert(Memory(id:"owned",text:"unchanged source"));let before=try pending()
        try store.withRoutineDatabase {db in
            let c=SyncIdentityCatalog(database:db,scope:try SyncChangeCapture.scope(db))
            try db.execute("DROP TABLE personal_sync_identity_current; CREATE TABLE personal_sync_identity_current(table_name TEXT,local_key BLOB,object_digest TEXT)")
            XCTAssertThrowsError(try c.process {_ in XCTFail("Changed schema admitted")})
            XCTAssertThrowsError(try SyncIdentityCatalog.install(db))
        }
        XCTAssertEqual(try pending(),before);XCTAssertEqual(try store.get("owned")?.text,"unchanged source")
    }
    func testDisabledForeignKeysCannotConsumeOrBootstrapAnIdentity()throws {
        try store.insert(Memory(id:"owned",text:"source"));let before=try pending()
        try store.withRoutineDatabase {db in
            let c=SyncIdentityCatalog(database:db,scope:try SyncChangeCapture.scope(db));try db.execute("PRAGMA foreign_keys=OFF")
            XCTAssertThrowsError(try c.process {_ in XCTFail("Unprepared foreign-key connection admitted")});try db.execute("PRAGMA foreign_keys=ON")
        }
        XCTAssertEqual(try pending(),before);XCTAssertEqual(try drain().count,1)
    }
    func existing(_ ids:[String])throws {
        try store.withRoutineDatabase {try $0.execute("UPDATE personal_sync_capture SET enabled=0")}
        for id in ids {try store.insert(Memory(id:id,text:"existing authored source"))}
        try store.withRoutineDatabase {_=try SyncChangeCapture.activate($0)}
        XCTAssertTrue(try pending().isEmpty)
    }
    func testBootstrapResumesBoundedByteExactKeysetsAfterReopenAndClearsCompletedCursor()throws {
        let ids=["b","a","e\u{301}","é","c","nul\0suffix","z"]
        try existing(ids);XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identities"),0)
        var keys=[Data](),identities=[SyncObjectIdentity]()
        try catalog {c in let result=try c.bootstrap(.source,limit:2) {batch in keys += batch.map {if case .text(let bytes)=$0.primary[0] {return bytes};return Data()};identities += batch.map(\.identity)};XCTAssertEqual(result,.init(objects:2,complete:false))}
        try store.close();store=try MemoryStore(root:root)
        try catalog {c in while try !c.bootstrap(.source,limit:2,consume:{batch in keys += batch.map {if case .text(let bytes)=$0.primary[0] {return bytes};return Data()};identities += batch.map(\.identity)}).complete {}}
        XCTAssertEqual(keys,ids.map {Data($0.utf8)}.sorted {$0.lexicographicallyPrecedes($1)});XCTAssertEqual(Set(try identities.map {try $0.key}).count,ids.count)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identity_bootstrap WHERE complete=1 AND next_key IS NULL AND cursor_key IS NULL"),1)
        try catalog {c in XCTAssertEqual(try c.bootstrap(.source) {_ in XCTFail("Completed bootstrap ran again")},.init(objects:0,complete:true))}
    }
    func testBootstrapByteLimitAndFailureRollBackEveryIdentityAndCursor()throws {
        enum Stop:Error {case expected}
        try existing(["a","b","c"])
        try catalog {c in
            XCTAssertThrowsError(try c.bootstrap(.source,byteLimit:15) {_ in XCTFail("Key over byte budget")})
            XCTAssertThrowsError(try c.bootstrap(.source,limit:0) {_ in})
            XCTAssertThrowsError(try c.bootstrap(.source,limit:513) {_ in})
            XCTAssertThrowsError(try c.bootstrap(.source,limit:2) {_ in throw Stop.expected})
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identities"),0);XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identity_bootstrap"),0);XCTAssertEqual(try scalar("SELECT processing FROM personal_sync_identity_state"),0)
        try catalog {c in XCTAssertEqual(try c.bootstrap(.source,byteLimit:16) {XCTAssertEqual($0.count,1)},.init(objects:1,complete:false))}
    }
    func testDeletingBootstrapCursorPurgesItsRawKeyAndRestartsWithoutLosingRemainingRows()throws {
        try existing(["sensitive-alias-key","z-last"]);var old:SyncObjectIdentity!
        try catalog {c in _=try c.bootstrap(.source,limit:1) {old=$0[0].identity}}
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identity_bootstrap WHERE next_key IS NOT NULL"),1)
        try store.withRoutineDatabase {try $0.execute("DELETE FROM memories WHERE id='sensitive-alias-key'")}
        XCTAssertThrowsError(try catalog {try $0.bootstrap(.source) {_ in XCTFail("Pending local delete skipped")}})
        _=try drain();XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identity_bootstrap WHERE next_key IS NOT NULL OR cursor_key IS NOT NULL"),0)
        try catalog {c in XCTAssertTrue(try XCTUnwrap(c.object(old)).deleted);XCTAssertNil(try c.object(old)?.primary)
            XCTAssertEqual(try c.bootstrap(.source) {XCTAssertEqual($0.map(\.primary),[primary("z-last")])},.init(objects:1,complete:true))
        }
    }
    func testNewKeyBehindCursorIsCapturedBeforeBootstrapContinues()throws {
        try existing(["b","c"])
        try catalog {c in _=try c.bootstrap(.source,limit:1) {XCTAssertEqual($0[0].primary,primary("b"))}}
        try store.insert(Memory(id:"a",text:"new lower sorted key"))
        XCTAssertThrowsError(try catalog {try $0.bootstrap(.source) {_ in XCTFail("Local mutation bypassed")}})
        let inserted=try XCTUnwrap(drain().first?.after)
        try catalog {c in XCTAssertEqual(try c.object(inserted)?.primary,primary("a"));XCTAssertEqual(try c.bootstrap(.source) {XCTAssertEqual($0.map(\.primary),[primary("c")])},.init(objects:1,complete:true))}
    }
    func testBootstrapDeletionInsideCallbackCannotPersistADeletedRawCursorKey()throws {
        try existing(["a","b"])
        try catalog {c in XCTAssertEqual(try c.bootstrap(.source,limit:1) {_ in try c.database.execute("DELETE FROM memories WHERE id='a'")},.init(objects:1,complete:false))}
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identity_bootstrap WHERE next_key IS NOT NULL"),0)
        _=try drain()
        try catalog {c in XCTAssertEqual(try c.bootstrap(.source) {XCTAssertEqual($0.map(\.primary),[primary("b")])},.init(objects:1,complete:true))}
    }
    func testPartialCatalogCannotBeSilentlyReinstalled()throws {
        try store.withRoutineDatabase {db in try db.execute("DROP TABLE personal_sync_identity_bootstrap");XCTAssertThrowsError(try SyncIdentityCatalog.install(db))}
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='personal_sync_identity_bootstrap'"),0)
    }
    func testPrimaryStorageAffinityCannotOverwriteAnExistingSourceUnderADifferentIdentity()throws {
        try existing(["1"])
        try catalog {c in
            _=try c.registerExisting(.source,primary:primary("1"))
            XCTAssertThrowsError(try c.applyPeer(peer(),primary:[.integer(1)]) {try store.insert(Memory(id:"1",text:"incorrect foreign overwrite"))})
        }
        XCTAssertThrowsError(try SyncIdentityCatalog.keyFrame(.source,[.integer(1)]))
        XCTAssertThrowsError(try SyncIdentityCatalog.keyFrame(.conversationCitation,[.text(Data("turn".utf8)),.text(Data("0".utf8))]))
        XCTAssertThrowsError(try SyncIdentityCatalog.keyFrame(.recapCitation,[.text(Data("summary".utf8)),.text(Data("10".utf8))]))
        XCTAssertEqual(try store.get("1")?.text,"existing authored source")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM personal_sync_identities"),1)
        XCTAssertTrue(try pending().isEmpty)
    }
    func testConcurrentConnectionsConsumeEachCapturedInsertExactlyOnce()throws {
        let other=try MemoryStore(root:root);defer {try? other.close()};let results=IdentityTestResults()
        DispatchQueue.concurrentPerform(iterations:40) {index in do {try (index%2==0 ? store!:other).insert(Memory(id:"owned-\(index)",text:"authored concurrent source"))}catch {results.fail()}}
        DispatchQueue.concurrentPerform(iterations:2) {index in do {
            let selected=index==0 ? store!:other
            try selected.withRoutineDatabase {db in try SyncChangeCapture.prepare(db);let c=SyncIdentityCatalog(database:db,scope:try SyncChangeCapture.scope(db));while try c.process(limit:3,consume:{results.record($0)})>0 {}}
        }catch {results.fail()}}
        XCTAssertEqual(results.result.0,40);XCTAssertEqual(results.result.1,0);XCTAssertTrue(try pending().isEmpty)
    }
}
