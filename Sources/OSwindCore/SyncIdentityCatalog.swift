import Foundation
import CSQLite
import CryptoKit

/// Complete canonical table identity; citation rows are distinct protocol objects.
/// This catalog is internal until typed content, privacy and enrollment are complete.
enum SyncCanonicalTable:String,Codable,CaseIterable,Sendable {
    case source="memories",conversation="chat_sessions",turn="chat_turns"
    case conversationCitation="chat_sources",recapCitation="recap_sources"
    case routine="routines",routineRun="routine_runs",entity="memory_entities"
    case entityAlias="entity_aliases",entityMention="entity_mentions"
    case entityRejection="entity_ignored",projectRejection="entity_project_ignored",evidencePin="text_observation_pins"
    var schema:SyncCaptureTable {SyncChangeCapture.tables.first {$0.name==rawValue}!}
    var kind:SyncObjectKind {
        switch self {
        case .source:return .source;case .conversation:return .conversation;case .turn:return .turn
        case .conversationCitation:return .conversationCitation;case .recapCitation:return .recapCitation
        case .routine:return .routine;case .routineRun:return .routineRun;case .entity:return .entity
        case .entityAlias:return .entityAlias;case .entityMention:return .entityMention
        case .entityRejection:return .entityRejection;case .projectRejection:return .projectRejection;case .evidencePin:return .evidencePin
        }
    }
}
struct SyncObjectIdentity:Codable,Equatable,Sendable {
    let table:SyncCanonicalTable
    let origin:String
    let lifetime:String
    init(table:SyncCanonicalTable,origin:String,lifetime:String)throws {
        try SyncProtocolLimits.uuid(origin);try SyncProtocolLimits.uuid(lifetime)
        self.table=table;self.origin=origin;self.lifetime=lifetime
    }
    var key:SyncObjectKey {get throws {
        let frame=try SyncRowSnapshot([.text(Data(table.rawValue.utf8)),.text(Data(origin.utf8)),.text(Data(lifetime.utf8))]).encoded()
        return try .make(kind:table.kind,identity:frame)
    }}
    private enum CodingKeys:String,CodingKey {case table,origin,lifetime}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(table:c.decode(SyncCanonicalTable.self,forKey:.table),origin:c.decode(String.self,forKey:.origin),lifetime:c.decode(String.self,forKey:.lifetime))
    }
}
struct SyncIdentifiedChange:Sendable {
    let captured:SyncCapturedChange
    let before:SyncObjectIdentity?
    let after:SyncObjectIdentity?
}
struct SyncBootstrapObject:Sendable {let identity:SyncObjectIdentity;let primary:[SyncRowCell]}
struct SyncBootstrapResult:Equatable,Sendable {let objects:Int;let complete:Bool}
struct SyncLocalObject:Sendable {
    let identity:SyncObjectIdentity
    let primary:[SyncRowCell]?
    let deleted:Bool
}

/// Maps local byte-exact primary keys to globally distinct lifetimes. Historical
/// tombstones retain opaque digests, never a deleted row body or its raw key.
/// Queue acknowledgement and a required caller's typed journal/cache writes share
/// one transaction. No network, scheduler, capture activation or public API.
struct SyncIdentityCatalog {
    let database:RoutineDatabase
    let scope:SyncCaptureScope
    static func install(_ db:RoutineDatabase)throws->Self {
        try SyncChangeCapture.prepare(db)
        return try SyncChangeCapture.transaction(db) {
            let scope=try SyncChangeCapture.scope(db)
            let present=try db.statement("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('personal_sync_identity_state','personal_sync_identities','personal_sync_identity_current','personal_sync_identity_bootstrap')")
            var installed=Set<String>(),status=sqlite3_step(present)
            while status==SQLITE_ROW {installed.insert(db.text(present,0));status=sqlite3_step(present)};sqlite3_finalize(present)
            guard status==SQLITE_DONE,installed.isEmpty || installed==Set(Self.schemas.keys) else {throw OSwindError.database("Sync identity schema is incomplete; preserve its state")}
            for (name,sql) in Self.schemas.sorted(by:{$0.key<$1.key}) {
                let existing=try db.statement("SELECT sql FROM sqlite_master WHERE name=? AND type='table'");db.bind(existing,1,name)
                let code=sqlite3_step(existing),found=code==SQLITE_ROW ? db.text(existing,0):nil;sqlite3_finalize(existing)
                guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
                if let found {guard found==sql else {throw OSwindError.database("Sync identity schema differs")}}
                else {try db.execute(sql)}
            }
            let row=try db.statement("INSERT INTO personal_sync_identity_state VALUES(1,?,?,0,0) ON CONFLICT(singleton) DO NOTHING");defer {sqlite3_finalize(row)}
            db.bind(row,1,scope.origin);db.bind(row,2,scope.generation);try db.done(row)
            let value=Self(database:db,scope:scope);_ = try value.state();return value
        }
    }
    private static let schemas:[String:String]=[
        "personal_sync_identity_bootstrap":"CREATE TABLE personal_sync_identity_bootstrap(table_name TEXT PRIMARY KEY,next_key BLOB,cursor_key BLOB,complete INTEGER NOT NULL CHECK(complete IN(0,1)),CHECK((next_key IS NULL AND cursor_key IS NULL) OR (typeof(next_key)='blob' AND length(next_key)>0 AND length(next_key)<=66048 AND typeof(cursor_key)='blob' AND length(cursor_key)=32)),CHECK(complete=0 OR next_key IS NULL))",
        "personal_sync_identity_state":"CREATE TABLE personal_sync_identity_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),origin TEXT NOT NULL,generation TEXT NOT NULL,through_seq INTEGER NOT NULL CHECK(typeof(through_seq)='integer' AND through_seq>=0),processing INTEGER NOT NULL CHECK(processing IN(0,1)))",
        "personal_sync_identities":"CREATE TABLE personal_sync_identities(object_digest TEXT PRIMARY KEY,table_name TEXT NOT NULL,origin TEXT NOT NULL,lifetime TEXT NOT NULL,local_key BLOB,key_frame BLOB,deleted INTEGER NOT NULL CHECK(deleted IN(0,1)),UNIQUE(origin,lifetime),CHECK(local_key IS NULL OR (typeof(local_key)='blob' AND length(local_key)=32)),CHECK(deleted=0 OR key_frame IS NULL))",
        "personal_sync_identity_current":"CREATE TABLE personal_sync_identity_current(table_name TEXT NOT NULL,local_key BLOB NOT NULL CHECK(typeof(local_key)='blob' AND length(local_key)=32),object_digest TEXT NOT NULL REFERENCES personal_sync_identities(object_digest),PRIMARY KEY(table_name,local_key))"
    ]
    private func state()throws->(Int64,Bool) {
        for (name,sql) in Self.schemas {
            let s=try database.statement("SELECT sql FROM sqlite_master WHERE name=? AND type='table'");database.bind(s,1,name);defer {sqlite3_finalize(s)}
            guard sqlite3_step(s)==SQLITE_ROW,database.text(s,0)==sql else {throw OSwindError.database("Sync identity schema differs")}
        }
        guard try SyncChangeCapture.scope(database)==scope else {throw OSwindError.invalid("Sync identity capture scope changed")}
        let s=try database.statement("SELECT origin,generation,through_seq,processing FROM personal_sync_identity_state WHERE singleton=1");defer {sqlite3_finalize(s)}
        guard sqlite3_step(s)==SQLITE_ROW,database.text(s,0)==scope.origin,database.text(s,1)==scope.generation,sqlite3_column_type(s,2)==SQLITE_INTEGER,sqlite3_column_int64(s,2)>=0,sqlite3_column_type(s,3)==SQLITE_INTEGER,(0...1).contains(sqlite3_column_int(s,3)) else {throw OSwindError.database("Sync identity state differs")}
        return (sqlite3_column_int64(s,2),sqlite3_column_int(s,3)==1)
    }
    private func scoped<T>(_ body:()throws->T)throws->T {
        try SyncChangeCapture.transaction(database) {
            _=try state()
            let s=try database.statement("SELECT enabled,suppressed,(SELECT synchronous FROM pragma_synchronous),(SELECT recursive_triggers FROM pragma_recursive_triggers),(SELECT foreign_keys FROM pragma_foreign_keys) FROM personal_sync_capture WHERE singleton=1");defer {sqlite3_finalize(s)}
            guard sqlite3_step(s)==SQLITE_ROW,sqlite3_column_int(s,0)==1,sqlite3_column_int(s,1)==0,sqlite3_column_int(s,2)>=2,sqlite3_column_int(s,3)==1,sqlite3_column_int(s,4)==1 else {throw OSwindError.invalid("Sync identity writes need active, unsuppressed durable capture")}
            let value=try body();_=try state();return value
        }
    }
    private func bind(_ row:OpaquePointer,_ index:Int32,_ value:Data?) {
        guard let value else {sqlite3_bind_null(row,index);return}
        value.withUnsafeBytes {_ = sqlite3_bind_blob(row,index,$0.baseAddress,Int32(value.count),database.transient)}
    }
    private func data(_ row:OpaquePointer,_ index:Int32,maximum:Int)throws->Data? {
        if sqlite3_column_type(row,index)==SQLITE_NULL {return nil}
        let size=Int(sqlite3_column_bytes(row,index));guard sqlite3_column_type(row,index)==SQLITE_BLOB,size>0,size<=maximum,let pointer=sqlite3_column_blob(row,index) else {throw OSwindError.database("Invalid sync identity bytes")}
        return Data(bytes:pointer,count:size)
    }
    static func keyFrame(_ table:SyncCanonicalTable,_ primary:[SyncRowCell])throws->Data {
        guard primary.count==table.schema.primary.count else {throw OSwindError.invalid("Invalid canonical primary key width")}
        var bytes=0
        for (column,cell) in zip(table.schema.primary,primary) {
            let ordinal=(table == .conversationCitation || table == .recapCitation) && column=="ordinal"
            switch cell {
            case .integer:guard ordinal else {throw OSwindError.invalid("Canonical text key cannot use numeric affinity")}
            case .text(let value):guard !ordinal,!value.isEmpty,value.count<=SyncProtocolLimits.operationBytes,bytes<=SyncProtocolLimits.operationBytes-value.count else {throw OSwindError.invalid("Canonical primary key exceeds its bound")};bytes+=value.count
            default:throw OSwindError.invalid("Invalid canonical primary key storage")
            }
        }
        return try SyncRowSnapshot(primary).encoded()
    }
    private func readObject(_ digest:String)throws->SyncLocalObject? {
        let s=try database.statement("SELECT table_name,origin,lifetime,local_key,key_frame,deleted FROM personal_sync_identities WHERE object_digest=?");defer {sqlite3_finalize(s)};database.bind(s,1,digest)
        let code=sqlite3_step(s);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW,let table=SyncCanonicalTable(rawValue:database.text(s,0)) else {throw database.error()}
        let identity=try SyncObjectIdentity(table:table,origin:database.text(s,1),lifetime:database.text(s,2))
        guard try identity.key.digest==digest,sqlite3_column_type(s,5)==SQLITE_INTEGER,(0...1).contains(sqlite3_column_int(s,5)) else {throw OSwindError.database("Sync object identity differs")}
        let key=try data(s,3,maximum:32),frame=try data(s,4,maximum:SyncProtocolLimits.operationBytes+512),deleted=sqlite3_column_int(s,5)==1
        guard key==nil || key!.count==32,deleted || key != nil,!deleted || frame==nil else {throw OSwindError.database("Invalid sync identity mapping")}
        var primary:[SyncRowCell]?
        if let frame {primary=try SyncRowSnapshot.decode(frame).cells;guard try Self.keyFrame(table,primary!)==frame,Data(SHA256.hash(data:frame))==key else {throw OSwindError.database("Sync local primary key differs")}}
        return SyncLocalObject(identity:identity,primary:primary,deleted:deleted)
    }
    func object(_ identity:SyncObjectIdentity)throws->SyncLocalObject? {_=try state();let value=try readObject(identity.key.digest);guard value==nil || value!.identity==identity else {throw OSwindError.database("Sync object identity differs")};return value}
    func localIdentity(_ table:SyncCanonicalTable,primary:[SyncRowCell])throws->SyncObjectIdentity {
        _=try state();let frame=try Self.keyFrame(table,primary),key=Data(SHA256.hash(data:frame))
        guard let value=try current(table,key),!value.deleted,value.primary==primary else {throw OSwindError.unavailable("The local sync lifetime is unavailable")};return value.identity
    }
    private func current(_ table:SyncCanonicalTable,_ key:Data)throws->SyncLocalObject? {
        let s=try database.statement("SELECT c.object_digest,i.local_key FROM personal_sync_identity_current c LEFT JOIN personal_sync_identities i ON i.object_digest=c.object_digest WHERE c.table_name=? AND c.local_key=?");defer {sqlite3_finalize(s)};database.bind(s,1,table.rawValue);bind(s,2,key)
        let code=sqlite3_step(s);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW,let value=try readObject(database.text(s,0)),value.identity.table==table,try data(s,1,maximum:32)==key else {throw OSwindError.database("Sync current identity differs")};return value
    }
    private func map(_ identity:SyncObjectIdentity,_ key:Data,_ frame:Data?)throws {
        let digest=try identity.key.digest
        let s=try database.statement("INSERT INTO personal_sync_identities VALUES(?,?,?,?,?,?,0)");defer {sqlite3_finalize(s)}
        database.bind(s,1,digest);database.bind(s,2,identity.table.rawValue);database.bind(s,3,identity.origin);database.bind(s,4,identity.lifetime);bind(s,5,key);bind(s,6,frame);try database.done(s)
        let c=try database.statement("INSERT INTO personal_sync_identity_current VALUES(?,?,?) ON CONFLICT(table_name,local_key) DO UPDATE SET object_digest=excluded.object_digest");defer {sqlite3_finalize(c)};database.bind(c,1,identity.table.rawValue);bind(c,2,key);database.bind(c,3,digest);try database.done(c)
    }
    private func ensure(_ table:SyncCanonicalTable,_ key:Data,_ frame:Data?,insertion:Bool)throws->SyncObjectIdentity {
        if let old=try current(table,key) {
            if !old.deleted {
                guard !insertion else {throw OSwindError.invalid("Captured insert collides with a live sync object")}
                if let frame {let s=try database.statement("UPDATE personal_sync_identities SET key_frame=? WHERE object_digest=?");defer {sqlite3_finalize(s)};bind(s,1,frame);database.bind(s,2,try old.identity.key.digest);try database.done(s)}
                return old.identity
            }
            guard insertion else {throw OSwindError.invalid("Captured update targets a deleted sync lifetime")}
        }
        let identity=try SyncObjectIdentity(table:table,origin:scope.origin,lifetime:UUID().uuidString.lowercased());try map(identity,key,frame);return identity
    }
    private func markDeleted(_ identity:SyncObjectIdentity)throws {
        let prior=try database.statement("SELECT local_key FROM personal_sync_identities WHERE object_digest=?");database.bind(prior,1,try identity.key.digest)
        let code=sqlite3_step(prior);guard code==SQLITE_ROW else {sqlite3_finalize(prior);throw OSwindError.invalid("Sync deletion identity missing")}
        let localKey:Data?;do {localKey=try data(prior,0,maximum:32)}catch {sqlite3_finalize(prior);throw error};sqlite3_finalize(prior)
        if let localKey {
            let reset=try database.statement("UPDATE personal_sync_identity_bootstrap SET next_key=NULL,cursor_key=NULL,complete=0 WHERE table_name=? AND cursor_key=?");defer {sqlite3_finalize(reset)}
            database.bind(reset,1,identity.table.rawValue);bind(reset,2,localKey);try database.done(reset)
        }
        let s=try database.statement("UPDATE personal_sync_identities SET deleted=1,key_frame=NULL WHERE object_digest=?");defer {sqlite3_finalize(s)};database.bind(s,1,try identity.key.digest);try database.done(s)
        guard sqlite3_changes(database.handle)==1 else {throw OSwindError.invalid("Sync deletion identity missing")}
    }
    private func identify(_ change:SyncCapturedChange)throws->SyncIdentifiedChange {
        guard let table=SyncCanonicalTable(rawValue:change.table) else {throw OSwindError.invalid("Unknown sync canonical table")}
        var frame:Data?
        if let row=change.afterRow {
            let cells=try SyncRowSnapshot.decode(row).cells
            guard cells.count==table.schema.columns.count else {throw OSwindError.invalid("Sync canonical row width differs")}
            frame=try Self.keyFrame(table,table.schema.primary.map {cells[table.schema.columns.firstIndex(of:$0)!]})
            guard frame.map({Data(SHA256.hash(data:$0))})==change.afterKey else {throw OSwindError.invalid("Captured row primary key differs")}
        }
        if let before=change.beforeKey,let after=change.afterKey,before==after {
            let identity=try ensure(table,after,frame,insertion:false);return .init(captured:change,before:identity,after:identity)
        }
        var before:SyncObjectIdentity?,after:SyncObjectIdentity?
        if let key=change.beforeKey {
            if let old=try current(table,key) {before=old.identity}
            else {before=try ensure(table,key,nil,insertion:false)}
            try markDeleted(before!)
        }
        if let key=change.afterKey {after=try ensure(table,key,frame,insertion:true)}
        return .init(captured:change,before:before,after:after)
    }
    /// The required callback commits typed protocol/cache output here. Throwing
    /// rolls back identities, caller writes and queue acknowledgement together.
    @discardableResult func process(limit:Int=128,byteLimit:Int=4*1024*1024,consume:([SyncIdentifiedChange])throws->Void)throws->Int {
        try scoped {
            let (through,processing)=try state();guard !processing else {throw OSwindError.invalid("Sync identity processor already active")}
            let changes=try SyncChangeCapture.changes(database,scope:scope,limit:limit,byteLimit:byteLimit)
            guard !changes.isEmpty else {return 0}
            guard changes[0].sequence>through else {throw OSwindError.database("Sync capture cursor moved backwards")}
            try database.execute("UPDATE personal_sync_identity_state SET processing=1 WHERE singleton=1")
            let batch=try changes.map {try identify($0)};try consume(batch)
            let last=changes.last!.sequence
            try SyncChangeCapture.acknowledge(database,scope:scope,through:last)
            let s=try database.statement("UPDATE personal_sync_identity_state SET through_seq=?,processing=0 WHERE singleton=1");defer {sqlite3_finalize(s)};sqlite3_bind_int64(s,1,last);try database.done(s)
            return batch.count
        }
    }
    private func emptyQueue()throws {
        let s=try database.statement("SELECT EXISTS(SELECT 1 FROM personal_sync_changes LIMIT 1)");defer {sqlite3_finalize(s)}
        guard sqlite3_step(s)==SQLITE_ROW,sqlite3_column_int(s,0)==0,try !state().1 else {throw OSwindError.unavailable("Process local sync intents before bootstrap or peer apply")}
    }
    private func bindPrimary(_ row:OpaquePointer,_ primary:[SyncRowCell])throws {
        for (index,value) in primary.enumerated() {
            switch value {
            case .integer(let n):sqlite3_bind_int64(row,Int32(index+1),n)
            case .text(let bytes):bytes.withUnsafeBytes {_ = sqlite3_bind_text64(row,Int32(index+1),$0.baseAddress?.assumingMemoryBound(to:CChar.self),UInt64(bytes.count),database.transient,UInt8(SQLITE_UTF8))}
            default:throw OSwindError.invalid("Invalid canonical primary key storage")
            }
        }
    }
    private func exists(_ table:SyncCanonicalTable,_ primary:[SyncRowCell])throws->Bool {
        _=try Self.keyFrame(table,primary)
        let sql="SELECT 1 FROM \(table.rawValue) WHERE "+table.schema.primary.map {"\($0) IS ?"}.joined(separator:" AND ")+" LIMIT 1"
        let s=try database.statement(sql);defer {sqlite3_finalize(s)}
        try bindPrimary(s,primary)
        let code=sqlite3_step(s);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw database.error()};return code==SQLITE_ROW
    }
    /// Called in the eventual bounded bootstrap transaction, after local intents
    /// drain. Uses exact indexed primary-key lookup, never a table-wide hash scan.
    func registerExisting(_ table:SyncCanonicalTable,primary:[SyncRowCell])throws->SyncObjectIdentity {
        try scoped {
            try emptyQueue();guard try exists(table,primary) else {throw OSwindError.invalid("Bootstrap source row missing")}
            let frame=try Self.keyFrame(table,primary),key=Data(SHA256.hash(data:frame))
            return try ensure(table,key,frame,insertion:false)
        }
    }
    /// Bounded durable keyset bootstrap. A caller reads/validates current typed
    /// content and commits its journal output in consume; the cursor shares that
    /// transaction. Drain local intents first so pre-bootstrap edits cannot later
    /// overwrite a newer snapshot. New keys behind the cursor remain in capture.
    @discardableResult func bootstrap(_ table:SyncCanonicalTable,limit:Int=128,byteLimit:Int=1024*1024,consume:([SyncBootstrapObject])throws->Void)throws->SyncBootstrapResult {
        guard (1...512).contains(limit),(1...8*1024*1024).contains(byteLimit) else {throw OSwindError.invalid("Invalid sync bootstrap bounds")}
        return try scoped {
            try emptyQueue()
            let state=try database.statement("SELECT next_key,cursor_key,complete FROM personal_sync_identity_bootstrap WHERE table_name=?");database.bind(state,1,table.rawValue)
            let stateCode=sqlite3_step(state);var after:Data?,complete=false
            do {
                if stateCode==SQLITE_ROW {
                    after=try data(state,0,maximum:SyncProtocolLimits.operationBytes+512)
                    let digest=try data(state,1,maximum:32)
                    guard sqlite3_column_type(state,2)==SQLITE_INTEGER,(0...1).contains(sqlite3_column_int(state,2)),after.map({Data(SHA256.hash(data:$0))})==digest else {throw OSwindError.database("Sync bootstrap cursor differs")}
                    complete=sqlite3_column_int(state,2)==1
                    if let after {guard try Self.keyFrame(table,SyncRowSnapshot.decode(after).cells)==after,!complete else {throw OSwindError.database("Sync bootstrap primary cursor differs")}}
                }else if stateCode != SQLITE_DONE {throw database.error()}
            }catch {sqlite3_finalize(state);throw error};sqlite3_finalize(state)
            if complete {return .init(objects:0,complete:true)}
            let names=table.schema.primary,ordered=names.map {"\($0) COLLATE BINARY"}
            let predicate=after==nil ? "":" WHERE ("+ordered.joined(separator:",")+") > ("+names.map {_ in "?"}.joined(separator:",")+")"
            let query="SELECT "+names.joined(separator:",")+" FROM "+table.rawValue+predicate+" ORDER BY "+ordered.joined(separator:",")+" LIMIT ?"
            let rows=try database.statement(query);defer {sqlite3_finalize(rows)}
            if let after {try bindPrimary(rows,SyncRowSnapshot.decode(after).cells)}
            sqlite3_bind_int(rows,Int32(after==nil ? 1:names.count+1),Int32(limit+1))
            try database.execute("UPDATE personal_sync_identity_state SET processing=1 WHERE singleton=1")
            var values=[SyncBootstrapObject](),used=0,lastFrame=after,code=sqlite3_step(rows)
            while code==SQLITE_ROW {
                if values.count==limit {break}
                var primary=[SyncRowCell]()
                for column in 0..<names.count {
                    let index=Int32(column)
                    switch sqlite3_column_type(rows,index) {
                    case SQLITE_INTEGER:primary.append(.integer(sqlite3_column_int64(rows,index)))
                    case SQLITE_TEXT:
                        let size=Int(sqlite3_column_bytes(rows,index));guard size>0,size<=SyncProtocolLimits.operationBytes,let bytes=sqlite3_column_text(rows,index) else {throw OSwindError.invalid("Oversized sync bootstrap primary key")}
                        primary.append(.text(Data(bytes:bytes,count:size)))
                    default:throw OSwindError.invalid("Invalid sync bootstrap primary key storage")
                    }
                }
                let frame=try Self.keyFrame(table,primary)
                if frame.count>byteLimit-used {guard !values.isEmpty else {throw OSwindError.unavailable("Sync bootstrap key exceeds the requested byte budget")};break}
                let key=Data(SHA256.hash(data:frame)),identity=try ensure(table,key,frame,insertion:false)
                values.append(.init(identity:identity,primary:primary));used+=frame.count;lastFrame=frame
                try Task.checkCancellation();code=sqlite3_step(rows)
            }
            guard code==SQLITE_ROW || code==SQLITE_DONE else {throw database.error()}
            complete=code==SQLITE_DONE;try consume(values)
            // A callback that deleted the cursor row cannot retain its raw key.
            if let last=values.last,try !exists(table,last.primary) {lastFrame=nil;complete=false}
            if complete {lastFrame=nil}
            let cursor=try database.statement("INSERT INTO personal_sync_identity_bootstrap VALUES(?,?,?,?) ON CONFLICT(table_name) DO UPDATE SET next_key=excluded.next_key,cursor_key=excluded.cursor_key,complete=excluded.complete");defer {sqlite3_finalize(cursor)}
            database.bind(cursor,1,table.rawValue);bind(cursor,2,lastFrame);bind(cursor,3,lastFrame.map {Data(SHA256.hash(data:$0))});sqlite3_bind_int(cursor,4,complete ? 1:0);try database.done(cursor)
            try database.execute("UPDATE personal_sync_identity_state SET processing=0 WHERE singleton=1")
            return .init(objects:values.count,complete:complete)
        }
    }
    /// A missing derived pin table can be rebuilt without deleting its global
    /// lifetimes. Interpret only the just-created repair inserts against the
    /// prior raw intent prefix, then the already-validated catalog. No pending
    /// body is acknowledged or dropped; budget accounting runs on the rewrite.
    static func recoverPinLifetimes(_ db:RoutineDatabase,after:Int64)throws {
        let active=try db.statement("SELECT enabled,suppressed FROM personal_sync_capture WHERE singleton=1");defer {sqlite3_finalize(active)};guard sqlite3_step(active)==SQLITE_ROW else {throw db.error()};if sqlite3_column_int(active,0)==0 {return};guard sqlite3_column_int(active,1)==0 else {throw OSwindError.invalid("Pin repair cannot run with suppressed capture")}
        let present=try db.statement("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('personal_sync_identity_state','personal_sync_identities','personal_sync_identity_current','personal_sync_identity_bootstrap')");defer {sqlite3_finalize(present)};var names=Set<String>(),code=sqlite3_step(present)
        while code==SQLITE_ROW {names.insert(db.text(present,0));code=sqlite3_step(present)};guard code==SQLITE_DONE,names.isEmpty || names==Set(schemas.keys) else {throw OSwindError.database("Pin repair identity metadata is incomplete")}
        let catalog=names.isEmpty ? nil:Self(database:db,scope:try SyncChangeCapture.scope(db))
        if let catalog {guard try !catalog.state().1 else {throw OSwindError.invalid("Pin repair cannot change an in-progress identity transaction")}}
        let rows=try db.statement("SELECT seq,after_key,after_row FROM personal_sync_changes WHERE seq>? AND table_name='text_observation_pins' AND before_key IS NULL AND after_key IS NOT NULL AND after_row IS NOT NULL ORDER BY seq");defer {sqlite3_finalize(rows)};sqlite3_bind_int64(rows,1,after);code=sqlite3_step(rows)
        while code==SQLITE_ROW {
            let sequence=sqlite3_column_int64(rows,0)
            guard let key=try catalogData(rows,1,maximum:32),key.count==32,let body=try catalogData(rows,2,maximum:SyncRowSnapshot.maximumBytes) else {throw OSwindError.database("Invalid recovered pin intent")}
            let frame=try SyncRowSnapshot.decode(body);guard frame.cells.count==1,case .text=frame.cells[0],Data(SHA256.hash(data:try keyFrame(.evidencePin,frame.cells)))==key else {throw OSwindError.database("Recovered pin key differs")}
            let prior=try db.statement("SELECT after_key FROM personal_sync_changes WHERE table_name='text_observation_pins' AND seq<? AND (before_key=? OR after_key=?) ORDER BY seq DESC LIMIT 1");defer {sqlite3_finalize(prior)};sqlite3_bind_int64(prior,1,sequence);key.withUnsafeBytes {p in _=sqlite3_bind_blob(prior,2,p.baseAddress,Int32(key.count),db.transient);_=sqlite3_bind_blob(prior,3,p.baseAddress,Int32(key.count),db.transient)}
            let status=sqlite3_step(prior),live:Bool
            if status==SQLITE_ROW {live=try catalogData(prior,0,maximum:32)==key}
            else {guard status==SQLITE_DONE else {throw db.error()};live=try catalog?.current(.evidencePin,key)?.deleted==false}
            if live {
                let update=try db.statement("UPDATE personal_sync_changes SET before_key=after_key,after_row=after_row WHERE seq=? AND before_key IS NULL");defer {sqlite3_finalize(update)};sqlite3_bind_int64(update,1,sequence);try db.done(update)
            }
            code=sqlite3_step(rows)
        };guard code==SQLITE_DONE else {throw db.error()}
    }
    private static func catalogData(_ row:OpaquePointer,_ column:Int32,maximum:Int)throws->Data? {
        if sqlite3_column_type(row,column)==SQLITE_NULL {return nil}
        let n=Int(sqlite3_column_bytes(row,column));guard sqlite3_column_type(row,column)==SQLITE_BLOB,n>0,n<=maximum,let bytes=sqlite3_column_blob(row,column) else {throw OSwindError.database("Invalid recovered pin bytes")};return Data(bytes:bytes,count:n)
    }
    /// Authenticated journal admission calls this with a complete typed adapter.
    /// Mapping, source mutation and echo suppression commit or roll back together.
    func applyPeer(_ identity:SyncObjectIdentity,primary:[SyncRowCell],apply:()throws->Void)throws {
        try scoped {
            try emptyQueue();let frame=try Self.keyFrame(identity.table,primary),key=Data(SHA256.hash(data:frame))
            if let old=try readObject(identity.key.digest) {
                guard !old.deleted,old.identity==identity else {throw OSwindError.invalid("Peer cannot resurrect a deleted object lifetime")}
                let current=try current(identity.table,key)
                guard current?.identity==identity else {throw OSwindError.invalid("Peer object is already mapped to another local key")}
            }else {
                guard try current(identity.table,key)?.deleted != false else {throw OSwindError.invalid("Peer object collides with a live local object")}
                try map(identity,key,frame)
            }
            try SyncChangeCapture.withoutEcho(database,scope:scope) {try apply()}
            guard try exists(identity.table,primary) else {throw OSwindError.invalid("Typed peer adapter did not create its source")}
        }
    }
    /// A delete operation has no content body, so an unknown wire key need not
    /// reveal origin/lifetime metadata. The same-connection journal owns that
    /// durable barrier; a later missing put is suppressed before typed admission.
    func deletePeerKey(_ key:SyncObjectKey,journal:SyncJournal,apply:(SyncLocalObject?)throws->Void)throws {
        try scoped {
            try emptyQueue()
            guard journal.database.handle==database.handle,try journal.state(for:key).isDeleted else {throw OSwindError.invalid("Peer key deletion requires its transactional journal barrier")}
            if let old=try readObject(key.digest) {
                guard old.identity.table.kind==key.kind else {throw OSwindError.invalid("Peer key deletion kind differs")}
                try deletePeer(old.identity,apply:apply)
            }else {try SyncChangeCapture.withoutEcho(database,scope:scope) {try apply(nil)}}
        }
    }
    /// An unknown early delete is durable. A late delete for an old lifetime does
    /// not target the current replacement occupying the same local primary key.
    func deletePeer(_ identity:SyncObjectIdentity,apply:(SyncLocalObject?)throws->Void)throws {
        try scoped {
            try emptyQueue();let old=try readObject(identity.key.digest)
            guard old==nil || old!.identity==identity else {throw OSwindError.invalid("Peer deletion identity differs")}
            if old==nil {
                let s=try database.statement("INSERT INTO personal_sync_identities VALUES(?,?,?,?,NULL,NULL,1)");defer {sqlite3_finalize(s)}
                database.bind(s,1,try identity.key.digest);database.bind(s,2,identity.table.rawValue);database.bind(s,3,identity.origin);database.bind(s,4,identity.lifetime);try database.done(s)
            }else {try markDeleted(identity)}
            let active=old?.deleted==false ? old:nil
            try SyncChangeCapture.withoutEcho(database,scope:scope) {try apply(active)}
            if let primary=active?.primary {guard try !exists(identity.table,primary) else {throw OSwindError.invalid("Typed peer deletion left its source present")}}
        }
    }
}

