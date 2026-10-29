import Foundation
import CryptoKit

/// Explicit, offline text migration from API responses. This is not the
/// undocumented account-export ZIP format and does not authenticate the source.
public enum LimitlessImport {
    public static let maximumBytes=16*1024*1024
    public static func sourceID(_ externalID:String)throws->String {
        try text(externalID,limit:512,metadata:true)
        return "limitless:"+SHA256.hash(data:Data(externalID.utf8)).map {String(format:"%02x",$0)}.joined()
    }
    fileprivate static func invalid(_ reason:String)->OSwindError {.invalid("Limitless API JSON: "+reason)}
    fileprivate static func text(_ value:String,limit:Int,metadata:Bool=false)throws {
        guard value.utf8.count<=limit,!value.utf8.contains(0),!metadata || (!value.isEmpty && !value.unicodeScalars.contains {$0.value<32 || (127...159).contains($0.value)}) else {throw invalid("text exceeds its bound or contains unsupported controls")}
    }
    fileprivate static func instant(_ value:String)throws->Date {
        let suffix=Array(value.suffix(6).utf8)
        let offset=suffix.count==6 && [43,45].contains(suffix[0]) && suffix[3]==58 && [1,2,4,5].allSatisfy({(48...57).contains(suffix[$0])})
        guard value.hasSuffix("Z") || offset else {throw invalid("timestamps need an explicit time zone")}
        return try QueryScopeResolver.instant(value)
    }
}

public struct LimitlessImportResult:Codable,Sendable {
    public var learnedPrivacy:PIIImportSummary?=nil
    public var format="OSwind Limitless API text import",version=1
    public var requested:Int,imported:Int,excluded:Int,hasMorePages:Bool,sourceIDs:[String]
}

/// Small bounded JSON reader: duplicate keys and unsupported fields are errors,
/// rather than an apparently successful lossy migration. Strings are decoded
/// with an ASCII marker to protect leading U+FEFF from Foundation conversion.
private indirect enum LJSON {
    case object([String:LJSON]),array([LJSON]),string(String),number(String),bool(Bool),null
    func fields(_ allowed:Set<String>)throws->[String:LJSON] {
        guard case .object(let fields)=self,fields.keys.allSatisfy({allowed.contains($0)}) else {throw LimitlessImport.invalid("unsupported object or field; no records imported")};return fields
    }
    func string()throws->String {guard case .string(let value)=self else {throw LimitlessImport.invalid("expected text")};return value}
    func array()throws->[LJSON] {guard case .array(let value)=self else {throw LimitlessImport.invalid("expected an array")};return value}
    func boolean()throws->Bool {guard case .bool(let value)=self else {throw LimitlessImport.invalid("expected a boolean")};return value}
    func integer()throws->Int64 {guard case .number(let raw)=self,let value=Int64(raw),value>=0 else {throw LimitlessImport.invalid("expected a nonnegative integer")};return value}
    var isNull:Bool {if case .null=self {return true};return false}
}
private extension Dictionary where Key==String,Value==LJSON {
    func required(_ name:String)throws->LJSON {guard let value=self[name] else {throw LimitlessImport.invalid("missing "+name)};return value}
}
private struct LJSONReader {
    let bytes:[UInt8];var offset=0,nodes=0
    init(_ data:Data)throws {
        guard data.count<=LimitlessImport.maximumBytes else {throw LimitlessImport.invalid("input exceeds 16 MiB")};bytes=Array(data)
        if bytes.starts(with:[0xef,0xbb,0xbf]) {offset=3}
    }
    mutating func read()throws->LJSON {let result=try value(0);space();guard offset==bytes.count else {throw bad()};return result}
    func bad()->OSwindError {LimitlessImport.invalid("malformed, duplicate-key or over-complex JSON")}
    mutating func space() {while offset<bytes.count,[9,10,13,32].contains(bytes[offset]) {offset+=1}}
    mutating func take(_ byte:UInt8)->Bool {space();guard offset<bytes.count,bytes[offset]==byte else {return false};offset+=1;return true}
    mutating func string()throws->String {
        guard take(34) else {throw bad()};let start=offset;var escaped=false
        while offset<bytes.count {
            let byte=bytes[offset];offset+=1
            guard offset-start<=1024*1024 else {throw bad()}
            if byte==34 && !escaped {
                var token=Data([34,64]);token.append(contentsOf:bytes[start..<offset])
                let marked=try JSONDecoder().decode(String.self,from:token)
                guard marked.utf8.first==64 else {throw bad()}
                return String(decoding:marked.utf8.dropFirst(),as:UTF8.self)
            }
            if byte==92 && !escaped {escaped=true} else {escaped=false}
            if (offset-start)%65536==0 {try Task.checkCancellation()}
        };throw bad()
    }
    mutating func value(_ depth:Int)throws->LJSON {
        try Task.checkCancellation();nodes+=1;guard depth<=32,nodes<=100000 else {throw bad()};space();guard offset<bytes.count else {throw bad()}
        if bytes[offset]==34 {return .string(try string())}
        if take(123) {
            var result=[String:LJSON]();if take(125) {return .object(result)}
            repeat {
                let key=try string()
                // All supported API field names are ASCII. Refuse unknown
                // Unicode keys before Swift canonical equality could merge them.
                guard key.utf8.count<=64,key.utf8.allSatisfy({$0<128}),result[key]==nil,take(58),result.count<32 else {throw bad()}
                result[key]=try value(depth+1)
                if take(125) {return .object(result)}
            } while take(44)
            throw bad()
        }
        if take(91) {
            var result=[LJSON]();if take(93) {return .array(result)}
            repeat {guard result.count<10000 else {throw bad()};result.append(try value(depth+1));if take(93) {return .array(result)}} while take(44)
            throw bad()
        }
        for (literal,result) in [("true",LJSON.bool(true)),("false",.bool(false)),("null",.null)] {
            let match=Array(literal.utf8)
            if bytes[offset...].starts(with:match) {offset+=match.count;return result}
        }
        let start=offset
        while offset<bytes.count,[45,43,46,48,49,50,51,52,53,54,55,56,57,69,101].contains(bytes[offset]) {offset+=1;guard offset-start<=64 else {throw bad()}}
        guard offset>start else {throw bad()}
        let token=Data(bytes[start..<offset]);_ = try JSONDecoder().decode(Double.self,from:token)
        return .number(String(decoding:token,as:UTF8.self))
    }
}

private struct LimitlessPage {
    var memories=[Memory](),ids=[String](),hasMorePages=false
    init(_ data:Data)throws {
        var reader=try LJSONReader(data);let root=try reader.read().fields(["data","meta"])
        let payload=try root.required("data").fields(["lifelogs","lifelog"])
        guard payload.count==1 else {throw LimitlessImport.invalid("use data.lifelogs or data.lifelog")}
        let entries:[LJSON]
        if let list=payload["lifelogs"] {entries=try list.array()} else {entries=[try payload.required("lifelog")]}
        guard entries.count<=1000 else {throw LimitlessImport.invalid("use at most 1000 lifelogs per file")}
        if let meta=root["meta"] {
            let page=try meta.fields(["lifelogs"]).required("lifelogs").fields(["count","nextCursor"])
            if let count=page["count"],try count.integer() != Int64(entries.count) {throw LimitlessImport.invalid("page count differs from the supplied lifelogs")}
            if let cursor=page["nextCursor"],!cursor.isNull {let value=try cursor.string();try LimitlessImport.text(value,limit:8192,metadata:true);hasMorePages=true}
        }
        var seen=Set<String>(),contentNodes=0
        for entry in entries {
            try Task.checkCancellation()
            let fields=try entry.fields(["id","title","markdown","contents","startTime","endTime","isStarred","updatedAt"])
            let externalID=try fields.required("id").string(),id=try LimitlessImport.sourceID(externalID)
            guard seen.insert(id).inserted else {throw LimitlessImport.invalid("duplicate lifelog IDs")}
            let title=try fields.required("title").string();try LimitlessImport.text(title,limit:4096)
            let startRaw=try fields.required("startTime").string(),endRaw=try fields.required("endTime").string()
            let start=try LimitlessImport.instant(startRaw),end=try LimitlessImport.instant(endRaw)
            guard end>=start else {throw LimitlessImport.invalid("lifelog ends before it starts")}
            var text="Imported Limitless API lifelog\nSource ID: \(externalID)\nStart: \(startRaw)\nEnd: \(endRaw)\n"
            let starred=try fields["isStarred"]?.boolean() ?? false
            if fields["isStarred"] != nil {text+="Source starred: \(starred)\n"}
            if let updated=fields["updatedAt"] {let raw=try updated.string();_ = try LimitlessImport.instant(raw);text+="Updated: \(raw)\n"}
            var hasContent=false
            if let markdown=fields["markdown"] {
                if markdown.isNull {text+="\nMarkdown: null\n"}
                else {let value=try markdown.string();try LimitlessImport.text(value,limit:1024*1024);text+="\nMarkdown:\n"+value+"\n";hasContent = !value.isEmpty}
            }
            if let contents=fields["contents"] {
                text+="\nStructured contents (source-reported times, offsets and speaker labels):\n"
                for node in try contents.array() {try Self.render(node,depth:0,text:&text,nodes:&contentNodes,hasContent:&hasContent)}
            }
            guard hasContent,text.utf8.count<=2*1024*1024 else {throw LimitlessImport.invalid("lifelog has no text or exceeds 2 MiB of rendered text")}
            memories.append(Memory(id:id,timestamp:start,endTimestamp:end,kind:.note,app:"Limitless import",bundleID:"ai.limitless.import",title:title,text:text,favorite:starred,tags:["import:limitless"]));ids.append(id)
        }
    }
    private static func render(_ value:LJSON,depth:Int,text:inout String,nodes:inout Int,hasContent:inout Bool)throws {
        try Task.checkCancellation();nodes+=1;guard depth<=12,nodes<=10000 else {throw LimitlessImport.invalid("too many structured content nodes or levels")}
        let fields=try value.fields(["type","content","startTime","endTime","startOffsetMs","endOffsetMs","children","speakerName","speakerIdentifier"])
        let type=try fields.required("type").string(),content=try fields.required("content").string()
        try LimitlessImport.text(type,limit:128,metadata:true);try LimitlessImport.text(content,limit:1024*1024)
        let indent=String(repeating:"  ",count:depth);text+=indent+"["+type+"]\n"
        for name in ["speakerName","speakerIdentifier"] {if let field=fields[name] {if field.isNull {text+=indent+name+": null\n"} else {let raw=try field.string();try LimitlessImport.text(raw,limit:4096);text+=indent+name+": "+raw+"\n"}}}
        var times=[String:Date](),offsets=[String:Int64]()
        for name in ["startTime","endTime"] {if let field=fields[name] {let raw=try field.string();times[name]=try LimitlessImport.instant(raw);text+=indent+name+": "+raw+"\n"}}
        for name in ["startOffsetMs","endOffsetMs"] {if let field=fields[name] {let raw=try field.integer();offsets[name]=raw;text+=indent+name+": \(raw)\n"}}
        if let start=times["startTime"],let end=times["endTime"],end<start {throw LimitlessImport.invalid("content node ends before it starts")}
        if let start=offsets["startOffsetMs"],let end=offsets["endOffsetMs"],end<start {throw LimitlessImport.invalid("content offsets are reversed")}
        text+=indent+"Content:\n"+content+"\n";hasContent = hasContent || !content.isEmpty
        guard text.utf8.count<=2*1024*1024 else {throw LimitlessImport.invalid("rendered lifelog exceeds 2 MiB")}
        if let children=fields["children"] {for child in try children.array() {try render(child,depth:depth+1,text:&text,nodes:&nodes,hasContent:&hasContent)}}
    }
}

public extension MemoryStore {
    func importLimitlessAPI(from url:URL,embedder:LocalEmbedder?=nil,policy:PrivacyPolicy=PrivacyPolicy(),settingsSnapshot:LibrarySettingsSnapshot?=nil,admission:MediaAdmissionLease?=nil)throws->LimitlessImportResult {
        return try withImportActivity(admission) {activity in
            try validateImportSettings(policy:policy,snapshot:settingsSnapshot)
            return try importLimitlessAPI(data:LibraryImportFile.read(url,maximumBytes:LimitlessImport.maximumBytes),embedder:embedder,policy:policy,settingsSnapshot:settingsSnapshot,admission:activity)
        }
    }
    func importLimitlessAPI(data:Data,embedder:LocalEmbedder?=nil,policy:PrivacyPolicy=PrivacyPolicy(),settingsSnapshot:LibrarySettingsSnapshot?=nil,admission:MediaAdmissionLease?=nil)throws->LimitlessImportResult {
        return try withImportActivity(admission) {activity in
            try validateImportSettings(policy:policy,snapshot:settingsSnapshot)
            try Task.checkCancellation();let page=try LimitlessPage(data)
            let result=try importDecodedMemoriesDetailed(page.memories,embedder:embedder,policy:policy,collectorAdmission:true,settingsSnapshot:settingsSnapshot,admission:activity)
            return .init(requested:page.memories.count,imported:result.imported,excluded:result.excluded,hasMorePages:page.hasMorePages,sourceIDs:page.ids)
        }
    }
    func importLimitlessAPI(from url:URL,embedder:LocalEmbedder?=nil,policy:PrivacyPolicy=PrivacyPolicy(),settingsSnapshot:LibrarySettingsSnapshot?=nil,admission:MediaAdmissionLease?=nil,scanner:PIIImportScanner) async throws -> LimitlessImportResult {
        let reservation=try reserveImportActivity(admission);defer {if reservation.owned {reservation.lease.release()}}
        try validateImportSettings(policy:policy,snapshot:settingsSnapshot)
        return try await importLimitlessAPI(data:LibraryImportFile.read(url,maximumBytes:LimitlessImport.maximumBytes),embedder:embedder,policy:policy,settingsSnapshot:settingsSnapshot,admission:reservation.lease,scanner:scanner)
    }
    func importLimitlessAPI(data:Data,embedder:LocalEmbedder?=nil,policy:PrivacyPolicy=PrivacyPolicy(),settingsSnapshot:LibrarySettingsSnapshot?=nil,admission:MediaAdmissionLease?=nil,scanner:PIIImportScanner) async throws -> LimitlessImportResult {
        let reservation=try reserveImportActivity(admission);defer {if reservation.owned {reservation.lease.release()}}
        try validateImportSettings(policy:policy,snapshot:settingsSnapshot)
        try Task.checkCancellation();let page=try LimitlessPage(data)
        let result=try await importDecodedMemoriesWithPII(page.memories,embedder:embedder,policy:policy,collectorAdmission:true,settingsSnapshot:settingsSnapshot,admission:reservation.lease,scanner:scanner)
        return .init(learnedPrivacy:result.learnedPrivacy,requested:page.memories.count,imported:result.imported,excluded:result.excluded,hasMorePages:page.hasMorePages,sourceIDs:page.ids)
    }

}
