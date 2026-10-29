import Foundation
import CryptoKit
import Hub
import OSwindTokenizers

/// Native input contract for the pinned experimental GLiNER token-level model.
/// No backend, model installation or production redactor is selected here.
struct PIITokenizer:Sendable {
    struct Word:Equatable,Sendable {let text:String;let range:NSRange}
    struct Input:Sendable {
        let inputIDs:[Int64],attentionMask:[Int64],wordsMask:[Int64]
        let words:[Word]
        var textLength:Int64 {Int64(words.count)}
    }
    static let labels=["email address","phone number","location address","ssn","passport number","driver license","account number","credit card","dob","ip address","password","api key"]
    static let maximumTokens=512,maximumScalars=4096,maximumWordBytes=1024
    static let tokenizerSHA256="84b3a9b18f04a0ccd03b72d9f871b7e0bec40fd7021ef50bc30a7c3693c11205"
    static let configurationSHA256="3398f6d1ad4b4c4f9874d390d060a75c58cad5e5ce9b22841b3e40643b4ada27"
    private let tokenizer:Tokenizer
    private let prompt:[Int64]

    init(directory:URL)throws {
        try Task.checkCancellation()
        let tree=try BackupFileTree(root:directory)
        let data=try tree.read("tokenizer.json",limit:4*1024*1024)
        let configuration=try tree.read("tokenizer_config.json",limit:32768)
        func sha(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
        guard sha(data)==Self.tokenizerSHA256,sha(configuration)==Self.configurationSHA256 else {
            throw OSwindError.invalid("PII tokenizer assets differ from the pinned experimental model")
        }
        try Task.checkCancellation()
        // Explicit local data only: no Hub client, URL, credential or fallback.
        let tokenizer=try PreTrainedTokenizer(tokenizerConfig:JSONDecoder().decode(Config.self,from:configuration),tokenizerData:VisualTokenizerData.decode(data),strict:true)
        for (surface,id) in [("[CLS]",50281),("[SEP]",50282),("<<ENT>>",50368),("<<SEP>>",50369)] {
            guard tokenizer.convertTokenToId(surface)==id else {throw OSwindError.invalid("PII control token contract differs")}
        }
        var prompt=[Int64(50281)]
        for label in Self.labels {
            try Task.checkCancellation();prompt.append(50368)
            prompt += tokenizer.encode(text:label,addSpecialTokens:false).map(Int64.init)
        }
        prompt.append(50369)
        guard prompt.count<Self.maximumTokens-1 else {throw OSwindError.invalid("PII prompt exceeds input bound")}
        self.tokenizer=tokenizer;self.prompt=prompt
    }

    func encode(_ text:String)throws->Input {
        let words=try Self.split(text)
        guard !words.isEmpty else {throw OSwindError.invalid("PII input has no non-whitespace words")}
        var ids=prompt,mask=Array(repeating:Int64(0),count:prompt.count)
        for (ordinal,word) in words.enumerated() {
            try Task.checkCancellation()
            guard word.text.utf8.count<=Self.maximumWordBytes else {throw OSwindError.invalid("PII word exceeds bounded tokenization input")}
            let pieces=tokenizer.encode(text:word.text,addSpecialTokens:false)
            guard !pieces.isEmpty,ids.count+pieces.count+1<=Self.maximumTokens,
                  pieces.allSatisfy({(0..<50370).contains($0)}) else {
                throw OSwindError.invalid("PII input exceeds supported token contract; no truncated scan returned")
            }
            ids += pieces.map(Int64.init);mask.append(Int64(ordinal+1))
            mask += Array(repeating:0,count:pieces.count-1)
        }
        ids.append(50282);mask.append(0);try Task.checkCancellation()
        return Input(inputIDs:ids,attentionMask:Array(repeating:1,count:ids.count),wordsMask:mask,words:words)
    }

    /// Python3.12 re `\w+(?:[-_]\w+)*|\S`, with original scalar/UTF-16
    /// coordinates. Intermediate words can split a grapheme; future redaction
    /// admission must independently require/expand whole composed characters.
    static func split(_ text:String)throws->[Word] {
        guard text.utf8.count<=4*maximumScalars else {throw OSwindError.invalid("PII source exceeds input byte bound")}
        try Task.checkCancellation()
        let scalars=Array(text.unicodeScalars)
        guard scalars.count<=maximumScalars else {throw OSwindError.invalid("PII source exceeds input scalar bound")}
        var offsets=[Int]();offsets.reserveCapacity(scalars.count+1);offsets.append(0)
        for scalar in scalars {offsets.append(offsets.last!+(scalar.value>0xffff ? 2:1))}
        let original=text as NSString
        var cursor=0,words=[Word]()
        while cursor<scalars.count {
            if cursor%64==0 {try Task.checkCancellation()}
            let start=cursor
            if PIIWordCharacters.contains(scalars[cursor].value) {
                cursor+=1
                while cursor<scalars.count && PIIWordCharacters.contains(scalars[cursor].value) {cursor+=1}
                while cursor+1<scalars.count && scalars[cursor].value==45 && PIIWordCharacters.contains(scalars[cursor+1].value) {
                    cursor+=2
                    while cursor<scalars.count && PIIWordCharacters.contains(scalars[cursor].value) {cursor+=1}
                }
            } else {
                cursor+=1
                if whitespace(scalars[start].value) {continue}
            }
            let range=NSRange(location:offsets[start],length:offsets[cursor]-offsets[start])
            words.append(Word(text:original.substring(with:range),range:range))
        }
        try Task.checkCancellation();return words
    }
    private static func whitespace(_ value:UInt32)->Bool {
        switch value {
        case 9...13,28...32,0x85,0xa0,0x1680,0x2000...0x200a,0x2028,0x2029,0x202f,0x205f,0x3000:return true
        default:return false
        }
    }
}
