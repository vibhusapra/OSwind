import Foundation
import CSQLite

enum SyncOutgoingStep:Equatable,Sendable {case captured(Int),prepared(Int),bootstrapped(SyncCanonicalTable,Int),idle}

/// Internal synchronous outgoing adapter over all canonical tables. The owning
/// library supplies current privacy admission and prepared media; no networking,
/// settings activation, enrollment or inference is performed here. Each step is
/// bounded and atomic. Historical versions must already exist or refuse exactly.
struct SyncOutgoingProcessor {
    let queue:SyncOutgoingWorkQueue
    let cache:SyncVersionStore
    let admitRow:(SyncObjectIdentity,SyncRowSnapshot)throws->Void
    let admitVersion:(SyncPortableRecord)throws->Void
    let media:(Memory)throws->[SyncMediaManifest]
    /// Required by future service delivery; nil retains the internal legacy adapter.
    /// The sink durably retains immutable manifest bytes before its revision.
    var retainTurnPublication:((SyncContentReference,Data)throws->Void)? = nil
    var withholding:(work:SyncWithheldWork,policy:String)? = nil
    var maximumObjects=512
    var maximumBytes=16*1024*1024
    var maximumDepth=32
    var captureByteLimit=4*1024*1024
    private var database:RoutineDatabase {queue.database}
    func step(limit:Int=128)throws->SyncOutgoingStep {
        guard queue.catalog.database.handle==cache.database.handle,queue.catalog.scope==cache.catalog.scope,(1...256).contains(limit),(1...4096).contains(maximumObjects),(1...256*1024*1024).contains(maximumBytes),(1...128).contains(maximumDepth) else {throw OSwindError.invalid("Invalid outgoing sync processor context or bounds")}
        if let withholding {
            guard withholding.work.catalog.scope==queue.catalog.scope,withholding.work.catalog.database.handle==database.handle else {throw OSwindError.invalid("Use the outgoing processor's owning withheld metadata")}
            try SyncProtocolLimits.digest(withholding.policy)
        }
        // Selection and the selected step share the writer transaction, so no
        // peer/local connection can slip a mutation between inspection and work.
        return try SyncChangeCapture.transaction(database) {
            func any(_ table:String)throws->Bool {
                let row=try database.statement("SELECT EXISTS(SELECT 1 FROM "+table+")");defer {sqlite3_finalize(row)}
                guard sqlite3_step(row)==SQLITE_ROW else {throw database.error()};return sqlite3_column_int(row,0)==1
            }
            if try any("personal_sync_changes") {return .captured(try queue.stage(limit:limit,byteLimit:captureByteLimit,identified:{changes in
                if let withholding {for change in changes {if let before=change.before {try withholding.work.wake(before)};if let after=change.after {try withholding.work.wake(after)}}}
            }))}
            if try any("personal_sync_work") {
                let batch=Batch(processor:self)
                let count=try queue.process(limit:limit) {values in
                    // Relationship retirements precede replacement lifetimes.
                    // Entity parents retire after live alias transfers, which
                    // otherwise cascade-delete aliases that remain live globally.
                    for value in values where value.deleted && value.identity.table != .entity {
                        try withholding?.work.remove(value.identity)
                        let state=try cache.journal.state(for:value.identity.key)
                        if !state.isDeleted {_=try cache.journal.delete(key:value.identity.key)}
                    }
                    for value in values where !value.deleted {
                        if let withholding {
                            do {
                                // A denied owner must roll back every dependency
                                // put/cache change it tentatively prepared. Do
                                // not reuse that rolled-back Batch's memoized rows.
                                try SyncChangeCapture.transaction(database) {_=try Batch(processor:self).prepare(value.identity)}
                                try withholding.work.remove(value.identity)
                            }catch let error as SyncPublicationPolicyDenied {
                                try withholding.work.park(value.identity,denied:error.identity ?? value.identity,policy:withholding.policy)
                            }
                        }else{_=try batch.prepare(value.identity)}
                    }
                    for value in values where value.deleted && value.identity.table == .entity {
                        try withholding?.work.remove(value.identity)
                        let state=try cache.journal.state(for:value.identity.key)
                        if !state.isDeleted {_=try cache.journal.delete(key:value.identity.key)}
                    }
                }
                return .prepared(count)
            }
            for table in SyncCanonicalTable.allCases {
                let row=try database.statement("SELECT complete FROM personal_sync_identity_bootstrap WHERE table_name=?");defer {sqlite3_finalize(row)};database.bind(row,1,table.rawValue)
                let code=sqlite3_step(row);guard code==SQLITE_DONE || code==SQLITE_ROW else {throw database.error()}
                if code==SQLITE_DONE || sqlite3_column_int(row,0)==0 {return .bootstrapped(table,try queue.bootstrap(table,limit:limit).objects)}
            }
            // Even an idle call must validate generation, durability and schema.
            try queue.validateIdle();return .idle
        }
    }
    private final class Batch {
        let processor:SyncOutgoingProcessor
        var prepared=[String:SyncPortableRecord](),visiting=Set<String>(),objects=0,bytes=0
        var db:RoutineDatabase {processor.database}
        var cache:SyncVersionStore {processor.cache}
        let historical:HistoricalEvidenceStore
        init(processor:SyncOutgoingProcessor) {self.processor=processor;historical=HistoricalEvidenceStore(database:processor.database)}
        func current(_ identity:SyncObjectIdentity)throws->SyncRowSnapshot {
            guard let object=try processor.queue.catalog.object(identity),!object.deleted,let primary=object.primary else {throw OSwindError.invalid("Outgoing dependency has no live local lifetime")}
            let schema=identity.table.schema,row=try db.statement("SELECT "+schema.snapshot("t")+" FROM "+identity.table.rawValue+" t WHERE "+schema.primary.map {"t.\($0) IS ?"}.joined(separator:" AND "));defer {sqlite3_finalize(row)}
            for (i,cell) in primary.enumerated() {
                switch cell {
                case .text(let data):data.withUnsafeBytes {_ = sqlite3_bind_text64(row,Int32(i+1),$0.baseAddress?.assumingMemoryBound(to:CChar.self),UInt64(data.count),db.transient,UInt8(SQLITE_UTF8))}
                case .integer(let value):sqlite3_bind_int64(row,Int32(i+1),value)
                default:throw OSwindError.invalid("Outgoing local primary storage differs")
                }
            }
            guard sqlite3_step(row)==SQLITE_ROW,let p=sqlite3_column_blob(row,0),sqlite3_column_bytes(row,0)>0,Int(sqlite3_column_bytes(row,0))<=SyncRowSnapshot.maximumBytes else {throw OSwindError.invalid("Outgoing current row is unavailable")}
            return try .decode(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))))
        }
        func identity(_ table:SyncCanonicalTable,_ primary:[SyncRowCell])throws->SyncObjectIdentity {
            // This is safe only after every raw lifetime intent has drained.
            // registerExisting verifies that invariant on every dependency.
            try processor.queue.catalog.registerExisting(table,primary:primary)
        }
        var references:SyncPortableReferences {
            var base=SyncPortableReferences(identity:{try self.identity($0,$1)},source:{id,revision in
            let identity=try self.identity(.source,[.text(Data(id.utf8))]);_=try self.prepare(identity)
            return try self.cache.sourceVersion(localID:id,revision:revision,admit:self.processor.admitVersion)
        },media:processor.media,recipe:{id,ordinal in
            _=try self.prepare(self.identity(.routine,[.text(Data(id.utf8))]))
            return try self.cache.recipeVersion(localID:id,ordinal:ordinal,admit:self.processor.admitVersion)
        },session:{memory in
            try self.cache.sessionBinding(localID:memory.id) {_ in
                let id=try self.identity(.source,[.text(Data(memory.id.utf8))]);try self.processor.admitRow(id,self.current(id))
            }
        },runRecipe:{run,recipe,ordinal in
            _=try self.prepare(self.identity(.routine,[.text(Data(recipe.utf8))]))
            return try self.cache.runRecipe(localRunID:run,recipeID:recipe,ordinal:ordinal,admit:self.processor.admitVersion)
        },runOriginal:{run in try RoutineRunOriginalStore(db:self.db).read(run)},erasedRunConversation:{try self.cache.erasedRunConversation(localRunID:$0)})
            base.recordingSourceBinding={memory in try self.cache.recordingSourceBinding(memory,admit:self.processor.admitVersion)}
            base.recordingSource={_,id,revision in
                try self.cache.currentRecordingSource(localID:id,revision:revision,prepare:{_=try self.prepare($0)},admit:self.processor.admitVersion)
            }
            base.recordingSession={session in
                try RecordedMeetingSchema.populateIfNeeded(self.db)
                let row=try self.db.statement("SELECT memory_id FROM recorded_meeting_sources WHERE grouped=1 AND recording_id=? ORDER BY memory_id LIMIT 1");defer {sqlite3_finalize(row)};self.db.bind(row,1,session)
                let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw self.db.error()}
                let id=self.db.text(row,0),identity=try self.identity(.source,[.text(Data(id.utf8))]),frame=try self.current(identity)
                try self.processor.admitRow(identity,frame)
                guard case .blob(let payload)=frame.cells[8] else {throw OSwindError.invalid("Recording scope source differs")}
                let memory=try JSONDecoder().decode(Memory.self,from:payload)
                guard memory.kind == .audio,memory.audioSessionID.map({Data($0.utf8)})==Data(session.utf8) else {throw OSwindError.unavailable("Recording scope changed during preparation")}
                if let token=try self.cache.sessionBinding(localID:id,admit:{_ in try self.processor.admitRow(identity,self.current(identity))}) {return token}
                return try SyncSessionToken(origin:identity.origin,localID:session)
            }
            return historical.decorating(base,admit:processor.admitVersion,verify:{value in
                guard case .source(let body)=value.record.body,try self.processor.media(value.memory)==body.media else {throw OSwindError.invalid("Historical outgoing media differs")}
            })
        }
        @discardableResult func prepare(_ identity:SyncObjectIdentity)throws->SyncPortableRecord {
            do {return try prepareAdmitted(identity)}catch let error as SyncPublicationPolicyDenied {throw SyncPublicationPolicyDenied(identity:error.identity ?? identity)}
        }
        private func prepareAdmitted(_ identity:SyncObjectIdentity)throws->SyncPortableRecord {
            try Task.checkCancellation();let digest=try identity.key.digest
            if let value=prepared[digest] {return value}
            guard objects<processor.maximumObjects,visiting.count<processor.maximumDepth,visiting.insert(digest).inserted else {throw OSwindError.unavailable("Outgoing dependency graph is cyclic or exceeds its transaction bound")}
            objects+=1;defer {visiting.remove(digest)}
            let row=try current(identity);try processor.admitRow(identity,row)
            guard try current(identity).encoded()==row.encoded() else {throw OSwindError.invalid("Outgoing row changed during policy admission")}
            let record=try SyncPortableExporter(references:references).record(identity:identity,row:row),data=try record.encoded()
            guard data.count<=processor.maximumBytes-bytes else {throw OSwindError.unavailable("Outgoing graph exceeds its typed byte budget")};bytes+=data.count
            for dependency in try record.liveDependencies(conversationIsErased:{try cache.isErasedOptionalConversation(record,identity:$0)},entityScopeIsErased:{try cache.isErasedOptionalEntityScope(record,identity:$0)}) {
                if let content=dependency.content {
                    if try cache.record(.init(identity:dependency.identity,content:content),admit:processor.admitVersion)==nil {_=try prepare(dependency.identity)}
                    _=try cache.resolve(dependency.identity,content:content,admit:processor.admitVersion)
                }else {_=try prepare(dependency.identity)}
            }
            try processor.admitVersion(record)
            guard try current(identity).encoded()==row.encoded() else {throw OSwindError.invalid("Outgoing row changed during dependency preparation")}
            let ref=try record.reference,state=try cache.journal.state(for:identity.key)
            guard !state.isConflicted else {throw OSwindError.unavailable("Resolve sync conflicts explicitly before outgoing preparation")}
            var publication:SyncContentReference?,publicationAudit:(()throws->Void)?,citationRows=[(SyncObjectIdentity,SyncRowSnapshot)]()
            if identity.table == .turn,let sink=processor.retainTurnPublication {
                guard row.cells.count==4,case .text(let local)=row.cells[0],let turn=String(data:local,encoding:.utf8) else {throw OSwindError.invalid("Outgoing answer primary differs")}
                let query=try db.statement("SELECT ordinal FROM chat_sources WHERE turn_id=? ORDER BY ordinal LIMIT 61");defer {sqlite3_finalize(query)};db.bind(query,1,turn)
                var citations=[SyncPortableRecord](),code=sqlite3_step(query)
                while code==SQLITE_ROW {
                    guard citations.count<60,sqlite3_column_type(query,0)==SQLITE_INTEGER,sqlite3_column_int64(query,0)==Int64(citations.count) else {throw OSwindError.invalid("Outgoing answer citation declaration is incomplete")}
                    let id=try self.identity(.conversationCitation,[.text(local),.integer(Int64(citations.count))]),snapshot=try current(id)
                    try processor.admitRow(id,snapshot)
                    let child=try SyncPortableExporter(references:references).record(identity:id,row:snapshot)
                    try processor.admitVersion(child);citations.append(child);citationRows.append((id,snapshot));code=sqlite3_step(query)
                }
                guard code==SQLITE_DONE else {throw db.error()}
                let manifest=try SyncTurnPublication(group:cache.journal.group,epoch:cache.journal.epoch,owner:ref,citations:citations),data=try manifest.encoded()
                guard data.count<=processor.maximumBytes-bytes else {throw OSwindError.unavailable("Outgoing publication exceeds its typed byte budget")};bytes+=data.count
                let proof=try manifest.reference;publication=proof;try sink(proof,data)
                publicationAudit={
                    let count=try self.db.statement("SELECT count(*) FROM chat_sources WHERE turn_id=?");defer {sqlite3_finalize(count)};self.db.bind(count,1,turn)
                    guard sqlite3_step(count)==SQLITE_ROW,sqlite3_column_int64(count,0)==Int64(citations.count) else {throw OSwindError.invalid("Outgoing citations changed during publication retention")}
                    for (id,snapshot) in citationRows {guard try self.current(id)==snapshot else {throw OSwindError.invalid("Outgoing citation changed during publication retention")}}
                    guard try self.current(identity)==row else {throw OSwindError.invalid("Outgoing answer changed during publication retention")}
                }
                try publicationAudit?()
            }
            func retain()throws {_=try cache.retain(record,admit:processor.admitVersion);try cache.bindProjection(ref,references:references,admit:processor.admitVersion)}
            if state.heads.count==1,state.heads[0].content==ref.content,state.heads[0].publication==publication {try retain()}
            else {_=try cache.journal.put(key:identity.key,content:ref.content,publication:publication) {_ in try retain()}}
            try publicationAudit?()
            prepared[digest]=record;return record
        }
    }
}
