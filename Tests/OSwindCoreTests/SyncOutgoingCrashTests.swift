import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

/// Owned process death at actual staging/bootstrap/typed commit gates. The
/// parent reopens the database and completes the real processor after recovery.
final class SyncOutgoingCrashTests:XCTestCase {
    private enum OwnedError:Error {case invalid}
    private let group="00000000-0000-0000-0000-000000000811",epoch="00000000-0000-0000-0000-000000000812"
    func testStageBeforeCommitRetainsRawIntent()throws {try crash("stage","before")}
    func testStageAfterCommitRetainsOpaqueWork()throws {try crash("stage","after")}
    func testBootstrapBeforeCommitRetainsUnassignedSource()throws {try crash("bootstrap","before")}
    func testBootstrapAfterCommitRetainsCursorAndWork()throws {try crash("bootstrap","after")}
    func testTypedBeforeCommitRetainsWorkWithoutJournalOrCache()throws {try crash("typed","before")}
    func testTypedAfterCommitRetainsTypedJournalCacheAndAcknowledgement()throws {try crash("typed","after")}
    private func install(_ store:MemoryStore,_ replica:String)throws->(SyncOutgoingWorkQueue,SyncVersionStore) {
        try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);let c=try SyncIdentityCatalog.install(db),j=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
            return (try SyncOutgoingWorkQueue.install(catalog:c),try SyncVersionStore.install(catalog:c,journal:j))
        }
    }
    private func crash(_ mode:String,_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("oswind-outgoing-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:root)}
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent("owner").path)
        let log=root.appendingPathComponent("child.log"),gate=root.appendingPathComponent("ready"),child=Process()
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]));let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath();guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw OwnedError.invalid}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncOutgoingCrashTests/testCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_OUTGOING_CRASH_ROOT":root.path,"OSWIND_OUTGOING_CRASH_NONCE":nonce,"OSWIND_OUTGOING_CRASH_PHASE":phase,"OSWIND_OUTGOING_CRASH_MODE":mode]
        for i in 0..<_dyld_image_count() {guard let name=_dyld_get_image_name(i) else {continue};let image=URL(fileURLWithPath:String(cString:name)).resolvingSymlinksInPath();if image.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=image.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run();defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==mode+"-"+phase else {XCTFail("Owned outgoing worker missed its gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing"));return}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()};let (queue,cache)=try install(store,nonce.lowercased()),committed=phase=="after",typed=mode=="typed"
        func n(_ table:String)throws->Int {let row=try queue.database.statement("SELECT COUNT(*) FROM "+table);defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw queue.database.error()};return Int(sqlite3_column_int(row,0))}
        XCTAssertEqual(try store.get("owned")?.text,"Authored outgoing crash body")
        XCTAssertEqual(try n("personal_sync_changes"),mode=="stage" && !committed ? 1:0)
        XCTAssertEqual(try n("personal_sync_work"),typed ? (committed ? 0:1):(committed ? 1:0))
        XCTAssertEqual(try n("personal_sync_identities"),typed || committed ? 1:0)
        XCTAssertEqual(try n("personal_sync_identity_bootstrap"),mode=="bootstrap" && committed ? 1:0)
        XCTAssertEqual(try n("personal_sync_versions"),typed && committed ? 1:0);XCTAssertEqual(try n("personal_sync_version_projection"),typed && committed ? 1:0)
        XCTAssertEqual(try cache.journal.outbox().count,typed && committed ? 1:0)
        let processor=SyncOutgoingProcessor(queue:queue,cache:cache,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []})
        var finished=false;for _ in 0..<40 {if try processor.step(limit:1) == .idle {finished=true;break}}
        XCTAssertTrue(finished);XCTAssertEqual(try n("personal_sync_changes"),0);XCTAssertEqual(try n("personal_sync_work"),0);XCTAssertEqual(try n("personal_sync_versions"),1);XCTAssertEqual(try n("personal_sync_version_projection"),1);XCTAssertEqual(try cache.journal.outbox().count,1)
        XCTAssertEqual(try store.get("owned")?.text,"Authored outgoing crash body");print("OUTGOING_CRASH mode=\(mode) phase=\(phase) recoveredTyped=1 pending=0")
    }
    func testCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_OUTGOING_CRASH_ROOT"],let nonce=env["OSWIND_OUTGOING_CRASH_NONCE"],let mode=env["OSWIND_OUTGOING_CRASH_MODE"],let phase=env["OSWIND_OUTGOING_CRASH_PHASE"] else {throw XCTSkip("Only run as an owned outgoing commit crash child")}
        guard UUID(uuidString:nonce)?.uuidString==nonce,["stage","bootstrap","typed"].contains(mode),["before","after"].contains(phase) else {throw OwnedError.invalid}
        let root=URL(fileURLWithPath:path,isDirectory:true),expected=fm.temporaryDirectory.appendingPathComponent("oswind-outgoing-crash-"+nonce,isDirectory:true)
        guard root.resolvingSymlinksInPath().standardizedFileURL==expected.resolvingSymlinksInPath().standardizedFileURL,try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OwnedError.invalid}
        let store=try MemoryStore(root:root.appendingPathComponent("library"))
        func seed()throws {try store.insert(Memory(id:"owned",timestamp:Date(timeIntervalSince1970:1700000000),text:"Authored outgoing crash body"))}
        if mode=="bootstrap" {try seed()};let (queue,cache)=try install(store,nonce.lowercased())
        if mode != "bootstrap" {try seed()};if mode=="typed" {_=try queue.stage()}
        func hold()throws {try Data((mode+"-"+phase).utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop its owned worker")}
        try SyncChangeCapture.transaction(queue.database) {
            if mode=="stage" {_=try queue.stage()}
            else if mode=="bootstrap" {_=try queue.bootstrap(.source,limit:1)}
            else {let processor=SyncOutgoingProcessor(queue:queue,cache:cache,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []});XCTAssertEqual(try processor.step(),.prepared(1))}
            if phase=="before" {try hold()}
        }
        if phase=="after" {try hold()};try store.close()
    }
}
