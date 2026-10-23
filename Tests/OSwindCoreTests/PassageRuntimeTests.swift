import XCTest
@testable import OSwindCore

private final class PassageProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let data = try Self.handler!(request); let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!; client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
final class PassageRuntimeTests: XCTestCase {
    var root: URL!, store: MemoryStore!, client: OllamaClient!, configuration = SearchConfiguration()
    let identity = "ollama:qwen3-embedding:0.6b@fixture:desktop-v1:d2"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root)
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [PassageProtocol.self]; client = OllamaClient(session:URLSession(configuration:session)); configuration.provider = .ollama
    }
    override func tearDownWithError() throws { PassageProtocol.handler = nil; store = nil; try? FileManager.default.removeItem(at:root) }
    func memory() -> Memory { Memory(id:"synthetic",text:String(repeating:"A long synthetic source passage. ",count:900)) }
    func mock(onEmbedding: @escaping (Int) -> Void = { _ in }) {
        PassageProtocol.handler = { request in
            if request.url!.path == "/api/tags" { return try JSONSerialization.data(withJSONObject:["models":[["name":"qwen3-embedding:0.6b","digest":"fixture","size":1]]]) }
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable { let size = stream.read(&buffer,maxLength:buffer.count); if size <= 0 { break }; data.append(contentsOf:buffer.prefix(size)) }
            }
            let body = try JSONSerialization.jsonObject(with:data) as! [String:Any], inputs = body["input"] as! [String]
            XCTAssertLessThanOrEqual(inputs.count,16); onEmbedding(inputs.count)
            return try JSONSerialization.data(withJSONObject:["embeddings":inputs.map { _ in [1.0,0.0] }])
        }
    }
    func testCancellationDuringPassageEmbeddingCannotCommitPartialSource() async throws {
        let memory = memory(); try store.insert(memory)
        let calls = Counter(), cancellation = IndexCancellation()
        mock { _ in if calls.next() == 2 { cancellation.cancel() } }
        let engine = RetrievalEngine(store:store,client:client), config = configuration
        let task = Task { try await engine.index([memory],configuration:config) }; cancellation.install(task)
        do { _ = try await task.value; XCTFail("Cancellation accepted a complete source") } catch is CancellationError {} catch { XCTFail("Unexpected: \(error)") }
        XCTAssertEqual(try store.vectorEntityCount(modelID:identity),1); XCTAssertFalse(try store.passagesCurrent(memory,modelID:identity))
        mock(); _ = try await engine.rebuild(configuration:configuration) { _ in }
        XCTAssertTrue(try store.passagesCurrent(memory,modelID:identity)); XCTAssertEqual(try store.passageBacklog(modelID:identity,filter:SearchFilter()),0)
    }
    func testPowerDeferralInsideLongSourceResumesAtSourceBoundary() async throws {
        let memory = memory(); try store.insert(memory); mock(); let engine = RetrievalEngine(store:store,client:client)
        let checks = Counter()
        do { _ = try await engine.rebuild(configuration:configuration,shouldContinue:{ checks.next() < 3 }) { _ in }; XCTFail("Expected power deferral") } catch { XCTAssertTrue(error.localizedDescription.contains("power policy")) }
        XCTAssertEqual(try store.vectorEntityCount(modelID:identity),1); XCTAssertFalse(try store.passagesCurrent(memory,modelID:identity))
        _ = try await engine.rebuild(configuration:configuration) { _ in }; XCTAssertTrue(try store.passagesCurrent(memory,modelID:identity))
    }
    func testMutationDuringEmbeddingCannotSaveStaleSourceOrPassages() async throws {
        let memory = memory(); try store.insert(memory); let calls = Counter()
        mock { _ in if calls.next() == 2 { try! self.store.insert(Memory(id:memory.id,text:"Replacement")) } }
        _ = try await RetrievalEngine(store:store,client:client).index([memory],configuration:configuration)
        XCTAssertEqual(try store.get(memory.id)?.text,"Replacement"); XCTAssertEqual(try store.vectorEntityCount(modelID:identity),0)
    }
    func testReopenedConversationRetainsValidPassageAndEditErasesTurn() throws {
        let memory = memory(); try store.insert(memory)
        let range = SemanticPassagePlan.make(memory).last!.range, session = try store.createChat()
        let answer = Answer(text:"Source [1]",sources:[SearchHit(memory:memory,score:1,match:"semantic",passage:range)],provider:"evidence",duration:0)
        _ = try store.appendChatTurn(sessionID:session.id,question:"What?",answer:answer)
        let reopened = try MemoryStore(root:root); XCTAssertEqual(try reopened.chatTurns(session.id).first?.answer.sources.first?.passage,range)
        try reopened.insert(Memory(id:memory.id,text:"Replacement")); XCTAssertTrue(try store.chatTurns(session.id).isEmpty)
    }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private final class IndexCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var task: Task<String?,Error>?; private var cancelled = false
    func install(_ task: Task<String?,Error>) { lock.lock(); defer { lock.unlock() }; self.task = task; if cancelled { task.cancel() } }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; task?.cancel() }
}
