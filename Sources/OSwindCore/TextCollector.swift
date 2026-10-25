import Foundation
import CryptoKit

/// Explicit external text admission. This does not load plugins, start capture,
/// establish source authenticity, or expose mutation through HTTP/MCP.
public enum TextCollector {
    public static let maximumBatchBytes=16*1024*1024
    static func text(_ value:String,limit:Int,metadata:Bool=false,allowEmpty:Bool=false)throws {
        guard (allowEmpty || !value.isEmpty),value.utf8.count<=limit,!value.utf8.contains(0),!metadata || !value.unicodeScalars.contains(where:{$0.value<32 || (127...159).contains($0.value)}) else {throw OSwindError.invalid("Collector field exceeds its text bound or contains controls")}
    }
    static func identity(_ value:String)throws {
        try text(value,limit:120,metadata:true)
        let parts=value.split(separator:".",omittingEmptySubsequences:false)
        func alphanumeric(_ c:UInt8)->Bool {(97...122).contains(c) || (48...57).contains(c)}
        guard parts.count>=2,parts.allSatisfy({part in let bytes=Array(part.utf8);return !bytes.isEmpty && alphanumeric(bytes[0]) && alphanumeric(bytes[bytes.count-1]) && bytes.allSatisfy({alphanumeric($0) || $0==45})}) else {throw OSwindError.invalid("Use a lowercase reverse-DNS collector identity")}
    }
    private static func digest(_ value:String)->String {SHA256.hash(data:Data(value.utf8)).map {String(format:"%02x",$0)}.joined()}
    public static func sourceID(collectorID:String,key:String)throws->String {
        try identity(collectorID);try text(key,limit:512,metadata:true)
        // Exact UTF-8 identity: canonically equivalent keys can name different
        // external records. Ordinary source UUIDs occupy a separate namespace.
        return "collector:"+collectorID+":"+digest(key)
    }
    public static func tag(collectorID:String)throws->String {try identity(collectorID);return "collector:"+digest(collectorID).prefix(32)}
}
public struct CollectorImportResult:Codable,Sendable {
    public var format="OSwind collector result",version=1
    public var collectorID:String,requested:Int,imported:Int,excluded:Int,sourceIDs:[String]
}
private struct CollectorKey:CodingKey {
    let stringValue:String;var intValue:Int? {nil}
    init?(stringValue:String){self.stringValue=stringValue}
    init?(intValue:Int){return nil}
}
private func collectorFields(_ decoder:Decoder,_ names:Set<String>)throws->KeyedDecodingContainer<CollectorKey> {
    let result=try decoder.container(keyedBy:CollectorKey.self)
    guard result.allKeys.allSatisfy({names.contains($0.stringValue)}) else {throw OSwindError.invalid("Unknown collector field; use the version 1 text contract")}
    return result
}
private func collectorKey(_ name:String)->CollectorKey {CollectorKey(stringValue:name)!}
private struct CollectorRecord:Decodable {
    let key:String,timestamp:Date,app:String,bundleID:String,title:String,text:String,url:String?
    init(from decoder:Decoder)throws {
        let c=try collectorFields(decoder,["key","timestamp","app","bundleID","title","text","url"])
        key=try c.decode(String.self,forKey:collectorKey("key"));app=try c.decode(String.self,forKey:collectorKey("app"));bundleID=try c.decode(String.self,forKey:collectorKey("bundleID"));title=try c.decode(String.self,forKey:collectorKey("title"));text=try c.decode(String.self,forKey:collectorKey("text"));url=try c.decodeIfPresent(String.self,forKey:collectorKey("url"))
        let instant=try c.decode(String.self,forKey:collectorKey("timestamp")),suffix=Array(instant.suffix(6).utf8)
        let offset=suffix.count==6 && [43,45].contains(suffix[0]) && suffix[3]==58 && [1,2,4,5].allSatisfy({(48...57).contains(suffix[$0])})
        guard instant.hasSuffix("Z") || offset else {throw OSwindError.invalid("Use a complete collector timestamp with a time zone")}
        timestamp=try QueryScopeResolver.instant(instant)
        try TextCollector.text(key,limit:512,metadata:true);try TextCollector.text(app,limit:128,metadata:true);try TextCollector.text(bundleID,limit:255,metadata:true);try TextCollector.text(title,limit:4096,metadata:true,allowEmpty:true);try TextCollector.text(text,limit:1024*1024)
        if let url {
            try TextCollector.text(url,limit:8192,metadata:true)
            guard url==url.trimmingCharacters(in:.whitespacesAndNewlines),let parsed=URLComponents(string:url),["http","https"].contains(parsed.scheme?.lowercased() ?? ""),parsed.host?.isEmpty==false,parsed.user==nil,parsed.password==nil else {throw OSwindError.invalid("Use a complete HTTP(S) collector source URL without credentials")}
        }
    }
}
private struct CollectorBatch:Decodable {
    let collectorID:String,records:[CollectorRecord]
    init(from decoder:Decoder)throws {
        let c=try collectorFields(decoder,["format","version","collectorID","records"])
        guard try c.decode(String.self,forKey:collectorKey("format"))=="OSwind collector batch",try c.decode(Int.self,forKey:collectorKey("version"))==1 else {throw OSwindError.invalid("Unsupported collector format or version")}
        collectorID=try c.decode(String.self,forKey:collectorKey("collectorID"));try TextCollector.identity(collectorID)
        var input=try c.nestedUnkeyedContainer(forKey:collectorKey("records")),decoded=[CollectorRecord]()
        while !input.isAtEnd {try Task.checkCancellation();guard decoded.count<1000 else {throw OSwindError.invalid("Use at most 1000 collector records")};decoded.append(try input.decode(CollectorRecord.self))}
        guard !decoded.isEmpty else {throw OSwindError.invalid("Use at least one collector record")};records=decoded
    }
}
public extension MemoryStore {
    /// Validate the whole bounded batch before reserving a writer. Stable IDs
    /// permit retry after an unknown transport result; exclusions are prospective.
    func importCollectorBatch(_ data:Data,embedder:LocalEmbedder?=nil,policy:PrivacyPolicy=PrivacyPolicy())throws->CollectorImportResult {
        try Task.checkCancellation();guard data.count<=TextCollector.maximumBatchBytes else {throw OSwindError.invalid("Collector batch exceeds 16 MiB")}
        let batch=try JSONDecoder().decode(CollectorBatch.self,from:data),tag=try TextCollector.tag(collectorID:batch.collectorID)
        var memories=[Memory](),ids=[String](),seen=Set<String>()
        for record in batch.records {
            try Task.checkCancellation();let id=try TextCollector.sourceID(collectorID:batch.collectorID,key:record.key)
            guard seen.insert(id).inserted else {throw OSwindError.invalid("Collector source keys must be unique within a batch")}
            var memory=Memory(id:id,timestamp:record.timestamp,kind:.note,app:record.app,bundleID:record.bundleID,title:record.title,url:record.url,text:record.text);memory.tags=["collector",tag];memories.append(memory);ids.append(id)
        }
        let admission=try mediaWriteLease();defer {admission.release()}
        let result=try importDecodedMemoriesDetailed(memories,embedder:embedder,policy:policy,collectorAdmission:true)
        return .init(collectorID:batch.collectorID,requested:memories.count,imported:result.imported,excluded:result.excluded,sourceIDs:ids)
    }
}
