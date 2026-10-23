import Foundation
import Metal
import Darwin

/// Synthetic storage/search stress, separate from model and language relevance.
public enum VectorScalingEvaluation {
    static func vector(row: Int, dimensions: Int) -> [Float] {
        var state = UInt64(row) &+ 0x9e3779b97f4a7c15
        var values = (0..<dimensions).map { _ -> Float in
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Float((state &* 2685821657736338717) >> 40)/Float(1 << 23)-1
        }
        let magnitude = sqrt(values.reduce(Float(0)) { $0+$1*$1 }); for i in values.indices { values[i] /= magnitude }; return values
    }
    private struct Manifest: Codable, Equatable { var kind = "OSwind synthetic vectors v1"; var count: Int; var dimensions: Int }
    private final class Lease {
        let descriptor: Int32
        init(_ url: URL) throws {
            let opened = open(url.path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
            guard opened >= 0 else { throw OSwindError.invalid("Cannot lock the benchmark archive") }
            guard flock(opened,LOCK_EX | LOCK_NB) == 0 else { close(opened); throw OSwindError.unavailable("Another benchmark is using this archive") }; descriptor = opened
        }
        deinit { flock(descriptor,LOCK_UN); close(descriptor) }
    }
    public static func run(count: Int, dimensions: Int = 1024, repetitions: Int = 3, indexed: Bool = false, archive: URL? = nil, qualityQueries: Int = 0, qualitySeedOffset: Int = 17) async throws -> [String:Any] {
        guard (100...1_000_000).contains(count), (32...4096).contains(dimensions), (1...10).contains(repetitions), (0...64).contains(qualityQueries), (1...1_000_000).contains(qualitySeedOffset) else { throw OSwindError.invalid("Choose 100–1000000 rows, 32–4096 dimensions and 1–10 repetitions and 0–64 quality queries and a positive seed offset ≤1000000") }
        let root = archive ?? FileManager.default.temporaryDirectory.appendingPathComponent("oswind-vector-scale-"+UUID().uuidString)
        try Paths.ensure(root); defer { if archive == nil { try? FileManager.default.removeItem(at:root) } }
        let lease = try Lease(root.appendingPathComponent("benchmark.lock")); defer { withExtendedLifetime(lease) {} }
        let marker = root.appendingPathComponent("benchmark-fixture.json"), manifest = Manifest(count:count,dimensions:dimensions)
        if FileManager.default.fileExists(atPath:marker.path) {
            guard try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:marker)) == manifest else { throw OSwindError.invalid("Archive belongs to a different benchmark workload") }
        } else {
            let files = try FileManager.default.contentsOfDirectory(atPath:root.path).filter { $0 != "benchmark.lock" }
            guard files.isEmpty else { throw OSwindError.invalid("Refusing to overwrite a non-benchmark directory. Choose a new archive path.") }
            try JSONEncoder().encode(manifest).write(to:marker,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:marker.path)
        }
        let store = try MemoryStore(root:root), identity = "synthetic-random-v1:d\(dimensions)", before = Date(), existing = try store.matchingCount()
        guard existing <= count else { throw OSwindError.invalid("Benchmark archive contains extra records") }
        var pending = [VectorRecord]()
        for i in existing..<count {
            try Task.checkCancellation()
            let memory = Memory(id:String(format:"row-%08d",i),timestamp:Date(timeIntervalSince1970:1792700000+Double(i)),app:i % 2 == 0 ? "Synthetic A" : "Synthetic B",title:"Vector workload",text:"Synthetic row \(i). No recorded desktop content.")
            try store.insert(memory); pending.append(VectorRecord(memory:memory,vector:vector(row:i,dimensions:dimensions)))
            if pending.count == 32 || i == count-1 { _ = try store.saveVectors(pending,modelID:identity); pending.removeAll(keepingCapacity:true) }
            if (i+1)%10000 == 0 { FileHandle.standardError.write(Data("Ingested \(i+1)/\(count) synthetic rows\n".utf8)) }
        }
        // A cancelled run may have committed its final source rows before the
        // vector batch. Repair only recognizable fixture records; never delete.
        while true {
            let missing = try store.memoriesNeedingVectors(modelID:identity,limit:32); if missing.isEmpty { break }
            let repair = try missing.map { memory -> VectorRecord in
                guard memory.id.hasPrefix("row-"), let row = Int(memory.id.dropFirst(4)), row >= 0 && row < count, memory.text == "Synthetic row \(row). No recorded desktop content." else { throw OSwindError.invalid("Archive contains non-fixture evidence") }
                return VectorRecord(memory:memory,vector:vector(row:row,dimensions:dimensions))
            }
            _ = try store.saveVectors(repair,modelID:identity)
        }
        guard try store.vectorCount(modelID:identity) == count else { throw OSwindError.invalid("Benchmark vector coverage mismatch") }
        let ingest = Date().timeIntervalSince(before), samples = [0,count/3,count-1]
        var preparation = 0.0
        if indexed {
            let observer = Task { while !Task.isCancelled { let state = store.searchIndexStatus; FileHandle.standardError.write(Data("\(state.message) · \(state.indexed)/\(state.total)\n".utf8)); try? await Task.sleep(nanoseconds:2_000_000_000) } }; defer { observer.cancel() }
            let start = Date(); _ = try await store.buildSearchIndex(modelID:identity,dimensions:dimensions); preparation = Date().timeIntervalSince(start)
        }
        var modes = [String:Any]()
        for (label,threshold,scope) in [("all_candidates",-1.0,false),("thresholded",0.25,false),("filtered",-1.0,true)] {
            var times = [Double](), correct = 0, measurements = [[String:Any]]()
            for repetition in 0..<repetitions { for row in samples {
                let query = vector(row:row,dimensions:dimensions), start = Date(); var execution = SearchExecution(strategy:"exact",warnings:[])
                let filter = SearchFilter(query:"synthetic query",app:scope ? (row % 2 == 0 ? "Synthetic A" : "Synthetic B") : nil,limit:5)
                let coverage = try store.indexCoverage(modelID:identity,filter:filter)
                let hits = try store.search(filter,mode:.semantic,vector:query,modelID:identity,minimumSimilarity:threshold,indexPolicy:indexed ? .indexed : .exact,indexedCount:coverage.indexed) { execution = $0 }
                let milliseconds = Date().timeIntervalSince(start)*1000
                times.append(milliseconds); measurements.append(["row":row,"repetition":repetition,"latency_ms":milliseconds,"returned":hits.map(\.id),"strategy":execution.strategy,"warnings":execution.warnings]); if hits.first?.id == String(format:"row-%08d",row) { correct += 1 }
            } }
            let first = times[0], latency = try BenchmarkLatency(samples:times)
            modes[label] = ["p50_ms":latency.median,"p95_ms":latency.p95,"max_ms":latency.maximum,"first_query_ms":first,"top1_exact_match_rate":Double(correct)/Double(times.count),"query_samples":times.count,"minimum_similarity":threshold,"app_filtered":scope,"measurements":measurements]
        }
        var quality = [String:Any]()
        if indexed && qualityQueries > 0 {
            for scope in [false,true] {
                var recall = 0.0, exactTimes = [Double](), indexedTimes = [Double](), measurements = [[String:Any]]()
                for queryID in 0..<qualityQueries {
                    try Task.checkCancellation()
                    // Seeds lie outside the archive: these are non-self queries.
                    FileHandle.standardError.write(Data("Evaluating non-self \(scope ? "filtered" : "all") \(queryID+1)/\(qualityQueries)\n".utf8))
                    let query = vector(row:count+qualitySeedOffset+queryID,dimensions:dimensions)
                    let filter = SearchFilter(query:"synthetic query",app:scope ? "Synthetic A" : nil,limit:10)
                    var start = Date()
                    _ = try store.indexCoverage(modelID:identity,filter:filter)
                    let exact = try store.search(filter,mode:.semantic,vector:query,modelID:identity,minimumSimilarity:-1,indexPolicy:.exact)
                    exactTimes.append(Date().timeIntervalSince(start)*1000); start = Date()
                    var execution = SearchExecution(strategy:"exact",warnings:[])
                    let coverage = try store.indexCoverage(modelID:identity,filter:filter)
                    let approximate = try store.search(filter,mode:.semantic,vector:query,modelID:identity,minimumSimilarity:-1,indexPolicy:.indexed,indexedCount:coverage.indexed) { execution = $0 }
                    indexedTimes.append(Date().timeIntervalSince(start)*1000)
                    let target = Set(exact.map(\.id)), observed = Set(approximate.map(\.id)), score = Double(target.intersection(observed).count)/Double(max(1,target.count))
                    recall += score; measurements.append(["query_seed":count+qualitySeedOffset+queryID,"recall_at_10":score,"exact_ids":exact.map(\.id),"indexed_ids":approximate.map(\.id),"exact_ms":exactTimes.last!,"indexed_ms":indexedTimes.last!,"strategy":execution.strategy,"warnings":execution.warnings])
                }
                let exactLatency = try BenchmarkLatency(samples:exactTimes), indexedLatency = try BenchmarkLatency(samples:indexedTimes)
                quality[scope ? "filtered" : "all_candidates"] = ["recall_at_10":recall/Double(qualityQueries),"queries":qualityQueries,"exact_p95_ms":exactLatency.p95,"indexed_p95_ms":indexedLatency.p95,"exact_max_ms":exactLatency.maximum,"indexed_max_ms":indexedLatency.maximum,"measurements":measurements]
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        return ["schema":6,"coverage_counts_included":true,"quality_seed_offset":qualitySeedOffset,"latency_quantiles":BenchmarkLatency.method,"timestamp":ISO8601DateFormatter().string(from:Date()),"count":count,"dimensions":dimensions,"layout":"semantic_vectors","random_seed":"row+xorshift64star-v1","ingest_seconds":ingest,"reused_records":existing,"archive_retained":archive != nil,"index_policy":indexed ? "indexed" : "exact","index_prepare_seconds":preparation,"disk_bytes":store.diskBytes(),"process_peak_rss_bytes":usage.ru_maxrss,"build":build,"gpu":MTLCreateSystemDefaultDevice()?.name ?? "none","os":ProcessInfo.processInfo.operatingSystemVersionString,"modes":modes,"nonself_quality":quality,"scope":"Normalized synthetic random vectors and exact self-match checks, plus optional non-self Recall@10 against exhaustive float32 ground truth. Timings include coverage-count lookup, the selected SQLite search path and live validation/reranking but exclude embedding inference and index preparation. These are warm trials after ingestion/preparation; first_query_ms is not a controlled cold-cache test. Not natural-language relevance, isolated GPU execution, power or competitor measurement. Retained archives are explicit benchmark-only directories and can be reused to investigate cold starts separately."]
    }
}
