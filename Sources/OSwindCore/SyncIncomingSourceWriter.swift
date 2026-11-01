import Foundation
import CSQLite

/// Typed source projection from an already admitted, single journal head.
/// Media is pre-staged by the caller; no enrollment, transport or model work is
/// started here. The shared library reservation precedes journal/SQLite locks.
struct SyncIncomingSourceWriter {
    let library:MemoryStore
    let cache:SyncVersionStore
    let admit:(SyncPortableRecord)throws->Void
    let pathsFor:(SyncVersionReference,[SyncMediaManifest])throws->[SyncMediaRole:String]
    let admitMedia:(SyncVersionReference,[SyncMediaManifest],[SyncMediaRole:String])throws->Void
    var newID:((SyncObjectIdentity)throws->String)? = nil
    var db:RoutineDatabase {cache.database}
    var history:HistoricalEvidenceStore {library.historicalCatalog(db)}
    func verify(_ reference:SyncVersionReference,_ manifests:[SyncMediaManifest],_ paths:[SyncMediaRole:String])throws {
        try admitMedia(reference,manifests,paths);try library.verifyHistoricalMedia(reference,manifests,paths)
    }
    private func localID(_ identity:SyncObjectIdentity)throws->String {
        if let object=try cache.catalog.object(identity) {
            guard !object.deleted,let primary=object.primary,primary.count==1,case .text(let bytes)=primary[0],let value=String(data:bytes,encoding:.utf8) else {throw OSwindError.unavailable("Incoming source owner was erased or remapped")};return value
        }
        let value=try newID?(identity) ?? "peer-"+identity.key.digest
        guard !value.isEmpty,value.utf8.count<128,!value.utf8.contains(0),try library.get(value)==nil else {throw OSwindError.invalid("Incoming source identifier collides with an existing source")};return value
    }
    private func prepare(_ reference:SyncVersionReference,requestedBy:SyncPortableRecord,fetch:(SyncVersionReference)throws->SyncPortableRecord,visiting:inout Set<String>,remaining:inout Int)throws {
        try reference.validate(.source);let key=try reference.identity.key.digest+reference.content.sha256
        guard remaining>0,visiting.count<32,visiting.insert(key).inserted else {throw OSwindError.unavailable("Incoming source dependency graph exceeds its bound")};remaining-=1;defer {visiting.remove(key)}
        let packet:SyncPortableRecord
        if let value=try cache.record(reference,admit:admit) {packet=value}
        else {packet=try fetch(reference);guard try packet.reference==reference else {throw OSwindError.invalid("Incoming source dependency is not its requested version")};_=try cache.retain(packet,requiredBy:requestedBy,admit:admit)}
        guard case .source(let body)=packet.body else {throw OSwindError.invalid("Incoming source dependency is not a source")}
        for parent in body.recap?.sources ?? [] {try prepare(parent.source,requestedBy:packet,fetch:fetch,visiting:&visiting,remaining:&remaining)}
    }
    private func original(_ reference:SyncVersionReference,requestedBy:SyncPortableRecord,fetch:(SyncVersionReference)throws->SyncPortableRecord)throws->HistoricalEvidence {
        var visiting=Set<String>(),remaining=512;try prepare(reference,requestedBy:requestedBy,fetch:fetch,visiting:&visiting,remaining:&remaining)
        return try history.adopt(reference,cache:cache,pathsFor:pathsFor,admit:admit,verifyMedia:verify)
    }
    func references(_ record:SyncPortableRecord,local:String,paths:[SyncMediaRole:String])->SyncPortableReferences {
        let base=SyncPortableReferences(identity:{try cache.catalog.localIdentity($0,primary:$1)},source:{try cache.sourceVersion(localID:$0,revision:$1,admit:admit)},media:{memory in
            guard Data(memory.id.utf8)==Data(local.utf8),case .source(let body)=record.body else {throw OSwindError.invalid("Incoming source media binding differs")}
            var actual=[SyncMediaRole:String]();actual[.image]=memory.imagePath;actual[.audio]=memory.audioPath;actual[.video]=memory.videoPath
            guard actual==paths else {throw OSwindError.invalid("Incoming source paths changed")};return body.media
        },recipe:{try cache.recipeVersion(localID:$0,ordinal:$1,admit:admit)},session:{memory in
            guard Data(memory.id.utf8)==Data(local.utf8),case .source(let body)=record.body else {throw OSwindError.invalid("Incoming source session binding differs")};return body.audioSession
        })
        return history.decorating(base,admit:admit,verify:{value in
            guard case .source(let body)=value.record.body else {throw OSwindError.invalid("Incoming original source differs")}
            var paths=[SyncMediaRole:String]();paths[.image]=value.memory.imagePath;paths[.audio]=value.memory.audioPath;paths[.video]=value.memory.videoPath
            try verify(value.reference,body.media,paths)
        })
    }
    private struct RecapBindings {var unchanged=[SyncPortableRecord]();var retire=[SyncObjectIdentity]()}
    private func recapBindings(_ memory:Memory,old:SyncPortableRecord?,new:SyncPortableRecord)throws->RecapBindings {
        let previous:SyncRecapBody?,replacement:SyncRecapBody?
        if let old,case .source(let body)=old.body {previous=body.recap}else {previous=nil}
        if case .source(let body)=new.body {replacement=body.recap}else {replacement=nil}
        var result=RecapBindings()
        let row=try db.statement("SELECT ordinal FROM recap_sources WHERE recap_id=? ORDER BY ordinal");defer {sqlite3_finalize(row)};db.bind(row,1,memory.id);var code=sqlite3_step(row)
        while code==SQLITE_ROW {
            let ordinal=Int(sqlite3_column_int(row,0))
            if let identity=try cache.catalog.preparedIdentity(.recapCitation,primary:[.text(Data(memory.id.utf8)),.integer(Int64(ordinal))]) {
                if let replacement,ordinal<replacement.sources.count {
                    if let previous,ordinal<previous.sources.count,try SyncProtocolLimits.encode(previous.sources[ordinal])==SyncProtocolLimits.encode(replacement.sources[ordinal]),try cache.projectedReference(identity) != nil {result.unchanged.append(try cache.resolve(identity,content:nil,admit:admit))}
                }else {result.retire.append(identity)}
            };code=sqlite3_step(row)
        };guard code==SQLITE_DONE else {throw db.error()};return result
    }
    private func writeRecapLinks(_ memory:Memory,old:SyncPortableRecord?,new:SyncPortableRecord)throws {
        if let recap=memory.recap {try library.validateRecapParents(memory.id,recap:recap,db:db)}
        let count=memory.recap?.sources.count ?? 0,remove=try db.statement("DELETE FROM recap_sources WHERE recap_id=? AND ordinal>=?");defer {sqlite3_finalize(remove)};db.bind(remove,1,memory.id);sqlite3_bind_int(remove,2,Int32(count));try db.done(remove)
        let previous:SyncRecapBody?,replacement:SyncRecapBody?
        if let old,case .source(let body)=old.body {previous=body.recap}else {previous=nil}
        if case .source(let body)=new.body {replacement=body.recap}else {replacement=nil}
        for (ordinal,source) in (memory.recap?.sources ?? []).enumerated() {
            guard let handle=source.historicalHandle else {throw OSwindError.invalid("Incoming recap needs an exact historical parent")}
            let check=try db.statement("SELECT source_id,revision,owner_id,historical_handle FROM recap_sources WHERE recap_id=? AND ordinal=?");db.bind(check,1,memory.id);sqlite3_bind_int(check,2,Int32(ordinal));let code=sqlite3_step(check),oldOwner=code==SQLITE_ROW ? db.optional(check,0):nil,oldRevision=code==SQLITE_ROW ? db.text(check,1):"";sqlite3_finalize(check)
            guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
            let update={
                let row=try db.statement("INSERT INTO recap_sources(recap_id,source_id,ordinal,revision,score,match,passage_start,passage_length,owner_id,historical_handle) VALUES(?,NULL,?,?,?,?,?,?,?,?) ON CONFLICT(recap_id,ordinal) DO UPDATE SET source_id=NULL,revision=excluded.revision,score=excluded.score,match=excluded.match,passage_start=excluded.passage_start,passage_length=excluded.passage_length,owner_id=excluded.owner_id,historical_handle=excluded.historical_handle");defer {sqlite3_finalize(row)};db.bind(row,1,memory.id);sqlite3_bind_int(row,2,Int32(ordinal));db.bind(row,3,source.revision);sqlite3_bind_double(row,4,source.score);db.bind(row,5,source.match)
                if let range=source.passage {sqlite3_bind_int64(row,6,Int64(range.start));sqlite3_bind_int64(row,7,Int64(range.length))};db.bind(row,8,source.id);db.bind(row,9,handle);try db.done(row)
            }
            if oldOwner.map({Data($0.utf8)})==Data(source.id.utf8),let previous,let replacement,ordinal<previous.sources.count,ordinal<replacement.sources.count,try SyncProtocolLimits.encode(previous.sources[ordinal])==SyncProtocolLimits.encode(replacement.sources[ordinal]) {
                try library.incomingSourceProjection.withBinding(owner:source.id,handle:handle,oldRevision:oldRevision,newRevision:source.revision,update)
            } else {try update()}
        }
    }
    @discardableResult func apply(_ record:SyncPortableRecord,admission:MediaAdmissionLease,fetchExactSource:(SyncVersionReference)throws->SyncPortableRecord)throws->String {
        try admission.withActive(for:library.mediaRootIdentity) {}
        return try library.withRoutineDatabase {connection in
            guard connection.handle==db.handle else {throw OSwindError.invalid("Use the incoming source library's own connection")}
            return try SyncChangeCapture.transaction(db) {
                try record.validate();guard case .source(let body)=record.body else {throw OSwindError.invalid("Use the corresponding typed graph adapter")}
                let reference=try record.reference,state=try cache.journal.state(for:record.identity.key)
                guard !state.isDeleted,state.heads.count==1,state.heads.first?.content==reference.content else {throw OSwindError.unavailable("Admit one reviewed incoming source head before projection")}
                guard try !HistoricalErasureSchema.hasRevokedVersion(db,record) else {throw OSwindError.unavailable("Incoming source version was erased from this library")}
                let local=try localID(record.identity)
                var promotion=try SyncIncomingSourcePromotion.prepare(self,root:local)
                try admit(record);let paths=try pathsFor(reference,body.media);try verify(reference,body.media,paths)
                var parents=[HistoricalEvidence]()
                for link in body.recap?.sources ?? [] {parents.append(try original(link.source,requestedBy:record,fetch:fetchExactSource))}
                var index=0,memory=try body.projectedMemory(id:local,paths:paths) {ref in
                    guard index<parents.count,try parents[index].reference==ref else {throw OSwindError.invalid("Incoming recap parent order differs")};defer {index+=1};return(parents[index].sourceID,parents[index].memory.evidenceHash)
                }
                for i in parents.indices {memory.recap!.sources[i].historicalHandle=parents[i].handle}
                let old=promotion.nodes.first {Data($0.before.id.utf8)==Data(local.utf8)}?.packet
                let recapState=try recapBindings(memory,old:old,new:record)
                try promotion.apply()
                try SyncDerivedRetirement.enqueue(recapState.retire,db:db)
                for identity in recapState.retire {
                    try cache.catalog.deletePeer(identity) {mapping in
                        guard let primary=mapping?.primary,primary.count==2,case .text(let owner)=primary[0],case .integer(let ordinal)=primary[1],owner==Data(local.utf8) else {throw OSwindError.invalid("Incoming obsolete recap binding differs")}
                        let row=try db.statement("DELETE FROM recap_sources WHERE recap_id=? AND ordinal=?");defer {sqlite3_finalize(row)};db.bind(row,1,local);sqlite3_bind_int64(row,2,ordinal);try db.done(row)
                    }
                }
                try cache.catalog.applyPeer(record.identity,primary:[.text(Data(local.utf8))]) {
                    try library.insertIncomingSource(memory)
                    try writeRecapLinks(memory,old:old,new:record)
                }
                _=try cache.retain(record,admit:admit);try cache.bindProjection(reference,references:references(record,local:local,paths:paths),admit:admit)
                for packet in recapState.unchanged {try cache.bindProjection(packet.reference,references:references(packet,local:local,paths:[:]),admit:admit)}
                try verify(reference,body.media,paths)
                guard try SyncProtocolLimits.encode(library.get(local))==SyncProtocolLimits.encode(memory),try cache.resolve(record.identity,content:nil,admit:{_ in}).encoded()==record.encoded() else {throw OSwindError.invalid("Incoming source changed during projection")}
                let after=try cache.journal.state(for:record.identity.key)
                guard !after.isDeleted,after.heads.count==1,after.heads.first?.content==reference.content else {throw OSwindError.invalid("Incoming source head changed during projection")}
                try SyncIncomingDependencyAudit.check([record]+promotion.nodes.map(\.packet),cache:cache)
                try promotion.audit()
                // No caller callbacks after this point: re-read every newly
                // adopted dependency after the last mutable policy/media hook.
                for parent in parents {
                    let final=try history.read(parent.handle,sourceID:parent.sourceID,verifyMedia:library.verifyHistoricalMedia)
                    guard try final.reference==parent.reference,try SyncProtocolLimits.encode(final.memory)==SyncProtocolLimits.encode(parent.memory) else {throw OSwindError.invalid("Incoming recap original changed during projection")}
                }
                for packet in recapState.unchanged {guard try cache.resolve(packet.identity,content:nil,admit:{_ in}).encoded()==packet.encoded() else {throw OSwindError.invalid("Incoming recap citation changed during projection")}}
                try library.verifyHistoricalMedia(reference,body.media,paths)
                try admission.withActive(for:library.mediaRootIdentity) {};return local
            }
        }
    }
}

/// Final callback-free audit shared by typed incoming adapters. Exact versions
/// may be historical; identity-only references need one matching current head.
/// Version keys permit acyclic history even when canonical owner IDs repeat.
enum SyncIncomingDependencyAudit {
    static func check(_ packets:[SyncPortableRecord],cache:SyncVersionStore)throws {
        var visited=Set<String>(),visiting=Set<String>(),remaining=2048
        func resolve(_ identity:SyncObjectIdentity,_ content:SyncContentReference?)throws->SyncPortableRecord {
            let result=try cache.resolve(identity,content:content,admit:{_ in})
            if content==nil {
                let state=try cache.journal.state(for:identity.key)
                guard !state.isDeleted,state.heads.count==1,try state.heads.first?.content==result.reference.content else {throw OSwindError.unavailable("Incoming current dependency head changed during projection")}
            }
            return result
        }
        func walk(_ packet:SyncPortableRecord)throws {
            try Task.checkCancellation()
            let ref=try packet.reference,key=try ref.identity.key.digest+ref.content.sha256
            guard !visiting.contains(key),visiting.count<32 else {throw OSwindError.unavailable("Incoming final dependency audit exceeds its graph bound")}
            if visited.contains(key) {return}
            guard remaining>0,let stored=try cache.record(ref,admit:{_ in}),try stored.encoded()==packet.encoded() else {throw OSwindError.invalid("Incoming exact dependency admission changed during projection")}
            remaining-=1;visiting.insert(key);defer {visiting.remove(key)}
            for dependency in try packet.liveDependencies(conversationIsErased:{try cache.isErasedOptionalConversation(packet,identity:$0)},entityScopeIsErased:{try cache.isErasedOptionalEntityScope(packet,identity:$0)}) {try walk(resolve(dependency.identity,dependency.content))}
            try packet.validateDependencies(conversationIsErased:{try cache.isErasedOptionalConversation(packet,identity:$0)},entityScopeIsErased:{try cache.isErasedOptionalEntityScope(packet,identity:$0)},resolve:resolve)
            visited.insert(key)
        }
        for packet in packets {try walk(packet)}
    }
}
