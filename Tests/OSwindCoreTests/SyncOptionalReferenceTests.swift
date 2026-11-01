import XCTest
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private struct OptionalRunFixture {
        let a:MemoryStore,ac:SyncVersionStore,b:MemoryStore,bc:SyncVersionStore,c:MemoryStore,cc:SyncVersionStore
        let initial:[SyncRevision],operation:SyncRevision,record:SyncPortableRecord,conversation:SyncObjectIdentity
        let eraserChat:String,prompt:String,runLocal:String?
    }
    private func withOptionalRun(known:Bool,_ body:(OptionalRunFixture)throws->Void)throws {
        let third="00000000-0000-0000-0000-000000006173"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("eraser",third)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(third);try cc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="owned-optional-controls";recipe.prompt="Exact original 👩🏽‍💻 e\u{301} prompt";recipe.schedule.timeZone="UTC"
        _=try a.saveRoutine(recipe,now:now);let claim=try XCTUnwrap(a.claimRoutine(id:recipe.id,now:now))
        _=try a.completeRoutine(claim,answer:.init(text:"Owned completed result",sources:[],provider:"owned",duration:0),policy:.init());try drain(a,ac)
        let initial=try ac.journal.outbox(),operation=try XCTUnwrap(initial.last {$0.key.kind == .routineRun}),record=try packet(operation,ac)
        guard case .routineRun(let run)=record.body else {throw OSwindError.invalid("Owned fixture needs a native completed run")}
        let optional=try XCTUnwrap(run.conversation);var erasedLocal:String?,runLocal:String?
        for preceding in initial {
            let packet=try self.packet(preceding,ac)
            if known || preceding.dot.counter<operation.dot.counter {
                let local=try receive(preceding,packet,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
                if packet.identity==record.identity {runLocal=local}
            }
            if preceding.dot.counter<operation.dot.counter {
                let local=try receive(preceding,packet,c,cc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
                if packet.identity==optional {erasedLocal=local}
            }
        }
        try body(.init(a:a,ac:ac,b:b,bc:bc,c:c,cc:cc,initial:initial,operation:operation,record:record,conversation:optional,eraserChat:try XCTUnwrap(erasedLocal),prompt:recipe.prompt,runLocal:runLocal))
    }
    func testMissingLiveOptionalConversationRemainsRetryableWithoutBarrierOrReceipt()throws {
        try withOptionalRun(known:false) {f in
            let local=try XCTUnwrap(f.bc.catalog.object(f.conversation)?.primary?.first)
            guard case .text(let bytes)=local,let chat=String(data:bytes,encoding:.utf8) else {return XCTFail("Missing owned chat")}
            // Inject a missing native projection, without the authority of a
            // journal deletion. This must never be mistaken for known erasure.
            try f.b.withRoutineDatabase {db in let row=try db.statement("DELETE FROM chat_sessions WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,chat);try db.done(row)}
            let cursor=try f.bc.journal.cursor(for:producerID),outbox=try f.bc.journal.outbox()
            XCTAssertThrowsError(try receive(f.operation,f.record,f.b,f.bc,fetch:{ref in try XCTUnwrap(f.ac.record(ref,admit:{_ in}))}))
            XCTAssertEqual(try f.bc.journal.cursor(for:producerID),cursor);XCTAssertEqual(try f.bc.journal.outbox(),outbox)
            XCTAssertFalse(try f.bc.journal.state(for:f.conversation.key).isDeleted);XCTAssertFalse(try f.bc.journal.state(for:f.record.identity.key).isDeleted)
            XCTAssertEqual(try count(f.b,"routine_runs"),0);XCTAssertEqual(try count(f.b,"routine_run_originals"),0)
        }
    }
    func testDetachedRunQuietRestorePreservesRecipeWithoutOldLifetimeAuthority()throws {
        try withOptionalRun(known:true) {f in
            try f.c.deleteChat(f.eraserChat);try drain(f.c,f.cc)
            for deletion in try f.cc.journal.outbox() {try receiveDeletion(deletion,f.b,f.bc)}
            let local=try XCTUnwrap(f.runLocal),archive=root.appendingPathComponent("detached.oswindbackup"),restored=root.appendingPathComponent("detached-restored")
            _=try LibraryBackup.create(store:f.b,destination:archive);_=try LibraryBackup.restore(archive,to:restored)
            let target=try MemoryStore(root:restored);defer {try? target.close()}
            XCTAssertEqual(try target.routineRuns().first?.original?.recipePrompt,f.prompt);XCTAssertNil(try target.routineRuns().first?.chatID)
            XCTAssertEqual(try target.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).read(local)?.record.encoded()},try f.record.encoded())
            let fresh=try target.withRoutineDatabase {db in
                _=try SyncChangeCapture.activate(db);let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:"00000000-0000-0000-0000-000000006179",group:group,epoch:epoch)
                return try SyncVersionStore.install(catalog:catalog,journal:journal)
            }
            XCTAssertThrowsError(try fresh.erasedRunConversation(localRunID:local));try drain(target,fresh)
            let op=try XCTUnwrap(fresh.journal.outbox().first {$0.key.kind == .routineRun}),forwarded=try packet(op,fresh)
            guard case .routineRun(let body)=forwarded.body else {return XCTFail("No restored run")}
            XCTAssertNotEqual(forwarded.identity,f.record.identity);XCTAssertNil(body.conversation)
            XCTAssertEqual(try fresh.resolve(forwarded.identity,content:nil,admit:{_ in}).encoded(),try forwarded.encoded())
            XCTAssertEqual(try target.routineRuns().first?.original?.recipePrompt,f.prompt)
        }
    }
    func testOptionalConversationRetryAndNewLifetimeNeverReattachOldRun()throws {
        try withOptionalRun(known:true) {f in
            let oldLocal=try XCTUnwrap(f.b.routineRuns().first?.chatID)
            try f.c.deleteChat(f.eraserChat);try drain(f.c,f.cc)
            let operations=try f.cc.journal.outbox()
            for deletion in operations {try receiveDeletion(deletion,f.b,f.bc)}
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            let writer=SyncIncomingConversationWriter(library:f.b,cache:f.bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
            let before=try f.bc.journal.outbox()
            for deletion in operations {
                let result=try f.bc.journal.receive(deletion,contentAvailable:{_ in true}) {_ in XCTFail("Duplicate must not reapply")}
                XCTAssertEqual(result.applied,0)
                try writer.applyDeletionBarrier(deletion.key,admission:lease)
            }
            // Owned reuse of the exact native primary key must get a fresh
            // catalog lifetime. It cannot satisfy the old optional wire link.
            try f.b.withRoutineDatabase {db in let row=try db.statement("INSERT INTO chat_sessions(id,title,created,updated) VALUES(?,'New lifetime',1700000000,1700000000)");defer {sqlite3_finalize(row)};db.bind(row,1,oldLocal);try db.done(row)}
            try drain(f.b,f.bc)
            let newIdentity=try f.bc.catalog.localIdentity(.conversation,primary:[.text(Data(oldLocal.utf8))])
            XCTAssertNotEqual(newIdentity,f.conversation);XCTAssertTrue(try f.bc.journal.state(for:f.conversation.key).isDeleted)
            XCTAssertNil(try f.b.routineRuns().first?.chatID);XCTAssertEqual(try f.b.routineRuns().first?.original?.recipePrompt,f.prompt)
            XCTAssertEqual(try f.bc.resolve(f.record.identity,content:nil,admit:{_ in}).encoded(),try f.record.encoded())
            XCTAssertEqual(try f.bc.journal.outbox().count,before.count+1)
        }
    }
    func testOptionalConversationDetachmentCrossesBatchAndNegativeRowIDBoundary()throws {
        try withOptionalRun(known:true) {f in
            // Owned raw population shares a conversation across 130 runs.
            // Actual outgoing export and incoming projection create all packets
            // and protected originals; this is not a public API ingress claim.
            let cursor=try XCTUnwrap(f.initial.last).dot.counter
            try f.a.withRoutineDatabase {db in try db.transaction {
                let row=try db.statement("""
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<129)
                INSERT INTO routine_runs(id,routine_id,revision,scheduled_at,started,finished,trigger,status,chat_id,message,scope)
                SELECT printf('owned-batch-%03d',x),r.routine_id,r.revision,r.scheduled_at+x,r.started+x,r.finished+x,'manual',r.status,r.chat_id,r.message,r.scope FROM n CROSS JOIN routine_runs r WHERE r.id=?
                """);defer {sqlite3_finalize(row)};db.bind(row,1,try XCTUnwrap(f.a.routineRuns().first?.id));try db.done(row)
            }}
            try drain(f.a,f.ac)
            var received=0
            for op in try f.ac.journal.outbox(after:cursor,limit:256) {
                let value=try packet(op,f.ac)
                _=try receive(op,value,f.b,f.bc,fetch:{ref in try XCTUnwrap(f.ac.record(ref,admit:{_ in}))});received+=1
            }
            XCTAssertEqual(received,129);XCTAssertEqual(try count(f.b,"routine_run_originals"),130)
            try f.b.withRoutineDatabase {db in
                // Native rowid is not part of the exact 11-cell original.
                try db.execute("UPDATE routine_runs SET rowid=-9223372036854775808 WHERE rowid=(SELECT min(rowid) FROM routine_runs)")
                var seen=[String]()
                try RoutineRunOriginalStore(db:db).forEachLinkedRun(chatID:try XCTUnwrap(f.b.routineRuns().first?.chatID)) {local,_,_ in seen.append(local)}
                XCTAssertEqual(seen.count,130);XCTAssertEqual(Set(seen).count,130)
            }
            try f.c.deleteChat(f.eraserChat);try drain(f.c,f.cc)
            for op in try f.cc.journal.outbox() {try receiveDeletion(op,f.b,f.bc)}
            XCTAssertEqual(try count(f.b,"routine_run_originals"),130)
            let runs=try f.b.routineRuns(limit:200);XCTAssertEqual(runs.count,130)
            XCTAssertTrue(runs.allSatisfy {$0.chatID==nil && $0.original?.recipePrompt==f.prompt})
            for run in runs {
                let original=try f.b.withRoutineDatabase {try XCTUnwrap(RoutineRunOriginalStore(db:$0).read(run.id))}
                XCTAssertEqual(try f.bc.resolve(original.record.identity,content:nil,admit:{_ in}).encoded(),try original.record.encoded())
            }
            XCTAssertTrue(try f.bc.journal.outbox().isEmpty);XCTAssertEqual(try count(f.b,"personal_sync_changes"),0)
        }
    }
    func testOptionalDetachmentRejectsForeignConnectionAndChangedNativeFrame()throws {
        try withOptionalRun(known:true) {f in
            let local=try XCTUnwrap(f.runLocal),chat=try XCTUnwrap(f.b.routineRuns().first?.chatID)
            let original=try f.b.withRoutineDatabase {try XCTUnwrap(RoutineRunOriginalStore(db:$0).read(local))},before=try f.b.withRoutineDatabase {try XCTUnwrap(RoutineRunOriginalStore(db:$0).frame(local))}
            try f.a.withRoutineDatabase {db in XCTAssertThrowsError(try f.b.detachRunOriginalConversation(local,from:chat,original:original,before:before,db:db))}
            try f.b.withRoutineDatabase {db in
                XCTAssertThrowsError(try f.b.detachRunOriginalConversation(local,from:chat,original:original,before:before,db:db),"A valid frame still requires an atomic transaction")
                try db.transaction {
                    var cells=before.cells;cells[9] = .text(Data("changed native message".utf8))
                    XCTAssertThrowsError(try f.b.detachRunOriginalConversation(local,from:chat,original:original,before:SyncRowSnapshot(cells),db:db))
                    XCTAssertThrowsError(try f.b.detachRunOriginalConversation(local,from:"foreign-chat",original:original,before:before,db:db))
                }
                XCTAssertEqual(try RoutineRunOriginalStore(db:db).frame(local),before);XCTAssertEqual(try RoutineRunOriginalStore(db:db).read(local),original)
            }
        }
    }
    func testOptionalConversationCancellationAfterDetachmentRollsBackEveryProjection()throws {
        try withOptionalRun(known:true) {f in
            try f.c.deleteChat(f.eraserChat);try drain(f.c,f.cc)
            let operations=try f.cc.journal.outbox(),target=try XCTUnwrap(operations.first {$0.key == (try? f.conversation.key)})
            for op in operations where op.dot.counter<target.dot.counter {try receiveDeletion(op,f.b,f.bc)}
            let local=try XCTUnwrap(f.runLocal),before=try f.b.withRoutineDatabase {try XCTUnwrap(RoutineRunOriginalStore(db:$0).frame(local))},outbox=try f.bc.journal.outbox(),cursor=try f.bc.journal.cursor(for:target.dot.replica)
            try f.b.withRoutineDatabase {db in
                guard sqlite3_create_function_v2(db.handle,"owned_cancel_optional",0,SQLITE_UTF8,nil,{context,_,_ in withUnsafeCurrentTask {$0?.cancel()};sqlite3_result_int(context,1)},nil,nil,nil)==SQLITE_OK else {throw db.error()}
                try db.execute("CREATE TEMP TRIGGER owned_optional_cancel BEFORE DELETE ON chat_sessions BEGIN SELECT owned_cancel_optional(); END")
            }
            let finished=expectation(description:"Owned cancelled deletion unwinds")
            Task.detached {
                defer {finished.fulfill()}
                do {try self.receiveDeletion(target,f.b,f.bc);XCTFail("Cancelled deletion must roll back")}
                catch {XCTAssertTrue(error is CancellationError,"Unexpected cancellation result: \(error)")}
            }
            wait(for:[finished],timeout:10)
            XCTAssertEqual(try f.bc.journal.cursor(for:target.dot.replica),cursor);XCTAssertEqual(try f.bc.journal.outbox(),outbox);XCTAssertFalse(try f.bc.journal.state(for:f.conversation.key).isDeleted)
            XCTAssertEqual(try f.b.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).frame(local)},before)
            XCTAssertEqual(try f.b.routineRuns().first?.original?.recipePrompt,f.prompt)
            XCTAssertEqual(try f.bc.resolve(f.record.identity,content:nil,admit:{_ in}).encoded(),try f.record.encoded())
            try f.b.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_optional_cancel")}
            try receiveDeletion(target,f.b,f.bc)
            XCTAssertNil(try f.b.routineRuns().first?.chatID)
        }
    }
    private struct OptionalCrashState:Codable {
        let target:SyncRevision,record:SyncPortableRecord,conversation:SyncObjectIdentity,local:String,frame:Data,prompt:String
        let cursor:Int64?,outbox:Int,versions:Int,conversationVersions:Int
    }
    func testOptionalConversationDeathBeforeCommitPreservesOriginalAndReceipt()throws {try crashOptionalConversation("before")}
    func testOptionalConversationDeathAfterCommitPreservesDetachedOriginalAndReceipt()throws {try crashOptionalConversation("after")}
    private func openOptionalCrash(_ base:URL)throws->(MemoryStore,SyncVersionStore) {
        let store=try MemoryStore(root:base.appendingPathComponent("receiver"))
        let cache=try store.withRoutineDatabase {db in
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:receiverID,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        };return(store,cache)
    }
    private func checkOptionalCrash(_ state:OptionalCrashState,committed:Bool,store:MemoryStore,cache:SyncVersionStore)throws {
        let run=try XCTUnwrap(store.routineRuns().first)
        XCTAssertEqual(run.id,state.local);XCTAssertEqual(run.original?.recipePrompt,state.prompt)
        var cells=try SyncRowSnapshot.decode(state.frame).cells;if committed {cells[8] = .null}
        XCTAssertEqual(try store.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).frame(state.local)},try SyncRowSnapshot(cells))
        XCTAssertEqual(try store.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).read(state.local)?.record.encoded()},try state.record.encoded())
        XCTAssertEqual(try cache.resolve(state.record.identity,content:nil,admit:{_ in}).encoded(),try state.record.encoded())
        XCTAssertEqual(try cache.journal.state(for:state.conversation.key).isDeleted,committed);XCTAssertFalse(try cache.journal.state(for:state.record.identity.key).isDeleted)
        XCTAssertEqual(try cache.journal.cursor(for:state.target.dot.replica),committed ? state.target.dot.counter:state.cursor)
        XCTAssertEqual(try cache.journal.outbox().count,state.outbox);XCTAssertEqual(try count(store,"personal_sync_versions"),state.versions-(committed ? state.conversationVersions:0))
        XCTAssertEqual(try count(store,"personal_sync_changes"),0)
        try store.withRoutineDatabase {XCTAssertEqual(try $0.eraseCount("SELECT count(*) FROM pragma_foreign_key_check"),0)}
    }
    private func crashOptionalConversation(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,base=fm.temporaryDirectory.appendingPathComponent("owned-incoming-source-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:base)}
        try Data(nonce.utf8).write(to:base.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=base.appendingPathComponent("child.log"),gate=base.appendingPathComponent("ready")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path),fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw OSwindError.invalid("Invalid owned optional crash runner")}
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncIncomingSourceTests/testOptionalConversationCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_INCOMING_SOURCE_CRASH_ROOT":base.path,"OSWIND_INCOMING_SOURCE_CRASH_NONCE":nonce,"OSWIND_OPTIONAL_CONVERSATION_CRASH_PHASE":phase]
        for index in 0..<_dyld_image_count() {guard let p=_dyld_get_image_name(index) else {continue};let file=URL(fileURLWithPath:String(cString:p)).resolvingSymlinksInPath();if file.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=file.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {return XCTFail("Owned optional worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let state=try JSONDecoder().decode(OptionalCrashState.self,from:Data(contentsOf:base.appendingPathComponent("expected.json")))
        let (store,cache)=try openOptionalCrash(base);try checkOptionalCrash(state,committed:phase=="after",store:store,cache:cache);try store.close()
        if keep {try fm.copyItem(at:base,to:root.appendingPathComponent("optional-crash-"+phase))}
        let (retry,rc)=try openOptionalCrash(base);defer {try? retry.close()};let lease=try retry.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:retry,cache:rc,admit:{_ in XCTFail("Content-free deletion must not invoke body policy")},pathsFor:{_,_ in XCTFail("No deletion media");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        let result=try rc.journal.receive(state.target,contentAvailable:{_ in true}) {change in try writer.applyDeletion(change,admission:lease)}
        XCTAssertEqual(result.applied,phase=="before" ? 1:0);try checkOptionalCrash(state,committed:true,store:retry,cache:rc)
        try writer.applyDeletionBarrier(state.target.key,admission:lease);try checkOptionalCrash(state,committed:true,store:retry,cache:rc)
        print("OPTIONAL_CONVERSATION_CRASH phase=\(phase) exactOriginal=true detachedFingerprint=true receiptAtomic=true noEcho=true retryIdempotent=true")
    }
    func testOptionalConversationCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"] != nil,let phase=env["OSWIND_OPTIONAL_CONVERSATION_CRASH_PHASE"],["before","after"].contains(phase) else {throw XCTSkip("Only run as owned optional-conversation crash child")}
        try withOptionalRun(known:true) {f in
            try f.c.deleteChat(f.eraserChat);try drain(f.c,f.cc)
            let operations=try f.cc.journal.outbox(),target=try XCTUnwrap(operations.first {$0.key == (try? f.conversation.key)})
            for op in operations where op.dot.counter<target.dot.counter {try receiveDeletion(op,f.b,f.bc)}
            let local=try XCTUnwrap(f.runLocal),state=OptionalCrashState(target:target,record:f.record,conversation:f.conversation,local:local,frame:try f.b.withRoutineDatabase {try XCTUnwrap(RoutineRunOriginalStore(db:$0).frame(local)).encoded()},prompt:f.prompt,cursor:try f.bc.journal.cursor(for:target.dot.replica),outbox:try f.bc.journal.outbox().count,versions:try count(f.b,"personal_sync_versions"),conversationVersions:try f.b.withRoutineDatabase {db in
                let row=try db.statement("SELECT count(*) FROM personal_sync_versions WHERE object_digest=?");defer {sqlite3_finalize(row)};db.bind(row,1,try target.key.digest);guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return Int(sqlite3_column_int64(row,0))
            })
            try SyncProtocolLimits.encode(state).write(to:root.appendingPathComponent("expected.json"),options:.atomic)
            func hold()throws {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop owned optional worker")}
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            let writer=SyncIncomingConversationWriter(library:f.b,cache:f.bc,admit:{_ in XCTFail("No deletion body callback")},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
            _=try f.bc.journal.receive(target,contentAvailable:{_ in true}) {change in try writer.applyDeletion(change,admission:lease);if phase=="before" {try hold()}}
            if phase=="after" {try hold()}
        }
    }
    func testMissingDetachedRunCachedBodyRefusesInsteadOfRewritingOriginalReference()throws {
        try withOptionalRun(known:true) {f in
            let local=try XCTUnwrap(f.runLocal),chat=try XCTUnwrap(f.b.routineRuns().first?.chatID)
            try f.b.deleteChat(chat);try drain(f.b,f.bc)
            XCTAssertEqual(try f.bc.erasedRunConversation(localRunID:local),f.conversation)
            // Deliberate owned cache corruption: the protected original alone
            // cannot authorize a new packet that silently drops its wire link.
            try f.b.withRoutineDatabase {db in let row=try db.statement("DELETE FROM personal_sync_versions WHERE object_digest=?");defer {sqlite3_finalize(row)};db.bind(row,1,try f.record.identity.key.digest);try db.done(row)}
            XCTAssertThrowsError(try f.bc.erasedRunConversation(localRunID:local))
            XCTAssertEqual(try f.b.routineRuns().first?.original?.recipePrompt,f.prompt);XCTAssertNil(try f.b.routineRuns().first?.chatID)
            XCTAssertFalse(try f.bc.journal.state(for:f.record.identity.key).isDeleted)
        }
    }
    func testOptionalConversationDeletionFailureRollsBackDetachmentOriginalAndReceipt()throws {
        try withOptionalRun(known:true) {f in
            let local=try XCTUnwrap(f.runLocal),original=try f.b.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).read(local)?.encoded()},frame=try f.b.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).frame(local)?.encoded()}
            try f.c.deleteChat(f.eraserChat);try drain(f.c,f.cc)
            let deletes=try f.cc.journal.outbox(),target=try XCTUnwrap(deletes.first {$0.key == (try? f.conversation.key)})
            for preceding in deletes where preceding.dot.counter<target.dot.counter {try receiveDeletion(preceding,f.b,f.bc)}
            let cursor=try f.bc.journal.cursor(for:target.dot.replica),outbox=try f.bc.journal.outbox(),clock=try f.bc.journal.state(for:f.conversation.key).clock
            try f.b.withRoutineDatabase {try $0.execute("CREATE TEMP TRIGGER owned_optional_abort BEFORE DELETE ON chat_sessions BEGIN SELECT RAISE(ABORT,'Owned optional rejection'); END")}
            XCTAssertThrowsError(try receiveDeletion(target,f.b,f.bc)) {error in XCTAssertTrue(error.localizedDescription.contains("Owned optional rejection"))}
            XCTAssertEqual(try f.bc.journal.cursor(for:target.dot.replica),cursor);XCTAssertEqual(try f.bc.journal.outbox(),outbox);XCTAssertEqual(try f.bc.journal.state(for:f.conversation.key).clock,clock)
            XCTAssertFalse(try f.bc.journal.state(for:f.conversation.key).isDeleted)
            XCTAssertEqual(try f.b.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).read(local)?.encoded()},original)
            XCTAssertEqual(try f.b.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).frame(local)?.encoded()},frame)
            XCTAssertEqual(try f.bc.resolve(f.record.identity,content:nil,admit:{_ in}).encoded(),try f.record.encoded())
            try f.b.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_optional_abort")}
            try receiveDeletion(target,f.b,f.bc)
            for following in deletes where following.dot.counter>target.dot.counter {try receiveDeletion(following,f.b,f.bc)}
            XCTAssertNil(try f.b.routineRuns().first?.chatID);XCTAssertEqual(try f.b.routineRuns().first?.original?.recipePrompt,f.prompt)
            XCTAssertEqual(try f.bc.resolve(f.record.identity,content:nil,admit:{_ in}).encoded(),try f.record.encoded())
        }
    }
    func testLocalConversationDeletionKeepsImportedRunOriginalAndOutgoingProgress()throws {
        try withOptionalRun(known:true) {f in
            let chat=try XCTUnwrap(f.b.routineRuns().first?.chatID)
            try f.b.deleteChat(chat)
            XCTAssertEqual(try f.b.routineRuns().first?.original?.recipePrompt,f.prompt)
            XCTAssertNil(try f.b.routineRuns().first?.chatID)
            var failure:Error?
            do {try drain(f.b,f.bc)}catch {failure=error}
            XCTAssertNil(failure,"Local conversation erasure must preserve its independent run and sender progress: \(String(describing:failure))")
            XCTAssertTrue(try f.bc.journal.state(for:f.conversation.key).isDeleted);XCTAssertFalse(try f.bc.journal.state(for:f.record.identity.key).isDeleted)
            XCTAssertEqual(try f.bc.record(f.record.reference,admit:{_ in})?.encoded(),try f.record.encoded())
            XCTAssertNoThrow(try f.bc.resolve(f.record.identity,content:nil,admit:{_ in}))
            XCTAssertEqual(try f.b.routineRuns().first?.original?.recipePrompt,f.prompt)
        }
    }
    func testKnownRunKeepsExactOriginalAfterOptionalConversationDeletion()throws {
        let thirdID="00000000-0000-0000-0000-000000006172"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("eraser",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="owned-known-optional";recipe.prompt="Retain the actual original prompt";recipe.schedule.timeZone="UTC"
        _=try a.saveRoutine(recipe,now:now);let claim=try XCTUnwrap(a.claimRoutine(id:recipe.id,now:now))
        _=try a.completeRoutine(claim,answer:.init(text:"Owned completed result",sources:[],provider:"owned",duration:0),policy:.init());try drain(a,ac)
        let initial=try ac.journal.outbox(),operation=try XCTUnwrap(initial.last {$0.key.kind == .routineRun}),record=try packet(operation,ac)
        guard case .routineRun(let body)=record.body else {return XCTFail("Expected actual completed run")}
        let optional=try XCTUnwrap(body.conversation),runCounter=operation.dot.counter;var erasedLocal:String?,runLocal:String?
        for operation in initial {
            let packet=try self.packet(operation,ac),local=try receive(operation,packet,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if packet.identity==record.identity {runLocal=local}
            if operation.dot.counter<runCounter {
                let local=try receive(operation,packet,c,cc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
                if packet.identity==optional {erasedLocal=local}
            }
        }
        let local=try XCTUnwrap(runLocal);XCTAssertEqual(try b.routineRuns().first?.id,local)
        try c.deleteChat(try XCTUnwrap(erasedLocal));try drain(c,cc)
        for deletion in try cc.journal.outbox() {try receiveDeletion(deletion,b,bc)}
        XCTAssertTrue(try bc.journal.state(for:optional.key).isDeleted);XCTAssertFalse(try bc.journal.state(for:record.identity.key).isDeleted)
        let run=try XCTUnwrap(b.routineRuns().first);XCTAssertEqual(run.id,local);XCTAssertEqual(run.status,.completed);XCTAssertNil(run.chatID)
        XCTAssertEqual(run.original?.recipePrompt,recipe.prompt)
        var resolved:SyncPortableRecord?,failure:Error?
        do {resolved=try bc.resolve(record.identity,content:nil,admit:{_ in})}catch {failure=error}
        XCTAssertNil(failure,"An independent stored run must retain its exact original after optional conversation deletion: \(String(describing:failure))")
        XCTAssertEqual(try resolved?.encoded(),try record.encoded())
        XCTAssertEqual(try b.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).read(local)?.record.encoded()},try record.encoded())
    }
    func testUnseenRunSurvivesErasedOptionalConversationAndKeepsExactOriginal()throws {
        let thirdID="00000000-0000-0000-0000-000000006171"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("eraser",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="owned-optional-conversation";recipe.title="Independent recipe";recipe.prompt="Preserve this exact original prompt";recipe.schedule.timeZone="UTC"
        _=try a.saveRoutine(recipe,now:now)
        let claim=try XCTUnwrap(a.claimRoutine(id:recipe.id,now:now))
        let finished=try XCTUnwrap(a.completeRoutine(claim,answer:.init(text:"Owned completed result",sources:[],provider:"owned",duration:0),policy:.init()))
        XCTAssertEqual(finished.status,.completed);XCTAssertNotNil(finished.chatID)
        try drain(a,ac)
        let initial=try ac.journal.outbox(),operation=try XCTUnwrap(initial.last {$0.key.kind == .routineRun}),record=try packet(operation,ac)
        guard case .routineRun(let body)=record.body else {return XCTFail("Expected actual completed run")}
        let optional=try XCTUnwrap(body.conversation);var erasedLocal:String?
        for preceding in initial where preceding.dot.counter<operation.dot.counter {
            let packet=try self.packet(preceding,ac)
            _=try receive(preceding,packet,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            let local=try receive(preceding,packet,c,cc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if packet.identity==optional {erasedLocal=local}
        }
        XCTAssertEqual(try count(b,"routine_runs"),0,"Withhold the actual run, not its optional conversation")
        try c.deleteChat(try XCTUnwrap(erasedLocal));try drain(c,cc)
        for deletion in try cc.journal.outbox() {XCTAssertEqual(deletion.mutation,.delete);try receiveDeletion(deletion,b,bc)}
        XCTAssertTrue(try bc.journal.state(for:optional.key).isDeleted)
        let before=try bc.journal.outbox();var projected:String?,failure:Error?
        do {projected=try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}catch {failure=error}
        XCTAssertNil(failure,"An erased optional conversation must not block an independent completed run: \(String(describing:failure))")
        XCTAssertEqual(try count(b,"routine_runs"),1)
        XCTAssertEqual(try bc.journal.cursor(for:producerID),operation.dot.counter)
        XCTAssertFalse(try bc.journal.state(for:record.identity.key).isDeleted,"A nullable conversation is not the run's owner")
        guard failure==nil else {return}
        let run=try XCTUnwrap(b.routineRuns().first)
        XCTAssertEqual(run.id,projected);XCTAssertEqual(run.status,.completed);XCTAssertNil(run.chatID);XCTAssertFalse(run.resultAvailable)
        XCTAssertEqual(run.original?.recipePrompt,recipe.prompt)
        XCTAssertEqual(try bc.resolve(record.identity,content:nil,admit:{_ in}).encoded(),try record.encoded())
        XCTAssertEqual(try b.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).read(run.id)?.record.encoded()},try record.encoded())
        XCTAssertEqual(try bc.journal.outbox(),before,"Preserving an independent run must not invent a deletion or echo")
        // Remaining predecessors can be stale puts for the erased conversation.
        // The caller must use their admitted outcome, not blindly project them.
        for following in initial where following.dot.counter>operation.dot.counter {
            let packet=try self.packet(following,ac),lease=try b.mediaWriteLease();defer {lease.release()}
            let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
            _=try bc.journal.receive(following,contentAvailable:{_ in true}) {change in
                if change.after.isDeleted {try writer.applyDeletion(change,admission:lease)}
                else {_=try writer.applyOutcome(packet,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}
            }
        }
        _=try a.createChat(title:"Independent later sender record");try drain(a,ac)
        let later=try XCTUnwrap(ac.journal.outbox().last),laterRecord=try packet(later,ac)
        _=try receive(later,laterRecord,b,bc,fetch:{_ in laterRecord})
        XCTAssertEqual(try bc.journal.cursor(for:producerID),later.dot.counter)
        XCTAssertEqual(try b.chats().map(\.title),["Independent later sender record"])
        XCTAssertTrue(try bc.journal.state(for:optional.key).isDeleted)
    }
}
