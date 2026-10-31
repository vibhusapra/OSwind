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
    /// Content-free recap deletion. The global old citation is retired even
    /// when its current owner still independently requires the same native row.
    func applyDeletion(_ change:SyncJournalChange,admission:MediaAdmissionLease)throws {
        try admission.withActive(for:library.mediaRootIdentity) {}
        try library.withRoutineDatabase {connection in
            guard connection.handle==db.handle,change.after.isDeleted,change.revision.key.kind == .recapCitation else {throw OSwindError.invalid("Use the corresponding typed deletion adapter")}
            try cache.catalog.retireDerivedRecap(change.revision.key,journal:cache.journal) {object in
                guard let primary=object.primary,primary.count==2,case .text(let bytes)=primary[0],case .integer(let position)=primary[1],let owner=String(data:bytes,encoding:.utf8),let ordinal=Int(exactly:position),ordinal>=0 else {throw OSwindError.invalid("Incoming recap deletion key differs")}
                guard let native=try library.get(owner) else {return false}
                guard let identity=try cache.catalog.preparedIdentity(.source,primary:[.text(bytes)]) else {throw OSwindError.unavailable("Prepare the recap owner before derived retirement")}
                let packet=try cache.resolve(identity,content:nil,admit:{_ in})
                guard case .source(let body)=packet.body else {throw OSwindError.invalid("Incoming recap owner is not a source")}
                guard let wire=body.recap,ordinal<wire.sources.count else {return false}
                guard let recap=native.recap,ordinal<recap.sources.count else {throw OSwindError.invalid("Native recap provenance differs during retirement")}
                let expected=recap.sources[ordinal],row=try db.statement("SELECT source_id,revision,score,match,passage_start,passage_length,owner_id,historical_handle FROM recap_sources WHERE recap_id=? AND ordinal=?");defer {sqlite3_finalize(row)};db.bind(row,1,owner);sqlite3_bind_int64(row,2,position)
                guard sqlite3_step(row)==SQLITE_ROW,Data(db.text(row,1).utf8)==Data(expected.revision.utf8),sqlite3_column_double(row,2)==expected.score,Data(db.text(row,3).utf8)==Data(expected.match.utf8),db.optional(row,7).map({Data($0.utf8)})==expected.historicalHandle.map({Data($0.utf8)}) else {throw OSwindError.invalid("Derived recap row differs from its current owner")}
                if expected.historicalHandle != nil {guard sqlite3_column_type(row,0)==SQLITE_NULL,Data(db.text(row,6).utf8)==Data(expected.id.utf8) else {throw OSwindError.invalid("Derived historical owner differs")}}
                else {guard Data(db.text(row,0).utf8)==Data(expected.id.utf8),sqlite3_column_type(row,6)==SQLITE_NULL else {throw OSwindError.invalid("Derived current owner differs")}}
                if let range=expected.passage {guard sqlite3_column_type(row,4)==SQLITE_INTEGER,sqlite3_column_int64(row,4)==range.start,sqlite3_column_type(row,5)==SQLITE_INTEGER,sqlite3_column_int64(row,5)==range.length else {throw OSwindError.invalid("Derived recap passage differs")}}
                else {guard sqlite3_column_type(row,4)==SQLITE_NULL,sqlite3_column_type(row,5)==SQLITE_NULL else {throw OSwindError.invalid("Derived recap has an undeclared passage")}}
                return true
            }
            try admission.withActive(for:library.mediaRootIdentity) {}
        }
    }
    @discardableResult func apply(_ record:SyncPortableRecord,admission:MediaAdmissionLease,fetchExactSource:(SyncVersionReference)throws->SyncPortableRecord)throws->String {
        // The caller reserves media BEFORE journal/SQLite locks, then retains
        // this reservation through admission. Acquiring it here can deadlock
        // against erasure holding the exclusive lease while waiting for SQLite.
        if case .source=record.body {
            return try SyncIncomingSourceWriter(library:library,cache:cache,admit:admit,pathsFor:pathsFor,admitMedia:admitMedia,newID:newID).apply(record,admission:admission,fetchExactSource:fetchExactSource)
        }
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
                    guard Data(evidence.sourceID.utf8)==Data(source.utf8),body.link.passage.map({$0.text(in:evidence.memory.text) != nil}) ?? true else {throw OSwindError.invalid("Historical citation owner or passage differs")}
                    try cache.catalog.applyPeer(record.identity,primary:[.text(Data(local.utf8)),.integer(Int64(body.ordinal))]) {
                        let row=try db.statement("INSERT INTO chat_sources(turn_id,memory_id,ordinal,score,match,passage_start,passage_length,owner_id,historical_handle) VALUES(?,NULL,?,?,?,?,?,?,?) ON CONFLICT(turn_id,ordinal) DO UPDATE SET memory_id=excluded.memory_id,score=excluded.score,match=excluded.match,passage_start=excluded.passage_start,passage_length=excluded.passage_length,owner_id=excluded.owner_id,historical_handle=excluded.historical_handle");defer {sqlite3_finalize(row)}
                        db.bind(row,1,local);sqlite3_bind_int64(row,2,Int64(body.ordinal));sqlite3_bind_double(row,3,body.link.score);db.bind(row,4,body.link.match)
                        if let range=body.link.passage {sqlite3_bind_int64(row,5,Int64(range.start));sqlite3_bind_int64(row,6,Int64(range.length))};db.bind(row,7,source);db.bind(row,8,evidence.handle);try db.done(row)
                    }
                case .recapCitation(let body):
                    local=try id(body.owner);let source=try id(body.link.source.identity)
                    let owner=try cache.resolve(body.owner,content:nil,admit:admit)
                    guard case .source(let root)=owner.body,let recap=root.recap,body.ordinal<recap.sources.count,try SyncProtocolLimits.encode(recap.sources[body.ordinal])==SyncProtocolLimits.encode(body.link) else {throw OSwindError.invalid("Incoming recap citation differs from its owner")}
                    let evidence=try original(body.link.source,requestedBy:record,fetch:fetchExactSource);historical=evidence
                    guard Data(evidence.sourceID.utf8)==Data(source.utf8),body.link.passage.map({$0.text(in:evidence.memory.text) != nil}) ?? true else {throw OSwindError.invalid("Incoming recap citation source or passage differs")}
                    guard let native=try library.get(local),let links=native.recap?.sources,body.ordinal<links.count,links[body.ordinal].historicalHandle==evidence.handle,Data(links[body.ordinal].id.utf8)==Data(source.utf8),links[body.ordinal].revision==evidence.memory.evidenceHash else {throw OSwindError.invalid("Prepare the exact incoming recap owner before its citation")}
                    try cache.catalog.applyPeer(record.identity,primary:[.text(Data(local.utf8)),.integer(Int64(body.ordinal))]) {
                        let row=try db.statement("UPDATE recap_sources SET revision=?,score=?,match=?,passage_start=?,passage_length=?,owner_id=?,historical_handle=? WHERE recap_id=? AND ordinal=? AND source_id IS NULL");defer {sqlite3_finalize(row)};db.bind(row,1,evidence.memory.evidenceHash);sqlite3_bind_double(row,2,body.link.score);db.bind(row,3,body.link.match)
                        if let range=body.link.passage {sqlite3_bind_int64(row,4,Int64(range.start));sqlite3_bind_int64(row,5,Int64(range.length))};db.bind(row,6,source);db.bind(row,7,evidence.handle);db.bind(row,8,local);sqlite3_bind_int64(row,9,Int64(body.ordinal));try db.done(row);guard sqlite3_changes(db.handle)==1 else {throw OSwindError.invalid("Incoming recap relationship disappeared")}
                    }
                case .evidencePin(let body):
                    local=try id(body.source.identity);let evidence=try original(body.source,requestedBy:record,fetch:fetchExactSource);historical=evidence
                    guard Data(evidence.sourceID.utf8)==Data(local.utf8) else {throw OSwindError.invalid("Historical pin owner differs")}
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
                try SyncIncomingDependencyAudit.check([record],cache:cache)
                let after=try cache.journal.state(for:record.identity.key)
                guard !after.isDeleted,after.heads.count==1,after.heads.first?.content==reference.content,try cache.resolve(record.identity,content:nil,admit:{_ in}).encoded()==record.encoded() else {throw OSwindError.invalid("Incoming head or exact projection changed during admission")}
                try admission.withActive(for:library.mediaRootIdentity) {};return local
            }
        }
    }
}
