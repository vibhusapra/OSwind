import XCTest
import AppKit
import Darwin
import MachO
@testable import OSwindCore
@testable import OSwind

@MainActor final class PendingMediaSchedulerTests:XCTestCase {
    var root:URL!,app:AppModel!
    var session:AppSession?,defaults:UserDefaults?,suite:String?
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-pending-cleanup-"+UUID().uuidString)
        app=try AppModel(root:root,startServices:false)
        app.settings.captureOnLaunch=false;app.settings.apiEnabled=false;app.settings.routinesEnabled=false
        app.settings.entityAutomaticIndex=false;app.settings.automaticMaintenance=false
        app.settings.meetings.enabled=false;app.settings.clipboard.enabled=false
        app.settings.search.visual.enabled=false;app.settings.privacy.retentionDays=1
        app.showOnboarding=false
    }
    override func tearDown()async throws {
        if let model=session?.model {model.prepareForLibrarySwitch();await model.cancelExternalWorkAndWait();try model.store.close();session?.model=nil}
        session=nil;if let suite {defaults?.removePersistentDomain(forName:suite)};defaults=nil
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();app=nil
        try? FileManager.default.removeItem(at:root)
    }
    func waitForRemoval(_ file:URL)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while FileManager.default.fileExists(atPath:file.path),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path),"Committed queued media cleanup should resume without another retention pass or manual retry")
    }
    func seed()throws->URL {
        let file=root.appendingPathComponent("images/owned-pending")
        try Data([31,41,59]).write(to:file)
        try app.store.insert(Memory(id:"erase",text:"Owned deleted source",imagePath:"images/owned-pending"))
        try app.store.insert(Memory(id:"keep",timestamp:Date(timeIntervalSince1970:100),text:"Old unrelated source must survive cleanup-only retry"))
        return file
    }
    func eventually(_ predicate:@escaping ()->Bool)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !predicate(),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertTrue(predicate())
    }
    func testWriterReleaseAutomaticallyResumesCommittedDeletionWithoutExtraRetention()async throws {
        let file=try seed(),lease=try app.store.mediaWriteLease();defer {lease.release()}
        app.startConfiguredServices()
        app.delete(try XCTUnwrap(app.store.get("erase")))
        for _ in 0..<1000 where app.deletingID != nil {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertNil(app.deletingID);XCTAssertNil(try app.store.get("erase"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path));XCTAssertNotNil(try app.store.get("keep"))
        lease.release();try await waitForRemoval(file)
        try await eventually {!self.app.pendingMediaCleanup.hasPendingWork}
        XCTAssertNotEqual(app.pendingMediaCleanup.lastDisposition,.waitingForWriters,"Completed cleanup must not leave a waiting banner during a final idle probe")
        XCTAssertNotNil(try app.store.get("keep"),"Automatic retry must not prune additional history")
    }
    func testLibraryStartupResumesEarlierCommittedQueueAfterWriterRelease()async throws {
        let file=try seed(),lease=try app.store.mediaWriteLease();defer {lease.release()}
        let result=try app.store.delete("erase");XCTAssertEqual(result.pendingMedia,1)
        app.startConfiguredServices();lease.release();try await waitForRemoval(file)
        XCTAssertNotNil(try app.store.get("keep"))
    }
    func testIdleSharedWriterReleasesNeverStartPeriodicQueueProbes()async throws {
        app.startConfiguredServices();try await eventually {!self.app.pendingMediaCleanup.hasPendingWork}
        try await Task.sleep(for:.milliseconds(100))
        let baseline=app.pendingMediaCleanup.attempts
        for _ in 0..<50 {let lease=try app.store.mediaWriteLease();lease.release()}
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertEqual(app.pendingMediaCleanup.attempts,baseline);XCTAssertFalse(app.pendingMediaCleanup.hasPendingWork)
    }
    func actualDrain(_ cancelCaller:Bool)async throws {
        let file=try seed(),lease=try app.store.mediaWriteLease();XCTAssertEqual(try app.store.delete("erase").pendingMedia,1);lease.release()
        let gate=ImportWorkerGate();defer {gate.release()}
        app.pendingMediaCleanup=PendingMediaCleanupModel(store:app.store,beforeAttempt:{try gate.pause()})
        app.startConfiguredServices();await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertTrue(app.hasPendingExitWork)
        var finished=false
        let drain=Task {await self.app.cancelExternalWorkAndWait();finished=true}
        await fulfillment(of:[gate.cancelled],timeout:5);if cancelCaller {drain.cancel()}
        app.startConfiguredServices();try await Task.sleep(for:.milliseconds(50))
        XCTAssertFalse(finished);XCTAssertFalse(app.pendingMediaCleanup.active);XCTAssertEqual(try Data(contentsOf:file),Data([31,41,59]))
        gate.release();await drain.value;XCTAssertTrue(finished);XCTAssertFalse(app.hasPendingExitWork)
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path));XCTAssertNotNil(try app.store.get("keep"))
        app.pendingMediaCleanup.start();try await waitForRemoval(file)
    }
    func testExitDrainJoinsActualUnreservedWorkerAndRejectsRestart()async throws {try await actualDrain(false)}
    func testCancelledDrainCallerStillWaitsForActualWorker()async throws {try await actualDrain(true)}
    func testRetirementAfterActualCleanupCannotPublishLateSuccess()async throws {
        let file=try seed(),lease=try app.store.mediaWriteLease();XCTAssertEqual(try app.store.delete("erase").pendingMedia,1);lease.release()
        let gate=ImportWorkerGate();defer {gate.release()}
        app.pendingMediaCleanup=PendingMediaCleanupModel(store:app.store,afterAttempt:{try? gate.pause()})
        app.startConfiguredServices();await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path),"The actual cleanup already committed")
        let before=app.pendingMediaCleanup.status
        app.prepareForLibrarySwitch();let drain=Task {await self.app.cancelExternalWorkAndWait()}
        await fulfillment(of:[gate.cancelled],timeout:5);gate.release();await drain.value
        XCTAssertEqual(app.pendingMediaCleanup.status,before);XCTAssertFalse(app.hasPendingExitWork)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));XCTAssertNotNil(try app.store.get("keep"))
    }
    func testBackoffSleeperIsCancelledAndJoinedBeforeExit()async throws {
        let file=try seed(),lease=try app.store.mediaWriteLease();defer {lease.release()}
        XCTAssertEqual(try app.store.delete("erase").pendingMedia,1)
        app.pendingMediaCleanup=PendingMediaCleanupModel(store:app.store,delays:[.seconds(10)])
        app.startConfiguredServices();try await eventually {self.app.pendingMediaCleanup.status.contains("waiting")}
        let began=ContinuousClock.now;await app.pendingMediaCleanup.cancelAndWait()
        XCTAssertLessThan(began.duration(to:.now),.seconds(1));XCTAssertFalse(app.pendingMediaCleanup.hasPendingWork)
        let baseline=app.pendingMediaCleanup.attempts;lease.release();try await Task.sleep(for:.milliseconds(350))
        XCTAssertEqual(app.pendingMediaCleanup.attempts,baseline);XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        app.pendingMediaCleanup.start();try await waitForRemoval(file)
    }
    func testStructuralCleanupFailureDoesNotPollAndDeliberateResumeCanRecover()async throws {
        let outside=root.appendingPathComponent("owned-target"),file=root.appendingPathComponent("images/owned-pending")
        try Data([31,41,59]).write(to:outside);try Data([31,41,59]).write(to:file)
        try app.store.insert(Memory(id:"erase",text:"Owned reference",imagePath:"images/owned-pending"))
        try FileManager.default.removeItem(at:file);try FileManager.default.createSymbolicLink(at:file,withDestinationURL:outside)
        let lease=try app.store.mediaWriteLease();XCTAssertEqual(try app.store.delete("erase").pendingMedia,1);lease.release()
        app.startConfiguredServices();try await eventually {!self.app.pendingMediaCleanup.hasPendingWork && self.app.pendingMediaCleanup.status.contains("attention")}
        let baseline=app.pendingMediaCleanup.attempts
        for _ in 0..<20 {let hint=try app.store.mediaWriteLease();hint.release()}
        try await Task.sleep(for:.milliseconds(700));XCTAssertEqual(app.pendingMediaCleanup.attempts,baseline)
        XCTAssertEqual(try Data(contentsOf:outside),Data([31,41,59]))
        try FileManager.default.removeItem(at:file);app.pendingMediaCleanup.resume()
        try await eventually {!self.app.pendingMediaCleanup.hasPendingWork}
        XCTAssertEqual(try app.store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM erasure_assets")},0)
    }
    func separateProcess(_ killed:Bool)async throws {
        let file=try seed(),fm=FileManager.default,nonce=String(root.lastPathComponent.dropFirst("owned-pending-cleanup-".count))
        XCTAssertNotNil(UUID(uuidString:nonce));try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        app.pendingMediaCleanup=PendingMediaCleanupModel(store:app.store,delays:killed ? [.milliseconds(100)]:[.seconds(10)])
        app.startConfiguredServices();try await eventually {!self.app.pendingMediaCleanup.hasPendingWork}
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),child=Process()
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw OSwindError.invalid("Invalid owned notification worker runner")}
        let log=root.appendingPathComponent("notification-worker.log");XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil))
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.PendingMediaNotificationWorkerTests/testOwnedNotificationWriterWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_PENDING_MEDIA_WORKER_ROOT":root.path,"OSWIND_PENDING_MEDIA_WORKER_NONCE":nonce]
        for index in 0..<_dyld_image_count() {guard let pointer=_dyld_get_image_name(index) else {continue};let library=URL(fileURLWithPath:String(cString:pointer)).resolvingSymlinksInPath();if library.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=library.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let ready=root.appendingPathComponent("ready")
        try await eventually {fm.fileExists(atPath:ready.path) || !child.isRunning}
        guard child.isRunning,try String(contentsOf:ready,encoding:.utf8)==nonce else {return XCTFail("Owned notification child missed its real lease gate")}
        XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:0))
        XCTAssertEqual(try app.store.delete("erase").pendingMedia,1)
        try await eventually {self.app.pendingMediaCleanup.status.contains("waiting")}
        XCTAssertTrue(fm.fileExists(atPath:file.path))
        if killed {XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0)}
        else {try Data(nonce.utf8).write(to:root.appendingPathComponent("release"),options:.withoutOverwriting)}
        try await waitForRemoval(file)
        try await eventually {!child.isRunning};child.waitUntilExit()
        if killed {XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)}
        else {XCTAssertEqual(child.terminationStatus,0);XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("done"),encoding:.utf8),nonce)}
        XCTAssertNotNil(try app.store.get("keep"))
    }
    func testSeparateProcessReleaseNotificationResumesBeforeLongBackoff()async throws {try await separateProcess(false)}
    func testSeparateProcessDeathRecoversThroughPendingOnlyBackoff()async throws {try await separateProcess(true)}
    func testReleaseBurstCoalescesAndBoundsAttemptsWhileAnotherWriterRemains()async throws {
        let file=try seed(),lease=try app.store.mediaWriteLease();defer {lease.release()}
        XCTAssertEqual(try app.store.delete("erase").pendingMedia,1)
        app.pendingMediaCleanup=PendingMediaCleanupModel(store:app.store,delays:[.seconds(10)])
        app.startConfiguredServices();try await eventually {self.app.pendingMediaCleanup.status.contains("waiting")}
        let baseline=app.pendingMediaCleanup.attempts,began=ContinuousClock.now
        for _ in 0..<60 {let hint=try app.store.mediaWriteLease();hint.release();try await Task.sleep(for:.milliseconds(10))}
        let elapsed=began.duration(to:.now).components
        let seconds=Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18
        XCTAssertLessThanOrEqual(app.pendingMediaCleanup.attempts-baseline,Int(seconds/0.25)+2,"Release hints must not turn a held writer into an unbounded database loop")
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path));lease.release();try await waitForRemoval(file)
    }
    func testExternalWipeKeepsOwnRetryAndClearsWarningAfterSupportedCompletion()async throws {
        _=try seed();let outside=root.appendingPathComponent("owned-target"),link=root.appendingPathComponent("images/owned-link")
        try Data([7]).write(to:outside);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        app.startConfiguredServices();try await eventually {!self.app.pendingMediaCleanup.hasPendingWork}
        let wiped=try app.store.wipeLibrary();XCTAssertFalse(wiped.cleanupComplete)
        try app.store.insert(Memory(id:"fresh",text:"New source survives earlier wipe retry"))
        try await eventually {self.app.libraryWipe.pendingCleanup && self.app.pendingMediaCleanup.wipePending}
        XCTAssertTrue(try app.store.hasPendingLibraryWipeCleanup());XCTAssertEqual(try Data(contentsOf:outside),Data([7]))
        try FileManager.default.removeItem(at:link);XCTAssertTrue(try app.store.retryLibraryWipeCleanup().cleanupComplete)
        try await eventually {!self.app.libraryWipe.pendingCleanup && !self.app.pendingMediaCleanup.hasPendingWork}
        XCTAssertNotNil(try app.store.get("fresh"));XCTAssertEqual(try Data(contentsOf:outside),Data([7]))
    }
    func testObservationRootFailureIsVisibleAndCanRetryAfterActualRootRestored()async throws {
        let file=try seed(),lease=try app.store.mediaWriteLease();XCTAssertEqual(try app.store.delete("erase").pendingMedia,1);lease.release()
        let fm=FileManager.default,moved=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try fm.moveItem(at:root,to:moved);try fm.createDirectory(at:root,withIntermediateDirectories:false)
        var restored=false
        defer {if !restored {try? fm.removeItem(at:root);try? fm.moveItem(at:moved,to:root)}}
        app.startConfiguredServices()
        XCTAssertTrue(app.pendingMediaCleanup.needsAttention);XCTAssertTrue(app.pendingMediaCleanup.canRetry)
        XCTAssertFalse(app.pendingMediaCleanup.active);XCTAssertFalse(app.pendingMediaCleanup.hasPendingWork)
        XCTAssertTrue(fm.fileExists(atPath:moved.appendingPathComponent("images/owned-pending").path))
        try fm.removeItem(at:root);try fm.moveItem(at:moved,to:root);restored=true
        app.pendingMediaCleanup.resume();try await waitForRemoval(file)
        XCTAssertTrue(app.pendingMediaCleanup.active);XCTAssertNotNil(try app.store.get("keep"))
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();let before=app.pendingMediaCleanup.attempts
        try app.store.close()
        app.pendingMediaCleanup.resume();app.startConfiguredServices();try await Task.sleep(for:.milliseconds(300))
        XCTAssertEqual(app.pendingMediaCleanup.attempts,before);XCTAssertFalse(app.pendingMediaCleanup.active)
    }
    func sessionBoundary(_ quit:Bool)async throws {
        let file=try seed(),lease=try app.store.mediaWriteLease();defer {lease.release()}
        XCTAssertEqual(try app.store.delete("erase").pendingMedia,1)
        let name="com.oswind.tests.pending-cleanup."+UUID().uuidString,values=try XCTUnwrap(UserDefaults(suiteName:name))
        suite=name;defaults=values
        let current=AppSession(selection:.init(url:root,requiresExisting:true,origin:"owned-test"),defaults:values,locked:{false});session=current
        try await eventually {!current.busy};XCTAssertNil(current.failure)
        let old=try XCTUnwrap(current.model);await old.pendingMediaCleanup.cancelAndWait();lease.release()
        let gate=ImportWorkerGate();defer {gate.release()}
        old.pendingMediaCleanup=PendingMediaCleanupModel(store:old.store,beforeAttempt:{try gate.pause()});old.pendingMediaCleanup.start()
        await fulfillment(of:[gate.entered],timeout:5)
        if quit {
            let delegate=AppDelegate(),done=expectation(description:"Quit resumes after pending-media worker");var finished=false
            delegate.finishTermination={_ in finished=true;done.fulfill()}
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
            await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(finished);XCTAssertTrue(old.hasPendingExitWork)
            gate.release();await fulfillment(of:[done],timeout:5);XCTAssertTrue(finished)
        } else {
            let next=root.appendingPathComponent("next"),prepared=try MemoryStore(root:next);try prepared.close()
            current.open(next,persist:false);await fulfillment(of:[gate.cancelled],timeout:5)
            XCTAssertTrue(current.busy);XCTAssertNil(current.model);XCTAssertFalse(old.store.isClosed)
            gate.release();try await eventually {!current.busy};XCTAssertNil(current.failure);XCTAssertTrue(old.store.isClosed)
            XCTAssertEqual(current.model?.store.root,next)
        }
        XCTAssertFalse(old.hasPendingExitWork);XCTAssertTrue(FileManager.default.fileExists(atPath:file.path));XCTAssertNotNil(try app.store.get("keep"))
    }
    func testPlainQuitDelegateJoinsActualPendingMediaWorker()async throws {try await sessionBoundary(true)}
    func testLibrarySwitchJoinsActualPendingMediaWorkerBeforeClosingStore()async throws {try await sessionBoundary(false)}
}
