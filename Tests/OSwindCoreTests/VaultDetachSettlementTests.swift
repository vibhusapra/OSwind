import XCTest
import Darwin
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
    func testLongIncompleteIntervalCanSettleWithinExpandedBoundedBudget() async throws {
        let state=DetachObservations(Array(repeating:.pending,count:14)+[.detached,.detached])
        try await VaultDetachSettlement.confirm(pause:{_ in await state.pause()},inspect:{try await state.inspect()})
        let counts=await state.counts();XCTAssertEqual(counts,[16,15])
    }
    func testExpandedDefaultStillRefusesPermanentAttachmentWithBoundedBackoff() async throws {
        let state=DetachObservations([.pending])
        do {try await VaultDetachSettlement.confirm(pause:{_ in await state.pause()},inspect:{try await state.inspect()});XCTFail("Permanent incomplete attachment accepted")}
        catch {XCTAssertTrue(error.localizedDescription.contains("could not be verified"))}
        let counts=await state.counts();XCTAssertEqual(counts,[16,15])
        let delays=(0..<15).map(VaultDetachSettlement.delayMilliseconds)
        XCTAssertEqual(delays.first,50);XCTAssertEqual(delays.reduce(0,+),11550);XCTAssertLessThanOrEqual(delays.max()!,1000)
    }
    func testOneAbsenceAtFinalObservationCannotReportDetached() async throws {
        let state=DetachObservations(Array(repeating:.pending,count:15)+[.detached])
        do {try await VaultDetachSettlement.confirm(pause:{_ in await state.pause()},inspect:{try await state.inspect()});XCTFail("Only one absence accepted")}
        catch {XCTAssertTrue(error.localizedDescription.contains("could not be verified"))}
        let counts=await state.counts();XCTAssertEqual(counts,[16,15])
    }
    func testInvalidVerificationBudgetsNeverInspect() async throws {
        for budget in [0,17] {
            let state=DetachObservations([.detached])
            do {try await VaultDetachSettlement.confirm(attempts:budget,inspect:{try await state.inspect()});XCTFail("Unbounded observation budget accepted")}catch {}
            let counts=await state.counts();XCTAssertEqual(counts,[0,0])
        }
    }
    func testIncompleteThenAttachedThenAbsentNeedsFreshConfirmation() async throws {
        let state=DetachObservations([.pending,.pending,.attached,.detached])
        try await VaultDetachSettlement.confirm(pause:{_ in await state.pause()},inspect:{try await state.inspect()})
        let counts=await state.counts();XCTAssertEqual(counts,[5,4])
    }
    func testOneAbsentObservationDoesNotHideAReappearingAttachment() async throws {
        for gap in [DetachObservations.Value.attached,.pending] {
            let state=DetachObservations([.detached,gap,.detached,.detached])
            try await VaultDetachSettlement.confirm(pause:{_ in await state.pause()},inspect:{try await state.inspect()})
            let counts=await state.counts();XCTAssertEqual(counts,[4,3])
        }
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
    func testPrecreatedPathsStillPinPackageEvenWhenSameImageAndManifestMoveToReplacement() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-precreated-detach-"+UUID().uuidString);try Paths.ensure(root);defer {try? FileManager.default.removeItem(at:root)}
        let paths=try VaultPaths(root.appendingPathComponent("Future.oswindvault"))
        try Paths.ensure(paths.package);let info=LibraryVaultInfo(name:"Owned precreated identity",capacityGiB:1,volumeUUID:UUID().uuidString)
        try paths.write(info,as:VaultPaths.manifestName);try Paths.ensure(paths.image);try Data("original image".utf8).write(to:paths.image.appendingPathComponent("keep"))
        let identity=try VaultDetachIdentity(paths:paths,image:BackupFileTree(root:paths.image).identity())
        let moved=root.appendingPathComponent("OriginalPackage");try FileManager.default.moveItem(at:paths.package,to:moved);try Paths.ensure(paths.package)
        // Preserve the image inode and exact manifest. Only the package itself
        // changed; a VaultPaths made before creation has no initial root stamp.
        try FileManager.default.moveItem(at:moved.appendingPathComponent("contents.sparsebundle"),to:paths.image)
        try paths.write(info,as:VaultPaths.manifestName)
        XCTAssertThrowsError(try identity.validate());XCTAssertEqual(try paths.info(),info)
        XCTAssertEqual(try String(contentsOf:paths.image.appendingPathComponent("keep"),encoding:.utf8),"original image")
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

private final class OwnedVaultNativeTrace:@unchecked Sendable {
    struct Item:Codable {let stage:String,event:VaultNativeDiagnostic}
    struct Handle:Codable {let descriptor:Int,path:String?,mounted:Bool}
    struct Boundary:Codable {let stage:String,operation:VaultNativeOperation,mountedDevice:Int32?,ownedHandles:[Handle]}
    struct Report:Codable {let stage:String,failureStage:String?,total:Int,nonzero:Int,dropped:Int,events:[Item],beforeMutations:[Boundary]}
    private let lock=NSLock()
    private let root:URL
    private let rootPrefix:String
    private var stage="create",failureStage:String?,items=[Item](),total=0,nonzero=0,dropped=0
    private var boundaries=[Boundary]()
    init(root:URL) {let canonical=root.resolvingSymlinksInPath();self.root=canonical;rootPrefix=canonical.path.hasSuffix("/") ? canonical.path:canonical.path+"/"}
    func beforeMutation(_ operation:VaultNativeOperation,_ mountedDevice:Int32?) {
        // Inspect this test process's descriptor names only, without reading
        // file contents or retaining unrelated paths. /dev/fd snapshots can
        // race a concurrent close; failed lookups are simply omitted.
        var owned=[Handle]()
        for name in (try? FileManager.default.contentsOfDirectory(atPath:"/dev/fd")) ?? [] {
            guard let descriptor=Int32(name) else {continue}
            var metadata=stat();guard fstat(descriptor,&metadata)==0 else {continue}
            let mounted=mountedDevice.map {$0==metadata.st_dev} ?? false
            var bytes=[CChar](repeating:0,count:Int(MAXPATHLEN))
            let found=bytes.withUnsafeMutableBytes {fcntl(descriptor,F_GETPATH,$0.baseAddress!)}
            let path=found==0 ? String(cString:bytes):nil
            if mounted || path?.hasPrefix(rootPrefix)==true {owned.append(.init(descriptor:Int(descriptor),path:path,mounted:mounted))}
        }
        lock.withLock {if boundaries.count<128 {boundaries.append(.init(stage:stage,operation:operation,mountedDevice:mountedDevice,ownedHandles:owned.sorted {$0.descriptor<$1.descriptor}))}}
    }
    func setStage(_ value:String) {lock.withLock {stage=value}}
    func markFailure() {lock.withLock {failureStage=stage;stage="failure-cleanup"}}
    func append(_ event:VaultNativeDiagnostic) {lock.withLock {total+=1;if event.summary.status != 0 {nonzero+=1};if items.count==512 {items.removeFirst();dropped+=1};items.append(.init(stage:stage,event:event))}}
    func snapshot()->Report {lock.withLock {.init(stage:stage,failureStage:failureStage,total:total,nonzero:nonzero,dropped:dropped,events:items,beforeMutations:boundaries)}}
    static func redactedJSON(_ encoded:Data,roots:[URL],secret:Data)throws->Data {
        guard encoded.range(of:secret)==nil else {throw OSwindError.invalid("Fixture credential appeared in native diagnostic capture")}
        let encoder=JSONEncoder()
        var text=String(decoding:encoded,as:UTF8.self)
        // Match JSON's escaped representation, including /private aliases and
        // quoted/non-ASCII path components. Longer roots must be replaced first.
        for path in Set(roots.map(\.path)).sorted(by:{$0.count==$1.count ? $0<$1:$0.count>$1.count}) {
            let quoted=String(decoding:try encoder.encode(path),as:UTF8.self)
            text=text.replacingOccurrences(of:String(quoted.dropFirst().dropLast()),with:"<owned-fixture>")
        }
        return Data(text.utf8)
    }
    func save(root:URL,secret:Data,failed:Bool)throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let encoded=try encoder.encode(snapshot())
        // Fixture-only observation can contain owned system-tool text. Refuse
        // to print/write any trace containing the generated credential.
        let exported=try Self.redactedJSON(encoded,roots:[root,self.root],secret:secret)
        let text=String(decoding:exported,as:UTF8.self)
        if let destination=ProcessInfo.processInfo.environment["OSWIND_TEST_VAULT_TRACE_DIR"] {
            let directory=URL(fileURLWithPath:destination,isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try Data(text.utf8).write(to:directory.appendingPathComponent(root.lastPathComponent+(failed ? "-exception":"-completed")+".json"),options:.withoutOverwriting)
        }
        if failed || snapshot().nonzero>0 {print("Owned vault native result trace: "+text)}
        else {let s=snapshot();print("Owned vault native trace: calls=\(s.total) nonzero=\(s.nonzero) dropped=\(s.dropped)")}
    }
}
final class OwnedVaultNativeTraceTests:XCTestCase {
    func testEscapedAndCanonicalFixturePathsAreRedactedBeforeExport() throws {
        let roots=["/var/tmp/owned-\"café\"","/private/var/tmp/owned-\"café\""].map {URL(fileURLWithPath:$0)}
        let original=["alias":roots[0].path+"/Library/memory.sqlite","canonical":roots[1].path+"/Library/memory.sqlite","native":"Failure at "+roots[1].path+"/image"]
        let encoded=try JSONEncoder().encode(original)
        let exported=try OwnedVaultNativeTrace.redactedJSON(encoded,roots:roots,secret:Data("fixture-credential".utf8))
        let result=try JSONDecoder().decode([String:String].self,from:exported)
        XCTAssertEqual(result,["alias":"<owned-fixture>/Library/memory.sqlite","canonical":"<owned-fixture>/Library/memory.sqlite","native":"Failure at <owned-fixture>/image"])
        XCTAssertTrue(result.values.allSatisfy {!$0.contains("/var/tmp/")})
    }
    func testCredentialBearingTraceIsRefusedBeforeExport() throws {
        let secret=Data("owned-fixture-secret".utf8),encoded=try JSONEncoder().encode(["diagnostic":"owned-fixture-secret"])
        XCTAssertThrowsError(try OwnedVaultNativeTrace.redactedJSON(encoded,roots:[],secret:secret))
    }
}
final class NativeVaultDetachSettlementTests:XCTestCase {
    func testKnownHeldReaderCapturesBusyExitAndPreservesHistoryUntilNormalRecovery() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned held-reader encrypted-volume fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-detach-held-reader-"+UUID().uuidString);try Paths.ensure(root)
        let trace=OwnedVaultNativeTrace(root:root),driver=NativeVaultDriver(observer:{trace.append($0)},willMutate:{trace.beforeMutation($0,$1)})
        let package=root.appendingPathComponent("Fixture.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package,nativeDriver:driver)
        var activeStore:MemoryStore?,reader:FileHandle?
        do {
            _ = try await LibraryVault.create(at:package,name:"Owned native busy control",capacityGiB:1,passphrase:secret,nativeDriver:driver)
            trace.setStage("held-reader-unlock");_ = try await vault.unlock(passphrase:secret)
            let store=try MemoryStore(root:vault.libraryURL);activeStore=store
            try store.insert(Memory(id:"owned-busy",text:"Owned busy control must survive normal recovery"))
            // A raw owned file handle represents an external reader, outside
            // OSwind's read-lease registry. No user process or file is used.
            reader=try FileHandle(forReadingFrom:vault.libraryURL.appendingPathComponent("memory.sqlite"))
            trace.setStage("expected-held-reader-lock")
            do {_ = try await vault.lock(store:store);XCTFail("A held filesystem reader was force-detached")}
            catch let error as VaultNativeFailure {XCTAssertEqual(error.summary.operation,.imageDetach);XCTAssertEqual(error.summary.status,EBUSY)}
            XCTAssertTrue(store.isClosed);activeStore=nil
            let attached=try await driver.attachment(paths:VaultPaths(package));XCTAssertNotNil(attached);XCTAssertTrue(attached?.mounted == true)
            let paths=try VaultPaths(package);XCTAssertEqual(try paths.session(info:paths.info())?.phase,.closing)
            try reader?.close();reader=nil
            trace.setStage("normal-recovery-lock");let recovered=try await vault.lock();XCTAssertFalse(recovered.imageAttached)
            trace.setStage("verify-preserved-history");_ = try await vault.unlock(passphrase:secret)
            let final=try MemoryStore(root:vault.libraryURL);activeStore=final
            XCTAssertEqual(try final.get("owned-busy")?.text,"Owned busy control must survive normal recovery")
            _ = try await vault.lock(store:final);activeStore=nil
            let busy=trace.snapshot().events.filter {$0.event.summary.operation == .imageDetach && $0.event.summary.status != 0}
            XCTAssertEqual(busy.count,1);XCTAssertTrue(busy.first?.event.stderrSuffix.lowercased().contains("busy") == true)
            let blocked=trace.snapshot().beforeMutations.filter {$0.stage=="expected-held-reader-lock"}
            XCTAssertEqual(blocked.count,1);XCTAssertTrue(blocked[0].ownedHandles.contains {$0.mounted && $0.path?.hasSuffix("/memory.sqlite")==true})
            try trace.save(root:root,secret:secret,failed:false);try FileManager.default.removeItem(at:root)
        } catch {
            let original=error;trace.markFailure();try? reader?.close();try? activeStore?.close();_ = try? await vault.lock()
            do {try trace.save(root:root,secret:secret,failed:true)} catch {print("Owned native trace could not be saved; original failure is preserved")};throw original
        }
    }
    func testRapidNativeLockUnlockKeepsHistoryAndIndependentlyConfirmsNoAttachment() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned rapid encrypted-volume detach fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-detach-settling-"+UUID().uuidString);try Paths.ensure(root)
        let trace=OwnedVaultNativeTrace(root:root),driver=NativeVaultDriver(observer:{trace.append($0)},willMutate:{trace.beforeMutation($0,$1)})
        let package=root.appendingPathComponent("Fixture.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package,nativeDriver:driver)
        var activeStore:MemoryStore?
        do {
            _ = try await LibraryVault.create(at:package,name:"Owned detach settling",capacityGiB:1,passphrase:secret,nativeDriver:driver)
            for iteration in 0..<6 {
                trace.setStage("cycle-\(iteration)-unlock")
                _ = try await vault.unlock(passphrase:secret)
                let store=try MemoryStore(root:vault.libraryURL);activeStore=store
                XCTAssertEqual(try store.stats(includeDiskUsage:false).count,iteration)
                try store.insert(Memory(id:"owned-\(iteration)",text:"Preserved owned detach cycle \(iteration)"))
                trace.setStage("cycle-\(iteration)-lock")
                let locked=try await vault.lock(store:store);XCTAssertTrue(store.isClosed);activeStore=nil
                XCTAssertEqual(locked.state,.locked);XCTAssertFalse(locked.imageAttached);XCTAssertFalse(locked.volumeMounted)
                let inventory=try await VaultProcess.run("/usr/bin/hdiutil",["info","-plist"]);XCTAssertEqual(inventory.status,0)
                let info=try XCTUnwrap(PropertyListSerialization.propertyList(from:inventory.stdout,format:nil) as? [String:Any])
                let images=try XCTUnwrap(info["images"] as? [[String:Any]])
                XCTAssertFalse(images.contains {($0["image-path"] as? String)?.hasPrefix(package.path+"/") == true})
            }
            trace.setStage("final-read-unlock");_ = try await vault.unlock(passphrase:secret)
            let final=try MemoryStore(root:vault.libraryURL);activeStore=final
            XCTAssertEqual(try final.stats(includeDiskUsage:false).count,6)
            for iteration in 0..<6 {XCTAssertEqual(try final.get("owned-\(iteration)")?.text,"Preserved owned detach cycle \(iteration)")}
            trace.setStage("final-lock");_ = try await vault.lock(store:final);activeStore=nil
            XCTAssertTrue(trace.snapshot().beforeMutations.allSatisfy {$0.ownedHandles.allSatisfy {!$0.mounted}},"OSwind retained an owned mounted-file handle before a normal detach")
            try trace.save(root:root,secret:secret,failed:false)
            try FileManager.default.removeItem(at:root)
        } catch {
            let original=error;trace.markFailure();try? activeStore?.close();_ = try? await vault.lock()
            do {try trace.save(root:root,secret:secret,failed:true)} catch {print("Owned native trace could not be saved; original failure is preserved")};throw original
        }
    }
}
