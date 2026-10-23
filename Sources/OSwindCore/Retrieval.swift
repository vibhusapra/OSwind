import Foundation
import CryptoKit

public extension Memory {
    var contentHash: String { SHA256.hash(data:Data(searchableText.utf8)).map { String(format:"%02x",$0) }.joined() }
    /// Source dates/kinds can support a claim even when the embedding text is
    /// unchanged. Keep this stricter revision separate from vector identity.
    var evidenceHash: String {
        let encoder=JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let audio=transcript.flatMap { try? encoder.encode($0) }.map { SHA256.hash(data:$0).map { String(format:"%02x",$0) }.joined() } ?? ""
        let base=contentHash + ":" + String(timestamp.timeIntervalSinceReferenceDate.bitPattern) + ":" + kind.rawValue + ":" + audio
        guard let visualRecording else {return base}
        return base+":"+SHA256.hash(data:(try? encoder.encode(visualRecording)) ?? Data()).map {String(format:"%02x",$0)}.joined()
    }
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
    public var resolution: QueryResolution? = nil
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
    public func search(_ input: SearchFilter, mode: SearchMode = .hybrid, configuration: SearchConfiguration = SearchConfiguration(), interpretQuery: Bool = true, now: Date = Date(), timeZone: TimeZone = .current, detail:SearchDetail = .full) async throws -> RetrievalResult {
        let start = Date()
        // Invalid scopes must escape before model-failure fallback. Otherwise an
        // incomplete operator could silently become an unfiltered keyword query.
        let resolution = try store.resolveQueryScope(input,interpret:interpretQuery,now:now,timeZone:timeZone)
        let filter = resolution.filter
        if filter.query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || mode == .keyword {
            return RetrievalResult(hits:try store.search(filter,mode:.keyword,detail:detail),warnings:[],modelID:nil,duration:Date().timeIntervalSince(start),resolution:resolution)
        }
        do {
            let vector: [Float]?, identity: String
            if configuration.provider == .apple { vector = await Task.detached(priority:.userInitiated) { self.apple.embed(filter.query) }.value; identity = apple.modelID }
            else { let batch = try await client.embed([filter.query],configuration:configuration,query:true); vector = batch.vectors.first; identity = batch.modelID }
            try Task.checkCancellation()
            guard let vector else { throw OSwindError.unavailable("The selected embedding model is unavailable") }
            let coverage = try store.indexCoverage(modelID:identity,filter:filter)
            let indexed = coverage.indexed, total = coverage.total
            var warnings = indexed == 0 && total > 0 ? ["No vectors for the selected model in this range. Build its search index in Models settings."] : indexed < total ? ["Semantic index covers \(indexed) of \(total) memories in this range. Keyword matches remain available in Hybrid mode."] : []
            let backlog = try store.passageBacklog(modelID:identity,filter:filter)
            if backlog > 0 { warnings.append("Long-source passage indexing is pending for \(backlog) records. Build the selected embedding index in Models settings for complete semantic coverage.") }
            var execution = SearchExecution(strategy:"exact",warnings:[])
            let hits = try store.search(filter,mode:mode,vector:vector,modelID:identity,minimumSimilarity:configuration.provider == .apple ? 0.15 : 0.25,similarityFusion:configuration.provider == .ollama,indexPolicy:configuration.indexPolicy,indexedCount:indexed,allowIndexOnLowPower:configuration.indexOnLowPower,detail:detail) { execution = $0 }
            warnings += execution.warnings
            return RetrievalResult(hits:hits,warnings:warnings,modelID:identity,duration:Date().timeIntervalSince(start),strategy:execution.strategy,resolution:resolution)
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard mode == .hybrid else { throw error }
            return RetrievalResult(hits:try store.search(filter,mode:.keyword,detail:detail),warnings:["Semantic search unavailable; showing keyword matches. " + error.localizedDescription],modelID:nil,duration:Date().timeIntervalSince(start),resolution:resolution)
        }
    }
    @discardableResult public func index(_ memories: [Memory], configuration: SearchConfiguration, shouldContinue: @escaping @Sendable () -> Bool = { true }) async throws -> String? {
        guard !memories.isEmpty else { return nil }
        let batch = try await embeddings(memories.map(\.searchableText),configuration:configuration)
        try Task.checkCancellation()
        _ = try store.saveVectors(zip(memories,batch.vectors).map { VectorRecord(memory:$0.0,vector:$0.1) },modelID:batch.modelID)
        for memory in memories { try await indexPassages(memory,identity:batch.modelID,configuration:configuration,shouldContinue:shouldContinue) }
        return batch.modelID
    }
    private func embeddings(_ inputs: [String], configuration: SearchConfiguration) async throws -> EmbeddingBatch {
        if configuration.provider == .ollama { return try await client.embed(inputs,configuration:configuration) }
        let start = Date(), apple = self.apple
        return try await Task.detached(priority:.utility) {
            var vectors = [[Float]]()
            for input in inputs { try Task.checkCancellation(); guard let vector = apple.embed(input) else { throw OSwindError.unavailable("Apple sentence embeddings are unavailable") }; vectors.append(vector) }
            return EmbeddingBatch(vectors:vectors,modelID:apple.modelID,duration:Date().timeIntervalSince(start))
        }.value
    }
    private func indexPassages(_ memory: Memory, identity: String, configuration: SearchConfiguration, shouldContinue: @escaping @Sendable () -> Bool = { true }) async throws {
        guard try !store.passagesCurrent(memory,modelID:identity) else { return }
        let plan = SemanticPassagePlan.make(memory); var records = [PassageVector]()
        for first in stride(from:0,to:plan.count,by:8) {
            try Task.checkCancellation()
            guard shouldContinue() else { throw OSwindError.unavailable("Passage indexing deferred by power policy; earlier completed sources are saved") }
            let slice = Array(plan[first..<min(first+8,plan.count)])
            let batch = try await embeddings(slice.map(\.input),configuration:configuration)
            guard batch.modelID == identity else { throw OSwindError.unavailable("Model changed during passage indexing; restart with the installed model") }
            records += zip(slice,batch.vectors).map { PassageVector(range:$0.0.range,vector:$0.1) }
        }
        try Task.checkCancellation(); _ = try store.savePassages(memory:memory,modelID:identity,records:records)
    }
    @discardableResult public func rebuild(configuration: SearchConfiguration, shouldContinue: @escaping @Sendable () -> Bool = { true }, progress: @escaping @Sendable (IndexProgress) -> Void) async throws -> IndexProgress {
        let probe = try await embeddings(["index identity"],configuration:configuration)
        let identity = probe.modelID, total = try store.matchingCount()
        var cursor = ""
        progress(IndexProgress(indexed:try store.vectorCount(modelID:identity),total:total,modelID:identity))
        while true {
            try Task.checkCancellation()
            guard shouldContinue() else { throw OSwindError.unavailable("Indexing deferred by the current power policy; completed sources are saved") }
            let memories = try store.memoriesNeedingVectors(modelID:identity,afterID:cursor,limit:16)
            guard let last = memories.last else { break }
            let batch = try await embeddings(memories.map(\.searchableText),configuration:configuration)
            guard batch.modelID == identity else { throw OSwindError.unavailable("Model changed during index build; restart with the installed model") }
            try Task.checkCancellation()
            _ = try store.saveVectors(zip(memories,batch.vectors).map { VectorRecord(memory:$0.0,vector:$0.1) },modelID:identity)
            for memory in memories { try await indexPassages(memory,identity:identity,configuration:configuration,shouldContinue:shouldContinue) }
            // Short multibyte sources may pass the conservative SQL length test.
            for memory in memories where !SemanticPassagePlan.needed(memory) { _ = try store.savePassages(memory:memory,modelID:identity,records:[]) }
            cursor = last.id; progress(IndexProgress(indexed:try store.vectorCount(modelID:identity),total:total,modelID:identity))
        }
        let final = IndexProgress(indexed:try store.vectorCount(modelID:identity),total:try store.matchingCount(),modelID:identity); progress(final); return final
    }
}
