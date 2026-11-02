import XCTest
import SwiftUI
import AppKit
import Vision
@testable import OSwindCore
@testable import OSwind

@MainActor final class PersonalSyncPairingModelTests:XCTestCase {
    private var root:URL!,a:MemoryStore!,b:MemoryStore!,storage:PairingAppStorage!
    var models=[PersonalSyncModel]()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-pairing-app-"+UUID().uuidString)
        a=try MemoryStore(root:root.appendingPathComponent("a"));b=try MemoryStore(root:root.appendingPathComponent("b"));storage=PairingAppStorage()
    }
    override func tearDown()async throws {for model in models {await model.cancelAndWait()};try a.close();try b.close();try FileManager.default.removeItem(at:root)}
    func model(_ store:MemoryStore,gate:ImportWorkerGate?=nil)->PersonalSyncModel {
        let state=root.appendingPathComponent("state"),storage=storage!
        let value=PersonalSyncModel(store:store,locked:{false},pairingFactory:{store in
            try gate?.pause()
            return try PersonalSyncPairing(store:store,stateRoot:state,machine:PairingAppMachine(),storage:storage)
        });models.append(value);return value
    }
    func done(_ model:PersonalSyncModel)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(15))
        while model.pairingBusy,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        guard !model.pairingBusy else {throw OSwindError.unavailable("Owned pairing action did not finish")}
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
        owner.performPairing(.load);await fulfillment(of:[gate.entered],timeout:10)
        XCTAssertTrue(owner.busy);XCTAssertTrue(owner.pairingBusy)
        var drained=false
        let drain=Task {await owner.cancelAndWait();drained=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(40));XCTAssertFalse(drained);XCTAssertFalse(a.isClosed)
        gate.release();await drain.value
        XCTAssertFalse(owner.busy);XCTAssertFalse(owner.pairingBusy);XCTAssertNil(owner.pairingStatus)
        XCTAssertTrue(storage.values.isEmpty)
        try a.close();XCTAssertTrue(a.isClosed)
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
        joiner.performPairing(.retire);try await done(joiner);try await render(joiner,name:"retired",directory:directory)
        owner.performPairing(.review("Owned invalid request"));try await done(owner);try await render(owner,name:"failure",directory:directory)
    }
    private func render(_ model:PersonalSyncModel,name:String,directory:URL)async throws {
        for dark in [false,true] {
            let background=dark ? NSColor(calibratedWhite:0.12,alpha:1):NSColor.white
            let view=PersonalSyncPairingView(model:model,receivingResponse:name=="pending-response").environment(\.colorScheme,dark ? .dark:.light).background(Color(nsColor:background))
            let host=NSHostingView(rootView:view),window=NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:650),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);window.contentView=host
            host.layoutSubtreeIfNeeded();window.displayIfNeeded();try await Task.sleep(for:.milliseconds(150));host.layoutSubtreeIfNeeded();window.displayIfNeeded()
            let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
            let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]));try png.write(to:directory.appendingPathComponent("\(name)-\(dark ? "dark":"light").png"))
            let recognition=VNRecognizeTextRequest();recognition.recognitionLevel = .accurate;recognition.recognitionLanguages=["en-US"]
            try VNImageRequestHandler(data:png,options:[:]).perform([recognition])
            let text=(recognition.results ?? []).compactMap {$0.topCandidates(1).first?.string}.joined(separator:" ").lowercased()
            let expected=["unconfigured":"create a group","owner":"add a mac","pending":"waiting for the group owner","pending-response":"verify and save this mac","review":"approve this exact request","response":"return this encrypted response","paired":"device paired","retired":"local pairing retired","failure":"pairing could not finish"][name]!
            XCTAssertTrue(text.contains(expected),"Owned \(name) render omitted expected screen content: \(text)")
            window.contentView=nil;window.close()


        }
    }
}
private struct PairingAppMachine:SyncMachineFingerprint {func fingerprint()throws->String {String(repeating:"a",count:64)}}
private final class PairingAppStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let lock=NSLock();private var saved=[String:Data](),createGate:PairingSaveGate?
    func install(_ value:PairingSaveGate?) {lock.lock();createGate=value;lock.unlock()}
    var values:[String:Data] {lock.lock();defer {lock.unlock()};return saved}
    func create(id:String,bytes:Data)throws {lock.lock();let gate=createGate;lock.unlock();gate?.pause()
        lock.lock();defer {lock.unlock()};guard saved[id]==nil else {throw SyncCredentialStorageError.alreadyExists};saved[id]=bytes}
    func read(id:String)throws->Data {lock.lock();defer {lock.unlock()};guard let bytes=saved[id] else {throw SyncCredentialStorageError.missing};return bytes}
    func replace(id:String,expected:Data,bytes:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved[id]=bytes}
    func remove(id:String,expected:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved.removeValue(forKey:id)}
}

private final class PairingSaveGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"Actual pairing credential save entered")
    private let condition=NSCondition();private var released=false
    func pause() {condition.lock();defer {condition.unlock()};entered.fulfill();while !released {condition.wait()}}
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
}
