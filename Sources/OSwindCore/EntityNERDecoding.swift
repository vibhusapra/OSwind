import Foundation

/// Internal groundwork for the optional native recognizer. Current library
/// indexing continues using Apple name tagging until explicit backend wiring.
struct EntityNERWindow:Sendable {
    let tokens:[EntityWordPieceTokenizer.Token]
    var inputIDs:[Int32] {[101]+tokens.map(\.id)+[102]+Array(repeating:0,count:254-tokens.count)}
    var attentionMask:[Int32] {Array(repeating:1,count:tokens.count+2)+Array(repeating:0,count:254-tokens.count)}
    static func make(_ tokens:[EntityWordPieceTokenizer.Token]) throws ->[Self] {
        try Task.checkCancellation()
        guard tokens.count<=EntityWordPieceTokenizer.maximumUTF16 else {throw OSwindError.invalid("Entity token count exceeds its input bound")}
        var result=[Self](),start=0
        while start<tokens.count {
            try Task.checkCancellation();var end=min(tokens.count,start+254)
            if end<tokens.count,let word=tokens[end].word {while end>start && tokens[end-1].word==word {end-=1}}
            guard end>start else {throw OSwindError.invalid("Entity word exceeds the 254-token window")}
            result.append(.init(tokens:Array(tokens[start..<end])))
            if end==tokens.count {break}
            var next=max(start+1,end-64)
            if let word=tokens[next].word {while next>start && tokens[next-1].word==word {next-=1}}
            if next<=start {
                next=start+1
                if let word=tokens[start].word {while next<end && tokens[next].word==word {next+=1}}
            }
            guard next>start,next<=end else {throw OSwindError.invalid("Entity window did not advance")};start=next
        }
        return result
    }
}

enum EntityNERDecoder {
    /// Pinned model labels: O, B/I-PER, B/I-ORG, B/I-LOC, B/I-MISC.
    /// First subword decides each whole word. Literal model-control tokens
    /// close evidence spans; they cannot become names from captured text.
    static func decode(text:String,window:EntityNERWindow,labels:[Int]) throws ->[EntityCandidate] {
        try Task.checkCancellation()
        guard text.utf16.count<=EntityWordPieceTokenizer.maximumUTF16,window.tokens.count<=254,labels.count==256,labels.allSatisfy({(0...8).contains($0)}) else {throw OSwindError.invalid("Invalid entity decoder input")}
        let source=text as NSString,units=Array(text.utf16);var previousEnd=0
        func scalarBoundary(_ offset:Int)->Bool {
            offset==0 || offset==units.count || !((0xd800...0xdbff).contains(units[offset-1]) && (0xdc00...0xdfff).contains(units[offset]))
        }
        for token in window.tokens {
            guard token.range.location>=previousEnd,token.range.length>0,token.range.location<=source.length,token.range.length<=source.length-token.range.location,scalarBoundary(token.range.location),scalarBoundary(NSMaxRange(token.range)) else {throw OSwindError.invalid("Entity token is outside its source")}
            previousEnd=NSMaxRange(token.range)
        }
        var word:(id:Int,label:Int,range:NSRange)?,entity:(kind:EntityKind,range:NSRange)?,result=[EntityCandidate]()
        func finishEntity() {
            if let entity,let surface=PassageRange(start:entity.range.location,length:entity.range.length).text(in:text),let name=try? EntityLabel.clean(surface),!name.contains("[REDACTED]"),entity.range.length<=2048 {
                result.append(.init(kind:entity.kind,name:name,start:entity.range.location,length:entity.range.length,method:"coreml-distilbert"))
            }
            entity=nil
        }
        func finishWord() {
            guard let current=word else {return};word=nil
            let kind:EntityKind?
            switch current.label {case 1,2:kind = .person;case 3,4:kind = .organization;case 5,6:kind = .place;default:kind=nil}
            guard let kind else {finishEntity();return}
            if let existing=entity,existing.kind==kind,[2,4,6].contains(current.label) {entity=(kind,NSRange(location:existing.range.location,length:NSMaxRange(current.range)-existing.range.location))}
            else {finishEntity();entity=(kind,current.range)}
        }
        for (index,token) in window.tokens.enumerated() {
            if index%32==0 {try Task.checkCancellation()}
            guard let id=token.word else {finishWord();finishEntity();continue}
            if let current=word,current.id==id {word=(id,current.label,NSRange(location:current.range.location,length:NSMaxRange(token.range)-current.range.location))}
            else {finishWord();word=(id,labels[index+1],token.range)}
        }
        finishWord();finishEntity();try Task.checkCancellation();return result
    }
}
