import XCTest
import CSQLite
import AppKit
import SwiftUI
import Combine
@testable import OSwindCore
@testable import OSwind

private struct AppOwnerMachine:SyncMachineFingerprint {func fingerprint()throws->String {String(repeating:"d",count:64)}}
private final class AppOwnerStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let lock=NSLock()
    private var saved=[String:Data]()
    private var shouldFailAfterIntent=false
    var failAfterIntent:Bool {get {lock.lock();defer {lock.unlock()};return shouldFailAfterIntent} set {lock.lock();shouldFailAfterIntent=newValue;lock.unlock()}}
    var values:[String:Data] {lock.lock();defer {lock.unlock()};return saved}
    func create(id:String,bytes:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==nil else {throw SyncCredentialStorageError.alreadyExists};saved[id]=bytes}
    func read(id:String)throws->Data {lock.lock();defer {lock.unlock()};guard let data=saved[id] else {throw SyncCredentialStorageError.missing};return data}
    func replace(id:String,expected:Data,bytes:Data)throws {
        lock.lock();defer {lock.unlock()};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved[id]=bytes
        if shouldFailAfterIntent,let value=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],value["membershipPreparation"] != nil {throw SyncCredentialStorageError.unavailable(-1)}
    }
    func remove(id:String,expected:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved[id]=nil}
}
private final class OwnerOpenTracker:@unchecked Sendable {
    private let condition=NSCondition(),environment:SyncNativeWriterEnvironment
    private var opened=[MemoryStore](),heldOrdinal:Int?,released=false
    private var beforeOpen:(@Sendable (URL)throws->Void)?
    let entered=XCTestExpectation(description:"Late fresh workspace opened")
    init(_ environment:SyncNativeWriterEnvironment) {self.environment=environment}
    var count:Int {condition.lock();defer {condition.unlock()};return opened.count}
    var stores:[MemoryStore] {condition.lock();defer {condition.unlock()};return opened}
    func holdNext() {condition.lock();heldOrdinal=opened.count+1;released=false;condition.unlock()}
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
    func beforeNextOpen(_ work:@escaping @Sendable (URL)throws->Void) {condition.lock();beforeOpen=work;condition.unlock()}
    func open(_ path:URL)throws->MemoryStore {
        condition.lock();let work=beforeOpen;beforeOpen=nil;condition.unlock();try work?(path)
        let store=try MemoryStore(root:path,recoveryReadOnly:false,nativeWriterEnvironment:environment)
        condition.lock();defer {condition.unlock()};opened.append(store)
        if heldOrdinal==opened.count {
            entered.fulfill();let deadline=Date().addingTimeInterval(15)
            while !released,Date()<deadline {_=condition.wait(until:Date().addingTimeInterval(0.01))}
        }
        return store // Deliberately ignores cancellation to exercise late success.
    }
}
private final class AppOwnerNativeStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let backend=SyncKeychainCredentialStorage(protection:.loginKeychain),lock=NSLock()
    private var ids=Set<String>()
    private var shouldFailAfterIntent=false
    var failAfterIntent:Bool {get {lock.lock();defer {lock.unlock()};return shouldFailAfterIntent} set {lock.lock();shouldFailAfterIntent=newValue;lock.unlock()}}
    private func owned(_ id:String)throws {lock.lock();defer {lock.unlock()};guard ids.contains(id) else {throw OSwindError.invalid("Unowned app fixture credential")}}
    func create(id:String,bytes:Data)throws {try backend.create(id:id,bytes:bytes);lock.lock();ids.insert(id);lock.unlock()}
    func read(id:String)throws->Data {try owned(id);return try backend.read(id:id)}
    func replace(id:String,expected:Data,bytes:Data)throws {
        try owned(id);try backend.replace(id:id,expected:expected,bytes:bytes)
        if failAfterIntent,let value=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],value["membershipPreparation"] != nil {throw SyncCredentialStorageError.unavailable(-1)}
    }
    func remove(id:String,expected:Data)throws {try owned(id);try backend.remove(id:id,expected:expected)}
    func cleanup()throws {
        lock.lock();let accounts=ids;lock.unlock()
        for id in accounts {
            try backend.remove(id:id,expected:backend.read(id:id))
            do {_=try backend.read(id:id);throw OSwindError.invalid("Owned app fixture credential survived cleanup")}
            catch SyncCredentialStorageError.missing {}
        }
        lock.lock();ids.removeAll();lock.unlock()
    }
}
@MainActor private final class OwnerLockFlag {var locked=false}

@MainActor final class OwnerAdditionAppSessionTests:XCTestCase {
    private var root:URL!,defaults:UserDefaults!,suite:String!
    private var stores=[MemoryStore](),pairings=[PersonalSyncPairing](),coreSessions=[PersonalSyncSession](),apps=[AppSession](),trackers=[OwnerOpenTracker]()
    private var vaults=[LibraryVault]()
    private let storage=AppOwnerStorage()
    private var nativeStorage:AppOwnerNativeStorage?
    private let locks=OwnerLockFlag()
    private var environment:SyncNativeWriterEnvironment {
        if let nativeStorage {let native=SyncNativeWriterEnvironment.native;return .init(stateRoot:native.stateRoot,machine:native.machine,storage:{_ in nativeStorage})}
        return .init(stateRoot:root.appendingPathComponent("state"),machine:AppOwnerMachine(),storage:{[storage] _ in storage})
    }
    private struct Fixture {
        let app:AppSession,old:AppModel,peer:PersonalSyncPairing,request:String,fingerprint:String,provider:URL,pairingID:String,deliveryID:String,tracker:OwnerOpenTracker,passphrase:String?
    }
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-app-owner-addition-"+UUID().uuidString);try Paths.ensure(root)
        suite="org.oswind.tests.owner-addition."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
    }
    override func tearDown()async throws {
        storage.failAfterIntent=false;nativeStorage?.failAfterIntent=false;locks.locked=false;trackers.forEach {$0.release()}
        for app in apps {
            if app.busy {app.cancelOperation();try await settle(app)}
            if app.hasPendingMembershipClose {app.retryMembershipClose();try await settle(app)}
            if let model=app.model {model.prepareForLibrarySwitch();await model.cancelExternalWorkAndWait();try model.store.close();app.model=nil}
        }
        for session in coreSessions {try await session.stop()}
        pairings.forEach {$0.close()};try stores.forEach {try $0.close()};try trackers.flatMap(\.stores).forEach {try $0.close()}
        for vault in vaults {
            let status=try await vault.lock()
            guard status.state == .locked,!status.imageAttached else {throw OSwindError.unavailable("Owned encrypted fixture remains attached; directory preserved")}
        }
        try nativeStorage?.cleanup()
        defaults.removePersistentDomain(forName:suite);try FileManager.default.removeItem(at:root)
    }
    private func store(_ path:URL)throws->MemoryStore {let value=try MemoryStore(root:path,recoveryReadOnly:false,nativeWriterEnvironment:environment);stores.append(value);return value}
    private func pair(_ library:MemoryStore)throws->PersonalSyncPairing {let env=environment,value=try PersonalSyncPairing(store:library,stateRoot:env.stateRoot,machine:env.machine,storage:env.storage(.loginKeychain));pairings.append(value);return value}
    private func settle(_ app:AppSession)async throws {
        let end=SuspendingClock.now.advanced(by:.seconds(25))
        while app.busy,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(app.busy,"Owned app operation did not finish")
    }
    private func review(_ f:Fixture)async throws->PersonalSyncOwnerReview {
        f.old.personalSync.reviewOwnerRequest(f.request)
        let end=SuspendingClock.now.advanced(by:.seconds(10))
        while f.old.personalSync.ownerReviewBusy,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertNil(f.old.personalSync.ownerReviewError)
        return try XCTUnwrap(f.old.personalSync.ownerAdditionReview)
    }
    private func fixture(expirySeconds:Int?=nil,preferences:PersonalSyncPreferences = .init(reconnectOnLaunch:false,networkEnabled:false),nativeVault:Bool=false,previewEnabled:Bool=true)async throws->Fixture {
        var libraryRoot=root.appendingPathComponent("owner"),passphrase:String?
        if nativeVault {
            guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1",ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned encrypted APFS and generated login-Keychain fixture")}
            nativeStorage=AppOwnerNativeStorage()
            let package=root.appendingPathComponent("Owned.oswindvault"),secret=UUID().uuidString
            _=try await LibraryVault.create(at:package,name:"Owned device addition",capacityGiB:1,passphrase:Data(secret.utf8))
            let vault=try LibraryVault(package:package);vaults.append(vault)
            _=try await vault.unlock(passphrase:Data(secret.utf8));libraryRoot=vault.libraryURL;passphrase=secret
        }
        let library=try store(libraryRoot),owner=try pair(library),first=try pair(store(root.appendingPathComponent("first")))
        let now=Date();_=try owner.createGroup(deviceName:"Owned app desk",now:now)
        let fingerprint=try XCTUnwrap(owner.status().rootFingerprint),initial=try XCTUnwrap(first.requestJoin(deviceName:"Owned first Mac",now:now).request)
        let response=try owner.approve(owner.reviewRequest(initial,now:now),now:now)
        _=try first.acceptResponse(response,trustedRootFingerprint:fingerprint,now:now);first.close()
        let provider=root.appendingPathComponent("provider"),native=try owner.prepareSession(sharedFolder:provider,createSharedFolder:true);coreSessions.append(native)
        try library.insert(Memory(id:"keep",text:"Owned source before adding a Mac"));try library.savePersonalSyncPreferences(preferences)
        try await native.stop();try library.close()
        var settings=AppSettings();settings.captureOnLaunch=false;settings.apiEnabled=false;settings.automaticMaintenance=false;settings.routinesEnabled=false;settings.entityAutomaticIndex=false;settings.clipboard.enabled=false;settings.meetings.enabled=false
        try settings.save(root:library.root)
        let environment=environment,locks=locks,tracker=OwnerOpenTracker(environment);trackers.append(tracker)
        let app=AppSession(selection:.init(url:library.root,requiresExisting:true,origin:"owned"),defaults:defaults,locked:{[locks] in locks.locked},openStore:{try tracker.open($0)},personalSyncSetup:{store in
            PersonalSyncModel(store:store,locked:{[locks] in locks.locked},pairingFactory:{try PersonalSyncPairing(store:$0,stateRoot:environment.stateRoot,machine:environment.machine,storage:environment.storage(.loginKeychain))})
        },syncRecovery:.init(pending:{_ in false},retry:{_,_ in throw OSwindError.invalid("Not an erasure fixture")}),membershipRecovery:{PersonalSyncOwnerChange.recover(root:$0,environment:environment)},ownerAdditionPreview:previewEnabled)
        apps.append(app);try await settle(app);XCTAssertNil(app.failure)
        let old=try XCTUnwrap(app.model);old.showOnboarding=false;try await SourceWorkTestJob.settle(old)
        // Completing onboarding can start the passive saved-preference read.
        // Join that actual startup job before this explicit manual reconnect.
        let startupEnd=SuspendingClock.now.advanced(by:.seconds(15))
        while old.personalSync.preparing || old.personalSync.changing,SuspendingClock.now<startupEnd {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(old.personalSync.preparing);XCTAssertFalse(old.personalSync.changing)
        old.personalSync.reconnectSavedFolder()
        let end=SuspendingClock.now.advanced(by:.seconds(10))
        while old.personalSync.preparing || old.personalSync.changing || !old.personalSync.configured,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        guard old.personalSync.configured else {throw OSwindError.unavailable("Owned explicit connection did not finish: preparing=\(old.personalSync.preparing) changing=\(old.personalSync.changing) errorPresent=\(old.personalSync.error != nil)")}
        XCTAssertTrue(old.personalSync.isGroupOwner);XCTAssertEqual(old.personalSync.networkPaused,!preferences.networkEnabled)
        let ids=try old.store.withRoutineDatabase {db->(String,String) in
            let row=try db.statement("SELECT id,(SELECT value FROM store_metadata WHERE key='sync-pairing-handle-v1') FROM personal_sync_delivery_anchor");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Original owned accounts missing")}
            let handle=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(db.text(row,1).utf8)) as? [String:Any]);return(try XCTUnwrap(handle["id"] as? String),db.text(row,0))
        }
        let peer=try pair(store(root.appendingPathComponent("new"))),created=expirySeconds.map {Date().addingTimeInterval(TimeInterval($0-600))} ?? Date()
        let request=try XCTUnwrap(peer.requestJoin(deviceName:"Owned new Mac",now:created).request)
        return .init(app:app,old:old,peer:peer,request:request,fingerprint:fingerprint,provider:provider,pairingID:ids.0,deliveryID:ids.1,tracker:tracker,passphrase:passphrase)
    }
    private func assertQuiet(_ model:AppModel,preferences:PersonalSyncPreferences = .init(reconnectOnLaunch:false,networkEnabled:false),file:StaticString=#filePath,line:UInt=#line)throws {
        XCTAssertFalse(model.isCapturing,file:file,line:line);XCTAssertEqual(model.apiStatus,"API off",file:file,line:line)
        XCTAssertFalse(model.personalSync.configured,file:file,line:line)
        XCTAssertEqual(try model.store.personalSyncPreferences(),preferences,file:file,line:line)
        XCTAssertNotNil(try model.store.get("keep"),file:file,line:line)
    }
    func testApproveThirdMacClosesOriginalAndReopensFreshQuietWorkspace()async throws {
        let f=try await fixture(),review=try await review(f),accounts=Set(storage.values.keys)
        f.app.approveSyncDevice(review,from:f.old);XCTAssertNil(f.app.model);XCTAssertTrue(f.app.busy)
        try await settle(f.app);XCTAssertNil(f.app.failure);let fresh=try XCTUnwrap(f.app.model),presentation=try XCTUnwrap(f.app.syncApprovalPresentation)
        XCTAssertTrue(f.old.store.isClosed);XCTAssertFalse(fresh === f.old);try assertQuiet(fresh)
        XCTAssertEqual(presentation.response.requestFingerprint,review.requestFingerprint);XCTAssertEqual(presentation.rootFingerprint,f.fingerprint)
        _=try f.peer.acceptResponse(presentation.response.response,trustedRootFingerprint:f.fingerprint)
        XCTAssertEqual(Set(storage.values.keys),accounts);XCTAssertFalse(f.app.hasPendingMembershipClose)
    }
    private func heldProducer(_ job:SourceWorkTestJob)async throws {
        let f=try await fixture(),review=try await review(f),before=try storage.read(id:f.pairingID),gate=ImportWorkerGate();defer {gate.release()}
        try job.start(f.old,gate:gate);await fulfillment(of:[gate.entered],timeout:5)
        f.app.approveSyncDevice(review,from:f.old);await fulfillment(of:[gate.cancelled],timeout:5)
        XCTAssertTrue(f.app.busy);XCTAssertNil(f.app.model);XCTAssertFalse(f.old.store.isClosed);XCTAssertEqual(f.tracker.count,1)
        XCTAssertTrue(try storage.read(id:f.pairingID)==before)
        gate.release();try await settle(f.app);XCTAssertNil(f.app.failure);try assertQuiet(XCTUnwrap(f.app.model))
    }
    func testActualHeldNoteWorkerDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.note)}
    func testActualHeldRecapWorkerDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.recap)}
    func testActualHeldStatisticsWorkerDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.statistics)}
    func testActualHeldStorageWorkerDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.storage)}
    func testActualHeldAnswerWorkerDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.answer)}
    func testActualHeldAudioImportDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.audioImport)}
    func testActualHeldSelectedMetadataDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.selectedPII)}
    func testActualHeldSourceOpeningDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.sourceOpening)}
    func testActualHeldHistoricalValidationDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.historicalValidation)}
    func testActualHeldQueryDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.query)}
    func testActualHeldTextRebuildDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.textRebuild)}
    func testActualHeldFastIndexDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.fastIndex)}
    func testActualHeldAutomaticTextIndexDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.automaticText)}
    func testActualHeldVisualRebuildDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.visualRebuild)}
    func testActualHeldAutomaticVisualIndexDelaysPrivateIntentAndFreshOpening()async throws {try await heldProducer(.automaticVisual)}
    func testSavedAutomaticReconnectIntentDoesNotRestartFreshWorkspace()async throws {
        let preferences=PersonalSyncPreferences(reconnectOnLaunch:true,networkEnabled:false)
        let f=try await fixture(preferences:preferences),review=try await review(f)
        f.app.approveSyncDevice(review,from:f.old);try await settle(f.app)
        XCTAssertNil(f.app.failure);try assertQuiet(XCTUnwrap(f.app.model),preferences:preferences)
        XCTAssertNotNil(f.app.syncApprovalPresentation)
    }
    func testCancellationWhileProducerDrainsDoesNotPublishIntent()async throws {
        let f=try await fixture(),review=try await review(f),before=try storage.read(id:f.pairingID),gate=ImportWorkerGate();defer {gate.release()}
        try SourceWorkTestJob.note.start(f.old,gate:gate);await fulfillment(of:[gate.entered],timeout:5)
        f.app.approveSyncDevice(review,from:f.old);await fulfillment(of:[gate.cancelled],timeout:5)
        f.app.cancelOperation();XCTAssertTrue(f.app.busy);XCTAssertFalse(f.old.store.isClosed)
        gate.release();try await settle(f.app)
        XCTAssertTrue(try storage.read(id:f.pairingID)==before);XCTAssertTrue(f.old.store.isClosed)
        XCTAssertNil(f.app.syncApprovalPresentation);try assertQuiet(XCTUnwrap(f.app.model))
    }
    func testClearedReviewAndRetiredModelCannotStartApproval()async throws {
        let f=try await fixture(),review=try await review(f),before=try storage.read(id:f.pairingID)
        f.old.personalSync.clearOwnerReview();f.app.approveSyncDevice(review,from:f.old)
        XCTAssertFalse(f.app.busy);XCTAssertTrue(f.app.model === f.old);XCTAssertTrue(try storage.read(id:f.pairingID)==before)
        let current=try await self.review(f);f.old.prepareForLibrarySwitch();await f.old.cancelExternalWorkAndWait()
        f.app.approveSyncDevice(current,from:f.old);XCTAssertFalse(f.app.busy);XCTAssertTrue(f.app.model === f.old)
        XCTAssertTrue(try storage.read(id:f.pairingID)==before);XCTAssertFalse(f.old.store.isClosed)
    }
    func testOwnerAdditionRemainsUnavailableWithoutExplicitPreview()async throws {
        let f=try await fixture(previewEnabled:false),review=try await review(f),before=try storage.read(id:f.pairingID)
        XCTAssertNil(f.old.personalSync.approveOwnerAddition)
        f.app.approveSyncDevice(review,from:f.old);XCTAssertFalse(f.app.busy);XCTAssertTrue(f.app.model === f.old)
        XCTAssertTrue(try storage.read(id:f.pairingID)==before);XCTAssertNil(f.app.syncApprovalPresentation)
    }
    private func substitutedWorkspace(databaseOnly:Bool)async throws {
        let f=try await fixture(),review=try await review(f),replacement=root.appendingPathComponent("replacement"),saved=root.appendingPathComponent("original-saved")
        let other=try store(replacement);try other.insert(Memory(id:"other",text:"Unrelated workspace must never receive an approval"));try other.close()
        let original=f.old.store.root
        if databaseOnly {
            try Paths.ensure(saved)
            f.tracker.beforeNextOpen {path in
                let fm=FileManager.default
                for name in ["memory.sqlite","memory.sqlite-wal","memory.sqlite-shm"] where fm.fileExists(atPath:path.appendingPathComponent(name).path) {try fm.moveItem(at:path.appendingPathComponent(name),to:saved.appendingPathComponent(name))}
                try fm.copyItem(at:replacement.appendingPathComponent("memory.sqlite"),to:path.appendingPathComponent("memory.sqlite"))
            }
        }else {
            f.tracker.beforeNextOpen {path in try FileManager.default.moveItem(at:path,to:saved);try FileManager.default.moveItem(at:replacement,to:path)}
        }
        f.app.approveSyncDevice(review,from:f.old);try await settle(f.app)
        XCTAssertNotNil(f.app.failure);XCTAssertNil(f.app.model);XCTAssertNil(f.app.syncApprovalPresentation)
        XCTAssertTrue(f.old.store.isClosed);XCTAssertTrue(f.tracker.stores.allSatisfy(\.isClosed));XCTAssertFalse(f.app.hasPendingMembershipClose)
        if databaseOnly {
            for name in ["memory.sqlite","memory.sqlite-wal","memory.sqlite-shm"] where FileManager.default.fileExists(atPath:original.appendingPathComponent(name).path) {try FileManager.default.removeItem(at:original.appendingPathComponent(name))}
            for name in ["memory.sqlite","memory.sqlite-wal","memory.sqlite-shm"] where FileManager.default.fileExists(atPath:saved.appendingPathComponent(name).path) {try FileManager.default.moveItem(at:saved.appendingPathComponent(name),to:original.appendingPathComponent(name))}
        }else {try FileManager.default.moveItem(at:original,to:replacement);try FileManager.default.moveItem(at:saved,to:original)}
        f.app.retryMembershipClose();try await settle(f.app)
        XCTAssertNil(f.app.failure);let fresh=try XCTUnwrap(f.app.model);try assertQuiet(fresh)
        XCTAssertNil(try fresh.store.get("other"));XCTAssertEqual(f.app.syncApprovalPresentation?.response.requestFingerprint,review.requestFingerprint)
    }
    func testReplacedRootAfterCloseCannotReceiveWorkspaceOrResponse()async throws {try await substitutedWorkspace(databaseOnly:false)}
    func testReplacedDatabaseInSameDirectoryCannotReceiveWorkspaceOrResponse()async throws {try await substitutedWorkspace(databaseOnly:true)}
    func testActualBusyCloseRetainsOriginalLeasesAndQuitCannotBypassRetry()async throws {
        let f=try await fixture(),review=try await review(f)
        var statement:OpaquePointer?=try f.old.store.withRoutineDatabase {try $0.statement("SELECT 1")};defer {sqlite3_finalize(statement)}
        f.app.approveSyncDevice(review,from:f.old);try await settle(f.app)
        XCTAssertNotNil(f.app.failure);XCTAssertNil(f.app.model);XCTAssertFalse(f.old.store.isClosed);XCTAssertTrue(f.app.hasPendingMembershipClose);XCTAssertNil(f.app.syncApprovalPresentation);XCTAssertEqual(f.tracker.count,1)
        for id in [f.pairingID,f.deliveryID] {XCTAssertThrowsError(try SyncCredentialExclusiveLease(id:id,stateRoot:environment.stateRoot))}
        let safe=await f.app.lockForTermination();XCTAssertFalse(safe);XCTAssertFalse(f.old.store.isClosed)
        sqlite3_finalize(statement);statement=nil;f.app.retryMembershipClose();try await settle(f.app)
        XCTAssertNil(f.app.failure);XCTAssertTrue(f.old.store.isClosed);XCTAssertFalse(f.app.hasPendingMembershipClose);try assertQuiet(XCTUnwrap(f.app.model));XCTAssertNil(f.app.syncApprovalPresentation)
    }
    func testSavedIntentReopensAsDistinctRecoveryAndFinishesWithoutProvider()async throws {
        let f=try await fixture(),review=try await review(f),accounts=Set(storage.values.keys)
        storage.failAfterIntent=true;f.app.approveSyncDevice(review,from:f.old);try await settle(f.app);storage.failAfterIntent=false
        XCTAssertNil(f.app.model);XCTAssertTrue(f.app.syncMembershipPending);XCTAssertFalse(f.app.hasPendingMembershipClose);XCTAssertTrue(f.old.store.isClosed)
        try FileManager.default.removeItem(at:f.provider)
        f.app.resumeSyncMembership();try await settle(f.app)
        XCTAssertNil(f.app.failure);XCTAssertFalse(f.app.syncMembershipPending);XCTAssertNil(f.app.syncApprovalPresentation)
        let fresh=try XCTUnwrap(f.app.model);try assertQuiet(fresh);let owner=try pair(fresh.store),response=try XCTUnwrap(owner.lastApprovedResponse())
        XCTAssertEqual(response.requestFingerprint,review.requestFingerprint);_=try f.peer.acceptResponse(response.response,trustedRootFingerprint:f.fingerprint);XCTAssertEqual(Set(storage.values.keys),accounts)
    }
    func testExpiryWhileActualProducerDrainsLeavesOriginalMembershipAndQuietReopen()async throws {
        let f=try await fixture(expirySeconds:5),review=try await review(f),before=try storage.read(id:f.pairingID),gate=ImportWorkerGate();defer {gate.release()}
        try SourceWorkTestJob.note.start(f.old,gate:gate);await fulfillment(of:[gate.entered],timeout:5)
        f.app.approveSyncDevice(review,from:f.old);await fulfillment(of:[gate.cancelled],timeout:5)
        // The signed protocol timestamp is an inclusive whole second. Wait
        // past that second rather than just past its Date representation.
        while Date()<review.expires.addingTimeInterval(1) {try await Task.sleep(for:.milliseconds(50))}
        gate.release();try await settle(f.app)
        XCTAssertNotNil(f.app.failure);XCTAssertNil(f.app.syncApprovalPresentation);XCTAssertTrue(try storage.read(id:f.pairingID)==before)
        XCTAssertTrue(f.old.store.isClosed);try assertQuiet(XCTUnwrap(f.app.model))
    }
    func testLateLockClosesFreshCandidateAndNeverPresentsResponse()async throws {
        let f=try await fixture(),review=try await review(f);f.tracker.holdNext()
        f.app.approveSyncDevice(review,from:f.old);await fulfillment(of:[f.tracker.entered],timeout:10)
        locks.locked=true;f.app.cancelOperation();XCTAssertTrue(f.app.busy);f.tracker.release();try await settle(f.app)
        XCTAssertNil(f.app.model);XCTAssertNil(f.app.syncApprovalPresentation);XCTAssertTrue(f.tracker.stores.allSatisfy(\.isClosed));XCTAssertFalse(f.app.hasPendingMembershipClose)
        locks.locked=false;f.app.retry();try await settle(f.app);XCTAssertNil(f.app.failure);try assertQuiet(XCTUnwrap(f.app.model))
    }
    func testNativeEncryptedApprovalReopensQuietThenLocksAndUnlocksExactLibrary()async throws {
        let f=try await fixture(nativeVault:true),review=try await review(f)
        f.app.approveSyncDevice(review,from:f.old);try await settle(f.app)
        XCTAssertNil(f.app.failure);XCTAssertTrue(f.old.store.isClosed)
        let fresh=try XCTUnwrap(f.app.model),presentation=try XCTUnwrap(f.app.syncApprovalPresentation);try assertQuiet(fresh)
        _=try f.peer.acceptResponse(presentation.response.response,trustedRootFingerprint:f.fingerprint)
        f.app.requestLock();try await settle(f.app)
        XCTAssertNil(f.app.failure);XCTAssertNil(f.app.model);XCTAssertNil(f.app.syncApprovalPresentation)
        XCTAssertTrue(fresh.store.isClosed);XCTAssertEqual(f.app.vaultStatus?.state,.locked);XCTAssertEqual(f.app.vaultStatus?.imageAttached,false)
        f.app.unlock(passphrase:try XCTUnwrap(f.passphrase),remember:false);try await settle(f.app)
        XCTAssertNil(f.app.failure);try assertQuiet(XCTUnwrap(f.app.model));XCTAssertNil(f.app.syncApprovalPresentation)
        f.app.requestLock();try await settle(f.app);XCTAssertEqual(f.app.vaultStatus?.imageAttached,false)
    }
    func testNativeFailedOwnerClosePreventsVaultDetachUntilExactRetry()async throws {
        let f=try await fixture(nativeVault:true),review=try await review(f)
        var statement:OpaquePointer?=try f.old.store.withRoutineDatabase {try $0.statement("SELECT 1")};defer {sqlite3_finalize(statement)}
        f.app.approveSyncDevice(review,from:f.old);try await settle(f.app)
        XCTAssertTrue(f.app.hasPendingMembershipClose);XCTAssertFalse(f.old.store.isClosed)
        f.app.requestLock();try await settle(f.app)
        XCTAssertNotNil(f.app.failure);XCTAssertTrue(f.app.hasPendingMembershipClose)
        XCTAssertEqual(f.app.vaultStatus?.imageAttached,true);XCTAssertFalse(f.old.store.isClosed)
        for id in [f.pairingID,f.deliveryID] {XCTAssertThrowsError(try SyncCredentialExclusiveLease(id:id,stateRoot:environment.stateRoot))}
        sqlite3_finalize(statement);statement=nil;f.app.requestLock();try await settle(f.app)
        XCTAssertNil(f.app.failure);XCTAssertTrue(f.old.store.isClosed);XCTAssertFalse(f.app.hasPendingMembershipClose)
        XCTAssertNil(f.app.model);XCTAssertNil(f.app.syncApprovalPresentation);XCTAssertEqual(f.app.vaultStatus?.imageAttached,false)
        f.app.unlock(passphrase:try XCTUnwrap(f.passphrase),remember:false);try await settle(f.app)
        XCTAssertNil(f.app.failure);try assertQuiet(XCTUnwrap(f.app.model));XCTAssertNil(f.app.syncApprovalPresentation)
        f.app.requestLock();try await settle(f.app);XCTAssertEqual(f.app.vaultStatus?.imageAttached,false)
    }
    func testNativeSavedApprovalSurvivesDetachAndUnlockReturnsOnlyRecovery()async throws {
        let f=try await fixture(nativeVault:true),review=try await review(f),backend=try XCTUnwrap(nativeStorage)
        backend.failAfterIntent=true;f.app.approveSyncDevice(review,from:f.old);try await settle(f.app);backend.failAfterIntent=false
        XCTAssertNil(f.app.model);XCTAssertTrue(f.app.syncMembershipPending);XCTAssertTrue(f.old.store.isClosed)
        f.app.requestLock();try await settle(f.app);XCTAssertEqual(f.app.vaultStatus?.imageAttached,false)
        try FileManager.default.removeItem(at:f.provider)
        f.app.unlock(passphrase:try XCTUnwrap(f.passphrase),remember:false);try await settle(f.app)
        XCTAssertEqual(f.app.vaultStatus?.state,.unlocked);XCTAssertNil(f.app.model);XCTAssertTrue(f.app.syncMembershipPending)
        XCTAssertNil(f.app.syncApprovalPresentation)
        f.app.resumeSyncMembership();try await settle(f.app)
        XCTAssertNil(f.app.failure);try assertQuiet(XCTUnwrap(f.app.model));XCTAssertFalse(f.app.syncMembershipPending);XCTAssertNil(f.app.syncApprovalPresentation)
        let fresh=try XCTUnwrap(f.app.model),owner=try pair(fresh.store),response=try XCTUnwrap(owner.lastApprovedResponse())
        XCTAssertEqual(response.requestFingerprint,review.requestFingerprint);_=try f.peer.acceptResponse(response.response,trustedRootFingerprint:f.fingerprint);owner.close()
        f.app.requestLock();try await settle(f.app);XCTAssertEqual(f.app.vaultStatus?.imageAttached,false)
    }
    func testRenderActualOwnerReviewAndResponseInBothAppearances()async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_OWNER_UI_QA_DIR"] else {throw XCTSkip("Explicit authored component raster QA; no desktop capture")}
        let output=URL(fileURLWithPath:path);try Paths.ensure(output)
        let f=try await fixture()
        for dark in [false,true] {
            try await render(AnyView(PersonalSyncOwnerAdditionView(model:f.old.personalSync,initiallyExpanded:true).padding(24)),size:.init(width:660,height:420),dark:dark,to:output.appendingPathComponent("request-\(dark ? "dark":"light").png"))
        }
        let review=try await review(f)
        for dark in [false,true] {
            try await render(AnyView(PersonalSyncOwnerAdditionView(model:f.old.personalSync,initiallyExpanded:true).padding(24)),size:.init(width:660,height:500),dark:dark,to:output.appendingPathComponent("review-\(dark ? "dark":"light").png"))
        }
        f.app.approveSyncDevice(review,from:f.old);try await settle(f.app);XCTAssertNil(f.app.failure)
        let presentation=try XCTUnwrap(f.app.syncApprovalPresentation)
        for dark in [false,true] {
            try await render(AnyView(PersonalSyncApprovalResponseView(presentation:presentation)),size:.init(width:660,height:520),dark:dark,to:output.appendingPathComponent("response-\(dark ? "dark":"light").png"))
        }
    }
    private func render(_ content:AnyView,size:NSSize,dark:Bool,to path:URL)async throws {
        let view=NSHostingView(rootView:content.frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(dark ? .dark:.light))
        let window=NSWindow(contentRect:.init(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=view;defer {window.close()}
        view.layoutSubtreeIfNeeded();window.displayIfNeeded();try await Task.sleep(for:.milliseconds(350))
        view.layoutSubtreeIfNeeded();window.displayIfNeeded()
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
        let data=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]));try data.write(to:path)
        XCTAssertGreaterThan(data.count,4000,"Component raster unexpectedly empty")
    }
}

@MainActor final class PeerMembershipAppSessionTests:XCTestCase {
    private var root:URL!,defaults:UserDefaults!,suite:String!
    private var stores=[MemoryStore](),pairings=[PersonalSyncPairing](),sessions=[PersonalSyncSession](),changes=[PersonalSyncMembershipChange](),apps=[AppSession](),trackers=[OwnerOpenTracker](),vaults=[LibraryVault]()
    private let storage=AppOwnerStorage(),locks=OwnerLockFlag()
    private var nativeStorage:AppOwnerNativeStorage?
    private var environment:SyncNativeWriterEnvironment {
        if let nativeStorage {let native=SyncNativeWriterEnvironment.native;return .init(stateRoot:native.stateRoot,machine:native.machine,storage:{_ in nativeStorage})}
        return .init(stateRoot:root.appendingPathComponent("state"),machine:AppOwnerMachine(),storage:{[storage] _ in storage})
    }
    private struct Fixture {
        let app:AppSession,old:AppModel,page:String,pairingID:String,deliveryID:String,provider:URL,tracker:OwnerOpenTracker,passphrase:String?
        let ownerRoot:URL
    }
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-peer-membership-"+UUID().uuidString);try Paths.ensure(root)
        suite="org.oswind.tests.peer-membership."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
    }
    override func tearDown()async throws {
        storage.failAfterIntent=false;nativeStorage?.failAfterIntent=false;locks.locked=false;trackers.forEach {$0.release()}
        for app in apps {
            if app.busy {app.cancelOperation();try await settle(app)}
            if app.hasPendingMembershipClose {app.retryMembershipClose();try await settle(app)}
            guard await app.lockForTermination() else {throw OSwindError.unavailable("Owned peer fixture could not join its original session")}
            if let model=app.model {try model.store.close();app.model=nil}
        }
        for session in sessions {try await session.stop()}
        try changes.forEach {try $0.close()};pairings.forEach {$0.close()};try stores.forEach {try $0.close()};try trackers.flatMap(\.stores).forEach {try $0.close()}
        for vault in vaults {let status=try await vault.lock();guard status.state == .locked,!status.imageAttached else {throw OSwindError.unavailable("Owned peer vault remains attached; root preserved")}}
        try nativeStorage?.cleanup();defaults.removePersistentDomain(forName:suite);try FileManager.default.removeItem(at:root)
    }
    private func store(_ path:URL)throws->MemoryStore {let value=try MemoryStore(root:path,recoveryReadOnly:false,nativeWriterEnvironment:environment);stores.append(value);return value}
    private func pair(_ store:MemoryStore)throws->PersonalSyncPairing {let env=environment,value=try PersonalSyncPairing(store:store,stateRoot:env.stateRoot,machine:env.machine,storage:env.storage(.loginKeychain));pairings.append(value);return value}
    private func settle(_ app:AppSession)async throws {
        let end=SuspendingClock.now.advanced(by:.seconds(25))
        while app.busy,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(app.busy,"Owned peer app operation did not finish: phase=\(app.progress?.phase ?? "none") failure=\(app.failure ?? "none")")
    }
    private func waitAction(_ model:PersonalSyncModel)async throws {
        let end=SuspendingClock.now.advanced(by:.seconds(15))
        while model.ownerReviewBusy,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(model.ownerReviewBusy);XCTAssertNil(model.ownerReviewError)
    }
    private func review(_ f:Fixture)async throws->PersonalSyncMembershipReview {
        f.old.personalSync.reviewMembershipPage(f.page);try await waitAction(f.old.personalSync)
        return try XCTUnwrap(f.old.personalSync.membershipUpdateReview)
    }
    private func fixture(nativeVault:Bool=false,preview:Bool=true)async throws->Fixture {
        var peerRoot=root.appendingPathComponent("peer"),passphrase:String?
        if nativeVault {
            guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1",ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned peer encrypted APFS and generated login-Keychain fixture")}
            nativeStorage=AppOwnerNativeStorage();let package=root.appendingPathComponent("Peer.oswindvault"),secret=UUID().uuidString
            _=try await LibraryVault.create(at:package,name:"Owned peer update",capacityGiB:1,passphrase:Data(secret.utf8));let vault=try LibraryVault(package:package);vaults.append(vault)
            _=try await vault.unlock(passphrase:Data(secret.utf8));peerRoot=vault.libraryURL;passphrase=secret
        }
        let ownerStore=try store(root.appendingPathComponent("owner")),peerStore=try store(peerRoot),owner=try pair(ownerStore),peer=try pair(peerStore)
        _=try owner.createGroup(deviceName:"Owned group owner");let fingerprint=try XCTUnwrap(owner.status().rootFingerprint)
        let request=try XCTUnwrap(peer.requestJoin(deviceName:"Owned existing peer").request)
        _=try peer.acceptResponse(owner.approve(owner.reviewRequest(request)),trustedRootFingerprint:fingerprint)
        let provider=root.appendingPathComponent("provider"),ownerSession=try owner.prepareSession(sharedFolder:provider,createSharedFolder:true),peerSession=try peer.prepareSession(sharedFolder:provider);sessions += [ownerSession,peerSession]
        try peerStore.insert(Memory(id:"keep",text:"Owned peer source before membership update"))
        try peerStore.savePersonalSyncPreferences(.init(reconnectOnLaunch:false,networkEnabled:false));try await peerSession.stop();try peerStore.close()
        var settings=AppSettings();settings.captureOnLaunch=false;settings.apiEnabled=false;settings.routinesEnabled=false;settings.automaticMaintenance=false;settings.entityAutomaticIndex=false;settings.clipboard.enabled=false;settings.meetings.enabled=false;try settings.save(root:peerRoot)
        let env=environment,locks=locks,tracker=OwnerOpenTracker(env);trackers.append(tracker)
        let app=AppSession(selection:.init(url:peerRoot,requiresExisting:true,origin:"owned-peer"),defaults:defaults,locked:{[locks] in locks.locked},openStore:{try tracker.open($0)},personalSyncSetup:{library in
            PersonalSyncModel(store:library,locked:{[locks] in locks.locked},pairingFactory:{try PersonalSyncPairing(store:$0,stateRoot:env.stateRoot,machine:env.machine,storage:env.storage(.loginKeychain))})
        },syncRecovery:.init(pending:{_ in false},retry:{_,_ in throw OSwindError.invalid("Not peer erasure")}),membershipRecovery:{PersonalSyncMembershipChange.recover(root:$0,environment:env)},ownerAdditionPreview:preview)
        apps.append(app);try await settle(app);XCTAssertNil(app.failure)
        let old=try XCTUnwrap(app.model);old.showOnboarding=false;try await SourceWorkTestJob.settle(old)
        let startup=SuspendingClock.now.advanced(by:.seconds(15));while old.personalSync.preparing || old.personalSync.changing,SuspendingClock.now<startup {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(old.personalSync.preparing);XCTAssertFalse(old.personalSync.changing);old.personalSync.reconnectSavedFolder()
        let end=SuspendingClock.now.advanced(by:.seconds(15));while old.personalSync.preparing || old.personalSync.changing || !old.personalSync.configured,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertTrue(old.personalSync.configured);XCTAssertFalse(old.personalSync.isGroupOwner)
        old.personalSync.requestMembershipUpdate();try await waitAction(old.personalSync);let publicRequest=try XCTUnwrap(old.personalSync.membershipRequest)
        let ids=try old.store.withRoutineDatabase {db->(String,String) in
            let row=try db.statement("SELECT id,(SELECT value FROM store_metadata WHERE key='sync-pairing-handle-v1') FROM personal_sync_delivery_anchor");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Original peer accounts missing")}
            let handle=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(db.text(row,1).utf8)) as? [String:Any]);return(try XCTUnwrap(handle["id"] as? String),db.text(row,0))
        }
        let joining=try pair(store(root.appendingPathComponent("joining"))),joiningRequest=try XCTUnwrap(joining.requestJoin(deviceName:"Owned added Mac").request),ownerReview=try await ownerSession.reviewOwnerAddition(joiningRequest)
        try await ownerSession.stop();let change=try await ownerSession.ownerChangeAfterStopping(ownerReview);changes.append(change)
        let response=try XCTUnwrap(change.apply());try change.close();_=try joining.acceptResponse(response.response,trustedRootFingerprint:fingerprint);joining.close()
        let freshOwner=try store(ownerStore.root),exporter=try pair(freshOwner),page=try XCTUnwrap(exporter.membershipUpdatePage(for:publicRequest));exporter.close()
        try freshOwner.savePersonalSyncPreferences(.init(reconnectOnLaunch:false,networkEnabled:false))
        try freshOwner.close()
        return .init(app:app,old:old,page:page,pairingID:ids.0,deliveryID:ids.1,provider:provider,tracker:tracker,passphrase:passphrase,ownerRoot:freshOwner.root)
    }
    private func quiet(_ f:Fixture,file:StaticString=#filePath,line:UInt=#line)throws {
        let fresh=try XCTUnwrap(f.app.model,file:file,line:line);XCTAssertFalse(fresh === f.old,file:file,line:line);XCTAssertFalse(fresh.isCapturing,file:file,line:line);XCTAssertEqual(fresh.apiStatus,"API off",file:file,line:line);XCTAssertFalse(fresh.personalSync.configured,file:file,line:line)
        XCTAssertEqual(try fresh.store.personalSyncPreferences(),.init(reconnectOnLaunch:false,networkEnabled:false),file:file,line:line)
        XCTAssertNotNil(try fresh.store.get("keep"),file:file,line:line);XCTAssertNil(f.app.syncApprovalPresentation,file:file,line:line)
    }
    private func ownerApp(_ f:Fixture,gate:ImportWorkerGate?=nil)async throws->AppSession {
        var settings=AppSettings();settings.captureOnLaunch=false;settings.apiEnabled=false;settings.routinesEnabled=false;settings.automaticMaintenance=false;settings.entityAutomaticIndex=false;settings.clipboard.enabled=false;settings.meetings.enabled=false;try settings.save(root:f.ownerRoot)
        let env=environment,tracker=OwnerOpenTracker(env);trackers.append(tracker)
        let app=AppSession(selection:.init(url:f.ownerRoot,requiresExisting:true,origin:"owned-export"),defaults:defaults,locked:{false},openStore:{try tracker.open($0)},personalSyncSetup:{library in
            PersonalSyncModel(store:library,locked:{false},pairingFactory:{library in
                try gate?.pause()
                return try PersonalSyncPairing(store:library,stateRoot:env.stateRoot,machine:env.machine,storage:env.storage(.loginKeychain))
            })
        },ownerAdditionPreview:true)
        apps.append(app);try await settle(app);XCTAssertNil(app.failure)
        let model=try XCTUnwrap(app.model);model.showOnboarding=false;try await SourceWorkTestJob.settle(model)
        XCTAssertFalse(model.isCapturing);XCTAssertEqual(model.apiStatus,"API off");XCTAssertFalse(model.personalSync.configured)
        return app
    }
    private func pairingDone(_ model:PersonalSyncModel)async throws {
        let deadline=SuspendingClock.now.advanced(by:.seconds(15))
        while model.pairingBusy,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(model.pairingBusy);XCTAssertNil(model.pairingError)
    }
    func testActualOwnerAppExportsExactPublicPageWithoutChangingPrivateAccounts()async throws {
        let f=try await fixture(),owner=try await ownerApp(f),model=try XCTUnwrap(owner.model).personalSync,request=try XCTUnwrap(f.old.personalSync.membershipRequest),before=storage.values
        model.performPairing(.membershipPage(request));try await pairingDone(model)
        XCTAssertEqual(model.membershipPage,f.page);XCTAssertFalse(model.membershipPageCurrent);XCTAssertEqual(model.pairingStatus?.memberNames.count,3)
        XCTAssertNil(model.pairingResponse);XCTAssertFalse(model.configured);XCTAssertTrue(storage.values==before,"Public export changed private accounts")
        model.performPairing(.membershipRequest);try await pairingDone(model)
        let current=try XCTUnwrap(model.membershipRequest);model.performPairing(.membershipPage(current));try await pairingDone(model)
        XCTAssertNil(model.membershipPage);XCTAssertTrue(model.membershipPageCurrent);XCTAssertTrue(storage.values==before)
        model.clearPairingMessages();XCTAssertFalse(model.membershipPageCurrent);XCTAssertNil(model.membershipPage)
    }
    func testCancelledOwnerExportJoinsActualWorkerBeforeLibraryClose()async throws {
        let f=try await fixture(),gate=ImportWorkerGate();defer {gate.release()}
        let owner=try await ownerApp(f,gate:gate),old=try XCTUnwrap(owner.model),model=old.personalSync,request=try XCTUnwrap(f.old.personalSync.membershipRequest),before=storage.values
        model.performPairing(.membershipPage(request));await fulfillment(of:[gate.entered],timeout:5)
        model.cancelPairing();let departed=Task {await owner.lockForTermination()}
        for _ in 0..<10 {await Task.yield()}
        XCTAssertFalse(old.store.isClosed);XCTAssertTrue(model.busy);XCTAssertNil(model.membershipPage)
        gate.release();let joined=await departed.value;XCTAssertTrue(joined);XCTAssertFalse(model.busy)
        try old.store.close();XCTAssertTrue(old.store.isClosed)
        XCTAssertNil(model.membershipPage);XCTAssertTrue(storage.values==before)
    }
    func testRenderPeerRequestReviewAndOwnerExportInBothAppearances()async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_PEER_UI_QA_DIR"] else {throw XCTSkip("Explicit generated peer component raster QA; no desktop capture")}
        let output=URL(fileURLWithPath:path);try Paths.ensure(output);let f=try await fixture()
        for dark in [false,true] {try await renderPeer(f.old.personalSync,size:.init(width:660,height:650),dark:dark,to:output.appendingPathComponent("request-\(dark ? "dark":"light").png"))}
        _=try await review(f)
        for dark in [false,true] {try await renderPeer(f.old.personalSync,size:.init(width:660,height:470),dark:dark,to:output.appendingPathComponent("review-\(dark ? "dark":"light").png"))}
        let owner=try await ownerApp(f),model=try XCTUnwrap(owner.model).personalSync
        model.performPairing(.membershipPage(try XCTUnwrap(f.old.personalSync.membershipRequest)));try await pairingDone(model);XCTAssertEqual(model.membershipPage,f.page)
        for dark in [false,true] {try await renderPeer(model,size:.init(width:660,height:550),dark:dark,to:output.appendingPathComponent("export-\(dark ? "dark":"light").png"))}
    }
    private func renderPeer(_ model:PersonalSyncModel,size:NSSize,dark:Bool,to path:URL)async throws {
        let content=PersonalSyncMembershipUpdateView(model:model,initiallyExpanded:true).padding(24)
        let view=NSHostingView(rootView:content.frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(dark ? .dark:.light))
        let window=NSWindow(contentRect:.init(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;defer {window.close()}
        view.layoutSubtreeIfNeeded();window.displayIfNeeded();try await Task.sleep(for:.milliseconds(350));view.layoutSubtreeIfNeeded();window.displayIfNeeded()
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
        let bytes=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]));try bytes.write(to:path);XCTAssertGreaterThan(bytes.count,4000)
    }
    func testActualPeerAppAppliesExactReviewAndReopensQuietlyWithoutResponse()async throws {
        let f=try await fixture(),review=try await review(f),accounts=Set(storage.values.keys)
        f.app.approveSyncMembership(review,from:f.old);XCTAssertTrue(f.app.busy);XCTAssertNil(f.app.model);try await settle(f.app)
        XCTAssertNil(f.app.failure);XCTAssertTrue(f.old.store.isClosed);try quiet(f);XCTAssertEqual(Set(storage.values.keys),accounts)
        let peer=try pair(XCTUnwrap(f.app.model).store);XCTAssertEqual(try peer.status().memberNames.count,3);peer.close()
    }
    func testActualHeldProducerDelaysPeerIntentAndFreshOpening()async throws {
        let f=try await fixture(),review=try await review(f),backend=environment.storage(.loginKeychain),before=try backend.read(id:f.pairingID),gate=ImportWorkerGate();defer {gate.release()}
        try SourceWorkTestJob.note.start(f.old,gate:gate);await fulfillment(of:[gate.entered],timeout:5)
        f.app.approveSyncMembership(review,from:f.old);await fulfillment(of:[gate.cancelled],timeout:5)
        XCTAssertTrue(f.app.busy);XCTAssertFalse(f.old.store.isClosed);XCTAssertEqual(f.tracker.count,1);XCTAssertTrue(try backend.read(id:f.pairingID)==before)
        gate.release();try await settle(f.app);XCTAssertNil(f.app.failure);try quiet(f)
    }
    func testCancellationDuringActualDrainDoesNotPublishPeerIntent()async throws {
        let f=try await fixture(),review=try await review(f),backend=environment.storage(.loginKeychain),before=try backend.read(id:f.pairingID),gate=ImportWorkerGate();defer {gate.release()}
        try SourceWorkTestJob.statistics.start(f.old,gate:gate);await fulfillment(of:[gate.entered],timeout:5)
        f.app.approveSyncMembership(review,from:f.old);await fulfillment(of:[gate.cancelled],timeout:5);f.app.cancelOperation()
        XCTAssertTrue(f.app.busy);XCTAssertFalse(f.old.store.isClosed);gate.release();try await settle(f.app)
        XCTAssertTrue(try backend.read(id:f.pairingID)==before);try quiet(f)
    }
    func testBusyPeerCloseKeepsBothLeasesAndQuitCannotBypassOriginalRetry()async throws {
        let f=try await fixture(),review=try await review(f)
        var statement:OpaquePointer?=try f.old.store.withRoutineDatabase {try $0.statement("SELECT 1")};defer {sqlite3_finalize(statement)}
        f.app.approveSyncMembership(review,from:f.old);try await settle(f.app)
        XCTAssertNotNil(f.app.failure);XCTAssertTrue(f.app.hasPendingMembershipClose);XCTAssertFalse(f.old.store.isClosed);XCTAssertEqual(f.tracker.count,1)
        for id in [f.pairingID,f.deliveryID] {XCTAssertThrowsError(try SyncCredentialExclusiveLease(id:id,stateRoot:environment.stateRoot))}
        let safe=await f.app.lockForTermination();XCTAssertFalse(safe);XCTAssertFalse(f.old.store.isClosed)
        sqlite3_finalize(statement);statement=nil;f.app.retryMembershipClose();try await settle(f.app);XCTAssertNil(f.app.failure);try quiet(f)
    }
    func testSavedPeerIntentRecoversWithoutProviderAndNeverShowsJoiningResponse()async throws {
        let f=try await fixture(),review=try await review(f);storage.failAfterIntent=true
        f.app.approveSyncMembership(review,from:f.old);try await settle(f.app);storage.failAfterIntent=false
        XCTAssertTrue(f.app.syncMembershipPending);XCTAssertNil(f.app.model);XCTAssertNil(f.app.syncApprovalPresentation)
        try FileManager.default.removeItem(at:f.provider);f.app.resumeSyncMembership();try await settle(f.app)
        XCTAssertNil(f.app.failure);XCTAssertFalse(f.app.syncMembershipPending);try quiet(f)
    }
    func testLatePeerLockJoinsFreshOpeningAndSuppressesWorkspaceAndResponse()async throws {
        let f=try await fixture(),review=try await review(f);f.tracker.holdNext();defer {f.tracker.release()}
        f.app.approveSyncMembership(review,from:f.old);await fulfillment(of:[f.tracker.entered],timeout:15)
        f.app.requestLock();XCTAssertTrue(f.app.busy);XCTAssertNil(f.app.model);f.tracker.release();try await settle(f.app)
        XCTAssertNil(f.app.model);XCTAssertNil(f.app.syncApprovalPresentation);XCTAssertTrue(f.tracker.stores.allSatisfy(\.isClosed))
    }
    func testDisabledPreviewAndClearedReviewCannotStartPeerApply()async throws {
        let f=try await fixture(preview:false),review=try await review(f),backend=environment.storage(.loginKeychain),before=try backend.read(id:f.pairingID),accounts=Set(storage.values.keys)
        XCTAssertNil(f.old.personalSync.approveMembershipUpdate);f.app.approveSyncMembership(review,from:f.old)
        XCTAssertFalse(f.app.busy);XCTAssertTrue(f.app.model === f.old);XCTAssertTrue(try backend.read(id:f.pairingID)==before);XCTAssertEqual(Set(storage.values.keys),accounts)
    }
    func testClearedAndRetiredPeerReviewCannotStartPrivateWork()async throws {
        let f=try await fixture(),review=try await review(f),backend=environment.storage(.loginKeychain),before=try backend.read(id:f.pairingID),checkpoint=try backend.read(id:f.deliveryID),accounts=Set(storage.values.keys)
        f.old.personalSync.clearOwnerReview();f.app.approveSyncMembership(review,from:f.old);XCTAssertFalse(f.app.busy);XCTAssertTrue(try backend.read(id:f.pairingID)==before)
        let current=try await self.review(f);f.old.prepareForLibrarySwitch();await f.old.cancelExternalWorkAndWait();f.app.approveSyncMembership(current,from:f.old)
        XCTAssertFalse(f.app.busy);XCTAssertFalse(f.old.store.isClosed);XCTAssertTrue(try backend.read(id:f.pairingID)==before);XCTAssertEqual(Set(storage.values.keys),accounts)
        let paired=try pair(f.old.store);XCTAssertEqual(try paired.status().memberNames.count,2);paired.close()
        print("OWNED_PEER_STALE_REVIEW originalPairingUnchanged=true originalAccountSetUnchanged=true members=2 ordinaryCheckpointChanged=\(try backend.read(id:f.deliveryID) != checkpoint)")
    }
    private func substitution(_ databaseOnly:Bool)async throws {
        let f=try await fixture(),review=try await review(f),replacement=root.appendingPathComponent("replacement"),saved=root.appendingPathComponent("original-saved"),original=f.old.store.root
        let other=try store(replacement);try other.insert(Memory(id:"other",text:"Unrelated peer workspace"));try other.close()
        f.tracker.beforeNextOpen {path in
            let fm=FileManager.default
            if databaseOnly {
                try Paths.ensure(saved)
                for name in ["memory.sqlite","memory.sqlite-wal","memory.sqlite-shm"] where fm.fileExists(atPath:path.appendingPathComponent(name).path) {try fm.moveItem(at:path.appendingPathComponent(name),to:saved.appendingPathComponent(name))}
                try fm.copyItem(at:replacement.appendingPathComponent("memory.sqlite"),to:path.appendingPathComponent("memory.sqlite"))
            }else {try fm.moveItem(at:path,to:saved);try fm.moveItem(at:replacement,to:path)}
        }
        f.app.approveSyncMembership(review,from:f.old);try await settle(f.app);XCTAssertNotNil(f.app.failure);XCTAssertNil(f.app.model);XCTAssertNil(f.app.syncApprovalPresentation);XCTAssertTrue(f.tracker.stores.allSatisfy(\.isClosed))
        if databaseOnly {
            for name in ["memory.sqlite","memory.sqlite-wal","memory.sqlite-shm"] where FileManager.default.fileExists(atPath:original.appendingPathComponent(name).path) {try FileManager.default.removeItem(at:original.appendingPathComponent(name))}
            for name in ["memory.sqlite","memory.sqlite-wal","memory.sqlite-shm"] where FileManager.default.fileExists(atPath:saved.appendingPathComponent(name).path) {try FileManager.default.moveItem(at:saved.appendingPathComponent(name),to:original.appendingPathComponent(name))}
        }else {try FileManager.default.moveItem(at:original,to:replacement);try FileManager.default.moveItem(at:saved,to:original)}
        f.app.retryMembershipClose();try await settle(f.app);XCTAssertNil(f.app.failure);try quiet(f)
    }
    func testReplacedPeerRootCannotReceiveQuietWorkspace()async throws {try await substitution(false)}
    func testReplacedPeerDatabaseCannotReceiveQuietWorkspace()async throws {try await substitution(true)}
    func testNativePeerSavedIntentDetachesAndUnlocksIntoExactRecovery()async throws {
        let f=try await fixture(nativeVault:true),review=try await review(f);nativeStorage?.failAfterIntent=true
        f.app.approveSyncMembership(review,from:f.old);try await settle(f.app);nativeStorage?.failAfterIntent=false
        XCTAssertTrue(f.app.syncMembershipPending);f.app.requestLock();try await settle(f.app);XCTAssertEqual(f.app.vaultStatus?.imageAttached,false)
        try FileManager.default.removeItem(at:f.provider);f.app.unlock(passphrase:try XCTUnwrap(f.passphrase),remember:false);try await settle(f.app)
        XCTAssertEqual(f.app.vaultStatus?.state,.unlocked);XCTAssertTrue(f.app.syncMembershipPending);XCTAssertNil(f.app.model)
        f.app.resumeSyncMembership();try await settle(f.app);XCTAssertNil(f.app.failure);try quiet(f)
        f.app.requestLock();try await settle(f.app);XCTAssertEqual(f.app.vaultStatus?.imageAttached,false)
    }
    func testNativePeerFailedClosePreventsVaultDetachUntilOriginalRetry()async throws {
        let f=try await fixture(nativeVault:true),review=try await review(f)
        var statement:OpaquePointer?=try f.old.store.withRoutineDatabase {try $0.statement("SELECT 1")};defer {sqlite3_finalize(statement)}
        f.app.approveSyncMembership(review,from:f.old);try await settle(f.app);XCTAssertTrue(f.app.hasPendingMembershipClose)
        f.app.requestLock();try await settle(f.app);XCTAssertEqual(f.app.vaultStatus?.imageAttached,true);XCTAssertFalse(f.old.store.isClosed)
        sqlite3_finalize(statement);statement=nil;f.app.retryMembershipClose();try await settle(f.app)
        f.app.requestLock();try await settle(f.app);XCTAssertEqual(f.app.vaultStatus?.imageAttached,false);XCTAssertNil(f.app.syncApprovalPresentation)
    }
    func testNativeVaultWatcherCannotReopenWhileOriginalPeerCloseIsBlocked()async throws {
        let f=try await fixture(nativeVault:true),review=try await review(f)
        var statement:OpaquePointer?=try f.old.store.withRoutineDatabase {try $0.statement("SELECT 1")};defer {sqlite3_finalize(statement)}
        f.app.approveSyncMembership(review,from:f.old);try await settle(f.app)
        XCTAssertTrue(f.app.hasPendingMembershipClose);XCTAssertFalse(f.old.store.isClosed);XCTAssertEqual(f.tracker.count,1);XCTAssertNil(f.app.model)
        let observed=expectation(description:"Actual vault directory observer refresh entered")
        let observation=f.app.$busy.filter {$0}.prefix(1).sink {_ in observed.fulfill()};defer {observation.cancel()}
        let package=try XCTUnwrap(f.app.vaultPackage)
        try Data("owned watcher probe".utf8).write(to:package.appendingPathComponent(".owned-watcher-probe"))
        await fulfillment(of:[observed],timeout:5);try await settle(f.app)
        XCTAssertEqual(f.tracker.count,1,"A metadata notification reopened before the original owner closed")
        XCTAssertNil(f.app.model,"Pending original close must retain the restricted screen")
        XCTAssertTrue(f.app.hasPendingMembershipClose);XCTAssertFalse(f.old.store.isClosed)
        // Close any incorrectly admitted candidate even on the failing control
        // run, so the owned fixture never detaches with that reader unjoined.
        if let candidate=f.app.model {candidate.prepareForLibrarySwitch();await candidate.cancelExternalWorkAndWait();try candidate.store.close();f.app.model=nil}
        sqlite3_finalize(statement);statement=nil;f.app.requestLock();try await settle(f.app)
        XCTAssertEqual(f.app.vaultStatus?.imageAttached,false);XCTAssertTrue(f.old.store.isClosed);XCTAssertNil(f.app.syncApprovalPresentation)
    }
    func testNativePeerLateLockWaitsForActualFreshStoreBeforeDetach()async throws {
        let f=try await fixture(nativeVault:true),review=try await review(f);f.tracker.holdNext();defer {f.tracker.release()}
        f.app.approveSyncMembership(review,from:f.old);await fulfillment(of:[f.tracker.entered],timeout:15);f.app.requestLock()
        XCTAssertTrue(f.app.busy);XCTAssertEqual(f.app.vaultStatus?.imageAttached,true);f.tracker.release();try await settle(f.app)
        XCTAssertEqual(f.app.vaultStatus?.imageAttached,false);XCTAssertNil(f.app.model);XCTAssertNil(f.app.syncApprovalPresentation)
    }
}
