import XCTest
@testable import OSwindCore

@MainActor private final class ContextObservation {
    var loads=0,cancelledAtExit=false
    var continuation:CheckedContinuation<WindowContext?,Never>?
    let entered=XCTestExpectation(description:"owned shared context read")
    func read(_ identity:WindowContext) async ->WindowContext? {
        loads+=1
        if loads==1 {let result=await withCheckedContinuation {continuation=$0;entered.fulfill()};cancelledAtExit=Task.isCancelled;return result}
        var result=identity;result.title="Fresh \(loads)";return result
    }
    func resolve(_ value:WindowContext?){continuation?.resume(returning:value);continuation=nil}
}
@MainActor final class AccessibilityCoordinatorTests:XCTestCase {
    private var identity:WindowContext {WindowContext(app:"Owned",bundle:"org.fixture",pid:8123,title:"Owned",accessibilityText:"",secure:false)}
    private func wait(_ condition:()->Bool) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !condition(),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(1))};XCTAssertTrue(condition())
    }
    func testConcurrentReadersShareOnlyTheCurrentObservationAndKeepMainActorResponsive() async throws {
        let source=ContextObservation(),coordinator=AccessibilityContextCoordinator(operation:source.read),identity=self.identity
        let first=Task {await coordinator.read(identity)},second=Task {await coordinator.read(identity)}
        await fulfillment(of:[source.entered],timeout:5);try await wait {coordinator.observerCount==2}
        let tick=Task {@MainActor in 42},result=await tick.value;XCTAssertEqual(result,42);XCTAssertEqual(source.loads,1)
        source.resolve(identity);let a=await first.value,b=await second.value;XCTAssertEqual(a?.title,"Owned");XCTAssertEqual(b?.title,"Owned")
        let fresh=await coordinator.read(identity);XCTAssertEqual(fresh?.title,"Fresh 2");XCTAssertEqual(source.loads,2)
    }
    func testCancellingOneConsumerCannotCancelAnotherConsumersObservation() async throws {
        let source=ContextObservation(),coordinator=AccessibilityContextCoordinator(operation:source.read),identity=self.identity
        let first=Task {await coordinator.read(identity)},second=Task {await coordinator.read(identity)}
        await fulfillment(of:[source.entered],timeout:5);try await wait {coordinator.observerCount==2};first.cancel();try await wait {coordinator.observerCount==1}
        source.resolve(identity);let a=await first.value,b=await second.value;XCTAssertNil(a);XCTAssertEqual(b?.title,"Owned");XCTAssertFalse(source.cancelledAtExit)
    }
    func testLastCancellationRetainsSlotUntilCompletionAndNewReaderStartsFresh() async throws {
        let source=ContextObservation(),coordinator=AccessibilityContextCoordinator(operation:source.read),identity=self.identity
        let old=Task {await coordinator.read(identity)};await fulfillment(of:[source.entered],timeout:5)
        old.cancel();try await wait {coordinator.observerCount==0}
        let fresh=Task {await coordinator.read(identity)};await Task.yield();XCTAssertEqual(source.loads,1)
        source.resolve(identity);let a=await old.value,b=await fresh.value;XCTAssertNil(a);XCTAssertTrue(source.cancelledAtExit);XCTAssertEqual(b?.title,"Fresh 2")
    }
    func testDifferentApplicationCannotReuseAnotherTargetsResult() async throws {
        let source=ContextObservation(),coordinator=AccessibilityContextCoordinator(operation:source.read),identity=self.identity
        var changed=identity;changed.pid=9123;changed.bundle="org.other"
        let first=Task {await coordinator.read(identity)};await fulfillment(of:[source.entered],timeout:5)
        let second=Task {await coordinator.read(changed)};await Task.yield();XCTAssertEqual(source.loads,1)
        source.resolve(identity);_=await first.value;let other=await second.value;XCTAssertEqual(other?.pid,9123);XCTAssertEqual(other?.bundle,"org.other");XCTAssertEqual(source.loads,2)
    }
    func testIndependentSessionCancellationReleasesOnlyItsOwnLease() async throws {
        let source=ContextObservation(),coordinator=AccessibilityContextCoordinator(operation:source.read),identity=self.identity
        let a=AccessibilityReadSession(operation:{_ in await coordinator.read(identity)}),b=AccessibilityReadSession(operation:{_ in await coordinator.read(identity)})
        let first=Task {await a.read(nil)},second=Task {await b.read(nil)}
        await fulfillment(of:[source.entered],timeout:5);try await wait {coordinator.observerCount==2};a.cancel();try await wait {coordinator.observerCount==1}
        source.resolve(identity);let av=await first.value,bv=await second.value;XCTAssertNil(av);XCTAssertNotNil(bv);XCTAssertFalse(source.cancelledAtExit)
    }
    func testObserverCapDoesNotCreateMoreIPCJobs() async throws {
        let source=ContextObservation(),coordinator=AccessibilityContextCoordinator(operation:source.read),identity=self.identity
        var declined=0
        let tasks=(0..<9).map {_ in Task {let result=await coordinator.read(identity);if result==nil {declined+=1};return result}}
        await fulfillment(of:[source.entered],timeout:5);try await wait {coordinator.observerCount==8 && declined==1};source.resolve(identity)
        var accepted=0
        for task in tasks {if await task.value != nil {accepted+=1}}
        XCTAssertEqual(accepted,8);XCTAssertEqual(source.loads,1)
    }
    func testFullRequestWaitsForNarrowBindingReadAndStartsItsOwnCompleteObservation() async throws {
        let entered=XCTestExpectation(description:"binding IPC in flight")
        var resolve:CheckedContinuation<WindowContext?,Never>?,scopes=[AccessibilityReadScope](),requested=false
        let identity=self.identity,coordinator=AccessibilityContextCoordinator(scopedOperation:{context,scope in
            scopes.append(scope)
            if scope == .binding {return await withCheckedContinuation {resolve=$0;entered.fulfill()}}
            var result=context;result.accessibilityText="Complete current tree";result.secure=true;return result
        })
        let metadata=Task {await coordinator.read(identity,scope:.binding)};await fulfillment(of:[entered],timeout:5)
        let full=Task {requested=true;return await coordinator.read(identity,scope:.full)}
        try await wait {requested};await Task.yield();XCTAssertEqual(scopes,[.binding])
        resolve?.resume(returning:identity)
        let narrow=await metadata.value,complete=await full.value
        XCTAssertEqual(narrow?.accessibilityText,"");XCTAssertEqual(complete?.accessibilityText,"Complete current tree");XCTAssertTrue(complete?.secure==true)
        XCTAssertEqual(scopes,[.binding,.full])
    }
    func testBindingRequestCanJoinAlreadyRunningCompleteObservationWithoutAnotherIPCJob() async throws {
        let entered=XCTestExpectation(description:"full IPC in flight")
        var resolve:CheckedContinuation<WindowContext?,Never>?,scopes=[AccessibilityReadScope]()
        let identity=self.identity,coordinator=AccessibilityContextCoordinator(scopedOperation:{_,scope in scopes.append(scope);return await withCheckedContinuation {resolve=$0;entered.fulfill()}})
        let full=Task {await coordinator.read(identity,scope:.full)};await fulfillment(of:[entered],timeout:5)
        let metadata=Task {await coordinator.read(identity,scope:.binding)};try await wait {coordinator.observerCount==2}
        var complete=identity;complete.accessibilityText="Owned complete tree";resolve?.resume(returning:complete)
        let a=await full.value,b=await metadata.value;XCTAssertEqual(a?.accessibilityText,b?.accessibilityText);XCTAssertEqual(scopes,[.full])
    }
}
