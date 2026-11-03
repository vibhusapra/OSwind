import Network
import XCTest
@testable import OSwindCore
@testable import OSwind

final class OwnedModelLibraryHTTPServer: @unchecked Sendable {
    struct Request { let method: String; let path: String; let model: String?; let authorizationAbsent: Bool; let bodyKeys: Set<String>; let keepAlive: String?; let stream: Bool?; let numContext: Int?; let optionKeys: Set<String>; let numPredict: Int?; let temperature: Double?; let think: Bool? }
    let ready = XCTestExpectation(description: "owned loopback listener ready")
    let stopped = XCTestExpectation(description: "owned listener and connections stopped")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "oswind.owned-model-library-fixture")
    private let lock = NSLock()
    private var requests: [Request] = []
    private var connections: [UUID: NWConnection] = [:] // queue confined
    private var stopping = false, listenerStopped = false, stopReported = false
    private let preparationEnabled: Bool
    private var loaded = false // queue confined
    private var loadedContext = 262144 // emulate the observed server default
    let model: String
    init(model: String, preparationEnabled: Bool = false) throws {
        self.model = model
        self.preparationEnabled = preparationEnabled
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.ready.fulfill()
            case .cancelled: self.listenerStopped = true; self.finishStop()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopping else { connection.cancel(); return }
            let id = UUID(); self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                if case .cancelled = state { self?.connections.removeValue(forKey: id); self?.finishStop() }
                if case .failed = state { connection?.cancel() }
            }
            connection.start(queue: self.queue); self.read(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }
    var endpoint: String { "http://127.0.0.1:\(listener.port!.rawValue)" }
    func snapshot() -> [Request] { lock.lock(); defer { lock.unlock() }; return requests }
    func stop() {
        queue.async { [self] in
            stopping = true; for connection in connections.values { connection.cancel() }; listener.cancel(); finishStop()
        }
    }
    private func finishStop() {
        if stopping && listenerStopped && connections.isEmpty && !stopReported { stopReported = true; stopped.fulfill() }
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer; buffer.append(data ?? Data())
            guard buffer.count <= 32768 else { connection.cancel(); return }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)), let head = String(data: buffer[..<range.lowerBound], encoding: .utf8) {
                let lines = head.components(separatedBy: "\r\n")
                let length = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)) } ?? 0
                guard (0...32768).contains(length) else { connection.cancel(); return }
                if buffer.count >= range.upperBound + length {
                    let first = lines[0].split(separator: " ")
                    guard first.count == 3 else { connection.cancel(); return }
                    let method = String(first[0]), path = String(first[1])
                    let body = buffer[range.upperBound..<(range.upperBound + length)]
                    let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
                    let name = object["model"] as? String
                    let options = object["options"] as? [String:Any] ?? [:]
                    let request = Request(method: method, path: path, model: name, authorizationAbsent: !lines.contains { $0.lowercased().hasPrefix("authorization:") }, bodyKeys: Set(object.keys), keepAlive: object["keep_alive"] as? String, stream: object["stream"] as? Bool, numContext:options["num_ctx"] as? Int, optionKeys:Set(options.keys), numPredict:options["num_predict"] as? Int, temperature:options["temperature"] as? Double, think:object["think"] as? Bool)
                    self.lock.lock(); self.requests.append(request); self.lock.unlock()
                    let response: String
                    let digest = self.preparationEnabled ? String(repeating:"a",count:64) : "owned-fictional"
                    switch (method, path) {
                    case ("GET", "/api/tags"): response = "{\"models\":[{\"name\":\"\(self.model)\",\"digest\":\"\(digest)\",\"size\":10}]}"
                    case ("GET", "/api/ps"):
                        response = self.loaded ? "{\"models\":[{\"name\":\"\(self.model)\",\"digest\":\"\(digest)\",\"size\":4096,\"size_vram\":2048,\"context_length\":\(self.loadedContext),\"expires_at\":\"\(Date().addingTimeInterval(300).ISO8601Format())\"}]}" : "{\"models\":[]}"
                    case ("POST", "/api/pull"): response = "{\"status\":\"success\"}\n"
                    case ("POST", "/api/generate") where self.preparationEnabled:
                        self.loaded = true; self.loadedContext = request.numContext ?? 262144; response = "{\"model\":\"\(self.model)\",\"done\":true,\"response\":\"\",\"done_reason\":\"load\"}"
                    case ("POST", "/api/chat") where self.preparationEnabled:
                        response = "{\"message\":{\"role\":\"assistant\",\"content\":\"Rima owns the Cobalt handoff checklist [1].\"},\"done\":true,\"done_reason\":\"stop\"}"
                    default: connection.cancel(); return
                    }
                    let output = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(response.utf8.count)\r\nConnection: close\r\n\r\n\(response)".utf8)
                    connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() }); return
                }
            }
            if complete || error != nil { connection.cancel() } else { self.read(connection, buffer: buffer) }
        }
    }
}

@MainActor final class LocalModelLibraryHTTPTests: XCTestCase {
    func idle(_ library: LocalModelLibraryModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while library.busy && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(library.busy)
    }
    func testTwoOwnedHTTPServersReceiveOnlyTheirSelectedRoleRequests() async throws {
        let answer = try OwnedModelLibraryHTTPServer(model: "owned-chat"), search = try OwnedModelLibraryHTTPServer(model: "owned-embedding")
        defer { answer.stop(); search.stop() }
        await fulfillment(of: [answer.ready, search.ready], timeout: 5)
        let client = OllamaClient(), manager = LocalModelServer(client: client)
        let operations = LocalModelLibraryOperations(models: { try await client.models(endpoint: $0) }, runtime: { try await client.runtime(endpoint: $0) }, pull: { try await client.pull($0, endpoint: $1, progress: $2) }, start: { try await manager.start(endpoint: $0) })
        let library = LocalModelLibraryModel(operations: operations)
        library.configure(answer: answer.endpoint, search: search.endpoint)
        for role in LocalModelLibraryRole.allCases {
            library.inspect(role); try await idle(library)
            library.startServer(); try await idle(library)
            library.pull(role == .answer ? "owned-chat" : "owned-embedding"); try await idle(library)
        }
        XCTAssertEqual(library.models(for: .answer).map(\.name), ["owned-chat"])
        XCTAssertEqual(library.models(for: .search).map(\.name), ["owned-embedding"])
        XCTAssertFalse(manager.ownsRunningServer, "Existing fixture servers must never be adopted or replaced")
        for (server, expected) in [(answer, "owned-chat"), (search, "owned-embedding")] {
            let requests = server.snapshot()
            XCTAssertEqual(requests.filter { $0.method == "POST" }.map(\.model), [expected])
            XCTAssertTrue(requests.allSatisfy { $0.authorizationAbsent && ["/api/tags", "/api/ps", "/api/pull"].contains($0.path) })
            XCTAssertTrue(requests.contains { $0.path == "/api/tags" }); XCTAssertTrue(requests.contains { $0.path == "/api/ps" })
        }
        await library.cancelAndWait(); answer.stop(); search.stop()
        await fulfillment(of: [answer.stopped, search.stopped], timeout: 5)
    }
}
