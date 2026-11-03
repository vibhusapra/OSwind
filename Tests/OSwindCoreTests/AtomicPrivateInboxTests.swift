import XCTest
import Foundation
import Darwin
import MachO
@testable import OSwindCore

final class AtomicPrivateInboxTests:XCTestCase {
    private var root:URL!
    private let secret=SyncGroupSecret(),group=UUID().uuidString.lowercased(),epoch=UUID().uuidString.lowercased()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-atomic-inbox-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    }
    override func tearDownWithError()throws {try FileManager.default.removeItem(at:root)}
    private func names(_ directory:URL)throws->Set<String> {Set(try FileManager.default.contentsOfDirectory(atPath:directory.path))}
    func testAuthenticatedInboxAppearsOnlyAfterCompletePreparation()throws {
        let path=root.appendingPathComponent("inbox")
        let folder=try SyncObjectFolder.createPrivate(at:path,secret:secret,group:group,epoch:epoch,beforePublication:{
            XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
            XCTAssertEqual(try self.names(self.root).filter {$0.hasPrefix(".oswind-sync-inbox-")}.count,1)
        });defer {folder.close()}
        try folder.requireNamespace(group:group,epoch:epoch);XCTAssertEqual(try names(root),["inbox"])
        let content=Data("Owned private content".utf8),reference=try SyncContentReference(data:content)
        try folder.publishContent(content,reference:reference);XCTAssertEqual(try folder.content(reference),content)
    }
    func testThrownPreparationRemovesOnlyItsWorkspaceAndRetrySucceeds()throws {
        let path=root.appendingPathComponent("inbox"),canary=root.appendingPathComponent("keep.txt"),bytes=Data("Unrelated owned canary".utf8)
        try bytes.write(to:canary)
        XCTAssertThrowsError(try SyncObjectFolder.createPrivate(at:path,secret:secret,group:group,epoch:epoch,beforePublication:{throw OSwindError.unavailable("Owned preparation failure")}))
        XCTAssertEqual(try names(root),["keep.txt"]);XCTAssertEqual(try Data(contentsOf:canary),bytes)
        let retry=try SyncObjectFolder.createPrivate(at:path,secret:secret,group:group,epoch:epoch);defer {retry.close()}
        try retry.requireNamespace(group:group,epoch:epoch)
    }
    func testIgnoredCancellationBeforePublicationJoinsCleanupAndRetainsRetry()async throws {
        let path=root.appendingPathComponent("inbox"),secret=secret,group=group,epoch=epoch,gate=AtomicInboxGate()
        let worker=Task.detached {try SyncObjectFolder.createPrivate(at:path,secret:secret,group:group,epoch:epoch,beforePublication:{gate.pause()})}
        defer {gate.release()}
        await fulfillment(of:[gate.entered],timeout:10);worker.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path));gate.release()
        do {let folder=try await worker.value;folder.close();XCTFail("Cancelled preparation published an inbox")}
        catch is CancellationError {} catch {throw error}
        XCTAssertTrue(try names(root).isEmpty)
        let retry=try SyncObjectFolder.createPrivate(at:path,secret:secret,group:group,epoch:epoch);defer {retry.close()}
        try retry.requireNamespace(group:group,epoch:epoch)
    }
    func testExistingFileFolderAndSymlinkAreNeverReplaced()throws {
        let file=root.appendingPathComponent("existing-file"),directory=root.appendingPathComponent("existing-directory"),link=root.appendingPathComponent("existing-link"),bytes=Data("Owned retained destination".utf8)
        try bytes.write(to:file);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        try bytes.write(to:directory.appendingPathComponent("keep.txt"));try FileManager.default.createSymbolicLink(at:link,withDestinationURL:directory)
        let before=try names(root)
        for path in [file,directory,link] {XCTAssertThrowsError(try SyncObjectFolder.createPrivate(at:path,secret:secret,group:group,epoch:epoch))}
        XCTAssertEqual(try names(root),before);XCTAssertEqual(try Data(contentsOf:file),bytes);XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("keep.txt")),bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:link.path),directory.path)
    }
    func testLateDestinationRacePreservesOtherFolderAndRemovesOwnStage()throws {
        let path=root.appendingPathComponent("inbox"),bytes=Data("Owned late destination".utf8)
        XCTAssertThrowsError(try SyncObjectFolder.createPrivate(at:path,secret:secret,group:group,epoch:epoch,beforePublication:{
            try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
            try bytes.write(to:path.appendingPathComponent("keep.txt"))
        }))
        XCTAssertEqual(try names(root),["inbox"]);XCTAssertEqual(try Data(contentsOf:path.appendingPathComponent("keep.txt")),bytes)
    }
    func testReplacedPhysicalParentIsRefusedWithoutDeletingNewParent()throws {
        let parent=root.appendingPathComponent("parent"),moved=root.appendingPathComponent("moved-parent"),bytes=Data("Owned parent canary".utf8)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false);try bytes.write(to:parent.appendingPathComponent("keep.txt"))
        let path=parent.appendingPathComponent("inbox")
        XCTAssertThrowsError(try SyncObjectFolder.createPrivate(at:path,secret:secret,group:group,epoch:epoch,beforePublication:{
            try FileManager.default.moveItem(at:parent,to:moved);try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false)
            try bytes.write(to:parent.appendingPathComponent("new-parent.txt"))
        }))
        XCTAssertEqual(try names(parent),["new-parent.txt"]);XCTAssertEqual(try names(moved),["keep.txt"])
        XCTAssertEqual(try Data(contentsOf:parent.appendingPathComponent("new-parent.txt")),bytes);XCTAssertEqual(try Data(contentsOf:moved.appendingPathComponent("keep.txt")),bytes)
    }
    func testOwnedProcessDeathBeforePublicationCleansAbandonedStageAndRetries()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_ATOMIC_INBOX_CRASH"]=="1" else {throw XCTSkip("Explicit owned atomic inbox process-death fixture")}
        let fm=FileManager.default,nonce=UUID().uuidString,run=fm.temporaryDirectory.appendingPathComponent("owned-inbox-crash-"+nonce)
        try fm.createDirectory(at:run,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:run)}
        let parent=run.appendingPathComponent("container"),destination=parent.appendingPathComponent("inbox")
        try fm.createDirectory(at:parent,withIntermediateDirectories:false);try Data(nonce.utf8).write(to:run.appendingPathComponent("owner"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=run.appendingPathComponent("child.log")
        guard runner.lastPathComponent=="xctest" else {throw OSwindError.invalid("Owned XCTest runner required")}
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil));let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.AtomicPrivateInboxTests/testOwnedAtomicInboxCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_INBOX_CRASH_ROOT":run.path,"OSWIND_INBOX_CRASH_NONCE":nonce]
        for index in 0..<_dyld_image_count() {if let raw=_dyld_get_image_name(index) {let image=URL(fileURLWithPath:String(cString:raw));if image.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=image.path}}}
        child.environment=env;child.standardInput=FileHandle.nullDevice;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let ready=run.appendingPathComponent("ready"),deadline=ProcessInfo.processInfo.systemUptime+40
        while child.isRunning,!fm.fileExists(atPath:ready.path),ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:ready,encoding:.utf8))=="prepared" else {throw OSwindError.unavailable("Owned inbox child missed publication gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        XCTAssertFalse(fm.fileExists(atPath:destination.path));XCTAssertEqual(try names(parent).count,2)
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let retried=try SyncObjectFolder.createPrivate(at:destination,secret:secret,group:group,epoch:epoch);defer {retried.close()}
        try retried.requireNamespace(group:group,epoch:epoch);XCTAssertEqual(try names(parent),["inbox"])
        print("OWNED_ATOMIC_INBOX_CRASH signal=9 finalAbsentBeforeKill=true abandonedStageCleaned=true originalNamespaceRetry=true noCredentialAccountsCreated=true")
    }
    func testOwnedAtomicInboxCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment
        guard let path=env["OSWIND_INBOX_CRASH_ROOT"],let nonce=env["OSWIND_INBOX_CRASH_NONCE"] else {throw XCTSkip("Only run as owned atomic inbox crash worker")}
        let run=URL(fileURLWithPath:path),expected=FileManager.default.temporaryDirectory.appendingPathComponent("owned-inbox-crash-"+nonce)
        guard UUID(uuidString:nonce)?.uuidString==nonce,run.standardizedFileURL==expected.standardizedFileURL,try String(contentsOf:run.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OSwindError.invalid("Owned inbox crash root differs")}
        // A disposable unreferenced namespace needs no persisted/private key.
        // The original parent can clean its abandoned job and retry its own key.
        let disposable=SyncGroupSecret()
        _=try SyncObjectFolder.createPrivate(at:run.appendingPathComponent("container/inbox"),secret:disposable,group:UUID().uuidString.lowercased(),epoch:UUID().uuidString.lowercased(),beforePublication:{
            try Data("prepared".utf8).write(to:run.appendingPathComponent("ready"),options:.withoutOverwriting)
            while true {Thread.sleep(forTimeInterval:0.1)}
        })
        XCTFail("Owned crash worker unexpectedly published")
    }
}

private final class AtomicInboxGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"Owned inbox prepared before publication")
    private let condition=NSCondition();private var released=false
    func pause() {condition.lock();defer {condition.unlock()};entered.fulfill();while !released {condition.wait()}}
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
}
