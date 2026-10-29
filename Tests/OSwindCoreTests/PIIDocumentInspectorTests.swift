import XCTest
@testable import OSwindCore

final class PIIDocumentInspectorTests:XCTestCase {
    final class Backend:PIINativeBackend,@unchecked Sendable {
        enum Fault {case none,plan,source,window,model,shape,nan,failure,cancel}
        struct State {var calls=[Range<Int>]();var closes=0,active=0;var closedWhileActive=false}
        private let lock=NSLock();private var state=State()
        let fault:Fault,gate:PIIInspectorTests.Gate?,prepareGate:PIIInspectorTests.Gate?
        let targets:[Range<Int>],byWindow:[[Range<Int>]]?
        init(fault:Fault = .none,targets:[Range<Int>]=[],byWindow:[[Range<Int>]]?=nil,gate:PIIInspectorTests.Gate?=nil,prepareGate:PIIInspectorTests.Gate?=nil) {
            self.fault=fault;self.targets=targets;self.byWindow=byWindow;self.gate=gate;self.prepareGate=prepareGate
        }
        var snapshot:State {lock.withLock {state}}
        func close() {lock.withLock {state.closes+=1;state.closedWhileActive = state.closedWhileActive || state.active>0}}
        func prepare(_ document:PIIDocument) async throws -> PIIWindowPlan {
            lock.withLock {state.active+=1};defer {lock.withLock {state.active-=1}}
            if let prepareGate {await prepareGate.wait()}
            let source=try fault == .plan ? PIIDocument("other document"):document
            return try PIIWindowPlan.make(document:source,prompt:[50281,50369],tokenLimit:16) {_ in [1]}
        }
        func predict(_ window:PIIWindowPlan.Window) async throws -> PIINativeOutput {
            let ordinal=lock.withLock {let ordinal=state.calls.count;state.calls.append(window.wordRange);state.active+=1;return ordinal}
            defer {lock.withLock {state.active-=1}}
            if ordinal==1,let gate {await gate.wait()}
            let fail=ordinal==1
            if fail && fault == .failure {throw OSwindError.unavailable("Owned later-window failure")}
            if fail && fault == .cancel {withUnsafeCurrentTask {$0?.cancel()}}
            var logits=Array(repeating:Float(-20),count:window.input.words.count*36)
            let selected=byWindow.flatMap {ordinal<$0.count ? $0[ordinal]:nil} ?? targets
            for target in selected where target.lowerBound>=window.wordRange.lowerBound && target.upperBound<=window.wordRange.upperBound {
                let first=target.lowerBound-window.wordRange.lowerBound,last=target.upperBound-1-window.wordRange.lowerBound
                let score:Float=ordinal==0 ? 4:8
                logits[(first*12+10)*3]=score;logits[(last*12+10)*3+1]=score
                for index in first...last {logits[(index*12+10)*3+2]=score}
            }
            if fail && fault == .nan {logits[0] = .nan}
            return .init(sourceSHA256:fail && fault == .source ? "wrong":window.sourceSHA256,
                         windowID:fail && fault == .window ? "wrong":window.id,
                         modelID:fail && fault == .model ? "wrong":PIIInspector.expectedModelID(.cpu),
                         shape:fail && fault == .shape ? [1,1,1,1]:[1,window.input.words.count,12,3],logits:logits)
        }
    }
    var text:String {(0..<80).map {"item\($0)"}.joined(separator:" ")}
    func testEveryWindowSeamCanRecoverAnEntityInOverlappingContext() async throws {
        let source=try PIIDocument(text),probe=Backend(),plan=try await probe.prepare(source)
        let targets=plan.windows.dropLast().map {($0.wordRange.upperBound-1)..<($0.wordRange.upperBound+1)}
        let backend=Backend(targets:targets),inspector=PIIInspector(loader:{backend})
        let result=try await inspector.inspect(text,threshold:0.5)
        XCTAssertEqual(result.spans.count,targets.count);XCTAssertEqual(result.windowCount,plan.windows.count)
        for target in targets {
            let first=source.words[target.lowerBound].range.location,last=NSMaxRange(source.words[target.upperBound-1].range)
            XCTAssertTrue(result.modelMasks.contains {$0.startUTF16<=first && $0.startUTF16+$0.lengthUTF16>=last})
        }
        XCTAssertEqual(result.sourceSHA256,source.sha256);XCTAssertFalse(result.patternRedacted)
        await inspector.shutdown()
    }
    func testOverlappingContextsKeepBothSpansAndUnionTheirMasks() async throws {
        let backend=Backend(byWindow:[[7..<10],[8..<11]]),inspector=PIIInspector(loader:{backend})
        let source=try PIIDocument(text),result=try await inspector.inspect(text,threshold:0.5)
        XCTAssertEqual(result.spans.count,2);XCTAssertEqual(result.modelMasks.count,1)
        XCTAssertEqual(result.modelMasks[0].startUTF16,source.words[7].range.location)
        XCTAssertEqual(result.modelMasks[0].lengthUTF16,NSMaxRange(source.words[10].range)-source.words[7].range.location)
        await inspector.shutdown()
    }
    func testRepeatedDetectionKeepsHighestConfidenceOnce() async throws {
        let backend=Backend(targets:[8..<10]),inspector=PIIInspector(loader:{backend})
        let result=try await inspector.inspect(text,threshold:0.5)
        XCTAssertEqual(result.spans.count,1);XCTAssertGreaterThan(result.spans[0].confidence,0.99)
        await inspector.shutdown()
    }
    func testAnyLaterWindowFailureDiscardsEntireDocumentAndClosesModel() async throws {
        for fault:Backend.Fault in [.source,.window,.model,.shape,.nan,.failure,.cancel] {
            let backend=Backend(fault:fault,targets:[1..<2]),inspector=PIIInspector(loader:{backend})
            let task=Task {try await inspector.inspect(text,threshold:0.5)}
            do {_ = try await task.value;XCTFail("Failed later window returned partial result")}
            catch {}
            XCTAssertEqual(backend.snapshot.calls.count,2);XCTAssertEqual(backend.snapshot.closes,1)
            XCTAssertFalse(backend.snapshot.closedWhileActive);await inspector.shutdown()
        }
    }
    func testCancellationDuringPlanningJoinsBeforeClosing() async throws {
        let gate=PIIInspectorTests.Gate(),backend=Backend(prepareGate:gate),inspector=PIIInspector(loader:{backend})
        let task=Task {try await inspector.inspect(text,threshold:0.5)}
        await fulfillment(of:[gate.entered],timeout:5);task.cancel()
        XCTAssertEqual(backend.snapshot.closes,0);await gate.open()
        do {_ = try await task.value;XCTFail("Cancelled planning returned result")} catch {}
        XCTAssertEqual(backend.snapshot.closes,1);XCTAssertTrue(backend.snapshot.calls.isEmpty)
        XCTAssertFalse(backend.snapshot.closedWhileActive);await inspector.shutdown()
    }
    func testShutdownDuringLaterWindowDrainsBeforeAcknowledgingAndStopsFurtherWindows() async throws {
        let gate=PIIInspectorTests.Gate(),backend=Backend(gate:gate),inspector=PIIInspector(loader:{backend})
        let task=Task {try await inspector.inspect(text,threshold:0.5)}
        await fulfillment(of:[gate.entered],timeout:5)
        let shutdown=Task {await inspector.shutdown()}
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !(await inspector.isShutDown),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertEqual(backend.snapshot.closes,0);await gate.open()
        do {_ = try await task.value;XCTFail("Shutdown returned partial document") } catch {}
        await shutdown.value;XCTAssertEqual(backend.snapshot.calls.count,2)
        XCTAssertEqual(backend.snapshot.closes,1);XCTAssertFalse(backend.snapshot.closedWhileActive)
    }
    func testPatternDetectorSeesOriginalCompleteDocumentAfterAllModelWindows() async throws {
        let backend=Backend(),inspector=PIIInspector(loader:{backend})
        let input=text+" password=ownedSecretDocumentValue "+text,result=try await inspector.inspect(input,threshold:0.5)
        XCTAssertGreaterThan(result.windowCount,1);XCTAssertTrue(result.patternRedacted);XCTAssertFalse(result.modelRedacted)
        XCTAssertFalse(result.text.contains("ownedSecretDocumentValue"));XCTAssertTrue(result.suppressMedia)
        await inspector.shutdown()
    }
    func testAnotherDocumentsPlanIsRefusedBeforePrediction() async throws {
        let backend=Backend(fault:.plan),inspector=PIIInspector(loader:{backend})
        do {_ = try await inspector.inspect(text,threshold:0.5);XCTFail("Another document's plan accepted")} catch {}
        XCTAssertTrue(backend.snapshot.calls.isEmpty);XCTAssertEqual(backend.snapshot.closes,1)
        await inspector.shutdown()
    }
    func testQueuedRequestCannotInterleaveWithWholeDocumentWindows() async throws {
        let gate=PIIInspectorTests.Gate(),backend=Backend(gate:gate),inspector=PIIInspector(loader:{backend})
        let source=try PIIDocument(text),plan=try await Backend().prepare(source)
        let first=Task {try await inspector.inspect(text,threshold:0.5)}
        await fulfillment(of:[gate.entered],timeout:5)
        let second=Task {try await inspector.inspect("tail document",threshold:0.5)}
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while await inspector.queuedRequestCount != 1,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        let queued=await inspector.queuedRequestCount;XCTAssertEqual(queued,1)
        XCTAssertEqual(backend.snapshot.calls.count,2);await gate.open()
        _ = try await first.value;_ = try await second.value
        XCTAssertEqual(Array(backend.snapshot.calls.dropLast()),plan.windows.map(\.wordRange))
        XCTAssertEqual(backend.snapshot.calls.last,0..<2);await inspector.shutdown()
    }
}
