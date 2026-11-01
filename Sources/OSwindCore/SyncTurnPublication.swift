import Foundation
import CSQLite

/// An exact, complete citation declaration for one immutable answer body. Its
/// content reference is carried by the authenticated journal revision, rather
/// than inferred from whichever child packets happen to have arrived. This is
/// an internal service prerequisite; it does not enable background sync.
struct SyncTurnPublication:Codable,Equatable,Sendable {
    static let maximumBytes:Int64=1024*1024
    let format:String
    let version:Int
    let group:String,epoch:String
    let owner:SyncVersionReference
    let citations:[SyncPortableRecord]

    init(group:String,epoch:String,owner:SyncVersionReference,citations:[SyncPortableRecord])throws {
        format="OSwind.sync.turn-publication";version=1;self.group=group;self.epoch=epoch;self.owner=owner;self.citations=citations;try validate()
    }
    func validate()throws {
        guard format=="OSwind.sync.turn-publication",version==1,citations.count<=60 else {throw OSwindError.invalid("Invalid answer publication format or citation count")}
        try SyncProtocolLimits.uuid(group);try SyncProtocolLimits.uuid(epoch);try owner.validate(.turn)
        var identities=Set<SyncObjectKey>()
        for (ordinal,record) in citations.enumerated() {
            try record.validate()
            guard case .conversationCitation(let body)=record.body,body.owner==owner.identity,body.ordinal==ordinal,try identities.insert(record.identity.key).inserted else {throw OSwindError.invalid("Answer publication citations must be complete, unique and ordered")}
        }
    }
    func encoded()throws->Data {
        try validate();let data=try SyncProtocolLimits.encode(self)
        guard Int64(data.count)<=Self.maximumBytes else {throw OSwindError.invalid("Answer publication exceeds its byte bound")};return data
    }
    var reference:SyncContentReference {get throws {try .init(data:encoded())}}
    static func decode(_ data:Data,expected:SyncContentReference)throws->Self {
        guard !data.isEmpty,Int64(data.count)<=maximumBytes,expected.matches(data) else {throw OSwindError.invalid("Answer publication content differs")}
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard try value.encoded()==data else {throw OSwindError.invalid("Answer publication is not canonical")};return value
    }

    /// Call after outgoing preparation. Snapshot, exact native projections,
    /// immutable manifest retention and the publishing revision share one writer
    /// transaction. The sink must durably retain content-addressed bytes before
    /// returning; an orphaned immutable blob after rollback is harmless.
    static func publish(owner:SyncObjectIdentity,cache:SyncVersionStore,admit:(SyncPortableRecord)throws->Void,retainManifest:(SyncContentReference,Data)throws->Void)throws->(SyncRevision,Self) {
        let db=cache.database
        return try SyncChangeCapture.transaction(db) {
            try cache.validateIncomingDeletionContext();try SyncWireCheck.identity(owner,.turn)
            let packet=try cache.resolve(owner,content:nil,admit:admit)
            guard let object=try cache.catalog.object(owner),!object.deleted,let primary=object.primary,primary.count==1,case .text(let local)=primary[0],let id=String(data:local,encoding:.utf8) else {throw OSwindError.unavailable("Prepare the exact native answer before publication")}
            let row=try db.statement("SELECT ordinal FROM chat_sources WHERE turn_id=? ORDER BY ordinal LIMIT 61");defer {sqlite3_finalize(row)};db.bind(row,1,id)
            var citations=[SyncPortableRecord](),code=sqlite3_step(row)
            while code==SQLITE_ROW {
                guard citations.count<60,sqlite3_column_type(row,0)==SQLITE_INTEGER,sqlite3_column_int64(row,0)==Int64(citations.count) else {throw OSwindError.invalid("Native answer citation declaration is incomplete or exceeds its bound")}
                let identity=try cache.catalog.localIdentity(.conversationCitation,primary:[.text(local),.integer(Int64(citations.count))])
                citations.append(try cache.resolve(identity,content:nil,admit:admit));code=sqlite3_step(row)
            }
            guard code==SQLITE_DONE else {throw db.error()}
            let value=try Self(group:cache.journal.group,epoch:cache.journal.epoch,owner:packet.reference,citations:citations),bytes=try value.encoded(),ref=try value.reference
            try retainManifest(ref,bytes)
            // Policy/sink callbacks may reenter the connection. Recheck every
            // exact projection and the complete native ordinal set afterwards.
            guard try cache.resolve(owner,content:nil,admit:{_ in}).reference==packet.reference else {throw OSwindError.invalid("Answer changed during publication retention")}
            let check=try db.statement("SELECT count(*) FROM chat_sources WHERE turn_id=?");defer {sqlite3_finalize(check)};db.bind(check,1,id)
            guard sqlite3_step(check)==SQLITE_ROW,sqlite3_column_int64(check,0)==Int64(citations.count) else {throw OSwindError.invalid("Answer citations changed during publication retention")}
            for record in citations {guard try cache.resolve(record.identity,content:nil,admit:{_ in}).reference==record.reference else {throw OSwindError.invalid("Answer citation changed during publication retention")}}
            try Task.checkCancellation()
            return (try cache.journal.put(key:owner.key,content:packet.reference.content,publication:ref),value)
        }
    }
}

/// Receipt progress and readable native projection are distinct. The future
/// service must durably schedule explicit withheld outcomes for later retry;
/// this component does not claim to supply that scheduler or a complete service.
enum SyncPublicationWithheld:String,Equatable {
    case legacyDeclaration,missingDeclaration,conflict,missingCitation,changedCitation,unlistedCitation,missingOwner,replacementRequiresReview,missingOwnerContent,policyDenied,storagePressure,causalGap
}
enum SyncPublicationOutcome:Equatable {
    case projected(String)
    case retired(SyncObjectKey)
    case withheld(SyncPublicationWithheld)
}

/// Use inside the authenticated journal receive transaction, or as an explicit
/// retry of its current head. Reserve media before acquiring SQLite locks. Only
/// an authenticated owner's declared children may authorize owner retirement.
struct SyncIncomingTurnPublicationWriter {
    let writer:SyncIncomingConversationWriter
    var cache:SyncVersionStore {writer.cache}
    func apply(_ record:SyncPortableRecord,admission:MediaAdmissionLease,fetchManifest:(SyncContentReference)throws->Data?,fetchExactSource:(SyncVersionReference)throws->SyncPortableRecord)throws->SyncPublicationOutcome {
        try admission.withActive(for:writer.library.mediaRootIdentity) {}
        return try writer.library.withRoutineDatabase {connection in
            guard connection.handle==cache.database.handle else {throw OSwindError.invalid("Use the answer publication library's own connection")}
            return try SyncChangeCapture.transaction(cache.database) {
                try cache.validateIncomingDeletionContext();try Task.checkCancellation();try record.validate()
                guard case .turn=record.body else {throw OSwindError.invalid("Use an answer publication record")}
                let reference=try record.reference,key=try record.identity.key,state=try cache.journal.state(for:key)
                if state.isDeleted {try writer.applyDeletionBarrier(key,admission:admission);return .retired(key)}
                guard state.heads.contains(where:{$0.content==reference.content}) else {throw OSwindError.unavailable("Admit the exact answer head before publication")}
                guard state.heads.count==1 else {return .withheld(.conflict)}
                guard let declared=state.heads[0].publication else {return .withheld(.legacyDeclaration)}
                let fetched=try fetchManifest(declared)
                guard try cache.journal.state(for:key)==state else {throw OSwindError.invalid("Answer head changed during declaration lookup")}
                guard let bytes=fetched else {return .withheld(.missingDeclaration)}
                let publication=try SyncTurnPublication.decode(bytes,expected:declared)
                guard publication.group==cache.journal.group,publication.epoch==cache.journal.epoch,publication.owner==reference else {throw OSwindError.invalid("Answer publication context or owner differs")}
                // Check authentic evidence erasure before body/media admission or
                // source fetch. An unrelated citation cannot enter this set.
                var parents=record.retirementParents
                for citation in publication.citations {
                    guard case .conversationCitation(let body)=citation.body else {throw OSwindError.invalid("Invalid publication citation")}
                    parents += [citation.identity,body.link.source.identity]
                }
                var erased=[SyncObjectKey:SyncClock]()
                for parent in parents {let k=try parent.key,s=try cache.journal.state(for:k);if s.isDeleted {erased[k]=s.clock}}
                if !erased.isEmpty {
                    let deletion=try cache.journal.delete(key:key) {try writer.applyDeletion($0,admission:admission)}
                    for (parent,clock) in erased {guard try cache.journal.state(for:parent).isDeleted,deletion.context.covers(clock) else {throw OSwindError.invalid("Answer retirement lost its authentic evidence barrier")}}
                    try Task.checkCancellation();try admission.withActive(for:writer.library.mediaRootIdentity) {};return .retired(key)
                }
                // Child journal heads, rather than arbitrary fetched packets,
                // grant authority. A missing child is an explicit withheld
                // outcome; it never implies a source-free answer.
                for citation in publication.citations {
                    let child=try cache.journal.state(for:citation.identity.key)
                    if child.heads.isEmpty {return .withheld(.missingCitation)}
                    if child.isConflicted {return .withheld(.conflict)}
                    guard child.heads[0].content == (try citation.reference.content) else {return .withheld(.changedCitation)}
                }
                // Do not silently leave native citations excluded by a newer
                // declaration. Local projection detachment/replacement lifetimes
                // need their own reviewed protocol; withholding is explicit.
                if let object=try cache.catalog.object(record.identity),!object.deleted,let primary=object.primary,case .text(let local)=primary.first,let id=String(data:local,encoding:.utf8) {
                    let row=try cache.database.statement("SELECT ordinal FROM chat_sources WHERE turn_id=? ORDER BY ordinal LIMIT 61");defer {sqlite3_finalize(row)};cache.database.bind(row,1,id)
                    var count=0,code=sqlite3_step(row)
                    while code==SQLITE_ROW {
                        let ordinal=sqlite3_column_int64(row,0)
                        guard count<60,ordinal>=0,ordinal<Int64(publication.citations.count) else {return .withheld(.replacementRequiresReview)}
                        let identity=try cache.catalog.localIdentity(.conversationCitation,primary:[.text(local),.integer(ordinal)])
                        guard publication.citations[Int(ordinal)].identity==identity else {return .withheld(.replacementRequiresReview)}
                        count+=1;code=sqlite3_step(row)
                    }
                    guard code==SQLITE_DONE else {throw cache.database.error()}
                }
                // Readers see either the old complete answer or the new complete
                // answer: owner, originals and every child share this transaction.
                let outcome=try writer.applyOutcome(record,admission:admission,fetchExactSource:fetchExactSource)
                guard case .projected(let local)=outcome else {throw OSwindError.invalid("Answer retired after publication preflight")}
                for citation in publication.citations {
                    guard case .projected=try writer.applyOutcome(citation,admission:admission,fetchExactSource:fetchExactSource) else {throw OSwindError.invalid("Answer evidence retired during publication")}
                }
                for value in [record]+publication.citations {
                    guard try cache.resolve(value.identity,content:nil,admit:{_ in}).reference==value.reference,try value.erasedParents(cache:cache).isEmpty else {throw OSwindError.invalid("Published answer graph changed during admission")}
                }
                guard try cache.journal.state(for:key)==state else {throw OSwindError.invalid("Answer head changed during publication")}
                try cache.validateIncomingDeletionContext();try Task.checkCancellation();try admission.withActive(for:writer.library.mediaRootIdentity) {};return .projected(local)
            }
        }
    }

    func applyCitation(_ record:SyncPortableRecord,admission:MediaAdmissionLease,fetchManifest:(SyncContentReference)throws->Data?,fetchRecord:(SyncVersionReference)throws->SyncPortableRecord)throws->SyncPublicationOutcome {
        try record.validate();guard case .conversationCitation(let body)=record.body else {throw OSwindError.invalid("Use a publication citation")}
        try admission.withActive(for:writer.library.mediaRootIdentity) {}
        return try writer.library.withRoutineDatabase {connection in
            guard connection.handle==cache.database.handle else {throw OSwindError.invalid("Use the citation publication library's own connection")}
            return try SyncChangeCapture.transaction(cache.database) {
                try cache.validateIncomingDeletionContext();try Task.checkCancellation()
                let state=try cache.journal.state(for:body.owner.key)
                if state.isDeleted {try writer.applyDeletionBarrier(body.owner.key,admission:admission);return .retired(try body.owner.key)}
                guard !state.isConflicted else {return .withheld(.conflict)}
                guard let head=state.heads.first else {return .withheld(.missingOwner)}
                guard let ref=head.publication else {return .withheld(.legacyDeclaration)}
                let fetched=try fetchManifest(ref)
                guard try cache.journal.state(for:body.owner.key)==state else {throw OSwindError.invalid("Citation owner changed during declaration lookup")}
                guard let bytes=fetched else {return .withheld(.missingDeclaration)}
                let declaration=try SyncTurnPublication.decode(bytes,expected:ref),owner=SyncVersionReference(identity:body.owner,content:head.content!)
                guard declaration.group==cache.journal.group,declaration.epoch==cache.journal.epoch,declaration.owner==owner else {throw OSwindError.invalid("Citation publication context differs")}
                guard try declaration.citations.contains(where:{try $0.reference==record.reference}) else {return .withheld(.unlistedCitation)}
                let packet:SyncPortableRecord
                if let mapped=try cache.catalog.object(owner.identity),!mapped.deleted,mapped.primary != nil,let retained=try cache.record(owner,admit:{_ in}) {packet=retained}else {packet=try fetchRecord(owner)}
                guard try packet.reference==owner else {throw OSwindError.invalid("Fetched publication owner differs")}
                return try apply(packet,admission:admission,fetchManifest:fetchManifest,fetchExactSource:fetchRecord)
            }
        }
    }
}
