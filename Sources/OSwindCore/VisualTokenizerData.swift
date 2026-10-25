import Foundation
import CoreFoundation
import Hub

/// Explicit local tokenizer-data boundary; callers retain the pinned model
/// verification and never construct a Hub client or model-name resolver.
enum VisualTokenizerData {
    static let maximumBytes=36*1024*1024
    static func decode(_ data:Data)throws->Config {
        try Task.checkCancellation()
        guard data.count<=maximumBytes else {throw OSwindError.invalid("Visual tokenizer exceeds its byte bound")}
        return try autoreleasepool {
            // Keep Foundation dictionaries through enumeration. Bridging the
            // vocabulary into [String:Any] or keyed JSONDecoder loses distinct
            // UTF-8 spellings under Swift String canonical equality.
            // Foundation also strips leading U+FEFF inside JSON strings. Mark
            // every string before parsing, then remove exactly our one ASCII
            // byte. This keeps BOM tokens away from that implicit conversion.
            guard let root=try JSONSerialization.jsonObject(with:markStrings(data)) as? NSDictionary,root.count<=32 else {throw invalid()}
            try Task.checkCancellation()
            var result=[BinaryDistinctString:Config](),metadataBytes=0
            for (key,value) in root {
                try Task.checkCancellation();let key=try string(key)
                result[BinaryDistinctString(key)] = key=="model" ? try model(value,metadataBytes:&metadataBytes):try metadata(value,bytes:&metadataBytes)
            }
            guard result["model"] != nil else {throw invalid()}
            try Task.checkCancellation();return Config(result)
        }
    }
    private static func invalid()->OSwindError {.invalid("Unsupported or malformed pinned BPE tokenizer data")}
    private static func markStrings(_ data:Data)throws->Data {
        var output=[UInt8]();output.reserveCapacity(data.count+data.count/2)
        var inside=false,escaped=false
        try data.withUnsafeBytes {bytes in
            for offset in 0..<bytes.count {
                if offset%65536==0 {try Task.checkCancellation()}
                let byte=bytes[offset];output.append(byte)
                if inside {
                    if escaped {escaped=false}
                    else if byte==92 {escaped=true}
                    else if byte==34 {inside=false}
                } else if byte==34 {inside=true;output.append(64)}
            }
        }
        return Data(output)
    }
    private static func string(_ value:Any?)throws->String {
        guard let value=value as? String,value.utf8.first==64 else {throw invalid()}
        // Remove one ASCII byte, not a Character: a leading combining mark
        // would otherwise join our marker and be removed with its grapheme.
        return String(decoding:value.utf8.dropFirst(),as:UTF8.self)
    }
    private static func unmark(_ value:Any,depth:Int=0,nodes:inout Int)throws->Any {
        try Task.checkCancellation();nodes+=1
        guard depth<=32,nodes<=32768 else {throw invalid()}
        if value is String {return try string(value)}
        if let dictionary=value as? NSDictionary {
            guard dictionary.count<=32768 else {throw invalid()}
            let result=NSMutableDictionary(capacity:dictionary.count)
            for (key,value) in dictionary {result[try string(key) as NSString]=try unmark(value,depth:depth+1,nodes:&nodes)}
            guard result.count==dictionary.count else {throw invalid()};return result
        }
        if let array=value as? NSArray {
            guard array.count<=32768 else {throw invalid()}
            return try array.map {try unmark($0,depth:depth+1,nodes:&nodes)}
        }
        guard value is NSNumber || value is NSNull else {throw invalid()};return value
    }
    private static func metadata(_ value:Any,bytes:inout Int)throws->Config {
        try Task.checkCancellation()
        var nodes=0
        let data=try JSONSerialization.data(withJSONObject:unmark(value,nodes:&nodes),options:[.fragmentsAllowed])
        guard data.count<=256*1024,bytes<=512*1024-data.count else {throw invalid()};bytes+=data.count
        // Preserve existing Config semantics for the small metadata, including
        // token tuples, nulls, booleans and normalizer/pre-tokenizer settings.
        let config=try JSONDecoder().decode(Config.self,from:data)
        try Task.checkCancellation();return config
    }
    private static func model(_ value:Any,metadataBytes:inout Int)throws->Config {
        guard let object=value as? NSDictionary,object.count<=32,try string(object["@type"])=="BPE",
              let vocabulary=object["@vocab"] as? NSDictionary,(1...256000).contains(vocabulary.count),
              let merges=object["@merges"] as? NSArray,merges.count<=580604 else {throw invalid()}
        var tokens=[BinaryDistinctString:Config]();tokens.reserveCapacity(vocabulary.count)
        var index=0
        for (key,value) in vocabulary {
            if index%1024==0 {try Task.checkCancellation()};index+=1
            let key=try string(key)
            guard key.utf8.count<=32768,let number=value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {throw invalid()}
            let raw=number.doubleValue
            guard raw.isFinite,raw>=0,raw<256000,raw.rounded(.towardZero)==raw else {throw invalid()}
            tokens[BinaryDistinctString(key)]=Config(Int(raw))
        }
        // Exact binary-distinct keys must survive the Foundation bridge.
        guard tokens.count==vocabulary.count else {throw invalid()}
        var pairs=[Config]();pairs.reserveCapacity(merges.count)
        for (offset,value) in merges.enumerated() {
            if offset%1024==0 {try Task.checkCancellation()}
            guard let pair=value as? NSArray,pair.count==2 else {throw invalid()}
            let a=try string(pair[0]),b=try string(pair[1])
            guard a.utf8.count<=32768,b.utf8.count<=32768 else {throw invalid()}
            pairs.append(Config([Config(a),Config(b)]))
        }
        var result=[BinaryDistinctString:Config]()
        for (key,value) in object {
            try Task.checkCancellation();let key=try string(key)
            switch key {
            case "vocab":result[BinaryDistinctString(key)]=Config(tokens)
            case "merges":result[BinaryDistinctString(key)]=Config(pairs)
            default:result[BinaryDistinctString(key)]=try metadata(value,bytes:&metadataBytes)
            }
        }
        return Config(result)
    }
}
