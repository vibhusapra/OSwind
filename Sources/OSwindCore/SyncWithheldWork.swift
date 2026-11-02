import Foundation
import CSQLite
import Darwin

/// Durable local-only preparation holds. Denial creates no operation sequence,
/// portable body or media upload. The owning work acknowledgment and this row
/// commit together; ordinary eligible records can continue through the queue.
struct SyncWithheldWork {
    let catalog:SyncIdentityCatalog
    private var db:RoutineDatabase {catalog.database}
    private final class Stamp {let lock=NSLock();var cookie:Int?}
    private let stamp=Stamp()
    static let rowBytes:Int64=320,defaultBudget:Int64=64*1024*1024
    static let nativeHoldMessage="Native sync change is held by local privacy policy"
    static func isNativeHold(_ error:Error)->Bool {if case OSwindError.database(let message)=error {return message==nativeHoldMessage};return false}
    static func isMetadataFull(_ error:Error)->Bool {if case OSwindError.database(let message)=error {return message=="Sync withheld metadata is full"};return false}
    private struct PermitKey:Hashable {let connection:UInt,thread:UInt32}
    private final class Permits:@unchecked Sendable {let lock=NSLock();var depths=[PermitKey:Int]()}
    private static let permits=Permits()
    private static func permitKey(_ db:OpaquePointer)->PermitKey {.init(connection:UInt(bitPattern:db),thread:pthread_mach_thread_np(pthread_self()))}
    static func register(_ db:RoutineDatabase)throws {
        let code=sqlite3_create_function_v2(db.handle,"oswind_sync_withheld_erasure_v1",0,SQLITE_UTF8 | SQLITE_INNOCUOUS,nil,{context,_,_ in
            guard let context,let connection=sqlite3_context_db_handle(context) else {return}
            let key=SyncWithheldWork.permitKey(connection),permits=SyncWithheldWork.permits
            permits.lock.lock();let allowed=(permits.depths[key] ?? 0)>0;permits.lock.unlock()
            sqlite3_result_int(context,allowed ? 1:0)
        },nil,nil,nil)
        guard code==SQLITE_OK else {throw db.error()}
    }
    /// Only an owning authenticated deletion collector may retire held native
    /// descendants. The capability is connection/thread scoped and never SQL-
    /// grantable; a peer put or a second connection cannot borrow this window.
    static func withNativeErasure<T>(_ db:RoutineDatabase,enabled:Bool,_ body:()throws->T)throws->T {
        guard enabled else {return try body()}
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Retire held native changes in the owning deletion transaction")}
        let key=permitKey(db.handle);permits.lock.lock();permits.depths[key,default:0]+=1;permits.lock.unlock()
        defer {permits.lock.lock();let remaining=(permits.depths[key] ?? 1)-1;if remaining==0 {permits.depths.removeValue(forKey:key)}else{permits.depths[key]=remaining};permits.lock.unlock()}
        return try body()
    }
    private static let schemas:[String:String] = {
        var value:[String:String]=[
        "personal_sync_withheld_state":"CREATE TABLE personal_sync_withheld_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),origin TEXT NOT NULL,generation TEXT NOT NULL,policy_sha TEXT NOT NULL,review_after INTEGER NOT NULL CHECK(typeof(review_after)='integer' AND review_after>=0),review_through INTEGER NOT NULL CHECK(typeof(review_through)='integer' AND review_through>=0),reviewing INTEGER NOT NULL CHECK(reviewing IN(0,1)),used_bytes INTEGER NOT NULL CHECK(typeof(used_bytes)='integer' AND used_bytes>=0 AND used_bytes<=budget),budget INTEGER NOT NULL CHECK(typeof(budget)='integer' AND budget>0 AND budget<=8589934592))",
        "personal_sync_withheld":"CREATE TABLE personal_sync_withheld(ordinal INTEGER PRIMARY KEY AUTOINCREMENT,owner_digest TEXT NOT NULL UNIQUE REFERENCES personal_sync_identities(object_digest),denied_digest TEXT NOT NULL CHECK(length(denied_digest)=64),policy_sha TEXT NOT NULL CHECK(length(policy_sha)=64),ready INTEGER NOT NULL CHECK(ready IN(0,1)))",
        "sync_withheld_denied":"CREATE INDEX sync_withheld_denied ON personal_sync_withheld(denied_digest)",
        "sync_withheld_ready":"CREATE INDEX sync_withheld_ready ON personal_sync_withheld(ready,ordinal)",
        "sync_withheld_budget":"CREATE TRIGGER sync_withheld_budget BEFORE INSERT ON personal_sync_withheld BEGIN SELECT CASE WHEN (SELECT used_bytes+320>budget FROM personal_sync_withheld_state WHERE singleton=1) THEN RAISE(ABORT,'Sync withheld metadata is full') END; END",
        "sync_withheld_added":"CREATE TRIGGER sync_withheld_added AFTER INSERT ON personal_sync_withheld BEGIN UPDATE personal_sync_withheld_state SET used_bytes=used_bytes+320 WHERE singleton=1; END",
        "sync_withheld_removed":"CREATE TRIGGER sync_withheld_removed AFTER DELETE ON personal_sync_withheld BEGIN UPDATE personal_sync_withheld_state SET used_bytes=used_bytes-320 WHERE singleton=1; END",
        "sync_withheld_identity_retired":"CREATE TRIGGER sync_withheld_identity_retired AFTER UPDATE OF deleted ON personal_sync_identities WHEN new.deleted=1 BEGIN DELETE FROM personal_sync_withheld WHERE owner_digest=new.object_digest; END"
        ]
        for table in SyncCanonicalTable.allCases {
            for operation in ["insert","update","delete"] {
                let frames=operation=="insert" ? ["new"]:operation=="delete" ? ["old"]:["old","new"]
                let keys=frames.map {"c.local_key="+table.schema.snapshot($0,true)}.joined(separator:" OR ")
                let name="sync_withheld_native_"+table.rawValue+"_"+operation
                value[name]="CREATE TRIGGER \(name) BEFORE \(operation.uppercased()) ON \(table.rawValue) WHEN (SELECT suppressed>0 FROM personal_sync_capture WHERE singleton=1) AND (SELECT used_bytes>0 FROM personal_sync_withheld_state WHERE singleton=1) AND oswind_sync_withheld_erasure_v1()=0 AND EXISTS(SELECT 1 FROM personal_sync_withheld w JOIN personal_sync_identity_current c ON c.object_digest=w.owner_digest WHERE c.table_name='\(table.rawValue)' AND (\(keys))) BEGIN SELECT RAISE(ABORT,'\(nativeHoldMessage)'); END"
                let changed="SELECT c.object_digest FROM personal_sync_identity_current c WHERE c.table_name='\(table.rawValue)' AND (\(keys))"
                let wake="sync_withheld_changed_"+table.rawValue+"_"+operation
                value[wake]="CREATE TRIGGER \(wake) AFTER \(operation.uppercased()) ON \(table.rawValue) WHEN (SELECT suppressed>0 FROM personal_sync_capture WHERE singleton=1) AND (SELECT used_bytes>0 FROM personal_sync_withheld_state WHERE singleton=1) BEGIN UPDATE personal_sync_withheld SET ready=1 WHERE denied_digest IN (\(changed)); DELETE FROM personal_sync_withheld WHERE oswind_sync_withheld_erasure_v1()!=0 AND owner_digest IN (\(changed)); END"
            }
        };return value
    }()
    static func install(catalog:SyncIdentityCatalog,budget:Int64=defaultBudget)throws->Self {
        guard (1...SyncOutgoingWorkQueue.maximumBudget).contains(budget) else {throw OSwindError.invalid("Invalid withheld metadata budget")}
        let value=Self(catalog:catalog),db=catalog.database
        return try SyncChangeCapture.transaction(db) {
            let count=try db.eraseCount("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('personal_sync_withheld','personal_sync_withheld_state')")
            guard count==0 || count==2 else {throw OSwindError.database("Withheld sync metadata is incomplete")}
            if count==0 {
                for name in ["personal_sync_withheld_state","personal_sync_withheld"] {try db.execute(schemas[name]!)}
                let row=try db.statement("INSERT INTO personal_sync_withheld_state VALUES(1,?,?,'',0,0,0,0,?)");defer {sqlite3_finalize(row)}
                db.bind(row,1,catalog.scope.origin);db.bind(row,2,catalog.scope.generation);sqlite3_bind_int64(row,3,budget);try db.done(row)
                for name in schemas.keys.sorted() where name.hasPrefix("sync_") {try db.execute(schemas[name]!)}
            }
            try value.context();try value.checkAccounting();return value
        }
    }
    private func schema()throws {
        stamp.lock.lock();defer {stamp.lock.unlock()}
        let cookie=try db.eraseCount("PRAGMA schema_version");if stamp.cookie==cookie {return}
        for (name,sql) in Self.schemas {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.database("Withheld sync schema differs")}
        };stamp.cookie=cookie
    }
    private func context()throws {
        try schema()
        guard try SyncChangeCapture.scope(db,requireActive:true)==catalog.scope else {throw OSwindError.invalid("Withheld work belongs to another capture generation")}
        let row=try db.statement("SELECT origin,generation FROM personal_sync_withheld_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==catalog.scope.origin,db.text(row,1)==catalog.scope.generation else {throw OSwindError.invalid("Withheld work namespace differs")}
    }
    func checkAccounting()throws {
        let row=try db.statement("SELECT used_bytes=320*(SELECT COUNT(*) FROM personal_sync_withheld) FROM personal_sync_withheld_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_int(row,0)==1 else {throw OSwindError.database("Withheld work accounting differs")}
    }
    func count()throws->Int {try context();return try db.eraseCount("SELECT used_bytes/320 FROM personal_sync_withheld_state WHERE singleton=1")}
    func requireProjectionAvailable(_ identity:SyncObjectIdentity)throws {
        try schema()
        if try db.eraseCount("SELECT oswind_sync_withheld_erasure_v1()") != 0 {return}
        try context();let row=try db.statement("SELECT EXISTS(SELECT 1 FROM personal_sync_withheld WHERE owner_digest=?)");defer {sqlite3_finalize(row)};db.bind(row,1,try identity.key.digest)
        guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()}
        if sqlite3_column_int(row,0) != 0 {throw OSwindError.database(Self.nativeHoldMessage)}
    }
    func setBudget(_ budget:Int64)throws {
        guard (1...SyncOutgoingWorkQueue.maximumBudget).contains(budget) else {throw OSwindError.invalid("Invalid withheld metadata budget")}
        try SyncChangeCapture.transaction(db) {
            try context();let row=try db.statement("UPDATE personal_sync_withheld_state SET budget=? WHERE singleton=1 AND used_bytes<=?");defer {sqlite3_finalize(row)}
            sqlite3_bind_int64(row,1,budget);sqlite3_bind_int64(row,2,budget);try db.done(row)
            guard sqlite3_changes(db.handle)==1 else {throw OSwindError.unavailable("Withheld metadata exceeds the requested budget")}
        }
    }
    func park(_ owner:SyncObjectIdentity,denied:SyncObjectIdentity,policy:String)throws {
        guard sqlite3_get_autocommit(db.handle)==0,try db.eraseCount("SELECT processing FROM personal_sync_work_state WHERE singleton=1")==1 else {throw OSwindError.invalid("Hold denied work with its owning acknowledgment")}
        try context();try SyncProtocolLimits.digest(policy)
        guard let object=try catalog.object(owner),!object.deleted else {throw OSwindError.invalid("Hold only a current native identity")}
        let key=try owner.key.digest,prior=try db.statement("SELECT ordinal FROM personal_sync_withheld WHERE owner_digest=?");defer {sqlite3_finalize(prior)};db.bind(prior,1,key)
        let code=sqlite3_step(prior);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
        let row=try db.statement(code==SQLITE_ROW ? "UPDATE personal_sync_withheld SET denied_digest=?,policy_sha=?,ready=0 WHERE owner_digest=?":"INSERT INTO personal_sync_withheld(denied_digest,policy_sha,owner_digest,ready) VALUES(?,?,?,0)");defer {sqlite3_finalize(row)}
        db.bind(row,1,try denied.key.digest);db.bind(row,2,policy);db.bind(row,3,key);try db.done(row)
    }
    func remove(_ identity:SyncObjectIdentity)throws {
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Remove a hold with its owning work")}
        try context();let row=try db.statement("DELETE FROM personal_sync_withheld WHERE owner_digest=?");defer {sqlite3_finalize(row)};db.bind(row,1,try identity.key.digest);try db.done(row)
    }
    func wake(_ identity:SyncObjectIdentity)throws {
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Wake held work with the captured mutation")}
        try context();let row=try db.statement("UPDATE personal_sync_withheld SET ready=1 WHERE owner_digest=? OR denied_digest=?");defer {sqlite3_finalize(row)}
        let key=try identity.key.digest;db.bind(row,1,key);db.bind(row,2,key);try db.done(row)
    }
    /// A saved policy change scans this metadata once in keyset pages. An idle
    /// unchanged policy never rescans the full native archive or every hold.
    func reviewPolicy(_ policy:String,limit:Int)throws->Int {
        guard (1...256).contains(limit) else {throw OSwindError.invalid("Invalid withheld policy page bound")}
        try context();try SyncProtocolLimits.digest(policy)
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Review withheld policy in its owning transaction")}
        let update=try db.statement("UPDATE personal_sync_withheld_state SET policy_sha=?,review_after=0,review_through=COALESCE((SELECT MAX(ordinal) FROM personal_sync_withheld),0),reviewing=1 WHERE singleton=1 AND policy_sha!=?");defer {sqlite3_finalize(update)}
        db.bind(update,1,policy);db.bind(update,2,policy);try db.done(update)
        let state=try db.statement("SELECT review_after,review_through,reviewing FROM personal_sync_withheld_state WHERE singleton=1");defer {sqlite3_finalize(state)}
        guard sqlite3_step(state)==SQLITE_ROW else {throw db.error()};if sqlite3_column_int(state,2)==0 {return 0}
        let through=sqlite3_column_int64(state,1),row=try db.statement("SELECT ordinal,policy_sha FROM personal_sync_withheld WHERE ordinal>? AND ordinal<=? ORDER BY ordinal LIMIT ?");defer {sqlite3_finalize(row)}
        sqlite3_bind_int64(row,1,sqlite3_column_int64(state,0));sqlite3_bind_int64(row,2,through);sqlite3_bind_int(row,3,Int32(limit))
        var count=0,last=sqlite3_column_int64(state,0),code=sqlite3_step(row)
        while code==SQLITE_ROW {
            try Task.checkCancellation();last=sqlite3_column_int64(row,0);count+=1
            if db.text(row,1) != policy {
                let ready=try db.statement("UPDATE personal_sync_withheld SET ready=1 WHERE ordinal=?");defer {sqlite3_finalize(ready)};sqlite3_bind_int64(ready,1,last);try db.done(ready)
            };code=sqlite3_step(row)
        };guard code==SQLITE_DONE else {throw db.error()}
        let finish=try db.statement("UPDATE personal_sync_withheld_state SET review_after=?,reviewing=? WHERE singleton=1");defer {sqlite3_finalize(finish)}
        sqlite3_bind_int64(finish,1,last);sqlite3_bind_int(finish,2,count==limit && last<through ? 1:0);try db.done(finish);return count
    }
    func requeueReady(_ queue:SyncOutgoingWorkQueue,limit:Int)throws->Int {
        guard (1...256).contains(limit),queue.database.handle==db.handle,queue.catalog.scope==catalog.scope else {throw OSwindError.invalid("Requeue withheld work on its owning connection")}
        try context()
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Requeue held work with its durable ordinary work")}
        let row=try db.statement("SELECT w.owner_digest,i.table_name,i.origin,i.lifetime FROM personal_sync_withheld w INDEXED BY sync_withheld_ready LEFT JOIN personal_sync_identities i ON i.object_digest=w.owner_digest WHERE w.ready=1 ORDER BY w.ordinal LIMIT ?");defer {sqlite3_finalize(row)};sqlite3_bind_int(row,1,Int32(limit))
        var identities=[SyncObjectIdentity](),code=sqlite3_step(row)
        while code==SQLITE_ROW {
            guard let table=SyncCanonicalTable(rawValue:db.text(row,1)) else {throw OSwindError.database("Withheld owner table differs")}
            let identity=try SyncObjectIdentity(table:table,origin:db.text(row,2),lifetime:db.text(row,3))
            guard try identity.key.digest==db.text(row,0) else {throw OSwindError.database("Withheld owner identity differs")};identities.append(identity);code=sqlite3_step(row)
        };guard code==SQLITE_DONE else {throw db.error()}
        try queue.requeueWithheld(identities)
        for identity in identities {try remove(identity)}
        return identities.count
    }
    static func clearIfInstalled(_ db:RoutineDatabase)throws {
        let count=try db.eraseCount("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('personal_sync_withheld','personal_sync_withheld_state')")
        if count==0 {return}
        guard count==2,sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Clear complete withheld metadata in its erasure transaction")}
        let catalog=SyncIdentityCatalog(database:db,scope:try SyncChangeCapture.scope(db)),value=Self(catalog:catalog)
        try value.schema()
        let row=try db.statement("SELECT origin,generation FROM personal_sync_withheld_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==catalog.scope.origin,db.text(row,1)==catalog.scope.generation else {throw OSwindError.invalid("Withheld erasure generation differs")}
        try value.checkAccounting();try db.execute("DELETE FROM personal_sync_withheld; UPDATE personal_sync_withheld_state SET policy_sha='',review_after=0,review_through=0,reviewing=0 WHERE singleton=1");try value.checkAccounting()
    }
}
