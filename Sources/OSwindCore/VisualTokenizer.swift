import Foundation
import OSwindTokenizers
import Hub

struct VisualTokens:Sendable {var ids:[Int];var truncated:Bool}
/// The pinned Gemma BPE tokenizer preserves case, accents and whitespace.
/// Truncate before EOS, then right-pad: SigLIP pools the final position.
struct VisualTokenizer:Sendable {
    private let tokenizer:Tokenizer
    init(directory:URL) async throws {
        let tree=try BackupFileTree(root:directory)
        let configuration=try JSONDecoder().decode(Config.self,from:tree.read("tokenizer_config.json",limit:65536))
        let vocabulary=try VisualTokenizerData.decode(tree.read("tokenizer.json",limit:36*1024*1024))
        try Task.checkCancellation()
        // Explicit in-memory config: no Hub client, token lookup, fallback
        // resource accessor, URLSession or model-name resolution is constructed.
        tokenizer=try PreTrainedTokenizer(tokenizerConfig:configuration,tokenizerData:vocabulary,strict:true)
    }
    func encode(_ query:String) throws -> VisualTokens {
        guard query.utf8.count<=32768 else {throw OSwindError.invalid("Visual queries must fit in 32 KiB")}
        try Task.checkCancellation()
        let raw=tokenizer.encode(text:query,addSpecialTokens:false)
        var ids=Array(raw.prefix(63))+[1];ids += Array(repeating:0,count:64-ids.count)
        guard ids.allSatisfy({(0..<256000).contains($0)}) else {throw OSwindError.invalid("Visual tokenizer returned invalid token IDs")}
        return VisualTokens(ids:ids,truncated:raw.count>63)
    }
}
