import XCTest
import AppKit
@testable import OSwindCore
@testable import OSwind

@MainActor final class PersonalSyncLifecycleTests:XCTestCase {
    var root:URL!,app:AppModel!,session:AppSession?,defaults:UserDefaults!,suite:String!
    var folders=[SyncObjectFolder](),gates=[ImportWorkerGate](),holders=[Task<Void,Error>]()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-sync-app-"+UUID().uuidString);try Paths.ensure(root)
        let library=root.appendingPathComponent("library")
        var settings=AppSettings();settings.captureOnLaunch=false;settings.apiEnabled=false;settings.routinesEnabled=false;settings.automaticMaintenance=false;settings.entityAutomaticIndex=false
        try Paths.ensure(library);try settings.save(root:library)
        app=try AppModel(root:library,startServices:false,personalSyncSetup:{PersonalSyncModel(store:$0,locked:{false})});app.showOnboarding=false
        suite="com.oswind.tests.sync."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
    }
    override func tearDown()async throws {
        for gate in gates {gate.release()};for holder in holders {_ = try? await holder.value}
        if let model=session?.model {model.prepareForLibrarySwitch();await model.cancelExternalWorkAndWait();try model.store.close();session?.model=nil}
        app?.prepareForLibrarySwitch();await app?.cancelExternalWorkAndWait();try app?.store.close();app=nil;session=nil
        for folder in folders {folder.close()}
        defaults?.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)
    }
    func wait(_ predicate:()->Bool,_ message:String,file:StaticString=#filePath,line:UInt=#line)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(15))
        while !predicate(),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertTrue(predicate(),message,file:file,line:line)
    }
    func attach(_ model:AppModel)async throws->PersonalSyncSession {
        model.showOnboarding=false;try await SourceWorkTestJob.settle(model)
        let group=UUID().uuidString.lowercased(),epoch=UUID().uuidString.lowercased(),replica=UUID().uuidString.lowercased(),secret=SyncGroupSecret()
        let shared=try SyncObjectFolder.create(at:root.appendingPathComponent("shared-"+UUID().uuidString),secret:secret,group:group,epoch:epoch)
        let inbox=try SyncObjectFolder.create(at:model.store.root.appendingPathComponent("images/sync-owner"),secret:secret,group:group,epoch:epoch);folders += [shared,inbox]
        let service=try SyncLibraryService.install(library:model.store,replica:replica,group:group,epoch:epoch,peers:[],transport:shared,inbox:inbox)
        let connection=try PersonalSyncSession(service:service,schedule:.init(activeSeconds:0.005,idleSeconds:0.02,retrySeconds:0.02))
        try model.personalSync.attachPrepared(connection);model.personalSync.start()
        try await wait({model.personalSync.status?.phase == .upToDate && !model.personalSync.changing},"Actual sync service did not reach idle")
        XCTAssertTrue(model.hasPendingExitWork,"Even idle sync owns the app's exit path")
        return connection
    }
    /// Hold actual SQL, then positively observe the sync tick's shared media
    /// lease. No synthetic scheduler callback or replacement worker is involved.
    func heldTick(_ model:AppModel)async throws->ImportWorkerGate {
        let gate=ImportWorkerGate(),store=model.store;gates.append(gate)
        let holder=Task.detached {try store.withRoutineDatabase {_ in try gate.pause()}};holders.append(holder)
        await fulfillment(of:[gate.entered],timeout:10)
        let library=store.root
        let blocked=try await Task.detached {()->Bool in
            let deadline=ContinuousClock.now.advanced(by:.seconds(10))
            while ContinuousClock.now<deadline {
                var busy=false
                do {let lease=try MediaAdmissionLease.acquire(root:library,exclusive:true,timeout:0,onBusy:{busy=true});lease.release()}
                catch {if busy {return true};throw error}
                try Task.checkCancellation();Thread.sleep(forTimeInterval:0.005)
            };return false
        }.value
        XCTAssertTrue(blocked,"No actual sync lease was held behind the SQL barrier")
        return gate
    }
    func testActualSyncWorkerOwnsCancelledDrainUntilSQLAndMediaLeaseReturn()async throws {
        let connection=try await attach(app);let gate=try await heldTick(app)
        app.prepareForLibrarySwitch();let model=app!;var drained=false
        let drain=Task {await model.cancelExternalWorkAndWait();drained=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(40))
        XCTAssertFalse(drained);XCTAssertTrue(model.hasPendingExitWork);XCTAssertFalse(model.store.isClosed)
        gate.release();await drain.value
        XCTAssertFalse(model.hasPendingExitWork);XCTAssertFalse(model.personalSync.busy)
        let status=await connection.status();XCTAssertEqual(status.phase,.stopped)
        model.personalSync.start();model.personalSync.wake();model.personalSync.setNetworkEnabled(true)
        try await Task.sleep(for:.milliseconds(30));XCTAssertFalse(model.personalSync.busy)
    }
    func testActualOwnerSuspendsForOnboardingAndResumesOnlyItsPreparedConnection()async throws {
        _=try await attach(app)
        app.showOnboarding=true
        try await wait({app.personalSync.status?.phase == .suspended && !app.personalSync.changing},"Onboarding did not join sync processing")
        XCTAssertFalse(app.isCapturing);XCTAssertEqual(app.apiStatus,"API off")
        app.showOnboarding=false
        try await wait({app.personalSync.status?.phase == .upToDate && !app.personalSync.changing},"Owned sync did not resume after onboarding")
        XCTAssertFalse(app.isCapturing);XCTAssertEqual(app.apiStatus,"API off")
    }
    func testActualOwnerNetworkPauseKeepsLocalPreparationWithoutCaptureOrAPI()async throws {
        _=try await attach(app);app.personalSync.setNetworkEnabled(false)
        try await wait({app.personalSync.networkPaused && app.personalSync.status?.phase == .networkPaused && !app.personalSync.changing},"Network pause did not join the old worker")
        try app.store.insert(Memory(id:"local-while-paused",kind:.note,text:"Owned paused sync source"))
        try await wait({(try? self.app.store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM personal_sync_work")})==0 && (try? self.app.store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM personal_sync_changes")})==0},"Local work did not prepare while network was paused")
        XCTAssertFalse(app.isCapturing);XCTAssertEqual(app.apiStatus,"API off")
        app.personalSync.setNetworkEnabled(true)
        try await wait({!app.personalSync.networkPaused && !app.personalSync.changing && app.personalSync.status?.phase == .upToDate},"Network delivery did not resume")
    }
    func testActualWipeWaitsForSyncThenClearsHistoryWithoutRevivingTheOldSession()async throws {
        try app.store.insert(Memory(id:"wipe-owned",kind:.note,text:"Owned wipe source"))
        let connection=try await attach(app),gate=try await heldTick(app)
        app.wipeLocalLibrary();XCTAssertTrue(app.libraryWipe.busy)
        try await Task.sleep(for:.milliseconds(40));XCTAssertTrue(app.libraryWipe.busy);XCTAssertFalse(app.store.isClosed)
        gate.release();try await wait({!app.libraryWipe.busy},"Wipe did not finish after sync joined")
        XCTAssertNil(app.libraryWipe.error);XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
        XCTAssertFalse(app.personalSync.configured);XCTAssertFalse(app.personalSync.busy)
        let status=await connection.status();XCTAssertEqual(status.phase,.stopped)
    }
    func openedSession()async throws->AppModel {
        let store=app.store;app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try store.close();app=nil
        let value=AppSession(selection:.init(url:store.root,requiresExisting:true,origin:"owned-sync"),defaults:defaults,locked:{false},personalSyncSetup:{PersonalSyncModel(store:$0,locked:{false})});session=value
        try await wait({!value.busy},"Session did not open");XCTAssertNil(value.failure)
        let model=try XCTUnwrap(value.model);model.showOnboarding=false;try await SourceWorkTestJob.settle(model);return model
    }
    func testPlainQuitJoinsActualSyncWorkerBeforeReplying()async throws {
        let model=try await openedSession();_=try await attach(model);let gate=try await heldTick(model)
        let delegate=AppDelegate();var finished=false;let done=expectation(description:"Quit joined sync")
        delegate.finishTermination={_ in finished=true;done.fulfill()}
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
        try await Task.sleep(for:.milliseconds(40));XCTAssertFalse(finished);XCTAssertTrue(model.hasPendingExitWork)
        gate.release();await fulfillment(of:[done],timeout:15)
        XCTAssertFalse(model.hasPendingExitWork);XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateNow)
    }
    func testLibrarySwitchJoinsActualSyncBeforeClosingItsStore()async throws {
        let model=try await openedSession();_=try await attach(model);let gate=try await heldTick(model)
        let next=root.appendingPathComponent("next"),prepared=try MemoryStore(root:next);try prepared.close()
        session!.open(next,persist:false)
        try await Task.sleep(for:.milliseconds(40));XCTAssertTrue(session!.busy);XCTAssertFalse(model.store.isClosed)
        gate.release();try await wait({!self.session!.busy},"Switch did not finish after sync joined")
        XCTAssertNil(session!.failure);XCTAssertTrue(model.store.isClosed);XCTAssertFalse(model.hasPendingExitWork)
        XCTAssertEqual(session!.model?.store.root,next)
    }
    func testNativeVaultLockJoinsActualSyncBeforeDetachingOwnedImage()async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned sync APFS fixture; never opens a user vault or Keychain")}
        let package=root.appendingPathComponent("SyncOwner.oswindvault"),secret=UUID().uuidString
        _=try await LibraryVault.create(at:package,name:"Owned sync lifecycle",capacityGiB:1,passphrase:Data(secret.utf8))
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();app=nil
        let value=AppSession(selection:.init(url:package,requiresExisting:true,origin:"owned-sync-vault"),defaults:defaults,locked:{false},personalSyncSetup:{PersonalSyncModel(store:$0,locked:{false})});session=value
        try await wait({!value.busy},"Vault session did not open")
        value.unlock(passphrase:secret,remember:false);try await wait({!value.busy},"Owned vault did not unlock")
        XCTAssertNil(value.failure);let model=try XCTUnwrap(value.model)
        try model.store.insert(Memory(id:"encrypted-keep",kind:.note,text:"Owned encrypted source survives sync shutdown"))
        let connection=try await attach(model),gate=try await heldTick(model)
        value.requestLock();try await wait({value.busy && value.model==nil},"Lock did not retire visible access")
        XCTAssertFalse(model.store.isClosed)
        let held=try await LibraryVault(package:package).status();XCTAssertTrue(held.imageAttached);XCTAssertTrue(held.volumeMounted)
        gate.release();try await wait({!value.busy},"Lock did not finish after actual sync returned")
        XCTAssertNil(value.failure);XCTAssertTrue(model.store.isClosed);XCTAssertFalse(model.hasPendingExitWork)
        XCTAssertEqual(value.vaultStatus?.state,.locked);XCTAssertEqual(value.vaultStatus?.imageAttached,false)
        let stopped=await connection.status();XCTAssertEqual(stopped.phase,.stopped)
        value.unlock(passphrase:secret,remember:false);try await wait({!value.busy},"Owned vault did not reopen")
        XCTAssertNil(value.failure);XCTAssertNotNil(try value.model?.store.get("encrypted-keep"));XCTAssertFalse(value.model?.personalSync.configured ?? true)
        value.requestLock();try await wait({!value.busy},"Final owned vault cleanup did not finish")
        XCTAssertNil(value.failure);XCTAssertEqual(value.vaultStatus?.imageAttached,false)
    }

    func testPreparedSessionCannotAttachToAnotherNativeLibrary()async throws {
        let connection=try await attach(app),otherRoot=root.appendingPathComponent("foreign")
        let other=try AppModel(root:otherRoot,startServices:false,personalSyncSetup:{PersonalSyncModel(store:$0,locked:{false})});other.showOnboarding=false
        try await SourceWorkTestJob.settle(other)
        XCTAssertThrowsError(try other.personalSync.attachPrepared(connection))
        XCTAssertFalse(other.personalSync.configured);XCTAssertFalse(other.personalSync.busy)
        other.prepareForLibrarySwitch();await other.cancelExternalWorkAndWait();try other.store.close()
        XCTAssertTrue(app.personalSync.configured)
    }

}
