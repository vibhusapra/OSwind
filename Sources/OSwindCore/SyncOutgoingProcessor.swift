import Foundation
import CSQLite

enum SyncOutgoingStep:Equatable {case captured(Int),prepared(Int),bootstrapped(SyncCanonicalTable,Int),idle}

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
    var maximumObjects=512
    var maximumBytes=16*1024*1024
    var maximumDepth=32
    var captureByteLimit=4*1024*1024
    private var database:RoutineDatabase {queue.database}
    func step(limit:Int=128)throws->SyncOutgoingStep {
        guard queue.catalog.database.handle==cache.database.handle,queue.catalog.scope==cache.catalog.scope,(1...256).contains(limit),(1...4096).contains(maximumObjects),(1...256*1024*1024).contains(maximumBytes),(1...128).contains(maximumDepth) else {throw OSwindError.invalid("Invalid outgoing sync processor context or bounds")}
        // Selection and the selected step share the writer transaction, so no
        // peer/local connection can slip a mutation between inspection and work.
        return try SyncChangeCapture.transaction(database) {
            func any(_ table:String)throws->Bool {
                let row=try database.statement("SELECT EXISTS(SELECT 1 FROM "+table+")");defer {sqlite3_finalize(row)}
                guard sqlite3_step(row)==SQLITE_ROW else {throw database.error()};return sqlite3_column_int(row,0)==1
            }
            if try any("personal_sync_changes") {return .captured(try queue.stage(limit:limit,byteLimit:captureByteLimit))}
            if try any("personal_sync_work") {
                let batch=Batch(processor:self)
                let count=try queue.process(limit:limit) {values in
                    // Erasures never require reading deleted source content.
                    for value in values where value.deleted {
                        let state=try cache.journal.state(for:value.identity.key)
                        if !state.isDeleted {_=try cache.journal.delete(key:value.identity.key)}
                    }
                    for value in values where !value.deleted {_=try batch.prepare(value.identity)}
                }
                return .prepared(count)
            }
            for table in SyncCanonicalTable.allCases {
                let row=try database.statement("SELECT complete FROM personal_sync_identity_bootstrap WHERE table_name=?");defer {sqlite3_finalize(row)};database.bind(row,1,table.rawValue)
                let code=sqlite3_step(row);guard code==SQLITE_DONE || code==SQLITE_ROW else {throw database.error()}
                if code==SQLITE_DONE || sqlite3_column_int(row,0)==0 {return .bootstrapped(table,try queue.bootstrap(table,limit:limit).objects)}
            }
            // Even an idle call must validate generation, durability and schema.
            _=try queue.process(limit:limit) {_ in};return .idle
        }
    }
    private final class Batch {
        let processor:SyncOutgoingProcessor
        var prepared=[String:SyncPortableRecord](),visiting=Set<String>(),objects=0,bytes=0
        var db:RoutineDatabase {processor.database}
        var cache:SyncVersionStore {processor.cache}
        init(processor:SyncOutgoingProcessor) {self.processor=processor}
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
        var references:SyncPortableReferences {.init(identity:{try self.identity($0,$1)},source:{id,revision in
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
        })}
        @discardableResult func prepare(_ identity:SyncObjectIdentity)throws->SyncPortableRecord {
            try Task.checkCancellation();let digest=try identity.key.digest
            if let value=prepared[digest] {return value}
            guard objects<processor.maximumObjects,visiting.count<processor.maximumDepth,visiting.insert(digest).inserted else {throw OSwindError.unavailable("Outgoing dependency graph is cyclic or exceeds its transaction bound")}
            objects+=1;defer {visiting.remove(digest)}
            let row=try current(identity);try processor.admitRow(identity,row)
            guard try current(identity).encoded()==row.encoded() else {throw OSwindError.invalid("Outgoing row changed during policy admission")}
            let record=try SyncPortableExporter(references:references).record(identity:identity,row:row),data=try record.encoded()
            guard data.count<=processor.maximumBytes-bytes else {throw OSwindError.unavailable("Outgoing graph exceeds its typed byte budget")};bytes+=data.count
            for dependency in record.dependencies {
                if let content=dependency.content {
                    if try cache.record(.init(identity:dependency.identity,content:content),admit:processor.admitVersion)==nil {_=try prepare(dependency.identity)}
                    _=try cache.resolve(dependency.identity,content:content,admit:processor.admitVersion)
                }else {_=try prepare(dependency.identity)}
            }
            try processor.admitVersion(record)
            guard try current(identity).encoded()==row.encoded() else {throw OSwindError.invalid("Outgoing row changed during dependency preparation")}
            let ref=try record.reference,state=try cache.journal.state(for:identity.key)
            guard !state.isConflicted else {throw OSwindError.unavailable("Resolve sync conflicts explicitly before outgoing preparation")}
            func retain()throws {_=try cache.retain(record,admit:processor.admitVersion);try cache.bindProjection(ref,references:references,admit:processor.admitVersion)}
            if state.heads.count==1,state.heads[0].content==ref.content {try retain()}
            else {_=try cache.journal.put(key:identity.key,content:ref.content) {_ in try retain()}}
            prepared[digest]=record;return record
        }
    }
}
