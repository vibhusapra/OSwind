import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private struct RunCrashState:Codable {
        let action:String,local:String,recipeLocal:String,editorPrompt:String
        let old:SyncPortableRecord?,target:SyncPortableRecord,definition:SyncPortableRecord
        let operation:SyncRevision
        let versions:Int,outbox:Int
    }
    func testIncomingRunCreateDeathBeforeCommitLeavesNoPartialOriginal()throws {try crashRun("create","before")}
    func testIncomingRunCreateDeathAfterCommitRetainsExactOriginal()throws {try crashRun("create","after")}
    func testIncomingRunUpdateDeathBeforeCommitKeepsPriorOriginalAndHead()throws {try crashRun("update","before")}
    func testIncomingRunUpdateDeathAfterCommitKeepsOldWireAndNewStatus()throws {try crashRun("update","after")}
    private func openRunCrashLibrary(_ base:URL,_ name:String,_ replica:String)throws->(MemoryStore,SyncVersionStore) {
        let store=try MemoryStore(root:base.appendingPathComponent(name))
        let cache=try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT enabled FROM personal_sync_capture"),1)
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        }
        // Recovery inspection deliberately does not drain outgoing work.
        return(store,cache)
    }
    private func checkRunCrash(_ state:RunCrashState,_ committed:Bool,_ store:MemoryStore,_ cache:SyncVersionStore)throws {
        let expected=committed ? state.target:state.old
        let runs=try store.routineRuns();XCTAssertEqual(runs.count,expected==nil ? 0:1)
        XCTAssertEqual(try count(store,"routine_run_originals"),expected==nil ? 0:1)
        XCTAssertEqual(try count(store,"personal_sync_versions"),state.versions+(committed ? 1:0))
        XCTAssertEqual(try count(store,"personal_sync_changes"),0);XCTAssertEqual(try cache.journal.outbox().count,state.outbox)
        XCTAssertEqual(try store.routines().first?.definition.prompt,state.editorPrompt);XCTAssertFalse(try XCTUnwrap(store.routines().first).definition.enabled)
        let head=try cache.journal.state(for:state.target.identity.key)
        if let expected {
            let original=try store.withRoutineDatabase {try XCTUnwrap(RoutineRunOriginalStore(db:$0).read(state.local))}
            XCTAssertEqual(try original.record.encoded(),try expected.encoded());XCTAssertEqual(try original.definition?.encoded(),try state.definition.encoded())
            guard case .routineRun(let body)=expected.body else {return XCTFail("No typed run")}
            let run=try XCTUnwrap(runs.first);XCTAssertEqual(run.id,state.local);XCTAssertEqual(run.routineID,state.recipeLocal);XCTAssertEqual(run.status,body.projectedStatus)
            XCTAssertEqual(run.original?.recordedStatus,body.status);XCTAssertEqual(run.original?.recipePrompt,"Original crash recipe prompt");XCTAssertEqual(run.original?.recipeOrdinal,1)
            XCTAssertEqual(try cache.resolve(expected.identity,content:nil,admit:{_ in}).encoded(),try expected.encoded())
            XCTAssertEqual(head.heads.count,1);XCTAssertEqual(head.heads.first?.content,try expected.reference.content)
        }else {XCTAssertNil(try cache.catalog.object(state.target.identity));XCTAssertTrue(head.heads.isEmpty)}
        if let old=state.old {XCTAssertEqual(try cache.record(old.reference,admit:{_ in})?.encoded(),try old.encoded())}
        try store.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM pragma_foreign_key_check"),0)}
    }
    private func crashRun(_ action:String,_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,base=fm.temporaryDirectory.appendingPathComponent("owned-incoming-source-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:base)}
        try Data(nonce.utf8).write(to:base.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=base.appendingPathComponent("child.log"),gate=base.appendingPathComponent("ready")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path),fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw OSwindError.invalid("Invalid owned run crash runner")}
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncIncomingSourceTests/testIncomingRunCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_INCOMING_SOURCE_CRASH_ROOT":base.path,"OSWIND_INCOMING_SOURCE_CRASH_NONCE":nonce,"OSWIND_INCOMING_RUN_CRASH_PHASE":phase,"OSWIND_INCOMING_RUN_CRASH_ACTION":action]
        for index in 0..<_dyld_image_count() {guard let p=_dyld_get_image_name(index) else {continue};let file=URL(fileURLWithPath:String(cString:p)).resolvingSymlinksInPath();if file.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=file.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==action+":"+phase else {return XCTFail("Owned run worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let state=try JSONDecoder().decode(RunCrashState.self,from:Data(contentsOf:base.appendingPathComponent("expected.json")))
        let (producer,pc)=try openRunCrashLibrary(base,"producer",producerID)
        XCTAssertEqual(try pc.record(state.target.reference,admit:{_ in})?.encoded(),try state.target.encoded());XCTAssertEqual(try pc.record(state.definition.reference,admit:{_ in})?.encoded(),try state.definition.encoded());try producer.close()
        let (store,cache)=try openRunCrashLibrary(base,"receiver",receiverID)
        try checkRunCrash(state,phase=="after",store,cache);try store.close()
        if keep {try fm.copyItem(at:base,to:root.appendingPathComponent("retained-crash"))}
        let (retry,rc)=try openRunCrashLibrary(base,"receiver",receiverID)
        let lease=try retry.mediaWriteLease();defer {lease.release()};var applied=false
        let writer=SyncIncomingConversationWriter(library:retry,cache:rc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        let result=try rc.journal.receive(state.operation,contentAvailable:{_ in true}) {_ in
            applied=true;_=try writer.apply(state.target,admission:lease,fetchExactSource:{ref in guard try ref==state.definition.reference else {throw OSwindError.invalid("Unexpected run crash dependency")};return state.definition})
        }
        XCTAssertEqual(result.applied,phase=="before" ? 1:0);XCTAssertEqual(applied,phase=="before")
        try checkRunCrash(state,true,retry,rc);lease.release();try retry.close()
        if keep {try fm.copyItem(at:base,to:root.appendingPathComponent("retained-retry"))}
        print("INCOMING_RUN_CRASH action=\(action) phase=\(phase) exactOriginal=true exactHead=true oldWireRetained=true noEcho=true retryIdempotent=true")
    }
    func testIncomingRunCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"] != nil,let phase=env["OSWIND_INCOMING_RUN_CRASH_PHASE"],["before","after"].contains(phase),let action=env["OSWIND_INCOMING_RUN_CRASH_ACTION"],["create","update"].contains(action) else {throw XCTSkip("Only run as owned incoming-run crash child")}
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);try bc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="crash-recipe";recipe.title="Original crash recipe";recipe.prompt="Original crash recipe prompt";recipe.schedule.timeZone="UTC"
        let first=try a.saveRoutine(recipe,now:now),claim=try XCTUnwrap(a.claimRoutine(id:recipe.id,now:now));try drain(a,ac)
        let initial=try ac.journal.outbox(),recipeOp=try XCTUnwrap(initial.first),definition=try packet(recipeOp,ac),runOp=try XCTUnwrap(initial.last),running=try packet(runOp,ac)
        let recipeLocal=try receive(recipeOp,definition,b,bc,fetch:{_ in definition});var old:SyncPortableRecord?,operation=runOp,target=running
        if action=="update" {
            _=try receive(runOp,running,b,bc,fetch:{_ in definition});old=running
            recipe.prompt="New editor prompt after original run";_=try a.saveRoutine(recipe,expectedRevision:first.revision,now:now.addingTimeInterval(1));_=try a.finishRoutine(claim.run.id,status:.failed,message:"Owned peer terminal update");try drain(a,ac)
            for op in try ac.journal.outbox(after:runOp.dot.counter) {
                let value=try packet(op,ac)
                if case .routine=value.body {_=try receive(op,value,b,bc,fetch:{_ in definition})}
                else if case .routineRun=value.body {operation=op;target=value}
                else {throw OSwindError.invalid("Unexpected crash fixture operation")}
            }
        }
        let targetReference=try target.reference,runningReference=try running.reference
        guard case .routineRun(let targetBody)=target.body,targetBody.status==(action=="update" ? .failed:.running),action != "update" || targetReference != runningReference else {throw OSwindError.invalid("Crash fixture missed its real target update")}
        let local="peer-"+(try target.identity.key.digest),state=RunCrashState(action:action,local:local,recipeLocal:recipeLocal,editorPrompt:recipe.prompt,old:old,target:target,definition:definition,operation:operation,versions:try count(b,"personal_sync_versions"),outbox:try bc.journal.outbox().count)
        try SyncProtocolLimits.encode(state).write(to:root.appendingPathComponent("expected.json"),options:.atomic)
        func hold()throws {try Data((action+":"+phase).utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop owned incoming-run worker")}
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        _=try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in _=try writer.apply(target,admission:lease,fetchExactSource:{_ in definition});if phase=="before" {try hold()}}
        if phase=="after" {try hold()};try a.close();try b.close()
    }
}
