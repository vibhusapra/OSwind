import XCTest
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private struct PublicationSourceCrashState:Codable {
        let target:SyncRevision,future:SyncPortableRecord,futureRevision:SyncRevision,proof:SyncTurnPublication
        let objects:[SyncPortableRecord],keys:[Data],frames:[String:[Data]],cursor:Int64?,outbox:[SyncRevision]
        let chatID:String,asset:String,assetBytes:Data,searchIdentity:String,queueLifetime:String
    }
    private var sourceCrashTables:[SyncCanonicalTable] {[.source,.conversation,.turn,.conversationCitation,.evidencePin]}
    private func sourceCrashFrames(_ db:RoutineDatabase)throws->[String:[Data]] {
        var frames=[String:[Data]]()
        for table in sourceCrashTables {
            let row=try db.statement("SELECT "+table.schema.snapshot("t")+" FROM "+table.rawValue+" t ORDER BY "+table.schema.primary.joined(separator:","));defer {sqlite3_finalize(row)}
            var values=[Data](),code=sqlite3_step(row)
            while code==SQLITE_ROW {guard let bytes=sqlite3_column_blob(row,0) else {throw db.error()};values.append(Data(bytes:bytes,count:Int(sqlite3_column_bytes(row,0))));code=sqlite3_step(row)}
            guard code==SQLITE_DONE else {throw db.error()};frames[table.rawValue]=values
        };return frames
    }
    private func sourceCrashMetadata(_ db:RoutineDatabase,_ key:String)throws->String {
        let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,key)
        guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return db.text(row,0)
    }
    private func checkPublicationSourceCrash(_ state:PublicationSourceCrashState,committed:Bool,store:MemoryStore,cache:SyncVersionStore,queue:SyncPublicationQueue)throws {
        var expected=state.frames
        if committed {
            for table in sourceCrashTables where table != .conversation {expected[table.rawValue]=[]}
            var conversation=try SyncRowSnapshot.decode(XCTUnwrap(expected[SyncCanonicalTable.conversation.rawValue]?.first)).cells
            conversation[1] = .text(Data("Conversation".utf8));expected[SyncCanonicalTable.conversation.rawValue]=[try SyncRowSnapshot(conversation).encoded()]
        }
        XCTAssertEqual(try store.withRoutineDatabase{try sourceCrashFrames($0)},expected)
        XCTAssertEqual(try cache.journal.cursor(for:producerID),committed ? state.target.dot.counter:state.cursor)
        XCTAssertEqual(try queue.jobs(readyOnly:false).map(\.reason),committed ? [.erasedEvidence]:[])
        XCTAssertEqual(try queue.isComplete(state.future.identity),!committed)
        let outbox=try cache.journal.outbox()
        if committed {
            let metadata=try XCTUnwrap(outbox.first),conversation=try XCTUnwrap(state.objects.first{$0.identity.table == .conversation})
            XCTAssertEqual(metadata.key,try conversation.identity.key);XCTAssertEqual(metadata.mutation,.put);XCTAssertTrue(metadata.context.contains(state.target.dot))
            let pins=Set(try state.objects.filter{$0.identity.table == .evidencePin}.map{try $0.identity.key}),retirements=Array(outbox.dropFirst())
            XCTAssertEqual(Set(retirements.map(\.key)),pins)
            for retirement in retirements {XCTAssertEqual(retirement.mutation,.delete);XCTAssertTrue(retirement.context.contains(state.target.dot))}
            XCTAssertEqual(try store.chats().first?.title,"Conversation")
            guard case .conversation(let body)=try cache.resolve(conversation.identity,content:nil,admit:{_ in}).body else {return XCTFail("Missing canonical redacted conversation")};XCTAssertEqual(body.title,"Conversation")
        }else {XCTAssertEqual(outbox,state.outbox)}
        for (index,record) in state.objects.enumerated() {
            let erased=committed && [SyncCanonicalTable.source,.evidencePin].contains(record.identity.table),mapping=try XCTUnwrap(cache.catalog.object(record.identity))
            XCTAssertEqual(try cache.journal.state(for:record.identity.key).isDeleted,erased);XCTAssertEqual(mapping.deleted,erased)
            if !erased {XCTAssertEqual(try SyncIdentityCatalog.keyFrame(record.identity.table,XCTUnwrap(mapping.primary)),state.keys[index])}
            if !committed {XCTAssertEqual(try cache.resolve(record.identity,content:nil,admit:{_ in}).encoded(),try record.encoded())}
        }
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM personal_sync_changes"),0)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM pragma_foreign_key_check"),0)
            XCTAssertEqual(try sourceCrashMetadata(db,"sync-publication-library-lifetime-v1"),state.queueLifetime)
            XCTAssertEqual(try sourceCrashMetadata(db,"identity")==state.searchIdentity,!committed)
        };try queue.checkAccounting()
    }
    func testPublicationQueueSourceDeathDuringCanonicalRedactionRollsBackGraphAndReceipt()throws {try publicationSourceCrash("redacted")}
    func testPublicationQueueSourceDeathDuringProjectionWithdrawalRollsBackGraphAndReceipt()throws {try publicationSourceCrash("withdrawn")}
    func testPublicationQueueSourceDeathDuringNativeSourceDeleteRollsBackGraphAndReceipt()throws {try publicationSourceCrash("source")}
    func testPublicationQueueSourceDeathBeforeCommitRollsBackGraphAndReceipt()throws {try publicationSourceCrash("before")}
    func testPublicationQueueSourceDeathAfterCommitRetainsMetadataMediaQueueAndIndependentHead()throws {try publicationSourceCrash("after")}
    private func publicationSourceCrash(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,base=fm.temporaryDirectory.appendingPathComponent("owned-incoming-source-crash-"+nonce)
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:base)}
        try Data(nonce.utf8).write(to:base.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=base.appendingPathComponent("child.log"),gate=base.appendingPathComponent("ready")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path),fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw OSwindError.invalid("Invalid owned source-withdrawal crash runner")}
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncIncomingSourceTests/testPublicationQueueSourceCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_INCOMING_SOURCE_CRASH_ROOT":base.path,"OSWIND_INCOMING_SOURCE_CRASH_NONCE":nonce,"OSWIND_PUBLICATION_SOURCE_CRASH_PHASE":phase]
        for index in 0..<_dyld_image_count() {guard let pointer=_dyld_get_image_name(index) else {continue};let file=URL(fileURLWithPath:String(cString:pointer)).resolvingSymlinksInPath();if file.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=file.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {return XCTFail("Source-withdrawal worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        let committed=phase=="after"
        var reader:OpaquePointer?;XCTAssertEqual(sqlite3_open_v2(base.appendingPathComponent("receiver/memory.sqlite").path,&reader,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        if let reader {defer {sqlite3_close(reader)};var row:OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(reader,"SELECT (SELECT count(*) FROM memories),(SELECT count(*) FROM chat_turns),(SELECT title FROM chat_sessions),(SELECT count(*) FROM personal_sync_publication_jobs),(SELECT count(*) FROM erasure_assets),(SELECT count(*) FROM personal_sync_identities WHERE instr(key_frame,CAST('projection-retract-' AS BLOB))>0)",-1,&row,nil),SQLITE_OK)
            if let row {defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),committed ? 0:1);XCTAssertEqual(sqlite3_column_int(row,1),committed ? 0:1);XCTAssertEqual(String(cString:sqlite3_column_text(row,2)),committed ? "Conversation":"Queue question 0?");XCTAssertEqual(sqlite3_column_int(row,3),committed ? 1:0);XCTAssertEqual(sqlite3_column_int(row,4),committed ? 1:0);XCTAssertEqual(sqlite3_column_int(row,5),0)}
        }
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let state=try JSONDecoder().decode(PublicationSourceCrashState.self,from:Data(contentsOf:base.appendingPathComponent("expected.json")))
        // Capture the actual killed database/WAL and still-present owned media
        // before opening MemoryStore can resume ordinary cleanup.
        XCTAssertEqual(try Data(contentsOf:base.appendingPathComponent("receiver").appendingPathComponent(state.asset)),state.assetBytes)
        if keep {try fm.copyItem(at:base,to:root.appendingPathComponent("publication-source-crash-"+phase))}
        let (store,cache,queue,inbox)=try openQueueCrash(base);defer {try? store.close();inbox.close()}
        try checkPublicationSourceCrash(state,committed:committed,store:store,cache:cache,queue:queue)
        let service=queueService(store,cache,queue,inbox),lease=try store.mediaWriteLease();defer {lease.release()}
        let replay=try service.receive(state.target,record:nil,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Erasure recovery cannot fetch originals")})
        XCTAssertEqual(replay.receipt.inserted,!committed);try checkPublicationSourceCrash(state,committed:true,store:store,cache:cache,queue:queue)
        let metadata=try XCTUnwrap(cache.journal.outbox().first),bytes=try XCTUnwrap(inbox.content(XCTUnwrap(metadata.content))),record=try SyncPortableRecord.decode(bytes)
        XCTAssertEqual(try record.identity.key,metadata.key);XCTAssertEqual(try cache.resolve(record.identity,content:nil,admit:{_ in}).encoded(),bytes,"Recovered outgoing metadata must have its authenticated durable encrypted body")
        _=try service.receive(state.futureRevision,record:state.future,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Independent future cannot fetch erased originals")})
        try service.retainDeclaration(state.proof.encoded(),reference:state.proof.reference)
        guard case .projected=try service.retry(admission:lease,fetchSource:{_ in throw OSwindError.invalid("Independent retry cannot fetch erased originals")}).first else {return XCTFail("Crash recovery suppressed an independent future answer")}
        XCTAssertTrue(try queue.isComplete(state.future.identity));XCTAssertEqual(try store.chatTurns(state.chatID).count,1)
        lease.release();let cleanup=store.retryErasureCleanup();XCTAssertEqual(cleanup.pendingMedia,0);XCTAssertTrue(cleanup.warnings.isEmpty);XCTAssertFalse(fm.fileExists(atPath:base.appendingPathComponent("receiver").appendingPathComponent(state.asset).path));try queue.checkAccounting()
        print("PUBLICATION_SOURCE_CRASH phase=\(phase) SIGKILL=true independentReader=true exactNativeFramesAndKeys=true rootReceiptAtomic=true redactedCanonicalRevision=true sourcePinBarriers=true durableMediaQueue=true explicitCleanup=true futureAnswerSurvives=true")
    }
    func testPublicationQueueSourceCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"] != nil,let phase=env["OSWIND_PUBLICATION_SOURCE_CRASH_PHASE"],["redacted","withdrawn","source","before","after"].contains(phase) else {throw XCTSkip("Only run as owned source-withdrawal crash child")}
        let png=try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM3sAAAAASUVORK5CYII=")),asset="images/incoming.png"
        try withQueueFixture(citations:1,secret:SyncGroupSecret(rawRepresentation:Data(repeating:0x2c,count:32)),makeSource:{_ in
            try png.write(to:self.root.appendingPathComponent("producer/images/owned.png"));return Memory(id:"queue-source-0",timestamp:self.now,kind:.screen,app:"Owned",text:"Owned source-withdrawal original 👩🏽‍💻 e\u{301}",imagePath:"images/owned.png")
        },beforeQueueInstall:{store,_ in try png.write(to:store.root.appendingPathComponent(asset))}) {f in
            let writer=SyncIncomingConversationWriter(library:f.b,cache:f.bc,admit:{_ in},pathsFor:{_,media in media.isEmpty ? [:]:[.image:asset]},admitMedia:{_,_,_ in}),service=SyncPublicationAdmission(queue:f.queue,writer:writer,inbox:f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let objects=try f.operations.map{try packet($0,f.ac)},source=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),target=try f.ac.journal.delete(key:source.key),(future,proof,futureRevision)=try queueReplacement(f,text:"Independent answer recovered after source erasure")
            let state=try PublicationSourceCrashState(target:target,future:future,futureRevision:futureRevision,proof:proof,objects:objects,keys:objects.map{try SyncIdentityCatalog.keyFrame($0.identity.table,XCTUnwrap(f.bc.catalog.object($0.identity)?.primary))},frames:f.b.withRoutineDatabase{try sourceCrashFrames($0)},cursor:f.bc.journal.cursor(for:producerID),outbox:f.bc.journal.outbox(),chatID:XCTUnwrap(f.b.chats().first).id,asset:asset,assetBytes:png,searchIdentity:f.b.withRoutineDatabase{try sourceCrashMetadata($0,"identity")},queueLifetime:f.b.withRoutineDatabase{try sourceCrashMetadata($0,"sync-publication-library-lifetime-v1")})
            try SyncProtocolLimits.encode(state).write(to:root.appendingPathComponent("expected.json"),options:.atomic)
            func hold()throws {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop source-withdrawal worker")}
            if ["redacted","withdrawn","source"].contains(phase) {
                XCTAssertEqual(sqlite3_create_function_v2(f.bc.database.handle,"owned_source_queue_gate",0,SQLITE_UTF8,nil,{context,_,_ in
                    do {let env=ProcessInfo.processInfo.environment,path=try XCTUnwrap(env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"]),phase=try XCTUnwrap(env["OSWIND_PUBLICATION_SOURCE_CRASH_PHASE"]);try Data(phase.utf8).write(to:URL(fileURLWithPath:path).appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);sqlite3_result_error(context,"Owned source worker not killed",-1)}catch {sqlite3_result_error(context,"Owned source worker gate failed",-1)}
                },nil,nil,nil),SQLITE_OK)
                let trigger:String
                if phase=="redacted" {trigger="AFTER UPDATE OF title ON main.chat_sessions WHEN new.title='Conversation'"}
                else if phase=="withdrawn" {trigger="AFTER DELETE ON main.chat_turns"}
                else {trigger="AFTER DELETE ON main.memories"}
                try f.bc.database.execute("CREATE TEMP TRIGGER owned_source_queue_gate \(trigger) BEGIN SELECT owned_source_queue_gate(); END")
            }
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            try f.b.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
                _=try service.receive(target,record:nil,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Body-free source erasure cannot fetch")})
                if phase=="before" {try hold()}
            }}
            if phase=="after" {try hold()}
        }
    }
}
