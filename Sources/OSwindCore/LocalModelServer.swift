import Foundation

/// Starts only an installed local runtime, never replaces an existing server.
/// Ollama cloud inference is disabled on servers launched by OSwind.
@MainActor public final class LocalModelServer: ObservableObject {
    public static let shared = LocalModelServer()
    private var process: Process?
    private let client: OllamaClient
    public var ownsRunningServer: Bool { process?.isRunning == true }
    public init(client: OllamaClient = .shared) { self.client = client }
    public static func binary() -> URL? {
        ["/opt/homebrew/bin/ollama","/usr/local/bin/ollama","/Applications/Ollama.app/Contents/Resources/ollama"].first { FileManager.default.isExecutableFile(atPath:$0) }.map { URL(fileURLWithPath:$0) }
    }
    public func start(endpoint: String) async throws -> String {
        _ = try OllamaClient.localURL(endpoint,path:"api/tags")
        if (try? await client.models(endpoint:endpoint,timeout:0.5)) != nil { return "Local model server is already running" }
        guard !ownsRunningServer else { throw OSwindError.unavailable("OSwind already started a server. Check its endpoint before starting another.") }
        guard let base = URL(string:endpoint), base.scheme == "http", base.path.isEmpty || base.path == "/", let host = base.host else { throw OSwindError.invalid("Managed servers require a plain loopback HTTP URL without a path") }
        let port = base.port ?? 80; guard port >= 1024 else { throw OSwindError.invalid("Choose a local model server port of 1024 or higher") }
        guard let binary = Self.binary() else { throw OSwindError.unavailable("Install the local runtime with scripts/setup-models.sh, then try again") }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/OSwind/models")
        try Paths.ensure(directory); let log = directory.appendingPathComponent("ollama-managed.log")
        if !FileManager.default.fileExists(atPath:log.path) { FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) }
        let handle = try FileHandle(forWritingTo:log); try handle.seekToEnd(); defer { try? handle.close() }
        let process = Process(); process.executableURL = binary; process.arguments = ["serve"]; process.standardOutput = handle; process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        let address = host.contains(":") ? "[\(host.trimmingCharacters(in:CharacterSet(charactersIn:"[]")))]:\(port)" : "\(host):\(port)"
        environment["OLLAMA_HOST"] = address; environment["OLLAMA_NO_CLOUD"] = "1"; environment["OLLAMA_DEBUG"] = "false"; process.environment = environment
        try process.run(); self.process = process
        do {
            let deadline = Date().addingTimeInterval(12)
            while process.isRunning && Date() < deadline {
                try Task.checkCancellation()
                if (try? await client.models(endpoint:endpoint,timeout:0.5)) != nil { return "Started local model server with cloud inference disabled" }
                try await Task.sleep(nanoseconds:200_000_000)
            }
            throw OSwindError.unavailable("Local model server did not become ready. Inspect the OSwind runtime log or start Ollama yourself.")
        } catch { if process.isRunning { process.terminate() }; self.process = nil; throw error }
    }
    /// Stops only a process started by this manager, never an existing user server.
    public func stopOwnedServer() { if let process, process.isRunning { process.terminate() }; process = nil }
}
