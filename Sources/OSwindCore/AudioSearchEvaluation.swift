import Foundation
import CryptoKit
import Darwin

/// Explicit synthetic archive only. Separate prepare and run processes keep
/// fixture-generation allocations out of query-memory observations.
public enum AudioSearchEvaluation {
    public static func prepare(archive:URL,clips:Int=32,words:Int=10000) throws -> [String:Any] {
        guard (1...100).contains(clips),(1...50000).contains(words),!FileManager.default.fileExists(atPath:archive.path) else {throw OSwindError.invalid("Choose a new synthetic archive, 1–100 clips and 1–50,000 timed tokens per clip")}
        let start=Date()
        let segments:[TranscriptSegment]=(0..<words).map { index in
            let begin=Double(index)*0.35
            let name:String?=index%20==0 ? nil:((index/500)%2==0 ? "Maya":"Theo")
            return TranscriptSegment(start:begin,end:begin+0.3,text:"token\(index)",speaker:name)
        }
        let text=segments.map(\.text).joined(separator:" "),store=try MemoryStore(root:archive)
        var sourceBytes=0,previewBytes=0
        for index in 0..<clips {
            try Task.checkCancellation()
            var memory=Memory(id:"bench-audio-\(index)",timestamp:Date(timeIntervalSince1970:1_700_000_000+Double(index)),kind:.audio,app:"Synthetic audio",title:"Authored recording \(index)",text:text)
            memory.transcript=SpeechTranscript(text:text,duration:Double(words)*0.35,segments:segments,model:"synthetic-no-ASR")
            sourceBytes += try JSONEncoder().encode(memory).count;try store.insert(memory)
            let preview=try store.search(SearchFilter(start:memory.timestamp,end:memory.timestamp.addingTimeInterval(0.5),limit:1),mode:.keyword,detail:.preview)
            previewBytes += try JSONEncoder().encode(preview[0].memory).count
        }
        let marker:[String:Any]=["format":"OSwind synthetic audio search v1","clips":clips,"words_per_clip":words]
        try JSONSerialization.data(withJSONObject:marker,options:[.sortedKeys]).write(to:archive.appendingPathComponent("audio-search-benchmark.json"),options:.atomic)
        return ["fixture":marker,"prepare_seconds":Date().timeIntervalSince(start),"complete_payload_bytes":sourceBytes,"preview_payload_bytes":previewBytes,"archive_bytes":store.diskBytes(),"limits":"Preparation includes fixture construction, validation, original/derived writes, hashes, and a preview verification per clip. It is not an ASR or ingestion-only speed measurement."]
    }
    private static func peakRSS() -> Int64 {var usage=rusage();getrusage(RUSAGE_SELF,&usage);return Int64(usage.ru_maxrss)}
    public static func run(archive:URL,detail:SearchDetail,repetitions:Int=7) throws -> [String:Any] {
        let markerURL=archive.appendingPathComponent("audio-search-benchmark.json")
        guard (1...50).contains(repetitions),(try markerURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=1024,
              let marker=try JSONSerialization.jsonObject(with:Data(contentsOf:markerURL)) as? [String:Any],marker["format"] as? String == "OSwind synthetic audio search v1",
              let clips=marker["clips"] as? Int,(1...100).contains(clips),let words=marker["words_per_clip"] as? Int,(1...50000).contains(words),FileManager.default.fileExists(atPath:archive.appendingPathComponent("memory.sqlite").path) else {throw OSwindError.invalid("Choose a marked synthetic audio-search archive and 1–50 repetitions")}
        let opened=Date(),store=try MemoryStore(root:archive),openSeconds=Date().timeIntervalSince(opened)
        guard try store.matchingCount()==clips else {throw OSwindError.invalid("Synthetic archive record count changed")}
        let expected=Set((0..<clips).map {"bench-audio-\($0)"})
        var milliseconds=[Double](),last=[SearchHit]()
        for _ in 0..<repetitions {
            try Task.checkCancellation();let begin=DispatchTime.now().uptimeNanoseconds
            let hits=try autoreleasepool {try store.search(SearchFilter(query:"token",limit:clips),mode:.keyword,detail:detail)}
            milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds-begin)/1_000_000)
            guard Set(hits.map(\.id))==expected,hits.allSatisfy({$0.memory.app=="Synthetic audio" && $0.memory.text.hasSuffix("token\(words-1)") && (detail == .full ? $0.memory.transcript?.segments.count==words:$0.memory.searchPreview?.transcript.segmentCount==words && $0.memory.transcript==nil)}) else {throw OSwindError.invalid("Synthetic results or complete/preview contract changed")}
            last=hits
        }
        let queryPeak=peakRSS(),latency=try BenchmarkLatency(samples:milliseconds)
        let encoding=Date(),response=try JSONEncoder().encode(last),encodingSeconds=Date().timeIntervalSince(encoding)
        let encodingPeak=peakRSS(),opening=Date(),selected=try store.hydrate(Array(last.prefix(1)))
        guard selected.first?.memory.transcript?.segments.count==words,selected.first?.memory.searchPreview==nil else {throw OSwindError.invalid("Selected source did not hydrate completely")}
        #if DEBUG
        let build="debug"
        #else
        let build="release"
        #endif
        return ["schema":1,"store_schema":MemoryStore.schemaVersion,"detail":detail.rawValue,"build":build,"clips":clips,"words_per_clip":words,"repetitions":repetitions,"open_seconds":openSeconds,"query_ms":milliseconds,"p50_ms":latency.median,"p95_ms":latency.p95,"max_ms":latency.maximum,"latency_quantiles":BenchmarkLatency.method,"process_query_peak_rss_bytes":queryPeak,"response_bytes":response.count,"response_encode_seconds":encodingSeconds,"process_encode_peak_rss_bytes":encodingPeak,"one_source_hydration_seconds":Date().timeIntervalSince(opening),"process_hydration_peak_rss_bytes":peakRSS(),"ordered_id_sha256":SHA256.hash(data:Data(last.map(\.id).joined(separator:"\n").utf8)).map {String(format:"%02x",$0)}.joined(),"scope":"Synthetic long timed transcripts, keyword retrieval, same raw text/ranking in full and preview modes. No model inference/capture/network. Each trial retains the previous result list while loading the next, like UI publication. Query peak is measured before response encoding/hydration. OS/file caches are uncontrolled; separate fresh processes are not controlled cold-cache trials. No energy or competitor claim."]
    }
}
