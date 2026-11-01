import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private struct RetirementCrashState:Codable {
        let source:String,recap:String,chat:String
        let children:[SyncObjectIdentity],before:[SyncRevision],operation:SyncRevision
        let versions:Int
    }
    func testDerivedRetirementDeathBeforeCommitRollsBackSourceChildrenAndAnnouncements()throws {try crashRetirement("before")}
    func testDerivedRetirementDeathAfterCommitRetainsBarriersAndPendingMedia()throws {try crashRetirement("after")}
    private func openRetirementCrash(_ base:URL)throws->(MemoryStore,SyncVersionStore) {
        let store=try MemoryStore(root:base.appendingPathComponent("receiver"))
        let cache=try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT enabled FROM personal_sync_capture"),1)
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:receiverID,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        };return(store,cache)
    }
    private func checkRetirementCrash(_ state:RetirementCrashState,_ committed:Bool,_ store:MemoryStore,_ cache:SyncVersionStore)throws {
        XCTAssertEqual(try store.get(state.source)==nil,committed);XCTAssertEqual(try store.get(state.recap)==nil,committed)
        XCTAssertEqual(try count(store,"chat_turns"),committed ? 0:1);XCTAssertEqual(try count(store,"personal_sync_versions"),committed ? 0:state.versions)
        XCTAssertEqual(try cache.journal.state(for:state.operation.key).isDeleted,committed)
        let outbox=try cache.journal.outbox();XCTAssertEqual(Array(outbox.prefix(state.before.count)),state.before)
        XCTAssertEqual(outbox.count,state.before.count+(committed ? state.children.count:0))
        if committed {XCTAssertEqual(Set(outbox.dropFirst(state.before.count).map(\.key)),Set(try state.children.map {try $0.key}))}
        for child in state.children {
            XCTAssertEqual(try cache.journal.state(for:child.key).isDeleted,committed)
            XCTAssertEqual(try XCTUnwrap(cache.catalog.object(child)).deleted,committed)
        }
        // Reopening legitimately drains committed recap/media work after the
        // dead process's shared reservation is gone. Inspect durability before
        // opening, then require this normal startup cleanup to finish.
        XCTAssertEqual(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("images/received.png").path),!committed)
        XCTAssertEqual(try count(store,"erasure_assets"),0);XCTAssertEqual(try count(store,"personal_sync_changes"),0)
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM pragma_foreign_key_check"),0)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_temp_master WHERE name GLOB 'oswind_peer_retirement*'"),0)
        }
    }
    private func crashRetirement(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,base=fm.temporaryDirectory.appendingPathComponent("owned-incoming-source-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:base)}
        try Data(nonce.utf8).write(to:base.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=base.appendingPathComponent("child.log"),gate=base.appendingPathComponent("ready")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path),fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw OSwindError.invalid("Invalid owned retirement crash runner")}
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncIncomingSourceTests/testDerivedRetirementCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_INCOMING_SOURCE_CRASH_ROOT":base.path,"OSWIND_INCOMING_SOURCE_CRASH_NONCE":nonce,"OSWIND_RETIREMENT_CRASH_PHASE":phase]
        for index in 0..<_dyld_image_count() {guard let p=_dyld_get_image_name(index) else {continue};let file=URL(fileURLWithPath:String(cString:p)).resolvingSymlinksInPath();if file.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=file.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {return XCTFail("Owned retirement worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let state=try JSONDecoder().decode(RetirementCrashState.self,from:Data(contentsOf:base.appendingPathComponent("expected.json")))
        let databaseFile=base.appendingPathComponent("receiver/memory.sqlite")
        guard let path=realpath(databaseFile.path,nil) else {throw OSwindError.invalid("Missing owned retirement crash database")};defer {free(path)}
        var handle:OpaquePointer?;let status=sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)
        guard status==SQLITE_OK,let handle else {sqlite3_close(handle);throw OSwindError.invalid("Cannot inspect owned retirement crash database")}
        do {let raw=RoutineDatabase(handle:handle);try NativeMediaSchema.register(raw);XCTAssertEqual(try raw.eraseCount("SELECT count(*) FROM erasure_assets"),phase=="after" ? 1:0);sqlite3_close(handle)}catch {sqlite3_close(handle);throw error}
        XCTAssertTrue(fm.fileExists(atPath:base.appendingPathComponent("receiver/images/received.png").path))
        let (store,cache)=try openRetirementCrash(base);try checkRetirementCrash(state,phase=="after",store,cache);try store.close()
        if keep {try fm.copyItem(at:base,to:root.appendingPathComponent("retained-crash"))}
        let (retry,rc)=try openRetirementCrash(base),lease=try retry.mediaWriteLease()
        let writer=SyncIncomingConversationWriter(library:retry,cache:rc,admit:{_ in XCTFail("No deleted body")},pathsFor:{_,_ in XCTFail("No media download");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        let receipt=try rc.journal.receive(state.operation,contentAvailable:{_ in true}) {try writer.applyDeletion($0,admission:lease)}
        XCTAssertEqual(receipt.applied,phase=="before" ? 1:0)
        let announced=try rc.journal.outbox();XCTAssertEqual(announced.count,state.before.count+state.children.count)
        for child in state.children {XCTAssertTrue(try rc.journal.state(for:child.key).isDeleted)}
        XCTAssertEqual(try rc.journal.receive(state.operation,contentAvailable:{_ in true}) {_ in XCTFail("Committed deletion ran twice")}.applied,0);XCTAssertEqual(try rc.journal.outbox(),announced)
        lease.release();XCTAssertEqual(retry.retryErasureCleanup().pendingMedia,0);XCTAssertFalse(fm.fileExists(atPath:retry.root.appendingPathComponent("images/received.png").path));try retry.close()
        if keep {try fm.copyItem(at:base,to:root.appendingPathComponent("retained-retry"))}
        print("DERIVED_RETIREMENT_CRASH phase=\(phase) atomicSourceAndChildBarriers=true durableMediaQueue=true startupCleanup=true idempotentRetry=true")
    }
    func testDerivedRetirementCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OSWIND_INCOMING_SOURCE_CRASH_ROOT"] != nil,let phase=env["OSWIND_RETIREMENT_CRASH_PHASE"],["before","after"].contains(phase) else {throw XCTSkip("Only run as owned retirement crash child")}
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);try bc.journal.allowPeer(producerID)
        let image=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM3sAAAAASUVORK5CYII=")!
        try image.write(to:a.root.appendingPathComponent("images/owned.png"));try image.write(to:b.root.appendingPathComponent("images/received.png"))
        let source=Memory(id:"source",timestamp:now,kind:.screen,app:"Owned crash",text:"Owned crash original",imagePath:"images/owned.png");try a.insert(source);try drain(a,ac)
        let first=try XCTUnwrap(ac.journal.outbox().first),record=try packet(first,ac),local=try receive(first,record,b,bc,media:[.image:"images/received.png"],fetch:{_ in record}),memory=try XCTUnwrap(b.get(local))
        let recap=try b.saveRecap(.init(text:"Receiver crash recap",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]),title:"Owned recap"),chat=try b.createChat(title:"Receiver crash answer")
        _=try b.appendChatTurn(sessionID:chat.id,question:"Owned question",answer:.init(text:"Owned answer [1]",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[]));try drain(b,bc)
        let before=try bc.journal.outbox(),children=try before.filter {$0.key.kind != .conversation}.map {try packet($0,bc).identity},versions=try count(b,"personal_sync_versions")
        XCTAssertEqual(children.count,5);_=try a.delete(source.id);try drain(a,ac);let operation=try XCTUnwrap(ac.journal.outbox().last)
        let state=RetirementCrashState(source:local,recap:recap.id,chat:chat.id,children:children,before:before,operation:operation,versions:versions)
        try SyncProtocolLimits.encode(state).write(to:root.appendingPathComponent("expected.json"),options:.atomic)
        func hold()throws {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop retirement worker")}
        let lease=try b.mediaWriteLease();defer {lease.release()};let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        _=try bc.journal.receive(operation,contentAvailable:{_ in true}) {change in try writer.applyDeletion(change,admission:lease);if phase=="before" {try hold()}}
        if phase=="after" {try hold()};try a.close();try b.close()
    }
}
