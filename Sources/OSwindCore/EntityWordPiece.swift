import Foundation

/// Cased BERT WordPiece with original UTF-16 offsets. Vocabulary is immutable;
/// captured text is never retained after this bounded call. No Hub/network path.
struct EntityWordPieceTokenizer:Sendable {
    struct Token:Equatable,Sendable {var id:Int32;var range:NSRange;var word:Int?}
    private struct Scalar {var value:Unicode.Scalar;var start:Int;var end:Int}
    private enum Basic {case word([Scalar]);case special(Int32,NSRange)}
    static let maximumUTF16=32768
    private let vocabulary:[String:Int32]
    private let special:[([Unicode.Scalar],Int32)]
    init(vocabulary:[String:Int32]) throws {
        guard !vocabulary.isEmpty,vocabulary.count<=30000,Set(vocabulary.values).count==vocabulary.count,
              vocabulary.values.allSatisfy({$0>=0 && $0<30000}),
              ["[PAD]":Int32(0),"[UNK]":100,"[CLS]":101,"[SEP]":102,"[MASK]":103].allSatisfy({vocabulary[$0.key]==$0.value})
        else {throw OSwindError.invalid("Use the supported cased entity vocabulary")}
        self.vocabulary=vocabulary
        special=["[PAD]","[UNK]","[CLS]","[SEP]","[MASK]"].map {(Array($0.unicodeScalars),vocabulary[$0]!)}
    }
    func tokenize(_ text:String) throws ->[Token] {
        guard text.utf16.count<=Self.maximumUTF16 else {throw OSwindError.invalid("Entity tokenizer input exceeds 32,768 UTF-16 units")}
        try Task.checkCancellation()
        var scalars=[Scalar](),offset=0
        for scalar in text.unicodeScalars {let end=offset+(scalar.value>0xffff ? 2:1);scalars.append(.init(value:scalar,start:offset,end:end));offset=end}
        var basics=[Basic](),current=[Scalar](),cursor=0
        func flush() {if !current.isEmpty {basics.append(.word(current));current.removeAll(keepingCapacity:true)}}
        while cursor<scalars.count {
            if cursor%256==0 {try Task.checkCancellation()}
            let item=scalars[cursor],value=item.value.value
            if value==91,let match=special.first(where:{pattern,_ in cursor+pattern.count<=scalars.count && pattern.indices.allSatisfy({scalars[cursor+$0].value==pattern[$0]})}) {
                flush();let end=scalars[cursor+match.0.count-1].end;basics.append(.special(match.1,NSRange(location:item.start,length:end-item.start)));cursor+=match.0.count;continue
            }
            cursor+=1
            // BERT clean_text removes controls (except TAB/LF/CR) before
            // whitespace splitting. Keep source coordinates across removals.
            if value==0 || value==0xfffd || ((item.value.properties.generalCategory == .control || item.value.properties.generalCategory == .format) && ![9,10,13].contains(value)) {continue}
            if item.value.properties.isWhitespace {flush();continue}
            if Self.punctuation(item.value) || Self.chinese(value) {flush();basics.append(.word([item]))}
            else {current.append(item)}
        }
        flush();var result=[Token](),word=0
        for basic in basics {
            try Task.checkCancellation()
            switch basic {
            case .special(let id,let range):result.append(.init(id:id,range:range,word:nil))
            case .word(let values):
                let whole=NSRange(location:values[0].start,length:values[values.count-1].end-values[0].start)
                defer {word+=1}
                guard values.count<=100 else {result.append(.init(id:100,range:whole,word:word));continue}
                var begin=0,pieces=[Token](),unknown=false
                while begin<values.count {
                    var end=values.count,match:(Int32,Int)?
                    while end>begin {
                        let surface=String(String.UnicodeScalarView(values[begin..<end].map(\.value)))
                        if let id=vocabulary[(begin==0 ? "":"##")+surface] {match=(id,end);break}
                        end-=1
                    }
                    guard let match else {unknown=true;break}
                    let start=values[begin].start,finish=values[match.1-1].end
                    pieces.append(.init(id:match.0,range:NSRange(location:start,length:finish-start),word:word));begin=match.1
                }
                if unknown {result.append(.init(id:100,range:whole,word:word))}else {result+=pieces}
            }
        }
        try Task.checkCancellation();return result
    }
    private static func punctuation(_ scalar:Unicode.Scalar)->Bool {
        let value=scalar.value
        if (33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value) || (123...126).contains(value) {return true}
        switch scalar.properties.generalCategory {
        case .connectorPunctuation,.dashPunctuation,.openPunctuation,.closePunctuation,.initialPunctuation,.finalPunctuation,.otherPunctuation:return true
        default:return false
        }
    }
    private static func chinese(_ value:UInt32)->Bool {
        [(0x4e00...0x9fff),(0x3400...0x4dbf),(0x20000...0x2a6df),(0x2a700...0x2b73f),(0x2b740...0x2b81f),(0x2b820...0x2ceaf),(0xf900...0xfaff),(0x2f800...0x2fa1f)].contains {range in range.contains(Int(value))}
    }
}
