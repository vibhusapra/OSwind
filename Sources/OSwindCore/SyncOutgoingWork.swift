import Foundation
import CSQLite

struct SyncOutgoingWork:Sendable {
    let ordinal:Int64
    let identity:SyncObjectIdentity
    let deleted:Bool
    let sequence:Int64
}

/// Identity assignment and typed export are separate bounded transactions. Only
/// opaque identities survive here: never source bodies, paths or raw local keys.
/// No peer writer may pass the capture fence while this queue remains nonempty.
struct SyncOutgoingWorkQueue {
    let catalog:SyncIdentityCatalog
    var database:RoutineDatabase {catalog.database}
    static let rowBytes:Int64=192,defaultBudget:Int64=64*1024*1024,maximumBudget:Int64=8*1024*1024*1024
    private static let schemas:[String:String]=[
        "personal_sync_work_state":"CREATE TABLE personal_sync_work_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),origin TEXT NOT NULL,generation TEXT NOT NULL,processing INTEGER NOT NULL CHECK(processing IN(0,1)),used_bytes INTEGER NOT NULL CHECK(typeof(used_bytes)='integer' AND used_bytes>=0 AND used_bytes<=budget),budget INTEGER NOT NULL CHECK(typeof(budget)='integer' AND budget>0 AND budget<=8589934592))",
        "personal_sync_work":"CREATE TABLE personal_sync_work(ordinal INTEGER PRIMARY KEY AUTOINCREMENT,object_digest TEXT NOT NULL UNIQUE REFERENCES personal_sync_identities(object_digest),deleted INTEGER NOT NULL CHECK(deleted IN(0,1)),last_seq INTEGER NOT NULL CHECK(typeof(last_seq)='integer' AND last_seq>=0))",
        "sync_work_budget":"CREATE TRIGGER sync_work_budget BEFORE INSERT ON personal_sync_work BEGIN SELECT CASE WHEN (SELECT used_bytes+192>budget FROM personal_sync_work_state WHERE singleton=1) THEN RAISE(ABORT,'Sync outgoing work is full') END; END",
        "sync_work_added":"CREATE TRIGGER sync_work_added AFTER INSERT ON personal_sync_work BEGIN UPDATE personal_sync_work_state SET used_bytes=used_bytes+192 WHERE singleton=1; END",
        "sync_work_removed":"CREATE TRIGGER sync_work_removed AFTER DELETE ON personal_sync_work BEGIN UPDATE personal_sync_work_state SET used_bytes=used_bytes-192 WHERE singleton=1; END",
        "sync_work_identity":"CREATE TRIGGER sync_work_identity BEFORE UPDATE OF ordinal,object_digest ON personal_sync_work BEGIN SELECT RAISE(ABORT,'Sync work identity is immutable'); END",
        "sync_work_terminal":"CREATE TRIGGER sync_work_terminal BEFORE UPDATE ON personal_sync_work WHEN new.deleted<old.deleted OR new.last_seq<old.last_seq BEGIN SELECT RAISE(ABORT,'Sync work cannot move backwards'); END"
    ]
    private static func validateSchema(_ db:RoutineDatabase)throws {
        for (name,sql) in schemas {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.database("Sync outgoing work schema differs")}
        }
    }
    static func install(catalog:SyncIdentityCatalog,budget:Int64=defaultBudget)throws->Self {
        guard (1...maximumBudget).contains(budget) else {throw OSwindError.invalid("Invalid sync work budget")}
        let value=Self(catalog:catalog),db=catalog.database
        return try SyncChangeCapture.transaction(db) {
            let row=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('personal_sync_work','personal_sync_work_state')");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};let count=sqlite3_column_int(row,0)
            guard count==0 || count==2 else {throw OSwindError.database("Sync outgoing work installation is incomplete")}
            if count==0 {
                for name in ["personal_sync_work_state","personal_sync_work"] {try db.execute(schemas[name]!)}
                let insert=try db.statement("INSERT INTO personal_sync_work_state VALUES(1,?,?,0,0,?)");defer {sqlite3_finalize(insert)}
                db.bind(insert,1,catalog.scope.origin);db.bind(insert,2,catalog.scope.generation);sqlite3_bind_int64(insert,3,budget);try db.done(insert)
                for name in schemas.keys.sorted() where name.hasPrefix("sync_work_") {try db.execute(schemas[name]!)}
            }
            try value.context()
            let sum=try db.statement("SELECT 192*(SELECT COUNT(*) FROM personal_sync_work)=used_bytes FROM personal_sync_work_state WHERE singleton=1");defer {sqlite3_finalize(sum)}
            guard sqlite3_step(sum)==SQLITE_ROW,sqlite3_column_int(sum,0)==1 else {throw OSwindError.database("Sync work accounting differs")}
            return value
        }
    }
    private func context()throws {
        try Self.validateSchema(database)
        guard try SyncChangeCapture.scope(database)==catalog.scope else {throw OSwindError.invalid("Sync work capture generation differs")}
        let row=try database.statement("SELECT w.origin,w.generation,w.processing,c.enabled,c.suppressed,synchronous,recursive_triggers,foreign_keys FROM personal_sync_work_state w JOIN personal_sync_capture c USING(singleton),pragma_synchronous,pragma_recursive_triggers,pragma_foreign_keys WHERE w.singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,database.text(row,0)==catalog.scope.origin,database.text(row,1)==catalog.scope.generation,sqlite3_column_int(row,3)==1,sqlite3_column_int(row,4)==0,sqlite3_column_int(row,5)>=2,sqlite3_column_int(row,6)==1,sqlite3_column_int(row,7)==1 else {throw OSwindError.invalid("Sync work needs its active durable capture context")}
    }
    /// Also fences direct suppression callers; missing/altered internal state
    /// refuses instead of silently treating identified local work as consumed.
    static func requireNoPending(_ db:RoutineDatabase)throws {
        let row=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('personal_sync_work','personal_sync_work_state')");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};let count=sqlite3_column_int(row,0)
        if count==0 {return};guard count==2 else {throw OSwindError.database("Sync outgoing work installation is incomplete")}
        try validateSchema(db)
        let pending=try db.statement("SELECT processing,(SELECT EXISTS(SELECT 1 FROM personal_sync_work)) FROM personal_sync_work_state WHERE singleton=1");defer {sqlite3_finalize(pending)}
        guard sqlite3_step(pending)==SQLITE_ROW,sqlite3_column_int(pending,0)==0,sqlite3_column_int(pending,1)==0 else {throw OSwindError.unavailable("Process identified local sync work before peer apply")}
    }
    private func idleCapture()throws {
        let row=try database.statement("SELECT EXISTS(SELECT 1 FROM personal_sync_changes)");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_int(row,0)==0 else {throw OSwindError.unavailable("Assign all pending capture lifetimes before typed sync export")}
    }
    func setBudget(_ budget:Int64)throws {
        guard (1...Self.maximumBudget).contains(budget) else {throw OSwindError.invalid("Invalid sync work budget")}
        try scoped {
            let row=try database.statement("UPDATE personal_sync_work_state SET budget=? WHERE singleton=1 AND used_bytes<=?");defer {sqlite3_finalize(row)}
            sqlite3_bind_int64(row,1,budget);sqlite3_bind_int64(row,2,budget);try database.done(row)
            guard sqlite3_changes(database.handle)==1 else {throw OSwindError.invalid("Sync work budget is smaller than pending work")}
        }
    }
    private func scoped<T>(_ body:()throws->T)throws->T {
        try SyncChangeCapture.transaction(database) {
            try context()
            let row=try database.statement("UPDATE personal_sync_work_state SET processing=1 WHERE singleton=1 AND processing=0");defer {sqlite3_finalize(row)};try database.done(row)
            guard sqlite3_changes(database.handle)==1 else {throw OSwindError.invalid("Sync outgoing processor is already active")}
            let result=try body();try context();try database.execute("UPDATE personal_sync_work_state SET processing=0 WHERE singleton=1");return result
        }
    }
    private func enqueue(_ identity:SyncObjectIdentity,deleted:Bool,sequence:Int64)throws {
        let digest=try identity.key.digest,row=try database.statement("SELECT deleted,last_seq FROM personal_sync_work WHERE object_digest=?");defer {sqlite3_finalize(row)};database.bind(row,1,digest)
        let code=sqlite3_step(row)
        if code==SQLITE_ROW {
            // A later bootstrap of an already-dirty object carries no new event.
            if sequence==0 {guard sqlite3_column_int(row,0)==0 else {throw OSwindError.invalid("Bootstrap cannot resurrect staged erasure")};return}
            guard sqlite3_column_int(row,0)==0 || deleted,sequence>=sqlite3_column_int64(row,1) else {throw OSwindError.invalid("Sync staged lifetime moved backwards")}
            let update=try database.statement("UPDATE personal_sync_work SET deleted=?,last_seq=? WHERE object_digest=?");defer {sqlite3_finalize(update)}
            sqlite3_bind_int(update,1,deleted ? 1:0);sqlite3_bind_int64(update,2,sequence);database.bind(update,3,digest);try database.done(update)
        }else {
            guard code==SQLITE_DONE else {throw database.error()}
            let put=try database.statement("INSERT INTO personal_sync_work(object_digest,deleted,last_seq) VALUES(?,?,?)");defer {sqlite3_finalize(put)}
            database.bind(put,1,digest);sqlite3_bind_int(put,2,deleted ? 1:0);sqlite3_bind_int64(put,3,sequence);try database.done(put)
        }
    }
    /// Atomically replaces raw intents with opaque, coalesced lifetime work.
    @discardableResult func stage(limit:Int=128,byteLimit:Int=4*1024*1024)throws->Int {
        try scoped {
            try catalog.process(limit:limit,byteLimit:byteLimit) {batch in
                for value in batch {
                    if let before=value.before,before != value.after {try enqueue(before,deleted:true,sequence:value.captured.sequence)}
                    if let after=value.after {try enqueue(after,deleted:false,sequence:value.captured.sequence)}
                }
            }
        }
    }
    @discardableResult func bootstrap(_ table:SyncCanonicalTable,limit:Int=128,byteLimit:Int=1024*1024)throws->SyncBootstrapResult {
        try scoped {try idleCapture();return try catalog.bootstrap(table,limit:limit,byteLimit:byteLimit) {batch in for value in batch {try enqueue(value.identity,deleted:false,sequence:0)}}}
    }
    /// Caller journal/cache/projection output and work acknowledgement share the
    /// transaction. Any capture generated by admission causes a full rollback.
    @discardableResult func process(limit:Int=128,consume:([SyncOutgoingWork])throws->Void)throws->Int {
        guard (1...256).contains(limit) else {throw OSwindError.invalid("Invalid sync work batch limit")}
        return try scoped {
            try idleCapture()
            let row=try database.statement("SELECT w.ordinal,w.object_digest,w.deleted,w.last_seq,i.table_name,i.origin,i.lifetime FROM personal_sync_work w LEFT JOIN personal_sync_identities i USING(object_digest) ORDER BY w.ordinal LIMIT ?");defer {sqlite3_finalize(row)};sqlite3_bind_int(row,1,Int32(limit));var batch=[SyncOutgoingWork](),code=sqlite3_step(row)
            while code==SQLITE_ROW {
                guard let table=SyncCanonicalTable(rawValue:database.text(row,4)),(0...1).contains(sqlite3_column_int(row,2)) else {throw OSwindError.database("Sync work identity differs")}
                let identity=try SyncObjectIdentity(table:table,origin:database.text(row,5),lifetime:database.text(row,6)),deleted=sqlite3_column_int(row,2)==1
                guard try identity.key.digest==database.text(row,1),let object=try catalog.object(identity),object.deleted==deleted else {throw OSwindError.database("Sync work lifetime differs")}
                batch.append(.init(ordinal:sqlite3_column_int64(row,0),identity:identity,deleted:deleted,sequence:sqlite3_column_int64(row,3)));code=sqlite3_step(row)
            }
            guard code==SQLITE_DONE else {throw database.error()};try consume(batch);try idleCapture()
            for value in batch {
                let ack=try database.statement("DELETE FROM personal_sync_work WHERE ordinal=? AND object_digest=? AND deleted=? AND last_seq=?");defer {sqlite3_finalize(ack)}
                sqlite3_bind_int64(ack,1,value.ordinal);database.bind(ack,2,try value.identity.key.digest);sqlite3_bind_int(ack,3,value.deleted ? 1:0);sqlite3_bind_int64(ack,4,value.sequence);try database.done(ack)
                guard sqlite3_changes(database.handle)==1 else {throw OSwindError.invalid("Sync work changed during admission")}
            }
            return batch.count
        }
    }
}
