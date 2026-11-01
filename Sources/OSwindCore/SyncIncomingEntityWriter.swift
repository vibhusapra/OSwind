import Foundation
import CSQLite

/// Native entity projection from one authenticated, reviewed journal head.
/// Suggestions retain peer attribution; they never complete local extraction.
struct SyncIncomingEntityWriter {
    let library:MemoryStore
    let cache:SyncVersionStore
    let admit:(SyncPortableRecord)throws->Void
    var newID:((SyncObjectIdentity)throws->String)? = nil
    var db:RoutineDatabase {cache.database}
    static let tables:Set<SyncCanonicalTable> = [.entity,.entityAlias,.entityMention,.entityRejection,.projectRejection]

    private func id(_ identity:SyncObjectIdentity,create:Bool=false)throws->String {
        if let object=try cache.catalog.object(identity) {
            guard !object.deleted,let key=object.primary,key.count==1,case .text(let bytes)=key[0],let value=String(data:bytes,encoding:.utf8) else {throw OSwindError.unavailable("Incoming entity owner was erased or remapped")}
            return value
        }
        guard create else {throw OSwindError.unavailable("Prepare the incoming entity owner first")}
        let value=try newID?(identity) ?? "peer-"+identity.key.digest
        guard !value.isEmpty,value.utf8.count<128,!value.utf8.contains(0),try library.entity(value)==nil else {throw OSwindError.invalid("Incoming entity identifier collides with an existing owner")}
        return value
    }
    private func execute(_ sql:String,_ values:[String])throws {
        let row=try db.statement(sql);defer {sqlite3_finalize(row)}
        for (i,value) in values.enumerated() {db.bind(row,Int32(i+1),value)};try db.done(row)
    }
    private struct SourceBinding {let reference:SyncVersionReference,local:String,revision:String}
    private func source(_ reference:SyncVersionReference,record:SyncPortableRecord,fetch:(SyncVersionReference)throws->SyncPortableRecord)throws->SourceBinding {
        let local=try id(reference.identity)
        let current=try cache.sourceVersion(localID:local,revision:.current,admit:admit)
        let state=try cache.journal.state(for:reference.identity.key)
        guard !state.isDeleted,state.heads.count==1,state.heads.first?.content==current.content else {throw OSwindError.unavailable("Incoming entity needs one current native source head")}
        let packet:SyncPortableRecord
        if let retained=try cache.record(reference,admit:admit) {packet=retained}
        else {packet=try fetch(reference);guard try packet.reference==reference else {throw OSwindError.invalid("Incoming entity source is not its requested exact version")};_=try cache.retain(packet,requiredBy:record,admit:admit)}
        guard case .source(let body)=packet.body,let native=try library.get(local) else {throw OSwindError.unavailable("Incoming entity source is unavailable")}
        let original=Memory(id:local,timestamp:body.timestamp,kind:body.kind,app:body.app,title:body.title,url:body.url,text:body.text)
        guard Data(original.entityRevision.utf8)==Data(native.entityRevision.utf8) else {throw OSwindError.unavailable("Incoming entity link describes a different source revision")}
        return .init(reference:reference,local:local,revision:native.entityRevision)
    }
    private func audit(_ binding:SourceBinding)throws {
        let current=try cache.sourceVersion(localID:binding.local,revision:.entity(binding.revision),admit:{_ in}),state=try cache.journal.state(for:binding.reference.identity.key)
        guard current.identity==binding.reference.identity,!state.isDeleted,state.heads.count==1,state.heads.first?.content==current.content,let native=try library.get(binding.local),Data(native.entityRevision.utf8)==Data(binding.revision.utf8) else {throw OSwindError.unavailable("Incoming entity source changed during projection")}
    }
    private func references(_ binding:SourceBinding?)->SyncPortableReferences {
        .init(identity:{try cache.catalog.localIdentity($0,primary:$1)},source:{local,revision in
            guard let binding,Data(local.utf8)==Data(binding.local.utf8) else {throw OSwindError.invalid("Incoming entity source owner differs")}
            switch revision {case .current:break;case .entity(let expected):guard Data(expected.utf8)==Data(binding.revision.utf8) else {throw OSwindError.invalid("Incoming entity source revision differs")};case .evidence:throw OSwindError.invalid("Entity projection cannot bind citation evidence")}
            try audit(binding);return binding.reference
        },media:{_ in throw OSwindError.invalid("Entity projection has no media")},recipe:{_,_ in throw OSwindError.invalid("Entity projection has no recipe")},session:{_ in nil})
    }
    private func ownership(_ record:SyncPortableRecord,_ primary:[SyncRowCell])throws {
        if let old=try cache.catalog.object(record.identity) {
            guard !old.deleted,old.primary==primary else {throw OSwindError.invalid("Incoming entity relationship cannot change its native key")}
        } else {
            let schema=record.identity.table.schema,row=try db.statement("SELECT 1 FROM "+schema.name+" WHERE "+schema.primary.map {$0+"=?"}.joined(separator:" AND "));defer {sqlite3_finalize(row)}
            for (i,value) in primary.enumerated() {guard case .text(let bytes)=value,let text=String(data:bytes,encoding:.utf8) else {throw OSwindError.invalid("Incoming entity key is not text")};db.bind(row,Int32(i+1),text)}
            let code=sqlite3_step(row);guard code==SQLITE_DONE else {if code==SQLITE_ROW {throw OSwindError.unavailable("Incoming entity relationship collides with another native owner")};throw db.error()}
        }
    }
    func applyDeletion(_ change:SyncJournalChange,admission:MediaAdmissionLease)throws {
        guard change.after.isDeleted else {throw OSwindError.invalid("Use an admitted entity deletion barrier")}
        try applyDeletionKey(change.revision.key,admission:admission)
    }
    func applyDeletionKey(_ key:SyncObjectKey,admission:MediaAdmissionLease)throws {
        try admission.withActive(for:library.mediaRootIdentity) {}
        try library.withRoutineDatabase {connection in
            guard connection.handle==db.handle,try cache.journal.state(for:key).isDeleted,Self.tables.contains(where:{$0.kind==key.kind}) else {throw OSwindError.invalid("Use the corresponding typed entity deletion adapter")}
            try SyncChangeCapture.transaction(db) {
            if key.kind == .entity,let object=try cache.catalog.object(for:key),!object.deleted {try cache.retirePeerEntityScopes(object,library:library)}
            try cache.catalog.deletePeerKey(key,journal:cache.journal) {object in
                guard let object else {return}
                let schema=object.identity.table.schema
                guard Self.tables.contains(object.identity.table),let primary=object.primary,primary.count==schema.primary.count else {throw OSwindError.invalid("Incoming entity deletion key differs")}
                var values=[String]()
                for cell in primary {guard case .text(let bytes)=cell,let value=String(data:bytes,encoding:.utf8) else {throw OSwindError.invalid("Incoming entity deletion key is not text")};values.append(value)}
                var changesProjectRules=false
                if object.identity.table == .entityAlias {changesProjectRules=values[0]==EntityKind.project.rawValue}
                if object.identity.table == .entity {
                    let row=try db.statement("SELECT kind FROM memory_entities WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,values[0]);let code=sqlite3_step(row)
                    guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
                    changesProjectRules=code==SQLITE_ROW && db.text(row,0)==EntityKind.project.rawValue
                }
                // Cascades may have already removed this row. Its durable wire
                // tombstone still retires the mapping without inventing a body.
                try execute("DELETE FROM "+schema.name+" WHERE "+schema.primary.map {$0+"=?"}.joined(separator:" AND "),values)
                if changesProjectRules {try db.bumpEntityRules()}
            }
            try Task.checkCancellation()
            try admission.withActive(for:library.mediaRootIdentity) {}
            }
        }
    }
    @discardableResult func apply(_ record:SyncPortableRecord,admission:MediaAdmissionLease,fetchExactSource:(SyncVersionReference)throws->SyncPortableRecord)throws->String {
        try admission.withActive(for:library.mediaRootIdentity) {}
        return try library.withRoutineDatabase {connection in
            guard connection.handle==db.handle else {throw OSwindError.invalid("Use the incoming entity library's own connection")}
            return try SyncChangeCapture.transaction(db) {
                try record.validate();guard Self.tables.contains(record.identity.table) else {throw OSwindError.invalid("Use the corresponding typed entity adapter")}
                let reference=try record.reference,state=try cache.journal.state(for:record.identity.key)
                guard !state.isDeleted,state.heads.count==1,state.heads.first?.content==reference.content else {throw OSwindError.unavailable("Admit one reviewed incoming entity head before projection")}
                try admit(record)
                var binding:SourceBinding?,primary=[SyncRowCell](),local=""
                func text(_ value:String)->SyncRowCell {.text(Data(value.utf8))}
                switch record.body {
                case .entity:
                    local=try id(record.identity,create:true);primary=[text(local)]
                case .entityAlias(let body):
                    local=try id(body.entity);primary=[text(body.kind.rawValue),text(body.key)]
                case .entityMention(let body):
                    binding=try source(body.source,record:record,fetch:fetchExactSource);local=try id(body.entity);primary=[text(binding!.local),text(local),text(body.origin.rawValue)]
                case .entityRejection(let body):
                    binding=try source(body.source,record:record,fetch:fetchExactSource);local=binding!.local;primary=[text(local),text(body.kind.rawValue),text(body.key)]
                case .projectRejection(let body):
                    binding=try source(body.source,record:record,fetch:fetchExactSource);local=try id(body.entity);primary=[text(binding!.local),text(local)]
                default:throw OSwindError.invalid("Use the corresponding typed entity adapter")
                }
                try ownership(record,primary)
                try record.validateDependencies {try cache.resolve($0,content:$1,admit:admit)}
                try cache.catalog.applyPeer(record.identity,primary:primary) {
                    switch record.body {
                    case .entity(let body):
                        let previous=try library.entity(local)
                        guard previous==nil || previous?.kind==body.kind else {throw OSwindError.invalid("An entity lifetime cannot change kind")}
                        if body.kind == .project,body.curated,previous?.curated != true {guard try db.eraseCount("SELECT count(*) FROM memory_entities WHERE kind='project' AND curated=1")<1000 else {throw OSwindError.unavailable("At most 1,000 curated projects can be indexed")}}
                        let row=try db.statement("INSERT INTO memory_entities VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,detail=excluded.detail,curated=excluded.curated,created=excluded.created");defer {sqlite3_finalize(row)}
                        db.bind(row,1,local);db.bind(row,2,body.kind.rawValue);db.bind(row,3,body.name);db.bind(row,4,body.detail);sqlite3_bind_int(row,5,body.curated ? 1:0);sqlite3_bind_double(row,6,body.created.timeIntervalSince1970);try db.done(row)
                        if body.kind == .project,(previous?.name != body.name || previous?.curated != body.curated) {try db.bumpEntityRules()}
                    case .entityAlias(let body):
                        guard try db.entityKind(local)==body.kind else {throw OSwindError.invalid("Incoming alias kind differs from its owner")}
                        let previous=try db.entityID(kind:body.kind,key:body.key)
                        if previous != local {guard try db.entityAliases(local).count<32 else {throw OSwindError.unavailable("Use at most 32 aliases per entity")}}
                        try execute("INSERT INTO entity_aliases VALUES(?,?,?,?) ON CONFLICT(kind,key) DO UPDATE SET entity_id=excluded.entity_id,label=excluded.label",[local,body.kind.rawValue,body.key,body.label])
                        if body.kind == .project,previous != local {try db.bumpEntityRules()}
                    case .entityMention(let body):
                        let source=binding!.local
                        if body.origin == .manual {
                            try execute("DELETE FROM entity_ignored WHERE memory_id=? AND (kind,key) IN (SELECT kind,key FROM entity_aliases WHERE entity_id=?)",[source,local])
                            try execute("DELETE FROM entity_project_ignored WHERE memory_id=? AND entity_id=?",[source,local])
                        } else {
                            let row=try db.statement("SELECT 1 FROM entity_ignored i JOIN entity_aliases a ON a.kind=i.kind AND a.key=i.key WHERE i.memory_id=? AND a.entity_id=? LIMIT 1");defer {sqlite3_finalize(row)};db.bind(row,1,source);db.bind(row,2,local)
                            let code=sqlite3_step(row);guard code==SQLITE_DONE else {if code==SQLITE_ROW {throw OSwindError.unavailable("Incoming automatic entity mention conflicts with a saved correction")};throw db.error()}
                        }
                        let row=try db.statement("INSERT INTO entity_mentions VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(memory_id,entity_id,origin) DO UPDATE SET revision=excluded.revision,start=excluded.start,length=excluded.length,surface=excluded.surface,method=excluded.method");defer {sqlite3_finalize(row)}
                        db.bind(row,1,source);db.bind(row,2,local);db.bind(row,3,body.origin.rawValue);db.bind(row,4,binding!.revision);sqlite3_bind_int64(row,5,Int64(body.passage?.start ?? -1));sqlite3_bind_int64(row,6,Int64(body.passage?.length ?? 0));db.bind(row,7,body.surface);db.bind(row,8,body.method);try db.done(row)
                    case .entityRejection(let body):
                        try execute("INSERT INTO entity_ignored VALUES(?,?,?) ON CONFLICT(memory_id,kind,key) DO NOTHING",[local,body.kind.rawValue,body.key])
                        try execute("DELETE FROM entity_mentions WHERE memory_id=? AND entity_id IN (SELECT entity_id FROM entity_aliases WHERE kind=? AND key=?)",[local,body.kind.rawValue,body.key])
                    case .projectRejection:
                        guard try db.entityKind(local) == .project else {throw OSwindError.invalid("Incoming project correction needs a project owner")}
                        try execute("INSERT INTO entity_project_ignored VALUES(?,?) ON CONFLICT(memory_id,entity_id) DO NOTHING",[binding!.local,local])
                        try execute("DELETE FROM entity_mentions WHERE memory_id=? AND entity_id=?",[binding!.local,local])
                    default:throw OSwindError.invalid("Use the corresponding typed entity adapter")
                    }
                }
                _=try cache.retain(record,admit:admit);try cache.bindProjection(reference,references:references(binding),admit:admit)
                guard try cache.resolve(record.identity,content:nil,admit:{_ in}).encoded()==record.encoded() else {throw OSwindError.invalid("Incoming entity projection changed during admission")}
                let after=try cache.journal.state(for:record.identity.key)
                guard !after.isDeleted,after.heads.count==1,after.heads.first?.content==reference.content else {throw OSwindError.invalid("Incoming entity head changed during projection")}
                try SyncIncomingDependencyAudit.check([record],cache:cache);if let binding {try audit(binding)}
                try admission.withActive(for:library.mediaRootIdentity) {};return local
            }
        }
    }
}
