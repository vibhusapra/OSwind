import XCTest
import AppKit
import ApplicationServices
@testable import OSwindCore

private struct OwnedAccessibilityTree:AccessibilityTreeSource {
    typealias Node=Int
    let root=0
    var values:[Int:[AccessibilityAttribute:AccessibilityTreeValue<Int>]]=[0:[.focusedWindow:.node(1)],1:[.title:.string("Owned page"),.role:.string(kAXWindowRole),.children:.nodes([2])],2:[.role:.string(kAXStaticTextRole),.value:.string("Owned accessible text")]]
    var beforeRead:((Int,AccessibilityAttribute)throws->Void)?
    func value(_ node:Int,_ attribute:AccessibilityAttribute,budget:AccessibilityReadBudget) throws -> AccessibilityTreeValue<Int>? {
        _ = try budget.message();try beforeRead?(node,attribute);try budget.checkpoint();return values[node]?[attribute]
    }
}
private final class OwnedAccessibilityGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"owned AX worker entered")
    private let condition=NSCondition()
    private var released=false
    private(set) var onMain=false
    func wait()->WindowContext? {
        condition.lock();onMain=Thread.isMainThread;entered.fulfill();let deadline=Date().addingTimeInterval(10)
        while !released {if !condition.wait(until:deadline) {condition.unlock();return nil}}
        condition.unlock();return WindowContext(app:"Owned",bundle:"org.fixture",pid:8123,title:"Owned",accessibilityText:"",secure:false)
    }
    func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
}
final class AccessibilityReaderTests:XCTestCase {
    private var identity:WindowContext {WindowContext(app:"Owned app",bundle:"org.fixture",pid:8123,title:"",accessibilityText:"",secure:false)}
    func testOwnedTreeReadsWindowURLTextAndBounds() throws {
        var source=OwnedAccessibilityTree();source.values[1]?[.position] = .point(.init(x:12,y:34));source.values[1]?[.size] = .size(.init(width:480,height:300));source.values[2]?[.url] = .string("https://example.org/page")
        let result=try XCTUnwrap(AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget()))
        XCTAssertEqual(result.app,identity.app);XCTAssertEqual(result.pid,8123);XCTAssertEqual(result.title,"Owned page");XCTAssertEqual(result.url,"https://example.org/page");XCTAssertEqual(result.accessibilityText,"Owned accessible text");XCTAssertEqual(result.bounds,CGRect(x:12,y:34,width:480,height:300));XCTAssertFalse(result.secure)
    }
    func testMissingFocusedWindowNeverProducesPartialContext() throws {
        var source=OwnedAccessibilityTree();source.values[0]=[:]
        XCTAssertNil(try AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget()))
    }
    func testBindingScopeReadsOnlyFocusedWindowMetadataAndNeverReturnsTextURLOrSecurity() throws {
        var source=OwnedAccessibilityTree(),attributes=[AccessibilityAttribute](),input=identity
        input.accessibilityText="Old full text";input.url="https://example.org/old";input.secure=true
        source.values[1]?[.position] = .point(.init(x:12,y:34));source.values[1]?[.size] = .size(.init(width:480,height:300))
        source.beforeRead={_,attribute in
            attributes.append(attribute)
            if [.focusedElement,.role,.subrole,.url,.value,.children].contains(attribute) {XCTFail("Binding check read sensitive/tree attributes")}
        }
        let result=try XCTUnwrap(AccessibilityTraversal.read(source,identity:input,budget:AccessibilityReadBudget(maximumMessages:4),scope:.binding))
        XCTAssertEqual(attributes,[.focusedWindow,.title,.position,.size]);XCTAssertEqual(result.title,"Owned page")
        XCTAssertEqual(result.bounds,CGRect(x:12,y:34,width:480,height:300));XCTAssertEqual(result.accessibilityText,"");XCTAssertNil(result.url);XCTAssertFalse(result.secure)
    }
    func testBindingScopeStillRefusesIncompleteBudgetAndLateCancellation() throws {
        var source=OwnedAccessibilityTree(),cancelled=false
        XCTAssertThrowsError(try AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget(maximumMessages:2),scope:.binding))
        source.beforeRead={_,attribute in if attribute == .position {cancelled=true}}
        XCTAssertThrowsError(try AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget(cancelled:{cancelled}),scope:.binding)) {XCTAssertTrue($0 is CancellationError)}
    }
    func testFocusedSecureElementStopsBeforeTraversingValues() throws {
        var source=OwnedAccessibilityTree();source.values[0]?[.focusedElement] = .node(3);source.values[3]=[.subrole:.string(kAXSecureTextFieldSubrole)]
        source.beforeRead={_,attribute in if attribute == .value {XCTFail("Protected context reached text extraction")}}
        XCTAssertTrue(try XCTUnwrap(AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget())).secure)
    }
    func testTextLimitDoesNotHideLaterSecureFieldOrURL() throws {
        var source=OwnedAccessibilityTree();source.values[1]?[.children] = .nodes([2,3,4]);source.values[2]?[.value] = .string(String(repeating:"a",count:20000));source.values[3]=[.role:.string(kAXTextFieldRole),.value:.string("https://example.org/later")];source.values[4]=[.subrole:.string(kAXSecureTextFieldSubrole)]
        let result=try XCTUnwrap(AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget(maximumText:8)))
        XCTAssertTrue(result.secure);XCTAssertEqual(result.url,"https://example.org/later");XCTAssertEqual(result.accessibilityText,"")
        source.values[4]=[:]
        let publicResult=try XCTUnwrap(AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget(maximumText:8)))
        XCTAssertEqual(publicResult.accessibilityText,"aaaaaaaa");XCTAssertEqual(publicResult.url,"https://example.org/later")
    }
    func testCyclesAndRepeatedChildrenAreVisitedOnce() throws {
        var source=OwnedAccessibilityTree(),reads=0;source.values[1]?[.children] = .nodes([2,2,1]);source.values[2]?[.children] = .nodes([1,2]);source.beforeRead={_,attribute in if attribute == .role {reads+=1}}
        XCTAssertEqual(try XCTUnwrap(AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget())).accessibilityText,"Owned accessible text");XCTAssertEqual(reads,2)
    }
    func testIncompleteTreeAndMessageBudgetFailClosed() throws {
        let source=OwnedAccessibilityTree()
        XCTAssertThrowsError(try AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget(maximumNodes:1)))
        XCTAssertThrowsError(try AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget(maximumMessages:3)))
    }
    func testWideTreeCannotQueueBeyondNodeBudget() throws {
        var source=OwnedAccessibilityTree();source.values[1]?[.children] = .nodes(Array(2...100))
        XCTAssertThrowsError(try AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget(maximumNodes:4)))
    }
    func testDeadlineAndCancellationRejectEvenAfterLastMessage() throws {
        var now=10.0,cancelled=false
        let deadline=AccessibilityReadBudget(seconds:0.25,now:{now}),cancellation=AccessibilityReadBudget(cancelled:{cancelled})
        var source=OwnedAccessibilityTree();source.beforeRead={node,attribute in if node==2,attribute == .children {now=10.3}}
        XCTAssertThrowsError(try AccessibilityTraversal.read(source,identity:identity,budget:deadline))
        source.beforeRead={node,attribute in if node==2,attribute == .children {cancelled=true}}
        XCTAssertThrowsError(try AccessibilityTraversal.read(source,identity:identity,budget:cancellation)) {XCTAssertTrue($0 is CancellationError)}
    }
    func testMessagingTimeoutIsPerCallCappedByRemainingBudget() throws {
        var now=0.0;let budget=AccessibilityReadBudget(seconds:0.1,now:{now})
        XCTAssertEqual(try budget.message(),0.04,accuracy:0.0001);now=0.09;XCTAssertEqual(try budget.message(),0.01,accuracy:0.0001);now=0.1;XCTAssertThrowsError(try budget.message())
    }
    @MainActor func testSlowWorkerKeepsMainActorResponsiveAndRejectsOverlapWithoutAQueue() async throws {
        let worker=AccessibilityWorker(),gate=OwnedAccessibilityGate(),attempt=Task {await worker.run {gate.wait()}}
        await fulfillment(of:[gate.entered],timeout:5)
        var ticked=false;await Task {@MainActor in ticked=true}.value;XCTAssertTrue(ticked)
        let overlap=await worker.run {XCTFail("Overlapping AX read started");return nil};XCTAssertNil(overlap)
        gate.release();let result=await attempt.value;XCTAssertNotNil(result);XCTAssertFalse(gate.onMain)
        let retry=await worker.run {WindowContext(app:"Owned",bundle:"org.fixture",pid:8123,title:"Retry",accessibilityText:"",secure:false)};XCTAssertEqual(retry?.title,"Retry")
    }
    @MainActor func testCancellationWaitsForOwnedIPCThenReleasesSlotWithoutPublishing() async throws {
        let worker=AccessibilityWorker(),gate=OwnedAccessibilityGate();var completed=false
        let attempt=Task {let result=await worker.run {gate.wait()};completed=true;return result}
        await fulfillment(of:[gate.entered],timeout:5);attempt.cancel();await Task.yield();XCTAssertFalse(completed)
        let overlap=await worker.run {XCTFail("Cancelled IPC slot released too early");return nil};XCTAssertNil(overlap)
        gate.release();let result=await attempt.value;XCTAssertNil(result);XCTAssertTrue(completed)
        let retry=await worker.run {WindowContext(app:"Owned",bundle:"org.fixture",pid:8123,title:"Retry",accessibilityText:"",secure:false)};XCTAssertNotNil(retry)
    }
    func testCompleteWideTreeVisitsEachNodeAndCapsTextIncludingSeparators() throws {
        var source=OwnedAccessibilityTree(),roles=0
        source.values[1]?[.children] = .nodes(Array(2...301))
        for node in 2...301 {source.values[node]=[.role:.string(kAXStaticTextRole),.value:.string("Owned text"),.children:.nodes([1])]}
        source.beforeRead={_,attribute in if attribute == .role {roles+=1}}
        let result=try XCTUnwrap(AccessibilityTraversal.read(source,identity:identity,budget:AccessibilityReadBudget(seconds:2,maximumText:32)))
        XCTAssertEqual(roles,301);XCTAssertEqual(result.accessibilityText.count,32)
    }
    @MainActor func testSessionCoalescesInFlightReadAndNeverCachesCompletedResult() async throws {
        let entered=XCTestExpectation(description:"coalesced read entered"),joined=XCTestExpectation(description:"second caller joined")
        var resume:CheckedContinuation<WindowContext?,Never>?,reads=0
        let expected=identity,session=AccessibilityReadSession {_ in
            reads+=1
            if reads==1 {return await withCheckedContinuation {resume=$0;entered.fulfill()}}
            var fresh=expected;fresh.title="Fresh observation";return fresh
        }
        let first=Task {await session.read(nil)};await fulfillment(of:[entered],timeout:5)
        let second=Task {joined.fulfill();return await session.read(nil)};await fulfillment(of:[joined],timeout:5)
        XCTAssertEqual(reads,1);resume?.resume(returning:expected)
        let a=await first.value,b=await second.value;XCTAssertEqual(a?.pid,8123);XCTAssertEqual(b?.pid,8123)
        let fresh=await session.read(nil);XCTAssertEqual(reads,2);XCTAssertEqual(fresh?.title,"Fresh observation")
    }
    @MainActor func testSessionRejectsOtherTargetAndCancellationSuppressesLateSuccess() async throws {
        let entered=XCTestExpectation(description:"target read entered");var resume:CheckedContinuation<WindowContext?,Never>?,reads=0
        let expected=identity,session=AccessibilityReadSession {_ in reads+=1;return await withCheckedContinuation {resume=$0;entered.fulfill()}}
        let first=Task {await session.read("org.fixture")};await fulfillment(of:[entered],timeout:5)
        let other=await session.read("org.other");XCTAssertNil(other);XCTAssertEqual(reads,1)
        session.cancel();resume?.resume(returning:expected);let result=await first.value;XCTAssertNil(result)
    }
    @MainActor func testCancelledWaiterDoesNotCancelOtherSessionObserver() async throws {
        let entered=XCTestExpectation(description:"shared read entered"),joined=XCTestExpectation(description:"shared waiter joined")
        var resume:CheckedContinuation<WindowContext?,Never>?
        let expected=identity,session=AccessibilityReadSession {_ in await withCheckedContinuation {resume=$0;entered.fulfill()}}
        let first=Task {await session.read(nil)};await fulfillment(of:[entered],timeout:5)
        let second=Task {joined.fulfill();return await session.read(nil)};await fulfillment(of:[joined],timeout:5)
        first.cancel();resume?.resume(returning:expected)
        let cancelled=await first.value,other=await second.value;XCTAssertNil(cancelled);XCTAssertNotNil(other)
    }
    func testAlreadyCancelledRequestNeverStartsWorker() async {
        let worker=AccessibilityWorker(),attempt=Task {() -> WindowContext? in
            withUnsafeCurrentTask {$0?.cancel()}
            return await worker.run {XCTFail("Cancelled AX request started");return nil}
        }
        let result=await attempt.value;XCTAssertNil(result)
    }
}
