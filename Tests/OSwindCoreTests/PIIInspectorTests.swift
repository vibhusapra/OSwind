import XCTest
@testable import OSwindCore

final class PIIInspectorTests:XCTestCase {
    actor Gate {
        nonisolated let entered=XCTestExpectation(description:"native operation entered")
        private var opened=false
        private var continuations:[CheckedContinuation<Void,Never>]=[]
        func wait() async {if opened {return};entered.fulfill();await withCheckedContinuation {continuations.append($0)}}
        func open() {opened=true;let pending=continuations;continuations=[];for item in pending {item.resume()}}
    }
    final class Backend:PIINativeBackend,@unchecked Sendable {
        enum Mode {case valid,sourceMismatch,modelMismatch,nan,shape,fail,entity}
        struct State {var calls:[String]=[];var active=0,maximum=0,closes=0,closedWhileActive=false}
        let gate:Gate?,mode:Mode
        private let lock=NSLock()
        private var state=State()
        init(gate:Gate?=nil,mode:Mode = .valid) {self.gate=gate;self.mode=mode}
        var snapshot:State {lock.withLock {state}}
        func close() {lock.withLock {state.closes+=1;state.closedWhileActive = state.closedWhileActive || state.active>0}}
        func prepare(_ document:PIIDocument) async throws -> PIIWindowPlan {
            try PIIWindowPlan.make(document:document,prompt:[50281,50369],tokenLimit:512) {_ in [1]}
        }
        func predict(_ window:PIIWindowPlan.Window) async throws -> PIINativeOutput {
            let text=window.text
            lock.withLock {state.calls.append(text);state.active+=1;state.maximum=max(state.maximum,state.active)}
            defer {lock.withLock {state.active-=1}}
            if let gate {await gate.wait()}
            if mode == .fail {throw OSwindError.unavailable("synthetic model failure")}
            let source=try PIIDecoding.Source(window:window)
            var logits=Array(repeating:Float(-20),count:source.words.count*36)
            if mode == .entity {for channel in 0..<3 {logits[2*3+channel]=8}}
            if mode == .nan {logits[0] = .nan}
            return PIINativeOutput(sourceSHA256:mode == .sourceMismatch ? "other":source.sha256,
                windowID:window.id,
                modelID:mode == .modelMismatch ? "other":PIIInspector.expectedModelID(.cpu),
                shape:mode == .shape ? [1,1,1,1]:[1,source.words.count,12,3],logits:logits)
        }
    }
    func waitFor(_ inspector:PIIInspector,count:Int?=nil,closed:Bool?=nil) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while ContinuousClock.now<deadline {
            let queue=await inspector.queuedRequestCount,isClosed=await inspector.isShutDown
            if (count==nil || queue==count) && (closed==nil || isClosed==closed) {return}
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("PII owner did not reach expected state");throw OSwindError.unavailable("test coordination timed out")
    }
    func refused(_ operation:() async throws -> PIIInspection) async {
        do {_ = try await operation();XCTFail("Invalid/cancelled scan returned a result")} catch {}
    }
    func testSessionReuseExplicitUnloadAndTerminalShutdown() async throws {
        let backend=Backend(),inspector=PIIInspector(loader:{backend})
        await inspector.setRetention(.untilQuit)
        _ = try await inspector.inspect("first",threshold:0.5)
        _ = try await inspector.inspect("second",threshold:0.5)
        var resident=await inspector.modelResident;XCTAssertTrue(resident);XCTAssertEqual(backend.snapshot.closes,0)
        try await inspector.unload();resident=await inspector.modelResident;XCTAssertFalse(resident)
        XCTAssertEqual(backend.snapshot.closes,1)
        await inspector.shutdown();await inspector.shutdown()
        await refused {try await inspector.inspect("third",threshold:0.5)}
        XCTAssertEqual(backend.snapshot.calls,["first","second"])
    }
    func testFIFOAndQueuedCancellationNeverEnterBackendTogether() async throws {
        let gate=Gate(),backend=Backend(gate:gate),inspector=PIIInspector(loader:{backend})
        let first=Task {try await inspector.inspect("first",threshold:0.5)}
        await fulfillment(of:[gate.entered],timeout:5)
        let cancelled=Task {try await inspector.inspect("cancelled",threshold:0.5)}
        try await waitFor(inspector,count:1)
        let third=Task {try await inspector.inspect("third",threshold:0.5)}
        try await waitFor(inspector,count:2);cancelled.cancel()
        await refused {try await cancelled.value};try await waitFor(inspector,count:1)
        XCTAssertEqual(backend.snapshot.calls,["first"])
        await gate.open();_ = try await first.value;_ = try await third.value
        XCTAssertEqual(backend.snapshot.calls,["first","third"]);XCTAssertEqual(backend.snapshot.maximum,1)
        await inspector.shutdown();XCTAssertFalse(backend.snapshot.closedWhileActive)
    }
    func testInFlightCancellationJoinsBeforeClosingAndDiscarding() async throws {
        let gate=Gate(),backend=Backend(gate:gate),inspector=PIIInspector(loader:{backend})
        let first=Task {try await inspector.inspect("first",threshold:0.5)}
        await fulfillment(of:[gate.entered],timeout:5);first.cancel()
        XCTAssertEqual(backend.snapshot.closes,0);XCTAssertEqual(backend.snapshot.active,1)
        await gate.open();await refused {try await first.value}
        XCTAssertEqual(backend.snapshot.closes,1);XCTAssertFalse(backend.snapshot.closedWhileActive)
        await inspector.shutdown()
    }
    func testQueueBoundRefusesExcessWorkAndShutdownDrainsAllWaiters() async throws {
        let gate=Gate(),backend=Backend(gate:gate),inspector=PIIInspector(loader:{backend})
        let first=Task {try await inspector.inspect("first",threshold:0.5)}
        await fulfillment(of:[gate.entered],timeout:5)
        var queued=[Task<PIIInspection,Error>]()
        for index in 0..<32 {
            queued.append(Task {try await inspector.inspect("queued\(index)",threshold:0.5)})
            try await waitFor(inspector,count:index+1)
        }
        await refused {try await inspector.inspect("overflow",threshold:0.5)}
        XCTAssertEqual(backend.snapshot.calls,["first"])
        let shutdown=Task {await inspector.shutdown()};try await waitFor(inspector,count:0,closed:true)
        for item in queued {await refused {try await item.value}}
        await gate.open();await refused {try await first.value};await shutdown.value
        XCTAssertEqual(backend.snapshot.closes,1);XCTAssertFalse(backend.snapshot.closedWhileActive)
    }
    func testShutdownDuringInferenceDrainsAndRejectsQueuedAndNewRequests() async throws {
        let gate=Gate(),backend=Backend(gate:gate),inspector=PIIInspector(loader:{backend})
        let first=Task {try await inspector.inspect("first",threshold:0.5)}
        await fulfillment(of:[gate.entered],timeout:5)
        let queued=Task {try await inspector.inspect("queued",threshold:0.5)}
        try await waitFor(inspector,count:1)
        let shutdown=Task {await inspector.shutdown()};try await waitFor(inspector,count:0,closed:true)
        let secondShutdown=Task {await inspector.shutdown()};secondShutdown.cancel()
        await refused {try await queued.value};await refused {try await inspector.inspect("late",threshold:0.5)}
        XCTAssertEqual(backend.snapshot.closes,0);XCTAssertEqual(backend.snapshot.active,1)
        await gate.open();await refused {try await first.value};await shutdown.value;await secondShutdown.value
        XCTAssertEqual(backend.snapshot.closes,1);XCTAssertFalse(backend.snapshot.closedWhileActive)
        let resident=await inspector.modelResident;XCTAssertFalse(resident)
    }
    func testShutdownDuringLoadClosesStaleCandidateBeforeAcknowledgment() async throws {
        let gate=Gate(),backend=Backend(),inspector=PIIInspector(loader:{await gate.wait();return backend})
        let scan=Task {try await inspector.inspect("first",threshold:0.5)}
        await fulfillment(of:[gate.entered],timeout:5)
        let shutdown=Task {await inspector.shutdown()};try await waitFor(inspector,closed:true)
        XCTAssertEqual(backend.snapshot.closes,0)
        await gate.open();await refused {try await scan.value};await shutdown.value
        XCTAssertEqual(backend.snapshot.closes,1);XCTAssertTrue(backend.snapshot.calls.isEmpty)
    }
    func testCancelledLoadClosesCandidateWithoutCaching() async throws {
        let gate=Gate(),backend=Backend(),inspector=PIIInspector(loader:{await gate.wait();return backend})
        let scan=Task {try await inspector.inspect("first",threshold:0.5)}
        await fulfillment(of:[gate.entered],timeout:5);scan.cancel();await gate.open()
        await refused {try await scan.value};XCTAssertEqual(backend.snapshot.closes,1)
        let resident=await inspector.modelResident;XCTAssertFalse(resident);await inspector.shutdown()
    }
    func testSourceModelShapeAndFiniteFailuresNeverReturnFallback() async throws {
        for mode:Backend.Mode in [.sourceMismatch,.modelMismatch,.shape,.nan,.fail] {
            let backend=Backend(mode:mode),inspector=PIIInspector(loader:{backend})
            await refused {try await inspector.inspect("password=fixtureSecret",threshold:0.5)}
            XCTAssertEqual(backend.snapshot.closes,1);let resident=await inspector.modelResident;XCTAssertFalse(resident)
            await inspector.shutdown()
        }
    }
    func testThresholdEmptyAndOversizedInputRefuseBeforeLoading() async throws {
        let backend=Backend(),inspector=PIIInspector(loader:{backend})
        for threshold:Double in [0,1,-1,.nan,.infinity] {await refused {try await inspector.inspect("text",threshold:threshold)}}
        for text in [""," \n\t",String(repeating:"a",count:32769),Array(repeating:"a",count:8193).joined(separator:" ")] {
            await refused {try await inspector.inspect(text,threshold:0.5)}
        }
        XCTAssertTrue(backend.snapshot.calls.isEmpty);let resident=await inspector.modelResident;XCTAssertFalse(resident)
        await inspector.shutdown()
    }
    func testPatternProtectionRemainsWhenLearnedModelFindsNothing() async throws {
        let backend=Backend(),inspector=PIIInspector(loader:{backend})
        let result=try await inspector.inspect("password=fixtureSecret",threshold:0.5)
        XCTAssertEqual(result.text,"[REDACTED]");XCTAssertTrue(result.patternRedacted)
        XCTAssertFalse(result.modelRedacted);XCTAssertTrue(result.redacted);XCTAssertTrue(result.suppressMedia)
        XCTAssertTrue(result.spans.isEmpty);XCTAssertTrue(result.modelMasks.isEmpty)
        let json=String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
        XCTAssertFalse(json.contains("fixtureSecret"));await inspector.shutdown()
    }
    func testOriginalCoordinatesAndWholeGraphemeMasksHaveNoSpanText() async throws {
        let backend=Backend(mode:.entity),inspector=PIIInspector(loader:{backend})
        let result=try await inspector.inspect("Cafe\u{301} after",threshold:0.5)
        XCTAssertEqual(result.text,"[REDACTED] after");XCTAssertEqual(result.spans.first?.lengthUTF16,4)
        XCTAssertEqual(result.modelMasks.first?.lengthUTF16,5);XCTAssertEqual(result.spans.first?.category,"address")
        XCTAssertTrue(result.modelRedacted);XCTAssertFalse(result.patternRedacted)
        let json=String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
        XCTAssertFalse(json.contains("Cafe"));await inspector.shutdown()
    }
    func testLearnedMaskCannotHideOriginalSecretTriggerOrSuffix() async throws {
        let backend=Backend(mode:.entity),inspector=PIIInspector(loader:{backend})
        for text in ["password=fixtureSecret", "password=fixtureSecret🦊", "api_key=fixtureSecret", "secret=fixtureSecret\u{301}"] {
            let result=try await inspector.inspect(text,threshold:0.5)
            XCTAssertEqual(result.text,"[REDACTED]");XCTAssertTrue(result.patternRedacted);XCTAssertTrue(result.modelRedacted)
            XCTAssertEqual(result.masks.count,1);XCTAssertEqual(result.masks.first?.lengthUTF16,(text as NSString).length)
        }
        await inspector.shutdown()
    }
    func testAfterUsePolicyClosesBeforeResultReturns() async throws {
        let backend=Backend(),inspector=PIIInspector(loader:{backend})
        await inspector.setRetention(.afterUse)
        _ = try await inspector.inspect("owned",threshold:0.5)
        XCTAssertEqual(backend.snapshot.closes,1);let resident=await inspector.modelResident;XCTAssertFalse(resident)
        await inspector.shutdown()
    }
    func testIdleReleaseClosesSession() async throws {
        let gate=Gate(),backend=Backend(),inspector=PIIInspector(loader:{backend},idleSleep:{_ in await gate.wait()})
        _ = try await inspector.inspect("owned",threshold:0.5)
        await fulfillment(of:[gate.entered],timeout:5);await gate.open()
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while await inspector.modelResident,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        let resident=await inspector.modelResident;XCTAssertFalse(resident);XCTAssertEqual(backend.snapshot.closes,1)
        await inspector.shutdown()
    }
    func testCancelledIdleCallbackCannotUnloadRetainedSession() async throws {
        let idle=Gate(),inference=Gate(),backend=Backend(gate:inference)
        let inspector=PIIInspector(loader:{backend},idleSleep:{_ in await idle.wait()})
        await inference.open()
        _ = try await inspector.inspect("first",threshold:0.5)
        await fulfillment(of:[idle.entered],timeout:5)
        await inspector.setRetention(.untilQuit)
        await idle.open()
        _ = try await inspector.inspect("second",threshold:0.5)
        let resident=await inspector.modelResident;XCTAssertTrue(resident);XCTAssertEqual(backend.snapshot.closes,0)
        await inspector.shutdown();XCTAssertEqual(backend.snapshot.closes,1)
    }
    func testFailedLoadDoesNotPoisonNextRequest() async throws {
        actor Attempts {var count=0;func first()->Bool {count+=1;return count==1}}
        let attempts=Attempts(),backend=Backend(),inspector=PIIInspector(loader:{
            if await attempts.first() {throw OSwindError.unavailable("synthetic load failure")};return backend
        })
        await refused {try await inspector.inspect("first",threshold:0.5)}
        let result=try await inspector.inspect("second",threshold:0.5)
        XCTAssertEqual(result.text,"second");XCTAssertEqual(backend.snapshot.calls,["second"])
        await inspector.shutdown();XCTAssertEqual(backend.snapshot.closes,1)
    }
}
