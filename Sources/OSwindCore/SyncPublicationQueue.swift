import Foundation
import CSQLite

enum SyncPublicationPendingReason:String,Codable,Sendable {
    case legacyDeclaration,missingDeclaration,conflict,missingCitation,changedCitation,missingOwner,replacementRequiresReview
    case missingOwnerContent,policyDenied,storagePressure,causalGap,erasedEvidence
    init(_ reason:SyncPublicationWithheld) throws {
        guard let value=Self(rawValue:reason.rawValue) else {throw OSwindError.invalid("Unlisted citations cannot enqueue or change an independent owner")};self=value
    }
}
struct SyncPublicationJob:Sendable {
    let ordinal:Int64,identity:SyncObjectIdentity,stateSHA:String,reason:SyncPublicationPendingReason,attempts:Int64
}

/// Opt-in, opaque service work metadata in the owning library. Pending work is
/// distinct from a committed native declaration binding. Installation does not
/// enroll, activate capture, restore authority or start a worker. No raw answer,
/// source text, media path, key or error message is stored here.
struct SyncPublicationQueue {
    let cache:SyncVersionStore
    var db:RoutineDatabase {cache.database}
    static let maximumJobs=4096,maximumDependencies=121
    static let jobBytes:Int64=512,dependencyBytes:Int64=128,bindingBytes:Int64=256
    static let defaultBudget:Int64=64*1024*1024,maximumBudget:Int64=8*1024*1024*1024
    private final class SchemaStamp {let lock=NSLock();var value:Int64?}
    private let stamp=SchemaStamp()
    static let schemas:[String:String] = {
        var value:[String:String]=[
            "personal_sync_publication_state":"CREATE TABLE personal_sync_publication_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),origin TEXT NOT NULL,generation TEXT NOT NULL,group_id TEXT NOT NULL,epoch TEXT NOT NULL,library_id TEXT NOT NULL,pending_count INTEGER NOT NULL CHECK(pending_count BETWEEN 0 AND 4096),pending_bytes INTEGER NOT NULL CHECK(typeof(pending_bytes)='integer' AND pending_bytes>=0 AND pending_bytes<=pending_budget),pending_budget INTEGER NOT NULL CHECK(typeof(pending_budget)='integer' AND pending_budget>0 AND pending_budget<=8589934592),binding_bytes INTEGER NOT NULL CHECK(typeof(binding_bytes)='integer' AND binding_bytes>=0 AND binding_bytes<=binding_budget),binding_budget INTEGER NOT NULL CHECK(typeof(binding_budget)='integer' AND binding_budget>0 AND binding_budget<=8589934592))",
            "personal_sync_publication_jobs":"CREATE TABLE personal_sync_publication_jobs(ordinal INTEGER PRIMARY KEY AUTOINCREMENT,object_digest TEXT NOT NULL UNIQUE CHECK(length(object_digest)=64),origin TEXT NOT NULL,lifetime TEXT NOT NULL,state_sha TEXT NOT NULL CHECK(length(state_sha)=64),declaration_sha TEXT CHECK(declaration_sha IS NULL OR length(declaration_sha)=64),reason TEXT NOT NULL,ready INTEGER NOT NULL CHECK(ready IN(0,1)),attempts INTEGER NOT NULL CHECK(typeof(attempts)='integer' AND attempts>=0))",
            "personal_sync_publication_dependencies":"CREATE TABLE personal_sync_publication_dependencies(owner_digest TEXT NOT NULL REFERENCES personal_sync_publication_jobs(object_digest) ON DELETE CASCADE,kind TEXT NOT NULL,digest TEXT NOT NULL CHECK(length(digest)=64),PRIMARY KEY(owner_digest,kind,digest))",
            "personal_sync_publication_bindings":"CREATE TABLE personal_sync_publication_bindings(object_digest TEXT PRIMARY KEY REFERENCES personal_sync_version_projection(object_digest) ON DELETE CASCADE,state_sha TEXT NOT NULL CHECK(length(state_sha)=64),declaration_sha TEXT NOT NULL CHECK(length(declaration_sha)=64),content_sha TEXT NOT NULL CHECK(length(content_sha)=64))",
            "sync_publication_ready":"CREATE INDEX sync_publication_ready ON personal_sync_publication_jobs(ready,ordinal)",
            "sync_publication_reason":"CREATE INDEX sync_publication_reason ON personal_sync_publication_jobs(reason,ordinal)",
            "sync_publication_declaration":"CREATE INDEX sync_publication_declaration ON personal_sync_publication_jobs(declaration_sha,ordinal)",
            "sync_publication_dependency":"CREATE INDEX sync_publication_dependency ON personal_sync_publication_dependencies(kind,digest,owner_digest)",
            "sync_publication_job_budget":"CREATE TRIGGER sync_publication_job_budget BEFORE INSERT ON personal_sync_publication_jobs BEGIN SELECT CASE WHEN (SELECT pending_count>=4096 OR pending_bytes+512>pending_budget FROM personal_sync_publication_state WHERE singleton=1) THEN RAISE(ABORT,'Sync publication admission is full') END; END",
            "sync_publication_job_added":"CREATE TRIGGER sync_publication_job_added AFTER INSERT ON personal_sync_publication_jobs BEGIN UPDATE personal_sync_publication_state SET pending_count=pending_count+1,pending_bytes=pending_bytes+512 WHERE singleton=1; END",
            "sync_publication_job_removed":"CREATE TRIGGER sync_publication_job_removed AFTER DELETE ON personal_sync_publication_jobs BEGIN UPDATE personal_sync_publication_state SET pending_count=pending_count-1,pending_bytes=pending_bytes-512 WHERE singleton=1; END",
            "sync_publication_job_identity":"CREATE TRIGGER sync_publication_job_identity BEFORE UPDATE OF ordinal,object_digest,origin,lifetime ON personal_sync_publication_jobs BEGIN SELECT RAISE(ABORT,'Publication job identity is immutable'); END",
            "sync_publication_dependency_budget":"CREATE TRIGGER sync_publication_dependency_budget BEFORE INSERT ON personal_sync_publication_dependencies BEGIN SELECT CASE WHEN (SELECT pending_bytes+128>pending_budget FROM personal_sync_publication_state WHERE singleton=1) OR (SELECT count(*) FROM personal_sync_publication_dependencies WHERE owner_digest=new.owner_digest)>=121 THEN RAISE(ABORT,'Sync publication dependencies are full') END; END",
            "sync_publication_dependency_added":"CREATE TRIGGER sync_publication_dependency_added AFTER INSERT ON personal_sync_publication_dependencies BEGIN UPDATE personal_sync_publication_state SET pending_bytes=pending_bytes+128 WHERE singleton=1; END",
            "sync_publication_dependency_removed":"CREATE TRIGGER sync_publication_dependency_removed AFTER DELETE ON personal_sync_publication_dependencies BEGIN UPDATE personal_sync_publication_state SET pending_bytes=pending_bytes-128 WHERE singleton=1; END",
            "sync_publication_dependency_immutable":"CREATE TRIGGER sync_publication_dependency_immutable BEFORE UPDATE ON personal_sync_publication_dependencies BEGIN SELECT RAISE(ABORT,'Publication dependency is immutable'); END",
            "sync_publication_binding_budget":"CREATE TRIGGER sync_publication_binding_budget BEFORE INSERT ON personal_sync_publication_bindings WHEN NOT EXISTS(SELECT 1 FROM personal_sync_publication_bindings WHERE object_digest=new.object_digest) BEGIN SELECT CASE WHEN (SELECT binding_bytes+256>binding_budget FROM personal_sync_publication_state WHERE singleton=1) THEN RAISE(ABORT,'Sync publication binding storage is full') END; END",
            "sync_publication_binding_added":"CREATE TRIGGER sync_publication_binding_added AFTER INSERT ON personal_sync_publication_bindings BEGIN UPDATE personal_sync_publication_state SET binding_bytes=binding_bytes+256 WHERE singleton=1; END",
            "sync_publication_binding_removed":"CREATE TRIGGER sync_publication_binding_removed AFTER DELETE ON personal_sync_publication_bindings BEGIN UPDATE personal_sync_publication_state SET binding_bytes=binding_bytes-256 WHERE singleton=1; END",
            "sync_publication_binding_identity":"CREATE TRIGGER sync_publication_binding_identity BEFORE UPDATE OF object_digest ON personal_sync_publication_bindings BEGIN SELECT RAISE(ABORT,'Publication binding identity is immutable'); END"
        ]
        // These use only already-registered schema32 functions. Even a prior
        // initialized native writer must invalidate completion on real changes;
        // no unfamiliar native payload or new UDF is introduced by this metadata.
        func invalidate(_ owner:String)->String {"DELETE FROM personal_sync_publication_bindings WHERE object_digest IN (SELECT object_digest FROM personal_sync_identities WHERE table_name='chat_turns' AND local_key=oswind_sync_key_v1("+owner+"));"}
        for operation in ["insert","update","delete"] {
            let name="sync_publication_native_citation_"+operation
            let old=operation=="insert" ? "":invalidate("old.turn_id"),new=operation=="delete" ? "":invalidate("new.turn_id")
            value[name]="CREATE TRIGGER \(name) AFTER \(operation.uppercased()) ON chat_sources BEGIN \(old) \(new) END"
        }
        value["sync_publication_native_turn_change"]="CREATE TRIGGER sync_publication_native_turn_change AFTER UPDATE ON chat_turns WHEN old.id IS NOT new.id OR old.session_id IS NOT new.session_id OR old.timestamp IS NOT new.timestamp OR old.payload IS NOT new.payload BEGIN \(invalidate("old.id")) \(invalidate("new.id")) END"
        for operation in ["insert","update"] {
            let name="sync_publication_native_wipe_"+operation
            value[name]="CREATE TRIGGER \(name) AFTER \(operation.uppercased()) ON store_metadata WHEN new.key='library_wipe_dirty' AND new.value='1' BEGIN DELETE FROM store_metadata WHERE key='sync-publication-library-lifetime-v1'; END"
        }
        return value
    }()
    static func install(cache:SyncVersionStore,pendingBudget:Int64=defaultBudget,bindingBudget:Int64=defaultBudget)throws->Self {
        guard (1...maximumBudget).contains(pendingBudget),(1...maximumBudget).contains(bindingBudget) else {throw OSwindError.invalid("Invalid publication storage budget")}
        let value=Self(cache:cache),db=cache.database
        return try SyncChangeCapture.transaction(db) {
            try cache.validateIncomingDeletionContext()
            let names=schemas.keys.filter{$0.hasPrefix("personal_sync_")},placeholders=names.map{_ in "?"}.joined(separator:","),row=try db.statement("SELECT count(*) FROM sqlite_master WHERE name IN ("+placeholders+")");defer {sqlite3_finalize(row)}
            for (index,name) in names.enumerated() {db.bind(row,Int32(index+1),name)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};let count=Int(sqlite3_column_int(row,0))
            guard count==0 || count==names.count else {throw OSwindError.database("Publication queue installation is incomplete")}
            if count==0 {
                for name in ["personal_sync_publication_state","personal_sync_publication_jobs","personal_sync_publication_dependencies","personal_sync_publication_bindings"] {try db.execute(schemas[name]!)}
                try db.execute("INSERT INTO store_metadata(key,value) VALUES('sync-publication-library-lifetime-v1',lower(hex(randomblob(16)))) ON CONFLICT(key) DO NOTHING")
                let insert=try db.statement("INSERT INTO personal_sync_publication_state VALUES(1,?,?,?,?,?,0,0,?,0,?)");defer {sqlite3_finalize(insert)}
                db.bind(insert,1,cache.catalog.scope.origin);db.bind(insert,2,cache.catalog.scope.generation);db.bind(insert,3,cache.journal.group);db.bind(insert,4,cache.journal.epoch);db.bind(insert,5,try value.libraryID())
                sqlite3_bind_int64(insert,6,pendingBudget);sqlite3_bind_int64(insert,7,bindingBudget);try db.done(insert)
                for name in schemas.keys.sorted() where name.hasPrefix("sync_") {try db.execute(schemas[name]!)}
            }
            try value.context();try value.checkAccounting();return value
        }
    }
    private func libraryID()throws->String {
        let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-publication-library-lifetime-v1'");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,!db.text(row,0).isEmpty else {throw OSwindError.database("Library lifetime identity missing")};return db.text(row,0)
    }
    func context()throws {
        try cache.validateIncomingDeletionContext()
        try validateSchema()
        let row=try db.statement("SELECT origin,generation,group_id,epoch,library_id FROM personal_sync_publication_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==cache.catalog.scope.origin,db.text(row,1)==cache.catalog.scope.generation,db.text(row,2)==cache.journal.group,db.text(row,3)==cache.journal.epoch,try db.text(row,4)==libraryID() else {throw OSwindError.invalid("Publication queue belongs to another trusted library lifetime")}
    }
    private func validateSchema()throws {
        stamp.lock.lock();defer {stamp.lock.unlock()}
        let cookie=try db.eraseCount("PRAGMA schema_version")
        if stamp.value==Int64(cookie) {return}
        for (name,sql) in Self.schemas {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.database("Publication queue protection differs or is missing")}
        };stamp.value=Int64(cookie)
    }
    func setBudgets(pending:Int64,binding:Int64)throws {
        guard (1...Self.maximumBudget).contains(pending),(1...Self.maximumBudget).contains(binding) else {throw OSwindError.invalid("Invalid publication storage budget")}
        try SyncChangeCapture.transaction(db) {
            try context();let row=try db.statement("UPDATE personal_sync_publication_state SET pending_budget=?,binding_budget=? WHERE singleton=1 AND pending_bytes<=? AND binding_bytes<=?");defer {sqlite3_finalize(row)}
            sqlite3_bind_int64(row,1,pending);sqlite3_bind_int64(row,2,binding);sqlite3_bind_int64(row,3,pending);sqlite3_bind_int64(row,4,binding);try db.done(row)
            guard sqlite3_changes(db.handle)==1 else {throw OSwindError.unavailable("Publication budget is smaller than retained work")}
            _=try wakeReason(.storagePressure)
        }
    }
    /// A live, byte-exact native citation covered by a completed current owner
    /// declaration identifies the projection to withdraw. This is not authority
    /// to delete every future/concurrent version of that owner's global lifetime.
    func completedOwner(ofCitation key:SyncObjectKey)throws->SyncObjectIdentity? {
        try context();guard key.kind == .conversationCitation,try cache.catalog.nativeExists(for:key) else {return nil}
        let row=try db.statement("SELECT i.key_frame FROM personal_sync_identities i JOIN personal_sync_identity_current c USING(object_digest) WHERE i.object_digest=? AND i.table_name='chat_sources' AND c.table_name=i.table_name AND c.local_key=i.local_key AND i.deleted=0");defer {sqlite3_finalize(row)};db.bind(row,1,key.digest)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil}
        guard code==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_BLOB,let bytes=sqlite3_column_blob(row,0),sqlite3_column_bytes(row,0)>0,sqlite3_column_bytes(row,0)<=66048 else {throw OSwindError.database("Declared citation native key differs")}
        let frame=try SyncRowSnapshot.decode(Data(bytes:bytes,count:Int(sqlite3_column_bytes(row,0))))
        guard frame.cells.count==2,case .text=frame.cells[0],case .integer=frame.cells[1] else {throw OSwindError.database("Declared citation key shape differs")}
        guard let owner=try cache.catalog.preparedIdentity(.turn,primary:[frame.cells[0]]),try isComplete(owner) else {return nil};return owner
    }
    /// Early barriers are authentic before their causal predecessors have all
    /// arrived. They can withdraw cached data, but cannot prove the current
    /// owner declaration is fresh. The contiguous cursors, not the observation
    /// clock (which includes early tombstones), establish applied context.
    func hasApplied(_ clock:SyncClock)throws->Bool {
        try context()
        for (peer,counter) in clock.counters {if (try cache.journal.cursor(for:peer) ?? 0)<counter {return false}}
        return true
    }
    func deferCausalGap(_ identity:SyncObjectIdentity)throws->Bool {
        try context()
        let row=try db.statement("SELECT d.kind,d.digest FROM personal_sync_publication_dependencies d JOIN personal_sync_publication_jobs j ON j.object_digest=d.owner_digest WHERE j.object_digest=? AND j.reason='causalGap' LIMIT 122");defer {sqlite3_finalize(row)};db.bind(row,1,try identity.key.digest)
        var dependencies=[SyncObjectKey](),waiting=false,code=sqlite3_step(row)
        while code==SQLITE_ROW {
            guard dependencies.count<Self.maximumDependencies,let kind=SyncObjectKind(rawValue:db.text(row,0)) else {throw OSwindError.database("Causal gap dependencies exceed their bound")}
            let key=try SyncObjectKey(kind:kind,digest:db.text(row,1)),state=try cache.journal.state(for:key);dependencies.append(key)
            if state.isDeleted,try !hasApplied(state.clock) {waiting=true}
            code=sqlite3_step(row)
        };guard code==SQLITE_DONE else {throw db.error()}
        if waiting {try stage(identity,reason:.causalGap,dependencies:dependencies)}
        return waiting
    }
    func retire(_ key:SyncObjectKey)throws {
        try context();guard key.kind == .turn,try cache.journal.state(for:key).isDeleted else {throw OSwindError.invalid("Publication retirement requires its genuine answer barrier")}
        try remove(key)
        let row=try db.statement("DELETE FROM personal_sync_publication_bindings WHERE object_digest=?");defer {sqlite3_finalize(row)};db.bind(row,1,key.digest);try db.done(row)
        _=try wakeReason(.storagePressure)
    }
    func checkAccounting()throws {
        let row=try db.statement("SELECT pending_count=(SELECT count(*) FROM personal_sync_publication_jobs),pending_bytes=512*(SELECT count(*) FROM personal_sync_publication_jobs)+128*(SELECT count(*) FROM personal_sync_publication_dependencies),binding_bytes=256*(SELECT count(*) FROM personal_sync_publication_bindings) FROM personal_sync_publication_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,(0..<3).allSatisfy({sqlite3_column_int(row,Int32($0))==1}) else {throw OSwindError.database("Publication queue accounting differs")}
    }
    func stage(_ identity:SyncObjectIdentity,reason:SyncPublicationPendingReason,dependencies:[SyncObjectKey]=[])throws {
        try SyncChangeCapture.transaction(db) {
            try context();try SyncWireCheck.identity(identity,.turn);let key=try identity.key,state=try cache.journal.state(for:key)
            if state.isDeleted {try remove(key);return}
            let dependencies=Set(dependencies);guard dependencies.count<=Self.maximumDependencies else {throw OSwindError.invalid("Publication dependency set exceeds its bound")}
            let stateSHA=SyncProtocolLimits.hex(try state.encoded()),declaration=state.heads.count==1 ? state.heads[0].publication?.sha256:nil
            let prior=try db.statement("SELECT state_sha,attempts FROM personal_sync_publication_jobs WHERE object_digest=?");defer {sqlite3_finalize(prior)};db.bind(prior,1,key.digest)
            let code=sqlite3_step(prior),attempts:Int64
            if code==SQLITE_ROW {guard sqlite3_column_int64(prior,1)<Int64.max else {throw OSwindError.unavailable("Publication retry counter exhausted")};attempts=db.text(prior,0)==stateSHA ? sqlite3_column_int64(prior,1)+1:0}
            else {guard code==SQLITE_DONE else {throw db.error()};attempts=0}
            let delete=try db.statement("DELETE FROM personal_sync_publication_dependencies WHERE owner_digest=?");defer {sqlite3_finalize(delete)};db.bind(delete,1,key.digest);try db.done(delete)
            if code==SQLITE_ROW {
                let row=try db.statement("UPDATE personal_sync_publication_jobs SET state_sha=?,declaration_sha=?,reason=?,ready=0,attempts=? WHERE object_digest=?");defer {sqlite3_finalize(row)}
                db.bind(row,1,stateSHA);db.bind(row,2,declaration);db.bind(row,3,reason.rawValue);sqlite3_bind_int64(row,4,attempts);db.bind(row,5,key.digest);try db.done(row)
            }else {
                let row=try db.statement("INSERT INTO personal_sync_publication_jobs(object_digest,origin,lifetime,state_sha,declaration_sha,reason,ready,attempts) VALUES(?,?,?,?,?,?,0,?)");defer {sqlite3_finalize(row)}
                for (index,text) in [key.digest,identity.origin,identity.lifetime,stateSHA].enumerated() {db.bind(row,Int32(index+1),text)};db.bind(row,5,declaration);db.bind(row,6,reason.rawValue);sqlite3_bind_int64(row,7,attempts);try db.done(row)
            }
            for dependency in dependencies {
                let row=try db.statement("INSERT INTO personal_sync_publication_dependencies VALUES(?,?,?)");defer {sqlite3_finalize(row)};db.bind(row,1,key.digest);db.bind(row,2,dependency.kind.rawValue);db.bind(row,3,dependency.digest);try db.done(row)
            }
            try context();try Task.checkCancellation()
        }
    }
    /// Remove a previously visible answer while its current authenticated head
    /// is withheld. Actual native deletion keeps every reader/export/backup
    /// unaware of the old body, without changing global lifetime authority.
    func retractWithheldProjection(_ identity:SyncObjectIdentity)throws {
        try context();let state=try cache.journal.state(for:identity.key)
        guard !state.isDeleted,!state.heads.isEmpty else {return}
        try cache.catalog.retractTurnProjection(identity,journal:cache.journal,expectedRegisterSHA:SyncProtocolLimits.hex(state.encoded()))
        try context()
    }
    private func remove(_ key:SyncObjectKey)throws {
        let row=try db.statement("DELETE FROM personal_sync_publication_jobs WHERE object_digest=?");defer {sqlite3_finalize(row)};db.bind(row,1,key.digest);try db.done(row)
    }
    func wake(_ key:SyncObjectKey)throws {
        try SyncChangeCapture.transaction(db) {
            try context();let row=try db.statement("UPDATE personal_sync_publication_jobs SET ready=1 WHERE object_digest=? OR object_digest IN (SELECT owner_digest FROM personal_sync_publication_dependencies INDEXED BY sync_publication_dependency WHERE kind=? AND digest=?)");defer {sqlite3_finalize(row)}
            db.bind(row,1,key.digest);db.bind(row,2,key.kind.rawValue);db.bind(row,3,key.digest);try db.done(row)
        }
    }
    /// Explicit local events (policy review or storage recovery) wake a bounded
    /// reason bucket. No full archive scan or unbounded spinning of blocked work.
    @discardableResult func wakeReason(_ reason:SyncPublicationPendingReason,limit:Int=64)throws->Int {
        guard (1...256).contains(limit) else {throw OSwindError.invalid("Invalid publication wake bound")}
        return try SyncChangeCapture.transaction(db) {
            try context();let row=try db.statement("UPDATE personal_sync_publication_jobs SET ready=1 WHERE ordinal IN (SELECT ordinal FROM personal_sync_publication_jobs INDEXED BY sync_publication_reason WHERE reason=? AND ready=0 ORDER BY ordinal LIMIT ?)");defer {sqlite3_finalize(row)}
            db.bind(row,1,reason.rawValue);sqlite3_bind_int(row,2,Int32(limit));try db.done(row);let count=Int(sqlite3_changes(db.handle));guard count<=limit else {throw OSwindError.invalid("Publication wake exceeded its bound")};return count
        }
    }
    func wakeDeclaration(_ reference:SyncContentReference)throws {
        try SyncChangeCapture.transaction(db) {try context();let row=try db.statement("UPDATE personal_sync_publication_jobs SET ready=1 WHERE declaration_sha=?");defer {sqlite3_finalize(row)};db.bind(row,1,reference.sha256);try db.done(row)}
    }
    func jobs(limit:Int=64,readyOnly:Bool=true)throws->[SyncPublicationJob] {
        guard (1...256).contains(limit) else {throw OSwindError.invalid("Invalid publication batch bound")}
        return try SyncChangeCapture.transaction(db) {
            try context();let row=try db.statement("SELECT ordinal,object_digest,origin,lifetime,state_sha,reason,attempts FROM personal_sync_publication_jobs"+(readyOnly ? " INDEXED BY sync_publication_ready WHERE ready=1":"")+" ORDER BY ordinal LIMIT ?");defer {sqlite3_finalize(row)};sqlite3_bind_int(row,1,Int32(limit));var result=[SyncPublicationJob]()
            while true {let code=sqlite3_step(row);if code==SQLITE_DONE {break};guard code==SQLITE_ROW,let reason=SyncPublicationPendingReason(rawValue:db.text(row,5)) else {throw OSwindError.database("Publication job state differs")}
                let identity=try SyncObjectIdentity(table:.turn,origin:db.text(row,2),lifetime:db.text(row,3));guard try identity.key.digest==db.text(row,1) else {throw OSwindError.database("Publication job identity differs")};try SyncProtocolLimits.digest(db.text(row,4))
                result.append(.init(ordinal:sqlite3_column_int64(row,0),identity:identity,stateSHA:db.text(row,4),reason:reason,attempts:sqlite3_column_int64(row,6)))
            };return result
        }
    }
    func hasBindingCapacity(_ key:SyncObjectKey)throws->Bool {
        try context();let row=try db.statement("SELECT EXISTS(SELECT 1 FROM personal_sync_publication_bindings WHERE object_digest=?) OR binding_bytes+256<=binding_budget FROM personal_sync_publication_state WHERE singleton=1");defer {sqlite3_finalize(row)};db.bind(row,1,key.digest);guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return sqlite3_column_int(row,0)==1
    }
    func complete(_ identity:SyncObjectIdentity,publication:SyncTurnPublication)throws {
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Publication completion belongs to its native transaction")}
        try context();let key=try identity.key,state=try cache.journal.state(for:key)
        guard !state.isDeleted,state.heads.count==1,let proof=state.heads[0].publication,let content=state.heads[0].content else {throw OSwindError.invalid("Bind one complete current publication")}
        guard publication.group==cache.journal.group,publication.epoch==cache.journal.epoch,try publication.reference==proof,publication.owner.identity==identity,publication.owner.content==content,try cache.resolve(identity,content:nil,admit:{_ in}).reference==publication.owner else {throw OSwindError.invalid("Publication completion differs from its admitted owner")}
        guard let mapping=try cache.catalog.object(identity),!mapping.deleted,let primary=mapping.primary,primary.count==1,case .text(let local)=primary[0],let id=String(data:local,encoding:.utf8) else {throw OSwindError.invalid("Publication completion has no exact native owner")}
        let count=try db.statement("SELECT count(*) FROM chat_sources WHERE turn_id=?");defer {sqlite3_finalize(count)};db.bind(count,1,id)
        guard sqlite3_step(count)==SQLITE_ROW,sqlite3_column_int64(count,0)==Int64(publication.citations.count) else {throw OSwindError.invalid("Publication completion has undeclared native citations")}
        for (ordinal,citation) in publication.citations.enumerated() {
            guard try cache.resolve(citation.identity,content:nil,admit:{_ in}).reference==citation.reference,let child=try cache.catalog.object(citation.identity),!child.deleted,child.primary==[.text(local),.integer(Int64(ordinal))] else {throw OSwindError.invalid("Publication completion has an incomplete or differently owned citation")}
        }
        let row=try db.statement("INSERT INTO personal_sync_publication_bindings VALUES(?,?,?,?) ON CONFLICT(object_digest) DO UPDATE SET state_sha=excluded.state_sha,declaration_sha=excluded.declaration_sha,content_sha=excluded.content_sha");defer {sqlite3_finalize(row)}
        db.bind(row,1,key.digest);db.bind(row,2,SyncProtocolLimits.hex(try state.encoded()));db.bind(row,3,proof.sha256);db.bind(row,4,content.sha256);try db.done(row);try remove(key)
    }
    func isComplete(_ identity:SyncObjectIdentity)throws->Bool {
        try context();let state=try cache.journal.state(for:identity.key)
        guard !state.isDeleted,state.heads.count==1,let proof=state.heads[0].publication,let content=state.heads[0].content else {return false}
        let row=try db.statement("SELECT 1 FROM personal_sync_publication_bindings b JOIN personal_sync_version_projection p USING(object_digest) WHERE b.object_digest=? AND b.state_sha=? AND b.declaration_sha=? AND b.content_sha=? AND p.content_sha=b.content_sha");defer {sqlite3_finalize(row)}
        db.bind(row,1,try identity.key.digest);db.bind(row,2,SyncProtocolLimits.hex(try state.encoded()));db.bind(row,3,proof.sha256);db.bind(row,4,content.sha256);let code=sqlite3_step(row);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()};guard code==SQLITE_ROW else {return false}
        _=try cache.resolve(identity,content:nil,admit:{_ in});return true
    }
}
