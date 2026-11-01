import XCTest
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private struct ScopeCrashState:Codable {
        let target:SyncRevision,entity:SyncObjectIdentity,turn:SyncPortableRecord,run:SyncPortableRecord
        let chatLocal:String,runLocal:String,entityLocal:String,turnFrame:Data,runFrame:Data,original:Data
        let cursor:Int64?,outbox:[SyncRevision]
    }
    private func scopeTurnFrame(_ store:MemoryStore,_ id:String)throws->SyncRowSnapshot {
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT "+SyncCanonicalTable.turn.schema.snapshot("t")+" FROM chat_turns t WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id)
            guard sqlite3_step(row)==SQLITE_ROW,let p=sqlite3_column_blob(row,0) else {throw db.error()};return try .decode(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))))
        }
    }
    private func openScopeCrash(_ base:URL)throws->(MemoryStore,SyncVersionStore) {
        let store=try MemoryStore(root:base.appendingPathComponent("receiver"))
        let cache=try store.withRoutineDatabase {db in let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:receiverID,group:group,epoch:epoch);return try SyncVersionStore.install(catalog:catalog,journal:journal)}
        return (store,cache)
    }
    private func checkScopeCrash(_ state:ScopeCrashState,committed:Bool,store:MemoryStore,cache:SyncVersionStore)throws {
        let turn=try XCTUnwrap(store.chatTurns(state.chatLocal).first),run=try XCTUnwrap(store.routineRuns().first)
        var expectedTurn=try SyncRowSnapshot.decode(state.turnFrame).cells,expectedRun=try SyncRowSnapshot.decode(state.runFrame).cells
        if committed {
            let marker=try XCTUnwrap(cache.projectErasedFilterScope(state.entity))
            guard case .blob(let turnBytes)=expectedTurn[3],case .blob(let runBytes)=expectedRun[10] else {return XCTFail("Owned frame differs")}
            var payload=try JSONDecoder().decode(ChatPayload.self,from:turnBytes),scope=try JSONDecoder().decode(SearchFilter.self,from:runBytes)
            payload.filter.entityID=nil;payload.filter.unavailableEntityScope=marker;scope.entityID=nil;scope.unavailableEntityScope=marker
            expectedTurn[3] = .blob(try SyncProtocolLimits.encode(payload));expectedRun[10] = .blob(try SyncProtocolLimits.encode(scope))
            XCTAssertNil(try store.entity(state.entityLocal));XCTAssertThrowsError(try store.search(turn.filter,mode:.keyword))
        }else {XCTAssertNotNil(try store.entity(state.entityLocal));XCTAssertNil(turn.filter.unavailableEntityScope)}
        XCTAssertEqual(try scopeTurnFrame(store,turn.id),try SyncRowSnapshot(expectedTurn))
        XCTAssertEqual(try store.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).frame(state.runLocal)},try SyncRowSnapshot(expectedRun))
        XCTAssertEqual(try store.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).read(state.runLocal)?.encoded()},state.original)
        XCTAssertEqual(run.original?.recipePrompt,"Original scoped 👩🏽‍💻 e\u{301} prompt");XCTAssertEqual(turn.answer.text,"Original scoped answer 👩🏽‍💻 e\u{301}")
        for record in [state.turn,state.run] {XCTAssertEqual(try cache.resolve(record.identity,content:nil,admit:{_ in}).encoded(),try record.encoded());XCTAssertFalse(try cache.journal.state(for:record.identity.key).isDeleted)}
        XCTAssertEqual(try cache.journal.state(for:state.entity.key).isDeleted,committed);XCTAssertEqual(try cache.journal.cursor(for:state.target.dot.replica),committed ? state.target.dot.counter:state.cursor)
        XCTAssertEqual(try cache.journal.outbox(),state.outbox);XCTAssertEqual(try count(store,"personal_sync_changes"),0)
        try store.withRoutineDatabase {XCTAssertEqual(try $0.eraseCount("SELECT count(*) FROM pragma_foreign_key_check"),0);try EntityScopeSchema.validate($0)}
    }
    func testUnavailableScopeDeathBeforeCommitPreservesActiveFramesAndReceipt()throws {try crashUnavailableScope("before")}
    func testUnavailableScopeDeathAfterCommitPreservesUnavailableFramesAndOriginals()throws {try crashUnavailableScope("after")}
    private func crashUnavailableScope(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,base=fm.temporaryDirectory.appendingPathComponent("owned-incoming-source-crash-"+nonce)
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:base)}
        try Data(nonce.utf8).write(to:base.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=base.appendingPathComponent("child.log"),gate=base.appendingPathComponent("ready")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path),fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw OSwindError.invalid("Invalid owned scope crash runner")}
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncIncomingSourceTests/testUnavailableScopeCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_INCOMING_SOURCE_CRASH_ROOT":base.path,"OSWIND_INCOMING_SOURCE_CRASH_NONCE":nonce,"OSWIND_UNAVAILABLE_SCOPE_CRASH_PHASE":phase]
        for index in 0..<_dyld_image_count() {guard let p=_dyld_get_image_name(index) else {continue};let file=URL(fileURLWithPath:String(cString:p)).resolvingSymlinksInPath();if file.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=file.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {return XCTFail("Owned scope worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let state=try JSONDecoder().decode(ScopeCrashState.self,from:Data(contentsOf:base.appendingPathComponent("expected.json")))
        let (store,cache)=try openScopeCrash(base);try checkScopeCrash(state,committed:phase=="after",store:store,cache:cache);try store.close()
        if keep {try fm.copyItem(at:base,to:root.appendingPathComponent("entity-scope-crash-"+phase))}
        let (retry,rc)=try openScopeCrash(base);defer {try? retry.close()};let lease=try retry.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:retry,cache:rc,admit:{_ in XCTFail("No body policy during deletion")},pathsFor:{_,_ in XCTFail("No scope deletion media");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        let result=try rc.journal.receive(state.target,contentAvailable:{_ in true}) {try writer.applyDeletion($0,admission:lease)}
        XCTAssertEqual(result.applied,phase=="before" ? 1:0);try checkScopeCrash(state,committed:true,store:retry,cache:rc)
        try writer.applyDeletionBarrier(state.target.key,admission:lease);try checkScopeCrash(state,committed:true,store:retry,cache:rc)
        print("UNAVAILABLE_SCOPE_CRASH phase=\(phase) exactTurnAndRunFrames=true exactOriginal=true receiptAtomic=true noEcho=true retryIdempotent=true")
    }
    func testUnavailableScopeCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"] != nil,let phase=env["OSWIND_UNAVAILABLE_SCOPE_CRASH_PHASE"],["before","after"].contains(phase) else {throw XCTSkip("Only run as owned unavailable-scope crash child")}
        let eraser="00000000-0000-0000-0000-000000006195"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("eraser",eraser)
        defer {try? a.close();try? b.close();try? c.close()};try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(eraser);try cc.journal.allowPeer(producerID)
        let entity=try a.createEntity(kind:.project,name:"Owned crash scope")
        var recipe=RoutineDefinition();recipe.id="owned-scope-crash";recipe.prompt="Original scoped 👩🏽‍💻 e\u{301} prompt";_=try a.saveRoutine(recipe,now:now)
        let claim=try XCTUnwrap(a.claimRoutine(id:recipe.id,now:now));_=try a.completeRoutine(claim,answer:.init(text:"Original scoped answer 👩🏽‍💻 e\u{301}",sources:[],provider:"owned",duration:0),policy:.init())
        let chat=try XCTUnwrap(a.routineRuns().first?.chatID)
        // Owned stored-run filter fixture; routine definitions do not expose
        // entity selectors. Actual outgoing and incoming adapters do the rest.
        try a.withRoutineDatabase {db in try db.transaction {
            let run=try db.statement("UPDATE routine_runs SET scope=? WHERE id=?");defer {sqlite3_finalize(run)};try db.bind(run,1,json:SearchFilter(entityID:entity.id));db.bind(run,2,claim.run.id);try db.done(run)
            let row=try db.statement("SELECT id,payload FROM chat_turns WHERE session_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,chat);XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);let id=db.text(row,0);var value=try db.decode(row,1,as:ChatPayload.self);value.filter.entityID=entity.id
            let turn=try db.statement("UPDATE chat_turns SET payload=? WHERE id=?");defer {sqlite3_finalize(turn)};try db.bind(turn,1,json:value);db.bind(turn,2,id);try db.done(turn)
        }};try drain(a,ac)
        let initial=try ac.journal.outbox(),turnOp=try XCTUnwrap(initial.first {$0.key.kind == .turn}),runOp=try XCTUnwrap(initial.first {$0.key.kind == .routineRun}),turnRecord=try packet(turnOp,ac),runRecord=try packet(runOp,ac)
        guard case .routineRun(let body)=runRecord.body else {throw OSwindError.invalid("Owned run absent")};let scope=try XCTUnwrap(body.filter.entity)
        var entityLocal:String?,eraserLocal:String?,chatLocal:String?,runLocal:String?
        for operation in initial {
            let value=try packet(operation,ac),id=try receive(operation,value,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if value.identity==scope {entityLocal=id};if value.identity==body.conversation {chatLocal=id};if value.identity==runRecord.identity {runLocal=id}
            if operation.dot.counter<min(turnOp.dot.counter,runOp.dot.counter) {let local=try receive(operation,value,c,cc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))});if value.identity==scope {eraserLocal=local}}
        }
        try c.deleteEntity(try XCTUnwrap(eraserLocal));try drain(c,cc)
        let operations=try cc.journal.outbox(),target=try XCTUnwrap(operations.first {$0.key == (try? scope.key)})
        for operation in operations where operation.dot.counter<target.dot.counter {try receiveDeletion(operation,b,bc)}
        let local=try XCTUnwrap(runLocal),nativeChat=try XCTUnwrap(chatLocal),turn=try XCTUnwrap(b.chatTurns(nativeChat).first)
        let state=try ScopeCrashState(target:target,entity:scope,turn:turnRecord,run:runRecord,chatLocal:nativeChat,runLocal:local,entityLocal:XCTUnwrap(entityLocal),turnFrame:scopeTurnFrame(b,turn.id).encoded(),runFrame:b.withRoutineDatabase {try XCTUnwrap(RoutineRunOriginalStore(db:$0).frame(local)).encoded()},original:b.withRoutineDatabase {try XCTUnwrap(RoutineRunOriginalStore(db:$0).read(local)).encoded()},cursor:bc.journal.cursor(for:target.dot.replica),outbox:bc.journal.outbox())
        try SyncProtocolLimits.encode(state).write(to:root.appendingPathComponent("expected.json"),options:.atomic)
        func hold()throws {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop owned scope worker")}
        let lease=try b.mediaWriteLease();defer {lease.release()};let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("No body policy")},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        _=try bc.journal.receive(target,contentAvailable:{_ in true}) {try writer.applyDeletion($0,admission:lease);if phase=="before" {try hold()}}
        if phase=="after" {try hold()}
    }
}
