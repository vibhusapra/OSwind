import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class LocalAnswerPreparationModelTests: XCTestCase {
    let answer = "http://127.0.0.1:19481", search = "http://127.0.0.1:19482"
    actor Gate {
        let entered = XCTestExpectation(description: "model load entered")
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
        func open() { continuation?.resume(); continuation = nil }
    }
    actor Calls {
        var values: [String] = []
        func add(_ value: String) { values.append(value) }
    }
    nonisolated static func observation(_ model: String, _ endpoint: String, requested: String? = nil, observed: Date = Date(), expiry: Date = Date().addingTimeInterval(300), bytes: Int64 = 4096, context: Int? = 8192) -> LocalModelPreparation {
        LocalModelPreparation(endpoint: endpoint, requestedModel: requested ?? model, model: model, digest: String(repeating: "a", count: 64), observedAt: observed, serverExpiresAt: expiry, residentBytes: bytes, gpuBytes: 2048, contextLength: context, serverLoadNanoseconds: 10, elapsedSeconds: 0.01)
    }
    func operations(_ calls: Calls) -> LocalModelLibraryOperations {
        LocalModelLibraryOperations(models: { _ in await calls.add("inspect"); return [] }, runtime: { _ in "" }, pull: { _, _, _ in await calls.add("pull") }, start: { _ in await calls.add("start"); return "owned start" }, prepare: { model, endpoint in await calls.add("prepare " + model + " " + endpoint); return Self.observation(model, endpoint) })
    }
    func idle(_ library: LocalModelLibraryModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while library.busy && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(library.busy)
    }
    func testLoadAlwaysUsesSelectedAnswerIdentityDespiteSearchLibrarySelection() async throws {
        let calls = Calls(), library = LocalModelLibraryModel(operations: operations(calls))
        library.configure(answer: answer, search: search, answerModel: "owned:answer"); library.select(.search)
        library.prepareAnswer(); try await idle(library)
        let seen = await calls.values; XCTAssertEqual(seen, ["prepare owned:answer " + answer])
        XCTAssertEqual(library.prepared?.model, "owned:answer"); XCTAssertEqual(library.prepared?.endpoint, answer)
        XCTAssertEqual(library.role, .search); XCTAssertTrue(library.canPrepareAnswer)
    }
    func testCancelOwnsTaskUntilExitAndCannotPublishLateSuccessOrOverlapMutations() async throws {
        let gate = Gate(), calls = Calls(); var ops = operations(calls)
        ops.prepare = { model, endpoint in await calls.add("prepare"); await gate.wait(); return Self.observation(model, endpoint) }
        let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search, answerModel: "owned:answer")
        library.prepareAnswer(); await fulfillment(of: [gate.entered], timeout: 5)
        library.cancelPreparation(); library.prepareAnswer(); library.pull("blocked"); library.startServer()
        XCTAssertTrue(library.busy); XCTAssertFalse(library.canPrepareAnswer); XCTAssertTrue(library.preparing?.cancelling == true)
        await gate.open(); try await idle(library)
        let seen = await calls.values; XCTAssertEqual(seen, ["prepare"])
        XCTAssertNil(library.prepared); XCTAssertNil(library.preparing); XCTAssertTrue(library.preparationStatus?.contains("cancelled") == true)
    }
    func testChangingModelAndReturningToSameNameStillRejectsOriginalLoad() async throws {
        let gate = Gate(), calls = Calls(); var ops = operations(calls)
        ops.prepare = { model, endpoint in await calls.add("prepare"); await gate.wait(); return Self.observation(model, endpoint) }
        let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search, answerModel: "owned:first")
        library.prepareAnswer(); await fulfillment(of: [gate.entered], timeout: 5)
        library.configure(answer: answer, search: search, answerModel: "owned:second")
        library.configure(answer: answer, search: search, answerModel: "owned:first")
        XCTAssertFalse(library.canPrepareAnswer); await gate.open(); try await idle(library)
        XCTAssertNil(library.prepared); XCTAssertNil(library.preparationStatus); XCTAssertTrue(library.canPrepareAnswer)
    }
    func testEndpointChangeRejectsLateFailureWithoutReplacingNewSelectionStatus() async throws {
        let gate = Gate(), calls = Calls(); var ops = operations(calls)
        ops.prepare = { _, _ in await gate.wait(); throw OSwindError.network("old endpoint failure") }
        let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search, answerModel: "owned:answer")
        library.prepareAnswer(); await fulfillment(of: [gate.entered], timeout: 5)
        library.configure(answer: search, search: search, answerModel: "owned:answer"); await gate.open(); try await idle(library)
        XCTAssertNil(library.prepared); XCTAssertNil(library.preparationStatus); XCTAssertEqual(library.endpoints[.answer], search)
    }
    func testIndependentSearchChangesDoNotInvalidateAnswerLoad() async throws {
        let gate = Gate(), calls = Calls(); var ops = operations(calls)
        ops.prepare = { model, endpoint in await gate.wait(); return Self.observation(model, endpoint) }
        let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search, answerModel: "owned:answer")
        library.prepareAnswer(); await fulfillment(of: [gate.entered], timeout: 5)
        library.configure(answer: answer, search: "http://127.0.0.1:19483", answerModel: "owned:answer")
        await gate.open(); try await idle(library); XCTAssertEqual(library.prepared?.endpoint, answer)
    }
    func testWrongIdentityExpiredAndEmptyResidencyReceiptsCannotAppearLoaded() async throws {
        let answer = answer
        let receipts = [Self.observation("other:answer", answer), Self.observation("owned:answer", "http://127.0.0.1:19483"), Self.observation("owned:answer", answer, requested: "other:requested"), Self.observation("owned:answer", answer, expiry: Date().addingTimeInterval(-1)), Self.observation("owned:answer", answer, bytes: 0), Self.observation("owned:answer",answer,context:262144), Self.observation("owned:answer",answer,context:nil)]
        for receipt in receipts {
            var ops = operations(Calls()); ops.prepare = { _, _ in receipt }
            let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search, answerModel: "owned:answer")
            library.prepareAnswer(); try await idle(library); XCTAssertNil(library.prepared)
            XCTAssertTrue(library.preparationStatus?.contains("did not match") == true)
        }
    }
    func testUntypedMissingAndNonlocalAnswerSelectionsCannotStartLoading() async throws {
        let calls = Calls(), library = LocalModelLibraryModel(operations: operations(calls))
        library.configure(answer: nil, search: search, answerModel: "owned:answer"); library.prepareAnswer()
        library.configure(answer: answer, search: search); library.prepareAnswer()
        library.configure(answer: answer, search: search, answerModel: " "); library.prepareAnswer()
        library.configure(answer: "https://example.invalid", search: search, answerModel: "owned:answer"); library.prepareAnswer()
        try await idle(library); let seen = await calls.values; XCTAssertTrue(seen.isEmpty); XCTAssertNil(library.prepared)
    }
    func testAppModelLoadPreservesSavedConfigurationAndDoesNotStartCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls(), library = LocalModelLibraryModel(operations: operations(calls))
        let app = try AppModel(root: root, startServices: false, localModelSetup: library)
        app.showOnboarding = false; app.settings.ai.provider = .ollama; app.settings.ai.endpoint = answer; app.settings.ai.model = "owned:answer"; app.settings.search.endpoint = search
        let bytes = try Data(contentsOf: root.appendingPathComponent("settings.json"))
        library.prepareAnswer(); try await idle(library)
        XCTAssertEqual(library.prepared?.requestedModel, app.settings.ai.model)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("settings.json")), bytes)
        XCTAssertFalse(app.capture.running); XCTAssertFalse(app.audio.running)
        app.prepareForLibrarySwitch(); await app.cancelExternalWorkAndWait(); try app.store.close()
    }
    func testAppRetirementAndDrainWaitForOriginalLoadBeforeClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate(), calls = Calls(); var ops = operations(calls)
        ops.prepare = { model, endpoint in await calls.add("prepare"); await gate.wait(); return Self.observation(model, endpoint) }
        let library = LocalModelLibraryModel(operations: ops), app = try AppModel(root: root, startServices: false, localModelSetup: library)
        app.showOnboarding = false; app.settings.ai.provider = .ollama; app.settings.ai.endpoint = answer; app.settings.ai.model = "owned:answer"
        library.prepareAnswer(); await fulfillment(of: [gate.entered], timeout: 5); XCTAssertTrue(app.hasPendingExitWork)
        app.prepareForLibrarySwitch(); var drained = false
        let entered = expectation(description: "app drain entered"), task = Task { entered.fulfill(); await app.cancelExternalWorkAndWait(); drained = true }
        await fulfillment(of: [entered], timeout: 5); XCTAssertFalse(drained); XCTAssertFalse(app.store.isClosed); XCTAssertTrue(library.busy)
        library.prepareAnswer(); await gate.open(); await task.value
        XCTAssertTrue(drained); XCTAssertFalse(library.busy); XCTAssertNil(library.prepared); XCTAssertNil(library.preparationStatus)
        let seen = await calls.values; XCTAssertEqual(seen, ["prepare"]); XCTAssertEqual(app.settings.ai.model, "owned:answer")
        try app.store.close()
    }
}
