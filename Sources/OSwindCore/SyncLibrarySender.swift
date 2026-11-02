import Foundation

enum SyncLibrarySendResult:Equatable {
    case needsGroupReview(SyncCollectionControl)
    case published(through:Int64,revisions:Int,controls:Int,contentBytes:Int)
}

/// Owning publication boundary over the actual journal, typed version cache and
/// encrypted object folder. Raw journal reads never imply network publication.
/// Caller supplies current policy and separately staged manifest/media bytes.
/// Public scheduling/enrollment, durable large-transfer cursors and provider
/// acceptance remain separate work; this synchronous worker must be lifecycle
/// owned and run off the UI actor before enabling a service.
struct SyncLibrarySender {
    let library:MemoryStore
    let cache:SyncVersionStore
    let inbox:SyncObjectFolder
    let admit:(SyncPortableRecord)throws->Void
    let supplementalContent:(SyncContentReference)throws->Data?
    var publicationFence:((()throws->Void)throws->Void)? = nil
    var maximumObjects=512
    var maximumBytes=64*1024*1024
    var maximumDepth=64

    private func metadata<T>(_ body:(SyncCollectionHistory)throws->T)throws->T {
        try library.withRoutineDatabase {db in
            try SyncLibraryContext.requireActive(db,cache:cache)
            return try body(SyncCollectionHistory(database:db,replica:cache.journal.replica))
        }
    }
    private func ready()throws {
        try Task.checkCancellation()
        guard try metadata({try $0.reviewState(journal:cache.journal)}) == .ready else {throw OSwindError.unavailable("A local wipe changed before publication; review its group erasure first")}
        try inbox.requireNamespace(group:cache.journal.group,epoch:cache.journal.epoch)
    }
    /// Native retirement/configuration writers cannot commit between the last
    /// admission callback and the file link. Recheck after callbacks as well:
    /// they may invalidate this context or create a pending wipe themselves.
    /// External settings/trust still require the service's cancel/join owner.
    private func publication(validate:()throws->Void={},_ write:()throws->Void)throws {
        try library.withRoutineDatabase {db in
            try SyncChangeCapture.transaction(db) {
                try ready();try validate();try ready()
                if let publicationFence {try publicationFence {try ready();try write()}}
                else {try write()}
            }
        }
    }
    private func current(_ reference:SyncVersionReference)throws->SyncPortableRecord {
        guard let record=try cache.record(reference,admit:admit) else {throw OSwindError.unavailable("The exact outgoing version was erased before publication")}
        return record
    }
    func publish(after sequence:Int64=0,limit:Int=128,supersessionDepth:Int=0)throws->SyncLibrarySendResult {
        guard sequence>=0,(1...256).contains(limit),(1...16384).contains(maximumObjects),(1...512*1024*1024).contains(maximumBytes),(1...128).contains(maximumDepth),(0...maximumDepth).contains(supersessionDepth) else {throw OSwindError.invalid("Invalid sender work budget")}
        // A native whole-library wipe owns an exclusive media lease. It cannot
        // slip a new unreviewed control between this decision and file writes.
        let lease=try library.mediaWriteLease();defer {lease.release()}
        if case .needsGroupReview(let proposal)=try metadata({try $0.reviewState(journal:cache.journal)}) {return .needsGroupReview(proposal)}
        try ready()
        let controls=try metadata {try $0.knownControls(journal:cache.journal)}
        for control in controls {try publication {try inbox.ensureAuthenticatedCollectionControl(control)}}
        let revisions=try metadata {_ in try cache.journal.outbox(after:sequence,limit:limit)}
        var through=sequence,count=0,totalBytes=0
        for revision in revisions {
            try ready()
            if let control=controls.first(where:{$0.erases(revision)}) {
                try publication {try inbox.publishErasedRevision(revision,control:control)}
            } else if revision.mutation == .put,let deletion=try deletionBarrier(for:revision) {
                try publication {try inbox.publishRevision(deletion)}
                try publication {try inbox.publishDeletedRevision(revision,deletion:deletion)}
            } else if let replacement=try successor(for:revision) {
                let successor=replacement.revision
                if !replacement.certified,successor.dot.replica==cache.journal.replica {
                    let nested=try publish(after:successor.dot.counter-1,limit:1,supersessionDepth:supersessionDepth+1)
                    guard case .published(_,_,_,let bytes)=nested else {throw OSwindError.unavailable("The successor needs renewed group review")};totalBytes+=bytes
                }
                try publication {try inbox.publishSupersededRevision(revision,successor:successor)}
            } else {
                var graph=[SyncVersionReference]()
                if let content=revision.content {
                    let object=try metadata {_ in try cache.catalog.object(for:revision.key)}
                    guard let object,!object.deleted else {throw OSwindError.unavailable("The outgoing object has no live typed identity or authenticated erasure proof")}
                    let ref=SyncVersionReference(identity:object.identity,content:content)
                    var sent=Set<String>(),objects=0,bytes=0
                    func reserve(_ reference:SyncContentReference)throws->Bool {
                        let key=reference.sha256+":"+String(reference.bytes)
                        if sent.contains(key) {return false}
                        guard objects<maximumObjects,reference.bytes<=Int64(maximumBytes-bytes) else {throw OSwindError.unavailable("The content graph needs a larger resumable transfer budget; its revision was withheld")}
                        sent.insert(key);objects+=1;bytes+=Int(reference.bytes);return true
                    }
                    func emitSupplement(_ reference:SyncContentReference,owner:SyncPortableRecord)throws->Data {
                        try ready();_=try metadata {_ in try current(owner.reference)}
                        guard let data=try supplementalContent(reference),reference.matches(data) else {throw OSwindError.unavailable("Exact staged publication/media bytes are unavailable; withhold their revision")}
                        try publication(validate:{_=try current(owner.reference)}) {try inbox.publishContent(data,reference:reference)};return data
                    }
                    func emit(_ reference:SyncVersionReference,depth:Int)throws {
                        try ready();guard depth<=maximumDepth else {throw OSwindError.invalid("The outgoing dependency graph exceeds its depth budget")}
                        guard try reserve(reference.content) else {return}
                        guard let record=try metadata({_ in try cache.record(reference,admit:admit)}) else {throw OSwindError.unavailable("The exact outgoing version was erased or is unavailable")}
                        graph.append(reference)
                        for dependency in record.dependencies {
                            let child:SyncVersionReference
                            if let content=dependency.content {child = .init(identity:dependency.identity,content:content)}
                            else {let value=try metadata {_ in try cache.resolve(dependency.identity,content:nil,admit:admit)};child=try value.reference}
                            try emit(child,depth:depth+1)
                        }
                        if case .source(let source)=record.body {
                            for media in source.media {
                                try media.verify {chunk in
                                    if try reserve(chunk) {return try emitSupplement(chunk,owner:record)}
                                    guard let existing=try inbox.content(chunk) else {throw OSwindError.unavailable("A previously published media chunk is unavailable")};return existing
                                }
                            }
                        }
                        try publication(validate:{_=try current(reference)}) {try inbox.publishContent(record.encoded(),reference:reference.content)}
                    }
                    guard try object.identity.key==revision.key else {throw OSwindError.invalid("The outgoing revision differs from its typed identity")}
                    // Reserve/validate the complete answer declaration and its
                    // citations before publishing the final operation header.
                    if object.identity.table == .turn {
                        guard let declaration=revision.publication else {throw OSwindError.unavailable("Outgoing answers require their complete evidence declaration")}
                        guard try reserve(declaration),let data=try supplementalContent(declaration) else {throw OSwindError.unavailable("The exact outgoing answer declaration is unavailable")}
                        let manifest=try SyncTurnPublication.decode(data,expected:declaration)
                        guard manifest.group==cache.journal.group,manifest.epoch==cache.journal.epoch,manifest.owner==ref else {throw OSwindError.invalid("The answer declaration belongs to another owner or epoch")}
                        for citation in manifest.citations {try emit(citation.reference,depth:0)}
                        try emit(ref,depth:0)
                        try publication(validate:{_=try current(ref)}) {try inbox.publishContent(data,reference:declaration)}
                    } else {try emit(ref,depth:0)}
                    totalBytes+=bytes
                }
                // Dependencies may have been retired after their earlier body
                // writes. Withhold the operation unless its exact typed graph
                // still passes current admission at the final write boundary.
                try publication(validate:{
                    for reference in graph {_=try current(reference)}
                    // A later dependency's callback could retire an earlier
                    // one. Finish with a callback-free exact graph check.
                    for reference in graph {
                        guard try cache.record(reference,admit:{_ in}) != nil else {throw OSwindError.unavailable("The outgoing graph changed during final policy admission")}
                    }
                }) {try inbox.publishRevision(revision)}
            }
            through=revision.dot.counter;count+=1
        }
        return .published(through:through,revisions:count,controls:controls.count,contentBytes:totalBytes)
    }

    private func deletionBarrier(for revision:SyncRevision)throws->SyncRevision? {
        let state=try metadata {_ in try cache.journal.state(for:revision.key)}
        guard state.isDeleted else {return nil}
        for (peer,counter) in state.deletions.counters.sorted(by:{$0.key<$1.key}) {
            let candidate:SyncRevision?
            if peer==cache.journal.replica {candidate=try metadata {_ in try cache.journal.outbox(after:counter-1,limit:1).first}}
            else {candidate=try inbox.revision(replica:peer,sequence:counter)}
            if let candidate,candidate.mutation == .delete,candidate.key==revision.key,candidate.dot.counter==counter {return candidate}
        }
        throw OSwindError.unavailable("The erased outgoing lifetime has no available authenticated deletion barrier")
    }
    private func successor(for revision:SyncRevision)throws->(revision:SyncRevision,certified:Bool)? {
        guard revision.mutation == .put else {return nil}
        if let existing=try inbox.supersedingRevision(for:revision) {return (existing,true)}
        let state=try metadata {_ in try cache.journal.state(for:revision.key)}
        guard !state.isDeleted,state.heads.count==1,let candidate=state.preferred,candidate.dot != revision.dot else {return nil}
        try SyncSupersessionProof.validate(obsolete:revision,successor:candidate)
        if candidate.dot.replica != cache.journal.replica {
            guard try inbox.revision(replica:candidate.dot.replica,sequence:candidate.dot.counter)==candidate else {throw OSwindError.unavailable("The authenticated superseding peer operation is unavailable")}
        }
        return (candidate,false)
    }
}
