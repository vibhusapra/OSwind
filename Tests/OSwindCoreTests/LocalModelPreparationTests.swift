import XCTest
@testable import OSwindCore

private final class PreparationHTTPProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var body: Data; var delay: Double = 0 }
    private static let registryLock = NSLock()
    private static var scripts: [String: PreparationHTTPScript] = [:]
    private let lock = NSLock(); private var stopped = false
    static func register(_ script: PreparationHTTPScript) -> String {
        let id = UUID().uuidString; registryLock.lock(); scripts[id] = script; registryLock.unlock()
        return "http://127.0.0.1:19391/" + id
    }
    static func remove(_ endpoint: String) {
        registryLock.lock(); scripts.removeValue(forKey: URL(string: endpoint)!.lastPathComponent); registryLock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.url!.pathComponents.dropFirst().first ?? ""
        Self.registryLock.lock(); let script = Self.scripts[id]; Self.registryLock.unlock()
        guard let script else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        do {
            let reply = try script.reply(request)
            let deliver: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.lock.lock(); let stopped = self.stopped; self.lock.unlock(); guard !stopped else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: reply.body); self.client?.urlProtocolDidFinishLoading(self)
            }
            if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver) } else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
private final class PreparationHTTPScript: @unchecked Sendable {
    let lock = NSLock()
    var tags: [[String: Any]], afterTags: [[String: Any]]?
    var load: [String: Any], running: [[String: Any]]
    var loadStatus = 200, loadDelay: Double = 0
    var onLoad: (() -> Void)?
    private var requests: [URLRequest] = []; private var tagCalls = 0
    init(name: String = "owned:small") {
        let digest = String(repeating: "a", count: 64)
        tags = [["name": name, "digest": digest, "size": 4000, "capabilities": ["completion"]]]
        load = ["model": name, "done": true, "response": "", "done_reason": "load", "eval_count": 0, "prompt_eval_count": 0, "load_duration": 123_000_000]
        running = [["name": name, "digest": digest, "size": 4096, "size_vram": 2048, "context_length": 8192, "expires_at": Date().addingTimeInterval(300).ISO8601Format(.init(includingFractionalSeconds: true))]]
    }
    func reply(_ original: URLRequest) throws -> PreparationHTTPProtocol.Reply {
        var request = original
        // URLSession can hand URLProtocol a body stream rather than httpBody.
        // Capture those actual bytes before returning the inert fixture reply.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating:0,count:4096)
            while true {
                let count = stream.read(&buffer,maxLength:buffer.count)
                if count == 0 { break }
                guard count > 0, body.count + count <= 65536 else { throw URLError(.cannotDecodeContentData) }
                body.append(contentsOf:buffer.prefix(count))
            }
            request.httpBody = body
        }
        lock.lock(); defer { lock.unlock() }; requests.append(request)
        let payload: [String: Any]
        if request.url!.path.hasSuffix("/api/tags") { tagCalls += 1; payload = ["models": tagCalls > 1 ? afterTags ?? tags : tags] }
        else if request.url!.path.hasSuffix("/api/generate") { onLoad?(); return .init(status: loadStatus, body: try JSONSerialization.data(withJSONObject: load), delay: loadDelay) }
        else if request.url!.path.hasSuffix("/api/ps") { payload = ["models": running] }
        else { throw URLError(.unsupportedURL) }
        return .init(body: try JSONSerialization.data(withJSONObject: payload))
    }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

final class LocalModelPreparationTests: XCTestCase {
    func client() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PreparationHTTPProtocol.self]
        return OllamaClient(session: URLSession(configuration: configuration))
    }
    private func refused(_ script: PreparationHTTPScript, name: String = "owned:small", file: StaticString = #filePath, line: UInt = #line) async {
        let endpoint = PreparationHTTPProtocol.register(script); defer { PreparationHTTPProtocol.remove(endpoint) }
        do { _ = try await client().prepare(name, endpoint: endpoint); XCTFail("Accepted an invalid preparation observation", file: file, line: line) }
        catch { XCTAssertFalse(error is CancellationError, file: file, line: line) }
    }
    func testEmptyLoadRequestUsesFiniteRetentionAndBindsResidentIdentity() async throws {
        let script = PreparationHTTPScript(), endpoint = PreparationHTTPProtocol.register(script)
        defer { PreparationHTTPProtocol.remove(endpoint) }
        let before = Date(), value = try await client().prepare("owned:small", endpoint: endpoint), after = Date()
        XCTAssertEqual(value.endpoint, endpoint); XCTAssertEqual(value.requestedModel, "owned:small"); XCTAssertEqual(value.model, "owned:small")
        XCTAssertEqual(value.digest, String(repeating: "a", count: 64)); XCTAssertEqual(value.residentBytes, 4096); XCTAssertEqual(value.gpuBytes, 2048)
        XCTAssertEqual(value.contextLength, 8192); XCTAssertEqual(value.serverLoadNanoseconds, 123_000_000)
        XCTAssertGreaterThanOrEqual(value.observedAt, before); XCTAssertLessThanOrEqual(value.observedAt, after)
        XCTAssertGreaterThan(value.observationExpiresAt, after); XCTAssertLessThanOrEqual(value.observationExpiresAt, value.observedAt.addingTimeInterval(300))
        XCTAssertGreaterThanOrEqual(value.elapsedSeconds, 0)
        let requests = script.snapshot(); XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, ["tags", "generate", "tags", "ps"])
        let post = requests[1], body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(post.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "stream", "keep_alive"]); XCTAssertEqual(body["model"] as? String, "owned:small")
        XCTAssertEqual(body["stream"] as? Bool, false); XCTAssertEqual(body["keep_alive"] as? String, "5m"); XCTAssertEqual(post.timeoutInterval, 300)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil })
    }
    func testUntaggedLatestAndRegistryPortAliasesResolveWithoutChangingRequestedName() async throws {
        for name in ["owned", "registry.local:5000/team/owned"] {
            let script = PreparationHTTPScript(name: name + ":latest"), endpoint = PreparationHTTPProtocol.register(script)
            defer { PreparationHTTPProtocol.remove(endpoint) }
            let value = try await client().prepare(name, endpoint: endpoint)
            XCTAssertEqual(value.requestedModel, name); XCTAssertEqual(value.model, name + ":latest")
        }
        let ambiguous = PreparationHTTPScript(name: "owned"); ambiguous.tags.append(PreparationHTTPScript(name: "owned:latest").tags[0])
        await refused(ambiguous, name: "owned"); XCTAssertEqual(ambiguous.snapshot().count, 1)
    }
    func testMissingRemoteEmbeddingAndUnidentifiedModelsAreRefusedBeforeLoading() async {
        let missing = PreparationHTTPScript(); missing.tags = []; await refused(missing)
        let cloud = PreparationHTTPScript(); cloud.tags[0]["remote_host"] = "https://example.invalid"; await refused(cloud)
        let alias = PreparationHTTPScript(name: "owned:cloud"); await refused(alias, name: "owned:cloud")
        let embedding = PreparationHTTPScript(); embedding.tags[0]["capabilities"] = ["embedding"]; await refused(embedding)
        let unidentified = PreparationHTTPScript(); unidentified.tags[0]["digest"] = ""; await refused(unidentified)
        for script in [missing, cloud, alias, embedding, unidentified] { XCTAssertEqual(script.snapshot().map { $0.url!.lastPathComponent }, ["tags"]) }
    }
    func testNonlocalAndEmptySelectionsAreRefusedBeforeTransport() async {
        let script = PreparationHTTPScript(), endpoint = PreparationHTTPProtocol.register(script); defer { PreparationHTTPProtocol.remove(endpoint) }
        for (name, server) in [("owned:small", "https://example.invalid"), ("owned:small", "http://user:synthetic@127.0.0.1:19391"), (" ", endpoint)] {
            do { _ = try await client().prepare(name, endpoint: server); XCTFail("Accepted invalid admission") }
            catch is OSwindError {} catch { XCTFail("Admission reached transport instead of rejecting: \(error)") }
        }
        XCTAssertTrue(script.snapshot().isEmpty)
    }
    func testIncompleteWrongModelAndGeneratedTextCannotBecomeLoadConfirmation() async {
        let alterations: [[String: Any]] = [["done": false], ["model": "other:small"], ["done_reason": "length"], ["response": "unexpected answer"], ["thinking": "unexpected reasoning"], ["eval_count": 1], ["prompt_eval_count": 1], ["load_duration": -1]]
        for alteration in alterations {
            let script = PreparationHTTPScript(); script.load.merge(alteration) { _, new in new }; await refused(script)
            XCTAssertEqual(script.snapshot().map { $0.url!.lastPathComponent }, ["tags", "generate"])
        }
        let missing = PreparationHTTPScript(); missing.load = ["error": "synthetic load failure"]; await refused(missing)
        let status = PreparationHTTPScript(); status.loadStatus = 503; await refused(status)
    }
    func testModelReplacementAndCloudRetagDuringLoadAreRefused() async {
        for key in ["digest", "remote_host"] {
            let script = PreparationHTTPScript(); script.afterTags = script.tags
            script.afterTags![0][key] = key == "digest" ? String(repeating: "b", count: 64) : "https://example.invalid"
            await refused(script); XCTAssertEqual(script.snapshot().map { $0.url!.lastPathComponent }, ["tags", "generate", "tags"])
        }
    }
    func testAbsentExpiredAmbiguousAndInvalidResidencyCannotConfirmLoaded() async {
        let mutations: [(inout [[String: Any]]) -> Void] = [
            { $0 = [] }, { $0[0]["name"] = "other:small" }, { $0[0]["digest"] = String(repeating: "b", count: 64) },
            { $0.append($0[0]) }, { $0[0]["size"] = 0 }, { $0[0]["size_vram"] = -1 }, { $0[0]["context_length"] = 0 },
            { $0[0]["expires_at"] = "not-a-date" }, { $0[0]["expires_at"] = "2020-01-01T00:00:00Z" }
        ]
        for mutate in mutations { let script = PreparationHTTPScript(); mutate(&script.running); await refused(script) }
    }
    func testOptionalResidencyFieldsAndFractionalTimezoneExpiryAreSupported() async throws {
        for expiry in ["2099-01-01T00:00:00Z", "2099-01-01T16:47:07.93355-07:00"] {
            let script = PreparationHTTPScript(); script.running[0].removeValue(forKey: "size_vram"); script.running[0].removeValue(forKey: "context_length"); script.running[0]["expires_at"] = expiry
            let endpoint = PreparationHTTPProtocol.register(script); defer { PreparationHTTPProtocol.remove(endpoint) }
            let value = try await client().prepare("owned:small", endpoint: endpoint)
            XCTAssertNil(value.gpuBytes); XCTAssertNil(value.contextLength); XCTAssertEqual(value.observationExpiresAt, value.observedAt.addingTimeInterval(300))
        }
    }
    func testCancellationDuringLoadExitsWithoutPublishingLaterTagOrResidencyChecks() async throws {
        let script = PreparationHTTPScript(), requested = expectation(description: "empty load request admitted")
        script.loadDelay = 1; script.onLoad = { requested.fulfill() }
        let endpoint = PreparationHTTPProtocol.register(script); defer { PreparationHTTPProtocol.remove(endpoint) }
        let client = client(), task = Task { try await client.prepare("owned:small", endpoint: endpoint) }
        await fulfillment(of: [requested], timeout: 5); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled load returned success") } catch is CancellationError {} catch { throw error }
        XCTAssertEqual(script.snapshot().map { $0.url!.lastPathComponent }, ["tags", "generate"])
    }
}
