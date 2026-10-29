import XCTest
import AppKit
import OSwindCore
@testable import OSwind

final class ImportWorkerGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"Import worker entered controlled phase")
    let cancelled=XCTestExpectation(description:"Actual import worker observed cancellation")
    private let condition=NSCondition()
    private var released=false,reportedCancellation=false
    func pause() throws {
        condition.lock();defer {condition.unlock()};entered.fulfill()
        let deadline=Date().addingTimeInterval(20)
        while !released {
            if Task.isCancelled,!reportedCancellation {reportedCancellation=true;cancelled.fulfill()}
            guard Date()<deadline else {throw OSwindError.unavailable("Import test gate timed out")}
            _ = condition.wait(until:Date().addingTimeInterval(0.01))
        }
        try Task.checkCancellation()
    }
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
}

@MainActor final class ImportLifecycleModelTests:XCTestCase {
    var root:URL!,app:AppModel!,session:AppSession?,defaults:UserDefaults!,suite:String!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-import-lifecycle-"+UUID().uuidString);try Paths.ensure(root)
        app=try AppModel(root:root.appendingPathComponent("library"),startServices:false)
        suite="com.oswind.tests.import."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
    }
    override func tearDown() async throws {
        if let model=session?.model {model.prepareForLibrarySwitch();await model.cancelJSONImportAndWait();try model.store.close();session?.model=nil}
        session=nil
        app?.prepareForLibrarySwitch();await app?.cancelJSONImportAndWait();try app?.store.close();app=nil
        defaults?.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)
    }
    func fixture() throws -> URL {
        let file=root.appendingPathComponent("input.json")
        try JSONEncoder().encode([Memory(id:"owned",kind:.note,text:"Owned import fixture")]).write(to:file);return file
    }
    func finishImport(_ model:AppModel) async throws {
        for _ in 0..<2000 where model.hasPendingJSONImport {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(model.hasPendingJSONImport)
    }
    func finishSession(_ session:AppSession) async throws {
        let deadline=SuspendingClock.now.advanced(by:.seconds(60))
        while session.busy,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(session.busy);XCTAssertNil(session.failure)
    }
    func openSession() async throws -> AppSession {
        var config=AppSettings();config.automaticMaintenance=false;try config.save(root:app.store.root)
        let value=AppSession(selection:.init(url:app.store.root,requiresExisting:true,origin:"test"),defaults:defaults,locked:{false})
        session=value;try await finishSession(value);return value
    }
    func testDirectCancellationAndDrainJoinWorkerBeforeItHasAReservation() async throws {
        let gate=ImportWorkerGate();defer {gate.release()};let file=try fixture()
        app.importJSONFile(file,observeWorker:{if $0 == .started {try gate.pause()}})
        await fulfillment(of:[gate.entered],timeout:10)
        let model=app!,drained=XCTestExpectation(description:"Joined import completion")
        let drain=Task {await model.cancelJSONImportAndWait();drained.fulfill()}
        await fulfillment(of:[gate.cancelled],timeout:10)
        XCTAssertTrue(model.hasPendingJSONImport);XCTAssertFalse(model.store.isClosed)
        model.importJSONFile(file);XCTAssertEqual(try model.store.stats().count,0)
        gate.release();await fulfillment(of:[drained],timeout:10);await drain.value
        XCTAssertFalse(model.importingJSON);XCTAssertFalse(model.hasPendingJSONImport);XCTAssertEqual(try model.store.stats().count,0)
        model.importJSONFile(file);try await finishImport(model);XCTAssertEqual(try model.store.stats().count,1)
    }
    func testCancelledDrainCallerStillWaitsForSettingsDescriptorOwner() async throws {
        try app.settings.save(root:app.store.root)
        let gate=ImportWorkerGate();defer {gate.release()};let model=app!
        model.importJSONFile(try fixture(),observeWorker:{if $0 == .settingsCaptured {try gate.pause()}})
        await fulfillment(of:[gate.entered],timeout:10)
        var finished=false
        let drain=Task {await model.cancelJSONImportAndWait();finished=true};drain.cancel()
        await fulfillment(of:[gate.cancelled],timeout:10);XCTAssertFalse(finished);XCTAssertTrue(model.hasPendingJSONImport)
        gate.release();await drain.value;XCTAssertTrue(finished);XCTAssertFalse(model.hasPendingJSONImport)
        XCTAssertEqual(try model.store.stats().count,0);try model.store.close()
    }
    func testPrivacyChangeCancelsActualWorkerEvenWhenSettingsSaveFails() async throws {
        let gate=ImportWorkerGate();defer {gate.release()};let model=app!
        model.importJSONFile(try fixture(),observeWorker:{if $0 == .settingsCaptured {try gate.pause()}})
        await fulfillment(of:[gate.entered],timeout:10)
        let lock=model.store.root.appendingPathComponent(".settings-admission.lock"),target=root.appendingPathComponent("untouched")
        try Data("Owned marker".utf8).write(to:target);try FileManager.default.removeItem(at:lock);try FileManager.default.createSymbolicLink(at:lock,withDestinationURL:target)
        model.settings.privacy.redactSecrets.toggle()
        await fulfillment(of:[gate.cancelled],timeout:10);XCTAssertNotNil(model.errorMessage)
        gate.release();await model.cancelJSONImportAndWait();XCTAssertEqual(try model.store.stats().count,0)
        XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"Owned marker")
    }
    func testSwitchJoinsUnreservedWorkerBeforeClosingOldStore() async throws {
        let session=try await openSession(),old=try XCTUnwrap(session.model),gate=ImportWorkerGate();defer {gate.release()}
        let next=root.appendingPathComponent("next"),prepared=try MemoryStore(root:next);try prepared.close()
        old.importJSONFile(try fixture(),observeWorker:{if $0 == .started {try gate.pause()}})
        await fulfillment(of:[gate.entered],timeout:10);session.open(next,persist:false)
        await fulfillment(of:[gate.cancelled],timeout:10)
        XCTAssertTrue(session.busy);XCTAssertNil(session.model);XCTAssertFalse(old.store.isClosed)
        gate.release();try await finishSession(session)
        XCTAssertTrue(old.store.isClosed);XCTAssertFalse(old.hasPendingJSONImport);XCTAssertEqual(session.model?.store.root,next)
        XCTAssertFalse(old.importStatus.hasPrefix("Imported"));XCTAssertEqual(try session.model?.store.stats().count,0)
    }
    func testPlainQuitDelegateReturnsOnlyAfterUnreservedWorkerDrains() async throws {
        let session=try await openSession(),model=try XCTUnwrap(session.model),gate=ImportWorkerGate();defer {gate.release()}
        model.importJSONFile(try fixture(),observeWorker:{if $0 == .started {try gate.pause()}})
        await fulfillment(of:[gate.entered],timeout:10)
        let delegate=AppDelegate(),finished=XCTestExpectation(description:"Quit resumed after import drain");var didFinish=false
        delegate.finishTermination={_ in didFinish=true;finished.fulfill()}
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
        await fulfillment(of:[gate.cancelled],timeout:10);XCTAssertFalse(didFinish);XCTAssertTrue(model.hasPendingJSONImport)
        gate.release();await fulfillment(of:[finished],timeout:10)
        XCTAssertFalse(model.hasPendingJSONImport);XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateNow)
        XCTAssertEqual(try model.store.stats().count,0)
    }
    func testInvalidPlainSwitchPreservesOriginalAndDoesNotCancelItsImport() async throws {
        let session=try await openSession(),model=try XCTUnwrap(session.model),gate=ImportWorkerGate();defer {gate.release()}
        model.importJSONFile(try fixture(),observeWorker:{if $0 == .started {try gate.pause()}})
        await fulfillment(of:[gate.entered],timeout:10)
        session.open(root.appendingPathComponent("missing"),persist:false)
        let deadline=SuspendingClock.now.advanced(by:.seconds(10))
        while session.busy,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(session.busy);XCTAssertNotNil(session.failure);XCTAssertTrue(session.model === model);XCTAssertFalse(model.store.isClosed)
        gate.release();try await finishImport(model);XCTAssertEqual(try model.store.stats().count,1)
    }
}
