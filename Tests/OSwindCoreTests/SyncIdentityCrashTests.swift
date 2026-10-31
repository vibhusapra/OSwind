import XCTest
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

/// Kills only a nonce-owned child at an actual pre/post-commit gate. This tests
/// process death and SQLite recovery, not physical power failure or peer sync.
final class SyncIdentityCrashTests:XCTestCase {
    private enum FixtureError:Error {case invalidOwnership}
    private let group="00000000-0000-0000-0000-000000000010",epoch="00000000-0000-0000-0000-000000000020"
    func testProcessDeathBeforeCommitRetainsIntentAndRollsBackIdentityAndOutbox()throws {try crash(mode:"process",phase:"before")}
    func testProcessDeathAfterCommitRetainsIdentityOutboxAndAcknowledgement()throws {try crash(mode:"process",phase:"after")}
    func testBootstrapDeathBeforeCommitRollsBackCursorIdentityAndOutbox()throws {try crash(mode:"bootstrap",phase:"before")}
    func testBootstrapDeathAfterCommitResumesWithoutDuplicatingTheFirstObject()throws {try crash(mode:"bootstrap",phase:"after")}
    private func crash(mode:String,phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("oswind-identity-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:root)}
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent("owner").path)
        let child=Process(),log=root.appendingPathComponent("child.log"),gate=root.appendingPathComponent("ready")
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]));let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw FixtureError.invalidOwnership}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncIdentityCrashTests/testCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_IDENTITY_CRASH_ROOT":root.path,"OSWIND_IDENTITY_CRASH_NONCE":nonce,"OSWIND_IDENTITY_CRASH_PHASE":phase,"OSWIND_IDENTITY_CRASH_MODE":mode]
        for index in 0..<_dyld_image_count() {
            guard let name=_dyld_get_image_name(index) else {continue};let image=URL(fileURLWithPath:String(cString:name)).resolvingSymlinksInPath()
            if image.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=image.path}
        }
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==mode+"-"+phase else {XCTFail("Owned identity worker did not reach its gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"));return}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()};let committed=phase=="after"
        XCTAssertEqual(try store.get("owned-a")?.text,"authored identity crash body")
        try store.withRoutineDatabase {db in
            try SyncChangeCapture.prepare(db);let c=SyncIdentityCatalog(database:db,scope:try SyncChangeCapture.scope(db)),j=try SyncJournal(database:db,replica:nonce.lowercased(),group:group,epoch:epoch)
            func count(_ sql:String)throws->Int64 {let s=try db.statement(sql);defer {sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_ROW else {throw db.error()};return sqlite3_column_int64(s,0)}
            XCTAssertEqual(try count("SELECT COUNT(*) FROM personal_sync_identities"),committed ? 1:0)
            XCTAssertEqual(try j.outbox().count,committed ? 1:0)
            let expectedPending=mode=="process" && !committed ? 1:0;XCTAssertEqual(try SyncChangeCapture.changes(db,scope:c.scope).count,expectedPending)
            if mode=="bootstrap" {XCTAssertEqual(try count("SELECT COUNT(*) FROM personal_sync_identity_bootstrap WHERE next_key IS NOT NULL AND complete=0"),committed ? 1:0)}
            let reference=try SyncContentReference(data:Data("authored identity crash body".utf8))
            if mode=="process" {
                let processed=try c.process {batch in for value in batch {try j.put(key:XCTUnwrap(value.after).key,content:reference)}}
                XCTAssertEqual(processed,committed ? 0:1);XCTAssertEqual(try j.outbox().count,1)
            }else {
                var resumed=[SyncObjectIdentity]()
                while try !c.bootstrap(.source,limit:1,consume:{batch in for value in batch {resumed.append(value.identity);try j.put(key:value.identity.key,content:reference)}}).complete {}
                XCTAssertEqual(resumed.count,committed ? 1:2);XCTAssertEqual(try j.outbox().count,2);XCTAssertEqual(Set(try j.outbox().map(\.key)).count,2)
                XCTAssertEqual(try count("SELECT COUNT(*) FROM personal_sync_identity_bootstrap WHERE complete=1 AND next_key IS NULL AND cursor_key IS NULL"),1)
            }
            XCTAssertTrue(try SyncChangeCapture.changes(db,scope:c.scope).isEmpty)
            print("IDENTITY_CRASH mode=\(mode) phase=\(phase) committed=\(committed) recoveredOutbox=\(try j.outbox().count) pending=0")
        }
    }
    func testCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_IDENTITY_CRASH_ROOT"],let nonce=env["OSWIND_IDENTITY_CRASH_NONCE"],let phase=env["OSWIND_IDENTITY_CRASH_PHASE"],let mode=env["OSWIND_IDENTITY_CRASH_MODE"] else {throw XCTSkip("Only run as an owned identity crash subprocess")}
        guard UUID(uuidString:nonce)?.uuidString==nonce,["before","after"].contains(phase),["process","bootstrap"].contains(mode) else {throw FixtureError.invalidOwnership}
        let root=URL(fileURLWithPath:path,isDirectory:true),expected=fm.temporaryDirectory.appendingPathComponent("oswind-identity-crash-"+nonce,isDirectory:true)
        guard root.resolvingSymlinksInPath().standardizedFileURL==expected.resolvingSymlinksInPath().standardizedFileURL,try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw FixtureError.invalidOwnership}
        let store=try MemoryStore(root:root.appendingPathComponent("library"))
        if mode=="bootstrap" {for id in ["owned-a","owned-b"] {try store.insert(Memory(id:id,text:"authored identity crash body"))}}
        try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);let c=try SyncIdentityCatalog.install(db),j=try SyncJournal.install(database:db,replica:nonce.lowercased(),group:group,epoch:epoch)
            if mode=="process" {try store.insert(Memory(id:"owned-a",text:"authored identity crash body"))}
            func hold()throws {try Data((mode+"-"+phase).utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not kill its owned identity worker")}
            let reference=try SyncContentReference(data:Data("authored identity crash body".utf8))
            if mode=="process" {
                try c.process {batch in for value in batch {try j.put(key:XCTUnwrap(value.after).key,content:reference)};if phase=="before" {try hold()}}
            }else {
                try c.bootstrap(.source,limit:1) {batch in for value in batch {try j.put(key:value.identity.key,content:reference)};if phase=="before" {try hold()}}
            }
            if phase=="after" {try hold()}
        }
        try store.close()
    }
}
