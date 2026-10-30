import XCTest
import Foundation
import Darwin
@testable import OSwindCore

/// Registration precedes the operation, so even an immediately launched helper
/// cancels the correct worker after stdin delivery. No process-list race.
private final class OwnedCredentialCancellation:@unchecked Sendable {
    private let lock=NSLock(),action:VaultCredentialHelper
    private var armed=false,cancelWorker:(@Sendable ()->Void)?,observation:(pid:Int32,live:Bool)?
    init(_ action:VaultCredentialHelper) {self.action=action}
    func started(_ action:VaultCredentialHelper,_ pid:Int32) {
        lock.lock()
        guard armed,self.action==action,observation==nil else {lock.unlock();return}
        observation=(pid,kill(pid,0)==0);let cancel=cancelWorker;lock.unlock();cancel?()
    }
    func worker<T:Sendable>(_ operation:@escaping @Sendable () async throws ->T)->Task<T,Error> {
        let (stream,start)=AsyncStream<Void>.makeStream()
        lock.lock();precondition(!armed);armed=true;observation=nil;lock.unlock()
        let task=Task {for await _ in stream {break};try Task.checkCancellation();return try await operation()}
        lock.lock();cancelWorker={task.cancel()};lock.unlock()
        start.yield(());start.finish();return task
    }
    func finish()->(pid:Int32,live:Bool)? {
        lock.lock();defer {lock.unlock()};armed=false;cancelWorker=nil;return observation
    }
}

final class NativeVaultCancellationTests:XCTestCase {
    private func ownedAttachmentCount(_ package:URL) async throws ->Int {
        let result=try await VaultProcess.run("/usr/bin/hdiutil",["info","-plist"])
        XCTAssertEqual(result.status,0)
        let info=try XCTUnwrap(PropertyListSerialization.propertyList(from:result.stdout,format:nil) as? [String:Any])
        let images=try XCTUnwrap(info["images"] as? [[String:Any]])
        let image=package.appendingPathComponent("contents.sparsebundle").standardizedFileURL.resolvingSymlinksInPath()
        let matched=images.filter {item in (item["image-path"] as? String).map {URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath()==image} ?? false}
        if !matched.isEmpty {
            // Only this test's exact authored image. Distinguish stale inventory
            // from a remaining backing device without logging paths or secrets.
            let entities=matched.flatMap {($0["system-entities"] as? [[String:Any]] ?? []).map {entity -> [String:Any] in
                let device=entity["dev-entry"] as? String ?? ""
                let valid=device.hasPrefix("/dev/disk") && device.dropFirst(9).allSatisfy({$0.isNumber || $0=="s"})
                var metadata=stat()
                return ["contentHint":entity["content-hint"] as? String ?? "unknown","mounted":entity["mount-point"] != nil,"deviceNodeExists":valid && lstat(device,&metadata)==0]
            }}
            var metadata=stat();let aliasClosed=lstat(package.appendingPathComponent("Library").path,&metadata)==0 && metadata.st_mode&S_IFMT==S_IFREG
            let diagnostic:[String:Any] = ["ownedImageRecords":matched.count,"aliasClosed":aliasClosed,"entities":entities]
            print("Owned cancellation absence diagnostic: "+String(decoding:try JSONSerialization.data(withJSONObject:diagnostic,options:[.sortedKeys]),as:UTF8.self))
        }
        return matched.count
    }
    private func observeClosingPhase(_ paths:VaultPaths,store:MemoryStore) async throws ->Bool {
        let info=try paths.info(),deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while ContinuousClock.now<deadline {
            if store.isClosed,(try? paths.session(info:info))?.phase == .closing {return true}
            try await Task.sleep(for:.milliseconds(1))
        }
        return false
    }
    private func removeDetachedFixture(_ root:URL,package:URL) async throws {
        guard try await ownedAttachmentCount(package)==0 else {throw OSwindError.unavailable("Owned encrypted fixture is still attached; preserve its package")}
        try FileManager.default.removeItem(at:root)
    }
    func testCancelledOwnedUnlockCanImmediatelyRecoverWithHistory() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned observed native attach cancellation/recovery fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-cancel-recovery-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Owned.oswindvault"),secret=Data(UUID().uuidString.utf8),trigger=OwnedCredentialCancellation(.attach)
        let vault=try LibraryVault(package:package,nativeDriver:NativeVaultDriver(credentialHelperReady:{trigger.started($0,$1)}))
        var activeStore:MemoryStore?
        do {
            _=try await LibraryVault.create(at:package,name:"Owned cancellation recovery",capacityGiB:1,passphrase:secret)
            _=try await vault.unlock(passphrase:secret)
            let initial=try MemoryStore(root:vault.libraryURL);activeStore=initial;try initial.insert(Memory(id:"owned-keep",text:"Owned source survives cancelled unlock"))
            _=try await vault.lock(store:initial);activeStore=nil
            for _ in 0..<5 {
                let worker=trigger.worker {try await vault.unlock(passphrase:secret)}
                defer {_ = trigger.finish()}
                do {_ = try await worker.value;XCTFail("Cancelled unlock published success")}
                catch is CancellationError {}
                catch {throw error}
                let observed=try XCTUnwrap(trigger.finish(),"Owned attach start was not observed")
                XCTAssertGreaterThan(observed.pid,0);XCTAssertTrue(observed.live,"Attach helper was not active after credential delivery")
                let afterCancellation=try await ownedAttachmentCount(package);XCTAssertEqual(afterCancellation,0)
                let reopened=try await vault.unlock(passphrase:secret);XCTAssertEqual(reopened.state,.unlocked)
                let store=try MemoryStore(root:vault.libraryURL);activeStore=store
                XCTAssertEqual(try store.get("owned-keep")?.text,"Owned source survives cancelled unlock")
                let locked=try await vault.lock(store:store);activeStore=nil
                XCTAssertEqual(locked.state,.locked);XCTAssertFalse(locked.imageAttached)
                let afterLock=try await ownedAttachmentCount(package);XCTAssertEqual(afterLock,0)
            }
            print("NATIVE_CANCEL_PHASE attach cycles=5 inputClosed=5 activeHelpers=5 historyChecks=5")
            try await removeDetachedFixture(root,package:package)
        } catch {
            // Preserve the failed encrypted fixture. Only a normal product lock
            // may recover its freshly verified image; never force a device.
            try? activeStore?.close();_ = try? await vault.lock();throw error
        }
    }
    func testCancelledOwnedCreateKeepsClosedEncryptedSetupAndCanResume() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned observed native create cancellation/recovery fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-create-cancel-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Owned.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        let trigger=OwnedCredentialCancellation(.create),driver=NativeVaultDriver(credentialHelperReady:{trigger.started($0,$1)})
        let worker=trigger.worker {try await LibraryVault.create(at:package,name:"Owned cancelled creation",capacityGiB:1,passphrase:secret,nativeDriver:driver)}
        defer {_ = trigger.finish()}
        do {
            do {_ = try await worker.value;XCTFail("Cancelled create published success")}
            catch is CancellationError {} catch {throw error}
            let observed=try XCTUnwrap(trigger.finish(),"Owned create start was not observed")
            XCTAssertGreaterThan(observed.pid,0);XCTAssertTrue(observed.live,"Create helper was not active after credential delivery")
            let count=try await ownedAttachmentCount(package);XCTAssertEqual(count,0)
            XCTAssertFalse(try LibraryVault.metadata(at:package).setupComplete)
            XCTAssertThrowsError(try MemoryStore(root:vault.libraryURL))
            do {_ = try await vault.unlock(passphrase:Data(UUID().uuidString.utf8));XCTFail("Wrong passphrase resumed encrypted setup")}catch {}
            let opened=try await vault.unlock(passphrase:secret);XCTAssertEqual(opened.state,.unlocked)
            let locked=try await vault.lock();XCTAssertEqual(locked.state,.locked)
            let afterLock=try await ownedAttachmentCount(package);XCTAssertEqual(afterLock,0)
            print("NATIVE_CANCEL_PHASE create cycles=1 inputClosed=1 activeHelpers=1 resumed=1")
            try await removeDetachedFixture(root,package:package)
        } catch {worker.cancel();_ = try? await worker.value;_ = try? await vault.lock();throw error}
    }
    func testCancelledOwnedLockFinishesVerifiedDetachBeforeReturningWithHistoryIntact() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned observed native detach cancellation/recovery fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-lock-cancel-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Owned.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        var activeStore:MemoryStore?
        do {
            _=try await LibraryVault.create(at:package,name:"Owned cancelled locking",capacityGiB:1,passphrase:secret)
            for iteration in 0..<5 {
                _=try await vault.unlock(passphrase:secret)
                let store=try MemoryStore(root:vault.libraryURL);activeStore=store
                if iteration==0 {try store.insert(Memory(id:"owned-lock-keep",text:"Owned history survives cancelled locking"))}
                XCTAssertEqual(try store.get("owned-lock-keep")?.text,"Owned history survives cancelled locking")
                let worker=Task {try await vault.lock(store:store)}
                let observed:Bool
                do {observed=try await observeClosingPhase(VaultPaths(package),store:store)}catch {worker.cancel();_ = try? await worker.value;throw error}
                worker.cancel()
                guard observed else {_ = try? await worker.value;throw OSwindError.unavailable("Owned closing phase not observed; cancellation phase not qualified")}
                do {_ = try await worker.value;XCTFail("Cancelled lock published success")}
                catch is CancellationError {} catch {throw error}
                XCTAssertTrue(store.isClosed);activeStore=nil
                let count=try await ownedAttachmentCount(package);XCTAssertEqual(count,0)
                let status=try await vault.status();XCTAssertEqual(status.state,.locked);XCTAssertFalse(status.imageAttached)
                XCTAssertThrowsError(try MemoryStore(root:vault.libraryURL))
            }
            try await removeDetachedFixture(root,package:package)
        } catch {try? activeStore?.close();_ = try? await vault.lock();throw error}
    }
    func testCancellationDuringMediaDrainStillClosesStoreAliasAndOwnedImage() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned media-drain cancellation fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-drain-cancel-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Owned.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        var activeStore:MemoryStore?
        do {
            _=try await LibraryVault.create(at:package,name:"Owned cancelled media drain",capacityGiB:1,passphrase:secret)
            for iteration in 0..<3 {
                _=try await vault.unlock(passphrase:secret)
                let store=try MemoryStore(root:vault.libraryURL);activeStore=store
                if iteration==0 {try store.insert(Memory(id:"owned-drain-keep",text:"Owned source survives cancellation during media drain"))}
                XCTAssertEqual(try store.get("owned-drain-keep")?.text,"Owned source survives cancellation during media drain")
                let admission=try store.mediaWriteLease()
                let worker=Task {try await vault.lock(store:store)}
                do {
                    let paths=try VaultPaths(package),info=try paths.info(),deadline=SuspendingClock.now.advanced(by:.seconds(5))
                    var observed=false
                    while SuspendingClock.now<deadline {
                        if (try? paths.session(info:info))?.phase == .closing {observed=true;break}
                        try await Task.sleep(for:.milliseconds(1))
                    }
                    guard observed else {throw OSwindError.unavailable("Owned closing phase not observed while media admission is held")}
                    // The supported writer lease prevents close from completing.
                    // Cancellation must not abort its drain and skip alias/detach.
                    XCTAssertFalse(store.isClosed)
                    worker.cancel();try await Task.sleep(for:.milliseconds(100))
                    admission.release()
                    do {_ = try await worker.value;XCTFail("Cancelled media-drain lock published success")}
                    catch is CancellationError {} catch {throw error}
                    XCTAssertTrue(store.isClosed,"Cancellation returned before the store closed")
                    let count=try await ownedAttachmentCount(package);XCTAssertEqual(count,0,"Cancellation returned before independent image absence")
                    XCTAssertThrowsError(try MemoryStore(root:vault.libraryURL))
                    let status=try await vault.status();XCTAssertEqual(status.state,.locked)
                    if !store.isClosed {_ = try await vault.lock(store:store)}
                    activeStore=nil
                } catch {
                    admission.release();worker.cancel();_ = try? await worker.value;throw error
                }
            }
            try await removeDetachedFixture(root,package:package)
        } catch {try? activeStore?.close();_ = try? await vault.lock();throw error}
    }

}
