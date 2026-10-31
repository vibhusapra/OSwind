import Foundation
import CSQLite

struct SyncCaptureTable:Sendable {
    let name:String
    let columns:[String]
    let primary:[String]
    init(_ name:String,_ columns:String,_ primary:String) {self.name=name;self.columns=columns.split(separator:",").map(String.init);self.primary=primary.split(separator:",").map(String.init)}
    func snapshot(_ alias:String,_ key:Bool=false)->String {(key ? "oswind_sync_key_v1(":"oswind_sync_row_v1(")+(key ? primary:columns).map {alias+"."+$0}.joined(separator:",")+")"}
}
struct SyncCapturedChange:Equatable,Sendable {
    let sequence:Int64
    let table:String
    let beforeKey:Data?,afterKey:Data?,afterRow:Data?
    let superseded:Bool
    var bytes:Int {128+(beforeKey?.count ?? 0)+(afterKey?.count ?? 0)+(afterRow?.count ?? 0)}
}
struct SyncCaptureScope:Equatable,Sendable {let origin:String;let generation:String}

/// Internal local intent capture only. Superseded bodies are purged and keys are
/// opaque digests. A complete typed erasure/current-policy processor is still required before enrollment
/// can be exposed to users. No row snapshot is an approved transport object.
enum SyncChangeCapture {
    static let tables:[SyncCaptureTable]=[
        .init("memories","id,timestamp,kind,app,title,url,text,favorite,payload","id"),
        .init("chat_sessions","id,title,created,updated","id"),
        .init("chat_turns","id,session_id,timestamp,payload","id"),
        .init("chat_sources","turn_id,memory_id,ordinal,score,match,passage_start,passage_length,owner_id,historical_handle","turn_id,ordinal"),
        .init("recap_sources","recap_id,source_id,ordinal,revision,score,match,passage_start,passage_length,owner_id,historical_handle","recap_id,ordinal"),
        .init("routines","id,revision,payload","id"),
        .init("routine_runs","id,routine_id,revision,scheduled_at,started,finished,trigger,status,chat_id,message,scope","id"),
        .init("memory_entities","id,kind,name,detail,curated,created","id"),
        .init("entity_aliases","entity_id,kind,key,label","kind,key"),
        .init("entity_mentions","memory_id,entity_id,origin,revision,start,length,surface,method","memory_id,entity_id,origin"),
        .init("entity_ignored","memory_id,kind,key","memory_id,kind,key"),
        .init("entity_project_ignored","memory_id,entity_id","memory_id,entity_id"),
        .init("text_observation_pins","memory_id","memory_id")
    ]
    static let maximumQueueBytes:Int64=8*1024*1024*1024
    static let defaultQueueBytes:Int64=1024*1024*1024
    static func register(on db:RoutineDatabase)throws {try SyncRowSnapshot.register(on:db)}
    private static func trigger(_ table:SyncCaptureTable,_ operation:String)->String {
        let insert=operation=="insert",delete=operation=="delete",after=delete ? "NULL":table.snapshot("new")
        let beforeKey=insert ? "NULL":table.snapshot("old",true),afterKey=delete ? "NULL":table.snapshot("new",true)
        let changed=operation=="update" ? " AND ("+table.columns.map {"old.\($0) IS NOT new.\($0)"}.joined(separator:" OR ")+")":""
        let update=operation=="update" ? " OF "+table.columns.joined(separator:","):""
        return """
        CREATE TRIGGER sync_capture_\(table.name)_\(operation) AFTER \(operation.uppercased())\(update) ON \(table.name)
        WHEN (SELECT enabled=1 FROM personal_sync_capture WHERE singleton=1)\(changed)
        BEGIN
            SELECT CASE WHEN COALESCE((SELECT synchronous FROM pragma_synchronous),0)<2 OR COALESCE((SELECT recursive_triggers FROM pragma_recursive_triggers),0)<>1 THEN RAISE(ABORT,'Prepare sync capture durability before writing') END;
            UPDATE personal_sync_changes SET after_row=NULL,superseded=1 WHERE table_name='\(table.name)' AND after_row IS NOT NULL AND after_key IN (\(beforeKey),\(afterKey)) AND (SELECT suppressed=0 FROM personal_sync_capture WHERE singleton=1);
            INSERT INTO personal_sync_changes(table_name,before_key,after_key,after_row) SELECT '\(table.name)',\(beforeKey),\(afterKey),\(after) WHERE (SELECT suppressed=0 FROM personal_sync_capture WHERE singleton=1);
        END
        """
    }
    static func validateLegacyCitationTriggers(_ db:RoutineDatabase,table:SyncCanonicalTable)throws {
        let old=CitationSchema.legacy(table)
        for operation in ["insert","update","delete"] {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,"sync_capture_"+table.rawValue+"_"+operation)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==trigger(old,operation) else {throw OSwindError.database("Legacy citation capture protection differs")}
        }
    }
    static func install(on db:RoutineDatabase,sourceVersion:Int32,repairMissingPins:Bool=false,repairCitationUpgrade:Bool=false)throws {
        if sourceVersion>=25 {
            for name in ["personal_sync_capture","personal_sync_changes"] {
                let existing=try db.statement("SELECT type FROM sqlite_master WHERE name=?");db.bind(existing,1,name)
                let valid=sqlite3_step(existing)==SQLITE_ROW && db.text(existing,0)=="table";sqlite3_finalize(existing)
                guard valid else {throw OSwindError.database("Sync capture state table missing")}
            }
            let count=try db.statement("SELECT COUNT(*) FROM personal_sync_capture");defer {sqlite3_finalize(count)}
            guard sqlite3_step(count)==SQLITE_ROW,sqlite3_column_int(count,0)==1 else {throw OSwindError.database("Sync capture identity missing")}
        }
        try db.execute("""
        CREATE TABLE IF NOT EXISTS personal_sync_capture(singleton INTEGER PRIMARY KEY CHECK(singleton=1),origin TEXT NOT NULL,generation TEXT NOT NULL,enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),suppressed INTEGER NOT NULL CHECK(suppressed BETWEEN 0 AND 16),used_bytes INTEGER NOT NULL CHECK(typeof(used_bytes)='integer' AND used_bytes>=0 AND used_bytes<=budget),budget INTEGER NOT NULL CHECK(typeof(budget)='integer' AND budget>0 AND budget<=8589934592));
        CREATE TABLE IF NOT EXISTS personal_sync_changes(seq INTEGER PRIMARY KEY AUTOINCREMENT,table_name TEXT NOT NULL,before_key BLOB CHECK(before_key IS NULL OR (typeof(before_key)='blob' AND length(before_key)=32)),after_key BLOB CHECK(after_key IS NULL OR (typeof(after_key)='blob' AND length(after_key)=32)),after_row BLOB,superseded INTEGER NOT NULL DEFAULT 0 CHECK(superseded IN (0,1)),CHECK(before_key IS NOT NULL OR after_key IS NOT NULL),CHECK(after_row IS NULL OR after_key IS NOT NULL),CHECK(superseded=0 OR (after_row IS NULL AND after_key IS NOT NULL)));
        CREATE INDEX IF NOT EXISTS personal_sync_changes_live ON personal_sync_changes(table_name,after_key) WHERE after_row IS NOT NULL;
        """)
        let row=try db.statement("INSERT INTO personal_sync_capture VALUES(1,?,?,0,0,0,?) ON CONFLICT(singleton) DO NOTHING");defer {sqlite3_finalize(row)}
        db.bind(row,1,UUID().uuidString.lowercased());db.bind(row,2,UUID().uuidString.lowercased());sqlite3_bind_int64(row,3,defaultQueueBytes);try db.done(row)
        let size="128+COALESCE(length(new.before_key),0)+COALESCE(length(new.after_key),0)+COALESCE(length(new.after_row),0)"
        let oldSize=size.replacingOccurrences(of:"new.",with:"old.")
        var triggers=[String:String]()
        triggers["sync_capture_budget"]="CREATE TRIGGER sync_capture_budget BEFORE INSERT ON personal_sync_changes BEGIN SELECT CASE WHEN (SELECT used_bytes+\(size)>budget FROM personal_sync_capture WHERE singleton=1) THEN RAISE(ABORT,'Sync capture queue is full') END; END"
        triggers["sync_capture_added"]="CREATE TRIGGER sync_capture_added AFTER INSERT ON personal_sync_changes BEGIN UPDATE personal_sync_capture SET used_bytes=used_bytes+\(size) WHERE singleton=1; END"
        triggers["sync_capture_removed"]="CREATE TRIGGER sync_capture_removed AFTER DELETE ON personal_sync_changes BEGIN UPDATE personal_sync_capture SET used_bytes=used_bytes-(\(oldSize)) WHERE singleton=1; END"
        triggers["sync_capture_replaced"]="CREATE TRIGGER sync_capture_replaced AFTER UPDATE OF after_row ON personal_sync_changes BEGIN UPDATE personal_sync_capture SET used_bytes=used_bytes+(\(size))-(\(oldSize)) WHERE singleton=1; END"
        for table in tables {
            let info=try db.statement("SELECT name,pk FROM pragma_table_info(?)");db.bind(info,1,table.name);var columns=Set<String>(),primary=[(Int32,String)](),status=sqlite3_step(info)
            while status==SQLITE_ROW {let name=db.text(info,0);columns.insert(name);let ordinal=sqlite3_column_int(info,1);if ordinal>0 {primary.append((ordinal,name))};status=sqlite3_step(info)};sqlite3_finalize(info)
            let derived:Set<String>=table.name=="memories" ? ["embedding","embedding_model"]:(table.name=="routines" ? ["enabled","next_due"]:[])
            guard status==SQLITE_DONE,Set(table.columns).union(derived)==columns,primary.sorted(by:{$0.0<$1.0}).map({$0.1})==table.primary else {throw OSwindError.database("Canonical sync capture schema differs")}
            for operation in ["insert","update","delete"] {triggers["sync_capture_\(table.name)_\(operation)"]=trigger(table,operation)}
        }
        for (name,sql) in triggers.sorted(by:{$0.key<$1.key}) {
            let existing=try db.statement("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?");db.bind(existing,1,name);let status=sqlite3_step(existing),found=status==SQLITE_ROW ? db.text(existing,0):nil;sqlite3_finalize(existing)
            guard status==SQLITE_ROW || status==SQLITE_DONE else {throw db.error()}
            if let found {guard found==sql else {throw OSwindError.database("Sync capture trigger differs; preserve the library and repair its schema")}}
            else {guard sourceVersion<25 || (repairMissingPins && name.hasPrefix("sync_capture_text_observation_pins_")) || (repairCitationUpgrade && (name.hasPrefix("sync_capture_chat_sources_") || name.hasPrefix("sync_capture_recap_sources_"))) else {throw OSwindError.database("Sync capture trigger missing")};try db.execute(sql)}
        }
        _=try scope(db)
    }
    static func prepareWriterIfActive(_ db:RoutineDatabase)throws {
        guard sqlite3_get_autocommit(db.handle) != 0 else {return}
        let row=try db.statement("SELECT enabled FROM personal_sync_capture WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()}
        if sqlite3_column_int(row,0)==1 {try prepare(db)}
    }
    static func prepare(_ db:RoutineDatabase)throws {
        guard sqlite3_get_autocommit(db.handle) != 0 else {throw OSwindError.invalid("Prepare sync capture outside a transaction")}
        try db.execute("PRAGMA synchronous=FULL; PRAGMA recursive_triggers=ON")
    }
    static func scope(_ db:RoutineDatabase)throws->SyncCaptureScope {
        let row=try db.statement("SELECT origin,generation,enabled,suppressed,used_bytes,budget FROM personal_sync_capture WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.database("Sync capture scope missing")}
        let value=SyncCaptureScope(origin:db.text(row,0),generation:db.text(row,1));try SyncProtocolLimits.uuid(value.origin);try SyncProtocolLimits.uuid(value.generation)
        guard (0...1).contains(sqlite3_column_int(row,2)),(0...16).contains(sqlite3_column_int(row,3)),sqlite3_column_int64(row,4)>=0,sqlite3_column_int64(row,4)<=sqlite3_column_int64(row,5),(1...maximumQueueBytes).contains(sqlite3_column_int64(row,5)),(2...5).allSatisfy({sqlite3_column_type(row,Int32($0))==SQLITE_INTEGER}) else {throw OSwindError.database("Invalid sync capture state")};return value
    }
    static func activate(_ db:RoutineDatabase,budget:Int64=defaultQueueBytes)throws->SyncCaptureScope {
        guard (1...maximumQueueBytes).contains(budget) else {throw OSwindError.invalid("Invalid sync capture queue budget")}
        try prepare(db)
        return try transaction(db) {
            let current=try scope(db),row=try db.statement("UPDATE personal_sync_capture SET enabled=1,budget=? WHERE singleton=1 AND used_bytes<=?");defer {sqlite3_finalize(row)}
            sqlite3_bind_int64(row,1,budget);sqlite3_bind_int64(row,2,budget);try db.done(row);guard sqlite3_changes(db.handle)==1 else {throw OSwindError.invalid("Sync capture budget is smaller than retained changes")};return current
        }
    }
    static func transaction<T>(_ db:RoutineDatabase,_ body:()throws->T)throws->T {
        try Task.checkCancellation();let outer=sqlite3_get_autocommit(db.handle) != 0
        try db.execute(outer ? "BEGIN IMMEDIATE":"SAVEPOINT sync_capture_scope")
        do {let value=try body();try Task.checkCancellation();try db.execute(outer ? "COMMIT":"RELEASE sync_capture_scope");return value}
        catch {try? db.execute(outer ? "ROLLBACK":"ROLLBACK TO sync_capture_scope; RELEASE sync_capture_scope");throw error}
    }
    static func withoutEcho<T>(_ db:RoutineDatabase,scope expected:SyncCaptureScope,_ body:()throws->T)throws->T {
        try transaction(db) {
            guard try scope(db)==expected else {throw OSwindError.invalid("Sync capture scope changed")}
            let pending=try db.statement("SELECT EXISTS(SELECT 1 FROM personal_sync_changes LIMIT 1)");defer {sqlite3_finalize(pending)}
            guard sqlite3_step(pending)==SQLITE_ROW,sqlite3_column_int(pending,0)==0 else {throw OSwindError.unavailable("Process pending local changes before applying peer changes")}
            try SyncOutgoingWorkQueue.requireNoPending(db)
            try db.execute("UPDATE personal_sync_capture SET suppressed=suppressed+1 WHERE singleton=1")
            let result=try body();try db.execute("UPDATE personal_sync_capture SET suppressed=suppressed-1 WHERE singleton=1");return result
        }
    }
    static func changes(_ db:RoutineDatabase,scope expected:SyncCaptureScope,after:Int64=0,limit:Int=128,byteLimit:Int=4*1024*1024)throws->[SyncCapturedChange] {
        guard after>=0,(1...256).contains(limit),(1...2*SyncRowSnapshot.maximumBytes+131072).contains(byteLimit),try scope(db)==expected else {throw OSwindError.invalid("Invalid sync capture read scope or bound")}
        let row=try db.statement("SELECT seq,table_name,before_key,after_key,after_row,superseded FROM personal_sync_changes WHERE seq>? ORDER BY seq LIMIT ?");defer {sqlite3_finalize(row)}
        sqlite3_bind_int64(row,1,after);sqlite3_bind_int(row,2,Int32(limit));var result=[SyncCapturedChange](),used=0,status=sqlite3_step(row)
        while status==SQLITE_ROW {
            let name=db.text(row,1);guard let table=tables.first(where:{$0.name==name}) else {throw OSwindError.invalid("Unknown canonical change table")}
            var size=128;for column:Int32 in 2...4 {let n=Int(sqlite3_column_bytes(row,column));guard n<=SyncRowSnapshot.maximumBytes else {throw OSwindError.invalid("Oversized captured row")};size+=n}
            if size>byteLimit-used {guard !result.isEmpty else {throw OSwindError.unavailable("Captured row exceeds the requested read budget")};break}
            func value(_ column:Int32,_ width:Int?)throws->Data? {
                if sqlite3_column_type(row,column)==SQLITE_NULL {return nil}
                guard sqlite3_column_type(row,column)==SQLITE_BLOB,let p=sqlite3_column_blob(row,column) else {throw OSwindError.invalid("Invalid captured row storage")}
                let data=Data(bytes:p,count:Int(sqlite3_column_bytes(row,column)))
                if let width {guard try SyncRowSnapshot.decode(data).cells.count==width else {throw OSwindError.invalid("Captured row schema differs")}}else{guard data.count==32 else {throw OSwindError.invalid("Captured key differs")}};return data
            }
            let change=try SyncCapturedChange(sequence:sqlite3_column_int64(row,0),table:name,beforeKey:value(2,nil),afterKey:value(3,nil),afterRow:value(4,table.columns.count),superseded:sqlite3_column_int(row,5)==1)
            guard change.sequence>after,sqlite3_column_type(row,5)==SQLITE_INTEGER,(0...1).contains(sqlite3_column_int(row,5)),change.superseded ? (change.afterKey != nil && change.afterRow==nil):((change.afterKey != nil)==(change.afterRow != nil)),change.beforeKey != nil || change.afterKey != nil else {throw OSwindError.invalid("Invalid captured mutation")}
            result.append(change);used+=size;status=sqlite3_step(row)
        }
        guard status==SQLITE_ROW || status==SQLITE_DONE else {throw db.error()};return result
    }
    /// Consume only in the processor's transaction, together with its validated
    /// protocol/cache writes. Raw acknowledgement is not a user-facing API.
    static func acknowledge(_ db:RoutineDatabase,scope expected:SyncCaptureScope,through:Int64)throws {
        guard sqlite3_get_autocommit(db.handle)==0,through>=0,try scope(db)==expected else {throw OSwindError.invalid("Acknowledge changes in their scoped processor transaction")}
        let row=try db.statement("DELETE FROM personal_sync_changes WHERE seq<=?");defer {sqlite3_finalize(row)};sqlite3_bind_int64(row,1,through);try db.done(row)
    }
}
