import Foundation
import CSQLite

struct SyncJournalChange {
    let revision:SyncRevision
    let before:SyncRegister
    let after:SyncRegister
}
struct SyncReceiveResult:Equatable {let inserted:Bool;let applied:Int}

// Uses its caller's SQLite connection. A typed library adapter can mutate the
// source row inside the same transaction callback as state/outbox/cursor writes.
// Installation is internal and opt-in; MemoryStore does not install these tables
// yet. Public enrollment must add schema/version fences before using this layer.
struct SyncJournal {
    let database:RoutineDatabase
    let replica:String
    let group:String
    let epoch:String
    static let pendingLimit=4096
    init(database:RoutineDatabase,replica:String,group:String,epoch:String)throws {
        try SyncProtocolLimits.uuid(replica);try SyncProtocolLimits.uuid(group);try SyncProtocolLimits.uuid(epoch)
        self.database=database;self.replica=replica;self.group=group;self.epoch=epoch
        let row=try database.statement("SELECT replica,group_id,epoch FROM personal_sync_local WHERE singleton=1")
        defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,database.text(row,0)==replica,database.text(row,1)==group,database.text(row,2)==epoch else {throw OSwindError.invalid("Sync workspace identity differs")}
    }
    static func install(database db:RoutineDatabase,replica:String,group:String,epoch:String)throws->Self {
        try SyncProtocolLimits.uuid(replica);try SyncProtocolLimits.uuid(group);try SyncProtocolLimits.uuid(epoch)
        try prepareConnection(db)
        try transaction(db) {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS personal_sync_local(singleton INTEGER PRIMARY KEY CHECK(singleton=1),replica TEXT NOT NULL,group_id TEXT NOT NULL,epoch TEXT NOT NULL,sequence INTEGER NOT NULL CHECK(sequence>=0));
            CREATE TABLE IF NOT EXISTS personal_sync_peers(replica TEXT PRIMARY KEY,cursor INTEGER NOT NULL CHECK(cursor>=0));
            CREATE TABLE IF NOT EXISTS personal_sync_registers(kind TEXT NOT NULL,digest TEXT NOT NULL,state BLOB NOT NULL,PRIMARY KEY(kind,digest));
            CREATE TABLE IF NOT EXISTS personal_sync_receipts(replica TEXT NOT NULL,sequence INTEGER NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(replica,sequence));
            CREATE TABLE IF NOT EXISTS personal_sync_outbox(sequence INTEGER PRIMARY KEY,revision BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS personal_sync_pending(replica TEXT NOT NULL,sequence INTEGER NOT NULL,revision BLOB NOT NULL,PRIMARY KEY(replica,sequence));
            """)
            let row=try db.statement("INSERT INTO personal_sync_local(singleton,replica,group_id,epoch,sequence) VALUES(1,?,?,?,0) ON CONFLICT(singleton) DO NOTHING")
            defer {sqlite3_finalize(row)};db.bind(row,1,replica);db.bind(row,2,group);db.bind(row,3,epoch);try db.done(row)
            let peer=try db.statement("INSERT INTO personal_sync_peers(replica,cursor) VALUES(?,0) ON CONFLICT(replica) DO NOTHING")
            defer {sqlite3_finalize(peer)};db.bind(peer,1,replica);try db.done(peer)
            _=try Self(database:db,replica:replica,group:group,epoch:epoch)
        }
        return try Self(database:db,replica:replica,group:group,epoch:epoch)
    }
    // Must be called outside an active transaction on every writing connection.
    // The eventual MemoryStore enrollment hook will do this on reopen too.
    static func prepareConnection(_ db:RoutineDatabase)throws {
        guard sqlite3_get_autocommit(db.handle) != 0 else {throw OSwindError.invalid("Prepare sync durability outside an active transaction")}
        try db.execute("PRAGMA synchronous=FULL")
    }
    private static func transaction<T>(_ db:RoutineDatabase,_ body:()throws->T)throws->T {
        try Task.checkCancellation()
        let outer=sqlite3_get_autocommit(db.handle) != 0
        try db.execute(outer ? "BEGIN IMMEDIATE":"SAVEPOINT personal_sync_operation")
        do {let result=try body();try Task.checkCancellation();try db.execute(outer ? "COMMIT":"RELEASE personal_sync_operation");return result}
        catch {try? db.execute(outer ? "ROLLBACK":"ROLLBACK TO personal_sync_operation; RELEASE personal_sync_operation");throw error}
    }
    private func validateIdentity()throws {_ = try Self(database:database,replica:replica,group:group,epoch:epoch)}
    private func scoped<T>(_ body:()throws->T)throws->T {
        try Self.transaction(database) {
            try validateIdentity()
            let mode=try database.statement("PRAGMA synchronous");defer {sqlite3_finalize(mode)}
            guard sqlite3_step(mode)==SQLITE_ROW,sqlite3_column_int(mode,0)>=2 else {throw OSwindError.invalid("Sync writes require a prepared durable connection")}
            return try body()
        }
    }
    private func blob(_ row:OpaquePointer,_ column:Int32,limit:Int)throws->Data {
        let size=Int(sqlite3_column_bytes(row,column))
        guard sqlite3_column_type(row,column)==SQLITE_BLOB,size>0,size<=limit,let bytes=sqlite3_column_blob(row,column) else {throw OSwindError.invalid("Invalid sync journal record")}
        return Data(bytes:bytes,count:size)
    }
    private func bind(_ row:OpaquePointer,_ index:Int32,_ data:Data) {
        _=data.withUnsafeBytes {sqlite3_bind_blob(row,index,$0.baseAddress,Int32(data.count),database.transient)}
    }
    func allowPeer(_ id:String)throws {
        try SyncProtocolLimits.uuid(id)
        try scoped {
            if try readCursor(for:id) != nil {return}
            let count=try database.statement("SELECT COUNT(*) FROM personal_sync_peers");defer {sqlite3_finalize(count)}
            guard sqlite3_step(count)==SQLITE_ROW,sqlite3_column_int64(count,0)<Int64(SyncProtocolLimits.peers) else {throw OSwindError.invalid("Sync peer membership exceeds its bound")}
            let row=try database.statement("INSERT INTO personal_sync_peers(replica,cursor) VALUES(?,0)");defer {sqlite3_finalize(row)};database.bind(row,1,id);try database.done(row)
        }
    }
    func cursor(for id:String)throws->Int64? {try validateIdentity();return try readCursor(for:id)}
    private func readCursor(for id:String)throws->Int64? {
        let row=try database.statement("SELECT cursor FROM personal_sync_peers WHERE replica=?");defer {sqlite3_finalize(row)};database.bind(row,1,id)
        let status=sqlite3_step(row);if status==SQLITE_DONE {return nil}
        guard status==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_INTEGER,sqlite3_column_int64(row,0)>=0 else {throw OSwindError.invalid("Invalid sync cursor")}
        return sqlite3_column_int64(row,0)
    }
    func state(for key:SyncObjectKey)throws->SyncRegister {try validateIdentity();return try readState(for:key)}
    private func readState(for key:SyncObjectKey)throws->SyncRegister {
        let row=try database.statement("SELECT state FROM personal_sync_registers WHERE kind=? AND digest=?")
        defer {sqlite3_finalize(row)};database.bind(row,1,key.kind.rawValue);database.bind(row,2,key.digest)
        let status=sqlite3_step(row);if status==SQLITE_DONE {return SyncRegister(key:key)}
        guard status==SQLITE_ROW else {throw database.error()}
        let state=try SyncRegister.decode(blob(row,0,limit:SyncProtocolLimits.stateBytes))
        guard state.key==key else {throw OSwindError.invalid("Sync register identity differs")};return state
    }
    private func save(_ value:SyncRegister)throws {
        let row=try database.statement("INSERT INTO personal_sync_registers(kind,digest,state) VALUES(?,?,?) ON CONFLICT(kind,digest) DO UPDATE SET state=excluded.state")
        defer {sqlite3_finalize(row)};database.bind(row,1,value.key.kind.rawValue);database.bind(row,2,value.key.digest);bind(row,3,try value.encoded());try database.done(row)
    }
    private func recordReceipt(_ revision:SyncRevision,data:Data)throws->Bool {
        let digest=SyncProtocolLimits.hex(data)
        let existing=try database.statement("SELECT digest FROM personal_sync_receipts WHERE replica=? AND sequence=?")
        defer {sqlite3_finalize(existing)};database.bind(existing,1,revision.dot.replica);sqlite3_bind_int64(existing,2,revision.dot.counter)
        let status=sqlite3_step(existing)
        if status==SQLITE_ROW {guard database.text(existing,0)==digest else {throw OSwindError.invalid("Sync writer reused a durable sequence")};return false}
        guard status==SQLITE_DONE else {throw database.error()}
        let row=try database.statement("INSERT INTO personal_sync_receipts(replica,sequence,digest) VALUES(?,?,?)")
        defer {sqlite3_finalize(row)};database.bind(row,1,revision.dot.replica);sqlite3_bind_int64(row,2,revision.dot.counter);database.bind(row,3,digest);try database.done(row);return true
    }
    @discardableResult func put(key:SyncObjectKey,content:SyncContentReference,apply:(SyncJournalChange)throws->Void={_ in})throws->SyncRevision {
        try local(key:key,mutation:.put,content:content,apply:apply)
    }
    @discardableResult func delete(key:SyncObjectKey,apply:(SyncJournalChange)throws->Void={_ in})throws->SyncRevision {
        try local(key:key,mutation:.delete,content:nil,apply:apply)
    }
    @discardableResult func resolve(key:SyncObjectKey,expectedHeads:Set<SyncDot>,content:SyncContentReference,apply:(SyncJournalChange)throws->Void={_ in})throws->SyncRevision {
        try local(key:key,mutation:.put,content:content,resolution:expectedHeads,apply:apply)
    }
    private func local(key:SyncObjectKey,mutation:SyncMutation,content:SyncContentReference?,resolution:Set<SyncDot>?=nil,apply:(SyncJournalChange)throws->Void)throws->SyncRevision {
        try scoped {
            let old=try readState(for:key)
            guard mutation == .delete || !old.isDeleted else {throw OSwindError.invalid("Restore deleted sync content with a new object lifetime")}
            if let resolution {
                guard old.isConflicted,Set(old.heads.map(\.dot))==resolution else {throw OSwindError.invalid("Sync conflicts changed before resolution")}
            } else if old.isConflicted,mutation == .put {throw OSwindError.invalid("Review sync conflicts before updating this object")}

            let counter=try database.statement("SELECT sequence FROM personal_sync_local WHERE singleton=1")
            defer {sqlite3_finalize(counter)}
            guard sqlite3_step(counter)==SQLITE_ROW,sqlite3_column_type(counter,0)==SQLITE_INTEGER else {throw database.error()}
            let previous=sqlite3_column_int64(counter,0)
            guard previous>=0,previous<Int64.max,try readCursor(for:replica)==previous else {throw OSwindError.invalid("Sync sequence exhausted")}
            let revision=try SyncRevision(key:key,dot:.init(replica:replica,counter:previous+1),context:old.clock,mutation:mutation,content:content)
            var next=old;try next.integrate(revision);try save(next)
            let data=try revision.encoded();guard try recordReceipt(revision,data:data) else {throw OSwindError.invalid("Local sync sequence already exists")}
            let outbox=try database.statement("INSERT INTO personal_sync_outbox(sequence,revision) VALUES(?,?)")
            defer {sqlite3_finalize(outbox)};sqlite3_bind_int64(outbox,1,revision.dot.counter);bind(outbox,2,data);try database.done(outbox)
            let advance=try database.statement("UPDATE personal_sync_local SET sequence=? WHERE singleton=1")
            defer {sqlite3_finalize(advance)};sqlite3_bind_int64(advance,1,revision.dot.counter);try database.done(advance)
            try advanceCursor(replica,revision.dot.counter)
            try apply(.init(revision:revision,before:old,after:next))
            return revision
        }
    }
    func outbox(after sequence:Int64=0,limit:Int=128)throws->[SyncRevision] {
        try validateIdentity()
        guard sequence>=0,(1...256).contains(limit) else {throw OSwindError.invalid("Invalid sync outbox bounds")}
        let row=try database.statement("SELECT sequence,revision FROM personal_sync_outbox WHERE sequence>? ORDER BY sequence LIMIT ?")
        defer {sqlite3_finalize(row)};sqlite3_bind_int64(row,1,sequence);sqlite3_bind_int(row,2,Int32(limit));var result=[SyncRevision]();var status=sqlite3_step(row)
        while status==SQLITE_ROW {
            let revision=try SyncRevision.decode(blob(row,1,limit:SyncProtocolLimits.operationBytes))
            guard revision.dot.replica==replica,revision.dot.counter==sqlite3_column_int64(row,0) else {throw OSwindError.invalid("Sync outbox identity differs")}
            result.append(revision);status=sqlite3_step(row)
        }
        guard status==SQLITE_DONE else {throw database.error()};return result
    }
    private func advanceCursor(_ id:String,_ counter:Int64)throws {
        guard let current=try readCursor(for:id),counter>current else {throw OSwindError.invalid("Sync cursor cannot move backwards")}

        let row=try database.statement("UPDATE personal_sync_peers SET cursor=? WHERE replica=?")
        defer {sqlite3_finalize(row)};sqlite3_bind_int64(row,1,counter);database.bind(row,2,id);try database.done(row)
        guard sqlite3_changes(database.handle)==1 else {throw OSwindError.invalid("Sync peer is not enrolled")}
    }
    // A caller must authenticate/decode the object first. Prepared content is
    // verified outside this transaction; apply must perform typed admission and
    // may throw, rolling back state/cursors/source writes together.
    func receive(_ revision:SyncRevision,contentAvailable:(SyncContentReference)throws->Bool,apply:(SyncJournalChange)throws->Void={_ in})throws->SyncReceiveResult {
        try scoped {
            guard try readCursor(for:revision.dot.replica) != nil else {throw OSwindError.invalid("Sync peer is not enrolled")}
            for id in revision.context.counters.keys {guard try readCursor(for:id) != nil else {throw OSwindError.invalid("Sync context names an unknown peer")}}
            let encoded=try revision.encoded()
            let inserted=try recordReceipt(revision,data:encoded)
            if inserted {
                guard revision.dot.replica != replica else {throw OSwindError.invalid("Another sync writer reused this device identity")}
                guard let known=try readCursor(for:revision.dot.replica),revision.dot.counter>known else {throw OSwindError.invalid("Sync receipt history is incomplete")}

                let count=try database.statement("SELECT COUNT(*) FROM personal_sync_pending");defer {sqlite3_finalize(count)}
                guard sqlite3_step(count)==SQLITE_ROW else {throw database.error()}
                let current=try readCursor(for:revision.dot.replica) ?? 0
                guard current<Int64.max,sqlite3_column_int64(count,0)<Int64(Self.pendingLimit) || revision.dot.counter==current+1 else {throw OSwindError.unavailable("Sync pending queue is full; fetch missing predecessors")}
                let pending=try database.statement("INSERT INTO personal_sync_pending(replica,sequence,revision) VALUES(?,?,?)")
                defer {sqlite3_finalize(pending)};database.bind(pending,1,revision.dot.replica);sqlite3_bind_int64(pending,2,revision.dot.counter);bind(pending,3,encoded);try database.done(pending)
                if revision.mutation == .delete {
                    let old=try readState(for:revision.key);var next=old;try next.integrate(revision);try save(next)
                    if !old.isDeleted {try apply(.init(revision:revision,before:old,after:next))}
                }
            }
            return .init(inserted:inserted,applied:try drainInside(limit:256,contentAvailable:contentAvailable,apply:apply))
        }
    }
    func drain(limit:Int=256,contentAvailable:(SyncContentReference)throws->Bool,apply:(SyncJournalChange)throws->Void={_ in})throws->Int {
        guard (1...1024).contains(limit) else {throw OSwindError.invalid("Invalid sync drain bound")}
        return try scoped {try drainInside(limit:limit,contentAvailable:contentAvailable,apply:apply)}
    }
    private func drainInside(limit:Int,contentAvailable:(SyncContentReference)throws->Bool,apply:(SyncJournalChange)throws->Void)throws->Int {
        var applied=0
        while applied<limit {
            try Task.checkCancellation()
            let peers=try database.statement("SELECT replica,cursor FROM personal_sync_peers ORDER BY replica")
            var candidates=[(String,Int64)]();var status=sqlite3_step(peers)
            while status==SQLITE_ROW {let current=sqlite3_column_int64(peers,1);if current<Int64.max {candidates.append((database.text(peers,0),current+1))};status=sqlite3_step(peers)}
            sqlite3_finalize(peers);guard status==SQLITE_DONE else {throw database.error()}
            var progressed=false
            for (id,sequence) in candidates where applied<limit {
                let row=try database.statement("SELECT revision FROM personal_sync_pending WHERE replica=? AND sequence=?")
                database.bind(row,1,id);sqlite3_bind_int64(row,2,sequence)
                let result=sqlite3_step(row)
                if result==SQLITE_DONE {sqlite3_finalize(row);continue}
                guard result==SQLITE_ROW else {sqlite3_finalize(row);throw database.error()}
                let revision:SyncRevision
                do {revision=try SyncRevision.decode(blob(row,0,limit:SyncProtocolLimits.operationBytes));sqlite3_finalize(row)}catch {sqlite3_finalize(row);throw error}
                guard revision.dot.replica==id,revision.dot.counter==sequence else {throw OSwindError.invalid("Pending sync identity differs")}
                var ready=true
                for (peer,counter) in revision.context.counters {if (try readCursor(for:peer) ?? 0)<counter {ready=false;break}}
                if !ready {continue}
                let old=try readState(for:revision.key)
                if !old.isDeleted,let content=revision.content,try !contentAvailable(content) {continue}
                var next=old;try next.integrate(revision);try save(next)
                if old != next {try apply(.init(revision:revision,before:old,after:next))}
                let remove=try database.statement("DELETE FROM personal_sync_pending WHERE replica=? AND sequence=?")
                database.bind(remove,1,id);sqlite3_bind_int64(remove,2,sequence)
                do {try database.done(remove);sqlite3_finalize(remove)}catch {sqlite3_finalize(remove);throw error}
                try advanceCursor(id,sequence);applied+=1;progressed=true
            }
            if !progressed {break}
        }
        return applied
    }
}
