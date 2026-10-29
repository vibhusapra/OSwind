import Foundation
import CryptoKit

/// A complete bounded document, independent of any backend's framed token budget.
/// Model words retain original scalar/UTF-16 coordinates, including long gaps.
struct PIIDocument:Sendable {
    static let maximumScalars=32768,maximumBytes=131072,maximumWords=8192
    static let maximumWindows=256,maximumFramedTokens=65536,maximumSpans=16384
    static let overlapWords=16
    let text:String,sha256:String,words:[PIITokenizer.Word]
    init(_ text:String)throws {
        try Task.checkCancellation()
        words=try PIITokenizer.splitDocument(text)
        guard !words.isEmpty,words.count<=Self.maximumWords,
              words.allSatisfy({$0.text.utf8.count<=PIITokenizer.maximumWordBytes}) else {
            throw OSwindError.invalid("PII document has no words or exceeds its word bounds; no scan returned")
        }
        self.text=text;sha256=Self.digest(text)
    }
    static func digest(_ text:String)->String {SHA256.hash(data:Data(text.utf8)).map {String(format:"%02x",$0)}.joined()}
}

struct PIIWindowPlan:Sendable {
    struct Window:Sendable {
        let id:String,sourceSHA256:String,text:String
        let wordRange:Range<Int>,input:PIITokenizer.Input
        fileprivate init(document:PIIDocument,range:Range<Int>,input:PIITokenizer.Input) {
            wordRange=range;self.input=input
            let span=NSRange(location:document.words[range.lowerBound].range.location,
                             length:NSMaxRange(document.words[range.upperBound-1].range)-document.words[range.lowerBound].range.location)
            // Preserve the complete short input, including outer whitespace.
            text=range == 0..<document.words.count ? document.text:(document.text as NSString).substring(with:span)
            sourceSHA256=PIIDocument.digest(text)
            id=document.sha256+":\(range.lowerBound):\(range.upperBound)"
        }
    }
    let documentSHA256:String,windows:[Window],framedTokens:Int
    private init(document:PIIDocument,windows:[Window],framedTokens:Int) {
        documentSHA256=document.sha256;self.windows=windows;self.framedTokens=framedTokens
    }

    /// Tokenize every original word once. Do not truncate a word/group to fit.
    /// A composed character's constituent model words remain in one window.
    static func make(document:PIIDocument,prompt:[Int64],tokenLimit:Int,padded:Bool=false,
                     encode:(String)throws->[Int64])throws->Self {
        try Task.checkCancellation()
        guard (2...512).contains(tokenLimit),!prompt.isEmpty,prompt.count+1<tokenLimit,
              prompt.allSatisfy({(0..<50370).contains($0)}) else {throw OSwindError.invalid("Invalid PII window token budget")}
        let capacity=tokenLimit-prompt.count-1,original=document.text as NSString
        var pieces=[[Int64]]();pieces.reserveCapacity(document.words.count)
        var legal=Array(repeating:true,count:document.words.count+1),previousWhole:NSRange?
        for (index,word) in document.words.enumerated() {
            try Task.checkCancellation()
            let ids=try encode(word.text)
            guard !ids.isEmpty,ids.count<=capacity,ids.allSatisfy({(0..<50370).contains($0)}) else {
                throw OSwindError.invalid("A PII word exceeds the model window; no truncated scan returned")
            }
            pieces.append(ids)
            let whole=original.rangeOfComposedCharacterSequences(for:word.range)
            if let previousWhole {legal[index]=NSMaxRange(previousWhole)<=whole.location}
            previousWhole=whole
        }
        var start=0,windows=[Window](),total=0
        while start<document.words.count {
            try Task.checkCancellation()
            var end=start,cost=0,lastLegal=start
            while end<pieces.count,cost+pieces[end].count<=capacity,end-start<PIIDecoding.maximumWords {
                cost+=pieces[end].count;end+=1;if legal[end] {lastLegal=end}
            }
            end=lastLegal
            guard end>start else {throw OSwindError.invalid("A whole PII character group exceeds the model window; no scan returned")}
            if let previous=windows.last,end<=previous.wordRange.upperBound {
                // Expensive next words may require relinquishing overlap. The
                // previous window already covers this prefix; never infer twice
                // solely to make progress through the overlap.
                start=previous.wordRange.upperBound;continue
            }
            var ids=prompt,mask=Array(repeating:Int64(0),count:prompt.count)
            for word in start..<end {
                ids+=pieces[word];mask.append(Int64(word-start+1))
                mask+=Array(repeating:0,count:pieces[word].count-1)
            }
            ids.append(50282);mask.append(0)
            let framed=padded ? tokenLimit:ids.count
            guard windows.count<PIIDocument.maximumWindows,total<=PIIDocument.maximumFramedTokens-framed else {
                throw OSwindError.invalid("PII document exceeds the complete-window work budget; no partial scan returned")
            }
            total+=framed
            let input=PIITokenizer.Input(inputIDs:ids,attentionMask:Array(repeating:1,count:ids.count),wordsMask:mask,words:Array(document.words[start..<end]))
            windows.append(Window(document:document,range:start..<end,input:input))
            if end==document.words.count {break}
            start=end-min(PIIDocument.overlapWords,(end-start)/2)
            while start<end && !legal[start] {start+=1}
        }
        return Self(document:document,windows:windows,framedTokens:total)
    }
    func validate(document:PIIDocument)throws {
        guard documentSHA256==document.sha256,!windows.isEmpty,windows.count<=PIIDocument.maximumWindows,
              framedTokens>0,framedTokens<=PIIDocument.maximumFramedTokens else {throw OSwindError.invalid("PII window plan belongs to another document or exceeds its bounds")}
        var covered=0,previousStart = -1
        for window in windows {
            try Task.checkCancellation()
            let range=window.wordRange
            guard range.lowerBound>previousStart,range.lowerBound<=covered,range.upperBound>covered,
                  range.upperBound<=document.words.count,range.count==window.input.words.count,
                  window.id==document.sha256+":\(range.lowerBound):\(range.upperBound)" else {throw OSwindError.invalid("PII window plan has missing or changed source coverage")}
            for (a,b) in zip(window.input.words,document.words[range]) {
                guard a.range==b.range,a.text.utf8.elementsEqual(b.text.utf8) else {throw OSwindError.invalid("PII window source coordinates changed")}
            }
            previousStart=range.lowerBound;covered=range.upperBound
        }
        guard covered==document.words.count else {throw OSwindError.invalid("PII window plan is incomplete; no scan returned")}
    }
}
