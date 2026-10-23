import Foundation

/// Attribution is an annotation over literal source ranges, never a replacement
/// for source text. A failed whole-transcript alignment falls back to raw text.
public struct AudioEvidenceSpan: Equatable, Sendable {
    public var range: PassageRange
    public var speaker: String?
    public var start: Double
    public var end: Double
}
public enum AudioEvidence {
    public static func spans(_ transcript:SpeechTranscript) -> [AudioEvidenceSpan]? {
        guard (try? transcript.validated()) != nil,!transcript.segments.isEmpty else { return nil }
        let source=transcript.text as NSString
        let separators=CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var cursor=0, result=[AudioEvidenceSpan]()
        for segment in transcript.segments {
            if Task.isCancelled { return nil }
            let word=segment.text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let found=source.range(of:word,options:.literal,range:NSRange(location:cursor,length:source.length-cursor))
            guard found.location != NSNotFound,
                  source.substring(with:NSRange(location:cursor,length:found.location-cursor)).unicodeScalars.allSatisfy({separators.contains($0)}),
                  source.rangeOfComposedCharacterSequences(for:found)==found else { return nil }
            if let last=result.last,last.speaker==segment.speaker,segment.start>=last.end-0.05,segment.start-last.end<=0.75 {
                result[result.count-1].range.length=NSMaxRange(found)-last.range.start
                result[result.count-1].end=max(last.end,segment.end)
            } else { result.append(AudioEvidenceSpan(range:PassageRange(start:found.location,length:found.length),speaker:segment.speaker,start:segment.start,end:segment.end)) }
            cursor=NSMaxRange(found)
        }
        guard !result.isEmpty,source.substring(from:cursor).unicodeScalars.allSatisfy({separators.contains($0)}) else { return nil }
        return result
    }
    private static func time(_ seconds:Double) -> String {
        let tenths=Int(seconds*10)
        return String(format:"%02d:%02d.%d",tenths/600,(tenths/10)%60,tenths%10)
    }
    static func render(_ hit:SearchHit,query:String,budget:Int,summary:Bool,speaker:String?) -> String? {
        guard hit.memory.kind == .audio,let transcript=hit.memory.transcript,transcript.text==hit.memory.text,
              let spans=spans(transcript) else { return nil }
        let full=hit.memory.text as NSString
        let base:PassageRange
        if !summary,let passage=hit.passage,passage.text(in:hit.memory.text) != nil { base=passage }
        else { base=PassageRange(start:0,length:full.length) }
        let body=full.substring(with:NSRange(location:base.start,length:base.length))
        let queryTerms=Set(SpeakerLabel.words(query))
        let anchors=spans.compactMap { span -> NSRange? in
            guard let label=span.speaker else { return nil }
            let words=SpeakerLabel.words(label)
            guard speaker.map({SpeakerLabel.key($0)==SpeakerLabel.key(label)}) ?? words.contains(where:queryTerms.contains) else { return nil }
            let clipped=NSIntersectionRange(NSRange(location:span.range.start,length:span.range.length),NSRange(location:base.start,length:base.length))
            guard clipped.length>0 else { return nil }; return NSRange(location:clipped.location-base.start,length:clipped.length)
        }
        let ranges=EvidenceText.excerptRanges(body,query:query,budget:budget,summary:summary,anchors:anchors)
        var lines=["Speaker annotations use recording-local labels and source segment time bounds; unknown spans remain unattributed."], emitted=0
        for local in ranges {
            let range=NSRange(location:local.location+base.start,length:local.length)
            if range.location>0 { lines.append("…") }
            var cursor=range.location
            for span in spans where span.range.start<NSMaxRange(range) && span.range.start+span.range.length>range.location {
                let overlap=NSIntersectionRange(NSRange(location:span.range.start,length:span.range.length),range)
                if overlap.location>cursor {
                    let gap=full.substring(with:NSRange(location:cursor,length:overlap.location-cursor)).trimmingCharacters(in:.whitespacesAndNewlines)
                    if !gap.isEmpty { lines.append("[Unattributed source text] "+gap) }
                }
                guard emitted<16 else { lines.append("… [Further source spans omitted]"); return lines.joined(separator:"\n") }
                // JSON quoting prevents embedded newlines/brackets in a manual
                // label from masquerading as another source or annotation.
                let label=span.speaker.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data:$0,encoding:.utf8) } ?? "unknown"
                lines.append("speaker \(label); segment time \(time(span.start))–\(time(span.end)):\n"+full.substring(with:overlap))
                emitted += 1; cursor=NSMaxRange(overlap)
            }
            if cursor<NSMaxRange(range) {
                let gap=full.substring(with:NSRange(location:cursor,length:NSMaxRange(range)-cursor)).trimmingCharacters(in:.whitespacesAndNewlines)
                if !gap.isEmpty { lines.append("[Unattributed source text] "+gap) }
            }
            if NSMaxRange(range)<full.length { lines.append("…") }
        }
        return emitted>0 ? lines.joined(separator:"\n"):nil
    }
}
public extension SearchHit {
    func answerEvidence(query:String,budget:Int=800,summary:Bool=false,speaker:String?=nil) -> String {
        AudioEvidence.render(self,query:query,budget:budget,summary:summary,speaker:speaker) ?? excerpt(query:query,budget:budget,summary:summary)
    }
}
