import Foundation

enum VisualEvidence {
    static func render(_ hit:SearchHit,query:String,budget:Int,summary:Bool)->String? {
        guard let recording=hit.memory.visualRecording,(try? recording.validated()) != nil,recording.text==hit.memory.text else {return nil}
        let source=hit.memory.text as NSString
        let base:PassageRange = !summary && hit.passage?.text(in:hit.memory.text) != nil ? hit.passage!:PassageRange(start:0,length:source.length)
        let body=source.substring(with:NSRange(location:base.start,length:base.length))
        let ranges=EvidenceText.excerptRanges(body,query:query,budget:budget,summary:summary)
        var lines=["Frame times are offsets within this sampled visual clip. They do not imply continuous capture or text visibility between sampled frames."],emitted=0
        for local in ranges {
            let range=NSRange(location:base.start+local.location,length:local.length)
            if range.location>0 {lines.append("…")}
            for entry in recording.ranges() {
                let overlap=NSIntersectionRange(range,NSRange(location:entry.range.start,length:entry.range.length))
                guard overlap.length>0 else {continue}
                guard emitted<16 else {lines.append("… [Further frames omitted]");return lines.joined(separator:"\n")}
                lines.append(String(format:"frame time %.3f s:\n",entry.frame.time)+source.substring(with:overlap));emitted+=1
            }
            if NSMaxRange(range)<source.length {lines.append("…")}
        }
        return emitted>0 ? lines.joined(separator:"\n"):nil
    }
}
