import Foundation
import CSQLite

/// Typed incoming conversation/citation/pin adapter. Caller authenticates and
/// receives the journal operation, prefetches exact dependency bodies/media and
/// serializes the borrowed library connection. No enrollment/service is enabled.
struct SyncIncomingConversationWriter {
    let library:MemoryStore
    let cache:SyncVersionStore
    let admit:(SyncPortableRecord)throws->Void
    let pathsFor:(SyncVersionReference,[SyncMediaManifest])throws->[SyncMediaRole:String]
    let admitMedia:(SyncVersionReference,[SyncMediaManifest],[SyncMediaRole:String])throws->Void
    var newID:((SyncObjectIdentity)throws->String)? = nil
    var db:RoutineDatabase {cache.database}
    var history:HistoricalEvidenceStore {library.historicalCatalog(db)}
    private func verifyMedia(_ ref:SyncVersionReference,_ manifests:[SyncMediaManifest],_ paths:[SyncMediaRole:String])throws {try admitMedia(ref,manifests,paths);try library.verifyHistoricalMedia(ref,manifests,paths)}
    private func id(_ identity:SyncObjectIdentity,create:Bool=false)throws->String {
        if let object=try cache.catalog.object(identity) {
            guard !object.deleted,let primary=object.primary,primary.count==1,case .text(let bytes)=primary[0],let value=String(data:bytes,encoding:.utf8) else {throw OSwindError.unavailable("The incoming owner was erased or has a different key")};return value
        }
        guard create else {throw OSwindError.unavailable("Prepare the incoming object owner first")}
        let value=try newID?(identity) ?? "peer-"+identity.key.digest
        guard !value.isEmpty,value.utf8.count<128,!value.utf8.contains(0) else {throw OSwindError.invalid("Invalid incoming local identifier")};return value
    }
    private var references:SyncPortableReferences {
        let base=SyncPortableReferences(identity:{try cache.catalog.localIdentity($0,primary:$1)},source:{try cache.sourceVersion(localID:$0,revision:$1,admit:admit)},media:{_ in throw OSwindError.unavailable("Source projection uses its complete source/media adapter")},recipe:{try cache.recipeVersion(localID:$0,ordinal:$1,admit:admit)},session:{_ in throw OSwindError.unavailable("Source projection needs its original session binding")},runRecipe:{try cache.runRecipe(localRunID:$0,recipeID:$1,ordinal:$2,admit:admit)})
        return history.decorating(base,admit:admit,verify:{value in
            guard case .source(let body)=value.record.body else {throw OSwindError.invalid("Historical source differs")}
            var paths=[SyncMediaRole:String]();if let path=value.memory.imagePath {paths[.image]=path};if let path=value.memory.audioPath {paths[.audio]=path};if let path=value.memory.videoPath {paths[.video]=path}
            try verifyMedia(value.reference,body.media,paths)
        })
    }
    private func bind(_ row:OpaquePointer,_ index:Int32,_ bytes:Data) {bytes.withUnsafeBytes {_ = sqlite3_bind_blob(row,index,$0.baseAddress,Int32(bytes.count),db.transient)}}
    private func ensureSource(_ reference:SyncVersionReference,requestedBy:SyncPortableRecord,fetch:(SyncVersionReference)throws->SyncPortableRecord,visiting:inout Set<String>,remaining:inout Int)throws {
        try reference.validate(.source);let key=try reference.identity.key.digest+reference.content.sha256
        guard remaining>0,visiting.count<32,visiting.insert(key).inserted else {throw OSwindError.unavailable("Incoming original graph exceeds its preparation bound")};remaining-=1;defer {visiting.remove(key)}
        let record:SyncPortableRecord
        if let cached=try cache.record(reference,admit:admit) {record=cached}
        else {record=try fetch(reference);guard try record.reference==reference else {throw OSwindError.invalid("Fetched original is not the requested exact version")};_=try cache.retain(record,requiredBy:requestedBy,admit:admit)}
        guard case .source(let body)=record.body else {throw OSwindError.invalid("Incoming original is not a source")}
        for parent in body.recap?.sources ?? [] {try ensureSource(parent.source,requestedBy:record,fetch:fetch,visiting:&visiting,remaining:&remaining)}
    }
    private func original(_ ref:SyncVersionReference,requestedBy:SyncPortableRecord,fetch:(SyncVersionReference)throws->SyncPortableRecord)throws->HistoricalEvidence {
        var visiting=Set<String>(),remaining=512;try ensureSource(ref,requestedBy:requestedBy,fetch:fetch,visiting:&visiting,remaining:&remaining)
        return try history.adopt(ref,cache:cache,pathsFor:pathsFor,admit:admit,verifyMedia:verifyMedia)
    }
    @discardableResult func apply(_ record:SyncPortableRecord,admission:MediaAdmissionLease,fetchExactSource:(SyncVersionReference)throws->SyncPortableRecord)throws->String {
        // The caller reserves media BEFORE journal/SQLite locks, then retains
        // this reservation through admission. Acquiring it here can deadlock
        // against erasure holding the exclusive lease while waiting for SQLite.
        try admission.withActive(for:library.mediaRootIdentity) {}
        return try library.withRoutineDatabase {connection in
            guard connection.handle==db.handle else {throw OSwindError.invalid("Use the incoming library's own connection")}
            return try SyncChangeCapture.transaction(db) {
                try record.validate();let reference=try record.reference,state=try cache.journal.state(for:record.identity.key)
                guard !state.isDeleted,state.heads.count==1,state.heads.first?.content==reference.content else {throw OSwindError.unavailable("Admit one reviewed incoming head before projection; conflicts remain explicit")}
                try admit(record);var local="",historical:HistoricalEvidence?
                switch record.body {
                case .conversation(let body):
                    local=try id(record.identity,create:true)
                    try cache.catalog.applyPeer(record.identity,primary:[.text(Data(local.utf8))]) {
                        let row=try db.statement("INSERT INTO chat_sessions(id,title,created,updated) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,created=excluded.created,updated=excluded.updated");defer {sqlite3_finalize(row)}
                        db.bind(row,1,local);db.bind(row,2,body.title);sqlite3_bind_double(row,3,body.created.timeIntervalSince1970);sqlite3_bind_double(row,4,body.updated.timeIntervalSince1970);try db.done(row)
                    }
                case .turn(let body):
                    local=try id(record.identity,create:true);let conversation=try id(body.conversation)
                    let value=ChatPayload(question:body.question,text:body.text,provider:body.provider,duration:body.duration,warnings:body.warnings,filter:try body.filter.projected {try id($0)},timeZone:body.timeZone)
                    let data=try SyncProtocolLimits.encode(value)
                    try cache.catalog.applyPeer(record.identity,primary:[.text(Data(local.utf8))]) {
                        let row=try db.statement("INSERT INTO chat_turns(id,session_id,timestamp,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id,timestamp=excluded.timestamp,payload=excluded.payload");defer {sqlite3_finalize(row)}
                        db.bind(row,1,local);db.bind(row,2,conversation);sqlite3_bind_double(row,3,body.timestamp.timeIntervalSince1970);bind(row,4,data);try db.done(row)
                    }
                case .conversationCitation(let body):
                    local=try id(body.owner);let source=try id(body.link.source.identity);_=try cache.resolve(body.owner,content:nil,admit:admit)
                    let evidence=try original(body.link.source,requestedBy:record,fetch:fetchExactSource);historical=evidence
                    guard evidence.sourceID==source,body.link.passage.map({$0.text(in:evidence.memory.text) != nil}) ?? true else {throw OSwindError.invalid("Historical citation owner or passage differs")}
                    try cache.catalog.applyPeer(record.identity,primary:[.text(Data(local.utf8)),.integer(Int64(body.ordinal))]) {
                        let row=try db.statement("INSERT INTO chat_sources(turn_id,memory_id,ordinal,score,match,passage_start,passage_length,owner_id,historical_handle) VALUES(?,NULL,?,?,?,?,?,?,?) ON CONFLICT(turn_id,ordinal) DO UPDATE SET memory_id=excluded.memory_id,score=excluded.score,match=excluded.match,passage_start=excluded.passage_start,passage_length=excluded.passage_length,owner_id=excluded.owner_id,historical_handle=excluded.historical_handle");defer {sqlite3_finalize(row)}
                        db.bind(row,1,local);sqlite3_bind_int64(row,2,Int64(body.ordinal));sqlite3_bind_double(row,3,body.link.score);db.bind(row,4,body.link.match)
                        if let range=body.link.passage {sqlite3_bind_int64(row,5,Int64(range.start));sqlite3_bind_int64(row,6,Int64(range.length))};db.bind(row,7,source);db.bind(row,8,evidence.handle);try db.done(row)
                    }
                case .evidencePin(let body):
                    local=try id(body.source.identity);let evidence=try original(body.source,requestedBy:record,fetch:fetchExactSource);historical=evidence
                    guard evidence.sourceID==local else {throw OSwindError.invalid("Historical pin owner differs")}
                    try cache.catalog.applyPeer(record.identity,primary:[.text(Data(local.utf8))]) {
                        let row=try db.statement("INSERT OR IGNORE INTO text_observation_pins(memory_id) VALUES(?)");defer {sqlite3_finalize(row)};db.bind(row,1,local);try db.done(row)
                        let binding=try db.statement("INSERT INTO historical_evidence_pins VALUES(?,?) ON CONFLICT(memory_id) DO UPDATE SET handle=excluded.handle");defer {sqlite3_finalize(binding)};db.bind(binding,1,local);db.bind(binding,2,evidence.handle);try db.done(binding)
                    }
                default:throw OSwindError.unavailable("This record requires its complete typed graph adapter")
                }
                _=try cache.retain(record,admit:admit);try cache.bindProjection(reference,references:references,admit:admit)
                if let historical {
                    let after=try history.read(historical.handle,sourceID:historical.sourceID,verifyMedia:{_,_,_ in})
                    guard try after.reference==historical.reference,try SyncProtocolLimits.encode(after.memory)==SyncProtocolLimits.encode(historical.memory) else {throw OSwindError.invalid("Incoming historical citation changed during admission")}
                }
                _=try cache.resolve(record.identity,content:nil,admit:{_ in});try admission.withActive(for:library.mediaRootIdentity) {};return local
            }
        }
    }
}
