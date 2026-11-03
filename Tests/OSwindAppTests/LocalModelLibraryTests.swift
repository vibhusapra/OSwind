import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class LocalModelLibraryTests: XCTestCase {
    let answer = "http://127.0.0.1:19181", search = "http://127.0.0.1:19182"
    actor Gate {
        let entered = XCTestExpectation(description: "owned operation entered")
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
        func open() { continuation?.resume(); continuation = nil }
    }
    actor Calls {
        var values: [String] = []
        func add(_ value: String) { values.append(value) }
    }
    func model(_ name: String) throws -> InstalledModel {
        try JSONDecoder().decode(InstalledModel.self, from: JSONSerialization.data(withJSONObject: ["name": name, "digest": "owned-" + name, "size": 10]))
    }
    func operations(_ calls: Calls) -> LocalModelLibraryOperations {
        LocalModelLibraryOperations(models: { endpoint in await calls.add("models " + endpoint); return [] }, runtime: { endpoint in await calls.add("runtime " + endpoint); return "owned runtime" }, pull: { name, endpoint, _ in await calls.add("pull " + name + " " + endpoint) }, start: { endpoint in await calls.add("start " + endpoint); return "owned start" })
    }
    func idle(_ library: LocalModelLibraryModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while library.busy && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(library.busy)
    }
    func testDistinctAnswerAndSearchDestinationsRouteDiscoveryPullAndStart() async throws {
        let calls = Calls(), library = LocalModelLibraryModel(operations: operations(calls))
        library.configure(answer: answer, search: search)
        library.inspect(.answer); try await idle(library)
        library.pull("owned-chat"); try await idle(library)
        library.startServer(); try await idle(library)
        library.inspect(.search); try await idle(library)
        library.pull("owned-embedding"); try await idle(library)
        library.startServer(); try await idle(library)
        let seen = await calls.values
        for endpoint in [answer, search] { XCTAssertTrue(seen.contains("models " + endpoint)); XCTAssertTrue(seen.contains("runtime " + endpoint)); XCTAssertTrue(seen.contains("start " + endpoint)) }
        XCTAssertEqual(seen.filter { $0.hasPrefix("pull ") }, ["pull owned-chat " + answer, "pull owned-embedding " + search])
        XCTAssertEqual(library.endpoint, search)
    }
    func testInstalledListsStayWithTheirEndpointAndSharedServerWorks() async throws {
        let chat = try model("owned-chat"), embedding = try model("owned-embed"), answer = answer
        var ops = operations(Calls()); ops.models = { $0 == answer ? [chat] : [embedding] }
        let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search)
        library.inspect(.answer); try await idle(library); library.inspect(.search); try await idle(library)
        XCTAssertEqual(library.models(for: .answer).map(\.name), [chat.name]); XCTAssertEqual(library.models(for: .search).map(\.name), [embedding.name])
        library.configure(answer: search, search: search)
        XCTAssertEqual(library.models(for: .answer).map(\.name), [embedding.name])
        library.configure(answer: "http://127.0.0.1:19183", search: search)
        XCTAssertTrue(library.models(for: .answer).isEmpty); XCTAssertEqual(library.models(for: .search).map(\.name), [embedding.name])
    }
    func testOlderSameEndpointSuccessCannotReplaceNewerInspection() async throws {
        let gate = Gate(), calls = Calls(), old = try model("old"), current = try model("current")
        var ops = operations(calls)
        ops.models = { _ in await calls.add("inspect"); if await calls.values.count == 1 { await gate.wait(); return [old] }; return [current] }
        let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search)
        library.inspect(.answer); await fulfillment(of: [gate.entered], timeout: 5)
        library.inspect(.answer)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while library.models(for: .answer).first?.name != "current" && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        await gate.open(); try await idle(library)
        XCTAssertEqual(library.models(for: .answer).map(\.name), ["current"])
    }
    func testEndpointChangeAndBackRejectsOldFailure() async throws {
        let gate = Gate(), calls = Calls(), current = try model("current")
        var ops = operations(calls)
        ops.models = { _ in await calls.add("inspect"); if await calls.values.count == 1 { await gate.wait(); throw OSwindError.network("stale failure") }; return [current] }
        let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search)
        library.inspect(.answer); await fulfillment(of: [gate.entered], timeout: 5)
        library.configure(answer: search, search: search); library.configure(answer: answer, search: search)
        library.inspect(.answer); await gate.open(); try await idle(library)
        XCTAssertEqual(library.models(for: .answer).map(\.name), ["current"])
        XCTAssertFalse(library.listing.status.contains("stale"))
    }
    func testRuntimeFailureKeepsSuccessfulInstalledList() async throws {
        let installed = try model("available"), calls = Calls(); var ops = operations(calls)
        ops.models = { _ in [installed] }; ops.runtime = { _ in throw OSwindError.network("owned telemetry unavailable") }
        let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search); library.inspect(.answer); try await idle(library)
        XCTAssertEqual(library.listing.models.map(\.name), ["available"]); XCTAssertTrue(library.listing.runtimeWarning?.contains("telemetry unavailable") == true)
        XCTAssertFalse(library.listing.checking)
    }
    func testCancelledPullKeepsOwnershipAndSuppressesLateProgressAndSuccess() async throws {
        let gate = Gate(), calls = Calls(); var ops = operations(calls)
        ops.pull = { name, endpoint, progress in
            await calls.add("pull " + name + " " + endpoint); progress(ModelPullProgress(status: "first", total: 10, completed: 1)); await gate.wait()
            progress(ModelPullProgress(status: "late success", total: 10, completed: 10))
        }
        let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search)
        library.pull("original"); await fulfillment(of: [gate.entered], timeout: 5)
        library.select(.search); library.configure(answer: "http://127.0.0.1:19183", search: search)
        XCTAssertEqual(library.download?.endpoint, answer)
        library.cancelDownload(); library.pull("must-not-start")
        XCTAssertTrue(library.busy); XCTAssertTrue(library.download?.cancelling == true)
        await gate.open(); try await idle(library)
        let seen = await calls.values; XCTAssertEqual(seen, ["pull original " + answer])
        XCTAssertNil(library.download); XCTAssertTrue(library.downloadOutcome?.contains("cancelled") == true); XCTAssertTrue(library.downloadOutcome?.contains(answer) == true)
        XCTAssertFalse(library.downloadOutcome?.contains("Downloaded original") == true)
    }
    func testRetirementDrainWaitsForActualWorkAndBlocksNewRequests() async throws {
        let gate = Gate(), calls = Calls(); var ops = operations(calls)
        ops.pull = { _, _, _ in await calls.add("pull"); await gate.wait() }
        let library = LocalModelLibraryModel(operations: ops); library.configure(answer: answer, search: search)
        library.pull("owned"); await fulfillment(of: [gate.entered], timeout: 5)
        library.retire(); var drained = false
        let drain = Task { await library.cancelAndWait(); drained = true }
        await Task.yield(); XCTAssertFalse(drained); XCTAssertTrue(library.busy)
        library.inspect(.answer); library.pull("blocked"); library.startServer()
        await gate.open(); await drain.value
        XCTAssertTrue(drained); XCTAssertFalse(library.busy); XCTAssertTrue(library.listings.isEmpty); XCTAssertNil(library.downloadOutcome)
        let seen = await calls.values; XCTAssertEqual(seen, ["pull"])
    }
    func testNonlocalEndpointsCloudAliasesAndUnavailableRoleDoNotCallTransport() async throws {
        let calls = Calls(), library = LocalModelLibraryModel(operations: operations(calls))
        library.configure(answer: nil, search: search); library.inspect(.answer); XCTAssertFalse(library.busy)
        library.configure(answer: "https://example.invalid", search: search)
        library.select(.answer); library.inspect(); library.startServer(); library.pull("local")
        library.select(.search); library.pull("owned:cloud"); library.pull("owned-cloud")
        try await idle(library); let seen = await calls.values; XCTAssertTrue(seen.isEmpty)
    }
    func testAppSettingsAndRetirementWireControllerWithoutStartingCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls(), library = LocalModelLibraryModel(operations: operations(calls))
        let app = try AppModel(root: root, startServices: false, localModelSetup: library)
        app.showOnboarding = false
        app.settings.ai.provider = .ollama; app.settings.ai.endpoint = answer; app.settings.search.endpoint = search
        let originalAI = app.settings.ai, originalSearch = app.settings.search
        library.inspect(.answer); try await idle(library); library.inspect(.search); try await idle(library)
        let seen = await calls.values
        XCTAssertTrue(seen.contains("models " + answer)); XCTAssertTrue(seen.contains("models " + search))
        XCTAssertEqual(app.settings.ai, originalAI); XCTAssertEqual(app.settings.search, originalSearch)
        XCTAssertEqual(AppSettings.load(root: root).ai, originalAI); XCTAssertEqual(AppSettings.load(root: root).search, originalSearch)
        XCTAssertFalse(app.capture.running); XCTAssertFalse(app.audio.running)
        app.prepareForLibrarySwitch(); await app.cancelExternalWorkAndWait()
        library.inspect(.search); XCTAssertFalse(library.busy); XCTAssertFalse(library.canWork)
        try app.store.close()
    }
}
