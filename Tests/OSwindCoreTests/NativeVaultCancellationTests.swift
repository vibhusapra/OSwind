import XCTest
import Foundation
import Darwin
@testable import OSwindCore

final class NativeVaultCancellationTests:XCTestCase {
    private func ownedAttachmentCount(_ package:URL) async throws ->Int {
        let result=try await VaultProcess.run("/usr/bin/hdiutil",["info","-plist"])
        XCTAssertEqual(result.status,0)
        let info=try XCTUnwrap(PropertyListSerialization.propertyList(from:result.stdout,format:nil) as? [String:Any])
        let images=try XCTUnwrap(info["images"] as? [[String:Any]])
        let image=package.appendingPathComponent("contents.sparsebundle").standardizedFileURL.resolvingSymlinksInPath()
        return images.filter {item in (item["image-path"] as? String).map {URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath()==image} ?? false}.count
    }
    private func observeOwnedHelper(_ action:String,target:String) async throws ->Bool {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while ContinuousClock.now<deadline {
            let result=try await VaultProcess.run("/bin/ps",["-axo","pid=,ppid=,args="])
            guard result.status==0,let text=String(data:result.stdout,encoding:.utf8) else {throw OSwindError.unavailable("Owned attach observation failed")}
            let observed=text.split(separator:"\n").contains {line in
                let parts=line.split(maxSplits:2,whereSeparator:{$0.isWhitespace})
                return parts.count==3 && parts[1]==String(getpid()) && parts[2].hasPrefix("/usr/bin/hdiutil "+action+" ") && parts[2].contains(target)
            }
            if observed {return true}
            try await Task.sleep(for:.milliseconds(10))
        }
        return false
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
        let package=root.appendingPathComponent("Owned.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        var activeStore:MemoryStore?
        do {
            _=try await LibraryVault.create(at:package,name:"Owned cancellation recovery",capacityGiB:1,passphrase:secret)
            _=try await vault.unlock(passphrase:secret)
            let initial=try MemoryStore(root:vault.libraryURL);activeStore=initial;try initial.insert(Memory(id:"owned-keep",text:"Owned source survives cancelled unlock"))
            _=try await vault.lock(store:initial);activeStore=nil
            for _ in 0..<5 {
                let worker=Task {try await vault.unlock(passphrase:secret)}
                let observed:Bool
                do {observed=try await observeOwnedHelper("attach",target:VaultPaths(package).image.path)}
                catch {worker.cancel();_ = try? await worker.value;throw error}
                worker.cancel()
                do {_ = try await worker.value;XCTFail("Cancelled unlock published success")}
                catch is CancellationError {}
                catch {throw error}
                guard observed else {throw OSwindError.unavailable("No owned active attach helper observed; cancellation phase not qualified")}
                let afterCancellation=try await ownedAttachmentCount(package);XCTAssertEqual(afterCancellation,0)
                let reopened=try await vault.unlock(passphrase:secret);XCTAssertEqual(reopened.state,.unlocked)
                let store=try MemoryStore(root:vault.libraryURL);activeStore=store
                XCTAssertEqual(try store.get("owned-keep")?.text,"Owned source survives cancelled unlock")
                let locked=try await vault.lock(store:store);activeStore=nil
                XCTAssertEqual(locked.state,.locked);XCTAssertFalse(locked.imageAttached)
                let afterLock=try await ownedAttachmentCount(package);XCTAssertEqual(afterLock,0)
            }
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
        let worker=Task {try await LibraryVault.create(at:package,name:"Owned cancelled creation",capacityGiB:1,passphrase:secret)}
        do {
            let observed=try await observeOwnedHelper("create",target:VaultPaths(package).image.path);worker.cancel()
            do {_ = try await worker.value;XCTFail("Cancelled create published success")}
            catch is CancellationError {} catch {throw error}
            guard observed else {throw OSwindError.unavailable("No owned active create observed")}
            let count=try await ownedAttachmentCount(package);XCTAssertEqual(count,0)
            XCTAssertFalse(try LibraryVault.metadata(at:package).setupComplete)
            XCTAssertThrowsError(try MemoryStore(root:vault.libraryURL))
            do {_ = try await vault.unlock(passphrase:Data(UUID().uuidString.utf8));XCTFail("Wrong passphrase resumed encrypted setup")}catch {}
            let opened=try await vault.unlock(passphrase:secret);XCTAssertEqual(opened.state,.unlocked)
            let locked=try await vault.lock();XCTAssertEqual(locked.state,.locked)
            let afterLock=try await ownedAttachmentCount(package);XCTAssertEqual(afterLock,0)
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
}
