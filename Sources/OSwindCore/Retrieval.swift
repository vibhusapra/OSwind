import Foundation
import CryptoKit

public extension Memory {
    var contentHash: String { SHA256.hash(data:Data(searchableText.utf8)).map { String(format:"%02x",$0) }.joined() }
}
public struct VectorRecord: Sendable {
    public var memoryID: String
    public var contentHash: String
    public var vector: [Float]
    public init(memory: Memory, vector: [Float]) { memoryID = memory.id; contentHash = memory.contentHash; self.vector = vector }
}
public struct RetrievalResult: Codable, Sendable {
    public var hits: [SearchHit]
    public var warnings: [String]
    public var modelID: String?
    public var duration: Double
    public var strategy: String? = nil
}
public struct IndexProgress: Sendable {
    public var indexed: Int
    public var total: Int
    public var modelID: String
}
public final class RetrievalEngine: @unchecked Sendable {
    private let store: MemoryStore
    private let apple: LocalEmbedder
    private let client: OllamaClient
    public init(store: MemoryStore, apple: LocalEmbedder = LocalEmbedder(), client: OllamaClient = .shared) { self.store = store; self.apple = apple; self.client = client }
    public func search(_ filter: SearchFilter, mode: SearchMode = .hybrid, configuration: SearchConfiguration = SearchConfiguration()) async throws -> RetrievalResult {
        let start = Date()
        if filter.query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || mode == .keyword {
            return RetrievalResult(hits:try store.search(filter,mode:.keyword),warnings:[],modelID:nil,duration:Date().timeIntervalSince(start))
        }
        do {
            let vector: [Float]?, identity: String
            if configuration.provider == .apple { vector = await Task.detached(priority:.userInitiated) { self.apple.embed(filter.query) }.value; identity = apple.modelID }
            else { let batch = try await client.embed([filter.query],configuration:configuration,query:true); vector = batch.vectors.first; identity = batch.modelID }
            try Task.checkCancellation()
            guard let vector else { throw OSwindError.unavailable("The selected embedding model is unavailable") }
            let indexed = try store.vectorCount(modelID:identity,filter:filter)
            let total = try store.matchingCount(filter)
            var warnings = indexed == 0 && total > 0 ? ["No vectors for the selected model in this range. Build its search index in Models settings."] : indexed < total ? ["Semantic index covers \(indexed) of \(total) memories in this range. Keyword matches remain available in Hybrid mode."] : []
            var execution = SearchExecution(strategy:"exact",warnings:[])
            let hits = try store.search(filter,mode:mode,vector:vector,modelID:identity,minimumSimilarity:configuration.provider == .apple ? 0.15 : 0.25,similarityFusion:configuration.provider == .ollama,indexPolicy:configuration.indexPolicy,indexedCount:indexed,allowIndexOnLowPower:configuration.indexOnLowPower) { execution = $0 }
            warnings += execution.warnings
            return RetrievalResult(hits:hits,warnings:warnings,modelID:identity,duration:Date().timeIntervalSince(start),strategy:execution.strategy)
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard mode == .hybrid else { throw error }
            return RetrievalResult(hits:try store.search(filter,mode:.keyword),warnings:["Semantic search unavailable; showing keyword matches. " + error.localizedDescription],modelID:nil,duration:Date().timeIntervalSince(start))
        }
    }
    @discardableResult public func index(_ memories: [Memory], configuration: SearchConfiguration) async throws -> String? {
        guard configuration.provider == .ollama, !memories.isEmpty else { return nil }
        let batch = try await client.embed(memories.map(\.searchableText),configuration:configuration)
        try Task.checkCancellation()
        _ = try store.saveVectors(zip(memories,batch.vectors).map { VectorRecord(memory:$0.0,vector:$0.1) },modelID:batch.modelID)
        return batch.modelID
    }
    @discardableResult public func rebuild(configuration: SearchConfiguration, shouldContinue: @escaping @Sendable () -> Bool = { true }, progress: @escaping @Sendable (IndexProgress) -> Void) async throws -> IndexProgress {
        guard configuration.provider == .ollama else { throw OSwindError.invalid("Apple vectors are built during capture. Select a local embedding model to build its additional index.") }
        let probe = try await client.embed(["index identity"],configuration:configuration)
        let identity = probe.modelID, total = try store.stats().count
        var indexed = try store.vectorCount(modelID:identity), cursor = ""
        progress(IndexProgress(indexed:indexed,total:total,modelID:identity))
        while true {
            try Task.checkCancellation()
            guard shouldContinue() else { throw OSwindError.unavailable("Indexing deferred by the current power policy; completed batches are saved") }
            let memories = try store.memoriesNeedingVectors(modelID:identity,afterID:cursor,limit:16)
            guard let last = memories.last else { break }
            let batch = try await client.embed(memories.map(\.searchableText),configuration:configuration)
            guard batch.modelID == identity else { throw OSwindError.unavailable("Model changed during index build; restart with the installed model") }
            try Task.checkCancellation()
            indexed += try store.saveVectors(zip(memories,batch.vectors).map { VectorRecord(memory:$0.0,vector:$0.1) },modelID:identity)
            cursor = last.id; progress(IndexProgress(indexed:indexed,total:total,modelID:identity))
        }
        let final = IndexProgress(indexed:try store.vectorCount(modelID:identity),total:try store.matchingCount(),modelID:identity); progress(final); return final
    }
}
