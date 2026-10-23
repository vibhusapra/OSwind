import Foundation
import Metal
import Darwin

/// Synthetic exact-scan stress test, deliberately separate from model/relevance evaluation.
public enum VectorScalingEvaluation {
    static func vector(row: Int, dimensions: Int) -> [Float] {
        var state = UInt64(row) &+ 0x9e3779b97f4a7c15
        var values = (0..<dimensions).map { _ -> Float in
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Float((state &* 2685821657736338717) >> 40)/Float(1 << 23)-1
        }
        let magnitude = sqrt(values.reduce(Float(0)) { $0+$1*$1 }); for i in values.indices { values[i] /= magnitude }; return values
    }
    public static func run(count: Int, dimensions: Int = 1024, repetitions: Int = 3) throws -> [String:Any] {
        guard (100...1_000_000).contains(count), (32...4096).contains(dimensions), (1...10).contains(repetitions) else { throw OSwindError.invalid("Choose 100–1000000 rows, 32–4096 dimensions and 1–10 repetitions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oswind-vector-scale-"+UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root), identity = "synthetic-random-v1:d\(dimensions)", before = Date()
        var pending = [VectorRecord]()
        for i in 0..<count {
            let memory = Memory(id:String(format:"row-%08d",i),timestamp:Date(timeIntervalSince1970:1792700000+Double(i)),app:i % 2 == 0 ? "Synthetic A" : "Synthetic B",title:"Vector workload",text:"Synthetic row \(i). No recorded desktop content.")
            try store.insert(memory); pending.append(VectorRecord(memory:memory,vector:vector(row:i,dimensions:dimensions)))
            if pending.count == 32 || i == count-1 { _ = try store.saveVectors(pending,modelID:identity); pending.removeAll(keepingCapacity:true) }
        }
        let ingest = Date().timeIntervalSince(before), samples = [0,count/3,count-1]
        var modes = [String:Any]()
        for (label,threshold,scope) in [("all_candidates",-1.0,false),("thresholded",0.25,false),("filtered",-1.0,true)] {
            var times = [Double](), correct = 0
            var measurements = [[String:Any]]()
            for repetition in 0..<repetitions { for row in samples {
                let query = vector(row:row,dimensions:dimensions), start = Date()
                let hits = try store.search(SearchFilter(query:"synthetic query",app:scope ? (row % 2 == 0 ? "Synthetic A" : "Synthetic B") : nil,limit:5),mode:.semantic,vector:query,modelID:identity,minimumSimilarity:threshold)
                let milliseconds = Date().timeIntervalSince(start)*1000
                times.append(milliseconds); measurements.append(["row":row,"repetition":repetition,"latency_ms":milliseconds,"returned":hits.map(\.id)]); if hits.first?.id == String(format:"row-%08d",row) { correct += 1 }
            } }
            times.sort(); modes[label] = ["p50_ms":times[times.count/2],"p95_ms":times[Int(Double(times.count-1)*0.95)],"top1_exact_match_rate":Double(correct)/Double(times.count),"query_samples":times.count,"minimum_similarity":threshold,"app_filtered":scope,"measurements":measurements]
        }
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        return ["schema":1,"timestamp":ISO8601DateFormatter().string(from:Date()),"count":count,"dimensions":dimensions,"layout":"semantic_vectors","random_seed":"row+xorshift64star-v1","ingest_seconds":ingest,"disk_bytes":store.diskBytes(),"process_peak_rss_bytes":usage.ru_maxrss,"build":build,"gpu":MTLCreateSystemDefaultDevice()?.name ?? "none","os":ProcessInfo.processInfo.operatingSystemVersionString,"modes":modes,"scope":"Normalized synthetic random vectors in isolated SQLite storage. Exact self-match and scan latency only; no model inference, natural-language quality, GPU execution, power or competitor measurement. all_candidates stresses ranking by retaining every vector above -1; filtered matches half the archive."]
    }
}
