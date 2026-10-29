import XCTest
import AppKit
@testable import OSwindCore

@MainActor private final class TextCaptureWorld {
    var locked=false,permitted=true,idle=0.0,reads=0
    var targets=[String?]()
    var context:WindowContext?=WindowContext(app:"Owned browser",bundle:"org.oswind.fixture.chrome",pid:8123,title:"Owned page",url:"https://example.org/page",accessibilityText:"Maya owns the Friday release checklist.",secure:false,bounds:CGRect(x:10,y:20,width:600,height:400))
    func environment()->SnapshotCaptureEnvironment {
        var e=SnapshotCaptureEnvironment()
        e.locked={self.locked};e.accessibilityPermitted={self.permitted};e.idleSeconds={self.idle}
        e.permitted={XCTFail("Text-only path checked Screen Recording");return false}
        e.frames={_,_ in XCTFail("Text-only path enumerated screen sources");return []}
        e.recognize={_ in XCTFail("Text-only path invoked OCR");return []}
        e.context={target in self.reads+=1;self.targets.append(target);return self.context}
        e.identityCurrent={context,target in self.context.map {context.pid==$0.pid && context.bundle==$0.bundle && (target==nil || target==context.bundle)} ?? false}
        e.textCommitPermitted={true};e.textEmbedding={_,_ in nil}
        return e
    }
}
private final class TextPreparationGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"text embedding suspended off main actor")
    private let condition=NSCondition()
    private var released=false
    private(set) var onMain=false,sawCancellation=false
    func embed() throws -> [Float]? {
        condition.lock();onMain=Thread.isMainThread;entered.fulfill();let deadline=Date().addingTimeInterval(10)
        while !released {guard condition.wait(until:deadline) else {condition.unlock();throw OSwindError.unavailable("Owned preparation gate timed out")}}
        sawCancellation=Task.isCancelled;condition.unlock();try Task.checkCancellation();return nil
    }
    func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
}
private final class TextCompletion:@unchecked Sendable {
    private let lock=NSLock();private var value=false
    var complete:Bool {lock.lock();defer {lock.unlock()};return value}
    func finish(){lock.lock();value=true;lock.unlock()}
}
private final class TextEmbeddingCounter:@unchecked Sendable {
    private let lock=NSLock();private var value=0
    var count:Int {lock.lock();defer {lock.unlock()};return value}
    func increment(){lock.lock();value+=1;lock.unlock()}
}
@MainActor final class AccessibilityTextCaptureTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-ax-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {try? store.close();try? FileManager.default.removeItem(at:root)}
    private func configuration()->AppSettings {var s=AppSettings();s.visualCaptureMode = .accessibility;s.profile = .light;return s}
    private func controller(_ world:TextCaptureWorld,settings:AppSettings?=nil,environment:SnapshotCaptureEnvironment?=nil)throws->CaptureController {
        let s=settings ?? configuration();try s.save(root:root)
        return CaptureController(store:store,embedder:LocalEmbedder(),settings:s,snapshots:environment ?? world.environment())
    }
    private func assertNoMedia(file:StaticString=#filePath,line:UInt=#line) throws {
        for folder in ["images","audio","video"] {XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent(folder).path),[],file:file,line:line)}
    }
    private func empty(_ c:CaptureController,file:StaticString=#filePath,line:UInt=#line)throws {
        XCTAssertEqual(try store.stats().count,0,file:file,line:line);XCTAssertEqual(c.metrics.saved,0,file:file,line:line);try assertNoMedia(file:file,line:line)
    }
    func testTextOnlyAdmitsSearchableSourceWithoutScreenPermissionPixelsOCRorMedia() async throws {
        let world=TextCaptureWorld(),c=try controller(world);var callback:Memory?
        c.onCapture={callback=$0};await c.captureOnce(manual:true)
        let memory=try XCTUnwrap(callback);XCTAssertEqual(memory.text,world.context?.accessibilityText);XCTAssertEqual(memory.title,"Owned page");XCTAssertEqual(memory.display,AccessibilityCaptureRecord.display)
        XCTAssertEqual(memory.kind,.screen);XCTAssertTrue(memory.regions.isEmpty);XCTAssertNil(memory.imagePath);XCTAssertNil(memory.videoPath);XCTAssertNil(memory.audioPath)
        XCTAssertNil(memory.visualRecording);XCTAssertNil(memory.transcript);XCTAssertEqual(c.metrics.saved,1);XCTAssertEqual(c.metrics.errors,0);XCTAssertEqual(world.reads,2)
        XCTAssertEqual(try store.search(SearchFilter(query:"Friday"),mode:.keyword).first?.memory.id,memory.id)
        XCTAssertEqual(try store.piiScanStatus(memory.id).state,.notRecorded);try assertNoMedia()
    }
    func testExplicitTextOnlyStartNeedsAccessibilityAndNeverChecksPixelPermission() async throws {
        let world=TextCaptureWorld();world.permitted=false
        let c=try controller(world);c.start();XCTAssertFalse(c.running);XCTAssertTrue(c.status.contains("Accessibility"));XCTAssertEqual(world.reads,0)
        world.permitted=true;let saved=XCTestExpectation(description:"automatic text capture saved");c.onCapture={_ in saved.fulfill()}
        c.start();defer {c.pause()};await fulfillment(of:[saved],timeout:10);XCTAssertTrue(c.running);XCTAssertEqual(c.metrics.saved,1);try assertNoMedia()
    }
    func testLockedDeniedOrIdleContextNeverStartsAnAXRead() async throws {
        for kind in 0..<3 {
            let world=TextCaptureWorld(),c=try controller(world)
            if kind==0 {world.locked=true;await c.captureOnce(manual:true)}
            if kind==1 {world.permitted=false;await c.captureOnce(manual:true)}
            if kind==2 {world.idle=121;c.start();await Task.yield();await c.captureOnce();c.pause()}
            try empty(c);XCTAssertEqual(world.reads,0)
        }
    }
    func testInvalidAreaDisplayOrCropCannotFallThroughToWholeWindowText() async throws {
        for kind in 0..<3 {
            let world=TextCaptureWorld();var s=configuration()
            if kind==0 {s.snapshotRegions = .disabled};if kind==1 {s.allDisplays=true};if kind==2 {s.snapshotRegions.focusedWindowCrop=SnapshotRegion(x:0.5,width:0.5)}
            let c=try controller(world,settings:s);await c.captureOnce(manual:true);try empty(c);XCTAssertEqual(world.reads,0)
        }
    }
    func testTextOnlyExplicitReplayRefusesBeforeAnyPixelDevicePath() async throws {
        let world=TextCaptureWorld(),c=try controller(world)
        do {try await c.captureReplay(seconds:1);XCTFail("Text-only mode reached replay")}catch {XCTAssertTrue(error.localizedDescription.contains("Text-only"))}
        try empty(c);XCTAssertEqual(world.reads,0)
    }
    func testMissingUnsavedOrMalformedSettingsDoNotAdmitAnInMemoryTextPolicy() async throws {
        let world=TextCaptureWorld(),s=configuration(),c=CaptureController(store:store,embedder:LocalEmbedder(),settings:s,snapshots:world.environment())
        await c.captureOnce(manual:true);try empty(c);XCTAssertEqual(world.reads,0);XCTAssertTrue(c.status.contains("Save"))
        let file=root.appendingPathComponent("settings.json");try Data("malformed".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        await c.captureOnce(manual:true);try empty(c);XCTAssertEqual(world.reads,0);XCTAssertTrue(c.status.contains("malformed"))
    }
    func testProtectedExcludedMissingURLAndOwnContextsNeverReachPreparation() async throws {
        for kind in 0..<6 {
            let world=TextCaptureWorld()
            switch kind {
            case 0:world.context?.secure=true
            case 1:world.context?.bundle="com.apple.Passwords"
            case 2:world.context?.title="Incognito owned page"
            case 3:world.context?.url="https://accounts.google.com/owned"
            case 4:world.context?.url=nil
            default:world.context?.bundle="com.oswind.desktop"
            }
            var e=world.environment();e.textEmbedding={_,_ in XCTFail("Excluded context reached model preparation");return nil}
            let c=try controller(world,environment:e);await c.captureOnce(manual:true);try empty(c)
        }
    }
    func testEmptyAccessibleTextDoesNotInventATitleOnlySource() async throws {
        let world=TextCaptureWorld();world.context?.accessibilityText=" \n\t "
        let c=try controller(world);await c.captureOnce(manual:true);try empty(c);XCTAssertTrue(c.status.contains("No accessible"));XCTAssertEqual(c.metrics.errors,0)
    }
    func testPatternMasksCoverAccessibleTextAndTitleWithoutRetainingRawMedia() async throws {
        let world=TextCaptureWorld();world.context?.accessibilityText="Owned public text password=synthetic-value";world.context?.title="Owned secret=synthetic-title"
        let c=try controller(world);await c.captureOnce(manual:true)
        let memory=try XCTUnwrap(store.search(SearchFilter(query:"public"),mode:.keyword).first?.memory)
        XCTAssertFalse(memory.text.contains("synthetic-value"));XCTAssertFalse(memory.title.contains("synthetic-title"));XCTAssertTrue(memory.text.contains("[REDACTED]"));try assertNoMedia()
    }
    func testOversizedContextRefusesBeforeEmbeddings() async throws {
        let world=TextCaptureWorld();world.context?.accessibilityText=String(repeating:"a",count:16001)
        var e=world.environment();e.textEmbedding={_,_ in XCTFail("Oversized text reached embeddings");return nil}
        let c=try controller(world,environment:e);await c.captureOnce(manual:true);try empty(c);XCTAssertEqual(c.metrics.errors,1)
    }
    func testPauseAndPrivacyChangeDuringInitialReadJoinAndDiscardLateContext() async throws {
        for changePrivacy in [false,true] {
            let world=TextCaptureWorld(),entered=XCTestExpectation(description:"first text read suspended");var resolve:CheckedContinuation<WindowContext?,Never>?
            var e=world.environment();e.context={_ in world.reads+=1;return await withCheckedContinuation {resolve=$0;entered.fulfill()}}
            let c=try controller(world,environment:e),task=Task {await c.captureOnce(manual:true)}
            await fulfillment(of:[entered],timeout:5)
            if changePrivacy {c.settings.privacy.retainImages=false}else {c.pause()}
            resolve?.resume(returning:world.context);await task.value;try empty(c)
        }
    }
    func testCancellationDuringEmbeddingIsJoinedOffMainActorWithoutPublishing() async throws {
        let world=TextCaptureWorld(),gate=TextPreparationGate();var e=world.environment();e.textEmbedding={_,_ in try gate.embed()}
        let c=try controller(world,environment:e),task=Task {await c.captureOnce(manual:true)}
        await fulfillment(of:[gate.entered],timeout:5);task.cancel();gate.release();await task.value
        XCTAssertTrue(gate.sawCancellation);XCTAssertFalse(gate.onMain);try empty(c)
    }
    func testFinalPrivacyIdentityAndPermissionChangesDiscardPreparedText() async throws {
        for change in 0..<6 {
            let world=TextCaptureWorld();var e=world.environment()
            e.context={_ in
                world.reads+=1
                if world.reads==2 {
                    switch change {case 0:world.context?.secure=true;case 1:world.context?.url="https://accounts.google.com/owned";case 2:world.context?.title="Other window";case 3:world.context?.pid=9123;case 4:world.permitted=false;default:world.locked=true}
                }
                return world.context
            }
            let c=try controller(world,environment:e);await c.captureOnce(manual:true);try empty(c)
        }
    }
    func testCommitPermissionGuardRefusesAContextThatLostAccessAfterFinalObservation() async throws {
        let world=TextCaptureWorld();var e=world.environment();e.textCommitPermitted={false}
        let c=try controller(world,environment:e);await c.captureOnce(manual:true);try empty(c);XCTAssertEqual(world.reads,2)
    }
    func testAtomicIdenticalSettingsReplacementDuringPreparationRefusesAdmission() async throws {
        let world=TextCaptureWorld(),entered=XCTestExpectation(description:"final text context suspended");var resolve:CheckedContinuation<WindowContext?,Never>?
        var e=world.environment();e.context={_ in world.reads+=1;if world.reads==2 {return await withCheckedContinuation {resolve=$0;entered.fulfill()}};return world.context}
        let s=configuration(),c=try controller(world,settings:s,environment:e),task=Task {await c.captureOnce(manual:true)}
        await fulfillment(of:[entered],timeout:5);try s.save(root:root);resolve?.resume(returning:world.context);await task.value
        try empty(c);XCTAssertTrue(c.status.contains("Saved settings changed"))
    }
    func testRootReplacementDuringObservationDoesNotWriteIntoEitherLibrary() async throws {
        let world=TextCaptureWorld(),entered=XCTestExpectation(description:"text read before root replacement");var resolve:CheckedContinuation<WindowContext?,Never>?
        var e=world.environment();e.context={_ in world.reads+=1;if world.reads==1 {return await withCheckedContinuation {resolve=$0;entered.fulfill()}};return world.context}
        let c=try controller(world,environment:e),task=Task {await c.captureOnce(manual:true)},moved=root.deletingLastPathComponent().appendingPathComponent("oswind-displaced-ax-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:moved)}
        await fulfillment(of:[entered],timeout:5);try FileManager.default.moveItem(at:root,to:moved);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        resolve?.resume(returning:world.context);await task.value
        XCTAssertEqual(try store.stats().count,0);XCTAssertEqual(c.metrics.saved,0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),[])
        try FileManager.default.removeItem(at:root);try FileManager.default.moveItem(at:moved,to:root)
    }
    func testCancellationWhileWaitingForActivityNeverStartsContextAndReleasesItsRequest() async throws {
        let world=TextCaptureWorld(),c=try controller(world),exclusive=try MediaAdmissionLease.acquire(root:root,exclusive:true)
        let task=Task {await c.captureOnce(manual:true)}
        await Task.yield();task.cancel();await task.value;exclusive.release();try empty(c);XCTAssertEqual(world.reads,0)
        try store.close();XCTAssertTrue(store.isClosed)
    }
    func testReservationOrdersActualWipeAfterPendingTextAndLeavesNoLateSource() async throws {
        let world=TextCaptureWorld(),entered=XCTestExpectation(description:"AX read holds activity"),waiting=XCTestExpectation(description:"wipe waiting on activity")
        var resolve:CheckedContinuation<WindowContext?,Never>?,e=world.environment()
        e.context={_ in world.reads+=1;if world.reads==1 {return await withCheckedContinuation {resolve=$0;entered.fulfill()}};return world.context}
        let c=try controller(world,environment:e),capture=Task {await c.captureOnce(manual:true)}
        await fulfillment(of:[entered],timeout:5)
        let sourceStore=store!,complete=TextCompletion(),wipe=Task.detached {let result=try sourceStore.wipeLibrary {p in if p.phase=="Waiting for active media writers" {waiting.fulfill()}};complete.finish();return result}
        await fulfillment(of:[waiting],timeout:5);XCTAssertFalse(complete.complete)
        resolve?.resume(returning:world.context);await capture.value;let result=try await wipe.value
        XCTAssertEqual(c.metrics.saved,1);XCTAssertEqual(result.erasure.sources,1);XCTAssertEqual(try store.stats().count,0);try assertNoMedia()
    }
    func testAutomaticDedupeKeepsOneSourceButDeletionAndManualCaptureAreNotSuppressed() async throws {
        let world=TextCaptureWorld(),c=try controller(world),saved=XCTestExpectation(description:"first automatic source")
        var first:Memory?;c.onCapture={m in if first==nil {first=m;saved.fulfill()}}
        c.start();defer {c.pause()};await fulfillment(of:[saved],timeout:10)
        await c.captureOnce();XCTAssertEqual(c.metrics.unchanged,1);XCTAssertEqual(try store.stats().count,1)
        try store.delete(try XCTUnwrap(first).id);await c.captureOnce();XCTAssertEqual(c.metrics.saved,2);XCTAssertEqual(try store.stats().count,1)
        await c.captureOnce(manual:true);XCTAssertEqual(c.metrics.saved,3);XCTAssertEqual(try store.stats().count,2);try assertNoMedia()
    }
    func testRepeatedAndChangedTextUseBoundedSingleSourceDedupeAndNoPixels() async throws {
        let world=TextCaptureWorld(),counter=TextEmbeddingCounter();var e=world.environment()
        e.textEmbedding={text,embedder in counter.increment();return embedder.embed(text)}
        let c=try controller(world,environment:e),saved=XCTestExpectation(description:"initial duty fixture saved");var signaled=false
        c.onCapture={_ in if !signaled {signaled=true;saved.fulfill()}}
        c.start();defer {c.pause()};await fulfillment(of:[saved],timeout:10)
        for _ in 1..<100 {await c.captureOnce()}
        XCTAssertEqual(try store.stats().count,1);XCTAssertEqual(c.metrics.unchanged,99);XCTAssertEqual(world.reads,101);XCTAssertEqual(counter.count,1)
        print("AX_TEXT_DUTY repeated attempts=100 sources=1 fullReads=101 sourceEmbeddingRequests=1 mediaFiles=0")
        let firstReads=world.reads,firstRequests=counter.count
        for i in 0..<10 {world.context?.accessibilityText="Owned changing duty source \(i)";await c.captureOnce()}
        XCTAssertEqual(try store.stats().count,11);XCTAssertEqual(world.reads-firstReads,20);XCTAssertEqual(counter.count-firstRequests,10);try assertNoMedia()
        print("AX_TEXT_DUTY changed attempts=10 sources=10 fullReads=20 sourceEmbeddingRequests=10 mediaFiles=0")
    }
    func testTargetDoesNotFallbackToDifferentApplication() async throws {
        let world=TextCaptureWorld(),c=try controller(world)
        await c.captureOnce(manual:true,targetBundleID:"org.absent.owned");try empty(c);XCTAssertEqual(world.targets,["org.absent.owned"])
    }
    func testModeRoundTripQuietBackupAndFutureModeFailureKeepCaptureScope() async throws {
        let s=configuration();try s.save(root:root);XCTAssertEqual(AppSettings.load(root:root).visualCaptureMode,.accessibility)
        let world=TextCaptureWorld(),c=try controller(world);await c.captureOnce(manual:true)
        let backup=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".oswindbackup"),restored=root.deletingLastPathComponent().appendingPathComponent("oswind-restored-ax-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:backup);try? FileManager.default.removeItem(at:restored)}
        _=try LibraryBackup.create(store:store,destination:backup)
        _=try LibraryBackup.restore(backup,to:restored)
        let quiet=AppSettings.load(root:restored);XCTAssertEqual(quiet.visualCaptureMode,.accessibility);XCTAssertFalse(quiet.captureOnLaunch);XCTAssertFalse(quiet.apiEnabled)
        let file=root.appendingPathComponent("settings.json");try Data(#"{"visualCaptureMode":"unknown-future-mode","captureOnLaunch":true}"#.utf8).write(to:file)
        let future=AppSettings.load(root:root);XCTAssertFalse(future.snapshotRegions.valid);XCTAssertFalse(future.captureOnLaunch)
    }
}
