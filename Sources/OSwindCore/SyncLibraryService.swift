import Foundation
import CSQLite

enum SyncLibraryServiceStep:Equatable,Sendable {
    case preparing(SyncOutgoingStep)
    case needsGroupReview(SyncCollectionControl)
    case needsNativeCollectionRetirement(SyncCollectionControl)
    case transferred(sent:Int,received:Int,pendingPublications:Int)
}

/// Serialized, bounded folder-backed service over the complete native graph.
/// Enrollment is explicit and supplied by the owner; this experimental worker
/// does not grant membership, run recipes, or erase a live producer's library.
/// A scheduler calls tick off the UI actor. stop joins any in-flight tick.
final class SyncLibraryService:@unchecked Sendable {
    let library:MemoryStore
    let cache:SyncVersionStore
    let transport:SyncObjectFolder
    let inbox:SyncObjectFolder
    let peers:[String]
    private let work:SyncOutgoingWorkQueue
    private let publications:SyncPublicationQueue
    private let mutex=NSRecursiveLock()
    private let token:String
    private var stopped=false
    private static let stateSchema="CREATE TABLE personal_sync_service_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),origin TEXT NOT NULL,generation TEXT NOT NULL,group_id TEXT NOT NULL,epoch TEXT NOT NULL,token TEXT NOT NULL,sent INTEGER NOT NULL CHECK(typeof(sent)='integer' AND sent>=0))"
    private static let peerSchema="CREATE TABLE personal_sync_service_heads(replica TEXT PRIMARY KEY,through INTEGER NOT NULL CHECK(typeof(through)='integer' AND through>=0),collection_counter INTEGER NOT NULL CHECK(typeof(collection_counter)='integer' AND collection_counter>=0))"

    private init(library:MemoryStore,cache:SyncVersionStore,work:SyncOutgoingWorkQueue,publications:SyncPublicationQueue,transport:SyncObjectFolder,inbox:SyncObjectFolder,peers:[String],token:String) {
        self.library=library;self.cache=cache;self.work=work;self.publications=publications;self.transport=transport;self.inbox=inbox;self.peers=peers;self.token=token
    }

    static func install(library:MemoryStore,replica:String,group:String,epoch:String,peers:[String],transport:SyncObjectFolder,inbox:SyncObjectFolder,resumeAfterReceivedCollection:SyncCollectionControl?=nil)throws->SyncLibraryService {
        try SyncProtocolLimits.uuid(replica);try SyncProtocolLimits.uuid(group);try SyncProtocolLimits.uuid(epoch)
        let nativeRoot=library.root.standardizedFileURL.resolvingSymlinksInPath().path
        let sharedRoot=transport.root.standardizedFileURL.resolvingSymlinksInPath().path
        let localRoot=inbox.root.standardizedFileURL.resolvingSymlinksInPath().path
        // The shared folder must never contain the plaintext native library.
        // Local encrypted spool files stay inside the native wipe inventory
        // (and the mounted vault when used), separate from provider objects.
        guard sharedRoot != nativeRoot,!sharedRoot.hasPrefix(nativeRoot+"/"),!nativeRoot.hasPrefix(sharedRoot+"/"),
              localRoot.hasPrefix(nativeRoot+"/images/") else {throw OSwindError.invalid("Keep the shared transport outside the native library and its private sync inbox inside images")}
        guard Set(peers).count==peers.count,!peers.contains(replica),peers.count<SyncProtocolLimits.peers,
              transport.root.standardizedFileURL.resolvingSymlinksInPath() != inbox.root.standardizedFileURL.resolvingSymlinksInPath() else {throw OSwindError.invalid("Use separate local/transport spaces and unique explicit peers")}
        for peer in peers {try SyncProtocolLimits.uuid(peer)}
        try transport.requireNamespace(group:group,epoch:epoch);try inbox.requireNamespace(group:group,epoch:epoch)
        let token=UUID().uuidString.lowercased()
        return try library.withRoutineDatabase {db in
            // Component installers set connection durability before their own
            // transactions. Never change SQLite synchronous mode inside ours.
            _=try SyncChangeCapture.activate(db)
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
            for peer in peers {try journal.allowPeer(peer)}
            let cache=try SyncVersionStore.install(catalog:catalog,journal:journal),work=try SyncOutgoingWorkQueue.install(catalog:catalog)
            if let control=resumeAfterReceivedCollection {try SyncPublicationQueue.renewAfterReceivedCollection(cache:cache,library:library,control:control)}
            let publications=try SyncPublicationQueue.install(cache:cache)
            return try SyncChangeCapture.transaction(db) {
                for (name,schema) in [("personal_sync_service_state",stateSchema),("personal_sync_service_heads",peerSchema)] {
                    let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name)
                    let code=sqlite3_step(row),existing=code==SQLITE_ROW ? db.text(row,0):nil;sqlite3_finalize(row)
                    guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
                    if let existing {guard existing==schema else {throw OSwindError.database("Sync service schema differs")}}
                    else {try db.execute(schema)}
                }
                let row=try db.statement("INSERT INTO personal_sync_service_state VALUES(1,?,?,?,?,?,0) ON CONFLICT(singleton) DO UPDATE SET token=excluded.token WHERE origin=excluded.origin AND generation=excluded.generation AND group_id=excluded.group_id AND epoch=excluded.epoch");defer {sqlite3_finalize(row)}
                for (i,text) in [catalog.scope.origin,catalog.scope.generation,group,epoch,token].enumerated() {db.bind(row,Int32(i+1),text)}
                try db.done(row);guard sqlite3_changes(db.handle)==1 else {throw OSwindError.invalid("Service belongs to another trusted library generation")}
                let service=SyncLibraryService(library:library,cache:cache,work:work,publications:publications,transport:transport,inbox:inbox,peers:peers.sorted(),token:token)
                try service.context();return service
            }
        }
    }

    private func context()throws {
        guard !stopped else {throw OSwindError.unavailable("Sync service is stopped")}
        let db=cache.database
        try SyncLibraryContext.requireActive(db,cache:cache)
        let row=try db.statement("SELECT origin,generation,group_id,epoch,token FROM personal_sync_service_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==cache.catalog.scope.origin,db.text(row,1)==cache.catalog.scope.generation,db.text(row,2)==cache.journal.group,db.text(row,3)==cache.journal.epoch,db.text(row,4)==token else {throw OSwindError.unavailable("Sync service was replaced; reopen its current configuration")}
    }
    /// Call with an existing media lease. Keep lock order media -> SQL -> settings.
    private func fenced<T>(_ snapshot:LibrarySettingsSnapshot,_ body:()throws->T)throws->T {
        try library.withRoutineDatabase {db in
            try SyncChangeCapture.transaction(db) {
                try context()
                return try snapshot.withCurrent(root:library.root,policy:snapshot.settings.privacy) {
                    try context();let result=try body();try context();return result
                }
            }
        }
    }
    func stop()throws {
        mutex.lock();defer {mutex.unlock()}
        guard !stopped else {return}
        try library.withRoutineDatabase {db in
            let row=try db.statement("UPDATE personal_sync_service_state SET token='' WHERE singleton=1 AND token=?");defer {sqlite3_finalize(row)}
            db.bind(row,1,token);try db.done(row)
        }
        stopped=true
        // Native intent capture stays on: offline mutations must not disappear.
        // Explicit disconnect/reconciliation and bounded offline spool remain
        // enrollment-owner work before enabling unattended public scheduling.
    }

    func tick(limit:Int=64)throws->SyncLibraryServiceStep {
        mutex.lock();defer {mutex.unlock()}
        guard (1...128).contains(limit) else {throw OSwindError.invalid("Invalid sync service tick budget")}
        let snapshot=try LibrarySettingsSnapshot.capture(root:library.root);defer {snapshot.release()}
        let policy=SyncServicePolicy(settings:snapshot.settings),media=SyncServiceMedia(library:library,inbox:inbox,policy:policy)
        let activity=try library.mediaWriteLease();defer {activity.release()}
        let preparation=try fenced(snapshot) {()->SyncLibraryServiceStep? in
            let history=SyncCollectionHistory(database:cache.database,replica:cache.journal.replica)
            if case .needsGroupReview(let control)=try history.reviewState(journal:cache.journal) {return .needsGroupReview(control)}
            try publications.context()
            var processor=SyncOutgoingProcessor(queue:work,cache:cache,admitRow:policy.admitRow,admitVersion:policy.admit,media:media.prepare)
            processor.retainTurnPublication={reference,data in try self.inbox.publishContent(data,reference:reference)}
            let step=try processor.step(limit:limit)
            return step == .idle ? nil:.preparing(step)
        }
        if let preparation {return preparation}

        var heads=[SyncServiceHead]()
        for peer in peers {
            try Task.checkCancellation()
            guard let head=try transport.serviceHead(replica:peer) else {continue}
            try fenced(snapshot) {try pin(head)}
            let frontier=try fenced(snapshot) {try SyncCollectionHistory(database:cache.database,replica:cache.journal.replica).current()}
            if head.collectionCounter>frontier[peer] {
                guard let control=try transport.collectionControl(creator:peer,counter:head.collectionCounter) else {throw OSwindError.unavailable("Peer head arrived before its erasure control; retry after folder delivery")}
                // Release this tick's lease before the app cancels/joins all
                // actual producers and invokes SyncNativeCollectionReceiver.
                return .needsNativeCollectionRetirement(control)
            }
            heads.append(head)
        }

        var sender=SyncLibrarySender(library:library,cache:cache,inbox:transport,admit:policy.admit,supplementalContent:{try self.inbox.content($0)})
        sender.publicationFence={write in try snapshot.withCurrent(root:self.library.root,policy:snapshot.settings.privacy) {try self.context();try self.publications.context();try write();try self.context()}}
        let after=try fenced(snapshot) {try self.sent()}
        let sentResult=try sender.publish(after:after,limit:limit)
        guard case .published(let through,let sent,_,_)=sentResult else {
            if case .needsGroupReview(let control)=sentResult {return .needsGroupReview(control)}
            throw OSwindError.invalid("Unknown sync send result")
        }
        try fenced(snapshot) {
            let history=SyncCollectionHistory(database:cache.database,replica:cache.journal.replica)
            let head=try SyncServiceHead(group:cache.journal.group,epoch:cache.journal.epoch,replica:cache.journal.replica,through:through,collectionCounter:history.current()[cache.journal.replica])
            try transport.publishServiceHead(head)
            let row=try cache.database.statement("UPDATE personal_sync_service_state SET sent=? WHERE singleton=1 AND token=?");defer {sqlite3_finalize(row)}
            sqlite3_bind_int64(row,1,through);cache.database.bind(row,2,token);try cache.database.done(row)
        }
        let writer=SyncIncomingConversationWriter(library:library,cache:cache,admit:policy.admit,pathsFor:{reference,manifests in
            try media.paths(reference,manifests,fetch:{try self.fetch($0)})
        },admitMedia:media.verify)
        let admission=SyncPublicationAdmission(queue:publications,writer:writer,inbox:inbox)
        func record(_ reference:SyncVersionReference)throws->SyncPortableRecord {
            guard let bytes=try inbox.content(reference.content) ?? transport.content(reference.content) else {throw OSwindError.unavailable("The exact peer record has not arrived")}
            let value=try SyncPortableRecord.decode(bytes,expected:reference)
            try policy.admit(value);try inbox.publishContent(bytes,reference:reference.content);return value
        }
        var received=0
        for head in heads {
            let cursor=try fenced(snapshot) {try cache.journal.cursor(for:head.replica) ?? 0}
            guard cursor<=head.through else {throw OSwindError.invalid("Peer head precedes the durable operation cursor")}
            var operations=[SyncRevision]()
            if cursor<head.through {
                let count=Int(min(Int64(limit),head.through-cursor))
                for offset in 1...count {
                    guard let operation=try transport.revision(replica:head.replica,sequence:cursor+Int64(offset)) else {break}
                    operations.append(operation)
                }
            }
            // Early authenticated deletions must be visible before a pruned
            // predecessor. Journal causal cursors still advance contiguously.
            operations.sort {if $0.mutation != $1.mutation {return $0.mutation == .delete};return $0.dot.counter<$1.dot.counter}
            for operation in operations {
                try fenced(snapshot) {
                    if let declaration=operation.publication,let bytes=try transport.content(declaration) {
                        let value=try SyncTurnPublication.decode(bytes,expected:declaration)
                        guard value.group==cache.journal.group,value.epoch==cache.journal.epoch else {throw OSwindError.invalid("Peer declaration namespace differs")}
                        for citation in value.citations {try policy.admit(citation)}
                        try inbox.publishContent(bytes,reference:declaration);try publications.wakeDeclaration(declaration)
                    }
                    let packet:SyncPortableRecord?
                    if let reference=operation.content,let bytes=try transport.content(reference) {
                        let value=try SyncPortableRecord.decode(bytes)
                        guard try value.identity.key==operation.key,(try value.reference.content)==reference else {throw OSwindError.invalid("Peer operation content differs")}
                        try policy.admit(value);packet=value
                    }else{packet=nil}
                    let result=try admission.receive(operation,record:packet,admission:activity,allowPendingBody:true,supersededBy:{try self.transport.supersedingRevision(for:$0)},fetchSource:record)
                    received+=result.receipt.applied
                }
            }
        }
        let pending=try fenced(snapshot) {
            _=try admission.retry(limit:limit,admission:activity,fetchSource:record)
            try publications.checkAccounting()
            return try cache.database.eraseCount("SELECT COUNT(*) FROM personal_sync_publication_jobs")
        }
        return .transferred(sent:sent,received:received,pendingPublications:pending)
    }

    private func fetch(_ reference:SyncContentReference)throws->Data {
        if let data=try inbox.content(reference) {return data}
        guard let data=try transport.content(reference) else {throw OSwindError.unavailable("Peer content has not arrived in the shared folder")}
        try inbox.publishContent(data,reference:reference);return data
    }
    private func sent()throws->Int64 {Int64(try cache.database.eraseCount("SELECT sent FROM personal_sync_service_state WHERE singleton=1"))}
    private func pin(_ head:SyncServiceHead)throws {
        let db=cache.database,row=try db.statement("INSERT INTO personal_sync_service_heads VALUES(?,?,?) ON CONFLICT(replica) DO UPDATE SET through=excluded.through,collection_counter=excluded.collection_counter WHERE through<=excluded.through AND collection_counter<=excluded.collection_counter");defer {sqlite3_finalize(row)}
        db.bind(row,1,head.replica);sqlite3_bind_int64(row,2,head.through);sqlite3_bind_int64(row,3,head.collectionCounter);try db.done(row)
        guard sqlite3_changes(db.handle)==1 else {throw OSwindError.invalid("Peer head rolled back; review the restored device before resuming")}
    }
}
