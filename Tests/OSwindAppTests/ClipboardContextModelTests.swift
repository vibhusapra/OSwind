import XCTest
import Combine
@testable import OSwind
@testable import OSwindCore

actor ClipboardOwnedFixture {
    private var count=7,probes=0,reads=0,requests=0,held=false
    private var permission:ClipboardAccess = .allowed
    private var text="Mira owns the Marigold release.",waiters=[CheckedContinuation<Void,Never>]()
    func probe()->ClipboardProbe {probes+=1;return .init(access:permission,changeCount:permission == .allowed ? count:nil)}
    func read(_ expected:Int)async->ClipboardTextSnapshot {
        reads+=1;if held {await withCheckedContinuation {waiters.append($0)}}
        return .init(changeCount:expected,finalChangeCount:count,itemCount:1,types:["public.utf8-plain-text"],text:Data(text.utf8))
    }
    func change(_ value:Int,text:String?=nil){count=value;if let text {self.text=text}}
    func hold(){held=true}
    func release(){held=false;let values=waiters;waiters=[];for value in values {value.resume()}}
    func request()->ClipboardAccess {requests+=1;return permission}
    func access(_ value:ClipboardAccess){permission=value}
    func counts()->(probes:Int,reads:Int,requests:Int){(probes,reads,requests)}
}

@MainActor final class ClipboardContextModelTests:XCTestCase {
    var root:URL!,store:MemoryStore!,model:ClipboardContextModel!,fixture:ClipboardOwnedFixture!
    var settings=AppSettings(),contextReads=0,locked=false,idle=false,after:WindowContext?
    var observed=WindowContext(app:"Owned editor",bundle:"org.oswind.owned-editor",pid:123,title:"Marigold plan",url:nil,accessibilityText:"",secure:false)
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-clipboard-model-"+UUID().uuidString);store=try MemoryStore(root:root);fixture=ClipboardOwnedFixture();settings.clipboard.enabled=true;install()
    }
    override func tearDown()async throws {
        await fixture.release();await model.cancelAndWait();try store.close();try? FileManager.default.removeItem(at:root);model=nil;store=nil
    }
    func install(){
        let fixture=self.fixture!,store=self.store!
        let reader=ClipboardReader(probe:{await fixture.probe()},read:{count,_ in await fixture.read(count)},requestAccess:{await fixture.request()})
        model=ClipboardContextModel(store:store,settings:settings,reader:reader,context:{[unowned self] in self.contextReads+=1;return self.contextReads%2==0 ? self.after ?? self.observed:self.observed},locked:{[unowned self] in self.locked},idle:{[unowned self] in self.idle},limited:{false},schedulesTimers:false,workspaceNotifications:NotificationCenter())
        model.saveSource={draft in try Task.checkCancellation();return try store.importCollectorBatch(draft.batch)}
    }
    func wait(_ condition:@escaping @MainActor ()->Bool)async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(3));while !condition() {guard ContinuousClock.now<end else {XCTFail("Owned clipboard model did not settle");return};try await Task.sleep(for:.milliseconds(5))}
    }
    func settled()async throws {try await wait {[self] in !model.busy}}
    func start()async throws {model.start();try await settled()}
    func waitForRead()async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(3));while await fixture.counts().reads==0 {guard ContinuousClock.now<end else {XCTFail("Owned clipboard read did not enter");return};try await Task.sleep(for:.milliseconds(5))}
    }
    func testBaselineAndUnchangedPollsNeverReadTextOrContext()async throws {
        try await start();for _ in 0..<20 {model.poll();try await settled()}
        let before=await fixture.counts();XCTAssertEqual(before.probes,21);XCTAssertEqual(before.reads,0);XCTAssertEqual(contextReads,0);XCTAssertEqual(try store.stats().count,0)
        await fixture.change(8);model.poll();try await settled();XCTAssertEqual(contextReads,2);XCTAssertEqual(model.saved,1);XCTAssertEqual(try store.stats().count,1)
        await fixture.change(9);model.poll();try await settled();XCTAssertEqual(model.saved,1);XCTAssertEqual(try store.stats().count,1)
        let after=await fixture.counts();XCTAssertEqual(after.reads,2)
    }
    func testOffLockedAndIdleScopesDoNotProbeOrBackfill()async throws {
        settings.clipboard.enabled=false;model.apply(settings);try await start();let off=await fixture.counts();XCTAssertEqual(off.probes,0)
        settings.clipboard.enabled=true;model.apply(settings);locked=true;try await start();let closed=await fixture.counts();XCTAssertEqual(closed.probes,0)
        locked=false;model.poll();try await settled();await fixture.change(8);idle=true;model.poll();try await settled()
        idle=false;model.poll();try await settled();let resumed=await fixture.counts();XCTAssertEqual(resumed.reads,0);XCTAssertEqual(try store.stats().count,0)
    }
    func testProtectedBeforeContextSkipsIOAndChangedAfterContextSkipsSave()async throws {
        try await start();observed.secure=true;await fixture.change(8);model.poll();try await settled();let protected=await fixture.counts();XCTAssertEqual(protected.reads,0)
        observed.secure=false;contextReads=0;after=observed;after?.title="Different window";await fixture.change(9);model.poll();try await settled()
        let changed=await fixture.counts();XCTAssertEqual(changed.reads,1);XCTAssertEqual(try store.stats().count,0);XCTAssertEqual(model.saved,0)
    }
    func testStopJoinsIgnoringReadAndDiscardsLateData()async throws {
        try await start();await fixture.hold();await fixture.change(8);model.poll();try await waitForRead()
        var drained=false;let waiter=Task {await self.model.cancelAndWait();drained=true};try await wait {[self] in !model.running}
        XCTAssertTrue(model.busy);XCTAssertFalse(drained);XCTAssertFalse(store.isClosed)
        await fixture.release();await waiter.value;XCTAssertTrue(drained);XCTAssertFalse(model.busy);XCTAssertEqual(try store.stats().count,0)
    }
    func testPrivacyChangeRevokesHeldReadAndStartsFreshBaseline()async throws {
        try await start();await fixture.hold();await fixture.change(8);model.poll();try await waitForRead()
        settings.privacy.excludedApps.append(observed.bundle);model.apply(settings);await fixture.release();try await settled()
        model.poll();try await settled();await fixture.change(9);model.poll();try await settled()
        let counts=await fixture.counts();XCTAssertEqual(counts.reads,1);XCTAssertEqual(model.saved,0);XCTAssertEqual(try store.stats().count,0)
    }
    func testQuietPollsDoNotInvalidateVisibleUI()async throws {
        try await start();var updates=0;let subscription=model.objectWillChange.sink {updates+=1};defer {subscription.cancel()}
        for _ in 0..<20 {model.poll();try await settled()}
        XCTAssertEqual(updates,0);let counts=await fixture.counts();XCTAssertEqual(counts.reads,0);XCTAssertEqual(contextReads,0)
    }
    func testPermissionRequestsRequireExplicitActionAndNeverSaveCurrentText()async throws {
        try await start();let initial=await fixture.counts();XCTAssertEqual(initial.requests,0)
        model.requestAccess();try await settled();let requested=await fixture.counts();XCTAssertEqual(requested.requests,1);XCTAssertEqual(requested.reads,0);XCTAssertEqual(try store.stats().count,0)
        model.poll();try await settled();let baseline=await fixture.counts();XCTAssertEqual(baseline.reads,0);XCTAssertEqual(baseline.requests,1)
    }

    func testDeniedAndAskPermissionsNeverReadOrRequestAndReapprovalDoesNotBackfill()async throws {
        await fixture.access(.approvalRequired);try await start();for _ in 0..<3 {model.poll();try await settled()}
        let waiting=await fixture.counts();XCTAssertEqual(waiting.requests,0);XCTAssertEqual(waiting.reads,0);XCTAssertEqual(contextReads,0)
        await fixture.change(8);await fixture.access(.allowed);model.poll();try await settled();let first=await fixture.counts();XCTAssertEqual(first.reads,0)
        await fixture.change(9);model.poll();try await settled();XCTAssertEqual(model.saved,1)
        await fixture.access(.denied);await fixture.change(10);model.poll();try await settled();await fixture.access(.allowed);model.poll();try await settled()
        let restored=await fixture.counts();XCTAssertEqual(restored.reads,1);XCTAssertEqual(restored.requests,0);XCTAssertEqual(model.saved,1)
    }

    func testReplacedLibraryRefusesBeforeTextOrWindowRead()async throws {
        try await start();let retired=root.appendingPathExtension("retired");try FileManager.default.moveItem(at:root,to:retired);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.moveItem(at:retired,to:root)}
        await fixture.change(8);model.poll();try await settled();let counts=await fixture.counts();XCTAssertEqual(counts.reads,0);XCTAssertEqual(contextReads,0);XCTAssertEqual(model.saved,0)
    }

}
