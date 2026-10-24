import XCTest
import AppKit
import OSwindCore
@testable import OSwind

@MainActor final class VaultSessionTests:XCTestCase {
    var root:URL!,defaults:UserDefaults!,suite:String!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-session-"+UUID().uuidString);try Paths.ensure(root);suite="com.oswind.tests.vault."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!}
    override func tearDownWithError() throws {defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
    func native() throws {guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned encrypted APFS session fixture; no normal library or real Keychain access")}}
    func finish(_ session:AppSession) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(60))
        while session.busy,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(20))}
        XCTAssertFalse(session.busy,"Session operation exceeded bounded test wait")
    }
    func testBrokenReservedVaultCannotCreatePlaintextFromExplicitEnvironment() throws {
        let package=root.appendingPathComponent("Missing.oswindvault")
        let session=AppSession(selection:.init(url:package,requiresExisting:false,origin:"environment"),defaults:defaults,locked:{false})
        XCTAssertNil(session.model);XCTAssertNotNil(session.failure);XCTAssertFalse(FileManager.default.fileExists(atPath:package.path))
    }
    func testManagedSelectionCreatesLockedScreenWithoutLoadingCredentialOrStore() async throws {
        let package=root.appendingPathComponent("Fixture.oswindvault");try Paths.ensure(package)
        let info=LibraryVaultInfo(name:"Locked session fixture",capacityGiB:1,volumeUUID:UUID().uuidString,keychainEnabled:true)
        try JSONEncoder().encode(info).write(to:package.appendingPathComponent("oswind-vault.json"));try Data("closed".utf8).write(to:package.appendingPathComponent("Library"))
        let session=AppSession(selection:.init(url:package.appendingPathComponent("Library"),requiresExisting:true,origin:"selected"),defaults:defaults,locked:{false})
        try await finish(session);XCTAssertNil(session.model);XCTAssertEqual(session.vaultPackage?.resolvingSymlinksInPath().path,package.resolvingSymlinksInPath().path);XCTAssertTrue(session.vaultStatus?.info.keychainEnabled == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath:package.appendingPathComponent("memory.sqlite").path));XCTAssertNil(session.failure)
        let safe=await session.lockForTermination();XCTAssertTrue(safe);XCTAssertEqual(session.vaultStatus?.state,.unavailable);XCTAssertEqual(session.vaultStatus?.volumeMounted,false)
    }
    func testNativeCopySwitchLockUnlockAndFallbackPreserveOriginal() async throws {
        try native();let original=root.appendingPathComponent("Original"),package=root.appendingPathComponent("Encrypted.oswindvault"),secret=UUID().uuidString
        let session=AppSession(selection:.init(url:original,requiresExisting:false,origin:"environment"),defaults:defaults,locked:{false})
        let old=try XCTUnwrap(session.model);try old.store.insert(Memory(id:"keep",text:"Synthetic native session history"));old.query="sensitive query";old.question="sensitive question"
        session.createVault(at:package,name:"Owned session",capacityGiB:1,passphrase:secret,copyHistory:true,remember:false);try await finish(session)
        XCTAssertNil(session.failure);XCTAssertEqual(session.vaultStatus?.state,.unlocked);XCTAssertNotNil(try session.model?.store.get("keep"));XCTAssertTrue(old.store.isClosed)
        XCTAssertEqual(defaults.string(forKey:LibraryLocationPreferences.key),try LibraryVault(package:package).libraryURL.path)
        let current=try XCTUnwrap(session.model);session.requestLock();try await finish(session)
        XCTAssertNil(session.failure);XCTAssertNil(session.model);XCTAssertTrue(current.store.isClosed);XCTAssertEqual(session.vaultStatus?.state,.locked);XCTAssertTrue(old.query.isEmpty);XCTAssertTrue(old.question.isEmpty)
        session.unlock(passphrase:secret,remember:false);try await finish(session);XCTAssertNotNil(try session.model?.store.get("keep"))
        session.open(original);try await finish(session);XCTAssertNil(session.failure);XCTAssertNil(session.vaultPackage);XCTAssertNotNil(try session.model?.store.get("keep"))
        session.model?.prepareForLibrarySwitch();try session.model?.store.close();session.model=nil
    }
    func testNativeBusyReaderRemainsClosingUntilRetry() async throws {
        try native();let package=root.appendingPathComponent("Busy.oswindvault"),secret=UUID().uuidString
        _=try await LibraryVault.create(at:package,name:"Busy fixture",capacityGiB:1,passphrase:Data(secret.utf8))
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"selected"),defaults:defaults,locked:{false});try await finish(session)
        session.unlock(passphrase:secret,remember:false);try await finish(session);let active=try XCTUnwrap(session.model),other=try MemoryStore(root:active.store.root)
        session.requestLock();try await finish(session);XCTAssertNil(session.model);XCTAssertTrue(active.store.isClosed);XCTAssertEqual(session.vaultStatus?.state,.closing);XCTAssertNotNil(session.failure)
        try other.close();session.requestLock();try await finish(session);XCTAssertNil(session.failure);XCTAssertEqual(session.vaultStatus?.state,.locked)
    }
    func testNativeChangedSourceSnapshotDoesNotSwitchOrLockTheOriginal() async throws {
        try native();let original=root.appendingPathComponent("Original"),package=root.appendingPathComponent("Snapshot.oswindvault")
        let session=AppSession(selection:.init(url:original,requiresExisting:false,origin:"environment"),defaults:defaults,locked:{false}),source=try XCTUnwrap(session.model?.store)
        try source.insert(Memory(id:"keep",text:"Original source"));let mutation=SessionMigrationMutation(store:source)
        session.createVault(at:package,name:"Changed source snapshot",capacityGiB:1,passphrase:UUID().uuidString,copyHistory:true,remember:false,observeMigration:{mutation.observe($0)})
        try await finish(session);XCTAssertNil(session.failure);XCTAssertNil(session.vaultPackage);XCTAssertTrue(session.snapshotNeedsReview);XCTAssertNotNil(session.createdVault)
        XCTAssertNotNil(try session.model?.store.get("keep"));XCTAssertNotNil(try session.model?.store.get("changed"));XCTAssertNil(defaults.string(forKey:LibraryLocationPreferences.key))
        let status=try await LibraryVault(package:package).status();XCTAssertEqual(status.state,.locked)
        session.model?.prepareForLibrarySwitch();try session.model?.store.close();session.model=nil
    }
    func testNativeExternalLockEventClearsHistoryAndClosesTheExistingStore() async throws {
        try native();let package=root.appendingPathComponent("External.oswindvault"),secret=UUID().uuidString
        _=try await LibraryVault.create(at:package,name:"External lock fixture",capacityGiB:1,passphrase:Data(secret.utf8))
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"selected"),defaults:defaults,locked:{false});try await finish(session)
        session.unlock(passphrase:secret,remember:false);try await finish(session);let active=try XCTUnwrap(session.model)
        do {_=try await LibraryVault(package:package).lock()} catch {}
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while session.model != nil,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(20))}
        try await finish(session);XCTAssertNil(session.model);XCTAssertTrue(active.store.isClosed)
        session.requestLock();try await finish(session);XCTAssertEqual(session.vaultStatus?.state,.locked);XCTAssertNil(session.failure)
    }
    func testNativeSessionLockAtStartupDetachesWithoutOpeningHistory() async throws {
        try native();let package=root.appendingPathComponent("Startup.oswindvault"),secret=Data(UUID().uuidString.utf8)
        _=try await LibraryVault.create(at:package,name:"Startup fixture",capacityGiB:1,passphrase:secret,keepUnlocked:true)
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"selected"),defaults:defaults,locked:{true});try await finish(session)
        XCTAssertNil(session.model);XCTAssertEqual(session.vaultStatus?.state,.locked);XCTAssertNil(session.failure)
    }
    func testNativeSessionLockFallbackStopsAndDetachesWithoutAWorkspaceEvent() async throws {
        try native();let package=root.appendingPathComponent("Monitor.oswindvault"),secret=UUID().uuidString
        _=try await LibraryVault.create(at:package,name:"Monitored fixture",capacityGiB:1,passphrase:Data(secret.utf8))
        var locked=false
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"selected"),defaults:defaults,locked:{locked});try await finish(session)
        session.unlock(passphrase:secret,remember:false);try await finish(session);XCTAssertNotNil(session.model)
        locked=true
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while session.model != nil,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(20))}
        try await finish(session);XCTAssertNil(session.model);XCTAssertEqual(session.vaultStatus?.state,.locked);XCTAssertNil(session.failure)
    }
    func testQuitDelegateReturnsToTheRunLoopUntilVerifiedLockCompletes() async throws {
        try native();let package=root.appendingPathComponent("Quit.oswindvault"),secret=UUID().uuidString
        _=try await LibraryVault.create(at:package,name:"Quit lifecycle",capacityGiB:1,passphrase:Data(secret.utf8))
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"selected"),defaults:defaults,locked:{false});try await finish(session)
        session.unlock(passphrase:secret,remember:false);try await finish(session)
        let delegate=AppDelegate();var exits=0;delegate.finishTermination={_ in exits+=1}
        let app=NSApplication.shared
        XCTAssertEqual(delegate.applicationShouldTerminate(app),.terminateCancel)
        XCTAssertEqual(delegate.applicationShouldTerminate(app),.terminateCancel)
        let deadline=ContinuousClock.now.advanced(by:.seconds(15))
        while exits==0,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(20))}
        XCTAssertEqual(exits,1);XCTAssertEqual(session.vaultStatus?.state,.locked);XCTAssertNil(session.model);XCTAssertEqual(delegate.applicationShouldTerminate(app),.terminateNow)
        session.unlock(passphrase:secret,remember:false);XCTAssertFalse(session.busy);XCTAssertNil(session.model)
    }
    func testNormalTerminationAwaitsCancelledSetupBeforeReturning() async throws {
        try native();let original=root.appendingPathComponent("Original"),package=root.appendingPathComponent("Terminated.oswindvault")
        let session=AppSession(selection:.init(url:original,requiresExisting:false,origin:"environment"),defaults:defaults,locked:{false})
        try session.model?.store.insert(Memory(id:"keep",text:"Original at termination"))
        session.createVault(at:package,name:"Quit fixture",capacityGiB:1,passphrase:UUID().uuidString,copyHistory:true,remember:false)
        let safe=await session.lockForTermination();XCTAssertTrue(safe);XCTAssertFalse(session.busy);XCTAssertNotNil(try session.model?.store.get("keep"));XCTAssertNil(session.vaultPackage)
        try session.model?.store.close();session.model=nil
    }
    func testNativeCancelledSetupKeepsOriginalSelectedAndQuiet() async throws {
        try native();let original=root.appendingPathComponent("Original"),package=root.appendingPathComponent("Cancelled.oswindvault")
        let session=AppSession(selection:.init(url:original,requiresExisting:false,origin:"environment"),defaults:defaults,locked:{false});try session.model?.store.insert(Memory(id:"keep",text:"Original after cancellation"))
        session.createVault(at:package,name:"Cancelled",capacityGiB:1,passphrase:UUID().uuidString,copyHistory:true,remember:false);session.cancelOperation();try await finish(session)
        XCTAssertNotNil(try session.model?.store.get("keep"));XCTAssertNil(session.vaultPackage);XCTAssertNil(defaults.string(forKey:LibraryLocationPreferences.key));XCTAssertFalse(session.model?.isCapturing ?? true)
        session.model?.prepareForLibrarySwitch();try session.model?.store.close();session.model=nil
    }
}

private final class SessionMigrationMutation:@unchecked Sendable {
    let store:MemoryStore;private var changed=false
    init(store:MemoryStore) {self.store=store}
    func observe(_ progress:LibraryBackupProgress) {if !changed,progress.phase=="Publishing restored library" {changed=true;try? store.insert(Memory(id:"changed",text:"Concurrent source mutation"))}}
}
