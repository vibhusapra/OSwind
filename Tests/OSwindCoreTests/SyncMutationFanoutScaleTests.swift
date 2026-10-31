import XCTest
import Foundation
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private func snapshotFanout(_ store:MemoryStore,to file:URL)throws {
        guard !FileManager.default.fileExists(atPath:file.path) else {throw OSwindError.invalid("Owned fanout snapshot must be fresh")}
        try store.withRoutineDatabase {db in
            guard sqlite3_get_autocommit(db.handle) != 0 else {throw OSwindError.invalid("Close fanout transaction before snapshot")}
            var target:OpaquePointer?
            guard sqlite3_open_v2(file.path,&target,SQLITE_OPEN_CREATE|SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK,let target else {sqlite3_close(target);throw OSwindError.invalid("Cannot create owned fanout snapshot")}
            defer {sqlite3_close(target)}
            guard let copy=sqlite3_backup_init(target,"main",db.handle,"main") else {throw OSwindError.invalid("Cannot snapshot owned fanout fixture")}
            let code=sqlite3_backup_step(copy,-1),finish=sqlite3_backup_finish(copy)
            guard code==SQLITE_DONE,finish==SQLITE_OK else {throw OSwindError.invalid("Incomplete owned fanout snapshot")}
        }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    /// Warm authored metadata only. Population/preparation/snapshot are outside
    /// the deletion timer. This is not a service, transport or power benchmark.
    func testOwnedSyncMutationFanoutAtBoundedScale()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_SYNC_MUTATION_FANOUT_OUTPUT"] else {throw XCTSkip("Explicit owned fanout output required")}
        let fm=FileManager.default,base=URL(fileURLWithPath:path,isDirectory:true)
        guard base.path==path,base.resolvingSymlinksInPath().path==path,base.standardizedFileURL.path==path,fm.fileExists(atPath:base.deletingLastPathComponent().path),!fm.fileExists(atPath:path) else {throw OSwindError.invalid("Fanout requires fresh absolute nonsymlink output")}
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try Data("OSwind authored sync mutation fanout v1".utf8).write(to:base.appendingPathComponent("owned-fixture"),options:.withoutOverwriting)
        let previous=root;defer {root=previous};var reports=[[String:Any]]()
        for size in [1000,10000] {
            let folder=base.appendingPathComponent("n\(size)");try fm.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);root=folder
            let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
            var recipe=RoutineDefinition();recipe.id="fanout-recipe";recipe.title="Owned fanout recipe";recipe.prompt="Owned fanout prompt";recipe.schedule.timeZone="UTC"
            _=try a.saveRoutine(recipe,now:now);try drain(a,ac);let initial=try XCTUnwrap(ac.journal.outbox().first),definition=try packet(initial,ac),local=try receive(initial,definition,b,bc,fetch:{_ in definition})
            let scope=try SyncProtocolLimits.encode(recipe.filter(at:now)),load=ProcessInfo.processInfo.systemUptime
            try b.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
                let row=try db.statement("""
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<?)
                INSERT INTO routine_runs(id,routine_id,revision,scheduled_at,started,finished,trigger,status,chat_id,message,scope)
                SELECT printf('fanout-%08d',x),?,1,1700000000+x,1700000000+x,1700000001+x,'manual','failed',NULL,'Owned fanout run '||x,? FROM n
                """);defer {sqlite3_finalize(row)};sqlite3_bind_int(row,1,Int32(size));db.bind(row,2,local);scope.withUnsafeBytes {_=sqlite3_bind_blob(row,3,$0.baseAddress,Int32(scope.count),db.transient)};try db.done(row)
            }}
            let loadSeconds=ProcessInfo.processInfo.systemUptime-load,prepare=ProcessInfo.processInfo.systemUptime;try drain(b,bc);let preparationSeconds=ProcessInfo.processInfo.systemUptime-prepare
            XCTAssertEqual(try count(b,"routine_runs"),size);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
            try snapshotFanout(b,to:folder.appendingPathComponent("before-delete.sqlite"))
            let through=try b.withRoutineDatabase {try $0.eraseCount("SELECT sequence FROM personal_sync_local")}
            XCTAssertEqual(through,size);try a.deleteRoutine(recipe.id);try drain(a,ac);let operation=try XCTUnwrap(ac.journal.outbox().last)
            XCTAssertEqual(operation.mutation,.delete);XCTAssertEqual(operation.key.kind,.routine)
            let lease=try b.mediaWriteLease();defer {lease.release()};let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("No deleted body")},pathsFor:{_,_ in XCTFail("No incoming media");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
            let start=ProcessInfo.processInfo.systemUptime
            let receipt=try bc.journal.receive(operation,contentAvailable:{_ in XCTFail("No deleted content");return false}) {try writer.applyDeletion($0,admission:lease)}
            let seconds=ProcessInfo.processInfo.systemUptime-start;XCTAssertEqual(receipt.applied,1);XCTAssertTrue(receipt.inserted)
            lease.release();XCTAssertEqual(try count(b,"routine_runs"),0);XCTAssertEqual(try count(b,"personal_sync_versions"),0)
            var cursor=Int64(through),children=0
            while true {
                let batch=try bc.journal.outbox(after:cursor,limit:256);if batch.isEmpty {break}
                for child in batch {XCTAssertEqual(child.key.kind,.routineRun);XCTAssertEqual(child.mutation,.delete);XCTAssertNil(child.content);XCTAssertTrue(child.context.contains(operation.dot));children+=1}
                cursor=batch.last!.dot.counter
            };XCTAssertEqual(children,size)
            let report:[String:Any]=["count":size,"librarySchema":MemoryStore.schemaVersion,"loadSeconds":loadSeconds,"outgoingPreparationSeconds":preparationSeconds,"deletionSeconds":seconds,"announcements":children,"beforeSequence":through,"finalSequence":cursor,"root":try JSONSerialization.jsonObject(with:SyncProtocolLimits.encode(operation)),"testBundle":Bundle(for:Self.self).bundleURL.path,"scope":"Warm owned metadata fixture; actual receiver-only runs, native FK deletion and child journal/cache/mapping retirement in one real incoming receipt. Population/preparation/snapshot, media/model/transport/cold cache/energy/product ranking excluded."]
            try a.close();try b.close();try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:folder.appendingPathComponent("report.json"));reports.append(report)
            print("SYNC_MUTATION_FANOUT rows=\(size) seconds=\(seconds) exactChildBarriers=\(children) rootClock=true")
        }
        try JSONSerialization.data(withJSONObject:reports,options:[.sortedKeys,.prettyPrinted]).write(to:base.appendingPathComponent("report.json"))
    }
}
