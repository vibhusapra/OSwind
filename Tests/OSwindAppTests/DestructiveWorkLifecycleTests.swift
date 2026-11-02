import XCTest
import AppKit
import OSwindCore
@testable import OSwind

@MainActor final class DestructiveWorkLifecycleTests:XCTestCase {
    var root:URL!,app:AppModel!
    var session:AppSession?,defaults:UserDefaults?,suite:String?
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-destructive-lifecycle-"+UUID().uuidString)
        app=try AppModel(root:root,startServices:false)
        app.settings.privacy.retentionDays=1
        try app.store.insert(Memory(id:"old",timestamp:Date().addingTimeInterval(-60*86400),text:"Owned source must survive cancelled uncommitted work"))
    }
    override func tearDown()async throws {
        if let model=session?.model {model.prepareForLibrarySwitch();await model.cancelExternalWorkAndWait();try model.store.close();session?.model=nil}
        session=nil
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();app=nil
        if let suite {defaults?.removePersistentDomain(forName:suite)}
        defaults=nil;try? FileManager.default.removeItem(at:root)
    }
    func settle()async throws {
        for _ in 0..<1000 {
            if app.deletingID==nil && !app.maintenanceBusy {return}
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Owned destructive work did not finish")
    }
    func testRetiredLibraryRejectsQueuedManualDeletion()async throws {
        let memory=try XCTUnwrap(app.store.get("old"));app.prepareForLibrarySwitch();app.delete(memory);try await settle()
        XCTAssertNotNil(try app.store.get("old"));XCTAssertNil(app.deletionStatus)
    }
    func testRetiredLibraryRejectsQueuedManualMaintenance()async throws {
        app.prepareForLibrarySwitch();app.maintain();try await settle()
        XCTAssertNotNil(try app.store.get("old"));XCTAssertTrue(app.maintenanceStatus.isEmpty)
    }
    func drain(_ deletion:Bool)async throws {
        let model=app!,gate=ImportWorkerGate();defer {gate.release()}
        if deletion {model.delete(try XCTUnwrap(model.store.get("old")),observeWorker:{try gate.pause()})}
        else {model.maintain(observeWorker:{try gate.pause()})}
        await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertTrue(model.hasPendingExitWork,"The actual unreserved worker must participate in exit ownership")
        model.prepareForLibrarySwitch()
        var finished=false
        let started=expectation(description:"drain entered")
        let drain=Task {started.fulfill();await model.cancelExternalWorkAndWait();finished=true}
        await fulfillment(of:[started],timeout:5);try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(finished,"Closing cannot acknowledge before the actual worker releases its resources")
        gate.release();await drain.value;try await settle()
        XCTAssertTrue(finished);XCTAssertFalse(model.hasPendingExitWork)
        XCTAssertNotNil(try model.store.get("old"),"Cancellation before SQL must prevent late deletion")
        XCTAssertFalse(model.deletionStatus?.hasPrefix("Removed") ?? false,"A retired callback must not publish success")
        if !deletion {XCTAssertFalse(model.maintenanceStatus.hasPrefix("Removed"))}
    }
    func testDeleteDrainCancelsAndJoinsWorkerBeforeSQLAdmission()async throws {try await drain(true)}
    func testMaintenanceDrainCancelsAndJoinsWorkerBeforeSQLAdmission()async throws {try await drain(false)}
    func testClosedLibraryRejectsBothQueuedManualActions()async throws {
        let note=try XCTUnwrap(app.store.get("old"));try app.store.close();app.delete(note);app.maintain()
        XCTAssertFalse(app.hasPendingDestructiveWork);XCTAssertFalse(app.maintenanceBusy);XCTAssertNil(app.deletingID);XCTAssertNil(app.deletionStatus);XCTAssertTrue(app.maintenanceStatus.isEmpty)
    }
    func testRetirementBeforeWorkerLaunchRejectsBothQueuedCompletions()async throws {
        let note=try XCTUnwrap(app.store.get("old"))
        app.delete(note,observeWorker:{XCTFail("Retired deletion created a worker")});app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait()
        XCTAssertNotNil(try app.store.get("old"));XCTAssertFalse(app.hasPendingDestructiveWork)
        // The second owned model exercises maintenance before its actor task runs.
        let next=try AppModel(root:root,startServices:false);defer {next.prepareForLibrarySwitch();try? next.store.close()}
        next.maintain(observeWorker:{XCTFail("Retired maintenance created a worker")});next.prepareForLibrarySwitch();await next.cancelExternalWorkAndWait()
        XCTAssertNotNil(try next.store.get("old"));XCTAssertFalse(next.hasPendingDestructiveWork)
    }
    func cancelledDrainCaller(_ deletion:Bool)async throws {
        let model=app!,gate=ImportWorkerGate();defer {gate.release()}
        if deletion {model.delete(try XCTUnwrap(model.store.get("old")),observeWorker:{try gate.pause()})}
        else {model.maintain(observeWorker:{try gate.pause()})}
        await fulfillment(of:[gate.entered],timeout:5)
        var finished=false
        let drain=Task {await model.cancelDestructiveWorkAndWait();finished=true};drain.cancel()
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(finished);XCTAssertTrue(model.hasPendingDestructiveWork)
        model.maintain(observeWorker:{XCTFail("A drain cannot admit another worker")});model.delete(try XCTUnwrap(model.store.get("old")),observeWorker:{XCTFail("A drain cannot admit deletion")})
        gate.release();await drain.value
        XCTAssertTrue(finished);XCTAssertFalse(model.hasPendingDestructiveWork);XCTAssertNotNil(try model.store.get("old"))
        model.delete(try XCTUnwrap(model.store.get("old")));try await settle();XCTAssertNil(try model.store.get("old"));XCTAssertTrue(model.deletionStatus?.hasPrefix("Removed 1 source") == true)
    }
    func testCancelledDeleteDrainCallerStillJoinsAndAllowsLaterWork()async throws {try await cancelledDrainCaller(true)}
    func testCancelledMaintenanceDrainCallerStillJoinsAndAllowsLaterWork()async throws {try await cancelledDrainCaller(false)}
    func committed(_ deletion:Bool)async throws {
        let model=app!,gate=ImportWorkerGate();defer {gate.release()}
        let hold:@Sendable ()->Void={do {try gate.pause()} catch {}}
        if deletion {model.delete(try XCTUnwrap(model.store.get("old")),observeCompletion:hold)}else {model.maintain(observeCompletion:hold)}
        await fulfillment(of:[gate.entered],timeout:5);XCTAssertEqual(try model.store.stats().count,0,"Observe a real committed deletion before cancellation")
        model.prepareForLibrarySwitch();var finished=false
        let drain=Task {await model.cancelExternalWorkAndWait();finished=true}
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(finished);XCTAssertTrue(model.hasPendingExitWork)
        gate.release();await drain.value
        XCTAssertEqual(try model.store.stats().count,0);XCTAssertFalse(model.hasPendingDestructiveWork)
        XCTAssertFalse(model.deletionStatus?.contains("not deleted") ?? false);XCTAssertFalse(model.deletionStatus?.hasPrefix("Removed") ?? false)
        XCTAssertFalse(model.maintenanceStatus.hasPrefix("Removed"));XCTAssertNil(model.errorMessage)
    }
    func testDeleteCommitSurvivesRetirementAndLateCallbackPublishesNoSuccess()async throws {try await committed(true)}
    func testMaintenanceCommitSurvivesRetirementAndLateCallbackPublishesNoSuccess()async throws {try await committed(false)}
    func finishSession(_ value:AppSession)async throws {
        for _ in 0..<2000 {if !value.busy {break};try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(value.busy);XCTAssertNil(value.failure)
    }
    func openedSession()async throws->AppSession {
        var settings=AppSettings();settings.automaticMaintenance=false;try settings.save(root:root)
        let name="com.oswind.tests.destructive."+UUID().uuidString;let values=try XCTUnwrap(UserDefaults(suiteName:name));suite=name;defaults=values
        let value=AppSession(selection:.init(url:root,requiresExisting:true,origin:"owned-test"),defaults:values,locked:{false});session=value;try await finishSession(value);return value
    }
    func plainQuit(_ deletion:Bool)async throws {
        let session=try await openedSession(),model=try XCTUnwrap(session.model),gate=ImportWorkerGate();defer {gate.release()}
        if deletion {model.delete(try XCTUnwrap(model.store.get("old")),observeWorker:{try gate.pause()})}else {model.maintain(observeWorker:{try gate.pause()})}
        await fulfillment(of:[gate.entered],timeout:5)
        let delegate=AppDelegate(),done=expectation(description:"Quit resumed after destructive drain");var finished=false
        delegate.finishTermination={_ in finished=true;done.fulfill()}
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(finished);XCTAssertTrue(model.hasPendingExitWork)
        gate.release();await fulfillment(of:[done],timeout:5)
        XCTAssertTrue(finished);XCTAssertFalse(model.hasPendingExitWork);XCTAssertNotNil(try model.store.get("old"))
    }
    func testPlainQuitDelegateWaitsForActualDeletionWorker()async throws {try await plainQuit(true)}
    func testPlainQuitDelegateWaitsForActualMaintenanceWorker()async throws {try await plainQuit(false)}
    func switched(_ deletion:Bool)async throws {
        let session=try await openedSession(),old=try XCTUnwrap(session.model),gate=ImportWorkerGate();defer {gate.release()}
        let next=root.appendingPathComponent("next-library"),prepared=try MemoryStore(root:next);try prepared.close()
        if deletion {old.delete(try XCTUnwrap(old.store.get("old")),observeWorker:{try gate.pause()})}else {old.maintain(observeWorker:{try gate.pause()})}
        await fulfillment(of:[gate.entered],timeout:5);session.open(next,persist:false)
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertTrue(session.busy);XCTAssertNil(session.model);XCTAssertFalse(old.store.isClosed)
        gate.release();try await finishSession(session)
        XCTAssertTrue(old.store.isClosed);XCTAssertFalse(old.hasPendingExitWork);XCTAssertEqual(session.model?.store.root,next)
        XCTAssertEqual(try session.model?.store.stats().count,0);XCTAssertNotNil(try app.store.get("old"));XCTAssertFalse(old.maintenanceStatus.hasPrefix("Removed"));XCTAssertFalse(old.deletionStatus?.hasPrefix("Removed") ?? false)
    }
    func testSwitchWaitsForActualDeletionWorkerBeforeClosingOldStore()async throws {try await switched(true)}
    func testSwitchWaitsForActualMaintenanceWorkerBeforeClosingOldStore()async throws {try await switched(false)}
    func testDisablingAutomaticRetentionCancelsUncommittedAutomaticWorker()async throws {
        let gate=ImportWorkerGate();defer {gate.release()}
        app.showOnboarding=false;app.startConfiguredServices();app.configureAutomaticMaintenance(true)
        app.maintain(automatic:true,observeWorker:{try gate.pause()});await fulfillment(of:[gate.entered],timeout:5)
        app.configureAutomaticMaintenance(false);gate.release();try await settle()
        XCTAssertNotNil(try app.store.get("old"),"Turning automatic retention off must revoke its uncommitted worker")
    }
    func testChangingRetentionCancelsWorkerUsingObsoletePolicy()async throws {
        let gate=ImportWorkerGate();defer {gate.release()}
        app.maintain(observeWorker:{try gate.pause()});await fulfillment(of:[gate.entered],timeout:5)
        app.settings.privacy.retentionDays=90;gate.release();try await settle()
        XCTAssertNotNil(try app.store.get("old"),"The current policy keeps the 60-day source")
    }
    func testPolicyCancellationAfterCommitClearsCurrentStaleEvidence()async throws {
        let gate=ImportWorkerGate();defer {gate.release()}
        let note=try XCTUnwrap(app.store.get("old")),hit=SearchHit(memory:note,score:1,match:"owned")
        app.selected=note;app.hits=[hit];app.answer=Answer(text:"Owned answer",sources:[hit],provider:"evidence",duration:0)
        app.maintain(observeCompletion:{do {try gate.pause()}catch {}})
        await fulfillment(of:[gate.entered],timeout:5);XCTAssertEqual(try app.store.stats().count,0)
        app.settings.privacy.retentionDays=90
        await fulfillment(of:[gate.cancelled],timeout:5);gate.release();try await settle()
        XCTAssertEqual(try app.store.stats().count,0);XCTAssertNil(app.selected);XCTAssertTrue(app.hits.isEmpty);XCTAssertNil(app.answer)
        XCTAssertTrue(app.maintenanceStatus.hasPrefix("Removed 1 source"),"The already committed removal must not be reported as a rollback")
    }
    func testAutomaticPreferenceDoesNotRevokeExplicitManualCleanup()async throws {
        let gate=ImportWorkerGate();defer {gate.release()}
        app.settings.automaticMaintenance=true;app.maintain(observeWorker:{try gate.pause()})
        await fulfillment(of:[gate.entered],timeout:5);app.configureAutomaticMaintenance(false);gate.release();try await settle()
        XCTAssertNil(try app.store.get("old"));XCTAssertTrue(app.maintenanceStatus.hasPrefix("Removed 1 source"))
    }
    func testOnboardingSuspendsUncommittedAutomaticMaintenance()async throws {
        let gate=ImportWorkerGate();defer {gate.release()}
        app.showOnboarding=false;app.startConfiguredServices();app.configureAutomaticMaintenance(true)
        app.maintain(automatic:true,observeWorker:{try gate.pause()});await fulfillment(of:[gate.entered],timeout:5)
        app.showOnboarding=true;gate.release();try await settle();XCTAssertNotNil(try app.store.get("old"))
    }
    func testFailedPolicySaveStillCancelsObsoleteMaintenance()async throws {
        let gate=ImportWorkerGate();defer {gate.release()}
        try app.settings.save(root:root)
        app.maintain(observeWorker:{try gate.pause()});await fulfillment(of:[gate.entered],timeout:5)
        let lock=root.appendingPathComponent(".settings-admission.lock"),marker=root.appendingPathComponent("untouched")
        try Data("owned marker".utf8).write(to:marker);try FileManager.default.removeItem(at:lock);try FileManager.default.createSymbolicLink(at:lock,withDestinationURL:marker)
        app.settings.privacy.retentionDays=90
        await fulfillment(of:[gate.cancelled],timeout:5);gate.release();try await settle()
        XCTAssertNotNil(app.errorMessage);XCTAssertNotNil(try app.store.get("old"));XCTAssertEqual(try String(contentsOf:marker,encoding:.utf8),"owned marker")
    }
    func testReconfiguringEnabledTimerDoesNotCancelPermittedAutomaticWorker()async throws {
        let gate=ImportWorkerGate();defer {gate.release()}
        app.showOnboarding=false;app.startConfiguredServices();app.configureAutomaticMaintenance(true)
        app.maintain(automatic:true,observeWorker:{try gate.pause()});await fulfillment(of:[gate.entered],timeout:5)
        app.configureAutomaticMaintenance(true);gate.release();try await settle()
        XCTAssertNil(try app.store.get("old"));XCTAssertTrue(app.maintenanceStatus.hasPrefix("Removed 1 source"))
    }
    func testQueuedServiceStartupCannotReactivateRetiredLibrary()throws {
        app.showOnboarding=false;app.prepareForLibrarySwitch();app.configureAutomaticMaintenance(true)
        XCTAssertFalse(app.housekeepingActive,"A retired model cannot start a new timer")
        app.startConfiguredServices();XCTAssertFalse(app.housekeepingActive);XCTAssertFalse(app.isCapturing);XCTAssertEqual(app.apiStatus,"API off")
    }
    func testQueuedCleanupConfigurationCannotStartTimerOnClosedLibrary()throws {
        app.showOnboarding=false;try app.store.close();app.configureAutomaticMaintenance(true)
        XCTAssertFalse(app.housekeepingActive);app.startConfiguredServices();XCTAssertFalse(app.housekeepingActive)
    }
    func lateBinding(_ closed:Bool)throws {
        try app.settings.save(root:root)
        let file=root.appendingPathComponent("settings.json"),before=try Data(contentsOf:file),enabled=app.settings.apiEnabled
        if closed {try app.store.close()}else {app.prepareForLibrarySwitch()}
        app.settings.apiEnabled.toggle()
        XCTAssertEqual(app.settings.apiEnabled,enabled,"A detached view binding must not change its retired model")
        XCTAssertEqual(try Data(contentsOf:file),before,"No preferences write may follow workspace retirement/close")
    }
    func testDirectBindingCannotWriteRetiredLibraryPreferences()throws {try lateBinding(false)}
    func testDirectBindingCannotWriteClosedLibraryPreferences()throws {try lateBinding(true)}
    func lateWipe(_ closed:Bool)throws {
        try app.settings.save(root:root)
        let file=root.appendingPathComponent("settings.json"),before=try Data(contentsOf:file)
        if closed {try app.store.close()}else {app.prepareForLibrarySwitch()}
        app.wipeLocalLibrary()
        XCTAssertFalse(app.libraryWipe.busy,"A departed workspace cannot accept a queued wipe")
        XCTAssertNil(app.libraryWipe.result)
        XCTAssertEqual(try Data(contentsOf:file),before)
        let reader=try MemoryStore(root:root);defer {try? reader.close()}
        XCTAssertNotNil(try reader.get("old"))
    }
    func testQueuedWipeCannotStartOnRetiredLibrary()throws {try lateWipe(false)}
    func testQueuedWipeCannotStartOnClosedLibrary()throws {try lateWipe(true)}
}
