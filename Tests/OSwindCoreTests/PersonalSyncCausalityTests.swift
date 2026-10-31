import XCTest
import CSQLite
@testable import OSwindCore

/// Three owned libraries; actual graph foreign keys and body-free early deletes.
final class PersonalSyncCausalityTests:XCTestCase {
    private enum DependencyError:Error {case sourceAppliedTooLate}
    let a="00000000-0000-0000-0000-000000000001",b="00000000-0000-0000-0000-000000000002",c="00000000-0000-0000-0000-000000000003"
    let group="00000000-0000-0000-0000-000000000004",epoch="00000000-0000-0000-0000-000000000005"
    var root:URL!,stores:[String:MemoryStore]=[:]
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-sync-causality-"+UUID().uuidString)
        for id in [a,b,c] {
            let store=try MemoryStore(root:root.appendingPathComponent(id));stores[id]=store
            try store.withRoutineDatabase {db in let j=try SyncJournal.install(database:db,replica:id,group:group,epoch:epoch);for peer in [a,b,c] {try j.allowPeer(peer)}}
        }
    }
    override func tearDownWithError()throws {for store in stores.values {try store.close()};stores=[:];try FileManager.default.removeItem(at:root)}
    func key(_ name:String,_ kind:SyncObjectKind = .source)throws->SyncObjectKey {try .make(kind:kind,identity:Data(name.utf8))}
    func content(_ value:String)throws->SyncContentReference {try .init(data:Data(value.utf8))}
    func journal<T>(_ id:String,_ body:(SyncJournal,MemoryStore)throws->T)throws->T {
        let store=try XCTUnwrap(stores[id]);return try store.withRoutineDatabase {db in try SyncJournal.prepareConnection(db);return try body(.init(database:db,replica:id,group:group,epoch:epoch),store)}
    }
    func reopen(_ id:String)throws {try stores[id]?.close();stores[id]=try MemoryStore(root:root.appendingPathComponent(id))}
    func apply(_ change:SyncJournalChange,_ j:SyncJournal,_ store:MemoryStore)throws {
        if try change.revision.key==key("parent") {if change.after.isDeleted {try j.database.execute("DELETE FROM memories WHERE id='parent'")}else {try store.insert(Memory(id:"parent",text:"authored causal parent"))}}
        else if try change.revision.key==key("session",.conversation) {try j.database.execute("INSERT INTO chat_sessions VALUES('session','Owned causal chat',1,1)")}
        else if try change.revision.key==key("turn",.turn) {
            guard try store.get("parent") != nil else {throw DependencyError.sourceAppliedTooLate}
            try j.database.execute("INSERT INTO chat_turns VALUES('turn','session',1,x'7b7d'); INSERT INTO chat_sources(turn_id,memory_id,ordinal,score,match,passage_start,passage_length) VALUES('turn','parent',0,1,'authored',NULL,NULL)")
        }else if !change.after.isDeleted {try store.insert(Memory(id:"after-delete-"+change.revision.key.digest,text:"authored after observing deletion"))}
    }
    func testNewTurnWaitsForObservedSourceAcrossObjectsAndSurvivesReopen()throws {
        let parent=try journal(a) {j,s in try j.put(key:key("parent"),content:content("authored causal parent")) {try apply($0,j,s)}}
        let session=try journal(b) {j,s in try j.put(key:key("session",.conversation),content:content("Owned causal chat")) {try apply($0,j,s)}}
        try journal(c) {j,s in XCTAssertEqual(try j.receive(session,contentAvailable:{_ in true}) {try apply($0,j,s)}.applied,1)}
        try journal(b) {j,s in XCTAssertEqual(try j.receive(parent,contentAvailable:{_ in true}) {try apply($0,j,s)}.applied,1)}
        let turn=try journal(b) {j,s in try j.put(key:key("turn",.turn),content:content("authored answer with parent citation")) {try apply($0,j,s)}}
        XCTAssertTrue(turn.context.contains(parent.dot));XCTAssertTrue(turn.context.contains(session.dot))
        try journal(c) {j,s in
            var appliedTooEarly=false,result:SyncReceiveResult?
            XCTAssertNoThrow(result=try j.receive(turn,contentAvailable:{_ in true}) {change in appliedTooEarly=true;try apply(change,j,s)})
            XCTAssertFalse(appliedTooEarly);XCTAssertEqual(result?.applied,0);XCTAssertEqual(try j.cursor(for:b),1)
        }
        try reopen(c)
        try journal(c) {j,s in
            XCTAssertEqual(try j.receive(parent,contentAvailable:{_ in true}) {try apply($0,j,s)}.applied,2)
            XCTAssertEqual(try j.cursor(for:b),2)
            let row=try j.database.statement("SELECT memory_id FROM chat_sources WHERE turn_id='turn' AND ordinal=0");defer {sqlite3_finalize(row)}
            XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(j.database.text(row,0),"parent")
        }
    }
    func testEarlyDeletionObservationOrdersOtherObjectsWithoutFetchingDeletedBody()throws {
        let put=try journal(a) {j,_ in try j.put(key:key("parent"),content:content("missing old parent body"))}
        let deletion=try journal(a) {j,_ in try j.delete(key:key("parent"))}
        try journal(b) {j,s in XCTAssertEqual(try j.receive(deletion,contentAvailable:{_ in XCTFail("Deletion requested a body");return false}) {try apply($0,j,s)}.applied,0)}
        let first=try journal(b) {j,_ in try j.put(key:key("other"),content:content("observed deletion"))}
        XCTAssertTrue(first.context.contains(deletion.dot))
        try reopen(b)
        let second=try journal(b) {j,_ in try j.put(key:key("other-2"),content:content("observed deletion after restart"))}
        XCTAssertTrue(second.context.contains(deletion.dot))
        try journal(c) {j,s in
            XCTAssertEqual(try j.receive(first,contentAvailable:{_ in true}) {try apply($0,j,s)}.applied,0)
            XCTAssertEqual(try j.receive(second,contentAvailable:{_ in true}) {try apply($0,j,s)}.applied,0)
            XCTAssertNil(try s.get("after-delete-"+first.key.digest))
            _=try j.receive(deletion,contentAvailable:{_ in XCTFail("Deletion requested a body");return false}) {try apply($0,j,s)}
            XCTAssertEqual(try j.receive(put,contentAvailable:{reference in if reference==put.content {XCTFail("Deleted old body was requested");return false};return true}) {try apply($0,j,s)}.applied,4)
            XCTAssertNotNil(try s.get("after-delete-"+first.key.digest));XCTAssertNil(try s.get("parent"))
        }
    }
    func testLegacyJournalRebuildsPendingEarlyDeletionObservationBeforeAnotherObjectWrite()throws {
        let deletion=try journal(a) {j,_ -> SyncRevision in _=try j.put(key:key("parent"),content:content("old body"));return try j.delete(key:key("parent"))}
        try journal(b) {j,s in _=try j.receive(deletion,contentAvailable:{_ in false}) {try apply($0,j,s)};try j.database.execute("DROP TABLE IF EXISTS personal_sync_observed")}
        try XCTUnwrap(stores[b]).withRoutineDatabase {db in _=try SyncJournal.install(database:db,replica:b,group:group,epoch:epoch)}
        let next=try journal(b) {j,_ in try j.put(key:key("new object"),content:content("after recovered deletion"))}
        XCTAssertTrue(next.context.contains(deletion.dot))
    }
    func scalar(_ id:String,_ sql:String)throws->Int64 {try XCTUnwrap(stores[id]).withRoutineDatabase {db in let s=try db.statement(sql);defer {sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_ROW else {throw db.error()};return sqlite3_column_int64(s,0)}}
    func testFailedEarlyDeleteAdapterRollsBackObservationAndReceiptTogether()throws {
        enum Stop:Error {case expected}
        let deletion=try journal(a) {j,_ -> SyncRevision in _=try j.put(key:key("parent"),content:content("old"));return try j.delete(key:key("parent"))}
        try journal(b) {j,_ in XCTAssertThrowsError(try j.receive(deletion,contentAvailable:{_ in false}) {_ in throw Stop.expected});XCTAssertFalse(try j.state(for:key("parent")).isDeleted)}
        let first=try journal(b) {j,_ in try j.put(key:key("other"),content:content("no deletion observed"))};XCTAssertFalse(first.context.contains(deletion.dot))
        try journal(b) {j,s in XCTAssertTrue(try j.receive(deletion,contentAvailable:{_ in false}) {try apply($0,j,s)}.inserted)}
        let second=try journal(b) {j,_ in try j.put(key:key("other-2"),content:content("deletion observed"))};XCTAssertTrue(second.context.contains(deletion.dot))
    }
    func testUnappliedPutDoesNotMakeUnrelatedWritesDependOnMissingContent()throws {
        let parent=try journal(a) {j,_ in try j.put(key:key("parent"),content:content("parent body"))}
        try journal(b) {j,_ in XCTAssertEqual(try j.receive(parent,contentAvailable:{_ in false}) {_ in XCTFail("Missing content applied")}.applied,0)}
        let before=try journal(b) {j,_ in try j.put(key:key("independent"),content:content("independent body"))};XCTAssertFalse(before.context.contains(parent.dot))
        try journal(c) {j,s in XCTAssertEqual(try j.receive(before,contentAvailable:{_ in true}) {try apply($0,j,s)}.applied,1)}
        try journal(b) {j,s in XCTAssertEqual(try j.receive(parent,contentAvailable:{_ in true}) {try apply($0,j,s)}.applied,1)}
        let after=try journal(b) {j,_ in try j.put(key:key("dependent"),content:content("after observing parent"))};XCTAssertTrue(after.context.contains(parent.dot))
    }
    func testConflictResolutionIncludesAnObservedDifferentObject()throws {
        let left=try journal(a) {j,_ in try j.put(key:key("same"),content:content("left"))}
        let right=try journal(b) {j,_ in try j.put(key:key("same"),content:content("right"))}
        let d="00000000-0000-0000-0000-000000000006"
        let other=try SyncRevision(key:key("independent"),dot:.init(replica:d,counter:1),context:.empty,mutation:.put,content:content("other object"))
        try journal(c) {j,_ in
            try j.allowPeer(d);_=try j.receive(left,contentAvailable:{_ in true});_=try j.receive(right,contentAvailable:{_ in true});_=try j.receive(other,contentAvailable:{_ in true})
            let resolved=try j.resolve(key:key("same"),expectedHeads:[left.dot,right.dot],content:content("resolved"));XCTAssertTrue(resolved.context.contains(left.dot));XCTAssertTrue(resolved.context.contains(right.dot));XCTAssertTrue(resolved.context.contains(other.dot))
        }
    }
    func testMalformedObservedClockOrFractionalPeerCursorCannotAdvanceLocalSequence()throws {
        let unknown="00000000-0000-0000-0000-000000000099"
        try XCTUnwrap(stores[b]).withRoutineDatabase {db in try db.execute("UPDATE personal_sync_observed SET clock=CAST('{\"\(unknown)\":1}' AS BLOB)")}
        XCTAssertThrowsError(try journal(b) {j,_ in try j.put(key:key("must not commit"),content:content("body"))})
        XCTAssertEqual(try scalar(b,"SELECT sequence FROM personal_sync_local"),0);XCTAssertEqual(try scalar(b,"SELECT COUNT(*) FROM personal_sync_outbox"),0)
        try XCTUnwrap(stores[b]).withRoutineDatabase {db in try db.execute("UPDATE personal_sync_observed SET clock=CAST('{}' AS BLOB); UPDATE personal_sync_peers SET cursor=1.5 WHERE replica='\(a)'")}
        XCTAssertThrowsError(try journal(b) {j,_ in try j.put(key:key("must not commit"),content:content("body"))})
        XCTAssertEqual(try scalar(b,"SELECT sequence FROM personal_sync_local"),0)
        try XCTUnwrap(stores[b]).withRoutineDatabase {try $0.execute("UPDATE personal_sync_peers SET cursor=0 WHERE replica='\(a)'")}
        XCTAssertEqual(try journal(b) {j,_ in try j.put(key:key("valid"),content:content("body"))}.dot.counter,1)
    }
    func testCorruptLegacyPendingRecordRefusesObservationMigrationWithoutPartialRepair()throws {
        let deletion=try journal(a) {j,_ -> SyncRevision in _=try j.put(key:key("parent"),content:content("old"));return try j.delete(key:key("parent"))}
        try journal(b) {j,_ in _=try j.receive(deletion,contentAvailable:{_ in false});try j.database.execute("DROP TABLE personal_sync_observed; INSERT INTO personal_sync_pending VALUES('\(a)',3,x'00')")}
        try XCTUnwrap(stores[b]).withRoutineDatabase {db in XCTAssertThrowsError(try SyncJournal.install(database:db,replica:b,group:group,epoch:epoch))}
        XCTAssertEqual(try scalar(b,"SELECT COUNT(*) FROM sqlite_master WHERE name='personal_sync_observed'"),0);XCTAssertEqual(try scalar(b,"SELECT COUNT(*) FROM personal_sync_pending"),2)
        try XCTUnwrap(stores[b]).withRoutineDatabase {db in try db.execute("DELETE FROM personal_sync_pending WHERE sequence=3");_=try SyncJournal.install(database:db,replica:b,group:group,epoch:epoch)}
        XCTAssertTrue(try journal(b) {j,_ in try j.put(key:key("after migration"),content:content("body"))}.context.contains(deletion.dot))
    }

}
