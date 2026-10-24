import XCTest
@testable import OSwindCore

private actor DetachObservations {
    enum Value {case pending,attached,detached,changed,unavailable}
    let values:[Value];var calls=0,pauses=0
    init(_ values:[Value]) {self.values=values}
    func inspect()throws->Bool {
        let value=values[min(calls,values.count-1)];calls+=1
        switch value {
        case .pending:throw VaultAttachmentObservationError.unmountedVolumePending
        case .attached:return false
        case .detached:return true
        case .changed:throw OSwindError.invalid("Owned fixture identity changed")
        case .unavailable:throw OSwindError.unavailable("Owned fixture inspection unavailable")
        }
    }
    func pause() {pauses+=1}
    func counts()->[Int] {[calls,pauses]}
}
private actor DetachPause {
    let entered=XCTestExpectation(description:"detach observation paused")
    var continuation:CheckedContinuation<Void,Never>?
    func wait() async {await withCheckedContinuation {continuation=$0;entered.fulfill()}}
    func resume() {continuation?.resume();continuation=nil}
}

@MainActor final class VaultDetachSettlementTests:XCTestCase {
    func testIncompleteThenAttachedThenAbsentNeedsFreshConfirmation() async throws {
        let state=DetachObservations([.pending,.pending,.attached,.detached])
        try await VaultDetachSettlement.confirm(pause:{_ in await state.pause()},inspect:{try await state.inspect()})
        let counts=await state.counts();XCTAssertEqual(counts,[5,4])
    }
    func testOneAbsentObservationDoesNotHideAReappearingAttachment() async throws {
        let state=DetachObservations([.detached,.attached,.detached,.detached])
        try await VaultDetachSettlement.confirm(pause:{_ in await state.pause()},inspect:{try await state.inspect()})
        let counts=await state.counts();XCTAssertEqual(counts,[4,3])
    }
    func testUnknownInspectionOrChangedIdentityFailsWithoutConsumingRemainingBudget() async throws {
        for value in [DetachObservations.Value.changed,.unavailable] {
            let state=DetachObservations([.attached,value,.detached])
            do {try await VaultDetachSettlement.confirm(pause:{_ in await state.pause()},inspect:{try await state.inspect()});XCTFail("Unknown or changed identity accepted")}
            catch {XCTAssertTrue(error.localizedDescription.contains("Owned fixture"))}
            let counts=await state.counts();XCTAssertEqual(counts,[2,1])
        }
    }
    func testStillAttachedOrPermanentlyIncompleteNeverReportsDetached() async throws {
        for value in [DetachObservations.Value.attached,.pending] {
            let state=DetachObservations([value])
            do {try await VaultDetachSettlement.confirm(attempts:3,pause:{_ in await state.pause()},inspect:{try await state.inspect()});XCTFail("Unverified detach accepted")}
            catch {XCTAssertTrue(error.localizedDescription.contains("could not be verified"))}
            let counts=await state.counts();XCTAssertEqual(counts,[3,2])
        }
    }
    func testCancellationWhileWaitingPreventsAnotherInspection() async throws {
        let state=DetachObservations([.attached,.detached]),gate=DetachPause()
        let task=Task {try await VaultDetachSettlement.confirm(pause:{_ in await gate.wait()},inspect:{try await state.inspect()})}
        await fulfillment(of:[gate.entered],timeout:5);task.cancel();await gate.resume()
        do {try await task.value;XCTFail("Cancelled confirmation succeeded")} catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        let counts=await state.counts();XCTAssertEqual(counts[0],1)
    }
    func testAlreadyCancelledConfirmationDoesNotInspect() async throws {
        let state=DetachObservations([.detached])
        let task=Task {withUnsafeCurrentTask {$0?.cancel()};try await VaultDetachSettlement.confirm(inspect:{try await state.inspect()})}
        do {try await task.value;XCTFail("Cancelled confirmation succeeded")} catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        let counts=await state.counts();XCTAssertEqual(counts[0],0)
    }
    func testCancellationDuringAbsentReplyDoesNotPublishSuccess() async throws {
        let task=Task {try await VaultDetachSettlement.confirm(inspect:{withUnsafeCurrentTask {$0?.cancel()};return true})}
        do {try await task.value;XCTFail("Cancelled absence accepted")} catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
    }
    private func fixture() throws ->(URL,VaultPaths,VaultDetachIdentity) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-detach-identity-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Fixture.oswindvault");try Paths.ensure(package);let paths=try VaultPaths(package)
        try paths.write(LibraryVaultInfo(name:"Owned identity fixture",capacityGiB:1,volumeUUID:UUID().uuidString),as:VaultPaths.manifestName)
        try Paths.ensure(paths.image);try Data("owned image marker".utf8).write(to:paths.image.appendingPathComponent("keep"))
        return (root,paths,try VaultDetachIdentity(paths:paths,image:BackupFileTree(root:paths.image).identity()))
    }
    func testImageReplacementDuringObservationRefusesAndPreservesBothDirectories() throws {
        let (root,paths,identity)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        try identity.validate();let moved=root.appendingPathComponent("OriginalImage");try FileManager.default.moveItem(at:paths.image,to:moved);try Paths.ensure(paths.image)
        try Data("replacement marker".utf8).write(to:paths.image.appendingPathComponent("keep"))
        XCTAssertThrowsError(try identity.validate());XCTAssertEqual(try String(contentsOf:moved.appendingPathComponent("keep"),encoding:.utf8),"owned image marker")
        XCTAssertEqual(try String(contentsOf:paths.image.appendingPathComponent("keep"),encoding:.utf8),"replacement marker")
    }
    func testPackageReplacementCannotRedirectPostDetachVerification() throws {
        let (root,paths,identity)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let moved=root.appendingPathComponent("OriginalPackage");try FileManager.default.moveItem(at:paths.package,to:moved);try Paths.ensure(paths.package)
        try Data("replacement".utf8).write(to:paths.package.appendingPathComponent("keep"));XCTAssertThrowsError(try identity.validate())
        XCTAssertEqual(try String(contentsOf:paths.package.appendingPathComponent("keep"),encoding:.utf8),"replacement")
        XCTAssertEqual(try String(contentsOf:moved.appendingPathComponent("contents.sparsebundle/keep"),encoding:.utf8),"owned image marker")
    }
    func testManifestVaultOrVolumeIdentityChangesRefuse() throws {
        for field in 0..<3 {
            let (root,paths,identity)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
            var changed=try paths.info()
            switch field {case 0:changed.id=UUID().uuidString.lowercased();case 1:changed.volumeUUID=UUID().uuidString;default:changed.setupComplete.toggle()}
            try paths.write(changed,as:VaultPaths.manifestName);XCTAssertThrowsError(try identity.validate())
            XCTAssertEqual(try paths.info(),changed)
        }
    }
}

final class NativeVaultDetachSettlementTests:XCTestCase {
    func testRapidNativeLockUnlockKeepsHistoryAndIndependentlyConfirmsNoAttachment() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned rapid encrypted-volume detach fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-detach-settling-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Fixture.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        var activeStore:MemoryStore?
        do {
            _ = try await LibraryVault.create(at:package,name:"Owned detach settling",capacityGiB:1,passphrase:secret)
            for iteration in 0..<6 {
                _ = try await vault.unlock(passphrase:secret)
                let store=try MemoryStore(root:vault.libraryURL);activeStore=store
                XCTAssertEqual(try store.stats(includeDiskUsage:false).count,iteration)
                try store.insert(Memory(id:"owned-\(iteration)",text:"Preserved owned detach cycle \(iteration)"))
                let locked=try await vault.lock(store:store);XCTAssertTrue(store.isClosed);activeStore=nil
                XCTAssertEqual(locked.state,.locked);XCTAssertFalse(locked.imageAttached);XCTAssertFalse(locked.volumeMounted)
                let inventory=try await VaultProcess.run("/usr/bin/hdiutil",["info","-plist"]);XCTAssertEqual(inventory.status,0)
                let info=try XCTUnwrap(PropertyListSerialization.propertyList(from:inventory.stdout,format:nil) as? [String:Any])
                let images=try XCTUnwrap(info["images"] as? [[String:Any]])
                XCTAssertFalse(images.contains {($0["image-path"] as? String)?.hasPrefix(package.path+"/") == true})
            }
            _ = try await vault.unlock(passphrase:secret)
            let final=try MemoryStore(root:vault.libraryURL);activeStore=final
            XCTAssertEqual(try final.stats(includeDiskUsage:false).count,6)
            for iteration in 0..<6 {XCTAssertEqual(try final.get("owned-\(iteration)")?.text,"Preserved owned detach cycle \(iteration)")}
            _ = try await vault.lock(store:final);activeStore=nil
            try FileManager.default.removeItem(at:root)
        } catch {
            try? activeStore?.close();_ = try? await vault.lock();throw error
        }
    }
}
