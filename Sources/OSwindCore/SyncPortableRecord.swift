import Foundation

/// These records carry data, never local execution authority. Decode canonical
/// bytes, authenticate their content reference, then perform dependency/privacy/
/// epoch admission before any writer consumes them. Not installed by MemoryStore.
enum SyncWireCheck {
    static func text(_ value:String,bytes:Int,empty:Bool=true,nul:Bool=true)throws {
        guard value.utf8.count<=bytes,empty || !value.isEmpty,nul || !value.utf8.contains(0) else {throw OSwindError.invalid("Invalid sync text field")}
    }
    static func date(_ value:Date)throws {guard value.timeIntervalSinceReferenceDate.isFinite else {throw OSwindError.invalid("Invalid sync date")}}
    static func identity(_ value:SyncObjectIdentity,_ table:SyncCanonicalTable)throws {guard value.table==table else {throw OSwindError.invalid("Sync dependency table differs")};_=try value.key}
    static func passage(_ value:PassageRange?)throws {
        if let value {guard value.start>=0,value.length>0,value.start<=Int(SyncProtocolLimits.contentBytes),value.length<=Int(SyncProtocolLimits.contentBytes)-value.start else {throw OSwindError.invalid("Invalid sync passage range")}}
    }
    static func citation(score:Double,match:String,passage:PassageRange?)throws {
        guard score.isFinite,abs(score)<=1_000_000 else {throw OSwindError.invalid("Invalid sync citation score")}
        try text(match,bytes:4096);try self.passage(passage)
    }
    static func region(_ r:TextRegion)throws {
        guard [r.x,r.y,r.width,r.height].allSatisfy(\.isFinite),r.x>=0,r.y>=0,r.width>=0,r.height>=0,r.x+r.width<=1.000001,r.y+r.height<=1.000001,r.text.count<=100_000 else {throw OSwindError.invalid("Invalid sync text region")}
    }
    /// A label is attribution only, not an executable model locator. Absolute
    /// paths, file URLs, tilde paths and traversal components stay device-local.
    static func provenance(_ value:String)->String {
        let unsafe=value.hasPrefix("/") || value.hasPrefix("~") || value.lowercased().hasPrefix("file:") || value.split(separator:"/").contains("..")
        return unsafe ? "peer-unspecified":value
    }
    static func label(_ value:String)throws {let clean=try EntityLabel.clean(value);guard Data(clean.utf8)==Data(value.utf8) else {throw OSwindError.invalid("Noncanonical sync entity label")}}
    static func entityKey(_ value:String)throws {try text(value,bytes:1024,empty:false,nul:false);guard Data(EntityLabel.key(value).utf8)==Data(value.utf8) else {throw OSwindError.invalid("Noncanonical sync entity key")}}
}
struct SyncFilterBody:Codable,Equatable,Sendable {
    let query:String
    let app:String?
    let kind:MemoryKind?
    let start:Date?,end:Date?
    let sourceStartsOnly:Bool?
    let favoritesOnly:Bool
    let tag:String?,speaker:String?
    let entity:SyncObjectIdentity?
    let limit:Int
    init(_ filter:SearchFilter,resolve:(String)throws->SyncObjectIdentity)throws {
        query=filter.query;app=filter.app;kind=filter.kind;start=filter.start;end=filter.end;sourceStartsOnly=filter.sourceStartsOnly;favoritesOnly=filter.favoritesOnly;tag=filter.tag;speaker=filter.speaker;limit=filter.limit
        entity=try filter.entityID.map(resolve);try validate()
    }
    func validate()throws {
        try SyncWireCheck.text(query,bytes:32768)
        for s in [app,tag,speaker].compactMap({$0}) {try SyncWireCheck.text(s,bytes:4096,nul:false)}
        if let start {try SyncWireCheck.date(start)};if let end {try SyncWireCheck.date(end)}
        guard (1...10000).contains(limit),start==nil || end==nil || start!<=end! else {throw OSwindError.invalid("Invalid sync query bounds")}
        if let entity {try SyncWireCheck.identity(entity,.entity)}
    }
    func projected(resolve:(SyncObjectIdentity)throws->String)throws->SearchFilter {
        try validate();return SearchFilter(query:query,app:app,kind:kind,start:start,end:end,favoritesOnly:favoritesOnly,tag:tag,speaker:speaker,entityID:try entity.map(resolve),limit:limit,sourceStartsOnly:sourceStartsOnly)
    }
}
struct SyncConversationBody:Codable,Equatable,Sendable {
    let title:String
    let created:Date,updated:Date
    func validate()throws {try SyncWireCheck.text(title,bytes:65536);try SyncWireCheck.date(created);try SyncWireCheck.date(updated)}
}
struct SyncTurnBody:Codable,Equatable,Sendable {
    let conversation:SyncObjectIdentity
    let timestamp:Date
    let question:String,text:String,provider:String
    let duration:Double
    let warnings:[String]
    let filter:SyncFilterBody
    let timeZone:String?
    func validate()throws {
        try SyncWireCheck.identity(conversation,.conversation);try SyncWireCheck.date(timestamp)
        guard !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,question.count<=8000,text.count<=100000,duration.isFinite,duration>=0,warnings.count<=1000 else {throw OSwindError.invalid("Invalid sync turn")}
        try SyncWireCheck.text(provider,bytes:4096);for warning in warnings {try SyncWireCheck.text(warning,bytes:32768)}
        if let timeZone {try SyncWireCheck.text(timeZone,bytes:1024,empty:false,nul:false);guard TimeZone(identifier:timeZone) != nil else {throw OSwindError.invalid("Invalid sync conversation time zone")}}
        try filter.validate()
    }
}
struct SyncCitationBody:Codable,Equatable,Sendable {
    let owner:SyncObjectIdentity
    let ordinal:Int
    let link:SyncRecapLink
    func validate(recap:Bool)throws {try SyncWireCheck.identity(owner,recap ? .source:.turn);guard (0..<60).contains(ordinal) else {throw OSwindError.invalid("Invalid sync citation ordinal")};try link.validate()}
}
struct SyncRoutineBody:Codable,Equatable,Sendable {
    let title:String,prompt:String
    let schedule:RoutineSchedule
    let window:RoutineWindow
    let app:String?,kind:MemoryKind?,tag:String?
    init(_ value:RoutineDefinition)throws {
        title=value.title;prompt=value.prompt;schedule=try value.schedule.validated();window=value.window;app=value.app;kind=value.kind;tag=value.tag;try validate()
    }
    func validate()throws {
        try SyncWireCheck.text(title,bytes:160,empty:false,nul:false);try SyncWireCheck.text(prompt,bytes:8000,empty:false)
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,try schedule.validated()==schedule else {throw OSwindError.invalid("Invalid sync recipe")}
        for s in [app,tag].compactMap({$0}) {try SyncWireCheck.text(s,bytes:300,empty:false,nul:false)}
    }
    /// A received recipe is always disabled and has only this device's default
    /// AI configuration. The wire never contains endpoints, keys or AI settings.
    func projected(id:String)throws->RoutineDefinition {
        try validate();var value=RoutineDefinition();value.id=id;value.title=title;value.prompt=prompt;value.schedule=schedule;value.window=window;value.app=app;value.kind=kind;value.tag=tag;value.enabled=false;value.allowRemote=false
        return value
    }
}
struct SyncRoutineRevision:Codable,Equatable,Sendable {
    let routine:SyncObjectIdentity
    let editorOrigin:String
    let ordinal:Int64
    /// nil explicitly means a pre-enrollment historical definition was not
    /// retained. It never means "use the current recipe as that old version".
    let definition:SyncContentReference?
    func validate()throws {try SyncWireCheck.identity(routine,.routine);try SyncProtocolLimits.uuid(editorOrigin);guard ordinal>0,definition.map({$0.bytes>0}) ?? true else {throw OSwindError.invalid("Invalid sync historical recipe revision")}}
}
struct SyncRoutineRunBody:Codable,Equatable,Sendable {
    let recipe:SyncRoutineRevision
    let scheduledAt:Date,started:Date,finished:Date?
    let trigger:RoutineTrigger
    let status:RoutineRunStatus
    let conversation:SyncObjectIdentity?
    let message:String?
    let filter:SyncFilterBody
    var projectedStatus:RoutineRunStatus {status == .running ? .interrupted:status}
    func validate()throws {
        try recipe.validate();try SyncWireCheck.date(scheduledAt);try SyncWireCheck.date(started);if let finished {try SyncWireCheck.date(finished)}
        if let conversation {try SyncWireCheck.identity(conversation,.conversation)}
        if let message {try SyncWireCheck.text(message,bytes:32768)};try filter.validate()
    }
}
struct SyncEntityBody:Codable,Equatable,Sendable {
    let kind:EntityKind
    let name:String,detail:String
    let curated:Bool
    let created:Date
    func validate()throws {try SyncWireCheck.label(name);try SyncWireCheck.text(detail,bytes:8000);try SyncWireCheck.date(created)}
}
struct SyncAliasBody:Codable,Equatable,Sendable {
    let entity:SyncObjectIdentity
    let kind:EntityKind
    let key:String,label:String
    func validate()throws {
        try SyncWireCheck.identity(entity,.entity);try SyncWireCheck.label(label);try SyncWireCheck.entityKey(key)
        guard Data(EntityLabel.key(label).utf8)==Data(key.utf8) else {throw OSwindError.invalid("Sync alias label/key differ")}
    }
}
enum SyncMentionOrigin:String,Codable,Sendable {case manual,automatic}
struct SyncMentionBody:Codable,Equatable,Sendable {
    let source:SyncVersionReference
    let entity:SyncObjectIdentity
    let origin:SyncMentionOrigin
    let passage:PassageRange?
    let surface:String,method:String
    func validate()throws {
        try source.validate(.source);try SyncWireCheck.identity(entity,.entity);try SyncWireCheck.passage(passage);try SyncWireCheck.text(surface,bytes:65536);try SyncWireCheck.text(method,bytes:1024,empty:false,nul:false)
        guard origin != .automatic || (passage != nil && !surface.isEmpty) else {throw OSwindError.invalid("Automatic sync mention needs an anchored suggestion")}
        guard passage != nil || surface.isEmpty else {throw OSwindError.invalid("Unanchored sync mention cannot claim a surface")}
    }
}
struct SyncEntityRejectionBody:Codable,Equatable,Sendable {
    let source:SyncVersionReference
    let kind:EntityKind
    let key:String
    func validate()throws {try source.validate(.source);try SyncWireCheck.entityKey(key)}
}
struct SyncProjectRejectionBody:Codable,Equatable,Sendable {
    let source:SyncVersionReference
    let entity:SyncObjectIdentity
    func validate()throws {try source.validate(.source);try SyncWireCheck.identity(entity,.entity)}
}
struct SyncEvidencePinBody:Codable,Equatable,Sendable {
    let source:SyncVersionReference
    func validate()throws {try source.validate(.source)}
}
enum SyncPortableBody:Codable,Equatable,Sendable {
    case source(SyncSourceBody),conversation(SyncConversationBody),turn(SyncTurnBody)
    case conversationCitation(SyncCitationBody),recapCitation(SyncCitationBody)
    case routine(SyncRoutineBody),routineRun(SyncRoutineRunBody),entity(SyncEntityBody),entityAlias(SyncAliasBody),entityMention(SyncMentionBody)
    case entityRejection(SyncEntityRejectionBody),projectRejection(SyncProjectRejectionBody),evidencePin(SyncEvidencePinBody)
    var table:SyncCanonicalTable {
        switch self {
        case .source:return .source;case .conversation:return .conversation;case .turn:return .turn;case .conversationCitation:return .conversationCitation;case .recapCitation:return .recapCitation;case .routine:return .routine;case .routineRun:return .routineRun;case .entity:return .entity;case .entityAlias:return .entityAlias;case .entityMention:return .entityMention;case .entityRejection:return .entityRejection;case .projectRejection:return .projectRejection;case .evidencePin:return .evidencePin
        }
    }
    func validate()throws {
        switch self {
        case .source(let v):try v.validate();case .conversation(let v):try v.validate();case .turn(let v):try v.validate();case .conversationCitation(let v):try v.validate(recap:false);case .recapCitation(let v):try v.validate(recap:true);case .routine(let v):try v.validate();case .routineRun(let v):try v.validate();case .entity(let v):try v.validate();case .entityAlias(let v):try v.validate();case .entityMention(let v):try v.validate();case .entityRejection(let v):try v.validate();case .projectRejection(let v):try v.validate();case .evidencePin(let v):try v.validate()
        }
    }
}
struct SyncPortableRecord:Codable,Equatable,Sendable {
    let format:String
    let version:Int
    let identity:SyncObjectIdentity
    let body:SyncPortableBody
    init(identity:SyncObjectIdentity,body:SyncPortableBody)throws {format="OSwind.sync.record";version=1;self.identity=identity;self.body=body;try validate()}
    func validate()throws {
        guard format=="OSwind.sync.record",version==1,identity.table==body.table else {throw OSwindError.invalid("Sync record format/table differs")}
        _=try identity.key;try body.validate()
        if case .source(let value)=body,let recap=value.recap {guard !recap.sources.contains(where:{$0.source.identity==identity}) else {throw OSwindError.invalid("Sync recap cannot cite itself")}}
    }
    func encoded()throws->Data {
        try validate();let data=try SyncProtocolLimits.encode(self)
        guard data.count<=SyncProtocolLimits.contentBytes else {throw OSwindError.invalid("Sync record exceeds its bound")};return data
    }
    static func decode(_ data:Data,expected:SyncVersionReference?=nil)throws->Self {
        guard !data.isEmpty,data.count<=SyncProtocolLimits.contentBytes,expected?.content.matches(data) ?? true else {throw OSwindError.invalid("Sync record content differs")}
        let value=try JSONDecoder().decode(Self.self,from:data);try value.validate()
        guard try value.encoded()==data,expected.map({$0.identity==value.identity}) ?? true else {throw OSwindError.invalid("Noncanonical or misidentified sync record")};return value
    }
    var reference:SyncVersionReference {get throws {try .init(identity:identity,content:.init(data:encoded()))}}
    /// Dependency lookup must return the requested immutable content version.
    /// No fallback to current source data, no local IDs or raw peer SQL.
    func validateDependencies(resolve:(SyncObjectIdentity,SyncContentReference?)throws->SyncPortableRecord)throws {
        try validate()
        func dependency(_ id:SyncObjectIdentity,_ content:SyncContentReference?=nil)throws->SyncPortableRecord {
            let record=try resolve(id,content);try record.validate()
            guard record.identity==id else {throw OSwindError.invalid("Sync dependency identity differs")}
            if let content {guard try record.reference.content==content else {throw OSwindError.invalid("Sync dependency version differs")}}
            return record
        }
        func source(_ ref:SyncVersionReference)throws->SyncSourceBody {
            guard case .source(let value)=try dependency(ref.identity,ref.content).body else {throw OSwindError.invalid("Sync source dependency differs")};return value
        }
        func link(_ value:SyncRecapLink)throws {
            let original=try source(value.source)
            guard value.passage.map({$0.text(in:original.text) != nil}) ?? true else {throw OSwindError.invalid("Sync citation passage is outside its source version")}
        }
        func filter(_ value:SyncFilterBody)throws {if let id=value.entity {_=try dependency(id)}}
        switch body {
        case .source(let value):for entry in value.recap?.sources ?? [] {try link(entry)}
        case .turn(let value):_=try dependency(value.conversation);try filter(value.filter)
        case .conversationCitation(let value):_=try dependency(value.owner);try link(value.link)
        case .recapCitation(let value):
            guard case .source(let parent)=try dependency(value.owner).body,let recap=parent.recap,value.ordinal<recap.sources.count,recap.sources[value.ordinal]==value.link else {throw OSwindError.invalid("Sync recap citation differs from its owner")};try link(value.link)
        case .routineRun(let value):_=try dependency(value.recipe.routine,value.recipe.definition);if let id=value.conversation {_=try dependency(id)};try filter(value.filter)
        case .entityAlias(let value):guard case .entity(let entity)=try dependency(value.entity).body,entity.kind==value.kind else {throw OSwindError.invalid("Sync alias entity kind differs")}
        case .entityMention(let value):
            let original=try source(value.source);_=try dependency(value.entity)
            if let range=value.passage {guard let text=range.text(in:original.text),Data(text.utf8)==Data(value.surface.utf8) else {throw OSwindError.invalid("Sync mention surface differs from its source version")}}
        case .entityRejection(let value):_=try source(value.source)
        case .projectRejection(let value):_=try source(value.source);guard case .entity(let entity)=try dependency(value.entity).body,entity.kind == .project else {throw OSwindError.invalid("Sync project rejection needs a project")}
        case .evidencePin(let value):_=try source(value.source)
        case .conversation,.routine,.entity:break
        }
    }
}
