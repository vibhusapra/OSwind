import Foundation

public enum EmbeddingProvider: String, Codable, CaseIterable, Sendable { case apple, ollama }
public enum SearchIndexPolicy: String, Codable, CaseIterable, Sendable { case automatic, exact, indexed }
public struct SearchConfiguration: Codable, Equatable, Sendable {
    public var provider: EmbeddingProvider = .apple
    public var endpoint = "http://127.0.0.1:11434"
    public var model = "qwen3-embedding:0.6b"
    public var indexOnLowPower = false
    public var indexPolicy: SearchIndexPolicy = .automatic
    public init() {}
    enum CodingKeys: String, CodingKey { case provider,endpoint,model,indexOnLowPower,indexPolicy }
    public init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy:CodingKeys.self)
        provider = try c.decodeIfPresent(EmbeddingProvider.self,forKey:.provider) ?? provider
        endpoint = try c.decodeIfPresent(String.self,forKey:.endpoint) ?? endpoint
        model = try c.decodeIfPresent(String.self,forKey:.model) ?? model
        indexOnLowPower = try c.decodeIfPresent(Bool.self,forKey:.indexOnLowPower) ?? indexOnLowPower
        indexPolicy = (try? c.decodeIfPresent(SearchIndexPolicy.self,forKey:.indexPolicy)) ?? indexPolicy
    }
}
public struct InstalledModel: Codable, Identifiable, Sendable {
    public var name: String
    public var digest: String
    public var size: Int64
    public var capabilities: [String]?
    public var remoteHost: String?
    public var remoteModel: String?
    enum CodingKeys: String, CodingKey { case name,digest,size,capabilities; case remoteHost = "remote_host", remoteModel = "remote_model" }
    public var isRemote: Bool { name.lowercased().hasSuffix(":cloud") || name.lowercased().hasSuffix("-cloud") || remoteHost?.isEmpty == false || remoteModel?.isEmpty == false || capabilities?.contains("cloud") == true }
    public var id: String { name + "@" + digest }
}
public struct ModelPullProgress: Codable, Sendable {
    public var status: String
    public var total: Int64?
    public var completed: Int64?
    public var fraction: Double? { guard let total, total > 0, let completed else { return nil }; return min(1,Double(completed)/Double(total)) }
}
public struct EmbeddingBatch: Sendable {
    public var vectors: [[Float]]
    public var modelID: String
    public var duration: Double
}
private final class LocalOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public actor OllamaClient {
    public static let shared = OllamaClient()
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else { let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 600; self.session = URLSession(configuration:configuration,delegate:LocalOnlyRedirects(),delegateQueue:nil) }
    }
    public static func localURL(_ endpoint: String, path: String) throws -> URL {
        guard let base = URL(string:endpoint), let host = base.host?.lowercased(), ["localhost","127.0.0.1","::1","[::1]"].contains(host), ["http","https"].contains(base.scheme), base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else { throw OSwindError.invalid("Local models require a loopback URL without credentials or query parameters") }
        return base.appendingPathComponent(path)
    }
    private func request(_ endpoint: String, path: String, body: [String:Any]? = nil, timeout: Double = 45) throws -> URLRequest {
        var request = URLRequest(url:try Self.localURL(endpoint,path:path)); request.timeoutInterval = timeout
        if let body { request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject:body) }
        return request
    }
    private func data(_ request: URLRequest) async throws -> Data {
        do {
            let (data,response) = try await session.data(for:request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw OSwindError.network("Local model server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
            return data
        } catch { if Task.isCancelled { throw CancellationError() }; throw error }
    }
    public func models(endpoint: String, timeout: Double = 5) async throws -> [InstalledModel] {
        struct Response: Decodable { var models: [InstalledModel] }
        return try JSONDecoder().decode(Response.self,from:await data(request(endpoint,path:"api/tags",timeout:timeout))).models
    }
    public func runtime(endpoint: String) async throws -> String {
        let payload = try await data(request(endpoint,path:"api/ps",timeout:5))
        guard let json = try JSONSerialization.jsonObject(with:payload) as? [String:Any], let models = json["models"] as? [[String:Any]] else { throw OSwindError.network("Invalid local runtime response") }
        return models.map { model in
            let name = model["name"] as? String ?? "model", size = (model["size"] as? NSNumber)?.doubleValue ?? 0, gpu = (model["size_vram"] as? NSNumber)?.doubleValue ?? 0
            return "\(name) · \(size > 0 ? Int(min(1,gpu/size)*100) : 0)% GPU memory residency"
        }.joined(separator:"\n")
    }
    public func pull(_ model: String, endpoint: String, progress: @escaping @Sendable (ModelPullProgress) -> Void) async throws {
        guard !model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw OSwindError.invalid("Choose a model to download") }
        guard !model.lowercased().hasSuffix(":cloud"), !model.lowercased().hasSuffix("-cloud") else { throw OSwindError.invalid("Choose a local model; cloud model aliases are not supported in local mode") }
        let request = try request(endpoint,path:"api/pull",body:["model":model,"stream":true],timeout:600)
        let (bytes,response) = try await session.bytes(for:request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw OSwindError.network("Model download could not start") }
        var finished = false
        for try await line in bytes.lines {
            try Task.checkCancellation(); guard !line.isEmpty else { continue }
            let payload = Data(line.utf8)
            if let json = try JSONSerialization.jsonObject(with:payload) as? [String:Any], json["error"] != nil { throw OSwindError.network("The local server could not download that model. Check its name and network connection.") }
            let state = try JSONDecoder().decode(ModelPullProgress.self,from:payload); progress(state); if state.status == "success" { finished = true }
        }
        guard finished else { throw OSwindError.network("Model download ended before completion") }
    }
    public static func queryInput(_ text: String, model: String) -> String {
        let bounded = String(text.prefix(4000))
        return model.lowercased().contains("qwen3-embedding") ? "Instruct: Given a question about desktop activity, retrieve relevant screen text, notes and conversation transcripts that answer it.\nQuery: \(bounded)" : bounded
    }
    public func embed(_ inputs: [String], configuration: SearchConfiguration, query: Bool = false) async throws -> EmbeddingBatch {
        guard !inputs.isEmpty, inputs.count <= 32 else { throw OSwindError.invalid("Embedding batches must contain 1–32 items") }
        let before = Date()
        let model = try await models(endpoint:configuration.endpoint).first { $0.name == configuration.model || $0.name == configuration.model + ":latest" }
        guard let model else { throw OSwindError.unavailable("Download \(configuration.model) in Models settings before building its index") }
        guard !model.isRemote else { throw OSwindError.invalid("Cloud-backed model aliases are disabled for local search") }
        let texts = inputs.map { query ? Self.queryInput($0,model:configuration.model) : String($0.prefix(12000)) }
        let response = try await data(request(configuration.endpoint,path:"api/embed",body:["model":configuration.model,"input":texts,"truncate":true,"keep_alive":"5m"],timeout:60))
        struct Response: Decodable { var embeddings: [[Float]] }
        let vectors = try JSONDecoder().decode(Response.self,from:response).embeddings
        guard vectors.count == inputs.count, let dimension = vectors.first?.count, (1...8192).contains(dimension), vectors.allSatisfy({ $0.count == dimension && $0.allSatisfy(\.isFinite) && $0.contains(where:{$0 != 0}) }) else { throw OSwindError.network("Local model returned invalid embedding dimensions or values") }
        let after = try await models(endpoint:configuration.endpoint).first { $0.name == model.name }
        guard after?.digest == model.digest else { throw OSwindError.unavailable("The embedding model changed during indexing. Retry with the installed model.") }
        return EmbeddingBatch(vectors:vectors.map(LocalEmbedder.normalized),modelID:"ollama:\(model.name)@\(model.digest):desktop-v1:d\(dimension)",duration:Date().timeIntervalSince(before))
    }
}
