import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class LocalAnswerPreparationHTTPTests: XCTestCase {
    func idle(_ library: LocalModelLibraryModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while library.busy && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(library.busy)
    }
    func testTwoActualHTTPDestinationsReceiveOnlyEmptyFiniteAnswerLoads() async throws {
        let first = try OwnedModelLibraryHTTPServer(model: "owned:first", preparationEnabled: true)
        let second = try OwnedModelLibraryHTTPServer(model: "owned:second", preparationEnabled: true)
        defer { first.stop(); second.stop() }
        await fulfillment(of: [first.ready, second.ready], timeout: 5)
        let client = OllamaClient()
        let operations = LocalModelLibraryOperations(models: { try await client.models(endpoint: $0) }, runtime: { try await client.runtime(endpoint: $0) }, pull: { try await client.pull($0, endpoint: $1, progress: $2) }, start: { _ in throw OSwindError.unavailable("No process startup in this fixture") }, prepare: { try await client.prepare($0, endpoint: $1) })
        let library = LocalModelLibraryModel(operations: operations)
        library.configure(answer: first.endpoint, search: second.endpoint, answerModel: "owned:first"); library.select(.search)
        library.prepareAnswer(); try await idle(library)
        XCTAssertEqual(library.prepared?.endpoint, first.endpoint); XCTAssertEqual(library.prepared?.model, "owned:first")
        XCTAssertTrue(second.snapshot().isEmpty, "Search selection must not redirect the answer load")
        library.configure(answer: second.endpoint, search: second.endpoint, answerModel: "owned:second")
        XCTAssertNil(library.prepared); library.prepareAnswer(); try await idle(library)
        XCTAssertEqual(library.prepared?.endpoint, second.endpoint); XCTAssertEqual(library.prepared?.model, "owned:second")
        for (server, model) in [(first, "owned:first"), (second, "owned:second")] {
            let rows = server.snapshot(); XCTAssertEqual(rows.map(\.path), ["/api/tags", "/api/generate", "/api/tags", "/api/ps"])
            let posts = rows.filter { $0.method == "POST" }; XCTAssertEqual(posts.count, 1)
            XCTAssertEqual(posts.first?.model, model); XCTAssertEqual(posts.first?.bodyKeys, ["model", "stream", "keep_alive", "options"])
            XCTAssertEqual(posts.first?.numContext,8192); XCTAssertEqual(posts.first?.optionKeys,["num_ctx"])
            XCTAssertEqual(posts.first?.stream, false); XCTAssertEqual(posts.first?.keepAlive, "5m")
            XCTAssertTrue(rows.allSatisfy(\.authorizationAbsent)); XCTAssertEqual(library.prepared?.residentBytes, 4096)
        }
        await library.cancelAndWait(); first.stop(); second.stop()
        await fulfillment(of: [first.stopped, second.stopped], timeout: 5)
    }
    func testLoadAndActualAnswerRequestsShareTheExistingContextWindow() async throws {
        let server = try OwnedModelLibraryHTTPServer(model:"owned:answer",preparationEnabled:true)
        defer {server.stop()};await fulfillment(of:[server.ready],timeout:5)
        let client = OllamaClient();_ = try await client.prepare("owned:answer",endpoint:server.endpoint)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root);defer {try? store.close()}
        try store.insert(Memory(id:"owned-context-contract",text:"Rima owns the Cobalt handoff checklist."))
        var configuration = AIConfiguration();configuration.provider = .ollama;configuration.endpoint = server.endpoint;configuration.model = "owned:answer"
        let answer = try await AnswerEngine(store:store,embedder:LocalEmbedder()).answer("Who owns Cobalt handoff checklist?",configuration:configuration,interpretQuery:false)
        XCTAssertTrue(answer.text.contains("Rima"));XCTAssertEqual(answer.sources.first?.id,"owned-context-contract")
        let posts = server.snapshot().filter {$0.method=="POST"};XCTAssertEqual(posts.map(\.path),["/api/generate","/api/chat"])
        XCTAssertEqual(posts.map(\.numContext),[8192,8192]);XCTAssertEqual(posts[0].optionKeys,["num_ctx"])
        XCTAssertEqual(posts[1].numPredict,1000);XCTAssertEqual(posts[1].temperature,0.2);XCTAssertEqual(posts[1].think,false)
        server.stop();await fulfillment(of:[server.stopped],timeout:5)
    }
}
