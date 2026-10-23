import Foundation
import OSwindCore
import CryptoKit
import Darwin

// Only a benchmark driver: the upstream DatabaseManager search implementation is
// compiled separately and remains unmodified apart from CLI logging identity.
@main struct Compare {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 7, let count = Int(args[1]), (32...100000).contains(count) else { fatalError("count root documents queries output sourceSHA") }
        let root = URL(fileURLWithPath:args[2]), documentData = try Data(contentsOf:URL(fileURLWithPath:args[3])), queryData = try Data(contentsOf:URL(fileURLWithPath:args[4]))
        let documents = (try JSONSerialization.jsonObject(with:documentData) as! [String:Any])["documents"] as! [[String:Any]]
        let queries = (try JSONSerialization.jsonObject(with:queryData) as! [String:Any])["queries"] as! [[String:Any]]
        try FileManager.default.createDirectory(at:root.appendingPathComponent("rem"),withIntermediateDirectories:true)
        let rem = DatabaseManager.shared, oswind = try MemoryStore(root:root.appendingPathComponent("oswind"))
        var remIDs = [Int64:String](), oswindIDs = [String:String](), ingestion = [String:Double]()
        var start = Date()
        for i in 0..<count {
            let document = documents[i%documents.count], content = (document["title"] as? String ?? "")+"\n"+(document["text"] as! String)
            let frame = rem.insertFrame(activeApplicationName:document["app"] as? String)
            rem.insertAllTextForFrame(frameId:frame,text:content); remIDs[frame] = document["id"] as? String
        }
        // Upstream registers a video chunk after its frames are stored, matching
        // the actual recorder's flush order. No synthetic video is decoded.
        _ = rem.startNewVideoChunk(filePath:"synthetic-no-video.mp4")
        ingestion["rem_seconds"] = Date().timeIntervalSince(start); start = Date()
        for i in 0..<count {
            let document = documents[i%documents.count], id = String(i), content = (document["title"] as? String ?? "")+"\n"+(document["text"] as! String)
            try oswind.insert(Memory(id:id,timestamp:Date(timeIntervalSince1970:Double(i)),kind:.note,app:document["app"] as! String,text:content))
            oswindIDs[id] = document["id"] as? String
        }
        ingestion["oswind_seconds"] = Date().timeIntervalSince(start)
        var measurements = [String:[[String:Any]]](uniqueKeysWithValues:["rem","oswind"].map {($0,[])})
        for repetition in 0..<5 {
            for (caseID,item) in queries.enumerated() {
                let query = item["query"] as! String, app = item["app"] as? String, target = Set(item["expected"] as! [String])
                for product in repetition%2 == 0 ? ["rem","oswind"] : ["oswind","rem"] {
                    start = Date(); let found: [String]
                    if product == "rem" { found = rem.search(appName:app ?? "",searchText:query,limit:5).compactMap {remIDs[$0.frameId]} }
                    else { found = try oswind.search(SearchFilter(query:query,app:app,limit:5),mode:.keyword).compactMap {oswindIDs[$0.id]} }
                    let elapsed = Date().timeIntervalSince(start)*1000, observed = Set(found), intersection = observed.intersection(target)
                    measurements[product]!.append(["case":caseID,"query":query,"app":app ?? "","repetition":repetition,"latency_ms":elapsed,"expected":Array(target).sorted(),"returned_document_labels":found,"hit_at_5":!intersection.isEmpty,"unique_label_recall_at_5":target.isEmpty ? NSNull() : Double(intersection.count)/Double(target.count),"unique_label_precision_at_5":observed.isEmpty ? NSNull() : Double(intersection.count)/Double(observed.count),"empty":found.isEmpty])
                }
            }
        }
        var results = [String:Any]()
        for product in ["rem","oswind"] {
            let values = measurements[product]!, times = values.map {$0["latency_ms"] as! Double}.sorted(), answerable = values.filter {!($0["expected"] as! [String]).isEmpty}, absent = values.filter {($0["expected"] as! [String]).isEmpty}
            let middle = times.count/2
            let median = times.count%2 == 0 ? (times[middle-1]+times[middle])/2 : times[middle]
            let hitRate = Double(answerable.filter {$0["hit_at_5"] as! Bool}.count)/Double(answerable.count)
            let recall = answerable.reduce(0.0) { $0+($1["unique_label_recall_at_5"] as! Double) }/Double(answerable.count)
            let emptyRate = Double(absent.filter {$0["empty"] as! Bool}.count)/Double(absent.count)
            results[product] = ["p50_ms":median,"p95_ms":times[Int(ceil(0.95*Double(times.count)))-1],"max_ms":times.last!,"answerable_hit_rate_at_5":hitRate,"unique_label_recall_at_5":recall,"absent_query_empty_rate":emptyRate,"measurements":values]
        }
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        let report: [String:Any] = ["schema":1,"timestamp":ISO8601DateFormatter().string(from:Date()),"count":count,"unique_documents":documents.count,"repetitions":5,"documents_sha256":SHA256.hash(data:documentData).map {String(format:"%02x",$0)}.joined(),"queries_sha256":SHA256.hash(data:queryData).map {String(format:"%02x",$0)}.joined(),"rem_revision":"f4f68049a064557bddeb93753f82aa41af776b98","rem_db_original_sha256":args[6],"oswind_source_tree_sha256":ProcessInfo.processInfo.environment["OSWIND_COMPARISON_SOURCE_SHA256"] ?? "unrecorded","oswind_revision":ProcessInfo.processInfo.environment["OSWIND_COMPARISON_REVISION"] ?? "unrecorded","ingestion":ingestion,"process_peak_rss_bytes_both_backends":usage.ru_maxrss,"os":ProcessInfo.processInfo.operatingSystemVersionString,"results":results,"latency_quantiles":"Median averages center pair; p95 nearest rank ceil(.95*n)","scope":"In-process keyword database/search-method comparison on duplicated synthetic text. Upstream rem DB.swift with logging bundle fallback and isolated path stub; original SQL/search logic and default store configuration. No upstream app UI, actual video, OCR, capture, model inference, energy or full-product comparison. OSwind keyword search only; same title+text concatenation in both text fields, no embeddings. Alternating query order after separate ingestion. A small authored workload, not held out or a ranking against major current commercial products."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[5]),options:.atomic)
        print("Wrote comparison: \(args[5])")
    }
}
