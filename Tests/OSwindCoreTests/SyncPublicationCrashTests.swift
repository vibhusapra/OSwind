import XCTest
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private struct PublicationCrashState:Codable {
        let target:SyncRevision,owner:SyncPortableRecord,publication:SyncTurnPublication,sources:[SyncPortableRecord]
        let cursor:Int64?,receipts:Int,versions:Int,historical:Int,outbox:[SyncRevision]
    }
    private func openPublicationCrash(_ base:URL)throws->(MemoryStore,SyncVersionStore) {
        let store=try MemoryStore(root:base.appendingPathComponent("receiver"))
        let cache=try store.withRoutineDatabase {db in
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:receiverID,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        };return(store,cache)
    }
    private func checkPublicationCrash(_ state:PublicationCrashState,_ committed:Bool,_ store:MemoryStore,_ cache:SyncVersionStore)throws {
        XCTAssertEqual(try count(store,"chat_turns"),committed ? 1:0);XCTAssertEqual(try count(store,"chat_sources"),committed ? 2:0);XCTAssertEqual(try count(store,"historical_evidence"),committed ? 2:state.historical)
        XCTAssertEqual(try count(store,"personal_sync_receipts"),state.receipts+(committed ? 1:0));XCTAssertEqual(try cache.journal.cursor(for:producerID),committed ? state.target.dot.counter:state.cursor)
        XCTAssertEqual(try count(store,"personal_sync_versions"),state.versions+(committed ? 3:0));XCTAssertEqual(try cache.journal.outbox(),state.outbox);XCTAssertEqual(try count(store,"personal_sync_changes"),0)
        XCTAssertEqual(try cache.journal.state(for:state.owner.identity.key).heads.first?.publication,try state.publication.reference)
        for source in state.sources {XCTAssertEqual(try cache.resolve(source.identity,content:nil,admit:{_ in}).encoded(),try source.encoded())}
        if committed {
            XCTAssertEqual(try cache.resolve(state.owner.identity,content:nil,admit:{_ in}).encoded(),try state.owner.encoded())
            for citation in state.publication.citations {XCTAssertEqual(try cache.resolve(citation.identity,content:nil,admit:{_ in}).encoded(),try citation.encoded())}
            guard case .turn(let body)=state.owner.body else {return XCTFail("Owned turn missing")}
            let chat="peer-"+(try body.conversation.key.digest),turn=try XCTUnwrap(store.chatTurns(chat).first)
            XCTAssertEqual(turn.answer.text,"Owned complete answer 👩🏽‍💻 e\u{301} [1] [2]");XCTAssertEqual(turn.answer.sources.map{$0.memory.text},["Owned first original","Owned second original"]);XCTAssertTrue(turn.answer.sources.allSatisfy{$0.memory.originalEvidence != nil})
        } else {XCTAssertThrowsError(try cache.resolve(state.owner.identity,content:nil,admit:{_ in}))}
        try store.withRoutineDatabase {XCTAssertEqual(try $0.eraseCount("SELECT count(*) FROM pragma_foreign_key_check"),0)}
    }
    func testPublicationDeathDuringSecondCitationLeavesNoReadablePartialAnswer()throws {try crashPublication("before")}
    func testPublicationDeathAfterCommitRetainsCompleteAnswerAndReceipt()throws {try crashPublication("after")}
    private func crashPublication(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,base=fm.temporaryDirectory.appendingPathComponent("owned-incoming-source-crash-"+nonce)
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:base)}
        try Data(nonce.utf8).write(to:base.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=base.appendingPathComponent("child.log"),gate=base.appendingPathComponent("ready")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path),fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw OSwindError.invalid("Invalid owned publication runner")}
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncIncomingSourceTests/testPublicationCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_INCOMING_SOURCE_CRASH_ROOT":base.path,"OSWIND_INCOMING_SOURCE_CRASH_NONCE":nonce,"OSWIND_PUBLICATION_CRASH_PHASE":phase]
        for index in 0..<_dyld_image_count() {guard let p=_dyld_get_image_name(index) else {continue};let file=URL(fileURLWithPath:String(cString:p)).resolvingSymlinksInPath();if file.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=file.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {return XCTFail("Owned publication worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        // A genuinely independent connection while the writer is held proves
        // that an uncommitted owner/first citation cannot reach another reader.
        var handle:OpaquePointer?
        guard sqlite3_open_v2(base.appendingPathComponent("receiver/memory.sqlite").path,&handle,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK,let handle else {sqlite3_close(handle);throw OSwindError.invalid("Cannot inspect owned publication reader")}
        let reader=RoutineDatabase(handle:handle)
        XCTAssertEqual(try reader.eraseCount("SELECT count(*) FROM chat_turns"),phase=="after" ? 1:0);XCTAssertEqual(try reader.eraseCount("SELECT count(*) FROM chat_sources"),phase=="after" ? 2:0);sqlite3_close(handle)
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let state=try JSONDecoder().decode(PublicationCrashState.self,from:Data(contentsOf:base.appendingPathComponent("expected.json")))
        let (store,cache)=try openPublicationCrash(base);try checkPublicationCrash(state,phase=="after",store,cache);try store.close()
        if keep {try fm.copyItem(at:base,to:root.appendingPathComponent("publication-crash-"+phase))}
        let (retry,rc)=try openPublicationCrash(base);defer {try? retry.close()};let lease=try retry.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:retry,cache:rc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in}),coordinator=SyncIncomingTurnPublicationWriter(writer:writer),target=try XCTUnwrap(state.publication.citations.last)
        let fetch:(SyncVersionReference)throws->SyncPortableRecord={ref in try XCTUnwrap(([state.owner]+state.sources).first{(try? $0.reference)==ref})}
        let received=try rc.journal.receive(state.target,contentAvailable:{_ in true}) {_ in
            guard case .projected=try coordinator.applyCitation(target,admission:lease,fetchManifest:{_ in try state.publication.encoded()},fetchRecord:fetch) else {throw OSwindError.invalid("Owned publication retry did not project")}
        }
        XCTAssertEqual(received.applied,phase=="before" ? 1:0);try checkPublicationCrash(state,true,retry,rc)
        guard case .projected=try coordinator.apply(state.owner,admission:lease,fetchManifest:{_ in try state.publication.encoded()},fetchExactSource:fetch) else {return XCTFail("Explicit retry must be idempotent")}
        try checkPublicationCrash(state,true,retry,rc)
        print("PUBLICATION_CRASH phase=\(phase) independentReader=true completeAnswer=true exactOriginals=true receiptAtomic=true noEcho=true retryIdempotent=true")
    }
    func testPublicationCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"] != nil,let phase=env["OSWIND_PUBLICATION_CRASH_PHASE"],["before","after"].contains(phase) else {throw XCTSkip("Only run as owned publication crash child")}
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),space=try publicationSpace();defer {try? a.close();try? b.close();space.close()};try bc.journal.allowPeer(producerID)
        let sources=[Memory(id:"first",timestamp:now,kind:.note,app:"Owned",text:"Owned first original"),Memory(id:"second",timestamp:now,kind:.note,app:"Owned",text:"Owned second original")]
        for source in sources {try a.insert(source)}
        let chat=try a.createChat(title:"Owned crash publication")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Owned crash?",answer:.init(text:"Owned complete answer 👩🏽‍💻 e\u{301} [1] [2]",sources:sources.map{.init(memory:$0,score:1,match:"owned")},provider:"owned",duration:0));try publicationDrain(a,ac,space)
        let ops=try ac.journal.outbox(),target=try XCTUnwrap(ops.last{$0.key.kind == .conversationCitation}),owner=try packet(XCTUnwrap(ops.first{$0.key.kind == .turn}),ac),record=try packet(target,ac),reference=try XCTUnwrap(ops.first{$0.key.kind == .turn}?.publication)
        let declaration=try SyncTurnPublication.decode(XCTUnwrap(space.content(reference)),expected:reference)
        for op in ops where op.dot.counter<target.dot.counter {_=try publicationReceive(op,packet(op,ac),b,bc,ac,space)}
        let originals=try ops.filter{$0.key.kind == .source}.map{try packet($0,ac)}
        let state=try PublicationCrashState(target:target,owner:owner,publication:declaration,sources:originals,cursor:bc.journal.cursor(for:producerID),receipts:count(b,"personal_sync_receipts"),versions:count(b,"personal_sync_versions"),historical:count(b,"historical_evidence"),outbox:bc.journal.outbox())
        try SyncProtocolLimits.encode(state).write(to:root.appendingPathComponent("expected.json"),options:.atomic)
        func hold()throws {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop owned publication worker")}
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{value in
            if phase=="before",case .conversationCitation(let body)=value.body,body.ordinal==1 {
                XCTAssertEqual(try self.count(b,"chat_turns"),1);XCTAssertEqual(try self.count(b,"chat_sources"),1);try hold()
            }
        },pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        _=try bc.journal.receive(target,contentAvailable:{_ in true}) {_ in
            guard case .projected=try SyncIncomingTurnPublicationWriter(writer:writer).applyCitation(record,admission:lease,fetchManifest:{try space.content($0)},fetchRecord:{try XCTUnwrap(ac.record($0,admit:{_ in}))}) else {throw OSwindError.invalid("Owned complete publication did not project")}
        }
        if phase=="after" {try hold()}
    }
}
