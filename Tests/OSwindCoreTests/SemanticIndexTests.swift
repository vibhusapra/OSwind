import XCTest
import CSQLite
@testable import OSwindCore

private final class ModelProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int,Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (status,data) = try Self.handler!(request); let response = HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!; client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
final class SemanticIndexTests: XCTestCase {
    var root: URL!, store: MemoryStore!, client: OllamaClient!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ModelProtocol.self]; client = OllamaClient(session:URLSession(configuration:configuration))
    }
    override func tearDownWithError() throws { ModelProtocol.handler = nil; store = nil; try? FileManager.default.removeItem(at:root) }
    func response(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject:object) }
    func mock() {
        ModelProtocol.handler = { request in
            if request.url!.path == "/api/tags" { return (200,try self.response(["models":[["name":"qwen3-embedding:0.6b","digest":"fixed-digest","size":1234]]])) }
            return (200,try self.response(["embeddings":[[3.0,4.0]]]))
        }
    }
    func testLocalEndpointAndQueryInstruction() throws {
        for endpoint in ["https://api.example.com", "http://127.0.0.1.evil.com", "file:///tmp", "http://user:secret@localhost", "http://localhost?token=x"] { XCTAssertThrowsError(try OllamaClient.localURL(endpoint,path:"api/embed")) }
        XCTAssertEqual(try OllamaClient.localURL("http://127.0.0.1:11434",path:"api/embed").path,"/api/embed")
        XCTAssertTrue(OllamaClient.queryInput("what shipped?",model:"qwen3-embedding:0.6b").hasPrefix("Instruct:"))
        XCTAssertEqual(OllamaClient.queryInput("question",model:"other"),"question")
    }
    func testEmbeddingVersionNormalizationAndRequest() async throws {
        mock(); var configuration = SearchConfiguration(); configuration.provider = .ollama
        let batch = try await client.embed(["Maya ships Friday"],configuration:configuration)
        XCTAssertEqual(batch.vectors[0][0],0.6,accuracy:0.001); XCTAssertEqual(batch.vectors[0][1],0.8,accuracy:0.001)
        XCTAssertTrue(batch.modelID.contains("fixed-digest")); XCTAssertTrue(batch.modelID.hasSuffix(":d2"))
    }
    func testInvalidEmbeddingResponseFails() async throws {
        ModelProtocol.handler = { request in
            request.url!.path == "/api/tags" ? (200,try self.response(["models":[["name":"qwen3-embedding:0.6b","digest":"fixed","size":1]]])) : (200,try self.response(["embeddings":[[0,0]]]))
        }
        do { _ = try await client.embed(["test"],configuration:SearchConfiguration()); XCTFail("Accepted zero vector") } catch { XCTAssertTrue(error.localizedDescription.contains("invalid embedding")) }
    }
    func testVectorsRespectDeletionAndContentChanges() throws {
        let original = Memory(id:"a",text:"Original evidence"); try store.insert(original)
        XCTAssertEqual(try store.saveVectors([VectorRecord(memory:original,vector:[1,0])],modelID:"test-gpu"),1)
        try store.setFavorite("a",value:true); XCTAssertEqual(try store.vectorCount(modelID:"test-gpu"),1)
        let hits = try store.search(SearchFilter(query:"meaning"),mode:.semantic,vector:[1,0],modelID:"test-gpu"); XCTAssertEqual(hits.first?.id,"a")
        try store.insert(Memory(id:"a",text:"Changed evidence")); XCTAssertEqual(try store.vectorCount(modelID:"test-gpu"),0)
        XCTAssertEqual(try store.saveVectors([VectorRecord(memory:original,vector:[1,0])],modelID:"test-gpu"),0)
        try store.delete("a"); XCTAssertEqual(try store.saveVectors([VectorRecord(memory:original,vector:[1,0])],modelID:"test-gpu"),0)
    }
    func testScopedVectorsDoNotMixModels() throws {
        let a = Memory(id:"a",timestamp:Date(timeIntervalSince1970:100),app:"Safari",text:"first"), b = Memory(id:"b",timestamp:Date(timeIntervalSince1970:200),app:"Xcode",text:"second")
        try store.insert(a); try store.insert(b)
        _ = try store.saveVectors([VectorRecord(memory:a,vector:[1,0]),VectorRecord(memory:b,vector:[0,1])],modelID:"model-one")
        _ = try store.saveVectors([VectorRecord(memory:b,vector:[1,0])],modelID:"model-two")
        XCTAssertEqual(try store.search(SearchFilter(query:"topic",app:"Xcode"),mode:.semantic,vector:[1,0],modelID:"model-one").count,0)
        XCTAssertEqual(try store.search(SearchFilter(query:"topic",app:"Xcode"),mode:.semantic,vector:[1,0],modelID:"model-two").map(\.id),["b"])
        XCTAssertEqual(try store.vectorCount(modelID:"model-one",filter:SearchFilter(app:"Xcode")),1)
        try store.delete("b"); XCTAssertEqual(try store.vectorCount(modelID:"model-two"),0)
    }
    func testHybridPreservesStrongMatchWithoutSharedWords() throws {
        let translated = Memory(id:"correct",text:"王林负责键盘焦点测试。"), distractor = Memory(id:"distractor",text:"The testing book arrived on Tuesday.")
        try store.insert(translated); try store.insert(distractor)
        _ = try store.saveVectors([VectorRecord(memory:translated,vector:[1,0]),VectorRecord(memory:distractor,vector:[0.4,0.9165])],modelID:"multilingual")
        let hits = try store.search(SearchFilter(query:"Who is testing keyboard focus?"),mode:.hybrid,vector:[1,0],modelID:"multilingual",minimumSimilarity:0.25,similarityFusion:true)
        XCTAssertEqual(hits.first?.id,"correct"); XCTAssertTrue(hits.first!.score > 0)
    }
    func testModelDigestChangeFailsTheBatch() async throws {
        var tagRequests = 0
        ModelProtocol.handler = { request in
            if request.url!.path == "/api/tags" { tagRequests += 1; return (200,try self.response(["models":[["name":"qwen3-embedding:0.6b","digest":tagRequests == 1 ? "before" : "after","size":1]]])) }
            return (200,try self.response(["embeddings":[[1,0]]]))
        }
        do { _ = try await client.embed(["text"],configuration:SearchConfiguration()); XCTFail("Mixed model versions") } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }
    func testCloudAliasIsRejectedBeforeSendingText() async throws {
        var calledEmbedding = false
        ModelProtocol.handler = { request in
            if request.url!.path == "/api/embed" { calledEmbedding = true }
            return (200,try self.response(["models":[["name":"qwen3-embedding:0.6b","digest":"remote","size":0,"remote_host":"https://example.com"]]]))
        }
        do { _ = try await client.embed(["private fixture"],configuration:SearchConfiguration()); XCTFail("Allowed a cloud model") } catch { XCTAssertTrue(error.localizedDescription.contains("Cloud")) }
        XCTAssertFalse(calledEmbedding)
    }
    func testIndexBuildResumesAndDoesNotRestoreDeletedData() async throws {
        mock(); let first = Memory(id:"first",text:"first"), second = Memory(id:"second",text:"second")
        try store.insert(first); try store.insert(second)
        let identity = "ollama:qwen3-embedding:0.6b@fixed-digest:desktop-v1:d2"
        _ = try store.saveVectors([VectorRecord(memory:first,vector:[1,0])],modelID:identity)
        var configuration = SearchConfiguration(); configuration.provider = .ollama
        let engine = RetrievalEngine(store:store,client:client)
        let final = try await engine.rebuild(configuration:configuration) { _ in }
        XCTAssertEqual(final.indexed,2); XCTAssertEqual(final.total,2)
        try store.delete("first")
        let resumed = try await engine.rebuild(configuration:configuration) { _ in }
        XCTAssertEqual(resumed.indexed,1); XCTAssertNil(try store.get("first"))
    }
    func testHybridFallbackIsExplicit() async throws {
        try store.insert(Memory(text:"release checklist"))
        ModelProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        var configuration = SearchConfiguration(); configuration.provider = .ollama
        let result = try await RetrievalEngine(store:store,client:client).search(SearchFilter(query:"release"),configuration:configuration)
        XCTAssertEqual(result.hits.count,1); XCTAssertTrue(result.warnings.first!.contains("keyword"))
        do { _ = try await RetrievalEngine(store:store,client:client).search(SearchFilter(query:"release"),mode:.semantic,configuration:configuration); XCTFail("Semantic mode silently fell back") } catch { }
    }
    func testOldSettingsPreservePrivacyDuringMigration() throws {
        var settings = AppSettings(); settings.privacy.excludedDomains = ["private.example"]; settings.profile = .light
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(settings)) as! [String:Any]; object.removeValue(forKey:"search")
        let migrated = try JSONDecoder().decode(AppSettings.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(migrated.privacy.excludedDomains,["private.example"]); XCTAssertEqual(migrated.profile,.light); XCTAssertEqual(migrated.search.provider,.apple)
        object["search"] = ["indexPolicy":"a-future-strategy"]
        let forward = try JSONDecoder().decode(AppSettings.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(forward.privacy.excludedDomains,["private.example"]); XCTAssertEqual(forward.search.indexPolicy,.automatic)
    }
    func testVersionOneStoreMigratesWithoutLosingEvidenceOrLegacyVectors() throws {
        var memory = Memory(id:"legacy",text:"Archived release checklist"); memory.embedding = [1,0]; memory.embeddingModel = "apple-test"
        try store.insert(memory); store = nil
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&connection),SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,"DROP TRIGGER semantic_content_update; DROP TABLE semantic_vectors; PRAGMA user_version=1;",nil,nil,nil),SQLITE_OK)
        store = try MemoryStore(root:root)
        XCTAssertEqual(try store.get("legacy")?.text,memory.text)
        XCTAssertEqual(try store.search(SearchFilter(query:"meaning"),mode:.semantic,vector:[1,0],modelID:"apple-test").map(\.id),["legacy"])
        XCTAssertEqual(try store.saveVectors([VectorRecord(memory:memory,vector:[0,1])],modelID:"new-model"),1)
        XCTAssertEqual(try store.search(SearchFilter(query:"checklist"),mode:.keyword).first?.id,"legacy")
    }
    @MainActor func testExistingServerIsNeverOwnedOrStopped() async throws {
        mock(); let manager = LocalModelServer(client:client)
        let result = try await manager.start(endpoint:"http://127.0.0.1:11434")
        XCTAssertTrue(result.contains("already running")); XCTAssertFalse(manager.ownsRunningServer)
        manager.stopOwnedServer(); let models = try await client.models(endpoint:"http://127.0.0.1:11434"); XCTAssertEqual(models.count,1)
    }
}
