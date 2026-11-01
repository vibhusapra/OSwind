import XCTest
import AppKit
@testable import OSwind
@testable import OSwindCore

@MainActor final class ClipboardWorkspaceTests:XCTestCase {
    var root:URL!,app:AppModel!,fixture:ClipboardOwnedFixture!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-clipboard-app-"+UUID().uuidString);fixture=ClipboardOwnedFixture();let fixture=self.fixture!
        let reader=ClipboardReader(probe:{await fixture.probe()},read:{count,_ in await fixture.read(count)})
        app=try AppModel(root:root,startServices:false,clipboardSetup:{store,settings in
            ClipboardContextModel(store:store,settings:settings,reader:reader,context:{.init(app:"Owned editor",bundle:"org.oswind.owned-editor",pid:123,title:"Marigold plan",url:nil,accessibilityText:"",secure:false)},locked:{false},idle:{false},limited:{false},schedulesTimers:false,workspaceNotifications:NotificationCenter())
        });app.showOnboarding=false;app.settings.clipboard.enabled=true
    }
    override func tearDown()async throws {
        await fixture.release();app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();try? FileManager.default.removeItem(at:root);app=nil
    }
    func wait(_ condition:@escaping @MainActor ()->Bool)async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(5));while !condition() {guard ContinuousClock.now<end else {XCTFail("Owned clipboard workspace did not settle");return};try await Task.sleep(for:.milliseconds(5))}
    }
    func settle()async throws {try await wait {[self] in !app.clipboard.busy}}
    func start()async throws {app.clipboard.start();try await settle()}
    func observe()async throws {await fixture.change(8);app.clipboard.poll();try await settle()}
    func plainSession()async throws->AppSession {
        let bootstrap=root.appendingPathComponent("bootstrap"),session=AppSession(selection:.init(url:bootstrap,requiresExisting:false,origin:"owned clipboard session"),defaults:UserDefaults(suiteName:"oswind-owned-clipboard-session-"+UUID().uuidString)!,locked:{false})
        try await wait {session.model != nil && !session.busy}
        if let initial=session.model {initial.prepareForLibrarySwitch();await initial.cancelExternalWorkAndWait();try initial.store.close()}
        session.model=app;return session
    }
    func testActualAdmissionSavesSearchableTextWithoutMedia()async throws {
        try await start();XCTAssertEqual(try app.store.stats().count,0);try await observe()
        let hits=try app.store.search(SearchFilter(query:"Marigold")),saved=try XCTUnwrap(hits.first?.memory)
        XCTAssertEqual(hits.count,1);XCTAssertEqual(saved.kind,.note);XCTAssertEqual(saved.bundleID,"org.oswind.owned-editor");XCTAssertTrue(saved.text.contains("Clipboard origin is not verified"))
        XCTAssertNil(saved.imagePath);XCTAssertNil(saved.audioPath);XCTAssertNil(saved.videoPath);XCTAssertNil(saved.visualRecording)
        app.openMemory(saved,query:"Marigold");try await wait {[self] in app.openingMemoryID==nil};XCTAssertEqual(app.selected?.id,saved.id)
    }
    func testDisableDuringActualPreparationRefusesSourcePublication()async throws {
        try await start();let barrier=MCPAdmissionBarrier();defer {barrier.release()}
        app.clipboard.saveSource={[unowned self] draft in try await self.app.saveClipboardResult(draft,observeWorker:{if $0 == .settingsCaptured {try barrier.hold()}})}
        await fixture.change(8);app.clipboard.poll();try await wait {barrier.waiting};app.configureClipboard(false);barrier.release();try await settle()
        XCTAssertEqual(try app.store.stats().count,0);XCTAssertEqual(app.clipboard.saved,0);XCTAssertFalse(app.clipboard.running)
    }
    func testClipboardOnlyGlobalPauseResumeDoesNotStartScreenCaptureOrBackfill()async throws {
        try await start();XCTAssertFalse(app.isCapturing);XCTAssertTrue(app.hasPausableWork);app.toggleCapture();await app.clipboard.cancelAndWait()
        XCTAssertFalse(app.capture.running);XCTAssertFalse(app.clipboard.running);await fixture.change(8);app.toggleCapture();try await settle()
        XCTAssertTrue(app.clipboard.running);XCTAssertFalse(app.capture.running);let counts=await fixture.counts();XCTAssertEqual(counts.reads,0);XCTAssertEqual(try app.store.stats().count,0)
    }
    func testPlainQuitWaitsForActualClipboardPreparation()async throws {
        let previous=AppSession.current;defer {AppSession.current=previous};let session=try await plainSession();try await start()
        let barrier=MCPAdmissionBarrier();defer {barrier.release()};app.clipboard.saveSource={[unowned self] draft in try await self.app.saveClipboardResult(draft,observeWorker:{if $0 == .settingsCaptured {try barrier.hold()}})}
        await fixture.change(8);app.clipboard.poll();try await wait {barrier.waiting}
        XCTAssertFalse(app.hasPendingJSONImport);XCTAssertTrue(app.hasPendingExitWork)
        let delegate=AppDelegate();var exits=0;delegate.finishTermination={_ in exits+=1}
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel);try await wait {[self] in !app.clipboard.running}
        XCTAssertEqual(exits,0);XCTAssertFalse(app.store.isClosed);XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
        barrier.release();try await wait {exits==1};XCTAssertFalse(app.hasPendingExitWork);XCTAssertEqual(try app.store.stats().count,0)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateNow);XCTAssertEqual(exits,1);session.model=nil
    }
    func testActualSessionSwitchJoinsIgnoringReaderBeforeClose()async throws {
        let previous=AppSession.current;defer {AppSession.current=previous};let session=try await plainSession();try await start();await fixture.hold();await fixture.change(8);app.clipboard.poll()
        let until=ContinuousClock.now.advanced(by:.seconds(5));while await fixture.counts().reads==0 {guard ContinuousClock.now<until else {XCTFail("Owned read did not enter");return};try await Task.sleep(for:.milliseconds(5))}
        let destination=root.appendingPathExtension("next"),other=try MemoryStore(root:destination);try other.close();defer {try? FileManager.default.removeItem(at:destination)}
        session.open(destination,persist:false);try await wait {session.busy && session.model==nil};XCTAssertFalse(app.store.isClosed);XCTAssertTrue(app.clipboard.busy)
        await fixture.release();try await wait {!session.busy};XCTAssertNil(session.failure);XCTAssertTrue(app.store.isClosed)
        let next=try XCTUnwrap(session.model);XCTAssertEqual(next.store.root.standardizedFileURL,destination.standardizedFileURL);next.prepareForLibrarySwitch();await next.cancelExternalWorkAndWait();try next.store.close();session.model=nil
    }
    func testRetiredLibraryCannotEnableOrResumeClipboard()async throws {
        app.settings.clipboard.enabled=false;app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait()
        app.configureClipboard(true);app.clipboard.start();try await settle();XCTAssertFalse(app.settings.clipboard.enabled);XCTAssertFalse(app.clipboard.running)
        let counts=await fixture.counts();XCTAssertEqual(counts.probes,0);XCTAssertEqual(try app.store.stats().count,0)
    }

    func testSourceDeletionRevokesHeldCopyAndDoesNotReappearFromCurrentClipboard()async throws {
        try await start();try await observe();let memory=try XCTUnwrap(app.store.search(SearchFilter(query:"Marigold")).first?.memory)
        await fixture.hold();await fixture.change(9,text:"A later owned clipboard note");app.clipboard.poll()
        let until=ContinuousClock.now.advanced(by:.seconds(5));while await fixture.counts().reads<2 {guard ContinuousClock.now<until else {XCTFail("Owned later read did not enter");return};try await Task.sleep(for:.milliseconds(5))}
        app.delete(memory);try await wait {[self] in app.deletingID==nil};XCTAssertNil(try app.store.get(memory.id));XCTAssertTrue(app.clipboard.busy)
        await fixture.release();try await settle();app.clipboard.poll();try await settle();XCTAssertEqual(try app.store.stats().count,0)
        let counts=await fixture.counts();XCTAssertEqual(counts.reads,2)
    }

}
