import Foundation
import CSQLite

/// A caller's current local policy may throw this explicit signal. Other errors
/// and cancellation remain failures, rather than becoming successful receipts.
struct SyncPublicationPolicyDenied:Error {}
struct SyncPublicationAdmissionResult {
    let receipt:SyncReceiveResult
    let publications:[SyncPublicationOutcome]
}

/// Internal owning-connection dispatcher and bounded restart worker. The caller
/// supplies authenticated journal membership, a trusted encrypted local inbox,
/// current policy/media adapters and a media lease reserved before SQLite locks.
/// No public enrollment, folder watcher, remote provider or capture is enabled.
struct SyncPublicationAdmission {
    let queue:SyncPublicationQueue
    let writer:SyncIncomingConversationWriter
    let inbox:SyncObjectFolder
    var cache:SyncVersionStore {queue.cache}
    private func declaration(_ state:SyncRegister)throws->SyncTurnPublication? {
        guard state.heads.count==1,let reference=state.heads[0].publication,let bytes=try inbox.content(reference) else {return nil}
        let value=try SyncTurnPublication.decode(bytes,expected:reference)
        guard value.group==cache.journal.group,value.epoch==cache.journal.epoch,try value.owner.identity.key==state.key,value.owner.content==state.heads[0].content else {throw OSwindError.invalid("Queued publication differs from its trusted current head")};return value
    }
    private func dependencies(_ publication:SyncTurnPublication?,owner:SyncPortableRecord?)throws->[SyncObjectKey] {
        var result=[SyncObjectKey]()
        if let owner,case .turn(let body)=owner.body {result.append(try body.conversation.key)}
        for citation in publication?.citations ?? [] {
            guard case .conversationCitation(let body)=citation.body else {throw OSwindError.invalid("Invalid queued citation")}
            result += [try citation.identity.key,try body.link.source.identity.key]
        };return result
    }
    /// Whole-source erasure purges its native graph/originals and durably stages
    /// associated media cleanup; the owning service must drain it after leases.
    /// Withdraw affected answer projections first so the ordinary native FK /
    /// derived-retirement collector cannot mistake version invalidation for a
    /// permanent deletion of every independent future/concurrent owner head.
    private func withdrawSourceDependents(_ change:SyncJournalChange,admission:MediaAdmissionLease)throws->[SyncPublicationOutcome] {
        let key=change.revision.key,db=cache.database
        guard key.kind == .source,change.after.isDeleted else {return []}
        let local=try cache.catalog.object(for:key),activeKey:Data?
        if let local,!local.deleted,let primary=local.primary,primary.count==1,case .text(let bytes)=primary[0] {activeKey=bytes}else {activeKey=nil}
        let selected=try db.preparePeerSourceErasure(key.digest,activeKey:activeKey);defer {try? db.clearErasureSelection()}
        var owners=[String:SyncObjectIdentity]()
        func include(_ owner:SyncObjectIdentity)throws {
            guard owner.table == .turn else {return}
            owners[try owner.key.digest]=owner
            guard owners.count<=SyncPublicationQueue.maximumJobs else {throw OSwindError.unavailable("Source withdrawal exceeds durable publication capacity")}
        }
        for owner in selected {try Task.checkCancellation();try include(owner)}
        let affected=try db.statement("SELECT id FROM chat_turns WHERE id IN (\(RoutineDatabase.affectedTurns)) LIMIT 4097");defer {sqlite3_finalize(affected)}
        var code=sqlite3_step(affected)
        while code==SQLITE_ROW {
            try Task.checkCancellation()
            let size=Int(sqlite3_column_bytes(affected,0))
            guard sqlite3_column_type(affected,0)==SQLITE_TEXT,size>0,size<=SyncProtocolLimits.operationBytes,let pointer=sqlite3_column_text(affected,0) else {throw OSwindError.database("Source withdrawal answer key differs")}
            if let owner=try cache.catalog.preparedIdentity(.turn,primary:[.text(Data(bytes:pointer,count:size))]) {try include(owner)}
            code=sqlite3_step(affected)
        };guard code==SQLITE_DONE else {throw db.error()}
        let contiguous=try cache.journal.cursor(for:change.revision.dot.replica)==change.revision.dot.counter-1
        let appliedContext=try queue.hasApplied(change.revision.context)
        let reason:SyncPublicationPendingReason=contiguous && appliedContext ? .erasedEvidence:.causalGap
        // A native-only title scrub would invalidate the conversation's exact
        // canonical binding and block independent later answers. Publish a real
        // redacted metadata revision, causally after the authentic erasure root.
        // Construct it from dates/identity and a fixed title; never retain the
        // erased title, invoke body policy, fetch originals or admit media.
        let chats=try db.statement("SELECT id,created,updated FROM chat_sessions WHERE title!='Conversation' AND id IN (SELECT session_id FROM chat_turns WHERE id IN (\(RoutineDatabase.affectedTurns))) LIMIT 4097");defer {sqlite3_finalize(chats)}
        var redactions=[SyncPortableRecord]();code=sqlite3_step(chats)
        while code==SQLITE_ROW {
            let size=Int(sqlite3_column_bytes(chats,0))
            guard redactions.count<SyncPublicationQueue.maximumJobs,sqlite3_column_type(chats,0)==SQLITE_TEXT,size>0,size<=SyncProtocolLimits.operationBytes,let pointer=sqlite3_column_text(chats,0),let identity=try cache.catalog.preparedIdentity(.conversation,primary:[.text(Data(bytes:pointer,count:size))]) else {throw OSwindError.unavailable("Prepare bounded source-erasure conversation identities")}
            guard [SQLITE_INTEGER,SQLITE_FLOAT].contains(sqlite3_column_type(chats,1)),[SQLITE_INTEGER,SQLITE_FLOAT].contains(sqlite3_column_type(chats,2)) else {throw OSwindError.database("Source redaction requires a native numeric date; do not coerce malformed storage")}
            let created=sqlite3_column_double(chats,1),updated=sqlite3_column_double(chats,2)
            guard created.isFinite,updated.isFinite else {throw OSwindError.database("Source redaction requires a finite native numeric date")}
            let record=try SyncPortableRecord(identity:identity,body:.conversation(.init(title:"Conversation",created:Date(timeIntervalSince1970:created),updated:Date(timeIntervalSince1970:updated))))
            redactions.append(record);code=sqlite3_step(chats)
        };guard code==SQLITE_DONE else {throw db.error()}
        if !redactions.isEmpty {
            try cache.journal.observeAppliedRoot(key)
            let eraser=SyncIncomingConversationWriter(library:writer.library,cache:cache,admit:{_ in},pathsFor:{_,_ in throw OSwindError.invalid("Redacted conversation metadata cannot contain media")},admitMedia:{_,_,_ in throw OSwindError.invalid("Redacted conversation metadata cannot admit media")})
            for record in redactions {
                try Task.checkCancellation();try inbox.publishContent(record.encoded(),reference:record.reference.content)
                _=try cache.journal.put(key:record.identity.key,content:record.reference.content) {_ in
                    _=try eraser.apply(record,admission:admission,fetchExactSource:{_ in throw OSwindError.invalid("Redacted conversation metadata cannot fetch evidence")})
                }
            }
        }
        var outcomes=[SyncPublicationOutcome]()
        for owner in owners.sorted(by:{$0.key<$1.key}).map(\.value) {
            try Task.checkCancellation();let state=try cache.journal.state(for:owner.key)
            if state.isDeleted {try queue.retire(owner.key);continue}
            guard !state.heads.isEmpty else {continue}
            try queue.stage(owner,reason:reason,dependencies:[key]);try queue.retractWithheldProjection(owner)
            outcomes.append(.withheld(reason == .causalGap ? .causalGap:.erasedEvidence))
        }
        return outcomes
    }
    private func offer(_ identity:SyncObjectIdentity,citation:SyncPortableRecord?=nil,admission:MediaAdmissionLease,fetchSource:(SyncVersionReference)throws->SyncPortableRecord)throws->SyncPublicationOutcome {
        try queue.context();let key=try identity.key,state=try cache.journal.state(for:key)
        if state.isDeleted {try writer.applyDeletionBarrier(key,admission:admission);try queue.retire(key);return .retired(key)}
        if try queue.deferCausalGap(identity) {return .withheld(.causalGap)}
        if state.isConflicted {try queue.stage(identity,reason:.conflict);try queue.retractWithheldProjection(identity);return .withheld(.conflict)}
        guard let head=state.preferred,let content=head.content else {try queue.stage(identity,reason:.missingOwner);return .withheld(.missingOwner)}
        let reference=SyncVersionReference(identity:identity,content:content)
        guard let bytes=try inbox.content(content) else {try queue.stage(identity,reason:.missingOwnerContent);try queue.retractWithheldProjection(identity);return .withheld(.missingOwnerContent)}
        let owner=try SyncPortableRecord.decode(bytes,expected:reference),publication=try declaration(state)
        // A received unlisted child is not work on the independent owner. Check
        // membership before quota checks so it cannot consume owner capacity or
        // turn its completed binding into a pending/failed status.
        if let citation,let publication,try !publication.citations.contains(where:{try $0.reference==citation.reference}) {return .withheld(.unlistedCitation)}
        let parents=try dependencies(publication,owner:owner)
        // Storage pressure must not precede authentic evidence retirement.
        // Preflight a genuine deletion using the same declared ownership set.
        let erased=try ([key]+parents).contains{try cache.journal.state(for:$0).isDeleted}
        if !erased,try !queue.hasBindingCapacity(key) {try queue.stage(identity,reason:.storagePressure,dependencies:parents);try queue.retractWithheldProjection(identity);return .withheld(.storagePressure)}
        let coordinator=SyncIncomingTurnPublicationWriter(writer:writer,dependencyRetirement:.currentVersion),outcome:SyncPublicationOutcome
        do {
            outcome=try SyncChangeCapture.transaction(cache.database) {
                let value:SyncPublicationOutcome
                if let citation {
                    value=try coordinator.applyCitation(citation,admission:admission,fetchManifest:{try inbox.content($0)},fetchRecord:{ref in ref==reference ? owner:try fetchSource(ref)})
                }else {value=try coordinator.apply(owner,admission:admission,fetchManifest:{try inbox.content($0)},fetchExactSource:fetchSource)}
                if case .projected=value {guard let publication else {throw OSwindError.invalid("Complete publication declaration disappeared")};try queue.complete(identity,publication:publication)}
                return value
            }
        }catch is SyncPublicationPolicyDenied {
            try queue.stage(identity,reason:.policyDenied,dependencies:parents);try queue.retractWithheldProjection(identity);return .withheld(.policyDenied)
        }
        switch outcome {
        case .projected:break
        case .retired:try queue.retire(key)
        case .withheld(let reason):if reason != .unlistedCitation {try queue.stage(identity,reason:try .init(reason),dependencies:parents);try queue.retractWithheldProjection(identity)}
        };return outcome
    }
    /// The immutable encrypted body is retained before receipt. If admission or
    /// capacity fails, the journal/queue/native transaction rolls back together;
    /// the local content space may retain an unreferenced encrypted object.
    func receive(_ operation:SyncRevision,record:SyncPortableRecord?,admission:MediaAdmissionLease,fetchSource:(SyncVersionReference)throws->SyncPortableRecord)throws->SyncPublicationAdmissionResult {
        try admission.withActive(for:writer.library.mediaRootIdentity) {}
        guard writer.cache.database.handle==cache.database.handle else {throw OSwindError.invalid("Use one publication admission connection")}
        if operation.mutation == .put {
            guard let record,try record.identity.key==operation.key,try record.reference.content==operation.content else {throw OSwindError.invalid("Received publication record differs from its operation")}
            try inbox.publishContent(record.encoded(),reference:record.reference.content)
        }else {guard record==nil else {throw OSwindError.invalid("A deletion must remain body-free")}}
        return try writer.library.withRoutineDatabase {connection in
            guard connection.handle==cache.database.handle else {throw OSwindError.invalid("Use the publication library's own connection")}
            try queue.context();var outcomes=[SyncPublicationOutcome]()
            let received=try cache.journal.receive(operation,contentAvailable:{try inbox.content($0) != nil}) {change in
                if change.after.isDeleted {
                    outcomes += try withdrawSourceDependents(change,admission:admission)
                    if let owner=try queue.completedOwner(ofCitation:change.revision.key) {
                        let contiguous=try cache.journal.cursor(for:change.revision.dot.replica)==change.revision.dot.counter-1
                        if contiguous,try queue.hasApplied(change.revision.context) {
                            try queue.stage(owner,reason:.erasedEvidence,dependencies:[change.revision.key])
                            try queue.retractWithheldProjection(owner);outcomes.append(.withheld(.erasedEvidence))
                        }else {
                            try queue.stage(owner,reason:.causalGap,dependencies:[change.revision.key])
                            try queue.retractWithheldProjection(owner);outcomes.append(.withheld(.causalGap))
                        }
                    }
                    try writer.applyDeletion(change,admission:admission)
                    if change.revision.key.kind == .turn {try queue.retire(change.revision.key)}
                }else {
                    // The journal can drain several now-contiguous operations.
                    // Resolve each callback's own bytes, never the outer packet.
                    guard let content=change.revision.content,let bytes=try inbox.content(content) else {throw OSwindError.invalid("Received durable content disappeared")}
                    let packet=try SyncPortableRecord.decode(bytes)
                    guard try packet.identity.key==change.revision.key,try packet.reference.content==content else {throw OSwindError.invalid("Journal callback body differs")}
                    switch packet.body {
                    case .turn:outcomes.append(try offer(packet.identity,admission:admission,fetchSource:fetchSource))
                    case .conversationCitation(let body):
                        // A new version of an actually declared native child
                        // must recheck its old owner's complete declaration.
                        // Its incoming claimed owner is not reverse-lookup
                        // authority; unrelated unlisted child IDs still cannot
                        // consume work or withdraw an independent publication.
                        if let previous=try queue.completedOwner(ofCitation:packet.identity.key) {
                            outcomes.append(try offer(previous,admission:admission,fetchSource:fetchSource))
                            if previous != body.owner {outcomes.append(try offer(body.owner,citation:packet,admission:admission,fetchSource:fetchSource))}
                        }else {outcomes.append(try offer(body.owner,citation:packet,admission:admission,fetchSource:fetchSource))}
                    default:_=try writer.apply(packet,admission:admission,fetchExactSource:fetchSource)
                    }
                }
                try queue.wake(change.revision.key)
            }
            // A previously applied early deletion may drain without another
            // callback once predecessors arrive. Wake its bounded reason bucket
            // after cursor progress so durable work can recheck those cursors.
            if received.applied>0 {_=try queue.wakeReason(.causalGap)}
            try admission.withActive(for:writer.library.mediaRootIdentity) {};return .init(receipt:received,publications:outcomes)
        }
    }
    /// The content-arrival event is explicit and authenticated by the supplied
    /// hash. Wake only matching declarations, then caller runs a bounded retry.
    func retainDeclaration(_ bytes:Data,reference:SyncContentReference)throws {
        let value=try SyncTurnPublication.decode(bytes,expected:reference)
        guard value.group==cache.journal.group,value.epoch==cache.journal.epoch else {throw OSwindError.invalid("Declaration belongs to another trusted namespace")}
        try inbox.publishContent(bytes,reference:reference)
        try writer.library.withRoutineDatabase {connection in guard connection.handle==cache.database.handle else {throw OSwindError.invalid("Use the declaration library connection")};try queue.wakeDeclaration(reference)}
    }
    func retry(limit:Int=64,admission:MediaAdmissionLease,fetchSource:(SyncVersionReference)throws->SyncPortableRecord)throws->[SyncPublicationOutcome] {
        try admission.withActive(for:writer.library.mediaRootIdentity) {}
        return try writer.library.withRoutineDatabase {connection in
            guard connection.handle==cache.database.handle else {throw OSwindError.invalid("Use the retry library connection")}
            let jobs=try queue.jobs(limit:limit);var results=[SyncPublicationOutcome]()
            for job in jobs {
                try Task.checkCancellation()
                let result=try SyncChangeCapture.transaction(cache.database) {try offer(job.identity,admission:admission,fetchSource:fetchSource)}
                results.append(result)
            };try admission.withActive(for:writer.library.mediaRootIdentity) {};return results
        }
    }
}
