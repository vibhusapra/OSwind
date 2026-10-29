import Foundation
import CryptoKit

/// Explicit, prospective import protection. The threshold is experimental;
/// neither model output nor a successful import establishes absence of PII.
public struct PIIImportConfiguration:Codable,Equatable,Sendable {
    public var enabled=false
    public var compute:PIIComputePolicy = .coreML
    public var threshold:Double=0.5
    public var cacheRoot:String=""
    public init() {}
    public func scanner() async throws -> PIIImportScanner {
        guard threshold.isFinite,threshold>0,threshold<1 else {throw OSwindError.invalid("PII threshold must be strictly between zero and one")}
        let installation=try await PIIModelPreparation.verify(cache:cacheRoot.isEmpty ? nil:URL(fileURLWithPath:cacheRoot,isDirectory:true))
        try Task.checkCancellation()
        return try PIIImportScanner(installation:installation,compute:compute,threshold:threshold)
    }
    /// Callers join teardown before releasing their import/library reservation.
    public func withScanner<T>(_ body:(PIIImportScanner) async throws -> T) async throws -> T {
        let scanner=try await scanner()
        do {let value=try await body(scanner);await scanner.shutdown();return value}
        catch {await scanner.shutdown();throw error}
    }

}
public struct PIIImportSummary:Codable,Sendable {
    public let modelID:String,compute:PIIComputePolicy,threshold:Double
    public var sources=0,redactedSources=0,fields=0,windows=0
}

public actor PIIImportScanner {
    public nonisolated let modelID:String,compute:PIIComputePolicy,threshold:Double
    private let inspector:PIIInspector
    private var closed=false
    public init(installation:PIIModelInstallation,compute:PIIComputePolicy,threshold:Double) throws {
        guard threshold.isFinite,threshold>0,threshold<1 else {throw OSwindError.invalid("PII threshold must be strictly between zero and one")}
        self.compute=compute;self.threshold=threshold;modelID=PIIInspector.expectedModelID(compute)
        inspector=PIIInspector(modelDirectory:installation.modelDirectory,runtimeLibrary:installation.runtimeLibrary,compute:compute)
    }
    init(inspector:PIIInspector,compute:PIIComputePolicy = .cpu,threshold:Double=0.5) {
        self.inspector=inspector;self.compute=compute;self.threshold=threshold;modelID=PIIInspector.expectedModelID(compute)
    }
    public func shutdown() async {closed=true;await inspector.shutdown()}
    struct Result:Sendable {let memory:Memory,redacted:Bool,fields:Int,windows:Int,framedTokens:Int,checkedAt:Date}
    func sanitize(_ original:Memory,policy:PrivacyPolicy) async throws -> Result {
        guard !closed else {throw OSwindError.unavailable("PII import scanner is shut down")}
        var document=try ImportPIIDocument(original)
        let result=try await inspector.inspect(document.source,threshold:threshold)
        try Task.checkCancellation();guard !closed else {throw CancellationError()}
        let masks=try Self.validatedMasks(result,source:document.source,compute:compute,threshold:threshold)
        let memory=try document.apply(masks,learned:result.modelMasks.map {NSRange(location:$0.startUTF16,length:$0.lengthUTF16)})
        return .init(memory:memory,redacted:document.redacted,fields:document.fields.count,windows:result.windowCount,framedTokens:result.framedTokens,checkedAt:Date())
    }
    /// Independently bind the service response to the exact original bytes and
    /// reconstruct its masks. Never trust rendered output or offsets blindly.
    static func validatedMasks(_ result:PIIInspection,source:String,compute:PIIComputePolicy,threshold:Double) throws -> [NSRange] {
        let document=try PIIDocument(source)
        guard result.sourceSHA256==document.sha256,result.modelID==PIIInspector.expectedModelID(compute),result.compute==compute,
              result.threshold==threshold,result.windowCount>0,result.windowCount<=PIIDocument.maximumWindows,
              result.framedTokens>0,result.framedTokens<=PIIDocument.maximumFramedTokens,result.spans.count<=PIIDocument.maximumSpans else {throw OSwindError.invalid("PII import result has a mismatched source or model contract")}
        let length=source.utf16.count
        var scalarBoundaries:Set<Int>=[0],offset=0
        for scalar in source.unicodeScalars {offset += scalar.value>0xffff ? 2:1;scalarBoundaries.insert(offset)}
        for span in result.spans {
            guard span.confidence.isFinite,span.confidence>=Float(threshold),span.confidence<=1,PIITokenizer.labels.contains(span.label),
                  span.startUTF16>=0,span.lengthUTF16>0,span.startUTF16<=length,span.lengthUTF16<=length-span.startUTF16,
                  scalarBoundaries.contains(span.startUTF16),scalarBoundaries.contains(span.startUTF16+span.lengthUTF16) else {throw OSwindError.invalid("PII import result has an invalid span")}
        }
        let learned=try PIIDecoding.mask(source,ranges:result.spans.map {NSRange(location:$0.startUTF16,length:$0.lengthUTF16)})
        let patterns=PrivacyPolicy().sensitiveRanges(in:source)
        let final=try PIIDecoding.mask(source,ranges:learned.ranges+patterns)
        func equal(_ left:[PIIInspection.Mask],_ right:[NSRange])->Bool {left.count==right.count && zip(left,right).allSatisfy {$0.startUTF16==$1.location && $0.lengthUTF16==$1.length}}
        guard equal(result.modelMasks,learned.ranges),equal(result.masks,final.ranges),Data(result.text.utf8)==Data(final.text.utf8),
              result.modelRedacted==learned.redacted,result.patternRedacted == !patterns.isEmpty,result.redacted==final.redacted,result.suppressMedia==final.redacted else {throw OSwindError.invalid("PII import result masks or rendered text do not match its spans")}
        return final.ranges
    }
}

/// Visit typed Memory string leaves, not JSON escape sequences. Non-string
/// values and structural enums round-trip through Codable. Every new string
/// property is scanned unless explicitly identified as a validated enum/opaque ID.
private indirect enum ImportPIIValue:Codable {
    case object([String:Self]),array([Self]),string(String),number(Double),bool(Bool),null
    init(from decoder:Decoder)throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil() {self = .null}
        else if let v=try? c.decode(String.self) {self = .string(v)}
        else if let v=try? c.decode(Bool.self) {self = .bool(v)}
        else if let v=try? c.decode(Double.self) {self = .number(v)}
        else if let v=try? c.decode([String:Self].self) {self = .object(v)}
        else {self = .array(try c.decode([Self].self))}
    }
    func encode(to encoder:Encoder)throws {
        var c=encoder.singleValueContainer()
        switch self {
        case .object(let v):try c.encode(v)
        case .array(let v):try c.encode(v)
        case .string(let v):try c.encode(v)
        case .number(let v):try c.encode(v)
        case .bool(let v):try c.encode(v)
        case .null:try c.encodeNil()
        }
    }
    func strings(_ visit:([String],String)throws->Void,path:[String]=[])throws {
        try Task.checkCancellation()
        switch self {
        case .object(let fields):for key in fields.keys.sorted() {try fields[key]!.strings(visit,path:path+[key])}
        case .array(let fields):for (index,value) in fields.enumerated() {try value.strings(visit,path:path+[String(index)])}
        case .string(let value):try visit(path,value)
        default:break
        }
    }
    func replacing(_ replacements:[[String]:String],path:[String]=[]) -> Self {
        switch self {
        case .object(let fields):return .object(fields.mapValuesWithKey {key,value in value.replacing(replacements,path:path+[key])})
        case .array(let fields):return .array(fields.enumerated().map {$1.replacing(replacements,path:path+[String($0)])})
        case .string(let value):return .string(replacements[path] ?? value)
        default:return self
        }
    }
}
private extension Dictionary where Key==String,Value==ImportPIIValue {
    func mapValuesWithKey(_ body:(String,Value)->Value)->[String:Value] {Dictionary(uniqueKeysWithValues:map {($0.key,body($0.key,$0.value))})}
}
private struct ImportPIIDocument {
    struct Field {let path:[String],value:String,range:NSRange,identity:Bool}
    let original:Memory,tree:ImportPIIValue
    var fields=[Field](),source="",redacted=false
    init(_ original:Memory)throws {
        guard original.searchPreview==nil else {throw OSwindError.invalid("A search preview cannot be imported as a complete source")}
        guard original.text.utf8.count<=PIIDocument.maximumBytes else {throw OSwindError.invalid("Experimental PII import main text exceeds 128 KiB")}
        if let transcript=original.transcript {
            _ = try transcript.validated();guard Data(original.text.utf8)==Data(transcript.text.utf8),original.visualRecording==nil else {throw OSwindError.invalid("Imported transcript and source differ")}
        }
        if let visual=original.visualRecording {_ = try visual.validated();guard Data(original.text.utf8)==Data(visual.text.utf8) else {throw OSwindError.invalid("Imported visual recording and source differ")}}
        self.original=original
        var stripped=original;stripped.embedding=nil;stripped.embeddingModel=nil;stripped.imagePath=nil;stripped.audioPath=nil;stripped.videoPath=nil;stripped.regions=[]
        // Input is already bounded by its import reader; add a smaller explicit
        // per-source experimental budget. Refuse rather than truncate fields.
        let data=try JSONEncoder().encode(stripped)
        guard data.count<=512*1024 else {throw OSwindError.invalid("Experimental PII import source exceeds 512 KiB of typed JSON")}
        tree=try JSONDecoder().decode(ImportPIIValue.self,from:data)
        var collected=[Field](),framed=""
        try tree.strings {path,value in
            if path==["kind"] || path==["visualRecording","codec"] || path==["transcript","diarization","scope"] {return}
            let identity=path==["id"] || path==["bundleID"] || path==["audioSessionID"] || (path.count==4 && path[0]=="recap" && path[1]=="sources" && ["id","revision"].contains(path[3]))
            if value.isEmpty {return}
            if identity,Self.opaque(value) {return}
            guard collected.count<4096 else {throw OSwindError.invalid("Experimental PII import field budget exceeded")}
            // Keys are fixed typed property names or array ordinals; user values
            // are never interpreted as framing or decoded as JSON again.
            framed+="\n\n"+path.joined(separator:".")+":\n"
            let range=NSRange(location:framed.utf16.count,length:value.utf16.count)
            framed+=value
            guard framed.utf8.count<=PIIDocument.maximumBytes else {throw OSwindError.invalid("Experimental PII import framed source exceeds 128 KiB")}
            collected.append(.init(path:path,value:value,range:range,identity:identity))
        }
        _ = try PIIDocument(framed);fields=collected;source=framed
    }
    private static func opaque(_ value:String)->Bool {
        func hex(_ v:Substring)->Bool {v.count==64 && v.utf8.allSatisfy {(48...57).contains($0)||(97...102).contains($0)}}
        if UUID(uuidString:value) != nil {return true}
        if hex(Substring(value)) {return true}
        if value.hasPrefix("limitless:"),hex(value.dropFirst(10)) {return true}
        let parts=value.split(separator:":",omittingEmptySubsequences:false)
        return parts.count==3 && parts[0]=="collector" && (try? TextCollector.identity(String(parts[1]))) != nil && hex(parts[2])
    }
    mutating func apply(_ masks:[NSRange],learned:[NSRange])throws -> Memory {
        guard fields.count*(masks.count+learned.count)<=1_000_000 else {throw OSwindError.invalid("Experimental PII import mask work budget exceeded")}
        var local=[[NSRange]](repeating:[],count:fields.count),fragments=[Data:String]()
        for (index,field) in fields.enumerated() {
            try Task.checkCancellation()
            for mask in masks+learned {
                let overlap=NSIntersectionRange(mask,field.range)
                if overlap.length>0 {
                    let localMask=NSRange(location:overlap.location-field.range.location,length:overlap.length)
                    local[index].append(localMask)
                    // Keep learned subspans as propagation seeds even when a
                    // larger pattern mask overlaps them and masks their trigger.
                    let seed=try PIIDecoding.mask(field.value,ranges:[localMask])
                    for range in seed.ranges {
                        let fragment=(field.value as NSString).substring(with:range)
                        fragments[Data(fragment.utf8)]=fragment
                        guard fragments.count<=256 else {throw OSwindError.invalid("Experimental PII import duplicate-value budget exceeded")}
                    }
                }
            }
            local[index]=try PIIDecoding.mask(field.value,ranges:local[index]).ranges
        }
        guard fragments.count<=256 else {throw OSwindError.invalid("Experimental PII import duplicate-value budget exceeded")}
        // Exact UTF-8 fragment keys and literal NSString matching preserve
        // decomposed characters and prevent normalization/offset substitution.
        var matches=0
        for (index,field) in fields.enumerated() {
            try Task.checkCancellation()
            let text=field.value as NSString
            for fragment in fragments.values {
                var start=0
                while start<text.length {
                    let range=text.range(of:fragment,options:.literal,range:NSRange(location:start,length:text.length-start))
                    if range.location==NSNotFound {break}
                    matches+=1;guard matches<=PIIDocument.maximumSpans else {throw OSwindError.invalid("Experimental PII import duplicate-match budget exceeded")}
                    local[index].append(range);start=NSMaxRange(range)
                }
            }
        }
        // Joined OCR can contain a secret spanning frame boundaries. Project
        // original main-source masks before any replacement changes offsets.
        if let visual=original.visualRecording,let main=fields.firstIndex(where:{$0.path==["text"]}) {
            for (index,entry) in visual.ranges().enumerated() {
                guard let target=fields.firstIndex(where:{$0.path==["visualRecording","frames",String(index),"text"]}) else {continue}
                for mask in local[main] {
                    let overlap=NSIntersectionRange(mask,NSRange(location:entry.range.start,length:entry.range.length))
                    if overlap.length>0 {local[target].append(NSRange(location:overlap.location-entry.range.start,length:overlap.length))}
                }
            }
        }
        var replacements=[[String]:String](),changedPaths=Set<[String]>()
        for (index,field) in fields.enumerated() {
            let clean=try PIIDecoding.mask(field.value,ranges:local[index])
            if clean.redacted {
                guard !field.identity else {throw OSwindError.invalid("PII was detected in an immutable source identity; no records imported")}
                replacements[field.path]=clean.text;changedPaths.insert(field.path)
            }
        }
        var memory=try JSONDecoder().decode(Memory.self,from:JSONEncoder().encode(tree.replacing(replacements)))
        if var visual=memory.visualRecording {
            for index in visual.frames.indices where changedPaths.contains(where:{$0.starts(with:["visualRecording","frames",String(index)])}) {visual.frames[index].regions=[]}
            memory.visualRecording=try visual.validated();memory.text=visual.text
        }
        if var transcript=memory.transcript,let before=original.transcript {
            // Keep original-source spoken/split-pattern detection even when a
            // learned mask hides its trigger. Extra protection always unions the
            // standard patterns, independently of the regular pattern toggle.
            let prior=try before.sanitized(policy:PrivacyPolicy())
            if prior.transcript.text=="[REDACTED SENSITIVE SPEECH]" {transcript.text=prior.transcript.text}
            if prior.suppressAudio || changedPaths.contains(["text"]) || changedPaths.contains(where:{$0.first=="transcript"}) {
                for index in transcript.segments.indices {transcript.segments[index].text="[REDACTED]"}
            }
            memory.transcript=try transcript.validated();memory.text=transcript.text
            redacted=prior.suppressAudio
        }
        redacted = redacted || !changedPaths.isEmpty
        if let recap=memory.recap {_ = try recap.validated()}
        try Task.checkCancellation();return memory
    }
}
