import Foundation

/// A display grouping over immutable source indices, never a retiming or a
/// speaker assignment. Unknown spans keep their own anonymous/unknown header.
public struct TranscriptParagraph:Equatable,Sendable,Identifiable {
    public var id:Int { range.lowerBound }
    public var range:Range<Int>
    public var speaker:String?
    public var start:Double
    public static func make(_ transcript:SpeechTranscript) throws -> [Self] {
        _ = try transcript.validated()
        var paragraphs=[Self](),start=0,characters=0
        for index in transcript.segments.indices {
            if index%1024==0 { try Task.checkCancellation() }
            let segment=transcript.segments[index]
            if index>start {
                let previous=transcript.segments[index-1],gap=segment.start-previous.end
                let sentenceEnd=previous.text.last.map{ ".!?".contains($0) } ?? false
                if segment.speaker != transcript.segments[start].speaker || gap>0.75 || gap < -0.05 || characters+segment.text.count>360 || (sentenceEnd && characters>=80) {
                    paragraphs.append(Self(range:start..<index,speaker:transcript.segments[start].speaker,start:transcript.segments[start].start));start=index;characters=0
                }
            }
            characters += segment.text.count+1
        }
        if start<transcript.segments.count { paragraphs.append(Self(range:start..<transcript.segments.count,speaker:transcript.segments[start].speaker,start:transcript.segments[start].start)) }
        return paragraphs
    }
}
