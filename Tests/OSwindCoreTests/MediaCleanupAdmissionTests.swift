import XCTest
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

/// Owned files only. A retained-media reservation covers files before their SQL
/// reference is admitted, and also snapshots while their consumers are running.
final class MediaCleanupAdmissionTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    let bytes=Data([11,22,33]),relative="images/reserved"
    override func setUpWithError() throws {
        if let owned=ProcessInfo.processInfo.environment["OSWIND_MEDIA_CLEANUP_WORKER_ROOT"],let nonce=ProcessInfo.processInfo.environment["OSWIND_MEDIA_CLEANUP_WORKER_NONCE"] {
            root=URL(fileURLWithPath:owned)
            guard UUID(uuidString:nonce) != nil,root.lastPathComponent==nonce,
                  root.deletingLastPathComponent().resolvingSymlinksInPath()==FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
                  (try? String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8))==nonce else {throw OSwindError.invalid("Invalid owned media worker root")}
        } else {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
        store=try MemoryStore(root:root)
    }
    override func tearDownWithError() throws {
        store=nil
        if ProcessInfo.processInfo.environment["OSWIND_MEDIA_CLEANUP_WORKER_ROOT"]==nil {try? FileManager.default.removeItem(at:root)}
    }
    var file:URL {root.appendingPathComponent(relative)}
    var cache:URL {root.appendingPathComponent(NativeMediaSchema.cacheDirectory+"/owned-cache")}
    func seed() throws {
        try bytes.write(to:file)
        try store.insert(Memory(id:"old",timestamp:Date(timeIntervalSince1970:100),app:"Owned",text:"owned source",imagePath:relative))
        try Paths.ensure(cache.deletingLastPathComponent());try bytes.write(to:cache)
    }
    func count(_ sql:String) throws -> Int {try store.withRoutineDatabase {try $0.eraseCount(sql)}}
    func assertDeferred(_ result:HistoryErasureResult,file expected:Data?=nil) throws {
        XCTAssertEqual(result.removedMedia,0);XCTAssertEqual(result.pendingMedia,1)
        XCTAssertFalse(result.searchCacheRemoved);XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf:file),expected ?? bytes)
        XCTAssertEqual(try Data(contentsOf:cache),bytes)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),1)
    }
    func assertDrained() throws {
        let result=store.retryErasureCleanup()
        XCTAssertEqual(result.removedMedia,1);XCTAssertEqual(result.pendingMedia,0)
        XCTAssertTrue(result.searchCacheRemoved);XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:cache.path))
    }
    func testOpeningLibraryDoesNotDrainMediaReservedByUncommittedWriter() throws {
        try seed()
        let original=try XCTUnwrap(store.get("old"))
        _=try store.saveRecap(.init(text:"Owned recap",sources:[.init(memory:original,score:1,match:"owned")],provider:"owned",duration:0))
        try store.withRoutineDatabase {try $0.execute("DELETE FROM memories WHERE id='old'")}
        let lease=try store.mediaWriteLease();defer {lease.release()}
        let replacement=Data([44,55]);try replacement.write(to:file)
        let opened=try MemoryStore(root:root)
        XCTAssertEqual(try Data(contentsOf:file),replacement)
        XCTAssertEqual(try Data(contentsOf:cache),bytes)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM store_metadata WHERE key='recap_cache_dirty_v33' AND value='1'"),1)
        // The same writer may now admit the reference, before releasing its lease.
        try opened.insert(Memory(id:"new",text:"new owned source",imagePath:relative))
        lease.release()
        let result=opened.retryErasureCleanup()
        XCTAssertEqual(result.removedMedia,0);XCTAssertEqual(result.sharedMedia,1)
        XCTAssertEqual(result.pendingMedia,0);XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf:file),replacement)
        XCTAssertNotNil(try opened.get("new"))
    }
    func testSingleDeleteCommitsButDefersPhysicalCleanupDuringReservation() throws {
        try seed();let lease=try store.mediaWriteLease();defer {lease.release()}
        let result=try store.delete("old")
        XCTAssertEqual(result.sources,1);XCTAssertNil(try store.get("old"))
        try assertDeferred(result)
        lease.release();try assertDrained()
    }
    func testExplicitRetryReportsPendingWorkWithoutWaitingForReservation() throws {
        try seed();let lease=try store.mediaWriteLease();defer {lease.release()}
        try store.withRoutineDatabase {try $0.execute("DELETE FROM memories WHERE id='old'")}
        try assertDeferred(store.retryErasureCleanup())
        lease.release();try assertDrained()
    }
    func testClosedLibraryRetryReportsUnknownPendingCount() throws {
        try seed();try store.close()
        let result=store.retryErasureCleanup()
        XCTAssertEqual(result.pendingMedia,-1);XCTAssertEqual(result.removedMedia,0)
        XCTAssertFalse(result.searchCacheRemoved);XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf:file),bytes);XCTAssertEqual(try Data(contentsOf:cache),bytes)
    }
    func testActualImageSnapshotDefersUnlinkButRejectsStaleAdmission() throws {
        try seed();let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:"old"))
        defer {snapshot.release()}
        XCTAssertEqual(snapshot.data,bytes)
        let result=try store.delete("old");try assertDeferred(result)
        XCTAssertThrowsError(try snapshot.withAdmission(for:store) {_ in XCTFail("Deleted source must not admit a visual result")})
        snapshot.release();try assertDrained()
    }
    func testScopedEraseCommitsButDefersPhysicalCleanupDuringReservation() throws {
        try seed();let preview=try store.previewErasure(.init(app:"Owned"))
        let lease=try store.mediaWriteLease();defer {lease.release()}
        let result=try store.eraseHistory(preview.scope,expectedToken:preview.token)
        XCTAssertEqual(result.sources,1);XCTAssertNil(try store.get("old"))
        try assertDeferred(result)
        lease.release();try assertDrained()
    }
    func testRetentionPreservesUnrelatedHistoryWhileMediaCleanupIsDeferred() throws {
        try seed();try store.insert(Memory(id:"keep",timestamp:Date(timeIntervalSince1970:200),text:"keep evidence"))
        let lease=try store.mediaWriteLease();defer {lease.release()}
        let result=try store.pruneHistory(before:Date(timeIntervalSince1970:150),maxBytes:1)
        XCTAssertEqual(result.erasure.sources,1);XCTAssertEqual(result.budgetMet,false)
        XCTAssertNil(try store.get("old"));XCTAssertNotNil(try store.get("keep"))
        try assertDeferred(result.erasure)
        lease.release();try assertDrained();XCTAssertNotNil(try store.get("keep"))
    }
    func testCleanupInsideTransactionCannotUnlinkFilesBeforeRollback() throws {
        try seed()
        try store.withRoutineDatabase {db in
            try db.execute("BEGIN IMMEDIATE; DELETE FROM memories WHERE id='old'")
            defer {try? db.execute("ROLLBACK")}
            let result=store.cleanupErasedAssets(db,sources:1,turns:0)
            try assertDeferred(result)
        }
        XCTAssertNotNil(try store.get("old"));XCTAssertEqual(try count("SELECT COUNT(*) FROM erasure_assets"),0)
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testSharedForeignAndReleasedReservationsCannotAuthorizeCleanup() throws {
        try seed();try store.withRoutineDatabase {try $0.execute("DELETE FROM memories WHERE id='old'")}
        let shared=try store.mediaWriteLease();defer {shared.release()}
        let foreign=try MemoryStore(root:root.appendingPathComponent("other"))
        let other=try MediaAdmissionLease.acquire(root:foreign.root,exclusive:true);defer {other.release()}
        for lease in [shared,other] {
            let result=try store.withRoutineDatabase {store.cleanupErasedAssets($0,sources:0,turns:0,reservation:lease)}
            try assertDeferred(result)
        }
        shared.release()
        let released=try MediaAdmissionLease.acquire(root:root,exclusive:true);released.release()
        let result=try store.withRoutineDatabase {store.cleanupErasedAssets($0,sources:0,turns:0,reservation:released)}
        try assertDeferred(result);try assertDrained()
    }
    func testChangedRootCannotRemoveReplacementFilesAfterLogicalDelete() throws {
        try seed();let original=root!,moved=original.appendingPathExtension("moved")
        try FileManager.default.moveItem(at:original,to:moved)
        defer {try? FileManager.default.removeItem(at:original);try? FileManager.default.moveItem(at:moved,to:original)}
        let replacement=try MemoryStore(root:original)
        try bytes.write(to:file);try Paths.ensure(cache.deletingLastPathComponent());try bytes.write(to:cache)
        let result=try store.delete("old")
        XCTAssertEqual(result.sources,1);try assertDeferred(result)
        XCTAssertEqual(try Data(contentsOf:moved.appendingPathComponent(relative)),bytes)
        XCTAssertEqual(try replacement.stats().count,0)
    }
    func testSeparateProcessReservationDefersCleanupUntilReferenceAdmission() throws {
        try seed();let nonce=root.lastPathComponent,fm=FileManager.default
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),child=Process()
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw OSwindError.invalid("Invalid owned media worker runner")}
        let log=root.appendingPathComponent("worker.log");XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil))
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.MediaCleanupAdmissionTests/testMediaReservationWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_MEDIA_CLEANUP_WORKER_ROOT":root.path,"OSWIND_MEDIA_CLEANUP_WORKER_NONCE":nonce]
        for index in 0..<_dyld_image_count() {guard let pointer=_dyld_get_image_name(index) else {continue};let library=URL(fileURLWithPath:String(cString:pointer)).resolvingSymlinksInPath();if library.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=library.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30,gate=root.appendingPathComponent("ready")
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==nonce else {return XCTFail("Owned media worker missed lease gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing"))}
        XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:0))
        let witness=try MediaAdmissionLease.acquire(root:root,exclusive:false,timeout:0);witness.release()
        let result=try store.delete("old");try assertDeferred(result)
        try Data(nonce.utf8).write(to:root.appendingPathComponent("release"),options:.atomic)
        while child.isRunning && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard !child.isRunning else {return XCTFail("Owned media worker did not finish")}
        XCTAssertEqual(child.terminationStatus,0);XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("done"),encoding:.utf8),nonce)
        let cleanup=store.retryErasureCleanup();XCTAssertEqual(cleanup.pendingMedia,0);XCTAssertEqual(cleanup.sharedMedia,1)
        XCTAssertEqual(cleanup.removedMedia,0);XCTAssertTrue(cleanup.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf:file),bytes);XCTAssertNotNil(try store.get("new"))
    }
    func testMediaReservationWorker() throws {
        let env=ProcessInfo.processInfo.environment
        guard let nonce=env["OSWIND_MEDIA_CLEANUP_WORKER_NONCE"],env["OSWIND_MEDIA_CLEANUP_WORKER_ROOT"] != nil else {throw XCTSkip("Only run as owned media reservation child")}
        let lease=try store.mediaWriteLease();defer {lease.release()}
        try Data(nonce.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic)
        let deadline=ProcessInfo.processInfo.systemUptime+30,gate=root.appendingPathComponent("release")
        while !FileManager.default.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        XCTAssertEqual(try String(contentsOf:gate,encoding:.utf8),nonce)
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        try store.insert(Memory(id:"new",text:"separate writer",imagePath:relative));lease.release()
        try Data(nonce.utf8).write(to:root.appendingPathComponent("done"),options:.atomic)
    }
}
