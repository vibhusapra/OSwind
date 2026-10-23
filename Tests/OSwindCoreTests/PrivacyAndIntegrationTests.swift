import XCTest
@testable import OSwindCore

final class PrivacyAndIntegrationTests: XCTestCase {
    func testDomainBoundaries() {
        let p = PrivacyPolicy()
        XCTAssertNotNil(p.exclusion(app:"browser",title:"",url:"https://sub.chase.com/a"))
        XCTAssertNil(p.exclusion(app:"browser",title:"",url:"https://notchase.com"))
        XCTAssertNil(p.exclusion(app:"browser",title:"",url:"https://chase.com.evil.example"))
        XCTAssertNotNil(p.exclusion(app:"browser",title:"",url:nil,isBrowser:true))
        XCTAssertNotNil(p.exclusion(app:"com.apple.Passwords",title:"",url:nil))
        XCTAssertNotNil(p.exclusion(app:"browser",title:"New Incognito Window",url:"https://example.com"))
    }
    func testSecretRedaction() {
        let p = PrivacyPolicy()
        for text in ["password=hello123", "api_key: abcdefghi", "sk-abcdefghijklmnopqrstuvwxyz1234", "ghp_abcdefghijklmnopqrstuvwxyz1234", "4111 1111 1111 1111", "123-45-6789", "-----BEGIN PRIVATE KEY-----\nhello\n-----END PRIVATE KEY-----"] {
            let result = p.sanitize(text); XCTAssertTrue(result.redacted,"Missed \(text)"); XCTAssertFalse(result.text.contains("hello123"))
        }
        XCTAssertEqual(p.sanitize("Ship Friday at 10:30").text,"Ship Friday at 10:30")
    }
    func testPowerProfileAndDedup() {
        XCTAssertNil(CaptureProfile.balanced.effectiveInterval(lowPower:false,thermalLimited:false,idleSeconds:121))
        XCTAssertEqual(CaptureProfile.balanced.effectiveInterval(lowPower:true,thermalLimited:true,idleSeconds:0),45)
        XCTAssertEqual(CaptureController.difference([10,20],[10,20]),0)
        XCTAssertEqual(CaptureController.difference([10,20],[20,30]),10)
    }
    func testRemoteModelGuardrails() throws {
        var c = AIConfiguration(); c.provider = .ollama; XCTAssertEqual(try c.validatedURL(path:"api/chat").host,"127.0.0.1")
        c.endpoint = "http://example.com"; c.allowRemote = true; XCTAssertThrowsError(try c.validatedURL(path:"x"))
        c.endpoint = "https://example.com"; XCTAssertThrowsError(try c.validatedURL(path:"x"))
        c.provider = .compatible; c.allowRemote = false; XCTAssertThrowsError(try c.validatedURL(path:"x")); c.allowRemote = true; XCTAssertNoThrow(try c.validatedURL(path:"x"))
        c.endpoint = "https://user:password@example.com"; XCTAssertThrowsError(try c.validatedURL(path:"x"))
    }
    func testWhisperCancellationStopsWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Paths.ensure(root); defer { try? FileManager.default.removeItem(at:root) }
        let binary = root.appendingPathComponent("mock-whisper"), model = root.appendingPathComponent("model.bin"), file = root.appendingPathComponent("test.wav")
        try Data("#!/bin/sh\nexec /bin/sleep 20\n".utf8).write(to:binary)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:binary.path)
        try Data([0]).write(to:model); try WAV.data(samples:[0,0]).write(to:file)
        let begin = Date(); let task = Task { try await Whisper.transcribe(file:file,binary:binary.path,model:model.path) }
        try await Task.sleep(nanoseconds:150_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled transcription returned success") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(begin),2)
    }
    func testWAVEncodingAndSilence() {
        let data = WAV.data(samples:[0,1,-1]); XCTAssertEqual(data.count,50); XCTAssertEqual(String(data:data.prefix(4),encoding:.utf8),"RIFF"); XCTAssertEqual(String(data:data[8..<12],encoding:.utf8),"WAVE"); XCTAssertEqual(WAV.rms([0,0]),0); XCTAssertEqual(WAV.rms([1,-1]),1)
    }
    func testAcceleratedCosine() { XCTAssertEqual(LocalEmbedder.cosine([1,0],[2,0]),1,accuracy:0.001); XCTAssertEqual(LocalEmbedder.cosine([1,0],[0,1]),0); XCTAssertEqual(LocalEmbedder.cosine([1],[]),0) }
    func testSettingsRoundTripWithoutSecrets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }; var s = AppSettings(); s.profile = .light; s.privacy.retentionDays = 7; try s.save(root:root); XCTAssertEqual(AppSettings.load(root:root),s)
    }
    func testReadOnlyAPIAuthenticationAndOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }; let store = try MemoryStore(root:root); let api = try LocalAPIServer(store:store,embedder:LocalEmbedder())
        func request(_ path: String = "/health",extra: String = "",authorized: Bool = true,host: String = "127.0.0.1:47831") -> String { "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\(authorized ? "Authorization: Bearer " + api.token + "\r\n" : "")\(extra)\r\n" }
        XCTAssertEqual(api.handle(request()).0,200); XCTAssertEqual(api.handle(request(authorized:false)).0,401); XCTAssertEqual(api.handle(request(extra:"Origin: https://evil.example\r\n")).0,403); XCTAssertEqual(api.handle(request(host:"evil.example")).0,403); XCTAssertEqual(api.handle("POST /v1/delete HTTP/1.1\r\n\r\n").0,405); XCTAssertEqual(api.handle(request("/notfound")).0,404)
        try store.insert(Memory(text:"special marker")); let result = api.handle(request("/v1/search?query=special&mode=keyword")); XCTAssertEqual(result.0,200); XCTAssertEqual((result.1 as? [[String:Any]])?.count,1)
    }
    func testMCPNegotiationAndSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }; let store = try MemoryStore(root:root); let embedder = LocalEmbedder()
        let response = Integration.rpc(["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-06-18"]],store:store,embedder:embedder)
        XCTAssertEqual((response?["result"] as? [String:Any])?["protocolVersion"] as? String,"2025-06-18")
        XCTAssertNil(Integration.rpc(["jsonrpc":"2.0","method":"notifications/initialized"],store:store,embedder:embedder))
        XCTAssertNotNil(Integration.rpc(["jsonrpc":"2.0","id":2,"method":"tools/list"],store:store,embedder:embedder)?["result"])
        let call = Integration.rpc(["jsonrpc":"2.0","id":3,"method":"tools/call","params":["name":"delete_all"]],store:store,embedder:embedder)
        XCTAssertEqual((call?["result"] as? [String:Any])?["isError"] as? Bool,true)
    }
    func testEvidenceModeAndNoResultsAbstention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }; let store = try MemoryStore(root:root); let engine = AnswerEngine(store:store,embedder:LocalEmbedder())
        let empty = try await engine.answer("unknown",configuration:AIConfiguration()); XCTAssertTrue(empty.sources.isEmpty); XCTAssertTrue(empty.text.contains("couldn’t find"))
        try store.insert(Memory(text:"Maya owns the Friday release")); let result = try await engine.answer("Friday release",configuration:AIConfiguration()); XCTAssertEqual(result.provider,"evidence"); XCTAssertEqual(result.sources.count,1); XCTAssertTrue(result.text.contains("[1]"))
    }
}
