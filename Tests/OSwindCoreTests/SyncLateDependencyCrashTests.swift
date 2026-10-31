import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private struct LateCrashState:Codable {
        let operation:SyncRevision,record:SyncPortableRecord,parent:SyncRevision
        let later:SyncRevision,laterRecord:SyncPortableRecord
        let beforeCursor:Int64
    }
    private func openLateCrash(_ base:URL)throws->(MemoryStore,SyncVersionStore) {
        let store=try MemoryStore(root:base.appendingPathComponent("receiver"))
        let cache=try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT enabled FROM personal_sync_capture"),1)
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:receiverID,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        };return(store,cache)
    }
    private func lateCrash(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,base=fm.temporaryDirectory.appendingPathComponent("owned-incoming-source-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:base)}
        try Data(nonce.utf8).write(to:base.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=base.appendingPathComponent("child.log"),gate=base.appendingPathComponent("ready")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path),fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw OSwindError.invalid("Invalid owned late crash runner")}
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncIncomingSourceTests/testLateDependencyCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_INCOMING_SOURCE_CRASH_ROOT":base.path,"OSWIND_INCOMING_SOURCE_CRASH_NONCE":nonce,"OSWIND_LATE_CRASH_PHASE":phase]
        for index in 0..<_dyld_image_count() {guard let p=_dyld_get_image_name(index) else {continue};let file=URL(fileURLWithPath:String(cString:p)).resolvingSymlinksInPath();if file.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=file.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {return XCTFail("Owned late worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let expected=try JSONDecoder().decode(LateCrashState.self,from:Data(contentsOf:base.appendingPathComponent("expected.json"))),committed=phase=="after"
        let database=base.appendingPathComponent("receiver/memory.sqlite")
        guard let path=realpath(database.path,nil) else {throw OSwindError.invalid("Missing owned late crash database")};defer {free(path)}
        var handle:OpaquePointer?;let status=sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)
        guard status==SQLITE_OK,let handle else {sqlite3_close(handle);throw OSwindError.invalid("Cannot inspect owned late crash database")}
        do {
            let raw=RoutineDatabase(handle:handle)
            XCTAssertEqual(try raw.eraseCount("SELECT count(*) FROM personal_sync_registers WHERE kind='turn'"),committed ? 1:0)
            XCTAssertEqual(try raw.eraseCount("SELECT count(*) FROM personal_sync_outbox"),committed ? 1:0)
            XCTAssertEqual(try raw.eraseCount("SELECT count(*) FROM chat_turns"),0)
            XCTAssertEqual(try raw.eraseCount("SELECT count(*) FROM personal_sync_pending"),0)
            sqlite3_close(handle)
        }catch {sqlite3_close(handle);throw error}
        let (store,cache)=try openLateCrash(base);defer {try? store.close()}
        XCTAssertEqual(try cache.journal.cursor(for:expected.operation.dot.replica),committed ? expected.operation.dot.counter:expected.beforeCursor)
        XCTAssertEqual(try cache.journal.state(for:expected.operation.key).isDeleted,committed)
        XCTAssertTrue(try cache.journal.state(for:expected.parent.key).isDeleted)
        XCTAssertEqual(try count(store,"chat_turns"),0);XCTAssertEqual(try count(store,"personal_sync_changes"),0)
        let lease=try store.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:store,cache:cache,admit:{_ in XCTFail("No retired admission")},pathsFor:{_,_ in XCTFail("No media");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        let receipt=try cache.journal.receive(expected.operation,contentAvailable:{_ in true}) {_ in
            XCTAssertEqual(try writer.apply(expected.record,admission:lease,fetchExactSource:{_ in XCTFail("No erased owner fetch");throw OSwindError.invalid("No fetch")}),"")
        }
        XCTAssertEqual(receipt.applied,committed ? 0:1)
        let barriers=try cache.journal.outbox();XCTAssertEqual(barriers.count,1)
        let barrier=try XCTUnwrap(barriers.first);XCTAssertEqual(barrier.key,expected.operation.key)
        XCTAssertTrue(barrier.context.contains(expected.operation.dot));XCTAssertTrue(barrier.context.contains(expected.parent.dot))
        XCTAssertEqual(try cache.journal.receive(expected.operation,contentAvailable:{_ in XCTFail("No duplicate body");return false}) {_ in XCTFail("No duplicate apply")}.applied,0)
        _=try receive(expected.later,expected.laterRecord,store,cache,fetch:{_ in throw OSwindError.invalid("No source dependency")})
        XCTAssertEqual(try cache.journal.cursor(for:expected.later.dot.replica),expected.later.dot.counter)
        XCTAssertEqual(try store.chats().map(\.title),["Independent after late crash"])
        XCTAssertEqual(try cache.journal.outbox(),barriers)
        if keep {try fm.copyItem(at:base,to:root.appendingPathComponent("retained-late-"+phase))}
        print("LATE_DEPENDENCY_CRASH phase=\(phase) atomicBarrierAndReceipt=true causalHeads=true retryIdempotent=true laterSenderProgress=true")
    }
    func testLateDependencyDeathBeforeCommitRollsBackBarrierAndReceipt()throws {try lateCrash("before")}
    func testLateDependencyDeathAfterCommitRetainsBarrierAndReceipt()throws {try lateCrash("after")}
    func testLateDependencyCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"] != nil,let phase=env["OSWIND_LATE_CRASH_PHASE"],["before","after"].contains(phase) else {throw XCTSkip("Only run as owned late-dependency crash child")}
        let thirdID="00000000-0000-0000-0000-000000006171"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        let chat=try a.createChat(title:"Owned late crash parent");try drain(a,ac);try derivedDeliver(ac,b,bc);try derivedDeliver(ac,c,cc)
        let local=try XCTUnwrap(c.chats().first)
        _=try c.appendChatTurn(sessionID:local.id,question:"Owned late crash question",answer:.init(text:"Owned late crash answer",sources:[],provider:"owned",duration:0,warnings:[]));try drain(c,cc)
        let operation=try XCTUnwrap(cc.journal.outbox().last),record=try packet(operation,cc)
        _=try c.createChat(title:"Independent after late crash");try drain(c,cc)
        let later=try XCTUnwrap(cc.journal.outbox().last),laterRecord=try packet(later,cc)
        try a.deleteChat(chat.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last);try receiveDeletion(deletion,b,bc)
        for preceding in try cc.journal.outbox() where preceding.dot.counter<operation.dot.counter {try receiveDeletion(preceding,b,bc)}
        let expected=LateCrashState(operation:operation,record:record,parent:deletion,later:later,laterRecord:laterRecord,beforeCursor:try XCTUnwrap(bc.journal.cursor(for:thirdID)))
        try SyncProtocolLimits.encode(expected).write(to:root.appendingPathComponent("expected.json"),options:.atomic)
        func hold()throws {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop owned late worker")}
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("No retired admission")},pathsFor:{_,_ in XCTFail("No media");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        _=try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in
            XCTAssertEqual(try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("No erased owner fetch")}),"")
            if phase=="before" {try hold()}
        }
        if phase=="after" {try hold()};try a.close();try b.close();try c.close()
    }
}
