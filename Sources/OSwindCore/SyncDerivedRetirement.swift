import Foundation
import CSQLite

/// Connection-local metadata collector around an admitted peer mutation. Native FK
/// cascades and reviewed cache-only evidence owners acquire real journal
/// barriers in the same transaction. No deleted body or archive-wide key scan.
enum SyncDerivedRetirement {
    static let queue="oswind_peer_retirements"
    static let state="oswind_peer_retirement_state"
    private static let schemas:[String:String] = {
        var schemas=[queue:"CREATE TABLE \(queue)(object_digest TEXT PRIMARY KEY,table_name TEXT NOT NULL) WITHOUT ROWID",state:"CREATE TABLE \(state)(singleton INTEGER PRIMARY KEY CHECK(singleton=1),active INTEGER NOT NULL CHECK(active IN(0,1)))"]
        for table in SyncCanonicalTable.allCases {
            let name="oswind_peer_retirement_"+table.rawValue
            schemas[name]="""
            CREATE TRIGGER \(name) AFTER DELETE ON main.\(table.rawValue)
            WHEN (SELECT active FROM \(state) WHERE singleton=1)=1 BEGIN
                INSERT OR IGNORE INTO \(queue)
                SELECT i.object_digest,i.table_name FROM main.personal_sync_identity_current c
                JOIN main.personal_sync_identities i ON i.object_digest=c.object_digest
                WHERE c.table_name='\(table.rawValue)' AND c.local_key=\(table.schema.snapshot("old",true))
                AND i.table_name=c.table_name AND i.deleted=0;
            END
            """
        };return schemas
    }()
    private static func prepare(_ db:RoutineDatabase)throws {
        let row=try db.statement("SELECT name,sql FROM sqlite_temp_master WHERE name='\(queue)' OR name GLOB 'oswind_peer_retirement_*'")
        var found=[String:String](),code=sqlite3_step(row)
        while code==SQLITE_ROW {found[db.text(row,0)]=db.text(row,1);code=sqlite3_step(row)};sqlite3_finalize(row)
        guard code==SQLITE_DONE else {throw db.error()}
        if found.isEmpty {
            for name in [queue,state] {try db.execute(schemas[name]!.replacingOccurrences(of:"CREATE TABLE ",with:"CREATE TEMP TABLE "))}
            try db.execute("INSERT INTO temp.\(state) VALUES(1,0)")
            for (name,sql) in schemas.sorted(by:{$0.key<$1.key}) where name != queue && name != state {
                try db.execute(sql.replacingOccurrences(of:"CREATE TRIGGER ",with:"CREATE TEMP TRIGGER "))
            }
        }else {guard found==schemas else {throw OSwindError.database("Connection-local retirement protection differs")}}
        guard try db.eraseCount("SELECT count(*) FROM temp.\(state) WHERE singleton=1 AND active=0")==1,try db.eraseCount("SELECT count(*) FROM temp.\(queue)")==0 else {throw OSwindError.invalid("Peer retirement collector is already active or not empty")}
    }
    private static func finish(_ db:RoutineDatabase)throws {
        // DML only: the outer journal can retain active prepared statements.
        // TEMP schemas live on this connection, stay inactive between receipts,
        // and are absent from SQLite backup and public library formats.
        try db.execute("DELETE FROM temp.\(queue); UPDATE temp.\(state) SET active=0 WHERE singleton=1")
    }
    static func enqueue(_ identities:[SyncObjectIdentity],db:RoutineDatabase)throws {
        guard try db.eraseCount("SELECT count(*) FROM temp.\(state) WHERE singleton=1 AND active=1")==1 else {throw OSwindError.invalid("No active peer retirement collector")}
        let row=try db.statement("INSERT OR IGNORE INTO temp.\(queue) VALUES(?,?)");defer {sqlite3_finalize(row)}
        for identity in identities {
            try Task.checkCancellation();sqlite3_reset(row);sqlite3_clear_bindings(row)
            db.bind(row,1,try identity.key.digest);db.bind(row,2,identity.table.rawValue);try db.done(row)
        }
    }
    static func collect(cache:SyncVersionStore,root:SyncObjectKey,deleting:Bool=true,body:()throws->Void,retire:(SyncObjectKey)throws->Void)throws {
        let db=cache.database
        let rootState=try cache.journal.state(for:root)
        guard sqlite3_get_autocommit(db.handle)==0,deleting ? rootState.isDeleted:(!rootState.isDeleted && rootState.heads.count==1) else {throw OSwindError.invalid("Peer retirement requires its admitted owning transaction")}
        try prepare(db)
        do {
            try db.execute("UPDATE temp.\(state) SET active=1 WHERE singleton=1")
            try body()
            var observedRoot=false
            while true {
                try Task.checkCancellation()
                let row=try db.statement("SELECT object_digest,table_name FROM temp.\(queue) ORDER BY object_digest LIMIT 1")
                let code=sqlite3_step(row)
                if code==SQLITE_DONE {sqlite3_finalize(row);break}
                guard code==SQLITE_ROW,let table=SyncCanonicalTable(rawValue:db.text(row,1)) else {sqlite3_finalize(row);throw OSwindError.database("Derived retirement key differs")}
                let key:SyncObjectKey
                do {key=try .init(kind:table.kind,digest:db.text(row,0));sqlite3_finalize(row)}catch {sqlite3_finalize(row);throw error}
                let done=try db.statement("DELETE FROM temp.\(queue) WHERE object_digest=?");db.bind(done,1,key.digest)
                do {try db.done(done);sqlite3_finalize(done)}catch {sqlite3_finalize(done);throw error}
                guard key != root else {continue}
                func apply()throws {
                    if try cache.catalog.nativeExists(for:key) {try retire(key)}
                    else {try cache.catalog.deletePeerKey(key,journal:cache.journal) {_ in}}
                    try cache.finishDeletedObject(key)
                }
                if try cache.journal.state(for:key).isDeleted {try apply()}
                else {
                    // Only publication inside this callback needs the root
                    // clock before the outer receive advances its cursor.
                    if !observedRoot {try cache.journal.observeAppliedRoot(root);observedRoot=true}
                    _=try cache.journal.delete(key:key) {_ in try apply()}
                }
            }
            try finish(db)
        }catch {try? finish(db);throw error}
    }
}
