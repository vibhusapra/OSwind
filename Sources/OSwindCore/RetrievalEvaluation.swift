import Foundation
import Metal
import CryptoKit

public enum RetrievalEvaluation {
    private struct Fixture: Decodable { var description: String; var documents: [Document]; var queries: [Query] }
    private struct Document: Decodable { var id,title,text,app,kind,timestamp: String }
    private struct Query: Decodable { var id,query,category: String; var relevant: [String]; var app,kind,start,end: String? }
    public static func run(fixture: URL, configuration: SearchConfiguration, repetitions: Int = 3) async throws -> [String:Any] {
        let bytes = try Data(contentsOf:fixture), data = try JSONDecoder().decode(Fixture.self,from:bytes)
        guard !data.documents.isEmpty, !data.queries.isEmpty else { throw OSwindError.invalid("Relevance fixture is empty") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oswind-relevance-"+UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root), apple = LocalEmbedder(), iso = ISO8601DateFormatter()
        let ingestStart = Date()
        for document in data.documents {
            guard let timestamp = iso.date(from:document.timestamp), let kind = MemoryKind(rawValue:document.kind) else { throw OSwindError.invalid("Invalid fixture timestamp or memory kind") }
            var memory = Memory(id:document.id,timestamp:timestamp,kind:kind,app:document.app,title:document.title,text:document.text)
            memory.embedding = apple.embed(memory.searchableText); memory.embeddingModel = memory.embedding == nil ? nil : apple.modelID; try store.insert(memory)
        }
        let engine = RetrievalEngine(store:store,apple:apple); var indexSeconds = Date().timeIntervalSince(ingestStart)
        if configuration.provider == .ollama { let start = Date(); try await engine.rebuild(configuration:configuration) { _ in }; indexSeconds = Date().timeIntervalSince(start) }
        var annSeconds = 0.0
        if configuration.indexPolicy == .indexed {
            let identity: String
            if configuration.provider == .apple { identity = apple.modelID }
            else { identity = try await OllamaClient.shared.embed(["search index identity"],configuration:configuration).modelID }
            guard let dimensions = try store.embeddingDimensions(modelID:identity) else { throw OSwindError.unavailable("No vectors exist for the selected search model") }
            let before = Date(); _ = try await store.buildSearchIndex(modelID:identity,dimensions:dimensions,allowLowPower:configuration.indexOnLowPower); annSeconds = Date().timeIntervalSince(before)
        }
        var reports = [String:Any](), modelIDs = Set<String>()
        for mode in SearchMode.textModes {
            var times = [Double](), recall = 0.0, hitRate = 0.0, reciprocal = 0.0, positives = 0, emptyCorrect = 0, negatives = 0
            var perQuery = [[String:Any]](), categories = [String:(count:Int,recall:Double,mrr:Double)]()
            for repetition in 0..<max(1,min(10,repetitions)) {
                for query in data.queries {
                    try Task.checkCancellation()
                    let filter = SearchFilter(query:query.query,app:query.app,kind:query.kind.flatMap(MemoryKind.init),start:query.start.flatMap(iso.date),end:query.end.flatMap(iso.date),limit:5)
                    let result = try await engine.search(filter,mode:mode,configuration:configuration); times.append(result.duration*1000); if let identity = result.modelID { modelIDs.insert(identity) }
                    let ids = result.hits.map(\.id), relevant = Set(query.relevant)
                    let rank = ids.firstIndex { relevant.contains($0) }
                    let r = relevant.isEmpty ? 0 : Double(Set(ids).intersection(relevant).count)/Double(relevant.count)
                    let mrr = rank.map { 1/Double($0+1) } ?? 0
                    if relevant.isEmpty { negatives += 1; if ids.isEmpty { emptyCorrect += 1 } }
                    else { positives += 1; recall += r; hitRate += rank == nil ? 0 : 1; reciprocal += mrr; let old = categories[query.category] ?? (0,0,0); categories[query.category] = (old.count+1,old.recall+r,old.mrr+mrr) }
                    if repetition == 0 { perQuery.append(["id":query.id,"query":query.query,"category":query.category,"expected":query.relevant,"returned":ids,"recall_at_5":r,"mrr_at_5":mrr,"scores":result.hits.map(\.score),"warnings":result.warnings,"strategy":result.strategy ?? "keyword","latency_ms":result.duration*1000]) }
                }
            }
            let latency = try BenchmarkLatency(samples:times)
            reports[mode.rawValue] = ["p50_ms":latency.median,"p95_ms":latency.p95,"max_ms":latency.maximum,"recall_at_5":recall/Double(max(1,positives)),"hit_rate_at_5":hitRate/Double(max(1,positives)),"mrr_at_5":reciprocal/Double(max(1,positives)),"no_evidence_empty_rate":Double(emptyCorrect)/Double(max(1,negatives)),"categories":categories.mapValues { ["count":Double($0.count),"recall_at_5":$0.recall/Double($0.count),"mrr_at_5":$0.mrr/Double($0.count)] },"queries":perQuery]
        }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        return ["schema":2,"latency_quantiles":BenchmarkLatency.method,"timestamp":iso.string(from:Date()),"fixture_sha256":SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined(),"fixture_description":data.description,"documents":data.documents.count,"queries":data.queries.count,"repetitions":max(1,min(10,repetitions)),"provider":configuration.provider.rawValue,"search_index":configuration.indexPolicy.rawValue,"ann_build_seconds":annSeconds,"hybrid_fusion":configuration.provider == .apple ? "rrf60" : "cosine-plus-bounded-lexical-bonus-v1","model_ids":modelIDs.sorted(),"model_index_seconds":indexSeconds,"disk_bytes":store.diskBytes(),"build":build,"gpu":MTLCreateSystemDefaultDevice()?.name ?? "none","os":ProcessInfo.processInfo.operatingSystemVersionString,"modes":reports]
    }
}
