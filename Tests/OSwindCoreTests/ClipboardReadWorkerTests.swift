import XCTest
@testable import OSwindCore

final class ClipboardOwnedReadGate:@unchecked Sendable {
    private let condition=NSCondition();private var started=false,open=false
    var entered:Bool {condition.lock();defer {condition.unlock()};return started}
    func wait()throws->Int {
        condition.lock();defer {condition.unlock()};started=true;let deadline=Date().addingTimeInterval(5)
        while !open {guard condition.wait(until:deadline) else {throw OSwindError.unavailable("Owned provider gate expired")}}
        return 7
    }
    func release(){condition.lock();open=true;condition.broadcast();condition.unlock()}
}
final class ClipboardOwnedDeadline:@unchecked Sendable {
    private let lock=NSLock();private var callback:(@Sendable ()->Void)?
    func arm(_ body:@escaping @Sendable ()->Void){lock.lock();callback=body;lock.unlock()}
    func fire(){lock.lock();let body=callback;callback=nil;lock.unlock();body?()}
}
final class ClipboardReadWorkerTests:XCTestCase {
    func settle(_ condition:@escaping ()->Bool)async throws {
        let until=ContinuousClock.now.advanced(by:.seconds(3));while !condition() {guard ContinuousClock.now<until else {XCTFail("Owned clipboard worker did not settle");return};try await Task.sleep(for:.milliseconds(5))}
    }
    func testDeadlineReleasesWaiterButKeepsOnlyOneActualProvider()async throws {
        let deadline=ClipboardOwnedDeadline(),worker=ClipboardReadWorker(schedule:{_,body in deadline.arm(body)}),gate=ClipboardOwnedReadGate();defer {gate.release()}
        let task=Task {try await worker.read {try gate.wait()}}
        try await settle {gate.entered};deadline.fire()
        do {_ = try await task.value;XCTFail("Deadline must refuse a still-blocked provider")}catch ClipboardReadFailure.timedOut {}catch {XCTFail("Unexpected error: \(error)")}
        XCTAssertTrue(worker.occupied)
        do {_ = try await worker.read {XCTFail("A second provider was launched");return 9};XCTFail("Occupied reader must refuse")}catch ClipboardReadFailure.occupied {}catch {XCTFail("Unexpected error: \(error)")}
        gate.release();try await settle {!worker.occupied};let next=try await worker.read {11};XCTAssertEqual(next,11)
    }
    func testCancellationReturnsWithoutReleasingActualProviderSlot()async throws {
        let worker=ClipboardReadWorker(),gate=ClipboardOwnedReadGate();defer {gate.release()}
        let task=Task {try await worker.read {try gate.wait()}};try await settle {gate.entered};task.cancel()
        do {_ = try await task.value;XCTFail("Cancelled waiter must not receive late provider data")}catch is CancellationError {}catch {XCTFail("Unexpected error: \(error)")}
        XCTAssertTrue(worker.occupied);gate.release();try await settle {!worker.occupied};let next=try await worker.read {12};XCTAssertEqual(next,12)
    }
    @MainActor func testAlreadyCancelledTaskNeverStartsIO()async throws {
        let worker=ClipboardReadWorker();let task=Task {try await worker.read {XCTFail("Cancelled task touched a clipboard provider");return 1}};task.cancel()
        do {_ = try await task.value;XCTFail("Cancellation must be propagated")}catch is CancellationError {}catch {XCTFail("Unexpected error: \(error)")}
        XCTAssertFalse(worker.occupied)
    }
    func testProviderFailureAndInvalidDeadlinesLeaveNoReservedSlot()async throws {
        let worker=ClipboardReadWorker()
        do {let _:Int=try await worker.read {throw OSwindError.invalid("Owned provider refusal")};XCTFail("Provider error was hidden")}catch {}
        XCTAssertFalse(worker.occupied)
        for deadline in [Double.nan,Double.infinity,0,-1,3] {
            do {_ = try await worker.read(timeout:deadline) {XCTFail("Invalid deadline started IO");return 1};XCTFail("Invalid deadline accepted")}catch {}
            XCTAssertFalse(worker.occupied)
        }
    }
}
