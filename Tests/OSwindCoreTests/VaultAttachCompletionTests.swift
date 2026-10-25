import XCTest
@testable import OSwindCore

private actor AttachProofGate {
    var continuation:CheckedContinuation<Void,Never>?
    var released=false
    let entered=XCTestExpectation(description:"owned attach stage entered")
    func wait() async {entered.fulfill();if !released {await withCheckedContinuation {continuation=$0}}}
    func resume() {released=true;continuation?.resume();continuation=nil}
}
private actor AttachProofEvents {
    var values=[String](),finished=false
    func record(_ value:String) {values.append(value)}
    func finish() {finished=true}
}
@MainActor final class VaultAttachCompletionTests:XCTestCase {
    func testCancellationWaitsForProofAndItsExactCleanupBeforeReturning() async throws {
        let action=AttachProofGate(),cleanup=AttachProofGate(),events=AttachProofEvents()
        let worker=Task {
            let result:Result<Int,Error>
            do {result = .success(try await VaultAttachCompletion.run(action:{
                await action.wait();try Task.checkCancellation();await events.record("proof");return 417
            },cancelled:{proof in
                XCTAssertEqual(proof,417);try Task.checkCancellation();await events.record("cleanup");await cleanup.wait();try Task.checkCancellation();await events.record("detached")
            }))} catch {result = .failure(error)}
            await events.finish();return try result.get()
        }
        await fulfillment(of:[action.entered],timeout:5);worker.cancel()
        let beforeProof=await events.values;XCTAssertTrue(beforeProof.isEmpty)
        await action.resume();await fulfillment(of:[cleanup.entered],timeout:5)
        let premature=await events.finished;XCTAssertFalse(premature)
        let during=await events.values;XCTAssertEqual(during,["proof","cleanup"])
        await cleanup.resume()
        do {_ = try await worker.value;XCTFail("Cancelled attach published success")}catch is CancellationError {} catch {throw error}
        let completed=await events.values;XCTAssertEqual(completed,["proof","cleanup","detached"])
    }
    func testAlreadyCancelledAttachDoesNotLaunchOrCleanUp() async throws {
        let events=AttachProofEvents()
        let worker=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            return try await VaultAttachCompletion.run(action:{await events.record("action");return 1},cancelled:{_ in await events.record("cleanup")})
        }
        do {_ = try await worker.value;XCTFail("Already cancelled attach ran")}catch is CancellationError {} catch {throw error}
        let values=await events.values;XCTAssertTrue(values.isEmpty)
    }
    func testSuccessfulAttachReturnsProofWithoutCleanup() async throws {
        let events=AttachProofEvents()
        let proof=try await VaultAttachCompletion.run(action:{417},cancelled:{_ in await events.record("unexpected")})
        XCTAssertEqual(proof,417);let values=await events.values;XCTAssertTrue(values.isEmpty)
    }
    func testActionFailureHasNoKnownProofToCleanUp() async throws {
        let events=AttachProofEvents()
        do {let _:Int=try await VaultAttachCompletion.run(action:{throw OSwindError.invalid("owned action failure")},cancelled:{_ in await events.record("unexpected")});XCTFail("Action failure published success")}
        catch {XCTAssertEqual(error.localizedDescription,"owned action failure")}
        let values=await events.values;XCTAssertTrue(values.isEmpty)
    }
    func testCancelledCleanupFailureIsVisibleInsteadOfAcknowledgingCancellation() async throws {
        let action=AttachProofGate(),events=AttachProofEvents()
        let worker=Task {
            try await VaultAttachCompletion.run(action:{await action.wait();return 417},cancelled:{proof in
                XCTAssertEqual(proof,417);await events.record("attempted");throw OSwindError.unavailable("owned image still attached")
            })
        }
        await fulfillment(of:[action.entered],timeout:5);worker.cancel();await action.resume()
        do {_ = try await worker.value;XCTFail("Failed cleanup published success")}
        catch is CancellationError {XCTFail("Failed cleanup was silently acknowledged as cancellation")}
        catch {XCTAssertEqual(error.localizedDescription,"owned image still attached")}
        let values=await events.values;XCTAssertEqual(values,["attempted"])
    }
}
