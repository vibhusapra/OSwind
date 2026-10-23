import XCTest
@testable import OSwindCore

final class LocalRuntimeLiveTests: XCTestCase {
    /// Opt-in hardware integration check; never replaces the user's normal daemon.
    @MainActor func testManagedLocalServerLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_MANAGED_RUNTIME"] == "1" else { throw XCTSkip("Set OSWIND_TEST_MANAGED_RUNTIME=1 to test an installed Ollama runtime") }
        guard LocalModelServer.binary() != nil else { throw XCTSkip("Ollama is not installed") }
        let endpoint = "http://127.0.0.1:\(Int.random(in:49000...59000))"
        if (try? await OllamaClient.shared.models(endpoint:endpoint,timeout:0.2)) != nil { throw XCTSkip("Isolated test port is occupied") }
        let manager = LocalModelServer(); defer { manager.stopOwnedServer() }
        let status = try await manager.start(endpoint:endpoint)
        XCTAssertTrue(status.contains("cloud inference disabled")); XCTAssertTrue(manager.ownsRunningServer)
        _ = try await OllamaClient.shared.models(endpoint:endpoint)
        manager.stopOwnedServer(); XCTAssertFalse(manager.ownsRunningServer)
    }
}
