import Foundation
import CSQLite

/// Internal creation-era capture for collection erasure. Installing this ledger
/// does not enable synchronization or make a collection control an approved peer
/// operation. The journal/transport/admission integration must still be completed.
/// Clocks here count collection wipes, independently of journal operation dots.
struct SyncCollectionHistory {
    let database:RoutineDatabase
    let replica:String

    private static let clockSQL="(SELECT CAST('{'||COALESCE(group_concat('\"'||replica||'\":'||counter,','),'')||'}' AS BLOB) FROM (SELECT replica,counter FROM personal_sync_collection_frontier ORDER BY replica))"
    private static let blobCheck="typeof(era)='blob' AND length(era)>=2 AND length(era)<=1048576"
    private static let schemas:[String:String]=[
        "personal_sync_collection_local":"CREATE TABLE personal_sync_collection_local(singleton INTEGER PRIMARY KEY CHECK(singleton=1),replica TEXT NOT NULL,counter INTEGER NOT NULL CHECK(typeof(counter)='integer' AND counter>=0))",
        "personal_sync_collection_frontier":"CREATE TABLE personal_sync_collection_frontier(replica TEXT PRIMARY KEY,counter INTEGER NOT NULL CHECK(typeof(counter)='integer' AND counter>0))",
        "personal_sync_collection_controls":"CREATE TABLE personal_sync_collection_controls(counter INTEGER PRIMARY KEY CHECK(counter>0),era BLOB NOT NULL CHECK(\(blobCheck)))",
        "personal_sync_collection_births":"CREATE TABLE personal_sync_collection_births(table_name TEXT NOT NULL,key_digest BLOB NOT NULL CHECK(typeof(key_digest)='blob' AND length(key_digest)=32),era BLOB NOT NULL CHECK(\(blobCheck)),PRIMARY KEY(table_name,key_digest))",
        "personal_sync_collection_changes":"CREATE TABLE personal_sync_collection_changes(sequence INTEGER PRIMARY KEY CHECK(sequence>0),era BLOB NOT NULL CHECK(\(blobCheck)))"
    ]

    static func install(_ db:RoutineDatabase,replica:String)throws->Self {
        try SyncProtocolLimits.uuid(replica)
        return try SyncChangeCapture.transaction(db) {
            let present=try db.statement("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'personal_sync_collection_%'")
            var installed=Set<String>(),code=sqlite3_step(present)
            while code==SQLITE_ROW {installed.insert(db.text(present,0));code=sqlite3_step(present)};sqlite3_finalize(present)
            guard code==SQLITE_DONE,installed.isEmpty || installed==Set(schemas.keys) else {throw OSwindError.database("Collection history schema is incomplete; preserve its state")}
            let fresh=installed.isEmpty
            for (name,sql) in schemas.sorted(by:{$0.key<$1.key}) {try require(db,name:name,sql:sql,allowCreate:fresh)}
            if fresh {
                let row=try db.statement("INSERT INTO personal_sync_collection_local VALUES(1,?,0)");defer {sqlite3_finalize(row)}
                db.bind(row,1,replica);try db.done(row)
            }
            let native=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('personal_sync_capture','personal_sync_changes')");defer {sqlite3_finalize(native)}
            guard sqlite3_step(native)==SQLITE_ROW else {throw db.error()}
            let nativeCount=sqlite3_column_int(native,0)
            guard nativeCount==0 || nativeCount==2 else {throw OSwindError.database("Native collection capture schema is incomplete")}
            if nativeCount==2 {for (name,sql) in triggers.sorted(by:{$0.key<$1.key}) {try require(db,name:name,sql:sql,allowCreate:fresh)}}
            let value=Self(database:db,replica:replica);_ = try value.current();return value
        }
    }

    private static func require(_ db:RoutineDatabase,name:String,sql:String,allowCreate:Bool)throws {
        let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
        let code=sqlite3_step(row)
        if code==SQLITE_ROW {guard db.text(row,0)==sql else {throw OSwindError.database("Collection history schema differs; preserve its state")}}
        else if code==SQLITE_DONE && allowCreate {try db.execute(sql)}
        else {throw OSwindError.database("Collection history schema member is missing; preserve its state")}
    }

    private static var triggers:[String:String] {
        var result=[String:String]()
        let active="(SELECT enabled=1 AND suppressed=0 FROM personal_sync_capture WHERE singleton=1)"
        for table in SyncChangeCapture.tables {
            let key=table.snapshot("new",true)
            // BEFORE INSERT also runs for an upsert. Existing native keys keep
            // their birth era, including keys predating ledger installation.
            let absent="NOT EXISTS(SELECT 1 FROM \(table.name) WHERE \(table.snapshot(table.name,true))=\(key))"
            for operation in ["insert","update"] {
                let name="sync_collection_birth_\(table.name)_\(operation)"
                let changed=operation=="insert" ? absent:"\(table.snapshot("old",true))!=\(key)"
                result[name]="CREATE TRIGGER \(name) BEFORE \(operation.uppercased()) ON \(table.name) WHEN \(active) AND \(changed) BEGIN INSERT INTO personal_sync_collection_births(table_name,key_digest,era) VALUES('\(table.name)',\(key),\(clockSQL)) ON CONFLICT(table_name,key_digest) DO UPDATE SET era=excluded.era; END"
            }
        }
        result["sync_collection_capture_era"]="CREATE TRIGGER sync_collection_capture_era AFTER INSERT ON personal_sync_changes WHEN new.after_row IS NOT NULL BEGIN INSERT INTO personal_sync_collection_changes(sequence,era) VALUES(new.seq,COALESCE((SELECT era FROM personal_sync_collection_births WHERE table_name=new.table_name AND key_digest=new.after_key),CAST('{}' AS BLOB))); END"
        result["sync_collection_capture_removed"]="CREATE TRIGGER sync_collection_capture_removed AFTER DELETE ON personal_sync_changes BEGIN DELETE FROM personal_sync_collection_changes WHERE sequence=old.seq; END"
        result["sync_collection_frontier_bound"]="CREATE TRIGGER sync_collection_frontier_bound BEFORE INSERT ON personal_sync_collection_frontier WHEN NOT EXISTS(SELECT 1 FROM personal_sync_collection_frontier WHERE replica=new.replica) BEGIN SELECT CASE WHEN (SELECT COUNT(*) FROM personal_sync_collection_frontier)>=64 THEN RAISE(ABORT,'Collection frontier exceeds peer bound') END; END"
        for operation in ["insert","update"] {
            let name="sync_collection_native_wipe_"+operation
            // Pure SQL runs in the actual native wipe transaction, including a
            // supported older writing connection. No delayed processor stamps
            // the event with a newer frontier. Retry-cleanup does not set this
            // marker and therefore does not manufacture an additional wipe.
            result[name]="CREATE TRIGGER \(name) AFTER \(operation.uppercased()) ON store_metadata WHEN new.key='library_wipe_dirty' AND new.value='1' BEGIN SELECT CASE WHEN (SELECT counter FROM personal_sync_collection_local WHERE singleton=1)=9223372036854775807 THEN RAISE(ABORT,'Collection wipe sequence exhausted') END; UPDATE personal_sync_collection_local SET counter=counter+1 WHERE singleton=1; INSERT INTO personal_sync_collection_frontier(replica,counter) SELECT replica,counter FROM personal_sync_collection_local WHERE singleton=1 ON CONFLICT(replica) DO UPDATE SET counter=excluded.counter; INSERT INTO personal_sync_collection_controls(counter,era) SELECT counter,\(clockSQL) FROM personal_sync_collection_local WHERE singleton=1; END"
        }
        return result
    }

    private func identity()throws->Int64 {
        let row=try database.statement("SELECT replica,counter FROM personal_sync_collection_local WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,database.text(row,0)==replica,sqlite3_column_type(row,1)==SQLITE_INTEGER,sqlite3_column_int64(row,1)>=0 else {throw OSwindError.invalid("Collection history identity differs")}
        return sqlite3_column_int64(row,1)
    }
    private func decode(_ row:OpaquePointer,_ column:Int32)throws->SyncClock {
        let size=Int(sqlite3_column_bytes(row,column))
        guard sqlite3_column_type(row,column)==SQLITE_BLOB,(2...SyncProtocolLimits.stateBytes).contains(size),let p=sqlite3_column_blob(row,column) else {throw OSwindError.invalid("Invalid collection era storage")}
        let data=Data(bytes:p,count:size),clock=try JSONDecoder().decode(SyncClock.self,from:data)
        guard try SyncProtocolLimits.encode(clock)==data else {throw OSwindError.invalid("Noncanonical collection era")};return clock
    }
    func current()throws->SyncClock {
        let counter=try identity(),row=try database.statement("SELECT \(Self.clockSQL)");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW else {throw database.error()};let clock=try decode(row,0)
        guard clock[replica]==counter else {throw OSwindError.invalid("Collection frontier differs from its local wipe sequence")};return clock
    }
    /// Nil is an unstamped legacy lifetime, not proof of a fresh creation.
    func birth(table:String,key:Data)throws->SyncClock? {
        _=try identity();guard SyncChangeCapture.tables.contains(where:{$0.name==table}),key.count==32 else {throw OSwindError.invalid("Invalid collection birth key")}
        let row=try database.statement("SELECT era FROM personal_sync_collection_births WHERE table_name=? AND key_digest=?");defer {sqlite3_finalize(row)};database.bind(row,1,table)
        key.withUnsafeBytes {_=sqlite3_bind_blob(row,2,$0.baseAddress,Int32(key.count),database.transient)}
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw database.error()};return try decode(row,0)
    }
    func captured(sequence:Int64)throws->SyncClock? {
        _=try identity();guard sequence>0 else {throw OSwindError.invalid("Invalid collection capture sequence")}
        let row=try database.statement("SELECT era FROM personal_sync_collection_changes WHERE sequence=?");defer {sqlite3_finalize(row)};sqlite3_bind_int64(row,1,sequence)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw database.error()};return try decode(row,0)
    }
    func pendingWipes(limit:Int=128)throws->[(counter:Int64,era:SyncClock)] {
        let frontier=try current();guard (1...256).contains(limit) else {throw OSwindError.invalid("Invalid collection control read bound")}
        let row=try database.statement("SELECT counter,era FROM personal_sync_collection_controls ORDER BY counter LIMIT ?");defer {sqlite3_finalize(row)};sqlite3_bind_int(row,1,Int32(limit))
        var values=[(counter:Int64,era:SyncClock)](),code=sqlite3_step(row)
        while code==SQLITE_ROW {
            let counter=sqlite3_column_int64(row,0),era=try decode(row,1)
            guard sqlite3_column_type(row,0)==SQLITE_INTEGER,counter>0,era[replica]==counter,frontier.covers(era) else {throw OSwindError.invalid("Collection control differs from its recorded frontier")}
            values.append((counter,era));code=sqlite3_step(row)
        }
        guard code==SQLITE_DONE else {throw database.error()};return values
    }
}
