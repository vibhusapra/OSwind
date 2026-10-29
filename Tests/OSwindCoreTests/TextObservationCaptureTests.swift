import XCTest
import AppKit
@testable import OSwindCore

@MainActor private final class ObservationWorld {
    var date=Date(timeIntervalSince1970:1730611800),uptime=100.0,locked=false,permitted=true,idle=0.0,reads=0
    var context=WindowContext(app:"Owned",bundle:"org.oswind.owned",pid:8123,title:"Owned page",url:"https://example.org/page",accessibilityText:"Maya owns the Friday release.",secure:false,bounds:CGRect(x:10,y:20,width:600,height:400))
    var readHook:(() async -> WindowContext?)?
    func advance(_ seconds:Double,uptime delta:Double?=nil){date.addTimeInterval(seconds);uptime += delta ?? seconds}
    func environment()->SnapshotCaptureEnvironment {
        var e=SnapshotCaptureEnvironment();e.locked={self.locked};e.accessibilityPermitted={self.permitted};e.idleSeconds={self.idle};e.now={self.date};e.uptime={self.uptime}
        e.permitted={XCTFail("Observed text checked pixel permission");return false};e.frames={_,_ in XCTFail("Observed text enumerated pixels");return []};e.recognize={_ in XCTFail("Observed text ran OCR");return []}
        e.context={_ in self.reads+=1;if let hook=self.readHook {return await hook()};return self.context}
        e.identityCurrent={c,_ in c.pid==self.context.pid && c.bundle==self.context.bundle}
        e.textCommitPermitted={true};e.textEmbedding={_,_ in nil};return e
    }
}
@MainActor final class TextObservationCaptureTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-observation-controller-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try? store.close();try? FileManager.default.removeItem(at:root)}
    private func controller(_ w:ObservationWorld)throws->CaptureController {var s=AppSettings();s.visualCaptureMode = .accessibility;s.profile = .light;try s.save(root:root);return CaptureController(store:store,embedder:LocalEmbedder(),settings:s,snapshots:w.environment())}
    private func start(_ c:CaptureController)async throws->Memory {
        let saved=XCTestExpectation(description:"first automatic text observation");var first:Memory?
        c.onCapture={if first==nil {first=$0;saved.fulfill()}};c.start();await fulfillment(of:[saved],timeout:10);return try XCTUnwrap(first)
    }
    func testAutomaticIdenticalObservationsExtendOneSourceAndEmitSeparateCallback()async throws {
        let w=ObservationWorld(),c=try controller(w);let first=try await start(c);defer {c.pause()}
        var updates=[Memory]();c.onObservation={updates.append($0)}
        for _ in 0..<3 {w.advance(5);await c.captureOnce()}
        let source=try XCTUnwrap(store.get(first.id));XCTAssertEqual(source.textObservation?.samples,4);XCTAssertEqual(source.textObservation?.largestGapSeconds,5);XCTAssertEqual(source.endTimestamp,w.date);XCTAssertEqual(try store.stats().count,1)
        XCTAssertEqual(c.metrics.saved,1);XCTAssertEqual(c.metrics.coalesced,3);XCTAssertEqual(updates.count,3);XCTAssertEqual(w.reads,8)
        XCTAssertEqual(try store.search(SearchFilter(query:"Friday",start:w.date.addingTimeInterval(-1),end:w.date.addingTimeInterval(1)),mode:.keyword).map(\.id),[first.id])
    }
    func testGapClockJumpAndProcessOrWindowChangesStartNewSpans()async throws {
        for kind in 0..<5 {
            let w=ObservationWorld(),c=try controller(w);_=try await start(c)
            switch kind {case 0:w.advance(121);case 1:w.advance(5,uptime:100);case 2:w.advance(-1,uptime:5);case 3:w.advance(5);w.context.pid+=1;default:w.advance(5);w.context.bounds?.origin.x+=1}
            let before=c.metrics.saved;await c.captureOnce();XCTAssertEqual(c.metrics.saved,before+1);XCTAssertEqual(c.metrics.coalesced,0);c.pause()
        }
    }
    func testLockPermissionIdleAndPauseBreakContinuityWithoutBridging()async throws {
        for kind in 0..<4 {
            let w=ObservationWorld(),c=try controller(w);let first=try await start(c)
            if kind==0 {w.locked=true};if kind==1 {w.permitted=false};if kind==2 {w.idle=121};if kind==3 {c.pause()}
            w.advance(5);await c.captureOnce();XCTAssertNil(try store.get(first.id)?.endTimestamp)
            w.locked=false;w.permitted=true;w.idle=0;w.advance(5)
            if kind==3 {_=try await start(c)}else {await c.captureOnce()}
            XCTAssertEqual(c.metrics.saved,2);XCTAssertEqual(c.metrics.coalesced,0);c.pause()
        }
    }
    func testManualCaptureIsSeparatePointAndCannotJoinLaterAutomaticSamples()async throws {
        let w=ObservationWorld(),c=try controller(w);_=try await start(c);defer {c.pause()}
        w.advance(5);await c.captureOnce(manual:true);w.advance(5);await c.captureOnce()
        XCTAssertEqual(c.metrics.saved,3);XCTAssertEqual(c.metrics.coalesced,0)
        let all=try store.search(SearchFilter(),mode:.keyword).map(\.memory);XCTAssertEqual(all.filter {$0.textObservation==nil}.count,1);XCTAssertTrue(all.allSatisfy {$0.endTimestamp==nil})
    }
    func testFifteenMinuteBoundaryStartsNewSourceDespiteUnchangedText()async throws {
        let w=ObservationWorld(),c=try controller(w);let first=try await start(c);defer {c.pause()}
        for _ in 0..<30 {w.advance(30);await c.captureOnce()}
        XCTAssertEqual(try store.get(first.id)?.textObservation?.samples,31);XCTAssertEqual(try store.stats().count,1)
        w.advance(30);await c.captureOnce();XCTAssertEqual(try store.stats().count,2);XCTAssertEqual(c.metrics.saved,2);XCTAssertEqual(c.metrics.coalesced,30)
    }
    func testFinalContextChangeDiscardsExtensionAndNextValidSampleStartsNewSource()async throws {
        let w=ObservationWorld(),c=try controller(w);let first=try await start(c);defer {c.pause()}
        w.advance(5);w.readHook={if w.reads==4 {w.context.title="Different focused window"};return w.context}
        await c.captureOnce();XCTAssertNil(try store.get(first.id)?.endTimestamp);XCTAssertEqual(c.metrics.coalesced,0)
        w.readHook=nil;w.context.title="Owned page";w.advance(5);await c.captureOnce();XCTAssertEqual(c.metrics.saved,2)
    }
    func testExternalEditAfterPreparationCannotOverwriteItDuringExtension()async throws {
        let w=ObservationWorld(),c=try controller(w);let first=try await start(c);defer {c.pause()}
        w.advance(5);w.readHook={if w.reads==4 {var edited=first;edited.text="User-edited source";try? self.store.insert(edited)};return w.context}
        await c.captureOnce();XCTAssertEqual(try store.get(first.id)?.text,"User-edited source");XCTAssertNil(try store.get(first.id)?.endTimestamp);XCTAssertEqual(c.metrics.coalesced,0)
        w.readHook=nil;w.advance(5);await c.captureOnce();XCTAssertEqual(c.metrics.saved,2)
    }
    func testPauseDuringFinalReadPreventsAnyExtentExtension()async throws {
        let w=ObservationWorld(),c=try controller(w);let first=try await start(c)
        let entered=XCTestExpectation(description:"one final observation read held");var resume:CheckedContinuation<WindowContext?,Never>?
        w.advance(5);w.readHook={if w.reads==4 {return await withCheckedContinuation {resume=$0;entered.fulfill()}};return w.context}
        let capture=Task {await c.captureOnce()};await fulfillment(of:[entered],timeout:10);c.pause();resume?.resume(returning:w.context);await capture.value
        XCTAssertNil(try store.get(first.id)?.endTimestamp);XCTAssertEqual(c.metrics.coalesced,0);XCTAssertEqual(try store.get(first.id)?.textObservation?.samples,1)
    }
    func testWipeWaitsForPendingObservationThenErasesSourceAndRange()async throws {
        let w=ObservationWorld(),c=try controller(w);_=try await start(c);defer {c.pause()}
        let entered=XCTestExpectation(description:"observation holds activity"),waiting=XCTestExpectation(description:"wipe waits on observation activity");var resume:CheckedContinuation<WindowContext?,Never>?
        w.advance(5);w.readHook={if w.reads==4 {return await withCheckedContinuation {resume=$0;entered.fulfill()}};return w.context}
        let capture=Task {await c.captureOnce()};await fulfillment(of:[entered],timeout:10)
        let sourceStore=store!,wipe=Task.detached {try sourceStore.wipeLibrary {if $0.phase=="Waiting for active media writers" {waiting.fulfill()}}};await fulfillment(of:[waiting],timeout:10)
        resume?.resume(returning:w.context);await capture.value;let result=try await wipe.value
        XCTAssertEqual(result.erasure.sources,1);XCTAssertEqual(try store.stats().count,0)
        let rangeCount=try store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM text_observation_ranges")};XCTAssertEqual(rangeCount,0)
    }
    func testPinnedEvidenceKeepsItsExtentWhileAutomaticCaptureContinuesInNewSource()async throws {
        let w=ObservationWorld(),c=try controller(w);let first=try await start(c);defer {c.pause()}
        w.advance(5);await c.captureOnce();let source=try XCTUnwrap(store.get(first.id))
        var configuration=AIConfiguration();configuration.provider = .evidence
        let answer=try await AnswerEngine(store:store,embedder:LocalEmbedder()).answer("Friday",configuration:configuration),chat=try store.createChat()
        _=try store.appendChatTurn(sessionID:chat.id,question:"Who owns release?",answer:answer);let recap=try store.saveRecap(answer)
        w.advance(5);await c.captureOnce();XCTAssertEqual(c.metrics.saved,2);XCTAssertEqual(try store.get(first.id)?.textObservation?.samples,2);XCTAssertEqual(try store.get(first.id)?.endTimestamp,source.endTimestamp)
        w.advance(5);await c.captureOnce();XCTAssertEqual(c.metrics.saved,2);XCTAssertEqual(c.metrics.coalesced,2);XCTAssertEqual(try store.stats().count,3)
        XCTAssertEqual(try store.search(SearchFilter(kind:.screen),mode:.keyword).count,2)
        XCTAssertNotNil(try store.get(recap.id));XCTAssertEqual(try store.chatTurns(chat.id).count,1)
    }
    func testPinAfterPreparationRefusesLateExtensionAndNextTickStartsNewSource()async throws {
        let w=ObservationWorld(),c=try controller(w);let first=try await start(c);defer {c.pause()}
        w.advance(5);w.readHook={if w.reads==4 {_=try? self.store.hydrate([SearchHit(memory:first,score:1,match:"owned")],pinTextObservations:true)};return w.context}
        await c.captureOnce();XCTAssertNil(try store.get(first.id)?.endTimestamp);XCTAssertEqual(c.metrics.coalesced,0)
        w.readHook=nil;w.advance(5);await c.captureOnce();XCTAssertEqual(c.metrics.saved,2)
    }
}
