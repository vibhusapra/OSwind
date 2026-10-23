import Foundation
import CSQLite

enum RoutineSchema {
    static let sql="""
    CREATE TABLE IF NOT EXISTS routines(id TEXT PRIMARY KEY,revision INTEGER NOT NULL CHECK(revision>0),enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),next_due REAL NOT NULL,payload BLOB NOT NULL);
    CREATE INDEX IF NOT EXISTS routines_due ON routines(enabled,next_due);
    CREATE TABLE IF NOT EXISTS routine_runs(id TEXT PRIMARY KEY,routine_id TEXT NOT NULL REFERENCES routines(id) ON DELETE CASCADE,revision INTEGER NOT NULL CHECK(revision>0),scheduled_at REAL NOT NULL,started REAL NOT NULL,finished REAL,trigger TEXT NOT NULL CHECK(trigger IN ('manual','scheduled')),status TEXT NOT NULL CHECK(status IN ('running','completed','failed','cancelled','interrupted','skipped')),chat_id TEXT REFERENCES chat_sessions(id) ON DELETE SET NULL,message TEXT,scope BLOB NOT NULL);
    CREATE UNIQUE INDEX IF NOT EXISTS routine_slot ON routine_runs(routine_id,scheduled_at) WHERE trigger='scheduled';
    CREATE INDEX IF NOT EXISTS routine_history ON routine_runs(routine_id,started DESC);
    CREATE INDEX IF NOT EXISTS routine_active ON routine_runs(status,started);
    CREATE INDEX IF NOT EXISTS routine_run_time ON routine_runs(started DESC,id);
    CREATE INDEX IF NOT EXISTS routine_chat ON routine_runs(chat_id) WHERE chat_id IS NOT NULL;
    """
}
/// Only used while MemoryStore holds its recursive connection lock.
struct RoutineDatabase {
    let handle:OpaquePointer
    let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    func error() -> OSwindError {.database(String(cString:sqlite3_errmsg(handle)))}
    func execute(_ sql:String) throws {guard sqlite3_exec(handle,sql,nil,nil,nil)==SQLITE_OK else {throw error()}}
    func statement(_ sql:String) throws -> OpaquePointer {var result:OpaquePointer?;guard sqlite3_prepare_v2(handle,sql,-1,&result,nil)==SQLITE_OK,let result else {throw error()};return result}
    func text(_ row:OpaquePointer,_ column:Int32) -> String {guard let data=sqlite3_column_text(row,column) else {return ""};return String(decoding:UnsafeBufferPointer(start:data,count:Int(sqlite3_column_bytes(row,column))),as:UTF8.self)}
    func optional(_ row:OpaquePointer,_ column:Int32) -> String? {sqlite3_column_type(row,column)==SQLITE_NULL ? nil : text(row,column)}
    func bind(_ row:OpaquePointer,_ index:Int32,_ value:String?) {if let value {sqlite3_bind_text64(row,index,value,UInt64(value.utf8.count),transient,UInt8(SQLITE_UTF8))} else {sqlite3_bind_null(row,index)}}
    func bind<T:Encodable>(_ row:OpaquePointer,_ index:Int32,json:T) throws {let data=try JSONEncoder().encode(json);guard data.count<=32768 else {throw OSwindError.invalid("Routine payload exceeds 32 KiB")};_ = data.withUnsafeBytes {sqlite3_bind_blob(row,index,$0.baseAddress,Int32(data.count),transient)}}
    func decode<T:Decodable>(_ row:OpaquePointer,_ column:Int32,as:T.Type) throws -> T {let count=Int(sqlite3_column_bytes(row,column));guard count>0,count<=32768,let data=sqlite3_column_blob(row,column) else {throw OSwindError.database("Invalid routine payload")};return try JSONDecoder().decode(T.self,from:Data(bytes:data,count:count))}
    func done(_ row:OpaquePointer) throws {guard sqlite3_step(row)==SQLITE_DONE else {throw error()}}
    func transaction<T>(_ body:() throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {let result=try body();try Task.checkCancellation();try execute("COMMIT");return result} catch {try? execute("ROLLBACK");throw error}
    }
    func routine(_ id:String) throws -> StoredRoutine? {
        let row=try statement("SELECT payload,revision,next_due FROM routines WHERE id=?");defer {sqlite3_finalize(row)};bind(row,1,id)
        let status=sqlite3_step(row);if status==SQLITE_DONE {return nil};guard status==SQLITE_ROW else {throw error()}
        return StoredRoutine(definition:try decode(row,0,as:RoutineDefinition.self),revision:Int(sqlite3_column_int64(row,1)),nextDue:Date(timeIntervalSince1970:sqlite3_column_double(row,2)))
    }
    static let runColumns="r.id,r.routine_id,r.revision,r.scheduled_at,r.started,r.finished,r.trigger,r.status,r.chat_id,r.message,r.scope,EXISTS(SELECT 1 FROM chat_turns t WHERE t.session_id=r.chat_id)"
    func run(_ row:OpaquePointer) throws -> RoutineRun {
        guard let trigger=RoutineTrigger(rawValue:text(row,6)),let status=RoutineRunStatus(rawValue:text(row,7)) else {throw OSwindError.database("Invalid routine status")}
        return RoutineRun(id:text(row,0),routineID:text(row,1),revision:Int(sqlite3_column_int64(row,2)),scheduledAt:Date(timeIntervalSince1970:sqlite3_column_double(row,3)),started:Date(timeIntervalSince1970:sqlite3_column_double(row,4)),finished:sqlite3_column_type(row,5)==SQLITE_NULL ? nil : Date(timeIntervalSince1970:sqlite3_column_double(row,5)),trigger:trigger,status:status,chatID:optional(row,8),message:optional(row,9),filter:try decode(row,10,as:SearchFilter.self),resultAvailable:sqlite3_column_int(row,11) != 0)
    }
    func run(_ id:String) throws -> RoutineRun? {
        let row=try statement("SELECT \(Self.runColumns) FROM routine_runs r WHERE r.id=?");defer {sqlite3_finalize(row)};bind(row,1,id)
        let status=sqlite3_step(row);if status==SQLITE_DONE {return nil};guard status==SQLITE_ROW else {throw error()};return try run(row)
    }
}
extension MemoryStore {
    public func routines() throws -> [StoredRoutine] {
        try withRoutineDatabase {db in
            let row=try db.statement("SELECT payload,revision,next_due FROM routines ORDER BY next_due,id");defer {sqlite3_finalize(row)};var result=[StoredRoutine]();var code=sqlite3_step(row)
            while code==SQLITE_ROW {result.append(StoredRoutine(definition:try db.decode(row,0,as:RoutineDefinition.self),revision:Int(sqlite3_column_int64(row,1)),nextDue:Date(timeIntervalSince1970:sqlite3_column_double(row,2))));code=sqlite3_step(row)}
            guard code==SQLITE_DONE else {throw db.error()};return result
        }
    }
    @discardableResult public func saveRoutine(_ input:RoutineDefinition,expectedRevision:Int?=nil,now:Date=Date(),policy:PrivacyPolicy=PrivacyPolicy()) throws -> StoredRoutine {
        let value=try input.validated(policy:policy),next=try value.schedule.occurrence(relativeTo:now,next:true)
        return try withRoutineDatabase {db in try db.transaction {
            let current=try db.routine(value.id)
            guard current?.revision==expectedRevision else {throw OSwindError.invalid("Routine changed. Reload it before saving.")}
            if current==nil {
                let count=try db.statement("SELECT COUNT(*) FROM routines");defer {sqlite3_finalize(count)};guard sqlite3_step(count)==SQLITE_ROW,sqlite3_column_int(count,0)<100 else {throw OSwindError.invalid("At most 100 routines can be saved")}
            }
            guard (current?.revision ?? 0)<Int.max-1 else {throw OSwindError.invalid("Routine revision limit reached")}
            let revision=(current?.revision ?? 0)+1
            let row=try db.statement("INSERT INTO routines(id,revision,enabled,next_due,payload) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,enabled=excluded.enabled,next_due=excluded.next_due,payload=excluded.payload");defer {sqlite3_finalize(row)}
            db.bind(row,1,value.id);sqlite3_bind_int64(row,2,Int64(revision));sqlite3_bind_int(row,3,value.enabled ? 1:0);sqlite3_bind_double(row,4,next.timeIntervalSince1970);try db.bind(row,5,json:value);try db.done(row)
            return StoredRoutine(definition:value,revision:revision,nextDue:next)
        }}
    }
    public func deleteRoutine(_ id:String) throws {
        try withRoutineDatabase {db in try db.transaction {
            let chats=try db.statement("DELETE FROM chat_sessions WHERE id IN (SELECT chat_id FROM routine_runs WHERE routine_id=?)");defer {sqlite3_finalize(chats)};db.bind(chats,1,id);try db.done(chats)
            let row=try db.statement("DELETE FROM routines WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id);try db.done(row)
        }}
    }
    public func routineRuns(_ id:String?=nil,limit:Int=100) throws -> [RoutineRun] {
        try withRoutineDatabase {db in
            let row=try db.statement("SELECT \(RoutineDatabase.runColumns) FROM routine_runs r WHERE (? IS NULL OR r.routine_id=?) ORDER BY r.started DESC,r.id LIMIT ?");defer {sqlite3_finalize(row)};db.bind(row,1,id);db.bind(row,2,id);sqlite3_bind_int(row,3,Int32(min(1000,max(1,limit))))
            var result=[RoutineRun](),code=sqlite3_step(row)
            while code==SQLITE_ROW {result.append(try db.run(row));code=sqlite3_step(row)};guard code==SQLITE_DONE else {throw db.error()};return result
        }
    }
    func claimRoutine(id:String?=nil,now:Date) throws -> RoutineClaim? {
        try RoutineDefinition.validateDate(now)
        return try withRoutineDatabase {db in try db.transaction {
            let stale=try db.statement("UPDATE routine_runs SET status='interrupted',finished=?,message='Run interrupted; no automatic retry for this occurrence.' WHERE status='running' AND started<?");defer {sqlite3_finalize(stale)};sqlite3_bind_double(stale,1,now.timeIntervalSince1970);sqlite3_bind_double(stale,2,now.addingTimeInterval(-900).timeIntervalSince1970);try db.done(stale)
            let active=try db.statement("SELECT 1 FROM routine_runs WHERE status='running' LIMIT 1");defer {sqlite3_finalize(active)};let activeCode=sqlite3_step(active);if activeCode==SQLITE_ROW {return nil};guard activeCode==SQLITE_DONE else {throw db.error()}
            let selected:String
            if let id {selected=id} else {
                let due=try db.statement("SELECT id FROM routines WHERE enabled=1 AND next_due<=? ORDER BY next_due,id LIMIT 1");defer {sqlite3_finalize(due)};sqlite3_bind_double(due,1,now.timeIntervalSince1970);let code=sqlite3_step(due);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw db.error()};selected=db.text(due,0)
            }
            guard let routine=try db.routine(selected) else {throw OSwindError.invalid("Routine no longer exists")}
            _ = try routine.definition.validated()
            let slot=id==nil ? try routine.definition.schedule.occurrence(relativeTo:now,next:false):now
            let skipped=id==nil && now.timeIntervalSince(slot)>86400
            let run=RoutineRun(id:UUID().uuidString,routineID:selected,revision:routine.revision,scheduledAt:slot,started:now,finished:skipped ? now:nil,trigger:id==nil ? .scheduled:.manual,status:skipped ? .skipped:.running,chatID:nil,message:skipped ? "Missed occurrences coalesced; latest is older than 24 hours.":nil,filter:try routine.definition.filter(at:slot))
            if id==nil {
                let next=try routine.definition.schedule.occurrence(relativeTo:now,next:true),update=try db.statement("UPDATE routines SET next_due=? WHERE id=?");defer {sqlite3_finalize(update)};sqlite3_bind_double(update,1,next.timeIntervalSince1970);db.bind(update,2,selected);try db.done(update)
            }
            let row=try db.statement("INSERT INTO routine_runs(id,routine_id,revision,scheduled_at,started,finished,trigger,status,chat_id,message,scope) VALUES(?,?,?,?,?,?,?,?,NULL,?,?)");defer {sqlite3_finalize(row)}
            db.bind(row,1,run.id);db.bind(row,2,selected);sqlite3_bind_int64(row,3,Int64(run.revision));sqlite3_bind_double(row,4,slot.timeIntervalSince1970);sqlite3_bind_double(row,5,now.timeIntervalSince1970);if skipped {sqlite3_bind_double(row,6,now.timeIntervalSince1970)};db.bind(row,7,run.trigger.rawValue);db.bind(row,8,run.status.rawValue);db.bind(row,9,run.message);try db.bind(row,10,json:run.filter);try db.done(row)
            return RoutineClaim(routine:routine,run:run)
        }}
    }
    @discardableResult func finishRoutine(_ id:String,status:RoutineRunStatus,message:String?) throws -> RoutineRun? {
        guard [.failed,.cancelled,.interrupted].contains(status) else {throw OSwindError.invalid("Invalid routine terminal status")}
        return try withRoutineDatabase {db in
            let row=try db.statement("UPDATE routine_runs SET status=?,finished=?,message=? WHERE id=? AND status='running'");defer {sqlite3_finalize(row)};db.bind(row,1,status.rawValue);sqlite3_bind_double(row,2,Date().timeIntervalSince1970);db.bind(row,3,message);db.bind(row,4,id);try db.done(row);return try db.run(id)
        }
    }
    func completeRoutine(_ claim:RoutineClaim,answer:Answer,policy:PrivacyPolicy) throws -> RoutineRun? {
        try withRoutineDatabase {db in try db.transaction {
            guard let run=try db.run(claim.run.id),run.status == .running else {return try db.run(claim.run.id)}
            guard let current=try db.routine(run.routineID),current.revision==run.revision else {return try finishRoutine(run.id,status:.cancelled,message:"Routine changed before completion; result discarded.")}
            try Task.checkCancellation()
            let chat=try createChat(title:current.definition.title)
            _ = try appendChatTurn(sessionID:chat.id,question:current.definition.prompt,answer:answer,filter:run.filter,policy:policy)
            let title=try db.statement("UPDATE chat_sessions SET title=? WHERE id=?");defer {sqlite3_finalize(title)};db.bind(title,1,current.definition.title);db.bind(title,2,chat.id);try db.done(title)
            let row=try db.statement("UPDATE routine_runs SET status='completed',finished=?,chat_id=? WHERE id=? AND status='running'");defer {sqlite3_finalize(row)};sqlite3_bind_double(row,1,Date().timeIntervalSince1970);db.bind(row,2,chat.id);db.bind(row,3,run.id);try db.done(row)
            return try db.run(run.id)
        }}
    }
}
