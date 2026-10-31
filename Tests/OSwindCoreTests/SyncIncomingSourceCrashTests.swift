import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private struct IncomingCrashState:Codable {
        let local:String,recap:String,conversation:String
        let old:SyncPortableRecord,new:SyncPortableRecord
        let versions:Int,outbox:Int
    }
    func testIncomingSourceDeathBeforeCommitPreservesCurrentGraph()throws {try crashIncoming("before")}
    func testIncomingSourceDeathAfterCommitRetainsNewHeadAndOldEvidenceWithoutEcho()throws {try crashIncoming("after")}
    private func crashIncoming(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,base=fm.temporaryDirectory.appendingPathComponent("owned-incoming-source-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:base)}
        try Data(nonce.utf8).write(to:base.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=base.appendingPathComponent("child.log"),gate=base.appendingPathComponent("ready")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path),fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw OSwindError.invalid("Invalid owned incoming-source crash runner")}
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncIncomingSourceTests/testIncomingSourceCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var environment=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_INCOMING_SOURCE_CRASH_ROOT":base.path,"OSWIND_INCOMING_SOURCE_CRASH_NONCE":nonce,"OSWIND_INCOMING_SOURCE_CRASH_PHASE":phase]
        for index in 0..<_dyld_image_count() {guard let path=_dyld_get_image_name(index) else {continue};let file=URL(fileURLWithPath:String(cString:path)).resolvingSymlinksInPath();if file.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {environment["DYLD_INSERT_LIBRARIES"]=file.path}}
        child.environment=environment;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {return XCTFail("Owned incoming-source worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let state=try JSONDecoder().decode(IncomingCrashState.self,from:Data(contentsOf:base.appendingPathComponent("expected.json"))),committed=phase=="after"
        let previousRoot=root;root=base;defer {root=previousRoot}
        let (store,cache)=try endpoint("receiver",receiverID);defer {try? store.close()}
        XCTAssertEqual(try store.get(state.local)?.text,committed ? "New current source":"Old exact source")
        XCTAssertEqual(try store.get(state.recap)?.text,"Preserved recap")
        XCTAssertEqual(try store.chatTurns(state.conversation).first?.answer.sources.first?.memory.text,"Preserved recap")
        XCTAssertEqual(try store.recapEvidence(state.recap).first?.memory.text,"Old exact source")
        XCTAssertEqual(try cache.resolve(state.new.identity,content:nil,admit:{_ in}),committed ? state.new:state.old)
        XCTAssertEqual(try count(store,"personal_sync_versions"),state.versions+(committed ? 1:0));XCTAssertEqual(try cache.journal.outbox().count,state.outbox);XCTAssertEqual(try count(store,"personal_sync_changes"),0)
        XCTAssertEqual(try count(store,"historical_evidence"),committed ? 2:0)
        let head=try cache.journal.state(for:state.new.identity.key);XCTAssertEqual(head.heads.count,1);XCTAssertEqual(head.heads.first?.content,try (committed ? state.new:state.old).reference.content)
        try store.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM pragma_foreign_key_check"),0)}
        try store.close()
        if keep {try fm.copyItem(at:base,to:previousRoot!.appendingPathComponent("retained-crash"))}
        print("INCOMING_SOURCE_CRASH phase=\(phase) current=1 preservedRecap=1 citedAnswer=1 exactHead=true noEcho=true")
    }
    func testIncomingSourceCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"] != nil,let phase=env["OSWIND_INCOMING_SOURCE_CRASH_PHASE"],["before","after"].contains(phase) else {throw XCTSkip("Only run as owned incoming-source crash child")}
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);try bc.journal.allowPeer(producerID)
        var memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned",text:"Old exact source");try a.insert(memory);try drain(a,ac)
        let first=try XCTUnwrap(ac.journal.outbox().first),old=try packet(first,ac),local=try receive(first,old,b,bc,fetch:{_ in old})
        let recap=try b.saveRecap(.init(text:"Preserved recap",sources:[.init(memory:XCTUnwrap(b.get(local)),score:1,match:"owned")],provider:"owned",duration:0),title:"Owned recap"),chat=try b.createChat(title:"Keep exact recap")
        _=try b.appendChatTurn(sessionID:chat.id,question:"Recap?",answer:.init(text:"Preserved recap [1]",sources:[.init(memory:recap,score:1,match:"owned")],provider:"owned",duration:0));try drain(b,bc)
        let versions=try count(b,"personal_sync_versions"),outbox=try bc.journal.outbox().count
        memory.text="New current source";try a.insert(memory);try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().last),new=try packet(operation,ac)
        let state=IncomingCrashState(local:local,recap:recap.id,conversation:chat.id,old:old,new:new,versions:versions,outbox:outbox)
        try SyncProtocolLimits.encode(state).write(to:root.appendingPathComponent("expected.json"),options:.atomic)
        func hold()throws {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop owned incoming-source worker")}
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        _=try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in
            _=try writer.apply(new,admission:lease,fetchExactSource:{_ in old})
            if phase=="before" {try hold()}
        }
        if phase=="after" {try hold()};try a.close();try b.close()
    }
}
