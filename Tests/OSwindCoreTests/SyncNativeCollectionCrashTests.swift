import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

/// Exact commit-hook process deaths against authored data and real encrypted
/// controls. No production kill switch or real provider/key is involved.
final class SyncNativeCollectionCrashTests:XCTestCase {
    private let local="00000000-0000-0000-0000-000000008301",peer="00000000-0000-0000-0000-000000008302",group="00000000-0000-0000-0000-000000008303",epoch="00000000-0000-0000-0000-000000008304"
    private var fixtureKey:SyncGroupSecret {get throws {try .init(rawRepresentation:Data(repeating:0x73,count:32))}}
    private final class Gate {
        let root:URL,phase:String
        init(_ root:URL,_ phase:String) {self.root=root;self.phase=phase}
        func hold()->Int32 {
            do {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic)} catch {return 1}
            Thread.sleep(forTimeInterval:45);return 1
        }
    }
    private func endpoint(_ root:URL,_ replica:String)throws->(MemoryStore,SyncVersionStore) {
        let store=try MemoryStore(root:root),cache=try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db)
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        };return(store,cache)
    }
    func testNativeCollectionDeathBeforeCommitPreservesWholeLibraryAndNoReceipt()throws {try crash("before")}
    func testNativeCollectionDeathAfterCommitPreservesReceiptRetirementAndCleanupInventory()throws {try crash("after")}
    private func crash(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("owned-native-collection-crash-"+nonce)
        try Paths.ensure(root);defer {try? fm.removeItem(at:root)}
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=root.appendingPathComponent("child.log")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw OSwindError.invalid("Owned XCTest runner required")}
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil));let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncNativeCollectionCrashTests/testNativeCollectionCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_NATIVE_COLLECTION_CRASH_ROOT":root.path,"OSWIND_NATIVE_COLLECTION_CRASH_NONCE":nonce,"OSWIND_NATIVE_COLLECTION_CRASH_PHASE":phase]
        for i in 0..<_dyld_image_count() {
            guard let raw=_dyld_get_image_name(i) else {continue};let image=URL(fileURLWithPath:String(cString:raw)).resolvingSymlinksInPath()
            if image.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=image.path}
        }
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let ready=root.appendingPathComponent("ready"),deadline=ProcessInfo.processInfo.systemUptime+40
        while child.isRunning && !fm.fileExists(atPath:ready.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:ready,encoding:.utf8))==phase else {XCTFail("Owned native receiver missed commit gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing child log"));return}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit()
        XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let library=root.appendingPathComponent("library"),committed=phase=="after"
        guard let canonical=realpath(library.appendingPathComponent("memory.sqlite").path,nil) else {throw OSwindError.invalid("Owned killed database missing")};defer {free(canonical)}
        let inspected=String(cString:canonical)
        let diagnostic=["requested":library.appendingPathComponent("memory.sqlite").path,"foundationResolved":library.appendingPathComponent("memory.sqlite").resolvingSymlinksInPath().path,"posixRealpath":inspected]
        try SyncProtocolLimits.encode(diagnostic).write(to:root.appendingPathComponent("inspect-path.json"),options:.atomic)
        // Retain actual killed database/WAL before any startup or cleanup.
        if let path=ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_COLLECTION_CRASH_OUTPUT"] {
            let base=URL(fileURLWithPath:path,isDirectory:true),destination=base.appendingPathComponent(phase)
            guard !fm.fileExists(atPath:destination.path) else {throw OSwindError.invalid("Use fresh owned killed native fixtures")}
            try Paths.ensure(base);try fm.copyItem(at:root,to:destination)
        }
        var raw:OpaquePointer?
        guard sqlite3_open_v2(canonical,&raw,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK else {throw OSwindError.database("Owned killed database strict open failed: "+inspected)}
        let db=RoutineDatabase(handle:try XCTUnwrap(raw));try NativeMediaSchema.register(db)
        do {
            for(table,before,after) in [("memories",4,0),("chat_turns",1,0),("personal_sync_collection_received_controls",0,1),("erasure_assets",0,2)] {XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM "+table),committed ? after:before,table)}
            XCTAssertEqual(try db.eraseCount("SELECT counter FROM personal_sync_collection_local"),0)
            XCTAssertEqual(try LibraryWipeState.isPending(db),committed)
        } catch {sqlite3_close(raw);throw error};XCTAssertEqual(sqlite3_close(raw),SQLITE_OK)
        XCTAssertEqual(try Data(contentsOf:library.appendingPathComponent("images/retained")),Data("Owned crash retained image".utf8))
        let(store,cache)=try endpoint(library,local);defer {try? store.close()}
        XCTAssertEqual(try store.hasPendingLibraryWipeCleanup(),committed)
        let folder=try SyncObjectFolder.open(at:root.appendingPathComponent("transport"),secret:fixtureKey,group:group,epoch:epoch);defer {folder.close()}
        let receiver=SyncNativeCollectionReceiver(library:store,cache:cache,inbox:folder)
        XCTAssertEqual(try receiver.receive(creator:peer,counter:1),committed ? .unchanged:.applied)
        try Data("Owned later orphan".utf8).write(to:library.appendingPathComponent("video/later"))
        try store.insert(Memory(id:"later",text:"Owned after actual killed receiver"))
        XCTAssertTrue(try store.retryLibraryWipeCleanup().cleanupComplete)
        XCTAssertNotNil(try store.get("later"));XCTAssertEqual(try Data(contentsOf:library.appendingPathComponent("video/later")),Data("Owned later orphan".utf8))
        XCTAssertFalse(fm.fileExists(atPath:library.appendingPathComponent("images/retained").path))
        XCTAssertEqual(try receiver.receive(creator:peer,counter:1),.unchanged);XCTAssertNotNil(try store.get("later"))
    }
    func testNativeCollectionCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_NATIVE_COLLECTION_CRASH_ROOT"],let nonce=env["OSWIND_NATIVE_COLLECTION_CRASH_NONCE"],let phase=env["OSWIND_NATIVE_COLLECTION_CRASH_PHASE"] else {throw XCTSkip("Only run as owned native collection crash worker")}
        guard UUID(uuidString:nonce)?.uuidString==nonce,["before","after"].contains(phase) else {throw OSwindError.invalid("Invalid owned native crash scope")}
        let root=URL(fileURLWithPath:path),expected=fm.temporaryDirectory.appendingPathComponent("owned-native-collection-crash-"+nonce)
        guard root.resolvingSymlinksInPath()==expected.resolvingSymlinksInPath(),try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OSwindError.invalid("Invalid owned native crash root")}
        let(store,cache)=try endpoint(root.appendingPathComponent("library"),local)
        try cache.journal.allowPeer(peer)
        let memory=Memory(id:"source",text:"Owned precommit source");try store.insert(memory)
        let answer=Answer(text:"Owned answer",sources:[.init(memory:memory,score:1,match:"owned")],provider:"owned",duration:0)
        _=try store.saveRecap(answer);let chat=try store.createChat();_=try store.appendChatTurn(sessionID:chat.id,question:"Owned question",answer:answer)
        let queue=try SyncOutgoingWorkQueue.install(catalog:cache.catalog),processor=SyncOutgoingProcessor(queue:queue,cache:cache,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []})
        var idle=false;for _ in 0..<300 {if try processor.step() == .idle {idle=true;break}};XCTAssertTrue(idle)
        try Data("Owned crash retained image".utf8).write(to:store.root.appendingPathComponent("images/retained"))
        try Data("Owned crash orphan".utf8).write(to:store.root.appendingPathComponent("audio/orphan"))
        try store.insert(Memory(id:"staged",text:"Owned staged image",imagePath:"images/retained"));while try queue.stage()>0 {}
        try store.insert(Memory(id:"raw",text:"Owned raw source"))
        let(a,ac)=try endpoint(root.appendingPathComponent("producer"),peer);_=try a.wipeLibrary()
        let control=try a.withRoutineDatabase {db in
            let history=SyncCollectionHistory(database:db,replica:peer)
            guard case .needsGroupReview(let proposal)=try history.reviewState(journal:ac.journal) else {throw OSwindError.invalid("Owned crash producer has no review")}
            return try history.approveGroupErase(journal:ac.journal,counter:proposal.counter,expectedEra:proposal.era)
        }
        let folder=try SyncObjectFolder.create(at:root.appendingPathComponent("transport"),secret:fixtureKey,group:group,epoch:epoch)
        try folder.publishCollectionControl(control);try a.close()
        try snapshotNativeCollectionBefore(store,to:root.appendingPathComponent("before-control.sqlite"))
        let gate=Gate(root,phase),pointer=Unmanaged.passUnretained(gate).toOpaque()
        try store.withRoutineDatabase {db -> Void in
            if phase=="before" {_=sqlite3_commit_hook(db.handle,{raw in guard let raw else {return 1};return Unmanaged<Gate>.fromOpaque(raw).takeUnretainedValue().hold()},pointer)}
            else {_=sqlite3_wal_hook(db.handle,{raw,_,_,_ in guard let raw else {return 1};return Unmanaged<Gate>.fromOpaque(raw).takeUnretainedValue().hold()},pointer)}
        }
        try withExtendedLifetime(gate) {_=try SyncNativeCollectionReceiver(library:store,cache:cache,inbox:folder).receive(creator:peer,counter:1)}
        XCTFail("Parent must kill native collection worker at the exact commit hook")
    }
}
