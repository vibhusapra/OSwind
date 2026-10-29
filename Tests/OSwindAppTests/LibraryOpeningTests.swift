import XCTest
@testable import OSwind
@testable import OSwindCore

private final class LibraryOpeningGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"owned library prepared off main actor")
    private let condition=NSCondition()
    private var released=false
    private(set) var store:MemoryStore?
    private(set) var usedMainThread=false,timedOut=false
    func open(_ root:URL) throws -> MemoryStore {
        let value=try MemoryStore(root:root)
        condition.lock();defer {condition.unlock()};store=value;usedMainThread=Thread.isMainThread;entered.fulfill()
        let deadline=SuspendingClock.now.advanced(by:.seconds(10))
        while !released {
            if SuspendingClock.now>=deadline {timedOut=true;break}
            _=condition.wait(until:Date().addingTimeInterval(0.1))
        }
        return value // Deliberately ignores cancellation to exercise late success cleanup.
    }
    func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
}
private final class OpeningAttempt:@unchecked Sendable {
    private let lock=NSLock();private var first=true
    func open(_ root:URL) throws -> MemoryStore {
        lock.lock();let fail=first;first=false;lock.unlock()
        if fail {throw OSwindError.unavailable("Owned initial opening failure")}
        return try MemoryStore(root:root)
    }
}
@MainActor final class LibraryOpeningTests:XCTestCase {
    var root:URL!,defaults:UserDefaults!,suite:String!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-opening-"+UUID().uuidString);try Paths.ensure(root);suite="org.oswind.owned-opening."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!}
    override func tearDownWithError() throws {defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
    func finish(_ session:AppSession) async throws {
        // Keep the same awake-work budget across laptop maintenance sleep.
        // A timed-out fixture must still join normal cleanup before tearDown
        // removes its owned root; never leave a busy task writing into it.
        let deadline=SuspendingClock.now.advanced(by:.seconds(20))
        while session.busy,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        if session.busy {
            XCTFail("Owned opening did not settle within 20 awake seconds")
            let safe=await session.lockForTermination();XCTAssertTrue(safe,"Owned opening cleanup could not confirm safe termination")
        }
        XCTAssertFalse(session.busy)
    }
    func cleanup(_ session:AppSession) throws {session.model?.prepareForLibrarySwitch();try session.model?.store.close();session.model=nil}
    private func session(_ gate:LibraryOpeningGate)->AppSession {AppSession(selection:.init(url:root.appendingPathComponent("library"),requiresExisting:false,origin:"owned"),defaults:defaults,locked:{false},openStore:{try gate.open($0)})}
    func testStartupKeepsMainActorResponsiveAndPublishesPreparedStoreOnce() async throws {
        let gate=LibraryOpeningGate(),app=session(gate);defer {gate.release();try? cleanup(app)}
        XCTAssertTrue(app.busy);XCTAssertNil(app.model);await fulfillment(of:[gate.entered],timeout:5)
        let tick=Task {@MainActor in 42},result=await tick.value;XCTAssertEqual(result,42);XCTAssertTrue(app.busy);XCTAssertNil(app.model)
        gate.release();try await finish(app);XCTAssertNil(app.failure);XCTAssertFalse(gate.usedMainThread);XCTAssertFalse(gate.timedOut)
        XCTAssertTrue(app.model?.store === gate.store);XCTAssertFalse(app.model?.store.isClosed ?? true)
    }
    func testCancelledOpeningClosesLateStoreWithoutPublishingOrStartingServices() async throws {
        let gate=LibraryOpeningGate(),app=session(gate);defer {gate.release();try? cleanup(app)}
        await fulfillment(of:[gate.entered],timeout:5);app.cancelOperation();XCTAssertTrue(app.busy);gate.release();try await finish(app)
        XCTAssertNil(app.model);XCTAssertTrue(gate.store?.isClosed == true);XCTAssertNil(app.failure);XCTAssertTrue(app.message.contains("Opening stopped"));XCTAssertNil(defaults.string(forKey:LibraryLocationPreferences.key))
    }
    func testTerminationAwaitsLateOpeningAndCannotPublishAfterExitApproval() async throws {
        let gate=LibraryOpeningGate(),app=session(gate);defer {gate.release();try? cleanup(app)}
        await fulfillment(of:[gate.entered],timeout:5)
        let termination=Task {@MainActor in await app.lockForTermination()};await Task.yield();XCTAssertTrue(app.busy)
        gate.release();let safe=await termination.value;XCTAssertTrue(safe);XCTAssertFalse(app.busy);XCTAssertNil(app.model);XCTAssertTrue(gate.store?.isClosed == true)
    }
    func testPreparedStoreFromDifferentLocationIsClosedAndRefused() async throws {
        let other=try MemoryStore(root:root.appendingPathComponent("other"));defer {try? other.close()}
        let app=AppSession(selection:.init(url:root.appendingPathComponent("chosen"),requiresExisting:false,origin:"owned"),defaults:defaults,locked:{false},openStore:{_ in other})
        try await finish(app);XCTAssertNil(app.model);XCTAssertNotNil(app.failure);XCTAssertTrue(other.isClosed)
    }
    func testDirectoryReplacedDuringPreparationCannotPublishAndOriginalCloses() async throws {
        let gate=LibraryOpeningGate(),app=session(gate);defer {gate.release();try? cleanup(app)}
        await fulfillment(of:[gate.entered],timeout:5)
        let location=try XCTUnwrap(gate.store?.root),moved=root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at:location,to:moved);try Paths.ensure(location)
        gate.release();try await finish(app)
        XCTAssertNil(app.model);XCTAssertNotNil(app.failure);XCTAssertTrue(gate.store?.isClosed == true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:location.path).isEmpty)
        let original=try MemoryStore(root:moved);try original.close()
    }
    func testRetryAfterOpeningFailureUsesSelectedLibraryAndStaysQuiet() async throws {
        let library=root.appendingPathComponent("library"),store=try MemoryStore(root:library);try store.insert(Memory(id:"keep",text:"Owned history"));try store.close()
        let attempt=OpeningAttempt(),app=AppSession(selection:.init(url:library,requiresExisting:true,origin:"owned"),defaults:defaults,locked:{false},openStore:{try attempt.open($0)})
        defer {try? cleanup(app)};try await finish(app);XCTAssertNil(app.model);XCTAssertNotNil(app.failure)
        app.retry();try await finish(app);XCTAssertNil(app.failure);XCTAssertEqual(try app.model?.store.get("keep")?.text,"Owned history");XCTAssertFalse(app.model?.isCapturing ?? true);XCTAssertEqual(app.model?.apiStatus,"API off")
    }
    func testInitialNewLibraryFailureCanRetryBeforeAnyDatabaseExists() async throws {
        let library=root.appendingPathComponent("new-library"),attempt=OpeningAttempt()
        let app=AppSession(selection:.init(url:library,requiresExisting:false,origin:"owned"),defaults:defaults,locked:{false},openStore:{try attempt.open($0)})
        defer {try? cleanup(app)};try await finish(app)
        XCTAssertNil(app.model);XCTAssertNotNil(app.failure);XCTAssertFalse(FileManager.default.fileExists(atPath:library.path))
        app.retry();try await finish(app)
        XCTAssertNil(app.failure);XCTAssertEqual(app.model?.store.root,library);XCTAssertEqual(try app.model?.store.stats(includeDiskUsage:false).count,0)
        XCTAssertFalse(app.model?.isCapturing ?? true);XCTAssertEqual(app.model?.apiStatus,"API off")
    }
    func testNativeVaultLockDuringPreparationClosesLateStoreAndDetaches() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned encrypted opening fixture; no normal history or Keychain")}
        let package=root.appendingPathComponent("Opening.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        _=try await LibraryVault.create(at:package,name:"Owned opening",capacityGiB:1,passphrase:secret,keepUnlocked:true)
        let gate=LibraryOpeningGate();var locked=false
        let app=AppSession(selection:.init(url:package,requiresExisting:true,origin:"owned"),defaults:defaults,locked:{locked},openStore:{try gate.open($0)})
        defer {gate.release();try? cleanup(app)}
        do {
            await fulfillment(of:[gate.entered],timeout:5);locked=true;app.requestLock();gate.release();try await finish(app)
            XCTAssertNil(app.model);XCTAssertTrue(gate.store?.isClosed == true);XCTAssertEqual(app.vaultStatus?.state,.locked);XCTAssertNil(app.failure)
            let attachment=try await NativeVaultDriver().attachment(paths:VaultPaths(package));XCTAssertNil(attachment)
        } catch {_=try? await vault.lock();throw error}
    }
}
