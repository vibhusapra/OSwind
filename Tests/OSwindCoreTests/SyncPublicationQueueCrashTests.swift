import XCTest
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private struct QueueCrashState:Codable {
        let target:SyncRevision,next:SyncPortableRecord,proof:SyncTurnPublication,objects:[SyncPortableRecord]
        let keyFrames:[Data],nativeFrames:[Data],chatID:String,cursor:Int64?,outbox:[SyncRevision]
    }
    private func queueFrames(_ db:RoutineDatabase)throws->[Data] {
        var frames=[Data]()
        for table in [SyncCanonicalTable.turn,.conversationCitation] {
            let row=try db.statement("SELECT "+table.schema.snapshot("t")+" FROM "+table.rawValue+" t ORDER BY "+table.schema.primary.joined(separator:","));defer {sqlite3_finalize(row)}
            var code=sqlite3_step(row)
            while code==SQLITE_ROW {guard let bytes=sqlite3_column_blob(row,0) else {throw db.error()};frames.append(Data(bytes:bytes,count:Int(sqlite3_column_bytes(row,0))));code=sqlite3_step(row)}
            guard code==SQLITE_DONE else {throw db.error()}
        };return frames
    }
    func openQueueCrash(_ base:URL)throws->(MemoryStore,SyncVersionStore,SyncPublicationQueue,SyncObjectFolder) {
        let store=try MemoryStore(root:base.appendingPathComponent("receiver")),cache=try store.withRoutineDatabase {db in
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:receiverID,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        }
        let queue=try store.withRoutineDatabase {_ in try SyncPublicationQueue.install(cache:cache)}
        // Public, synthetic fixture bytes; no real group secret is exported.
        let secret=try SyncGroupSecret(rawRepresentation:Data(repeating:0x2c,count:32)),inbox=try SyncObjectFolder.open(at:base.appendingPathComponent("queue-inbox"),secret:secret,group:group,epoch:epoch)
        return (store,cache,queue,inbox)
    }
    private func checkQueueCrash(_ state:QueueCrashState,committed:Bool,store:MemoryStore,cache:SyncVersionStore,queue:SyncPublicationQueue)throws {
        XCTAssertEqual(try store.withRoutineDatabase{try queueFrames($0)},committed ? []:state.nativeFrames)
        XCTAssertEqual(try cache.journal.cursor(for:producerID),committed ? state.target.dot.counter:state.cursor)
        XCTAssertEqual(try cache.journal.outbox(),state.outbox);XCTAssertEqual(try count(store,"personal_sync_changes"),0)
        XCTAssertEqual(try count(store,"personal_sync_version_revoked"),0)
        XCTAssertEqual(try queue.jobs(readyOnly:false).count,committed ? 1:0)
        XCTAssertEqual(try queue.isComplete(state.next.identity),!committed)
        for (index,object) in state.objects.enumerated() {
            let mapping=try XCTUnwrap(cache.catalog.object(object.identity));XCTAssertFalse(mapping.deleted)
            XCTAssertEqual(try SyncIdentityCatalog.keyFrame(object.identity.table,XCTUnwrap(mapping.primary)),state.keyFrames[index])
            XCTAssertFalse(try cache.journal.state(for:object.identity.key).isDeleted)
            if !committed {XCTAssertEqual(try cache.resolve(object.identity,content:nil,admit:{_ in}).encoded(),try object.encoded())}
            else {
                let row=try cache.database.statement("SELECT count(*) FROM personal_sync_versions WHERE object_digest=?");defer {sqlite3_finalize(row)};cache.database.bind(row,1,try object.identity.key.digest)
                XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int64(row,0),0)
            }
        }
        try store.withRoutineDatabase {XCTAssertEqual(try $0.eraseCount("SELECT count(*) FROM pragma_foreign_key_check"),0)};try queue.checkAccounting()
    }
    func testPublicationQueueDeathDuringCatalogueRelocationRollsBackExactGraph()throws {try crashQueue("relocated")}
    func testPublicationQueueDeathBeforeCommitRollsBackRetractionAndReceipt()throws {try crashQueue("before")}
    func testPublicationQueueDeathAfterCommitPreservesRetractionAndDurableRetry()throws {try crashQueue("after")}
    private func crashQueue(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,base=fm.temporaryDirectory.appendingPathComponent("owned-incoming-source-crash-"+nonce)
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:base)}
        try Data(nonce.utf8).write(to:base.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=base.appendingPathComponent("child.log"),gate=base.appendingPathComponent("ready")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path),fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw OSwindError.invalid("Invalid owned queue crash runner")}
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncIncomingSourceTests/testPublicationQueueCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_INCOMING_SOURCE_CRASH_ROOT":base.path,"OSWIND_INCOMING_SOURCE_CRASH_NONCE":nonce,"OSWIND_PUBLICATION_QUEUE_CRASH_PHASE":phase]
        for index in 0..<_dyld_image_count() {guard let pointer=_dyld_get_image_name(index) else {continue};let file=URL(fileURLWithPath:String(cString:pointer)).resolvingSymlinksInPath();if file.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=file.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {return XCTFail("Owned queue worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        // An independent read-only SQLite connection must never observe either
        // temporary catalogue keys or a partially withdrawn committed graph.
        var reader:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(base.appendingPathComponent("receiver/memory.sqlite").path,&reader,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        if let reader {defer {sqlite3_close(reader)};var row:OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(reader,"SELECT (SELECT count(*) FROM chat_turns),(SELECT count(*) FROM chat_sources),(SELECT count(*) FROM personal_sync_publication_jobs),(SELECT count(*) FROM personal_sync_identities WHERE instr(key_frame,CAST('projection-retract-' AS BLOB))>0)",-1,&row,nil),SQLITE_OK)
            if let row {defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),phase=="after" ? 0:1);XCTAssertEqual(sqlite3_column_int(row,1),phase=="after" ? 0:2);XCTAssertEqual(sqlite3_column_int(row,2),phase=="after" ? 1:0);XCTAssertEqual(sqlite3_column_int(row,3),0,"An independent connection must never see temporary catalogue bindings")}
        }
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let state=try JSONDecoder().decode(QueueCrashState.self,from:Data(contentsOf:base.appendingPathComponent("expected.json")))
        let (store,cache,queue,inbox)=try openQueueCrash(base)
        try checkQueueCrash(state,committed:phase=="after",store:store,cache:cache,queue:queue);try store.close();inbox.close()
        if keep {try fm.copyItem(at:base,to:root.appendingPathComponent("queue-crash-"+phase))}
        let (retry,rc,rq,ri)=try openQueueCrash(base);defer {try? retry.close();ri.close()}
        let service=queueService(retry,rc,rq,ri),lease=try retry.mediaWriteLease();defer {lease.release()}
        let received=try service.receive(state.target,record:state.next,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Source-free recovery must not fetch")})
        XCTAssertEqual(received.receipt.inserted,phase != "after");try checkQueueCrash(state,committed:true,store:retry,cache:rc,queue:rq)
        try service.retainDeclaration(state.proof.encoded(),reference:state.proof.reference)
        guard case .projected=try service.retry(admission:lease,fetchSource:{_ in throw OSwindError.invalid("Source-free retry must not fetch")}).first else {return XCTFail("Recovered durable queue must publish current independent answer")}
        XCTAssertEqual(try retry.chatTurns(state.chatID).first?.answer.text,state.next.body.queueCrashText)
        XCTAssertTrue(try rq.isComplete(state.next.identity));XCTAssertEqual(try rc.journal.outbox(),state.outbox);try rq.checkAccounting()
        print("PUBLICATION_QUEUE_CRASH phase=\(phase) killed=true independentReader=true exactFramesAndKeys=true receiptAtomic=true noEcho=true durableRetry=true")
    }
    func testPublicationQueueCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"] != nil,let phase=env["OSWIND_PUBLICATION_QUEUE_CRASH_PHASE"],["relocated","before","after"].contains(phase) else {throw XCTSkip("Only run as owned publication-queue crash child")}
        try withQueueFixture(citations:2,secret:SyncGroupSecret(rawRepresentation:Data(repeating:0x2c,count:32))) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let objects=try f.operations.filter{[.turn,.conversationCitation].contains($0.key.kind)}.map{try packet($0,f.ac)},(next,proof,target)=try queueReplacement(f,text:"Recovered independent answer 👩🏽‍💻 e\u{301}")
            let state=try QueueCrashState(target:target,next:next,proof:proof,objects:objects,keyFrames:objects.map{try SyncIdentityCatalog.keyFrame($0.identity.table,XCTUnwrap(f.bc.catalog.object($0.identity)?.primary))},nativeFrames:f.b.withRoutineDatabase{try queueFrames($0)},chatID:XCTUnwrap(f.b.chats().first).id,cursor:f.bc.journal.cursor(for:producerID),outbox:f.bc.journal.outbox())
            try SyncProtocolLimits.encode(state).write(to:root.appendingPathComponent("expected.json"),options:.atomic)
            func hold()throws {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop owned queue worker")}
            if phase=="relocated" {
                XCTAssertEqual(sqlite3_create_function_v2(f.bc.database.handle,"owned_queue_gate",0,SQLITE_UTF8,nil,{context,_,_ in
                    do {let env=ProcessInfo.processInfo.environment,path=try XCTUnwrap(env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"]);try Data("relocated".utf8).write(to:URL(fileURLWithPath:path).appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);sqlite3_result_error(context,"Owned worker not killed",-1)}catch {sqlite3_result_error(context,"Owned worker gate failed",-1)}
                },nil,nil,nil),SQLITE_OK)
                try f.bc.database.execute("CREATE TEMP TRIGGER owned_queue_gate BEFORE DELETE ON main.chat_turns BEGIN SELECT owned_queue_gate(); END")
            }
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            try f.b.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
                _=try service.receive(target,record:next,admission:lease,fetchSource:{_ in throw OSwindError.invalid("No replacement source fetch")})
                if phase=="before" {try hold()}
            }}
            if phase=="after" {try hold()}
        }
    }
}

private extension SyncPortableBody {
    var queueCrashText:String {if case .turn(let body)=self {return body.text};return "invalid owned answer"}
}
