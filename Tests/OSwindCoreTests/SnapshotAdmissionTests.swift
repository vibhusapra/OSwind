import XCTest
import AppKit
import ImageIO
@testable import OSwindCore

private final class SnapshotRecognitionGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"owned recognition entered")
    private let condition=NSCondition()
    private var released=false
    private var cancelled=false
    var sawCancellation:Bool {condition.lock();defer {condition.unlock()};return cancelled}
    func recognize(_ image:CGImage) throws -> [TextRegion] {
        condition.lock();entered.fulfill();let deadline=Date().addingTimeInterval(15)
        while !released {guard condition.wait(until:deadline) else {condition.unlock();throw OSwindError.unavailable("Owned recognition gate timed out")}}
        cancelled=Task.isCancelled;condition.unlock();try Task.checkCancellation()
        return [.init(text:"Owned screen region",x:0.1,y:0.2,width:0.5,height:0.1)]
    }
    func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
}
@MainActor private final class SnapshotWorld {
    var context:WindowContext?=WindowContext(app:"Fixture Browser",bundle:"org.fixture.chrome",pid:8123,title:"Owned public page",url:"https://example.org/page",accessibilityText:"Owned accessible text",secure:false,bounds:CGRect(x:0,y:0,width:480,height:300))
    var locked=false,permitted=true,captured=0
}
@MainActor final class SnapshotAdmissionTests:XCTestCase {
    var root:URL!
    var store:MemoryStore!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-snapshot-owned-"+UUID().uuidString)
        store=try MemoryStore(root:root)
    }
    override func tearDownWithError() throws {try? store.close();try? FileManager.default.removeItem(at:root)}
    func image() throws -> CGImage {
        let context=try XCTUnwrap(CGContext(data:nil,width:480,height:300,bitsPerComponent:8,bytesPerRow:1920,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.2,green:0.4,blue:0.8,alpha:1));context.fill(CGRect(x:0,y:0,width:480,height:300))
        return try XCTUnwrap(context.makeImage())
    }
    private func environment(_ world:SnapshotWorld,frame:SnapshotCaptureFrame)->SnapshotCaptureEnvironment {
        var environment=SnapshotCaptureEnvironment();environment.locked={world.locked};environment.permitted={world.permitted};environment.context={_ in world.context};environment.identityCurrent={context,_ in world.context.map {context.pid==$0.pid && context.bundle==$0.bundle} ?? false}
        environment.frames={_,_ in [frame]};environment.recognize={_ in [.init(text:"Owned screen region",x:0.1,y:0.2,width:0.5,height:0.1)]}
        return environment
    }
    func files() throws -> [String] {try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("images").path)}
    func assertEmpty(_ controller:CaptureController,file:StaticString=#filePath,line:UInt=#line) throws {
        XCTAssertEqual(try store.stats().count,0,file:file,line:line);XCTAssertEqual(try files(),[],file:file,line:line);XCTAssertEqual(controller.metrics.saved,0,file:file,line:line)
    }
    func testPauseAndSettingsDuringInitialContextReadPreventPixelsAndKeepStatus() async throws {
        for pause in [true,false] {
            let world=SnapshotWorld(),bitmap=try image(),entered=XCTestExpectation(description:"Initial context read suspended")
            var resume:CheckedContinuation<WindowContext?,Never>?
            var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{world.captured+=1;return bitmap}))
            environment.context={_ in await withCheckedContinuation {resume=$0;entered.fulfill()}}
            let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
            let attempt=Task {await controller.captureOnce(manual:true)}
            await fulfillment(of:[entered],timeout:5)
            // A second manual capture must defer without starting another read.
            await controller.captureOnce(manual:true)
            if pause {controller.pause()} else {controller.settings.privacy.retainImages=false}
            resume?.resume(returning:world.context);await attempt.value
            try assertEmpty(controller);XCTAssertEqual(world.captured,0)
            if pause {XCTAssertEqual(controller.status,"Paused")}
        }
    }
    func testCancelledOrLockedInitialContextReadCannotStartCapture() async throws {
        for cancel in [true,false] {
            let world=SnapshotWorld(),bitmap=try image(),entered=XCTestExpectation(description:"Initial context read suspended")
            var resume:CheckedContinuation<WindowContext?,Never>?,sawCancellation=false
            var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{world.captured+=1;return bitmap}))
            environment.context={_ in let result=await withCheckedContinuation {resume=$0;entered.fulfill()};sawCancellation=Task.isCancelled;return result}
            let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
            let attempt=Task {await controller.captureOnce(manual:true)}
            await fulfillment(of:[entered],timeout:5)
            if cancel {attempt.cancel()} else {world.locked=true}
            resume?.resume(returning:world.context);await attempt.value
            try assertEmpty(controller);XCTAssertEqual(world.captured,0)
            if cancel {XCTAssertTrue(sawCancellation)}
        }
    }
    func testLastIdentityFenceRemovesWrittenButUnadmittedJPEG() async throws {
        let world=SnapshotWorld(),bitmap=try image();var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap})),checks=0,sawWritten=false
        environment.identityCurrent={_,_ in
            checks+=1
            if checks==6 {sawWritten = (try? self.files().count)==1;return false}
            return true
        }
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        await controller.captureOnce(manual:true);XCTAssertEqual(checks,6);XCTAssertTrue(sawWritten);try assertEmpty(controller)
    }
    func testDisplayScopeRefusesTargetedWindowOverridesBeforeContextOrDevices() async throws {
        let world=SnapshotWorld(),bitmap=try image();var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{XCTFail("Display scope widened to window pixels");return bitmap}));environment.context={_ in XCTFail("Scope rejection reached context");return world.context}
        var settings=AppSettings();settings.allDisplays=true;settings.snapshotRegions.selectedDisplays=[]
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:settings,snapshots:environment)
        await controller.captureOnce(manual:true,targetBundleID:"org.fixture.chrome");try assertEmpty(controller);XCTAssertTrue(controller.status.contains("focused-window mode"))
        do {try await controller.captureReplay(seconds:1);XCTFail("Display scope widened to replay")}catch {XCTAssertTrue(error.localizedDescription.contains("focused-window mode"))}
    }
    func testInvalidAreaBlocksFocusedSnapshotAndReplayBeforeContextOrDevices() async throws {
        let world=SnapshotWorld(),bitmap=try image();var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{XCTFail("Blocked area reached pixels");return bitmap}));environment.context={_ in XCTFail("Blocked area reached context");return world.context}
        var settings=AppSettings();settings.snapshotRegions = .disabled
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:settings,snapshots:environment)
        await controller.captureOnce(manual:true);try assertEmpty(controller);XCTAssertTrue(controller.status.contains("Invalid capture area"))
        do {try await controller.captureReplay(seconds:1);XCTFail("Blocked area reached replay")}catch {XCTAssertTrue(error.localizedDescription.contains("Invalid capture area"))}
    }
    func testRegionFrameNeverMergesFullWindowAccessibilityText() async throws {
        let world=SnapshotWorld(),bitmap=try image();world.context?.accessibilityText="Outside selected region marker"
        var environment=environment(world,frame:.init(display:"owned-crop",title:"Owned",capture:{bitmap},includeAccessibilityText:false))
        environment.recognize={_ in [.init(text:"Inside crop marker",x:0,y:0,width:1,height:1)]}
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        await controller.captureOnce(manual:true)
        let memory=try XCTUnwrap(store.search(SearchFilter(query:"Inside"),mode:.keyword).first?.memory)
        XCTAssertTrue(memory.text.contains("Inside crop marker"));XCTAssertFalse(memory.text.contains("Outside selected region marker"));XCTAssertEqual(try store.search(SearchFilter(query:"Outside"),mode:.keyword).count,0)
    }
    func testRegionChangeDuringRecognitionCancelsPreviousScope() async throws {
        let world=SnapshotWorld(),bitmap=try image(),gate=SnapshotRecognitionGate();var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap}));environment.recognize={try gate.recognize($0)}
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        let attempt=Task {await controller.captureOnce(manual:true)};await fulfillment(of:[gate.entered],timeout:5)
        controller.settings.snapshotRegions.focusedWindowCrop=SnapshotRegion(x:0.5,width:0.5);gate.release();await attempt.value;try assertEmpty(controller);XCTAssertTrue(gate.sawCancellation)
    }
    func testExplicitReplayRefusesConfiguredWindowCropBeforeDevices() async throws {
        var settings=AppSettings();settings.snapshotRegions.focusedWindowCrop=SnapshotRegion(x:0.5,width:0.5)
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:settings)
        do {try await controller.captureReplay(seconds:1);XCTFail("Cropped scope fell through to full-window replay")}catch {XCTAssertTrue(error.localizedDescription.contains("crop"))}
        try assertEmpty(controller)
    }
    func testStableContextAdmitsPrivateJPEGAndUsesPostImageAccessibilityText() async throws {
        let world=SnapshotWorld(),bitmap=try image()
        let frame=SnapshotCaptureFrame(display:"window-owned",title:"Owned public page",capture:{world.captured+=1;world.context?.accessibilityText="Fresh accessible text";return bitmap})
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment(world,frame:frame))
        var callbacks=0;controller.onCapture={_ in callbacks+=1}
        await controller.captureOnce(manual:true)
        XCTAssertEqual(callbacks,1);XCTAssertEqual(world.captured,1);XCTAssertEqual(controller.metrics.saved,1)
        let hit=try XCTUnwrap(store.search(SearchFilter(query:"Fresh"),mode:.keyword).first),memory=hit.memory
        XCTAssertTrue(memory.text.contains("Fresh accessible text"));XCTAssertFalse(memory.text.contains("Owned accessible text"))
        let relative=try XCTUnwrap(memory.imagePath),url=root.appendingPathComponent(relative)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let source=try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil));XCTAssertEqual(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil)).width,480)
    }
    func testLongSourceCallbackWaitsForCapturePassagesBeforeAutomaticCatchupCanStart() async throws {
        let embedder=LocalEmbedder();guard embedder.available else {throw XCTSkip("Local Apple embeddings unavailable; no download")}
        let world=SnapshotWorld(),bitmap=try image();world.context?.accessibilityText=String(repeating:"Owned release checklist and project context. ",count:180)
        var settings=AppSettings();settings.search.indexOnLowPower=true
        let controller=CaptureController(store:store,embedder:embedder,settings:settings,snapshots:environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap})))
        var coverage:Bool?,callbacks=0
        controller.onCapture={memory in callbacks+=1;coverage=try? self.store.passagesCurrent(memory,modelID:embedder.modelID)}
        await controller.captureOnce(manual:true)
        XCTAssertEqual(callbacks,1);XCTAssertEqual(coverage,true);XCTAssertEqual(controller.metrics.saved,1)
    }
    func testPassageFailureKeepsCommittedSourceAndCanRecoverWithoutRecapture() async throws {
        let embedder=LocalEmbedder();guard embedder.available else {throw XCTSkip("Local Apple embeddings unavailable; no download")}
        try store.withRoutineDatabase {try $0.execute("CREATE TRIGGER owned_snapshot_passage_failure BEFORE INSERT ON semantic_passages BEGIN SELECT RAISE(ABORT,'Owned passage failure'); END;")}
        let world=SnapshotWorld(),bitmap=try image();world.context?.accessibilityText=String(repeating:"Owned release checklist and project context. ",count:180)
        var settings=AppSettings();settings.search.indexOnLowPower=true
        let controller=CaptureController(store:store,embedder:embedder,settings:settings,snapshots:environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap})))
        var notified:Memory?;controller.onCapture={notified=$0}
        await controller.captureOnce(manual:true)
        let memory=try XCTUnwrap(notified);XCTAssertNotNil(try store.get(memory.id));XCTAssertNotNil(memory.imagePath)
        XCTAssertEqual(controller.metrics.saved,1);XCTAssertEqual(controller.metrics.errors,1);XCTAssertTrue(controller.status.contains("search indexing pending"))
        XCTAssertFalse(try store.passagesCurrent(memory,modelID:embedder.modelID))
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_snapshot_passage_failure")}
        try store.indexApplePassages(memory,embedder:embedder);XCTAssertTrue(try store.passagesCurrent(memory,modelID:embedder.modelID));XCTAssertEqual(try store.stats().count,1)
    }
    func testSourceCommitFailureRemovesUnadmittedJPEGAndRetrySucceeds() async throws {
        try store.withRoutineDatabase {try $0.execute("CREATE TRIGGER owned_snapshot_admission_failure BEFORE INSERT ON memories BEGIN SELECT RAISE(ABORT,'Owned admission failure'); END;")}
        let world=SnapshotWorld(),bitmap=try image(),controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap})))
        var callbacks=0;controller.onCapture={_ in callbacks+=1}
        await controller.captureOnce(manual:true);try assertEmpty(controller);XCTAssertEqual(callbacks,0);XCTAssertEqual(controller.metrics.errors,1)
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_snapshot_admission_failure")}
        await controller.captureOnce(manual:true);XCTAssertEqual(callbacks,1);XCTAssertEqual(controller.metrics.saved,1);XCTAssertEqual(try files().count,1);XCTAssertEqual(try store.stats().count,1)
    }
    func testContextTransitionWhileDiscoveringSourcesNeverCapturesPixels() async throws {
        let world=SnapshotWorld(),bitmap=try image();var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{world.captured+=1;return bitmap}))
        environment.frames={_,_ in world.context?.url="https://accounts.google.com/private";await Task.yield();return [.init(display:"owned",title:"Owned",capture:{world.captured+=1;return bitmap})]}
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        await controller.captureOnce(manual:true);try assertEmpty(controller);XCTAssertEqual(world.captured,0)
    }
    func testEveryIdentityPrivacyAndPermissionChangeAfterPixelAcquisitionDiscards() async throws {
        let changes:[(SnapshotWorld)->Void]=[
            {$0.context=nil},{$0.context?.pid+=1},{$0.context?.bundle="org.different.app"},{$0.context?.title="Other page"},
            {$0.context?.url="https://example.org/different-allowed-page"},{$0.context?.url="https://accounts.google.com/private"},
            {$0.context?.secure=true},{$0.context?.bounds?.size.width+=10},{$0.context?.bounds=nil},{$0.permitted=false},{$0.locked=true}
        ]
        for change in changes {
            let world=SnapshotWorld(),bitmap=try image()
            let frame=SnapshotCaptureFrame(display:"owned",title:"Owned",capture:{world.captured+=1;change(world);await Task.yield();return bitmap})
            var environment=environment(world,frame:frame);environment.recognize={_ in XCTFail("Changed context reached recognition");return []}
            let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
            await controller.captureOnce(manual:true);try assertEmpty(controller);XCTAssertEqual(world.captured,1)
        }
    }
    func testContextChangeDuringRecognitionNeverWritesRawImageOrSource() async throws {
        let world=SnapshotWorld(),bitmap=try image(),gate=SnapshotRecognitionGate()
        var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap}));environment.recognize={try gate.recognize($0)}
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        let task=Task {await controller.captureOnce(manual:true)}
        await fulfillment(of:[gate.entered],timeout:10);world.context?.secure=true
        XCTAssertEqual(try files(),[]);gate.release();await task.value;try assertEmpty(controller)
    }
    func testPauseAndChangedSettingsDuringRecognitionDiscardLateResult() async throws {
        for pause in [true,false] {
            let world=SnapshotWorld(),bitmap=try image(),gate=SnapshotRecognitionGate()
            var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap}));environment.recognize={try gate.recognize($0)}
            let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
            let task=Task {await controller.captureOnce(manual:true)}
            await fulfillment(of:[gate.entered],timeout:10)
            if pause {controller.pause()} else {controller.settings.privacy.retainImages=false}
            gate.release();await task.value;try assertEmpty(controller)
            XCTAssertTrue(gate.sawCancellation)
            if pause {XCTAssertEqual(controller.status,"Paused")}
        }
    }
    func testCancellationWaitsForRecognitionAndCannotPublishLateResult() async throws {
        let world=SnapshotWorld(),bitmap=try image(),gate=SnapshotRecognitionGate()
        var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap}));environment.recognize={try gate.recognize($0)}
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        var completed=false;let task=Task {await controller.captureOnce(manual:true);completed=true}
        await fulfillment(of:[gate.entered],timeout:10);task.cancel();try await Task.sleep(for:.milliseconds(30));XCTAssertFalse(completed)
        gate.release();await task.value;XCTAssertTrue(completed);try assertEmpty(controller)
    }
    func testClosedLibraryCannotReceiveDelayedScreenshot() async throws {
        let world=SnapshotWorld(),bitmap=try image(),gate=SnapshotRecognitionGate()
        var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap}));environment.recognize={try gate.recognize($0)}
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        let task=Task {await controller.captureOnce(manual:true)}
        await fulfillment(of:[gate.entered],timeout:10);try store.close();gate.release();await task.value
        XCTAssertEqual(try files(),[]);XCTAssertEqual(controller.metrics.saved,0)
        let reopened=try MemoryStore(root:root);defer {try? reopened.close()};XCTAssertEqual(try reopened.stats().count,0)
    }
    func testReplacedLibraryRootNeverWritesForeignDirectory() async throws {
        let world=SnapshotWorld(),bitmap=try image(),gate=SnapshotRecognitionGate()
        var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap}));environment.recognize={try gate.recognize($0)}
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        let moved=root.appendingPathExtension("retained-owned");defer {try? store.close();try? FileManager.default.removeItem(at:moved)}
        let task=Task {await controller.captureOnce(manual:true)}
        await fulfillment(of:[gate.entered],timeout:10)
        try FileManager.default.moveItem(at:root,to:moved);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        let marker=root.appendingPathComponent("keep");try Data("Keep".utf8).write(to:marker)
        gate.release();await task.value;XCTAssertEqual(controller.metrics.saved,0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["keep"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:moved.appendingPathComponent("images").path),[])
    }
    func testUnshareableFocusedSourceDefersWithoutAnErrorOrFallback() async throws {
        let world=SnapshotWorld(),bitmap=try image();var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{world.captured+=1;return bitmap}))
        environment.frames={_,_ in throw SnapshotCaptureDeferral(reason:"Waiting for an unambiguous focused window")}
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        await controller.captureOnce(manual:true);try assertEmpty(controller);XCTAssertEqual(world.captured,0);XCTAssertEqual(controller.metrics.errors,0);XCTAssertTrue(controller.status.contains("Waiting"))
    }
    func testNewBackgroundExclusionAfterRecognitionDiscardsEvenWithStableForeground() async throws {
        let world=SnapshotWorld(),bitmap=try image(),gate=SnapshotRecognitionGate();var masked=true
        let frame=SnapshotCaptureFrame(display:"display-owned",title:"Display owned",capture:{bitmap},privacyStillMasked:{masked})
        var environment=environment(world,frame:frame);environment.recognize={try gate.recognize($0)}
        var settings=AppSettings();settings.allDisplays=true
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:settings,snapshots:environment)
        let task=Task {await controller.captureOnce(manual:true)}
        await fulfillment(of:[gate.entered],timeout:10);masked=false;gate.release();await task.value;try assertEmpty(controller)
    }
    func testSecretRecognitionSuppressesJPEGAndRegionText() async throws {
        let world=SnapshotWorld(),bitmap=try image()
        var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap}))
        environment.recognize={_ in [.init(text:"password=owned-secret",x:0,y:0,width:1,height:1)]}
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        await controller.captureOnce(manual:true)
        let memory=try XCTUnwrap(store.search(SearchFilter(),mode:.keyword).first?.memory)
        XCTAssertTrue(memory.text.contains("[REDACTED]"));XCTAssertFalse(memory.text.contains("owned-secret"));XCTAssertNil(memory.imagePath);XCTAssertEqual(memory.regions,[]);XCTAssertEqual(try files(),[])
    }
    func testNativeVisionProcessingRunsOnOwnedPixelsWithoutDeviceAccess() async throws {
        let world=SnapshotWorld(),bitmap=try image();var environment=environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap}))
        environment.recognize=SnapshotCaptureEnvironment().recognize
        let controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment)
        await controller.captureOnce(manual:true);XCTAssertEqual(controller.metrics.saved,1);XCTAssertEqual(try files().count,1)
    }
    func testNativeVaultSnapshotAdmissionAndCancelledWorkPermitVerifiedDetach() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned encrypted snapshot fixture; no normal history or Keychain")}
        let package=root.appendingPathComponent("Owned.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        var live:MemoryStore?
        do {
            _ = try await LibraryVault.create(at:package,name:"Owned snapshot fixture",capacityGiB:1,passphrase:secret)
            _ = try await vault.unlock(passphrase:secret);let encrypted=try MemoryStore(root:vault.libraryURL);live=encrypted
            let world=SnapshotWorld(),bitmap=try image(),frame=SnapshotCaptureFrame(display:"owned",title:"Owned",capture:{bitmap})
            let first=CaptureController(store:encrypted,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment(world,frame:frame))
            await first.captureOnce(manual:true);XCTAssertEqual(first.metrics.saved,1)
            let memory=try XCTUnwrap(encrypted.search(SearchFilter(),mode:.keyword).first?.memory),path=try XCTUnwrap(memory.imagePath)
            let bytes=try Data(contentsOf:encrypted.root.appendingPathComponent(path));XCTAssertEqual(Array(bytes.prefix(2)),[255,216])
            let gate=SnapshotRecognitionGate();var delayed=environment(world,frame:frame);delayed.recognize={try gate.recognize($0)}
            let second=CaptureController(store:encrypted,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:delayed)
            let capture=Task {await second.captureOnce(manual:true)}
            await fulfillment(of:[gate.entered],timeout:10);second.pause(discardReplay:true);gate.release();await capture.value
            XCTAssertEqual(second.metrics.saved,0);XCTAssertEqual(try encrypted.stats().count,1)
            let locked=try await vault.lock(store:encrypted);XCTAssertEqual(locked.state,.locked);XCTAssertTrue(encrypted.isClosed)
            let attachment=try await NativeVaultDriver().attachment(paths:VaultPaths(package));XCTAssertNil(attachment)
            _ = try await vault.unlock(passphrase:secret);let reopened=try MemoryStore(root:vault.libraryURL);live=reopened
            XCTAssertEqual(try reopened.stats().count,1);XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:reopened.root.appendingPathComponent("images").path).count,1)
            _ = try await vault.lock(store:reopened)
        } catch {try? live?.close();_ = try? await vault.lock();throw error}
    }
    func testSymlinkedImageDirectoryCannotWriteToAnotherDirectory() async throws {
        let outside=root.appendingPathComponent("owned-outside");try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false)
        let marker=outside.appendingPathComponent("keep");try Data("Keep".utf8).write(to:marker)
        let images=root.appendingPathComponent("images");try FileManager.default.removeItem(at:images);try FileManager.default.createSymbolicLink(at:images,withDestinationURL:outside)
        let world=SnapshotWorld(),bitmap=try image(),controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:AppSettings(),snapshots:environment(world,frame:.init(display:"owned",title:"Owned",capture:{bitmap})))
        await controller.captureOnce(manual:true)
        XCTAssertEqual(try store.stats().count,0);XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:outside.path),["keep"]);XCTAssertEqual(try Data(contentsOf:marker),Data("Keep".utf8))
    }
}

final class SnapshotDisplayPrivacyTests:XCTestCase {
    func testWholeApplicationMaskIncludesBrowserCaseInsensitiveAppAndBackgroundTitle() {
        let chrome=DisplayPrivacyApplication(pid:1,bundle:"org.fixture.Chrome"),notes=DisplayPrivacyApplication(pid:2,bundle:"org.fixture.notes"),excluded=DisplayPrivacyApplication(pid:3,bundle:"ORG.FIXTURE.EXCLUDED"),safe=DisplayPrivacyApplication(pid:4,bundle:"org.fixture.safe")
        var policy=PrivacyPolicy();policy.excludedApps=["org.fixture.excluded"];policy.excludedTitles=["private ledger"]
        let apps=[chrome,notes,excluded,safe],windows=[DisplayPrivacyWindow(application:notes,title:"PRIVATE LEDGER — owned")]
        XCTAssertEqual(SnapshotDisplayPrivacy.blocked(apps,windows:windows,policy:policy,ownBundle:nil),Set([chrome,notes,excluded]))
        XCTAssertTrue(SnapshotDisplayPrivacy.blocked([],windows:windows,policy:policy,ownBundle:nil).contains(notes))
        let original=SnapshotDisplayPrivacy.blocked(apps,windows:[],policy:policy,ownBundle:nil)
        XCTAssertFalse(SnapshotDisplayPrivacy.blocked(apps,windows:windows,policy:policy,ownBundle:nil).isSubset(of:original))
        XCTAssertTrue(SnapshotDisplayPrivacy.blocked(apps,windows:windows,policy:policy,ownBundle:nil).isSubset(of:Set(apps)))
        XCTAssertTrue(SnapshotDisplayPrivacy.hasUnmaskableWindow([.init(application:nil,title:"Private ledger")],policy:policy))
        XCTAssertFalse(SnapshotDisplayPrivacy.hasUnmaskableWindow([.init(application:nil,title:"Ordinary window")],policy:policy))
    }
}
