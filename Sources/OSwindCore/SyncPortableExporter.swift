import Foundation

/// Local revision domains are deliberately distinct. Entity offsets use an
/// entityRevision; recaps use evidenceHash. Neither is a peer wire version.
enum SyncLocalSourceRevision:Equatable {case current,evidence(String),entity(String)}
struct SyncPortableReferences {
    let identity:(SyncCanonicalTable,[SyncRowCell])throws->SyncObjectIdentity
    let source:(String,SyncLocalSourceRevision)throws->SyncVersionReference
    let media:(Memory)throws->[SyncMediaManifest]
    let recipe:(String,Int64)throws->SyncRoutineRevision
    let session:(Memory)throws->SyncSessionToken?
}
/// Converts the actual captured canonical row schema, not raw SQL supplied by a
/// peer. Reference/media preparation and the writer's current-row/privacy checks
/// remain required; returning a record does not acknowledge an intent or publish.
struct SyncPortableExporter {
    let references:SyncPortableReferences
    func record(identity:SyncObjectIdentity,row:SyncRowSnapshot)throws->SyncPortableRecord {
        let table=identity.table,schema=table.schema
        guard row.cells.count==schema.columns.count else {throw OSwindError.invalid("Portable sync row width differs")}
        let primary=schema.primary.map {row.cells[schema.columns.firstIndex(of:$0)!]}
        _=try SyncIdentityCatalog.keyFrame(table,primary)
        guard try references.identity(table,primary)==identity else {throw OSwindError.invalid("Portable sync row lifetime differs")}
        let cells=Dictionary(uniqueKeysWithValues:zip(schema.columns,row.cells))
        func cell(_ name:String)throws->SyncRowCell {guard let value=cells[name] else {throw OSwindError.invalid("Portable sync column missing")};return value}
        func text(_ name:String)throws->String {guard case .text(let data)=try cell(name),let value=String(data:data,encoding:.utf8) else {throw OSwindError.invalid("Portable sync text storage differs")};return value}
        func integer(_ name:String)throws->Int64 {guard case .integer(let value)=try cell(name) else {throw OSwindError.invalid("Portable sync integer storage differs")};return value}
        func number(_ name:String)throws->Double {
            let value:Double
            switch try cell(name) {case .real(let bits):value=Double(bitPattern:bits);case .integer(let n):value=Double(n);default:throw OSwindError.invalid("Portable sync number storage differs")}
            guard value.isFinite else {throw OSwindError.invalid("Portable sync number is nonfinite")};return value
        }
        func optionalText(_ name:String)throws->String? {if try cell(name) == .null {return nil};return try text(name)}
        func date(_ name:String)throws->Date {Date(timeIntervalSince1970:try number(name))}
        func optionalDate(_ name:String)throws->Date? {if try cell(name) == .null {return nil};return try date(name)}
        func decode<T:Decodable>(_ name:String,_ type:T.Type)throws->T {guard case .blob(let data)=try cell(name),!data.isEmpty,data.count<=MemoryStore.maximumRecordBytes else {throw OSwindError.invalid("Portable sync payload storage differs")};return try JSONDecoder().decode(type,from:data)}
        func boolean(_ name:String)throws->Bool {let value=try integer(name);guard value==0 || value==1 else {throw OSwindError.invalid("Portable sync boolean differs")};return value==1}
        func object(_ name:String,_ table:SyncCanonicalTable)throws->SyncObjectIdentity {
            let result=try references.identity(table,[.text(Data(text(name).utf8))]);try SyncWireCheck.identity(result,table);return result
        }
        func filter(_ value:SearchFilter)throws->SyncFilterBody {try .init(value) {id in try references.identity(.entity,[.text(Data(id.utf8))])}}
        func passage()throws->PassageRange? {
            let a=try cell("passage_start"),b=try cell("passage_length")
            if a == .null && b == .null {return nil}
            guard case .integer(let start)=a,case .integer(let length)=b,let s=Int(exactly:start),let n=Int(exactly:length) else {throw OSwindError.invalid("Portable sync passage storage differs")}
            let result=PassageRange(start:s,length:n);try SyncWireCheck.passage(result);return result
        }
        func citation(recap:Bool)throws->SyncCitationBody {
            let ordinal=try integer("ordinal");guard let position=Int(exactly:ordinal) else {throw OSwindError.invalid("Portable sync ordinal overflow")}
            let id=try text(recap ? "source_id":"memory_id"),revision:SyncLocalSourceRevision=recap ? .evidence(try text("revision")):.current
            return try .init(owner:object(recap ? "recap_id":"turn_id",recap ? .source:.turn),ordinal:position,link:.init(source:references.source(id,revision),score:number("score"),match:text("match"),passage:passage()))
        }
        let body:SyncPortableBody
        switch table {
        case .source:
            let memory=try decode("payload",Memory.self)
            guard Data(memory.id.utf8)==Data(try text("id").utf8),memory.timestamp.timeIntervalSince1970.bitPattern == (try number("timestamp")).bitPattern,memory.kind.rawValue == (try text("kind")),Data(memory.app.utf8)==Data(try text("app").utf8),Data(memory.title.utf8)==Data(try text("title").utf8),memory.url.map({Data($0.utf8)}) == (try optionalText("url")).map({Data($0.utf8)}),Data(memory.text.utf8)==Data(try text("text").utf8),memory.favorite == (try boolean("favorite")) else {throw OSwindError.invalid("Portable sync source columns differ from payload")}
            body = .source(try .init(memory:memory,origin:identity.origin,media:references.media(memory),sessionBinding:references.session(memory)) {id,revision in try references.source(id,.evidence(revision))})
        case .conversation:body = try .conversation(.init(title:text("title"),created:date("created"),updated:date("updated")))
        case .turn:
            let value=try decode("payload",ChatPayload.self)
            body = try .turn(.init(conversation:object("session_id",.conversation),timestamp:date("timestamp"),question:value.question,text:value.text,provider:value.provider,duration:value.duration,warnings:value.warnings,filter:filter(value.filter),timeZone:value.timeZone))
        case .conversationCitation:body = .conversationCitation(try citation(recap:false))
        case .recapCitation:body = .recapCitation(try citation(recap:true))
        case .routine:
            let value=try decode("payload",RoutineDefinition.self)
            guard try integer("revision")>0,Data(value.id.utf8)==Data(try text("id").utf8) else {throw OSwindError.invalid("Portable sync recipe columns differ")};body = .routine(try .init(value))
        case .routineRun:
            let id=try text("routine_id"),ordinal=try integer("revision"),recipe=try references.recipe(id,ordinal),parent=try object("routine_id",.routine)
            guard recipe.routine==parent,recipe.ordinal==ordinal,let trigger=RoutineTrigger(rawValue:try text("trigger")),let status=RoutineRunStatus(rawValue:try text("status")) else {throw OSwindError.invalid("Portable sync run metadata differs")}
            let chat=try optionalText("chat_id").map {try references.identity(.conversation,[.text(Data($0.utf8))])}
            body = try .routineRun(.init(recipe:recipe,scheduledAt:date("scheduled_at"),started:date("started"),finished:optionalDate("finished"),trigger:trigger,status:status,conversation:chat,message:optionalText("message"),filter:filter(decode("scope",SearchFilter.self))))
        case .entity:
            guard let kind=EntityKind(rawValue:try text("kind")) else {throw OSwindError.invalid("Portable sync entity kind differs")}
            body = try .entity(.init(kind:kind,name:text("name"),detail:text("detail"),curated:boolean("curated"),created:date("created")))
        case .entityAlias:
            guard let kind=EntityKind(rawValue:try text("kind")) else {throw OSwindError.invalid("Portable sync alias kind differs")}
            body = try .entityAlias(.init(entity:object("entity_id",.entity),kind:kind,key:text("key"),label:text("label")))
        case .entityMention:
            guard let origin=SyncMentionOrigin(rawValue:try text("origin")) else {throw OSwindError.invalid("Portable sync mention origin differs")}
            let start=try integer("start"),length=try integer("length"),anchor:PassageRange?
            if start == -1 && length==0 {anchor=nil}
            else {guard let s=Int(exactly:start),let n=Int(exactly:length) else {throw OSwindError.invalid("Portable sync mention range overflow")};anchor = .init(start:s,length:n)}
            body = try .entityMention(.init(source:references.source(text("memory_id"),.entity(text("revision"))),entity:object("entity_id",.entity),origin:origin,passage:anchor,surface:text("surface"),method:text("method")))
        case .entityRejection:
            guard let kind=EntityKind(rawValue:try text("kind")) else {throw OSwindError.invalid("Portable sync rejection kind differs")}
            body = try .entityRejection(.init(source:references.source(text("memory_id"),.current),kind:kind,key:text("key")))
        case .projectRejection:body = try .projectRejection(.init(source:references.source(text("memory_id"),.current),entity:object("entity_id",.entity)))
        case .evidencePin:body = try .evidencePin(.init(source:references.source(text("memory_id"),.current)))
        }
        return try .init(identity:identity,body:body)
    }
}
