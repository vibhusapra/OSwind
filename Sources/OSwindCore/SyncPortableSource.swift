import Foundation
import CryptoKit

/// Metadata only. Asset bytes are separately authenticated and verified before
/// admission; this manifest contains no filename, URL, bookmark or local path.
enum SyncMediaRole:String,Codable,CaseIterable,Sendable {case image,audio,video}
struct SyncMediaManifest:Codable,Equatable,Sendable {
    static let chunkBytes=8*1024*1024,maximumChunks=4096
    let role:SyncMediaRole
    let sha256:String
    let bytes:Int64
    let chunks:[SyncContentReference]
    func validate()throws {
        try SyncProtocolLimits.digest(sha256)
        guard (1...Self.maximumChunks).contains(chunks.count),bytes>0,bytes<=Int64(Self.chunkBytes)*Int64(Self.maximumChunks) else {throw OSwindError.invalid("Invalid sync asset size")}
        var total:Int64=0
        for (index,chunk) in chunks.enumerated() {
            try SyncProtocolLimits.digest(chunk.sha256)
            guard chunk.bytes>0,chunk.bytes<=Self.chunkBytes,index==chunks.count-1 || chunk.bytes==Self.chunkBytes else {throw OSwindError.invalid("Invalid sync asset chunk layout")}
            total+=chunk.bytes
        }
        guard total==bytes else {throw OSwindError.invalid("Sync asset chunks differ from declared size")}
    }
    /// At most one chunk is retained by this verifier. A caller still needs
    /// scoped, no-follow staging and current-policy/epoch checks around adoption.
    func verify(read:(SyncContentReference)throws->Data)throws {
        try validate();var hash=SHA256()
        for reference in chunks {
            try Task.checkCancellation();let data=try read(reference)
            guard reference.matches(data) else {throw OSwindError.invalid("Sync asset chunk differs")};hash.update(data:data)
        }
        guard hash.finalize().map({String(format:"%02x",$0)}).joined()==sha256 else {throw OSwindError.invalid("Sync complete asset digest differs")}
    }
}
struct SyncVersionReference:Codable,Equatable,Sendable {
    let identity:SyncObjectIdentity
    let content:SyncContentReference
    func validate(_ table:SyncCanonicalTable)throws {
        guard identity.table==table else {throw OSwindError.invalid("Sync reference table differs")}
        _=try identity.key;_ = try SyncContentReference(sha256:content.sha256,bytes:content.bytes)
        guard content.bytes>0 else {throw OSwindError.invalid("Empty sync record reference")}
    }
}
struct SyncSessionToken:Codable,Equatable,Sendable {
    let origin:String
    let digest:String
    init(origin:String,localID:String)throws {
        try SyncProtocolLimits.uuid(origin);try SyncWireCheck.text(localID,bytes:4096,empty:false)
        self.origin=origin;self.digest=SyncProtocolLimits.hex(try SyncRowSnapshot([.text(Data(origin.utf8)),.text(Data(localID.utf8))]).encoded())
    }
    func validate()throws {try SyncProtocolLimits.uuid(origin);try SyncProtocolLimits.digest(digest)}
    var localProjection:String {"sync-"+origin+"-"+digest}
}
struct SyncRecapLink:Codable,Equatable,Sendable {
    let source:SyncVersionReference
    let score:Double
    let match:String
    let passage:PassageRange?
    func validate()throws {try source.validate(.source);try SyncWireCheck.citation(score:score,match:match,passage:passage)}
}
struct SyncRecapBody:Codable,Equatable,Sendable {
    let provider:String
    let sources:[SyncRecapLink]
    func validate()throws {
        try SyncWireCheck.text(provider,bytes:128,empty:false,nul:false)
        guard (1...60).contains(sources.count) else {throw OSwindError.invalid("Invalid sync recap source count")}
        for source in sources {try source.validate();try SyncWireCheck.text(source.match,bytes:128)}
    }
}
struct SyncSourceBody:Codable,Equatable,Sendable {
    let timestamp:Date
    let endTimestamp:Date?
    let textObservation:TextObservationSpan?
    let kind:MemoryKind
    let app:String,bundleID:String,title:String
    let url:String?
    let text:String
    let visualRecording:VisualRecording?
    let transcript:SpeechTranscript?
    let audioSession:SyncSessionToken?
    let display:String?
    let regions:[TextRegion]
    let favorite:Bool
    let tags:[String]
    let recap:SyncRecapBody?
    let media:[SyncMediaManifest]

    /// Preparation must supply every retained asset; never silently drop media.
    /// resolve receives the recorded evidence revision, not just a local ID.
    init(memory:Memory,origin:String,media:[SyncMediaManifest],sessionBinding:SyncSessionToken?=nil,historical:((RecapSource)throws->SyncVersionReference)?=nil,resolve:(String,String)throws->SyncVersionReference)throws {
        guard memory.searchPreview==nil,memory.originalEvidence==nil else {throw OSwindError.invalid("Use a canonical complete source before sync preparation")}
        let roles:Set<SyncMediaRole>=Set([(memory.imagePath == nil ? nil:SyncMediaRole.image),(memory.audioPath == nil ? nil:SyncMediaRole.audio),(memory.videoPath == nil ? nil:SyncMediaRole.video)].compactMap {$0})
        guard roles==Set(media.map(\.role)),media.count==roles.count else {throw OSwindError.invalid("Prepare every source media asset exactly once")}
        timestamp=memory.timestamp;endTimestamp=memory.endTimestamp;textObservation=memory.textObservation;kind=memory.kind
        app=memory.app;bundleID=memory.bundleID;title=memory.title;url=memory.url;text=memory.text;visualRecording=memory.visualRecording
        var speech=memory.transcript
        if speech != nil {
            speech!.model=SyncWireCheck.provenance(speech!.model)
            if let info=speech!.diarization {speech!.diarization?.model=SyncWireCheck.provenance(info.model)}
        }
        transcript=speech
        if let sessionBinding {
            try sessionBinding.validate()
            guard memory.audioSessionID.map({Data($0.utf8)})==Data(sessionBinding.localProjection.utf8) else {throw OSwindError.invalid("Sync audio session projection/binding differs")}
            audioSession=sessionBinding
        } else {audioSession=try memory.audioSessionID.map {try SyncSessionToken(origin:origin,localID:$0)}}
        display=memory.display;regions=memory.regions;favorite=memory.favorite;tags=memory.tags;self.media=media.sorted {$0.role.rawValue<$1.role.rawValue}
        recap=try memory.recap.map {value in
            _=try value.validated()
            return SyncRecapBody(provider:value.provider,sources:try value.sources.map {source in
                let reference:SyncVersionReference
                if source.historicalHandle != nil {guard let historical else {throw OSwindError.unavailable("Historical recap version resolver is required")};reference=try historical(source)}
                else {reference=try resolve(source.id,source.revision)}
                return .init(source:reference,score:source.score,match:source.match,passage:source.passage)
            })
        }
        try validate()
    }
    func validate()throws {
        try SyncWireCheck.date(timestamp);if let endTimestamp {try SyncWireCheck.date(endTimestamp);guard endTimestamp>=timestamp else {throw OSwindError.invalid("Sync source end precedes start")}}
        guard text.count<=1_000_000,regions.count<=100_000,tags.count<=100_000,media.count<=3,Set(media.map(\.role)).count==media.count,media.map({$0.role.rawValue})==media.map({$0.role.rawValue}).sorted() else {throw OSwindError.invalid("Invalid sync source size")}
        for s in [app,bundleID,title,url,display].compactMap({$0}) {try SyncWireCheck.text(s,bytes:4*1024*1024)}
        for tag in tags {try SyncWireCheck.text(tag,bytes:4096)}
        for r in regions {try SyncWireCheck.region(r)}
        for asset in media {try asset.validate()}
        if let transcript {
            _=try transcript.validated()
            guard kind == .audio,Data(text.utf8)==Data(transcript.text.utf8),transcript.model==SyncWireCheck.provenance(transcript.model),transcript.diarization.map({$0.model==SyncWireCheck.provenance($0.model)}) ?? true else {throw OSwindError.invalid("Invalid sync transcript content or provenance")}
        }
        if let visualRecording {_=try visualRecording.validated();guard kind == .screen,Data(text.utf8)==Data(visualRecording.text.utf8) else {throw OSwindError.invalid("Sync visual metadata differs from source")}}
        guard !media.contains(where:{$0.role == .video}) || visualRecording != nil else {throw OSwindError.invalid("Sync video needs frame metadata")}
        try audioSession?.validate();try recap?.validate()
        if recap != nil {guard kind == .summary,media.isEmpty,transcript==nil,visualRecording==nil,textObservation==nil else {throw OSwindError.invalid("Invalid sync recap source")}}
        if let textObservation {
            guard media.isEmpty else {throw OSwindError.invalid("Sampled text cannot carry media")}
            var memory=Memory(id:"validation",timestamp:timestamp,endTimestamp:endTimestamp,kind:kind,app:app,bundleID:bundleID,title:title,url:url,text:text,display:display,regions:regions)
            memory.textObservation=textObservation;memory.transcript=transcript;memory.visualRecording=visualRecording;memory.audioSessionID=audioSession?.localProjection;memory.recap=recap.map {_ in RecapProvenance(provider:"validation",sources:[])}
            try textObservation.validated(for:memory)
        }
    }
    /// Resolve immutable versions and already-admitted local media explicitly.
    /// This returns data only: the caller must validate privacy, live identity,
    /// source-version bindings and epoch inside its eventual writer transaction.
    func projectedMemory(id:String,paths:[SyncMediaRole:String],resolve:(SyncVersionReference)throws->(id:String,evidenceHash:String))throws->Memory {
        try validate();guard Set(paths.keys)==Set(media.map(\.role)) else {throw OSwindError.invalid("Admitted sync media set differs")}
        var memory=Memory(id:id,timestamp:timestamp,endTimestamp:endTimestamp,kind:kind,app:app,bundleID:bundleID,title:title,url:url,text:text,imagePath:paths[.image],audioPath:paths[.audio],display:display,regions:regions,favorite:favorite,tags:tags)
        memory.videoPath=paths[.video];memory.visualRecording=visualRecording;memory.transcript=transcript;memory.audioSessionID=audioSession?.localProjection;memory.textObservation=textObservation
        if let recap {memory.recap=RecapProvenance(provider:recap.provider,sources:try recap.sources.map {link in
            let local=try resolve(link.source)
            return RecapSource(id:local.id,revision:local.evidenceHash,match:link.match,score:link.score,passage:link.passage)
        })}
        return memory
    }
}
