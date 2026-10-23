import Foundation
import Metal
import MetalPerformanceShaders
import Accelerate
import Darwin
import CryptoKit

struct Candidate { var row: Int; var score: Float }
struct TopK {
    let capacity: Int
    var heap = [Candidate]()
    static func better(_ a: Candidate,_ b: Candidate) -> Bool { a.score != b.score ? a.score > b.score : a.row > b.row }
    mutating func offer(_ value: Candidate) {
        if heap.count < capacity { heap.append(value); var child=heap.count-1; while child>0 { let parent=(child-1)/2; if !Self.better(heap[parent],heap[child]) {break}; heap.swapAt(parent,child); child=parent }; return }
        if !Self.better(value,heap[0]) { return }; heap[0]=value; var parent=0
        while true { let l=parent*2+1; if l>=heap.count {break}; let r=l+1; let child=r<heap.count && Self.better(heap[l],heap[r]) ? r : l; if !Self.better(heap[parent],heap[child]) {break}; heap.swapAt(parent,child); parent=child }
    }
}
func vector(_ row: Int,_ dimensions: Int) -> [Float] {
    var state=UInt64(row) &+ 0x9e3779b97f4a7c15
    var values=(0..<dimensions).map { _ -> Float in state ^= state >> 12; state ^= state << 25; state ^= state >> 27; return Float((state &* 2685821657736338717) >> 40)/Float(1 << 23)-1 }
    let norm=sqrt(values.reduce(Float(0)){$0+$1*$1}); for i in values.indices {values[i] /= norm}; return values
}
func elapsed(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds-start)/1e6 }
@main struct Probe {
 static func main() throws {
    let args=CommandLine.arguments
    guard args.count == 3 else { throw NSError(domain:"OSwindMetalProbe",code:1,userInfo:[NSLocalizedDescriptionKey:"Usage: metal-probe SYNTHETIC_REFERENCE.json OUTPUT.json"]) }
    let input=try Data(contentsOf:URL(fileURLWithPath:args[1])), reference=try JSONSerialization.jsonObject(with:input) as! [String:Any]
    let count=reference["count"] as! Int, dimensions=reference["dimensions"] as! Int, truth=reference["nonself_quality"] as! [String:[String:Any]]
    guard (100...1_000_000).contains(count), (32...4096).contains(dimensions), reference["random_seed"] as? String == "row+xorshift64star-v1" else { throw NSError(domain:"OSwindMetalProbe",code:2,userInfo:[NSLocalizedDescriptionKey:"Expected a synthetic vector benchmark reference"]) }
    guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else {fatalError("No Metal device")}
    let rowBytes=MPSMatrixDescriptor.rowBytes(forColumns:dimensions,dataType:.float32), required=count*rowBytes
    guard required <= device.maxBufferLength, UInt64(required) < device.recommendedMaxWorkingSetSize/2 else {fatalError("Probe exceeds device budget")}
    guard let data=device.makeBuffer(length:required,options:.storageModeShared), let query=device.makeBuffer(length:dimensions*4,options:.storageModeShared), let scores=device.makeBuffer(length:count*4,options:.storageModeShared) else {fatalError("GPU allocation failed")}
    let build=DispatchTime.now().uptimeNanoseconds
    for row in 0..<count { let values=vector(row,dimensions); values.withUnsafeBytes { bytes in data.contents().advanced(by:row*rowBytes).copyMemory(from:bytes.baseAddress!,byteCount:bytes.count) }; if (row+1)%100000==0 { FileHandle.standardError.write(Data("Generated \(row+1)/\(count) rows\n".utf8)) } }
    let generated=elapsed(build)
    let matrix=MPSMatrix(buffer:data,descriptor:MPSMatrixDescriptor(rows:count,columns:dimensions,rowBytes:rowBytes,dataType:.float32))
    let x=MPSVector(buffer:query,descriptor:MPSVectorDescriptor(length:dimensions,dataType:.float32)), y=MPSVector(buffer:scores,descriptor:MPSVectorDescriptor(length:count,dataType:.float32))
    let kernel=MPSMatrixVectorMultiplication(device:device,rows:count,columns:dimensions)
    var reports=[String:Any]()
    for label in ["all_candidates","filtered"] {
        let cases=truth[label]!["measurements"] as! [[String:Any]]; var trials=[[String:Any]](), recall=0.0
        for item in cases {
            let seed=item["query_seed"] as! Int, q=vector(seed,dimensions), started=DispatchTime.now().uptimeNanoseconds
            q.withUnsafeBytes {query.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count)}
            let command=queue.makeCommandBuffer()!; kernel.encode(commandBuffer:command,inputMatrix:matrix,inputVector:x,resultVector:y); command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else {throw command.error ?? NSError(domain:"OSwindMetalProbe",code:3,userInfo:[NSLocalizedDescriptionKey:"Metal command did not complete"])}
            let gpu=command.gpuEndTime-command.gpuStartTime, result=scores.contents().bindMemory(to:Float.self,capacity:count); var candidates=TopK(capacity:200)
            for row in 0..<count { if label == "filtered" && row%2 != 0 {continue}; candidates.offer(Candidate(row:row,score:result[row])) }
            var reranked=[Candidate](), qnorm: Float=0; vDSP_svesq(q,1,&qnorm,vDSP_Length(dimensions)); qnorm=sqrt(qnorm)
            for candidate in candidates.heap { let values=data.contents().advanced(by:candidate.row*rowBytes).assumingMemoryBound(to:Float.self); var dot:Float=0,norm:Float=0; vDSP_dotpr(q,1,values,1,&dot,vDSP_Length(dimensions)); vDSP_svesq(values,1,&norm,vDSP_Length(dimensions)); reranked.append(Candidate(row:candidate.row,score:dot/(qnorm*sqrt(norm)))) }
            let found=reranked.sorted(by:TopK.better).prefix(10).map {String(format:"row-%08d",$0.row)}, target=Set(item["exact_ids"] as! [String]), score=Double(Set(found).intersection(target).count)/Double(target.count)
            let milliseconds=elapsed(started); recall += score
            trials.append(["query_seed":seed,"latency_ms":milliseconds,"gpu_ms":gpu*1000,"recall_at_10":score,"returned":found,"expected":Array(target).sorted()])
        }
        let ordered=trials.map {$0["latency_ms"] as! Double}.sorted()
        let middle=ordered.count/2, median=ordered.count%2 == 0 ? (ordered[middle-1]+ordered[middle])/2 : ordered[middle]
        reports[label] = ["recall_at_10":recall/Double(cases.count),"p50_ms":median,"p95_ms":ordered[Int(ceil(0.95*Double(ordered.count)))-1],"measurements":trials]
    }
    var usage=rusage(); getrusage(RUSAGE_SELF,&usage)
    let report:[String:Any] = ["schema":1,"reference_sha256":SHA256.hash(data:input).map{String(format:"%02x",$0)}.joined(),"latency_quantiles":"Median averages center pair; p95 nearest rank ceil(.95*n)","count":count,"dimensions":dimensions,"device":device.name,"row_bytes":rowBytes,"buffer_bytes":required,"generated_ms":generated,"process_peak_rss_bytes":usage.ru_maxrss,"modes":reports,"scope":"Isolated MPS float32 exhaustive dot products, CPU top-200 and float32 cosine rerank against existing SQL ground-truth IDs. Regenerated deterministic fixture vectors, not the full product cache/filter/erasure path. GPU timing is command-buffer execution; full latency includes CPU selection. No embedding/model inference or competitor run."]
    let output=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]); try output.write(to:URL(fileURLWithPath:args[2])); print(String(data:output,encoding:.utf8)!)
 }
}
