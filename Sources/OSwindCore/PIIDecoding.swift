import Foundation
import CryptoKit

/// Experimental batch-one, flat/single-label GLiNER token-output contract.
/// Not selected by capture/import/export or the model installer.
enum PIIDecoding {
    static let maximumWords=512,maximumCandidates=16384
    private static let categories=["email","phone","address","government_id","government_id","government_id","financial_id","credit_card","date_of_birth","ip_address","secret","secret"]

    struct Source:Sendable {
        let sha256:String
        let words:[PIITokenizer.Word]
        init(_ text:String)throws {
            try Task.checkCancellation()
            words=try PIITokenizer.split(text)
            guard words.count<=maximumWords else {throw OSwindError.invalid("PII source exceeds decoder word bound")}
            sha256=PIIDecoding.digest(text)
        }
    }
    struct Span:Equatable,Sendable {
        let startWord:Int,endWord:Int,labelIndex:Int
        let range:NSRange
        let confidence:Float
        var promptLabel:String {PIITokenizer.labels[labelIndex]}
        var category:String {categories[labelIndex]}
        fileprivate init(startWord:Int,endWord:Int,labelIndex:Int,range:NSRange,confidence:Float) {
            self.startWord=startWord;self.endWord=endWord;self.labelIndex=labelIndex;self.range=range;self.confidence=confidence
        }
    }
    struct Detection:Sendable {
        let sourceSHA256:String
        let spans:[Span]
        fileprivate init(sourceSHA256:String,spans:[Span]) {self.sourceSHA256=sourceSHA256;self.spans=spans}
    }
    struct Redaction:Sendable {
        let text:String
        let ranges:[NSRange]
        var redacted:Bool {!ranges.isEmpty}
        var suppressMedia:Bool {redacted}
    }
    private struct Candidate {let start:Int,end:Int,label:Int,score:Float,ordinal:Int}
    private static func digest(_ text:String)->String {SHA256.hash(data:Data(text.utf8)).map {String(format:"%02x",$0)}.joined()}

    /// Accept only (1, exact source word count, 12 labels, start/end/inside).
    /// One malformed/nonfinite/budget-exhausted result refuses the entire call.
    static func decode(source:Source,shape:[Int],logits:[Float],threshold:Double)throws->Detection {
        try Task.checkCancellation()
        let count=source.words.count,classes=PIITokenizer.labels.count
        guard threshold.isFinite,threshold>0,threshold<1,
              count<=maximumWords,shape == [1,count,classes,3],logits.count==count*classes*3,
              logits.allSatisfy(\.isFinite) else {throw OSwindError.invalid("Invalid PII token-output tensor or threshold")}
        var probabilities=[Float]();probabilities.reserveCapacity(logits.count)
        for (index,value) in logits.enumerated() {
            if index%512==0 {try Task.checkCancellation()}
            probabilities.append(1/(1+expf(-value)))
        }
        func score(_ word:Int,_ label:Int,_ channel:Int)->Float {probabilities[(word*classes+label)*3+channel]}
        var candidates=[Candidate]()
        // Torch where() enumerates start word, then class; end positions follow
        // ascending order. Explicit ordinals preserve its stable tie ordering.
        for start in 0..<count {
            try Task.checkCancellation()
            for label in 0..<classes where score(start,label,0)>Float(threshold) {
                var insideMinimum=Float(1)
                for end in start..<count {
                    if end%128==0 {try Task.checkCancellation()}
                    let inside=score(end,label,2)
                    // The reference transfers Float32 inside probabilities to
                    // Python floats before comparison against the Double tau.
                    if Double(inside)<threshold {break}
                    insideMinimum=min(insideMinimum,inside)
                    if score(end,label,1)>Float(threshold) {
                        guard candidates.count<maximumCandidates else {throw OSwindError.invalid("PII candidate budget exceeded; no partial scan returned")}
                        candidates.append(Candidate(start:start,end:end,label:label,score:min(insideMinimum,score(start,label,0),score(end,label,1)),ordinal:candidates.count))
                    }
                }
            }
        }
        candidates.sort {a,b in a.score==b.score ? a.ordinal<b.ordinal:a.score>b.score}
        var occupied=Array(repeating:false,count:count),selected=[Candidate]()
        for (index,candidate) in candidates.enumerated() {
            if index%128==0 {try Task.checkCancellation()}
            if (candidate.start...candidate.end).contains(where:{occupied[$0]}) {continue}
            for word in candidate.start...candidate.end {occupied[word]=true}
            selected.append(candidate)
        }
        selected.sort {$0.start<$1.start}
        let spans=selected.map {item in
            let begin=source.words[item.start].range.location,end=NSMaxRange(source.words[item.end].range)
            return Span(startWord:item.start,endWord:item.end,labelIndex:item.label,range:NSRange(location:begin,length:end-begin),confidence:item.score)
        }
        try Task.checkCancellation();return Detection(sourceSHA256:source.sha256,spans:spans)
    }

    /// Expand raw model ranges to complete original composed characters, merge
    /// overlapping/touching masks, then replace from the end. Never normalize
    /// or use canonical String equality to admit a different source revision.
    static func redact(_ text:String,detection:Detection)throws->Redaction {
        try Task.checkCancellation()
        guard text.utf8.count<=4*PIITokenizer.maximumScalars,digest(text)==detection.sourceSHA256 else {throw OSwindError.invalid("PII result belongs to different source bytes")}
        return try mask(text,ranges:detection.spans.map(\.range))
    }
    static func mask(_ text:String,ranges:[NSRange])throws->Redaction {
        try Task.checkCancellation()
        guard text.utf8.count<=4*PIITokenizer.maximumScalars else {throw OSwindError.invalid("PII source exceeds input byte bound")}
        let original=text as NSString
        var masks=[NSRange]()
        for range in ranges {
            try Task.checkCancellation()
            guard range.location>=0,range.length>0,range.location<=original.length,
                  range.length<=original.length-range.location else {throw OSwindError.invalid("PII span is outside its source")}
            let whole=original.rangeOfComposedCharacterSequences(for:range)
            guard whole.location>=0,whole.length>0,whole.location<=original.length,whole.length<=original.length-whole.location,
                  PassageRange(start:whole.location,length:whole.length).text(in:text) != nil else {throw OSwindError.invalid("PII mask does not cover whole source characters")}
            masks.append(whole)
        }
        masks.sort {$0.location<$1.location}
        var merged=[NSRange]()
        for range in masks {
            if let previous=merged.last,range.location<=NSMaxRange(previous) {
                merged[merged.count-1]=NSRange(location:previous.location,length:max(NSMaxRange(previous),NSMaxRange(range))-previous.location)
            } else {merged.append(range)}
        }
        let output=NSMutableString(string:text)
        for range in merged.reversed() {try Task.checkCancellation();output.replaceCharacters(in:range,with:"[REDACTED]")}
        try Task.checkCancellation();return Redaction(text:output as String,ranges:merged)
    }
}
