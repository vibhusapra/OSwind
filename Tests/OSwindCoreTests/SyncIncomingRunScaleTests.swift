import XCTest
import Foundation
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    /// Authored warm metadata phases; raw population is setup, not API ingress.
    /// No provider, media, model, transport, cold-cache or energy result.
    func testOwnedIncomingRunProjectionAtBoundedScale()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_SYNC_RUN_SCALE_OUTPUT"] else {throw XCTSkip("Explicit owned routine-scale output required")}
        let fm=FileManager.default,base=URL(fileURLWithPath:path,isDirectory:true)
        guard base.path==path,base.resolvingSymlinksInPath().path==path,base.standardizedFileURL.path==path,fm.fileExists(atPath:base.deletingLastPathComponent().path),!fm.fileExists(atPath:path) else {throw OSwindError.invalid("Run scale requires fresh absolute nonsymlink output")}
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try Data("OSwind authored incoming run scale v1".utf8).write(to:base.appendingPathComponent("owned-fixture"),options:.withoutOverwriting)
        let previous=root;defer {root=previous};var reports=[[String:Any]]()
        for size in [1000,10000] {
            let folder=base.appendingPathComponent("n\(size)");try fm.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);root=folder
            let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
            var recipe=RoutineDefinition();recipe.id="scale-recipe";recipe.title="Owned run scale recipe";recipe.prompt="Original scale prompt "+String(repeating:"x",count:1024);recipe.schedule.timeZone="UTC"
            let first=try a.saveRoutine(recipe,now:now);try drain(a,ac)
            let initial=try XCTUnwrap(ac.journal.outbox().first),definition=try packet(initial,ac),recipeLocal=try receive(initial,definition,b,bc,fetch:{_ in definition})
            let scope=try SyncProtocolLimits.encode(recipe.filter(at:now)),load=ProcessInfo.processInfo.systemUptime
            try a.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
                let row=try db.statement("""
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<?)
                INSERT INTO routine_runs(id,routine_id,revision,scheduled_at,started,finished,trigger,status,chat_id,message,scope)
                SELECT printf('run-%08d',x),?,1,1700000000+x,1700000000+x,1700000001+x,'manual','failed',NULL,'Owned initial run '||x,? FROM n
                """);defer {sqlite3_finalize(row)};sqlite3_bind_int(row,1,Int32(size));db.bind(row,2,recipe.id);scope.withUnsafeBytes {_=sqlite3_bind_blob(row,3,$0.baseAddress,Int32(scope.count),db.transient)};try db.done(row)
            }}
            let loadSeconds=ProcessInfo.processInfo.systemUptime-load
            recipe.prompt="New current scale prompt";_=try a.saveRoutine(recipe,expectedRevision:first.revision,now:now)
            let prepare=ProcessInfo.processInfo.systemUptime;try drain(a,ac);let prepareSeconds=ProcessInfo.processInfo.systemUptime-prepare
            let lease=try b.mediaWriteLease();defer {lease.release()};let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
            var cursor=initial.dot.counter,received=0,runs=0,recipes=0,batches=[[String:Any]]();let began=ProcessInfo.processInfo.systemUptime
            while true {
                let start=ProcessInfo.processInfo.systemUptime,operations=try ac.journal.outbox(after:cursor,limit:128);if operations.isEmpty {break};let packets=try operations.map {try packet($0,ac)}
                try b.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
                    for (operation,record) in zip(operations,packets) {
                        let result=try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})};XCTAssertEqual(result.applied,1)
                        switch record.body {case .routine:recipes+=1;case .routineRun:runs+=1;default:throw OSwindError.invalid("Unexpected routine scale object")}
                    }
                }}
                cursor=operations.last!.dot.counter;received+=operations.count;batches.append(["objects":operations.count,"seconds":ProcessInfo.processInfo.systemUptime-start])
            }
            let incomingSeconds=ProcessInfo.processInfo.systemUptime-began;lease.release();XCTAssertEqual(runs,size);XCTAssertEqual(recipes,1);XCTAssertEqual(received,size+1)
            XCTAssertEqual(try count(b,"routine_runs"),size);XCTAssertEqual(try count(b,"routine_run_originals"),size);XCTAssertTrue(try bc.journal.outbox().isEmpty);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
            XCTAssertEqual(try b.routines().first?.definition.prompt,recipe.prompt);XCTAssertFalse(try XCTUnwrap(b.routines().first).definition.enabled)
            var beforeUpdates=[SyncPortableRecord]()
            for index in 1...10 {
                let id=String(format:"run-%08d",index),identity=try ac.catalog.localIdentity(.routineRun,primary:[.text(Data(id.utf8))]),record=try ac.resolve(identity,content:nil,admit:{_ in})
                beforeUpdates.append(record)
                try a.withRoutineDatabase {db in let row=try db.statement("UPDATE routine_runs SET message=? WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,"Owned updated run \(index)");db.bind(row,2,id);try db.done(row)}
            }
            try SyncProtocolLimits.encode(beforeUpdates).write(to:folder.appendingPathComponent("before-updates.json"),options:.withoutOverwriting);try drain(a,ac)
            let updateLease=try b.mediaWriteLease();defer {updateLease.release()};let update=ProcessInfo.processInfo.systemUptime;var updates=0
            while true {
                let operations=try ac.journal.outbox(after:cursor,limit:128);if operations.isEmpty {break}
                for operation in operations {let record=try packet(operation,ac),result=try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:updateLease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})};XCTAssertEqual(result.applied,1);updates+=1}
                cursor=operations.last!.dot.counter
            }
            let updateSeconds=ProcessInfo.processInfo.systemUptime-update;updateLease.release();XCTAssertEqual(updates,10)
            for record in beforeUpdates {XCTAssertEqual(try bc.record(record.reference,admit:{_ in})?.encoded(),try record.encoded())}
            _=try b.routineRuns(recipeLocal,limit:100);var historyMS=[Double]()
            for _ in 0..<7 {let start=ProcessInfo.processInfo.systemUptime,history=try b.routineRuns(recipeLocal,limit:100);historyMS.append((ProcessInfo.processInfo.systemUptime-start)*1000);XCTAssertEqual(history.count,100);XCTAssertTrue(history.allSatisfy {$0.original?.recipePrompt=="Original scale prompt "+String(repeating:"x",count:1024) && $0.status == .failed})}
            XCTAssertEqual(try count(b,"personal_sync_versions"),size+12);XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
            let report:[String:Any]=["count":size,"librarySchema":MemoryStore.schemaVersion,"loadSeconds":loadSeconds,"outgoingPreparationSeconds":prepareSeconds,"incomingSeconds":incomingSeconds,"incomingObjects":received,"incomingRuns":runs,"recipeUpdates":recipes,"batchSize":128,"batches":batches,"updatedRuns":updates,"runUpdateSeconds":updateSeconds,"nativeHistoryLimit":100,"nativeHistoryWarmMS":historyMS,"receiverVersions":size+12,"recipeLocal":recipeLocal,"originalPromptPaddingBytes":1024,"scope":"One warm authored metadata run per size; incoming timer includes actual producer packet reads, journal/native/original/cache projection and128-record transactions. Raw population/outgoing preparation, local policy inference, model/media/transport, cold cache, physical power and product ranking are excluded. Seven native history reads follow an untimed warmup." ]
            try a.close();try b.close();try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:folder.appendingPathComponent("report.json"));reports.append(report)
            print("INCOMING_RUN_SCALE rows=\(size) incomingSeconds=\(incomingSeconds) updateSeconds=\(updateSeconds) exactOriginal=true oldWireRetained=10 noEcho=true")
        }
        try JSONSerialization.data(withJSONObject:reports,options:[.sortedKeys,.prettyPrinted]).write(to:base.appendingPathComponent("report.json"))
    }
}
