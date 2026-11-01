import XCTest
import CSQLite
import CryptoKit
import Darwin
import MachO
@testable import OSwindCore

final class NativeMediaMigrationTests:XCTestCase {
    @discardableResult func seed(_ root:URL)throws->BackupDatabase {
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"NativeMediaMigration",withExtension:nil))
        let provenance=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:fixture.appendingPathComponent("provenance.json"))) as? [String:Any])
        let data=try Data(contentsOf:fixture.appendingPathComponent("schema32-pending.sqlite"))
        XCTAssertEqual(SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),provenance["databaseSHA256"] as? String)
        try Paths.ensure(root);try Paths.ensure(root.appendingPathComponent("images"));try data.write(to:root.appendingPathComponent("memory.sqlite"),options:.withoutOverwriting)
        try FileManager.default.copyItem(at:fixture.appendingPathComponent("owned-pending.png"),to:root.appendingPathComponent("images/owned-pending.png"))
        // Apple's read-only WAL reader requires existing sidecars. Bootstrap the
        // copied fixture without DML, then keep an idle read-only connection
        // alive so the last writer cannot remove them during crash inspection.
        var raw:OpaquePointer?;guard sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&raw)==SQLITE_OK,let raw else {throw OSwindError.invalid("Cannot bootstrap owned WAL fixture")};defer {sqlite3_close(raw)}
        let db=RoutineDatabase(handle:raw);_ = try db.eraseCount("PRAGMA user_version")
        let witness=try BackupDatabase(root.appendingPathComponent("memory.sqlite"));_ = try witness.integer("PRAGMA user_version")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("memory.sqlite")),data)
        return witness
    }
    func state(_ root:URL)throws->[String:String] {
        var raw:OpaquePointer?;guard sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&raw,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK,let raw else {throw OSwindError.invalid("Cannot inspect owned migration state")};defer {sqlite3_close(raw)}
        let db=RoutineDatabase(handle:raw);try NativeMediaSchema.register(db)
        func one(_ sql:String)throws->String {let row=try db.statement(sql);defer {sqlite3_finalize(row)};let result=sqlite3_step(row);guard result==SQLITE_ROW else {throw OSwindError.database("Owned inspection failed (\(result)): \(sql): \(db.error())")};return db.text(row,0)}
        return try ["schema":one("PRAGMA user_version"),"type":one("SELECT type FROM sqlite_master WHERE name='erasure_assets'"),"sources":one("SELECT count(*) FROM memories"),"identity":one("SELECT value FROM store_metadata WHERE key='identity'"),"queued":one("SELECT count(*) FROM erasure_assets"),"path":one("SELECT COALESCE((SELECT hex(path) FROM erasure_assets LIMIT 1),'')"),"oldDirty":one("SELECT count(*) FROM store_metadata WHERE key='recap_cache_dirty' AND value='1'"),"newDirty":one("SELECT count(*) FROM store_metadata WHERE key='recap_cache_dirty_v33' AND value='1'"),"guards":one("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'store_metadata_media_v33_%'"),"backing":one("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='erasure_assets_v33'")]
    }
    func withFixture(_ body:(URL)throws->Void)throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-media-migration-"+UUID().uuidString)
        let witness=try seed(root);defer {witness.close();try? FileManager.default.removeItem(at:root)};try body(root)
    }
    func testNativeMediaMigrationPreservesCommittedQueueAndFencesCachedLegacyStatements()throws {
        try withFixture {root in
            let before=try state(root),lease=try MediaAdmissionLease.acquire(root:root,exclusive:false);defer {lease.release()}
            var raw:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&raw),SQLITE_OK);let legacy=try XCTUnwrap(raw);defer {sqlite3_close(legacy)}
            var read:OpaquePointer?,write:OpaquePointer?;defer {sqlite3_finalize(read);sqlite3_finalize(write)}
            XCTAssertEqual(sqlite3_prepare_v2(legacy,"SELECT count(*) FROM erasure_assets",-1,&read,nil),SQLITE_OK);XCTAssertEqual(sqlite3_step(read),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(read,0),1);sqlite3_reset(read)
            XCTAssertEqual(sqlite3_prepare_v2(legacy,"INSERT OR IGNORE INTO store_metadata(key,value) VALUES('identity','stale')",-1,&write,nil),SQLITE_OK)
            let store=try MemoryStore(root:root),after=try state(root)
            XCTAssertEqual(after["schema"],"33");XCTAssertEqual(after["type"],"view");XCTAssertEqual(after["queued"],before["queued"]);XCTAssertEqual(after["path"],before["path"]);XCTAssertEqual(after["identity"],before["identity"]);XCTAssertEqual(after["sources"],"1");XCTAssertEqual(after["oldDirty"],"0");XCTAssertEqual(after["newDirty"],"1");XCTAssertEqual(after["guards"],"3")
            XCTAssertEqual(sqlite3_step(read),SQLITE_ERROR);XCTAssertTrue(String(cString:sqlite3_errmsg(legacy)).contains(NativeMediaSchema.function))
            XCTAssertEqual(sqlite3_step(write),SQLITE_ERROR);XCTAssertTrue(String(cString:sqlite3_errmsg(legacy)).contains(NativeMediaSchema.function))
            let producer=try store.withRoutineDatabase {db->String in let row=try db.statement("SELECT sql FROM sqlite_master WHERE name='erasure_stage_assets'");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return db.text(row,0)}
            XCTAssertTrue(producer.contains("INTO erasure_assets SELECT"));XCTAssertFalse(producer.contains("erasure_assets_v33"),"Migration must not retarget native producers around the read fence")
            lease.release();let result=store.retryErasureCleanup();XCTAssertEqual(result.removedMedia,1);XCTAssertEqual(result.pendingMedia,0);XCTAssertTrue(result.warnings.isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("images/owned-pending.png").path))
        }
    }
    func testNativeMediaMigrationFailureRollsBackQueueMarkerSchemaAndSource()throws {
        try withFixture {root in
            var raw:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&raw),SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(raw,"CREATE TRIGGER owned_migration_veto BEFORE DELETE ON store_metadata WHEN old.key='recap_cache_dirty' BEGIN SELECT RAISE(ABORT,'owned migration veto'); END",nil,nil,nil),SQLITE_OK);sqlite3_close(raw)
            let before=try state(root)
            XCTAssertThrowsError(try MemoryStore(root:root));XCTAssertEqual(try state(root),before)
            XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("images/owned-pending.png").path))
        }
    }
    func testNativeMediaMigrationSerializesWithPriorQueueWriter()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-media-migration-"+UUID().uuidString),witness=try seed(root)
        defer {witness.close();try? FileManager.default.removeItem(at:root)}
        let lease=try MediaAdmissionLease.acquire(root:root,exclusive:false);defer {lease.release()}
        var raw:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&raw),SQLITE_OK)
        let old=RoutineDatabase(handle:try XCTUnwrap(raw));defer {try? old.execute("ROLLBACK");sqlite3_close(raw)}
        try old.execute("BEGIN IMMEDIATE")
        let started=DispatchSemaphore(value:0),copied=DispatchSemaphore(value:0)
        let worker=Task.detached {started.signal();return try MemoryStore(root:root,observeUpgrade:{if $0 == .mediaQueueCopied {copied.signal()}})}
        XCTAssertEqual(started.wait(timeout:.now()+5),.success)
        XCTAssertEqual(copied.wait(timeout:.now()+0.1),.timedOut,"Migration cannot copy/publish around the existing SQL writer")
        let path="images/committed-during-upgrade",file=root.appendingPathComponent(path),bytes=Data([9,8,7]);try bytes.write(to:file)
        try old.execute("INSERT INTO erasure_assets VALUES('images/committed-during-upgrade'); COMMIT")
        let store=try await worker.value
        XCTAssertEqual(copied.wait(timeout:.now()+5),.success)
        XCTAssertEqual(try state(root)["schema"],"33")
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM erasure_assets")},2)
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        lease.release();let cleaned=store.retryErasureCleanup();XCTAssertEqual(cleaned.removedMedia,2);XCTAssertEqual(cleaned.pendingMedia,0);XCTAssertTrue(cleaned.warnings.isEmpty)
    }
    func cancelled(_ phase:MemoryStoreUpgradePhase)async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-media-migration-"+UUID().uuidString);let witness=try seed(root);defer {witness.close();try? FileManager.default.removeItem(at:root)}
        let before=try state(root)
        let worker=Task.detached {try MemoryStore(root:root,observeUpgrade:{if $0==phase {withUnsafeCurrentTask {$0?.cancel()}}})}
        if phase == .afterCommit {
            let store=try await worker.value;XCTAssertEqual(try state(root)["schema"],"33");XCTAssertEqual(try state(root)["queued"],"1");XCTAssertEqual(store.retryErasureCleanup().pendingMedia,0)
        } else {
            do {_=try await worker.value;XCTFail("Cancelled uncommitted migration returned a library")}catch is CancellationError {}catch {XCTFail("Wrong migration error: \(error)")}
            XCTAssertEqual(try state(root),before);XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("images/owned-pending.png").path))
        }
    }
    func testNativeMediaMigrationCancellationAfterQueueCopyRestoresSource32()async throws {try await cancelled(.mediaQueueCopied)}
    func testNativeMediaMigrationCancellationBeforeCommitRestoresSource32()async throws {try await cancelled(.beforeCommit)}
    func testNativeMediaMigrationCancellationAfterCommitReturnsCommittedLibraryAndPendingWork()async throws {try await cancelled(.afterCommit)}
    func testNativeMediaMigrationDeathAfterQueueCopyRestoresSource32()throws {try crash(.mediaQueueCopied)}
    func testNativeMediaMigrationDeathBeforeCommitRestoresSource32()throws {try crash(.beforeCommit)}
    func testNativeMediaMigrationDeathAfterCommitPreservesSource33()throws {try crash(.afterCommit)}
    func crash(_ phase:MemoryStoreUpgradePhase)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("owned-media-migration-"+nonce);let witness=try seed(root);defer {witness.close();try? fm.removeItem(at:root)}
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        let before=try state(root),child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=root.appendingPathComponent("child.log"),gate=root.appendingPathComponent("ready")
        guard runner.lastPathComponent=="xctest",fm.createFile(atPath:log.path,contents:nil) else {throw OSwindError.invalid("Invalid owned migration runner")}
        let stream=try FileHandle(forWritingTo:log);defer {try? stream.close()};child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.NativeMediaMigrationTests/testNativeMediaMigrationCrashWorker",Bundle(for:Self.self).bundleURL.path];child.standardOutput=stream;child.standardError=stream
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_MEDIA_MIGRATION_ROOT":root.path,"OSWIND_MEDIA_MIGRATION_NONCE":nonce,"OSWIND_MEDIA_MIGRATION_PHASE":phase.rawValue]
        for i in 0..<_dyld_image_count() {guard let name=_dyld_get_image_name(i) else {continue};let library=URL(fileURLWithPath:String(cString:name)).resolvingSymlinksInPath();if library.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=library.path}}
        child.environment=env;try child.run();defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase.rawValue else {return XCTFail("Migration child missed gate: "+String(((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log").suffix(2000)))}
        let observed=try state(root)
        if phase == .afterCommit {XCTAssertEqual(observed["schema"],"33");XCTAssertEqual(observed["type"],"view");XCTAssertEqual(observed["queued"],"1");XCTAssertEqual(observed["path"],before["path"])} else {XCTAssertEqual(observed,before)}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        if let destination=ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_MEDIA_RETAIN"] {
            let parent=URL(fileURLWithPath:destination);try Paths.ensure(parent);let proof=parent.appendingPathComponent(phase.rawValue+"-"+nonce);try fm.copyItem(at:root,to:proof)
            try JSONSerialization.data(withJSONObject:["phase":phase.rawValue,"observed":observed,"before":before],options:[.sortedKeys]).write(to:proof.appendingPathComponent("expected.json"),options:.withoutOverwriting)
        }
        let recovered=try MemoryStore(root:root);XCTAssertEqual(try recovered.stats().count,1);XCTAssertEqual(try state(root)["schema"],"33");XCTAssertEqual(try state(root)["queued"],"0");XCTAssertFalse(fm.fileExists(atPath:root.appendingPathComponent("images/owned-pending.png").path));try recovered.withRoutineDatabase {try NativeMediaSchema.validate($0)}
        print("NATIVE_MEDIA_MIGRATION_CRASH phase=\(phase.rawValue) independentReader=true wholeCommittedState=true recovery=true")
    }
    func testNativeMediaMigrationCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard let path=env["OSWIND_MEDIA_MIGRATION_ROOT"],let nonce=env["OSWIND_MEDIA_MIGRATION_NONCE"],let name=env["OSWIND_MEDIA_MIGRATION_PHASE"],let phase=MemoryStoreUpgradePhase(rawValue:name) else {throw XCTSkip("Only run as an owned migration child")}
        let root=URL(fileURLWithPath:path);guard UUID(uuidString:nonce) != nil,root.lastPathComponent=="owned-media-migration-"+nonce,(try? String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8))==nonce else {throw OSwindError.invalid("Invalid owned migration root")}
        _=try MemoryStore(root:root,observeUpgrade:{value in if value==phase {do {try Data(value.rawValue.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic)}catch {return};Thread.sleep(forTimeInterval:60)}})
        XCTFail("Parent did not kill the owned migration worker")
    }
}
