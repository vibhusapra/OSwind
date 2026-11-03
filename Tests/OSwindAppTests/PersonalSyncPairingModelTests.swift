import XCTest
import SwiftUI
import AppKit
import Vision
import CSQLite
import MachO
@testable import OSwindCore
@testable import OSwind

@MainActor final class PersonalSyncPairingModelTests:XCTestCase {
    private var root:URL!,a:MemoryStore!,b:MemoryStore!,storage:PairingAppStorage!
    var models=[PersonalSyncModel](),sessions=[AppSession]()
    var preferenceSuites=[String]()
    private var phaseStarted:TimeInterval=0
    private func trace(_ phase:String) {
        let line="OWNED_PAIRING_PHASE case=\(name) phase=\(phase) elapsedSeconds=\(ProcessInfo.processInfo.systemUptime-phaseStarted)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
    override func setUpWithError()throws {
        phaseStarted=ProcessInfo.processInfo.systemUptime;trace("setup-begin")
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-pairing-app-"+UUID().uuidString)
        a=try MemoryStore(root:root.appendingPathComponent("a"));trace("setup-store-a")
        b=try MemoryStore(root:root.appendingPathComponent("b"));trace("setup-store-b")
        storage=PairingAppStorage();trace("setup-complete")
    }
    override func tearDown()async throws {
        trace("teardown-begin")
        for session in sessions {_=await session.lockForTermination();try? session.model?.store.close();session.model=nil};sessions=[]
        trace("teardown-sessions")
        for model in models {await model.cancelAndWait()}
        trace("teardown-models")
        for name in preferenceSuites {UserDefaults(suiteName:name)?.removePersistentDomain(forName:name)}
        trace("teardown-preferences")
        try a.close();trace("teardown-store-a")
        try b.close();trace("teardown-store-b")
        try FileManager.default.removeItem(at:root);trace("teardown-complete")
    }
    func model(_ store:MemoryStore,gate:ImportWorkerGate?=nil)->PersonalSyncModel {
        let state=root.appendingPathComponent("state"),storage=storage!
        let value=PersonalSyncModel(store:store,locked:{false},pairingFactory:{store in
            try gate?.pause()
            return try PersonalSyncPairing(store:store,stateRoot:state,machine:PairingAppMachine(),storage:storage)
        });models.append(value);return value
    }
    func done(_ model:PersonalSyncModel,caller:UInt=#line)async throws {
        trace("pairing-wait-\(caller)-begin")
        let deadline=ContinuousClock.now.advanced(by:.seconds(15))
        while model.pairingBusy,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        guard !model.pairingBusy else {
            trace("pairing-wait-\(caller)-timeout")
            throw OSwindError.unavailable("Owned pairing action did not finish: caller=\(caller) configured=\(model.configured) preparing=\(model.preparing) stopping=\(model.stopping) error=\(model.pairingError ?? "none")")
        }
        trace("pairing-wait-\(caller)-complete")
    }
    private func pairedModels()async throws->(PersonalSyncModel,PersonalSyncModel) {
        try AppSettings().save(root:a.root);try AppSettings().save(root:b.root)
        let owner=model(a),peer=model(b)
        owner.performPairing(.create("Desk Mac"));peer.performPairing(.request("Travel Mac"));try await done(owner);try await done(peer)
        owner.performPairing(.review(try XCTUnwrap(peer.pairingStatus?.request)));try await done(owner)
        owner.performPairing(.approve(try XCTUnwrap(owner.pairingReview)));try await done(owner)
        peer.performPairing(.accept(try XCTUnwrap(owner.pairingResponse),try XCTUnwrap(owner.pairingStatus?.rootFingerprint)));try await done(peer)
        return(owner,peer)
    }
    private func connected(_ model:PersonalSyncModel,phase:PersonalSyncStatus.Phase = .upToDate)async throws {
        // Functional readiness is not a wall-time performance benchmark. Keep
        // the ordinary budget; instrumented native schema work needs more room.
        let instrumented=(0..<_dyld_image_count()).contains {index in
            guard let raw=_dyld_get_image_name(index) else {return false}
            return URL(fileURLWithPath:String(cString:raw)).lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib"
        }
        let seconds=instrumented ? 120:20,started=ContinuousClock.now,deadline=started.advanced(by:.seconds(seconds))
        while true {
            if let error=model.error {throw OSwindError.unavailable(error)}
            if model.configured,!model.preparing,!model.changing,model.status?.phase==phase {
                let elapsed=started.duration(to:ContinuousClock.now),parts=elapsed.components,value=Double(parts.seconds)+Double(parts.attoseconds)/1e18
                if instrumented || value>=20 {print("OWNED_SYNC_APP_READY sanitizer=\(instrumented) timeoutSeconds=\(seconds) elapsedSeconds=\(value) phase=\(String(describing:phase))")}
                return
            }
            // Observe the final state after an actor suspension even when the
            // clock expired while this executor could not resume.
            guard ContinuousClock.now<deadline else {
                throw OSwindError.unavailable("Owned app connection did not reach \(String(describing:phase)); configured=\(model.configured), preparing=\(model.preparing), changing=\(model.changing), phase=\(model.status.map {String(describing:$0.phase)} ?? "none"), sanitizer=\(instrumented), budget=\(seconds)s")
            }
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    func testClosingSetupAndReopeningRecoversExactApprovalWithoutConnecting()async throws {
        let (owner,peer)=try await pairedModels(),original=try XCTUnwrap(owner.pairingResponse),accounts=Set(storage.values.keys)
        owner.clearPairingMessages();XCTAssertNil(owner.pairingResponse)
        XCTAssertTrue(try XCTUnwrap(owner.pairingStatus).lastResponseAvailable)
        owner.performPairing(.recoverResponse);try await done(owner)
        XCTAssertEqual(owner.pairingResponse,original);XCTAssertFalse(owner.configured);XCTAssertNil(owner.status)
        await owner.cancelAndWait();await peer.cancelAndWait()
        let reopened=model(a);reopened.performPairing(.load);try await done(reopened)
        XCTAssertNil(reopened.pairingResponse);XCTAssertTrue(try XCTUnwrap(reopened.pairingStatus).lastResponseAvailable)
        reopened.performPairing(.recoverResponse);try await done(reopened)
        XCTAssertNil(reopened.pairingError);XCTAssertEqual(reopened.pairingResponse,original)
        XCTAssertFalse(reopened.configured);XCTAssertFalse(reopened.pairingBusy);XCTAssertTrue(reopened.busy,"The credential owner remains in the library departure barrier");XCTAssertNil(reopened.folderURL);XCTAssertNil(reopened.status)
        XCTAssertEqual(Set(storage.values.keys),accounts)
        await reopened.cancelAndWait();XCTAssertFalse(reopened.busy)
    }
    func testExplicitRecoveryWithoutApprovalReportsErrorAndCreatesNoCredentials()async throws {
        let value=model(a);value.performPairing(.create("Desk Mac"));try await done(value)
        let before=storage.values
        value.performPairing(.recoverResponse);try await done(value)
        XCTAssertNotNil(value.pairingError);XCTAssertNil(value.pairingResponse);XCTAssertFalse(value.configured)
        XCTAssertTrue(storage.values==before,"Original private accounts changed")
    }
    func testDepartureJoinsActualBlockedResponseRecoveryDespiteCancellation()async throws {
        let (owner,peer)=try await pairedModels(),before=storage.values,gate=PairingSaveGate()
        defer {gate.release();storage.installRead(nil)}
        storage.installRead(gate);owner.clearPairingMessages();owner.performPairing(.recoverResponse)
        await fulfillment(of:[gate.entered],timeout:10)
        var departed=false
        let drain=Task {await owner.cancelAndWait();departed=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(60));XCTAssertFalse(departed);XCTAssertTrue(owner.busy)
        gate.release();await drain.value
        XCTAssertTrue(departed);XCTAssertFalse(owner.busy);XCTAssertNil(owner.pairingResponse)
        XCTAssertTrue(storage.values==before,"Original private accounts changed");XCTAssertFalse(owner.configured)
        await peer.cancelAndWait()
    }
    func testOwnedApprovalRecoveryScreensRenderInBothThemes()async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_APPROVAL_RENDER_DIR"] else {throw XCTSkip("Explicit owned approval recovery render output absent")}
        let directory=URL(fileURLWithPath:path);try Paths.ensure(directory)
        let (owner,_)=try await pairedModels(),response=try XCTUnwrap(owner.pairingResponse),expiry=try XCTUnwrap(owner.pairingResponseExpiry)
        owner.clearPairingMessages()
        for dark in [false,true] {try await renderView(PersonalSyncPairingView(model:owner),name:"approval-recover",dark:dark,width:660,height:650,directory:directory,expected:"recover last joining response")}
        owner.performPairing(.recoverResponse);try await done(owner)
        XCTAssertEqual(owner.pairingResponse,response);XCTAssertEqual(owner.pairingResponseExpiry,expiry)
        for dark in [false,true] {
            try await renderView(PersonalSyncPairingView(model:owner),name:"approval-restored",dark:dark,width:660,height:650,directory:directory,expected:"request expires")
            let text=try String(contentsOf:directory.appendingPathComponent("approval-restored-\(dark ? "dark":"light").ocr.txt"),encoding:.utf8)
            XCTAssertTrue(text.contains("copy response"));XCTAssertTrue(text.contains("original request expiry"))
        }
    }
    func testFolderActivationTransfersPreviewOwnersAndDeliversBothLibraries()async throws {
        let (owner,peer)=try await pairedModels(),shared=root.appendingPathComponent("shared")
        try a.insert(Memory(id:"desk",text:"Owned desk memory"));try b.insert(Memory(id:"travel",text:"Owned travel memory"))
        owner.connectFolder(shared,create:true);try await connected(owner)
        peer.connectFolder(shared);try await connected(peer)
        owner.setNetworkEnabled(false);try await connected(owner,phase:.networkPaused)
        owner.setNetworkEnabled(true);try await connected(owner)
        XCTAssertTrue(owner.ownsHistoryRetirement);XCTAssertTrue(peer.ownsHistoryRetirement)
        XCTAssertNil(owner.pairingStatus);XCTAssertNil(peer.pairingStatus)
        XCTAssertEqual(try a.stats(includeDiskUsage:false).count,2);XCTAssertEqual(try b.stats(includeDiskUsage:false).count,2)
        XCTAssertEqual(storage.values.count,4)
        await owner.cancelAndWait();await peer.cancelAndWait();XCTAssertFalse(owner.busy);XCTAssertFalse(peer.busy)
        owner.prepareForReconnection();owner.reconnectSavedFolder();try await connected(owner)
        XCTAssertEqual(storage.values.count,4)
    }
    private func settledConnectionWork(_ value:PersonalSyncModel)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(20))
        while (value.preparing || value.changing),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        guard !value.preparing,!value.changing,value.error==nil else {throw OSwindError.unavailable(value.error ?? "Owned sync configuration did not settle")}
    }
    func testOptedInRelaunchRestoresOriginalFolderAndDurableNetworkPause()async throws {
        let (owner,peer)=try await pairedModels(),shared=root.appendingPathComponent("shared")
        owner.connectFolder(shared,create:true);try await connected(owner)
        owner.setReconnectOnLaunch(true);owner.setNetworkEnabled(false);try await connected(owner,phase:.networkPaused)
        XCTAssertEqual(try a.personalSyncPreferences(),.init(reconnectOnLaunch:true,networkEnabled:false))
        let accounts=Set(storage.values.keys)
        await owner.cancelAndWait();await peer.cancelAndWait()
        let restored=model(a);restored.configure(active:true);restored.restoreSavedConnectionIfEnabled()
        try await connected(restored,phase:.networkPaused)
        XCTAssertTrue(restored.reconnectOnLaunch);XCTAssertTrue(restored.networkPaused)
        XCTAssertEqual(restored.folderURL?.resolvingSymlinksInPath(),shared.resolvingSymlinksInPath())
        XCTAssertEqual(Set(storage.values.keys),accounts)
        restored.setNetworkEnabled(true);try await connected(restored)
        XCTAssertEqual(try a.personalSyncPreferences(),.init(reconnectOnLaunch:true,networkEnabled:true))
        restored.setReconnectOnLaunch(false)
        try await settledConnectionWork(restored)
        XCTAssertFalse(restored.changing);XCTAssertFalse(try a.personalSyncPreferences().reconnectOnLaunch)
        await restored.cancelAndWait()
        let disabled=model(a);disabled.configure(active:true);disabled.restoreSavedConnectionIfEnabled()
        try await settledConnectionWork(disabled)
        XCTAssertFalse(disabled.configured);XCTAssertFalse(disabled.busy);XCTAssertNil(disabled.error)
        XCTAssertEqual(Set(storage.values.keys),accounts)
    }
    func testDisabledStartupNeverOpensPairingAndDeniedWakeCanRetryOriginalIntent()async throws {
        let unused=PersonalSyncModel(store:a,locked:{false},pairingFactory:{_ in throw OSwindError.unavailable("Disabled startup touched pairing")});models.append(unused)
        unused.restoreSavedConnectionIfEnabled()
        try await settledConnectionWork(unused)
        XCTAssertTrue(storage.values.isEmpty);XCTAssertFalse(unused.busy)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("state").path))
        let (owner,peer)=try await pairedModels(),shared=root.appendingPathComponent("shared")
        owner.connectFolder(shared,create:true);try await connected(owner)
        owner.setReconnectOnLaunch(true)
        try await settledConnectionWork(owner)
        await owner.cancelAndWait();await peer.cancelAndWait()
        let restored=model(a);restored.allowed={false};restored.configure(active:true);restored.restoreSavedConnectionIfEnabled()
        XCTAssertFalse(restored.preparing);XCTAssertFalse(restored.configured)
        restored.allowed={true};restored.wake();try await connected(restored)
        XCTAssertTrue(restored.reconnectOnLaunch)
    }
    func testCanceledStartupJoinsRealSavedIntentReadBeforeStorageDeparture()async throws {
        let original=model(a),store=a!,gate=ImportWorkerGate()
        let holder=Task.detached {try store.withRoutineDatabase {_ in try gate.pause()}}
        defer {gate.release()}
        await fulfillment(of:[gate.entered],timeout:10)
        original.restoreSavedConnectionIfEnabled();XCTAssertTrue(original.preparing)
        var departed=false
        let drain=Task {await original.cancelAndWait();departed=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(60));XCTAssertFalse(departed)
        gate.release();try await holder.value;await drain.value
        XCTAssertTrue(departed);XCTAssertFalse(original.busy);XCTAssertTrue(storage.values.isEmpty)
    }
    func testDepartureJoinsActualPreferenceCommitAfterCallerCancellation()async throws {
        let (owner,_)=try await pairedModels(),gate=PairingSaveGate()
        owner.connectFolder(root.appendingPathComponent("shared"),create:true);try await connected(owner)
        let accounts=Set(storage.values.keys),store=a!
        _=try store.withRoutineDatabase {db in
            sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,sql in
                guard let context,let sql else {return 0}
                let statement=String(cString:sql.assumingMemoryBound(to:CChar.self))
                if statement.hasPrefix("INSERT INTO store_metadata(key,value) VALUES('sync-session-preferences-v1'") {Unmanaged<PairingSaveGate>.fromOpaque(context).takeUnretainedValue().pause()}
                return 0
            },Unmanaged.passUnretained(gate).toOpaque())
        }
        defer {gate.release();_=try? store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}}
        owner.setReconnectOnLaunch(true);await fulfillment(of:[gate.entered],timeout:10)
        var joined=false
        let drain=Task {await owner.cancelAndWait();joined=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(60));XCTAssertFalse(joined);XCTAssertFalse(store.isClosed)
        gate.release();await drain.value
        XCTAssertTrue(joined);XCTAssertFalse(owner.busy);XCTAssertEqual(Set(storage.values.keys),accounts)
        XCTAssertEqual(try store.personalSyncPreferences(),.init(reconnectOnLaunch:true,networkEnabled:true))
    }
    func testResumeWaitsForSavedPreferenceAndFailedPauseReportsItsSessionScope()async throws {
        let (owner,_)=try await pairedModels()
        owner.connectFolder(root.appendingPathComponent("shared"),create:true);try await connected(owner)
        owner.setReconnectOnLaunch(true);owner.setNetworkEnabled(false);try await connected(owner,phase:.networkPaused)
        func rejectSaves()throws {try a.withRoutineDatabase {try $0.execute("CREATE TRIGGER owned_reject_sync_preferences BEFORE INSERT ON store_metadata WHEN new.key='sync-session-preferences-v1' BEGIN SELECT RAISE(ABORT,'Owned preference write unavailable'); END")}}
        func allowSaves()throws {try a.withRoutineDatabase {try $0.execute("DROP TRIGGER IF EXISTS owned_reject_sync_preferences")}}
        defer {try? allowSaves()}
        try rejectSaves();owner.setNetworkEnabled(true)
        let first=ContinuousClock.now.advanced(by:.seconds(10))
        while owner.changing,ContinuousClock.now<first {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(owner.changing);XCTAssertNotNil(owner.error);XCTAssertTrue(owner.networkPaused)
        XCTAssertEqual(try a.personalSyncPreferences(),.init(reconnectOnLaunch:true,networkEnabled:false))
        try allowSaves();owner.setNetworkEnabled(true);try await connected(owner)
        try rejectSaves();owner.setNetworkEnabled(false)
        let second=ContinuousClock.now.advanced(by:.seconds(10))
        while owner.changing,ContinuousClock.now<second {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(owner.changing);XCTAssertTrue(owner.networkPaused)
        XCTAssertTrue(owner.error?.contains("future reconnect uses the previous saved settings")==true)
        XCTAssertEqual(try a.personalSyncPreferences(),.init(reconnectOnLaunch:true,networkEnabled:true))
        try allowSaves();owner.setNetworkEnabled(false);try await connected(owner,phase:.networkPaused)
        XCTAssertEqual(try a.personalSyncPreferences(),.init(reconnectOnLaunch:true,networkEnabled:false))
    }
    func testOwnedReconnectIntentScreensRenderInBothThemes()async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_SYNC_INTENT_RENDER_DIR"] else {throw XCTSkip("Explicit owned reconnect intent render output absent")}
        let directory=URL(fileURLWithPath:path);try Paths.ensure(directory)
        let (owner,peer)=try await pairedModels(),shared=root.appendingPathComponent("shared")
        owner.connectFolder(shared,create:true);try await connected(owner)
        for dark in [false,true] {try await renderView(PersonalSyncPairingView(model:owner),name:"intent-default",dark:dark,width:660,height:650,directory:directory,expected:"reconnect when oswind opens this library")}
        owner.setReconnectOnLaunch(true);owner.setNetworkEnabled(false);try await connected(owner,phase:.networkPaused)
        for dark in [false,true] {try await renderView(PersonalSyncPairingView(model:owner),name:"intent-paused",dark:dark,width:660,height:650,directory:directory,expected:"resume delivery")}
        await owner.cancelAndWait();await peer.cancelAndWait()
        let restored=model(a);restored.configure(active:true);restored.restoreSavedConnectionIfEnabled();try await connected(restored,phase:.networkPaused)
        for dark in [false,true] {try await renderView(PersonalSyncPairingView(model:restored),name:"intent-restored",dark:dark,width:660,height:650,directory:directory,expected:"resume delivery")}
    }
    func testCancelledActivationJoinsLateDeliveryCredentialAndCanResumeItsExactReservation()async throws {
        let (owner,_)=try await pairedModels(),shared=root.appendingPathComponent("shared"),gate=PairingSaveGate()
        defer {gate.release();storage.install(nil)}
        storage.install(gate);owner.connectFolder(shared,create:true)
        await fulfillment(of:[gate.entered],timeout:10)
        XCTAssertTrue(owner.preparing);var drained=false
        let drain=Task {await owner.cancelAndWait();drained=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(40));XCTAssertFalse(drained);XCTAssertFalse(a.isClosed)
        gate.release();await drain.value;storage.install(nil)
        XCTAssertFalse(owner.busy);XCTAssertFalse(owner.configured)
        let accounts=Set(storage.values.keys);XCTAssertEqual(accounts.count,3)
        owner.prepareForReconnection();owner.connectFolder(shared);try await connected(owner)
        XCTAssertEqual(Set(storage.values.keys),accounts)
    }
    func testActualModelReviewsExactLocalEraseAndResumesOnlyAfterExplicitApproval()async throws {
        let (owner,peer)=try await pairedModels(),shared=root.appendingPathComponent("shared")
        try a.insert(Memory(id:"before-review",text:"Owned history before review"))
        await owner.cancelAndWait()
        let credential=try PersonalSyncPairing(store:a,stateRoot:root.appendingPathComponent("state"),machine:PairingAppMachine(),storage:storage)
        let prepared=try credential.prepareSession(sharedFolder:shared,createSharedFolder:true)
        let erased=try await prepared.eraseLocalHistory();XCTAssertTrue(erased.cleanupComplete);try await prepared.stop()
        owner.prepareForReconnection();owner.reconnectSavedFolder();try await connected(owner,phase:.needsLocalEraseReview)
        owner.requestEraseReview()
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while owner.changing,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        let review=try XCTUnwrap(owner.eraseReview);XCTAssertEqual(Set(review.deviceNames),Set(["Desk Mac","Travel Mac"]))
        owner.approveErase(review);try await connected(owner)
        XCTAssertNil(owner.eraseReview);XCTAssertNil(owner.error)
        peer.connectFolder(shared);try await connected(peer,phase:.needsReceivedErase)
        XCTAssertEqual(try a.stats(includeDiskUsage:false).count,0)
    }
    func testQueuedReviewRechecksAdmissionAndDoesNotLeaveChangingStateStuck()async throws {
        let (owner,_)=try await pairedModels(),shared=root.appendingPathComponent("shared")
        await owner.cancelAndWait()
        let credential=try PersonalSyncPairing(store:a,stateRoot:root.appendingPathComponent("state"),machine:PairingAppMachine(),storage:storage)
        let prepared=try credential.prepareSession(sharedFolder:shared,createSharedFolder:true)
        _=try await prepared.eraseLocalHistory();try await prepared.stop()
        owner.prepareForReconnection();owner.reconnectSavedFolder();try await connected(owner,phase:.needsLocalEraseReview)
        owner.requestEraseReview()
        let reviewDeadline=ContinuousClock.now.advanced(by:.seconds(10))
        while owner.changing,ContinuousClock.now<reviewDeadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(owner.changing)
        let review=try XCTUnwrap(owner.eraseReview)
        owner.approveErase(review);owner.allowed={false}
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while owner.changing,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(owner.changing)
        XCTAssertEqual(try a.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM personal_sync_collection_approvals")},0)
        owner.allowed={true};owner.suspend();XCTAssertNil(owner.eraseReview)
    }
    func testErasureDrainWaitsForActualAppProducerBeforeAnyNativeDeletion()async throws {
        let (owner,_)=try await pairedModels(),shared=root.appendingPathComponent("shared"),gate=PairingAppDrainGate()
        try a.insert(Memory(id:"held-before-erase",text:"Owned source before held app drain"))
        owner.connectFolder(shared,create:true);try await connected(owner)
        let erase=Task {try await owner.eraseHistory(before:{await gate.wait()})}
        await fulfillment(of:[gate.entered],timeout:10)
        var departed=false
        let drain=Task {await owner.cancelAndWait();departed=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(40));XCTAssertFalse(departed);XCTAssertFalse(a.isClosed)
        XCTAssertEqual(try a.stats(includeDiskUsage:false).count,1)
        owner.prepareForReconnection();owner.connectFolder(shared);XCTAssertFalse(owner.preparing)
        gate.release()
        do {_=try await erase.value;XCTFail("Canceled app drain cannot start logical deletion")}catch {}
        await drain.value;XCTAssertTrue(departed);XCTAssertFalse(owner.busy);XCTAssertFalse(owner.configured)
        XCTAssertEqual(try a.stats(includeDiskUsage:false).count,1)
    }
    func testDisconnectedModelErasesLocallyWhileProviderFolderIsUnavailable()async throws {
        let (owner,_)=try await pairedModels(),shared=root.appendingPathComponent("shared"),parked=root.appendingPathComponent("parked-provider")
        try a.insert(Memory(id:"offline-app",text:"Owned source before native app erasure"))
        owner.connectFolder(shared,create:true);try await connected(owner)
        await owner.cancelAndWait();owner.prepareForReconnection()
        try FileManager.default.moveItem(at:shared,to:parked)
        let accounts=Set(storage.values.keys)
        XCTAssertTrue(a.requiresOwnedLibraryErasure);var joined=false
        let erased=try await owner.eraseHistory(before:{joined=true})
        XCTAssertTrue(joined);XCTAssertTrue(erased.cleanupComplete);XCTAssertEqual(erased.erasure.sources,1)
        XCTAssertFalse(owner.busy);XCTAssertFalse(owner.configured);XCTAssertEqual(Set(storage.values.keys),accounts)
        XCTAssertFalse(FileManager.default.fileExists(atPath:shared.path));XCTAssertEqual(try a.stats(includeDiskUsage:false).count,0)
        owner.prepareForReconnection();owner.performPairing(.load);try await done(owner)
        XCTAssertEqual(owner.pairingStatus?.phase,.owner)
    }
    private func rootSession(recoveryGate:PairingSaveGate?=nil)async throws->AppSession {
        let (owner,peer)=try await pairedModels();await owner.cancelAndWait();await peer.cancelAndWait()
        let location=a.root;try a.close()
        return try await openRootSession(location,recoveryGate:recoveryGate)
    }
    private func openRootSession(_ location:URL,recoveryGate:PairingSaveGate?=nil)async throws->AppSession {
        let state=root.appendingPathComponent("state"),backend=storage!
        var quiet=AppSettings();quiet.captureOnLaunch=false;quiet.apiEnabled=false;quiet.routinesEnabled=false;quiet.automaticMaintenance=false;quiet.entityAutomaticIndex=false;quiet.meetings = .init();quiet.clipboard.enabled=false
        try quiet.save(root:location)
        let environment=SyncNativeWriterEnvironment(stateRoot:state,machine:PairingAppMachine(),storage:{_ in backend})
        let suite="com.oswind.tests.sync-reopen."+UUID().uuidString;preferenceSuites.append(suite)
        let recovery=PersonalSyncErasureRecovery(pending:{await PersonalSyncRetirementRecovery.hasPending(root:$0,environment:environment)},retry:{location,progress in try await PersonalSyncRetirementRecovery.retry(root:location,environment:environment,progress:{value in recoveryGate?.pause();progress(value)})})
        let session=AppSession(selection:.init(url:location,requiresExisting:true,origin:"owned-sync-reopen"),defaults:UserDefaults(suiteName:suite)!,locked:{false},openStore:{try MemoryStore(root:$0,recoveryReadOnly:false,nativeWriterEnvironment:environment)},personalSyncSetup:{store in PersonalSyncModel(store:store,locked:{false},pairingFactory:{try PersonalSyncPairing(store:$0,stateRoot:state,machine:PairingAppMachine(),storage:backend)})},syncRecovery:recovery)
        sessions.append(session)
        try await rootSettled(session) {!session.busy && session.model != nil}
        session.model!.showOnboarding=false
        try await settledConnectionWork(session.model!.personalSync)
        return session
    }
    private func rootSettled(_ session:AppSession,caller:UInt=#line,diagnostics:()->String={""},_ condition:()->Bool)async throws {
        let started=ContinuousClock.now,deadline=started.advanced(by:.seconds(30))
        while !condition(),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        guard condition() else {
            let state="caller=\(caller) busy=\(session.busy) modelPresent=\(session.model != nil) erasurePending=\(session.syncErasurePending) membershipPending=\(session.syncMembershipPending) membershipClosePending=\(session.hasPendingMembershipClose) phase=\(session.progress?.phase ?? "none")"
            throw OSwindError.unavailable("Owned root transition did not finish: "+state+" "+diagnostics()+" "+(session.failure ?? session.message))
        }
        print("OWNED_ROOT_TRANSITION_READY caller=\(caller) budgetSeconds=30 elapsed=\(started.duration(to:ContinuousClock.now))")
    }
    func testEnrolledAppWipeReplacesClosedOwnerWithQuietFreshWorkspace()async throws {
        let session=try await rootSession(),old=try XCTUnwrap(session.model),shared=root.appendingPathComponent("shared")
        try old.store.insert(Memory(id:"root-erase",text:"Owned source before root erasure"))
        old.personalSync.connectFolder(shared,create:true);try await connected(old.personalSync)
        old.personalSync.setReconnectOnLaunch(true);try await settledConnectionWork(old.personalSync)
        let accounts=Set(storage.values.keys)
        old.wipeLocalLibrary()
        try await rootSettled(session) {!session.busy && session.model != nil && session.model !== old}
        let fresh=try XCTUnwrap(session.model)
        XCTAssertTrue(old.store.isClosed);XCTAssertFalse(old.personalSync.busy);XCTAssertFalse(old.libraryWipe.busy)
        XCTAssertEqual(try fresh.store.stats(includeDiskUsage:false).count,0);XCTAssertFalse(fresh.isCollecting)
        XCTAssertFalse(fresh.settings.captureOnLaunch);XCTAssertFalse(fresh.settings.apiEnabled);XCTAssertFalse(fresh.settings.routinesEnabled)
        XCTAssertFalse(fresh.personalSync.configured);XCTAssertFalse(fresh.personalSync.preparing)
        XCTAssertEqual(Set(storage.values.keys),accounts);XCTAssertFalse(session.syncErasurePending)
        fresh.showOnboarding=false;fresh.personalSync.reconnectSavedFolder();try await connected(fresh.personalSync,phase:.needsLocalEraseReview)
    }
    func testEnrolledAppWipeShowsRestrictedRecoveryUntilHeldWALReaderReleases()async throws {
        let session=try await rootSession(),old=try XCTUnwrap(session.model),shared=root.appendingPathComponent("shared")
        try old.store.insert(Memory(id:"root-pending",text:"Owned source held by another reader"))
        old.personalSync.connectFolder(shared,create:true);try await connected(old.personalSync)
        let reader=try PairingAppWALReader(root:old.store.root);defer {reader.close()}
        old.wipeLocalLibrary()
        try await rootSettled(session) {!session.busy && session.model==nil && session.syncErasurePending}
        XCTAssertTrue(old.store.isClosed);XCTAssertEqual(old.libraryWipe.result?.erasure.sources,1)
        XCTAssertEqual(old.libraryWipe.result?.cleanupComplete,false);XCTAssertTrue(session.canRecoverContent)
        if let path=ProcessInfo.processInfo.environment["OSWIND_TEST_PAIRING_RENDER_DIR"] {
            let directory=URL(fileURLWithPath:path);try Paths.ensure(directory)
            for dark in [false,true] {try await renderView(LibraryRecoveryView(session:session,locationLabel:"Owned test library"),name:"recovery-pending",dark:dark,width:900,height:800,directory:directory,expected:"resume erasure cleanup")}
        }
        reader.close();session.resumeSyncErasure()
        try await rootSettled(session) {!session.busy && session.model != nil}
        let fresh=try XCTUnwrap(session.model)
        XCTAssertFalse(session.syncErasurePending);XCTAssertEqual(try fresh.store.stats(includeDiskUsage:false).count,0)
        XCTAssertFalse(fresh.isCollecting);XCTAssertFalse(fresh.settings.captureOnLaunch)
    }
    func testTerminationJoinsActualRestrictedRecoveryAfterCancellation()async throws {
        let gate=PairingSaveGate();defer {gate.release()}
        let session=try await rootSession(recoveryGate:gate),old=try XCTUnwrap(session.model)
        try old.store.insert(Memory(id:"cancel-recovery",text:"Owned source before pending erasure"))
        old.personalSync.connectFolder(root.appendingPathComponent("shared"),create:true);try await connected(old.personalSync)
        let reader=try PairingAppWALReader(root:old.store.root);defer {reader.close()}
        old.wipeLocalLibrary()
        XCTAssertTrue(old.libraryWipe.busy,"Owned wipe was refused before recovery: "+(old.errorMessage ?? "no app error"))
        try await rootSettled(session,diagnostics:{"oldClosed=\(old.store.isClosed) wipeBusy=\(old.libraryWipe.busy) wipePending=\(old.libraryWipe.pendingCleanup) wipeStatus=\(old.libraryWipe.status) appError=\(old.errorMessage ?? "none")"}) {!session.busy && session.syncErasurePending && session.model==nil}
        reader.close();session.resumeSyncErasure();await fulfillment(of:[gate.entered],timeout:10)
        if let path=ProcessInfo.processInfo.environment["OSWIND_TEST_PAIRING_RENDER_DIR"] {
            let directory=URL(fileURLWithPath:path);try Paths.ensure(directory)
            for dark in [false,true] {try await renderView(LibraryRecoveryView(session:session,locationLabel:"Owned test library"),name:"recovery-working",dark:dark,width:900,height:800,directory:directory,expected:"stop")}
        }
        var joined=false
        let termination=Task {let value=await session.lockForTermination();joined=true;return value};termination.cancel()
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertTrue(session.busy);XCTAssertFalse(joined);XCTAssertNil(session.model)
        gate.release();let closed=await termination.value
        XCTAssertTrue(closed);XCTAssertTrue(joined);XCTAssertFalse(session.busy);XCTAssertNil(session.model);XCTAssertTrue(session.syncErasurePending)
        let state=root.appendingPathComponent("state"),backend=storage!
        let environment=SyncNativeWriterEnvironment(stateRoot:state,machine:PairingAppMachine(),storage:{_ in backend})
        let result=try await PersonalSyncRetirementRecovery.retry(root:old.store.root,environment:environment)
        XCTAssertTrue(result.cleanupComplete,"Canceled Root recovery must release its private SQLite and both credential leases")
    }
    func testApprovedPeerEraseAutomaticallyJoinsAppAndReopensQuietlyWithoutLocalApproval()async throws {
        let first=try await rootSession(),oldA=try XCTUnwrap(first.model),shared=root.appendingPathComponent("shared")
        let peerLocation=b.root;try b.close();let second=try await openRootSession(peerLocation),oldB=try XCTUnwrap(second.model)
        try oldA.store.insert(Memory(id:"peer-root-a",text:"Owned sender root before erase"));try oldB.store.insert(Memory(id:"peer-root-b",text:"Owned receiver root before erase"))
        oldA.personalSync.connectFolder(shared,create:true);try await connected(oldA.personalSync)
        oldB.personalSync.connectFolder(shared);try await connected(oldB.personalSync)
        oldA.personalSync.setNetworkEnabled(false);try await connected(oldA.personalSync,phase:.networkPaused)
        oldA.personalSync.setNetworkEnabled(true);try await connected(oldA.personalSync)
        XCTAssertEqual(try oldA.store.stats(includeDiskUsage:false).count,2);XCTAssertEqual(try oldB.store.stats(includeDiskUsage:false).count,2)
        oldA.wipeLocalLibrary();try await rootSettled(first) {!first.busy && first.model != nil && first.model !== oldA}
        let freshA=try XCTUnwrap(first.model);freshA.showOnboarding=false
        freshA.personalSync.reconnectSavedFolder();try await connected(freshA.personalSync,phase:.needsLocalEraseReview)
        freshA.personalSync.requestEraseReview()
        try await rootSettled(first) {freshA.personalSync.eraseReview != nil && !freshA.personalSync.changing}
        freshA.personalSync.approveErase(try XCTUnwrap(freshA.personalSync.eraseReview));try await connected(freshA.personalSync)
        if second.model === oldB {
            oldB.personalSync.suspend()
            try await rootSettled(second) {second.model !== oldB || oldB.libraryWipe.busy || oldB.personalSync.status?.phase == .suspended}
            if second.model === oldB,!oldB.libraryWipe.busy {oldB.personalSync.wake()}
        }
        try await rootSettled(second) {!second.busy && second.model != nil && second.model !== oldB}
        let freshB=try XCTUnwrap(second.model)
        XCTAssertTrue(oldB.store.isClosed);XCTAssertEqual(try freshB.store.stats(includeDiskUsage:false).count,0)
        XCTAssertFalse(freshB.isCollecting);XCTAssertFalse(freshB.settings.captureOnLaunch)
        XCTAssertEqual(try freshB.store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM personal_sync_collection_approvals")},0)
        freshB.showOnboarding=false;freshB.personalSync.reconnectSavedFolder();try await connected(freshB.personalSync)
    }
    func testActualModelCreateReviewApproveAndJoinKeepsKeysOutOfUIAndDeliveryOff()async throws {
        let owner=model(a),joiner=model(b)
        owner.performPairing(.load);joiner.performPairing(.load);try await done(owner);try await done(joiner)
        XCTAssertEqual(owner.pairingStatus?.phase,.unconfigured)
        owner.performPairing(.create("Desk Mac"));joiner.performPairing(.request("Travel Mac"));try await done(owner);try await done(joiner)
        let request=try XCTUnwrap(joiner.pairingStatus?.request)
        owner.performPairing(.review(request));try await done(owner)
        let review=try XCTUnwrap(owner.pairingReview);XCTAssertEqual(review.deviceName,"Travel Mac")
        owner.performPairing(.approve(review));try await done(owner)
        let response=try XCTUnwrap(owner.pairingResponse),fingerprint=try XCTUnwrap(owner.pairingStatus?.rootFingerprint)
        joiner.performPairing(.accept(response,fingerprint));try await done(joiner)
        XCTAssertNil(owner.pairingError);XCTAssertNil(joiner.pairingError);XCTAssertEqual(joiner.pairingStatus?.phase,.paired)
        XCTAssertFalse(owner.configured);XCTAssertFalse(joiner.configured);XCTAssertTrue(owner.busy);XCTAssertTrue(joiner.busy)
        owner.clearPairingMessages();XCTAssertNil(owner.pairingResponse);XCTAssertNil(owner.pairingReview)
        XCTAssertFalse(String(reflecting:joiner.pairingStatus).contains("signingPrivate"))
    }
    func testCancelledLibraryDrainJoinsRealPairingFactoryBeforeStoreMayClose()async throws {
        let gate=ImportWorkerGate(),owner=model(a,gate:gate)
        owner.performPairing(.load);trace("factory-requested")
        await fulfillment(of:[gate.entered],timeout:10);trace("factory-entered")
        XCTAssertTrue(owner.busy);XCTAssertTrue(owner.pairingBusy)
        var drained=false
        let drain=Task {await owner.cancelAndWait();drained=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(40));trace("factory-held-after-sleep");XCTAssertFalse(drained);XCTAssertFalse(a.isClosed)
        gate.release();trace("factory-released");await drain.value;trace("factory-drain-joined")
        XCTAssertFalse(owner.busy);XCTAssertFalse(owner.pairingBusy);XCTAssertNil(owner.pairingStatus)
        XCTAssertTrue(storage.values.isEmpty)
        try a.close();trace("factory-store-closed");XCTAssertTrue(a.isClosed)
    }
    func testCancelledDrainWaitsForLateCredentialCommitAndResumesItWithoutRecreatingKeys()async throws {
        let gate=PairingSaveGate();defer {gate.release()};storage.install(gate)
        let owner=model(a);owner.performPairing(.create("Durable desk Mac"))
        await fulfillment(of:[gate.entered],timeout:10)
        // This barrier is inside credential creation, after the actual native
        // handle/lifetime reservation committed. The backend ignores cancellation.
        let handles=try a.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-pairing-handle-v1'")}
        XCTAssertEqual(handles,1)
        var drained=false
        let drain=Task {await owner.cancelAndWait();drained=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(40));XCTAssertFalse(drained);XCTAssertFalse(a.isClosed)
        gate.release();await drain.value
        XCTAssertFalse(owner.busy);XCTAssertNil(owner.pairingStatus);XCTAssertEqual(storage.values.count,1)
        let saved=storage.values
        storage.install(nil);owner.prepareForReconnection();owner.performPairing(.load);try await done(owner)
        XCTAssertEqual(owner.pairingStatus?.phase,.owner);XCTAssertEqual(owner.pairingStatus?.deviceName,"Durable desk Mac")
        XCTAssertEqual(storage.values,saved,"Reload must use the committed keys after cancellation")
    }
    func testCancelledPairingCanReloadDurableStateAndRetirementClosesAdmission()async throws {
        let owner=model(a)
        owner.performPairing(.create("Desk Mac"));try await done(owner)
        await owner.cancelAndWait();XCTAssertFalse(owner.busy)
        owner.performPairing(.request("Cannot run"));XCTAssertFalse(owner.pairingBusy)
        owner.prepareForReconnection();owner.performPairing(.load);try await done(owner)
        XCTAssertEqual(owner.pairingStatus?.phase,.owner)
        owner.performPairing(.retire);try await done(owner);XCTAssertEqual(owner.pairingStatus?.phase,.retired)
        XCTAssertNil(owner.pairingError)
    }
    func testPairingErrorsAreSanitizedAndReloadCanRecoverOriginalState()async throws {
        let owner=model(a);owner.performPairing(.create("Desk Mac"));try await done(owner)
        owner.performPairing(.review("PAIRING-SECRET-DO-NOT-DISPLAY"));try await done(owner)
        XCTAssertNotNil(owner.pairingError);XCTAssertFalse(owner.pairingError!.contains("PAIRING-SECRET"));XCTAssertNil(owner.pairingStatus)
        owner.performPairing(.load);try await done(owner);XCTAssertEqual(owner.pairingStatus?.phase,.owner);XCTAssertNil(owner.pairingError)
    }
    func testForeignPairingFactoryCannotMutateAnotherLibrary()async throws {
        let foreign=b!,state=root.appendingPathComponent("state"),backend=storage!
        let owner=PersonalSyncModel(store:a,locked:{false},pairingFactory:{_ in try PersonalSyncPairing(store:foreign,stateRoot:state,machine:PairingAppMachine(),storage:backend)})
        models.append(owner);owner.performPairing(.create("Foreign Mac"));try await done(owner)
        XCTAssertNotNil(owner.pairingError);XCTAssertNil(owner.pairingStatus);XCTAssertFalse(owner.busy);XCTAssertTrue(storage.values.isEmpty)
        XCTAssertEqual(try foreign.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-pairing-handle-v1'")},0)
    }
    func testDeniedOrClosedLibraryDoesNotCreateCredentials()async throws {
        let owner=model(a);owner.allowed={false};owner.performPairing(.create("Denied Mac"))
        XCTAssertFalse(owner.pairingBusy);XCTAssertTrue(storage.values.isEmpty)
        owner.allowed={true};try a.close();owner.performPairing(.create("Closed Mac"));XCTAssertFalse(owner.pairingBusy);XCTAssertTrue(storage.values.isEmpty)
    }
    func testOwnedPairingScreensRenderInBothThemes()async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_PAIRING_RENDER_DIR"] else {throw XCTSkip("Explicit owned pairing render output absent")}
        let directory=URL(fileURLWithPath:path);try Paths.ensure(directory)
        _=NSApplication.shared
        let owner=model(a),joiner=model(b)
        owner.performPairing(.load);try await done(owner)
        try await render(owner,name:"unconfigured",directory:directory)
        owner.performPairing(.create("Desk Mac"));joiner.performPairing(.request("Travel Mac"));try await done(owner);try await done(joiner)
        try await render(owner,name:"owner",directory:directory);try await render(joiner,name:"pending",directory:directory);try await render(joiner,name:"pending-response",directory:directory)
        owner.performPairing(.review(try XCTUnwrap(joiner.pairingStatus?.request)));try await done(owner)
        try await render(owner,name:"review",directory:directory)
        owner.performPairing(.approve(try XCTUnwrap(owner.pairingReview)));try await done(owner)
        try await render(owner,name:"response",directory:directory)
        joiner.performPairing(.accept(try XCTUnwrap(owner.pairingResponse),try XCTUnwrap(owner.pairingStatus?.rootFingerprint)));try await done(joiner)
        try await render(joiner,name:"paired",directory:directory)
        owner.clearPairingMessages();try await render(owner,name:"folder",directory:directory)
        let shared=root.appendingPathComponent("render-shared")
        owner.connectFolder(shared,create:true);try await connected(owner)
        try await render(owner,name:"connected",directory:directory)
        await owner.cancelAndWait();owner.prepareForReconnection();owner.performPairing(.load);try await done(owner)
        XCTAssertEqual(owner.pairingStatus?.deliveryPrepared,true)
        try await render(owner,name:"reconnect",directory:directory)
        _=try await owner.eraseHistory(before:{})
        owner.prepareForReconnection();owner.reconnectSavedFolder();try await connected(owner,phase:.needsLocalEraseReview)
        try await render(owner,name:"erase-waiting",directory:directory)
        owner.requestEraseReview()
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while owner.eraseReview==nil,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        let review=try XCTUnwrap(owner.eraseReview)
        for dark in [false,true] {
            try await renderView(PersonalSyncEraseReviewView(model:owner,reviewed:review),name:"erase-review",dark:dark,width:560,height:500,directory:directory,expected:"approve group erase")
        }
        owner.clearEraseReview()
        joiner.performPairing(.retire);try await done(joiner);try await render(joiner,name:"retired",directory:directory)
        await owner.cancelAndWait();owner.prepareForReconnection()
        owner.performPairing(.review("Owned invalid request"));try await done(owner);try await render(owner,name:"failure",directory:directory)
    }
    private func render(_ model:PersonalSyncModel,name:String,directory:URL)async throws {
        for dark in [false,true] {
            let expected=["unconfigured":"create a group","owner":"add a mac","pending":"waiting for the group owner","pending-response":"verify and save this mac","review":"approve this exact request","response":"return this encrypted response","paired":"device paired","retired":"local pairing retired","failure":"pairing could not finish","folder":"connect a shared folder","connected":"up to date","reconnect":"reconnect saved folder","erase-waiting":"review group erase"][name]!
            try await renderView(PersonalSyncPairingView(model:model,receivingResponse:name=="pending-response"),name:name,dark:dark,width:660,height:650,directory:directory,expected:expected)
        }
    }
    private func renderView<Content:View>(_ view:Content,name:String,dark:Bool,width:CGFloat,height:CGFloat,directory:URL,expected:String)async throws {
        _=NSApplication.shared
        let background=dark ? NSColor(calibratedWhite:0.12,alpha:1):NSColor.white
        let host=NSHostingView(rootView:view.environment(\.colorScheme,dark ? .dark:.light).background(Color(nsColor:background)))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);window.contentView=host
        defer {window.contentView=nil;window.close()}
        host.layoutSubtreeIfNeeded();window.displayIfNeeded();try await Task.sleep(for:.milliseconds(150));host.layoutSubtreeIfNeeded();window.displayIfNeeded()
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
        let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]));try png.write(to:directory.appendingPathComponent("\(name)-\(dark ? "dark":"light").png"))
        let recognition=VNRecognizeTextRequest();recognition.recognitionLevel = .accurate;recognition.recognitionLanguages=["en-US"]
        try VNImageRequestHandler(data:png,options:[:]).perform([recognition])
        let text=(recognition.results ?? []).compactMap {$0.topCandidates(1).first?.string}.joined(separator:" ").lowercased()
        try text.write(to:directory.appendingPathComponent("\(name)-\(dark ? "dark":"light").ocr.txt"),atomically:true,encoding:.utf8)
        XCTAssertTrue(text.contains(expected),"Owned \(name) render omitted expected screen content: \(text)")
    }

}
private struct PairingAppMachine:SyncMachineFingerprint {func fingerprint()throws->String {String(repeating:"a",count:64)}}
private final class PairingAppStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let lock=NSLock();private var saved=[String:Data](),createGate:PairingSaveGate?,readGate:PairingSaveGate?
    func install(_ value:PairingSaveGate?) {lock.lock();createGate=value;lock.unlock()}
    func installRead(_ value:PairingSaveGate?) {lock.lock();readGate=value;lock.unlock()}
    var values:[String:Data] {lock.lock();defer {lock.unlock()};return saved}
    func create(id:String,bytes:Data)throws {lock.lock();let gate=createGate;lock.unlock();gate?.pause()
        lock.lock();defer {lock.unlock()};guard saved[id]==nil else {throw SyncCredentialStorageError.alreadyExists};saved[id]=bytes}
    func read(id:String)throws->Data {lock.lock();let gate=readGate;lock.unlock();gate?.pause();lock.lock();defer {lock.unlock()};guard let bytes=saved[id] else {throw SyncCredentialStorageError.missing};return bytes}
    func replace(id:String,expected:Data,bytes:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved[id]=bytes}
    func remove(id:String,expected:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved.removeValue(forKey:id)}
}

private final class PairingSaveGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"Actual pairing credential save entered")
    private let condition=NSCondition();private var released=false,arrived=false
    func pause() {condition.lock();defer {condition.unlock()};guard !arrived else {return};arrived=true;entered.fulfill();while !released {condition.wait()}}
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
}

@MainActor private final class PairingAppDrainGate {
    let entered=XCTestExpectation(description:"App producer drain entered")
    private var continuation:CheckedContinuation<Void,Never>?
    func wait()async {await withCheckedContinuation {continuation=$0;entered.fulfill()}}
    func release() {continuation?.resume();continuation=nil}
}

private final class PairingAppWALReader {
    private var database:OpaquePointer?
    init(root:URL)throws {
        guard sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&database,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {throw OSwindError.unavailable("Owned WAL reader could not open")}
        guard sqlite3_exec(database,"BEGIN; SELECT COUNT(*) FROM memories;",nil,nil,nil)==SQLITE_OK else {close();throw OSwindError.unavailable("Owned WAL reader could not retain its snapshot")}
    }
    func close() {if let database {sqlite3_exec(database,"ROLLBACK",nil,nil,nil);sqlite3_close(database);self.database=nil}}
    deinit {close()}
}
