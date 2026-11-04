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
    var projectionAdmission:((SyncObjectIdentity)throws->Void)? = nil
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
        let base=SyncPortableReferences(identity:{try cache.catalog.localIdentity($0,primary:$1)},source:{try cache.sourceVersion(localID:$0,revision:$1,admit:admit)},media:{_ in throw OSwindError.unavailable("Source projection uses its complete source/media adapter")},recipe:{try cache.recipeVersion(localID:$0,ordinal:$1,admit:admit)},session:{_ in throw OSwindError.unavailable("Source projection needs its original session binding")},runRecipe:{try cache.runRecipe(localRunID:$0,recipeID:$1,ordinal:$2,admit:admit)},runOriginal:{try RoutineRunOriginalStore(db:db).read($0)},erasedRunConversation:{try cache.erasedRunConversation(localRunID:$0)})
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
        for parent in body.sourceReferences {try ensureSource(parent,requestedBy:record,fetch:fetch,visiting:&visiting,remaining:&remaining)}
    }
    private func original(_ ref:SyncVersionReference,requestedBy:SyncPortableRecord,fetch:(SyncVersionReference)throws->SyncPortableRecord)throws->HistoricalEvidence {
        var visiting=Set<String>(),remaining=512;try ensureSource(ref,requestedBy:requestedBy,fetch:fetch,visiting:&visiting,remaining:&remaining)
        return try history.adopt(ref,cache:cache,pathsFor:pathsFor,admit:admit,verifyMedia:verifyMedia)
    }
    private func recordingScope(_ reference:SyncVersionReference,record:SyncPortableRecord,fetch:(SyncVersionReference)throws->SyncPortableRecord)throws->RecordingScope {
        let sourceID=try id(reference.identity),evidence=try original(reference,requestedBy:record,fetch:fetch)
        guard evidence.memory.kind == .audio else {throw OSwindError.invalid("Recording scope original is not audio")}
        return try .init(sourceID:sourceID,revision:evidence.memory.evidenceHash)
    }
    private struct RecipeProjection {let definition:RoutineDefinition,revision:Int,nextDue:Date}
    private func projectRecipe(_ body:SyncRoutineBody,record:SyncPortableRecord,local:String)throws->RecipeProjection {
        let current=try db.routine(local)
        guard try cache.catalog.object(record.identity)==nil || current != nil else {throw OSwindError.unavailable("Incoming recipe's native owner disappeared")}
        if current==nil {guard try db.eraseCount("SELECT count(*) FROM routines")<100 else {throw OSwindError.unavailable("At most 100 routines can be saved")}}
        guard (current?.revision ?? 0)<Int.max-1 else {throw OSwindError.invalid("Incoming recipe revision limit reached")}
        let value=try body.projected(id:local),revision=(current?.revision ?? 0)+1,next=try value.schedule.occurrence(relativeTo:Date(),next:true)
        try cache.catalog.applyPeer(record.identity,primary:[.text(Data(local.utf8))]) {
            let row=try db.statement("INSERT INTO routines(id,revision,enabled,next_due,payload) VALUES(?,?,0,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,enabled=0,next_due=excluded.next_due,payload=excluded.payload");defer {sqlite3_finalize(row)}
            db.bind(row,1,local);sqlite3_bind_int64(row,2,Int64(revision));sqlite3_bind_double(row,3,next.timeIntervalSince1970);try db.bind(row,4,json:value);try db.done(row)
        }
        return .init(definition:value,revision:revision,nextDue:next)
    }
    private func auditRecipe(_ expected:RecipeProjection,local:String)throws {
        guard let actual=try db.routine(local),try SyncProtocolLimits.encode(actual.definition)==SyncProtocolLimits.encode(expected.definition),actual.revision==expected.revision,actual.nextDue==expected.nextDue else {throw OSwindError.invalid("Incoming recipe's local projection changed during admission")}
        let row=try db.statement("SELECT enabled FROM routines WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,local)
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_int(row,0)==0,!actual.definition.enabled,!actual.definition.allowRemote,!actual.definition.ai.allowRemote else {throw OSwindError.invalid("Incoming recipe cannot acquire local execution authority")}
    }
    private struct RunProjection {let original:RoutineRunOriginal,frame:SyncRowSnapshot}
    private func projectRun(_ body:SyncRoutineRunBody,record:SyncPortableRecord,local:String,fetch:(SyncVersionReference)throws->SyncPortableRecord)throws->RunProjection {
        let recipeID=try id(body.recipe.routine),store=RoutineRunOriginalStore(db:db)
        guard let recipe=try db.routine(recipeID) else {throw OSwindError.unavailable("Prepare the incoming recipe before its run")}
        _=try cache.resolve(body.recipe.routine,content:nil,admit:admit)
        let previous=try db.run(local),prior=try store.read(local)
        if let previous,prior==nil {throw OSwindError.unavailable(previous.status == .running ? "Review the active local run before peer replacement":"Existing run has no admitted peer provenance")}
        if let prior,case .routineRun(let old)=prior.record.body {guard try SyncProtocolLimits.encode(old.recipe)==SyncProtocolLimits.encode(body.recipe) else {throw OSwindError.invalid("A run cannot change its original recipe")}}
        let definition:SyncPortableRecord?
        if let content=body.recipe.definition {
            let reference=SyncVersionReference(identity:body.recipe.routine,content:content)
            if let stored=try cache.record(reference,admit:admit) {definition=stored}
            else {let packet=try fetch(reference);guard try packet.reference==reference else {throw OSwindError.invalid("Fetched recipe is not its requested version")};_=try cache.retain(packet,requiredBy:record,admit:admit);definition=packet}
        }else{definition=nil}
        let original=RoutineRunOriginal(record:record,definition:definition);let payload=try original.encoded(),ordinal=previous?.revision ?? recipe.revision,filter=try body.filter.projected(erasedEntity:{try cache.projectErasedFilterScope($0)},recordingSource:{try self.recordingScope($0,record:record,fetch:fetch)}) {try id($0)},scope=try SyncProtocolLimits.encode(filter)
        let chat:String?
        if let conversation=body.conversation,try !cache.isErasedOptionalConversation(record,identity:conversation) {chat=try id(conversation)}else{chat=nil}
        func text(_ value:String)->SyncRowCell {.text(Data(value.utf8))}
        let frame=try SyncRowSnapshot([text(local),text(recipeID),.integer(Int64(ordinal)),.real(body.scheduledAt.timeIntervalSince1970.bitPattern),.real(body.started.timeIntervalSince1970.bitPattern),body.finished.map{.real($0.timeIntervalSince1970.bitPattern)} ?? .null,text(body.trigger.rawValue),text(body.projectedStatus.rawValue),chat.map(text) ?? .null,body.message.map(text) ?? .null,.blob(scope)])
        try library.incomingRunProjection.withRun(frame,payload:payload) {
            try cache.catalog.applyPeer(record.identity,primary:[text(local)]) {
                let row=try db.statement("INSERT INTO routine_runs(id,routine_id,revision,scheduled_at,started,finished,trigger,status,chat_id,message,scope) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET routine_id=excluded.routine_id,revision=excluded.revision,scheduled_at=excluded.scheduled_at,started=excluded.started,finished=excluded.finished,trigger=excluded.trigger,status=excluded.status,chat_id=excluded.chat_id,message=excluded.message,scope=excluded.scope");defer {sqlite3_finalize(row)}
                db.bind(row,1,local);db.bind(row,2,recipeID);sqlite3_bind_int64(row,3,Int64(ordinal));sqlite3_bind_double(row,4,body.scheduledAt.timeIntervalSince1970);sqlite3_bind_double(row,5,body.started.timeIntervalSince1970);if let end=body.finished {sqlite3_bind_double(row,6,end.timeIntervalSince1970)};db.bind(row,7,body.trigger.rawValue);db.bind(row,8,body.projectedStatus.rawValue);db.bind(row,9,chat);db.bind(row,10,body.message);scope.withUnsafeBytes {_=sqlite3_bind_blob(row,11,$0.baseAddress,Int32(scope.count),db.transient)};try db.done(row)
                try store.replace(local,payload:payload,frame:frame)
            }
        }
        return .init(original:original,frame:frame)
    }
    private func auditRun(_ expected:RunProjection,local:String)throws {
        let store=RoutineRunOriginalStore(db:db)
        guard let actual=try store.read(local),try actual.encoded()==expected.original.encoded(),try store.frame(local)==expected.frame else {throw OSwindError.invalid("Incoming run or original provenance changed during admission")}
    }
    /// Journal barrier, native retirement, cache protection and the reservation
    /// share one transaction, including a direct internal retry after receipt.
    func applyDeletion(_ change:SyncJournalChange,admission:MediaAdmissionLease)throws {
        guard change.after.isDeleted else {throw OSwindError.invalid("Use the incoming deletion barrier")}
        try applyDeletionBarrier(change.revision.key,admission:admission)
    }
    /// Retry an already committed barrier without inventing a revision or
    /// publishing another local tombstone. Only the actual stored state grants
    /// authority to this same-connection native/cache retirement path.
    func applyDeletionBarrier(_ key:SyncObjectKey,admission:MediaAdmissionLease)throws {
        try Task.checkCancellation()
        try admission.withActive(for:library.mediaRootIdentity) {}
        try library.withRoutineDatabase {connection in
            guard connection.handle==db.handle,try cache.journal.state(for:key).isDeleted else {throw OSwindError.invalid("Use the incoming deletion library's own connection and barrier")}
            try erasureCancellable(db) {try SyncChangeCapture.transaction(db) {
                try cache.validateIncomingDeletionContext()
                try SyncDerivedRetirement.collect(cache:cache,root:key,body:{
                    try applyDeletionKey(key,admission:admission)
                    try cache.finishDeletedObject(key)
                },retire:{key in try applyDeletionKey(key,admission:admission)})
                try cache.validateIncomingDeletionContext()
                try Task.checkCancellation()
                try admission.withActive(for:library.mediaRootIdentity) {}
            }}
        }
    }
    private func applyDeletionKey(_ key:SyncObjectKey,admission:MediaAdmissionLease)throws {
        if key.kind == .source {
            try cache.catalog.deletePeerKey(key,journal:cache.journal) {object in
                let nativeKey:Data?
                if let object {guard let primary=object.primary,primary.count==1,case .text(let bytes)=primary[0] else {throw OSwindError.invalid("Incoming source erasure key differs")};nativeKey=bytes}else{nativeKey=nil}
                defer {try? db.clearErasureSelection()}
                let affected=try db.preparePeerSourceErasure(key.digest,activeKey:nativeKey)
                _=try library.incomingSourceErasure.eraseSelected(db,revokingObject:key.digest)
                try SyncDerivedRetirement.enqueue(affected,db:db)
            }
        }else if SyncIncomingEntityWriter.tables.contains(where:{$0.kind==key.kind}) {
            try SyncIncomingEntityWriter(library:library,cache:cache,admit:admit,newID:newID).applyDeletionKey(key,admission:admission)
        }else if SyncIncomingMetadataDeletion.accepts(key.kind) {
            try SyncIncomingMetadataDeletion(cache:cache,beforeConversationDeletion:detachRunsFromConversation).applyKey(key)
        }else {
            try retireRecapCitation(key)
        }
    }
    /// Detach nullable links under the exact native-run permit before the FK
    /// fires. Otherwise its ordinary update invalidates the retained original.
    /// Batches follow rowid through the existing chat index, with bounded memory.
    private func detachRunsFromConversation(_ object:SyncLocalObject)throws {
        guard object.identity.table == .conversation,let primary=object.primary,primary.count==1,case .text(let bytes)=primary[0],let chat=String(data:bytes,encoding:.utf8),try cache.journal.state(for:object.identity.key).isDeleted else {throw OSwindError.invalid("Use the erased optional conversation's exact local owner")}
        let store=RoutineRunOriginalStore(db:db)
        try store.forEachLinkedRun(chatID:chat) {local,original,before in
            let identity=try cache.catalog.localIdentity(.routineRun,primary:[.text(Data(local.utf8))])
            if try cache.journal.state(for:identity.key).isDeleted {return}
            let packet=try cache.resolve(identity,content:nil,admit:{_ in})
            guard case .routineRun(let body)=packet.body,body.conversation==object.identity else {throw OSwindError.unavailable("Prepare the run's exact optional-conversation projection before erasure")}
            try cache.catalog.applyPeer(identity,primary:[.text(Data(local.utf8))]) {
                _=try library.detachRunOriginalConversation(local,from:chat,original:original,before:before,db:db)
            }
            // The exact original supplies its recipe. Erasure must not invoke
            // an unrelated body-policy callback through eager recipe lookup.
            var deletionReferences=references;deletionReferences.runRecipe=nil
            try cache.bindProjection(packet.reference,references:deletionReferences,admit:{_ in})
        }
    }
    /// Content-free recap deletion. The old global citation retires even when
    /// its current owner independently requires the same native derived row.
    private func retireRecapCitation(_ key:SyncObjectKey)throws {
        guard key.kind == .recapCitation else {throw OSwindError.invalid("Use the corresponding typed deletion adapter")}
        try cache.catalog.retireDerivedRecap(key,journal:cache.journal) {object in
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
    }
    @discardableResult func apply(_ record:SyncPortableRecord,admission:MediaAdmissionLease,fetchExactSource:(SyncVersionReference)throws->SyncPortableRecord)throws->String {
        // Existing internal callers consume local IDs. New service code should
        // use the explicit outcome; an empty string is never a native owner.
        switch try applyOutcome(record,admission:admission,fetchExactSource:fetchExactSource) {
        case .projected(let local):return local
        case .retired:return ""
        }
    }
    func applyOutcome(_ record:SyncPortableRecord,admission:MediaAdmissionLease,fetchExactSource:(SyncVersionReference)throws->SyncPortableRecord)throws->SyncIncomingProjectionOutcome {
        try Task.checkCancellation();try admission.withActive(for:library.mediaRootIdentity) {}
        return try library.withRoutineDatabase {connection in
            guard connection.handle==db.handle else {throw OSwindError.invalid("Use the incoming library's own connection")}
            return try SyncChangeCapture.transaction(db) {
                try cache.validateIncomingDeletionContext();try record.validate()
                let state=try cache.journal.state(for:record.identity.key),reference=try record.reference
                guard !state.isDeleted,state.heads.contains(where:{$0.content==reference.content}) else {throw OSwindError.unavailable("Admit the exact incoming head before projection")}
                let erased=try record.erasedParents(cache:cache)
                if !erased.isEmpty {return try retireLate(record,parents:erased,admission:admission)}
                try projectionAdmission?(record.identity)
                guard state.heads.count==1 else {throw OSwindError.unavailable("Review incoming conflicts before projection")}
                var local=""
                try SyncDerivedRetirement.collect(cache:cache,root:record.identity.key,deleting:false,body:{
                    local=try project(record,admission:admission,fetchExactSource:fetchExactSource)
                },retire:{key in try applyDeletionKey(key,admission:admission)})
                try cache.validateIncomingDeletionContext();try Task.checkCancellation();try admission.withActive(for:library.mediaRootIdentity) {}
                return .projected(local)
            }
        }
    }
    private func retireLate(_ record:SyncPortableRecord,parents:[SyncRetiredDependency],admission:MediaAdmissionLease)throws->SyncIncomingProjectionOutcome {
        let key=try record.identity.key,causes=Set(parents.map(\.key))
        // No body/media policy or fetch callback is invoked for retired data.
        // Its exact canonical bytes already match an authenticated stored head;
        // only opaque metadata and genuine deletion revisions are retained.
        let deletion=try cache.journal.delete(key:key) {try applyDeletion($0,admission:admission)}
        for parent in parents {
            guard parent.clock.counters.allSatisfy({(deletion.context.counters[$0.key] ?? 0)>=$0.value}),try cache.journal.state(for:parent.key).isDeleted else {throw OSwindError.invalid("Late retirement lost its admitted dependency barrier")}
        }
        let owners=try Set(record.ownersOfErasedEvidence(causes)).sorted(by:SyncPortableRecord.retirementOrder)
        for owner in owners where owner != key {
            if try cache.journal.state(for:owner).isDeleted {try applyDeletionBarrier(owner,admission:admission)}
            else {
                // Root deletion includes every admitted/conflicting root head.
                // Observe it before publishing a different object's barrier.
                try cache.journal.observeAppliedRoot(key)
                _=try cache.journal.delete(key:owner) {try applyDeletion($0,admission:admission)}
            }
        }
        guard try cache.journal.state(for:key).isDeleted else {throw OSwindError.invalid("Late incoming lifetime was not retired")}
        try cache.validateIncomingDeletionContext();try Task.checkCancellation();try admission.withActive(for:library.mediaRootIdentity) {}
        return .retired(key:key,parents:parents.map(\.key))
    }
    private func project(_ record:SyncPortableRecord,admission:MediaAdmissionLease,fetchExactSource:(SyncVersionReference)throws->SyncPortableRecord)throws->String {
        // The caller reserves media BEFORE journal/SQLite locks, then retains
        // this reservation through admission. Acquiring it here can deadlock
        // against erasure holding the exclusive lease while waiting for SQLite.
        if case .source=record.body {
            return try SyncIncomingSourceWriter(library:library,cache:cache,admit:admit,pathsFor:pathsFor,admitMedia:admitMedia,newID:newID).apply(record,admission:admission,fetchExactSource:fetchExactSource)
        }
        if SyncIncomingEntityWriter.tables.contains(record.identity.table) {
            return try SyncIncomingEntityWriter(library:library,cache:cache,admit:admit,newID:newID).apply(record,admission:admission,fetchExactSource:fetchExactSource)
        }
        try admission.withActive(for:library.mediaRootIdentity) {}
        return try library.withRoutineDatabase {connection in
            guard connection.handle==db.handle else {throw OSwindError.invalid("Use the incoming library's own connection")}
            return try SyncChangeCapture.transaction(db) {
                try record.validate();let reference=try record.reference,state=try cache.journal.state(for:record.identity.key)
                guard !state.isDeleted,state.heads.count==1,state.heads.first?.content==reference.content else {throw OSwindError.unavailable("Admit one reviewed incoming head before projection; conflicts remain explicit")}
                try admit(record);var local="",historical:HistoricalEvidence?,recipeProjection:RecipeProjection?,runProjection:RunProjection?
                switch record.body {
                case .routineRun(let body):
                    local=try id(record.identity,create:true);runProjection=try projectRun(body,record:record,local:local,fetch:fetchExactSource)
                case .routine(let body):
                    local=try id(record.identity,create:true);recipeProjection=try projectRecipe(body,record:record,local:local)
                case .conversation(let body):
                    local=try id(record.identity,create:true)
                    try cache.catalog.applyPeer(record.identity,primary:[.text(Data(local.utf8))]) {
                        let row=try db.statement("INSERT INTO chat_sessions(id,title,created,updated) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,created=excluded.created,updated=excluded.updated");defer {sqlite3_finalize(row)}
                        db.bind(row,1,local);db.bind(row,2,body.title);sqlite3_bind_double(row,3,body.created.timeIntervalSince1970);sqlite3_bind_double(row,4,body.updated.timeIntervalSince1970);try db.done(row)
                    }
                case .turn(let body):
                    local=try id(record.identity,create:true);let conversation=try id(body.conversation)
                    let value=ChatPayload(question:body.question,text:body.text,provider:body.provider,duration:body.duration,warnings:body.warnings,filter:try body.filter.projected(erasedEntity:{try cache.projectErasedFilterScope($0)},recordingSource:{try self.recordingScope($0,record:record,fetch:fetchExactSource)}) {try id($0)},timeZone:body.timeZone)
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
                if let recipeProjection {try auditRecipe(recipeProjection,local:local)}
                if let runProjection {try auditRun(runProjection,local:local)}
                try admission.withActive(for:library.mediaRootIdentity) {};return local
            }
        }
    }
}
