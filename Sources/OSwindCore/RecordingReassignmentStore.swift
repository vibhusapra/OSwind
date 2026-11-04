import Foundation
import CSQLite
import CryptoKit

/// A bounded, text-free record of an explicit native scope edit. It authorizes
/// normal dependency preparation, never an old body, a new lifetime or a head.
/// Quiet archive restore omits this operational state.
enum RecordingReassignmentStore {
    static let defaultBudget=1024*1024
    private static let charge="160+length(CAST(new.memory_id AS BLOB))+length(new.owner)+length(new.scope)"
    static let schemas:[String:String]=[
        "recording_reassignment_state":"CREATE TABLE recording_reassignment_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),used_bytes INTEGER NOT NULL CHECK(used_bytes>=0),budget INTEGER NOT NULL CHECK(budget BETWEEN 1 AND 8388608 AND used_bytes<=budget))",
        "recording_reassignments":"CREATE TABLE recording_reassignments(memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE CHECK(length(CAST(memory_id AS BLOB)) BETWEEN 1 AND 4096),owner BLOB NOT NULL CHECK(typeof(owner)='blob' AND length(owner) BETWEEN 1 AND 1024 AND json_valid(CAST(owner AS TEXT))),scope BLOB NOT NULL CHECK(typeof(scope)='blob' AND length(scope) BETWEEN 1 AND 8192 AND json_valid(CAST(scope AS TEXT))),checksum TEXT NOT NULL CHECK(length(checksum)=64)) WITHOUT ROWID",
        "recording_reassignment_budget":"CREATE TRIGGER recording_reassignment_budget BEFORE INSERT ON recording_reassignments BEGIN SELECT CASE WHEN (SELECT used_bytes+\(charge)>budget FROM recording_reassignment_state WHERE singleton=1) THEN RAISE(ABORT,'Recording reassignment metadata is full') END; END",
        "recording_reassignment_added":"CREATE TRIGGER recording_reassignment_added AFTER INSERT ON recording_reassignments BEGIN UPDATE recording_reassignment_state SET used_bytes=used_bytes+\(charge) WHERE singleton=1; END",
        "recording_reassignment_removed":"CREATE TRIGGER recording_reassignment_removed AFTER DELETE ON recording_reassignments BEGIN UPDATE recording_reassignment_state SET used_bytes=used_bytes-(\(charge.replacingOccurrences(of:"new.",with:"old."))) WHERE singleton=1; END",
        "recording_reassignment_immutable":"CREATE TRIGGER recording_reassignment_immutable BEFORE UPDATE ON recording_reassignments BEGIN SELECT RAISE(ABORT,'Recording reassignment intents are immutable'); END",
        "recording_reassignment_native_change":RecordingAffiliationStore.schemas["recording_affiliation_native_change"]!.replacingOccurrences(of:"recording_affiliation_native_change",with:"recording_reassignment_native_change").replacingOccurrences(of:"DELETE FROM recording_affiliations",with:"DELETE FROM recording_reassignments")
    ]
    struct Intent:Equatable {let owner:SyncObjectIdentity,scope:RecordingScope}
    static func install(_ db:RoutineDatabase)throws {
        try SyncChangeCapture.transaction(db) {
            var found=0
            for (name,sql) in schemas {
                let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name)
                let code=sqlite3_step(row)
                if code==SQLITE_ROW {guard db.text(row,0)==sql else {sqlite3_finalize(row);throw OSwindError.database("Recording reassignment schema differs; preserve its intent")};found+=1}
                else if code != SQLITE_DONE {sqlite3_finalize(row);throw db.error()}
                sqlite3_finalize(row)
            }
            guard found==0 || found==schemas.count else {throw OSwindError.database("Recording reassignment schema is incomplete")}
            if found==0 {
                for name in ["recording_reassignment_state","recording_reassignments"] {try db.execute(schemas[name]!)}
                try db.execute("INSERT INTO recording_reassignment_state VALUES(1,0,\(defaultBudget))")
                for (name,sql) in schemas.sorted(by:{$0.key<$1.key}) where name != "recording_reassignment_state" && name != "recording_reassignments" {try db.execute(sql)}
            }
            try checkAccounting(db)
        }
    }
    static func validate(_ db:RoutineDatabase)throws {
        for (name,sql) in schemas {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.database("Recording reassignment protection differs")}
        }
        let row=try db.statement("SELECT used_bytes,budget FROM recording_reassignment_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_INTEGER,sqlite3_column_type(row,1)==SQLITE_INTEGER,(1...8388608).contains(sqlite3_column_int64(row,1)),sqlite3_column_int64(row,0)>=0,sqlite3_column_int64(row,0)<=sqlite3_column_int64(row,1) else {throw OSwindError.database("Recording reassignment budget differs")}
    }
    static func checkAccounting(_ db:RoutineDatabase)throws {
        try validate(db)
        let sum=charge.replacingOccurrences(of:"new.",with:"")
        let row=try db.statement("SELECT used_bytes=(SELECT COALESCE(SUM(\(sum)),0) FROM recording_reassignments) FROM recording_reassignment_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_int(row,0)==1 else {throw OSwindError.database("Recording reassignment accounting differs")}
    }
    private static func checksum(_ id:String,_ owner:Data,_ scope:Data)throws->String {SyncProtocolLimits.hex(try SyncRowSnapshot([.text(Data(id.utf8)),.blob(owner),.blob(scope)]).encoded())}
    private static func bytes(_ row:OpaquePointer,_ column:Int32,_ maximum:Int)throws->Data {
        guard sqlite3_column_type(row,column)==SQLITE_BLOB,sqlite3_column_bytes(row,column)>0,Int(sqlite3_column_bytes(row,column))<=maximum,let pointer=sqlite3_column_blob(row,column) else {throw OSwindError.database("Recording reassignment payload differs")}
        return Data(bytes:pointer,count:Int(sqlite3_column_bytes(row,column)))
    }
    private static func bind(_ db:RoutineDatabase,_ row:OpaquePointer,_ column:Int32,_ value:Data) {_ = value.withUnsafeBytes {sqlite3_bind_blob(row,column,$0.baseAddress,Int32($0.count),db.transient)}}
    static func read(_ db:RoutineDatabase,id:String)throws->Intent? {
        try validate(db)
        let row=try db.statement("SELECT owner,scope,checksum FROM recording_reassignments WHERE memory_id=? COLLATE BINARY");defer {sqlite3_finalize(row)};db.bind(row,1,id)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw db.error()}
        let owner=try bytes(row,0,1024),scope=try bytes(row,1,8192)
        let intent=try Intent(owner:JSONDecoder().decode(SyncObjectIdentity.self,from:owner),scope:JSONDecoder().decode(RecordingScope.self,from:scope))
        guard intent.owner.table == .source,intent.scope.selector == .source,try SyncProtocolLimits.encode(intent.owner)==owner,try SyncProtocolLimits.encode(intent.scope)==scope,try checksum(id,owner,scope)==db.text(row,2) else {throw OSwindError.database("Recording reassignment checksum or scope differs")}
        return intent
    }
    static func rememberNativeChange(_ db:RoutineDatabase,before:Memory,after:Memory)throws {
        guard before.id==after.id,before.kind == .recordingMetadata,after.kind == .recordingMetadata,
              let previous=before.recordingDetails?.scope,let scope=after.recordingDetails?.scope,scope.selector == .source,!RecordingDetails.sameTarget(previous,scope) else {return}
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Record reassignment in the native writer")}
        try validate(db)
        guard try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name='personal_sync_identity_current'")==1 else {return}
        let frame=try SyncIdentityCatalog.keyFrame(.source,[.text(Data(after.id.utf8))]),key=Data(SHA256.hash(data:frame))
        let row=try db.statement("SELECT i.origin,i.lifetime,i.object_digest,i.key_frame,m.payload FROM personal_sync_identity_current c JOIN personal_sync_identities i ON i.object_digest=c.object_digest AND i.local_key=c.local_key AND i.table_name='memories' AND i.deleted=0 JOIN memories m ON m.id=? COLLATE BINARY WHERE c.table_name='memories' AND c.local_key=?");defer {sqlite3_finalize(row)};db.bind(row,1,after.id);bind(db,row,2,key)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return};guard code==SQLITE_ROW else {throw db.error()}
        let owner=try SyncObjectIdentity(table:.source,origin:db.text(row,0),lifetime:db.text(row,1))
        var canonical=after;canonical.embedding=nil
        guard try owner.key.digest==db.text(row,2),try bytes(row,3,4096)==frame,try SyncProtocolLimits.encode(JSONDecoder().decode(Memory.self,from:bytes(row,4,32768)))==SyncProtocolLimits.encode(canonical) else {throw OSwindError.invalid("Recording reassignment native owner differs")}
        let old=try read(db,id:after.id)
        guard old==nil else {throw OSwindError.database("Previous recording reassignment was not invalidated")}
        let ownerData=try SyncProtocolLimits.encode(owner),scopeData=try SyncProtocolLimits.encode(scope)
        let put=try db.statement("INSERT INTO recording_reassignments VALUES(?,?,?,?)");defer {sqlite3_finalize(put)};db.bind(put,1,after.id);bind(db,put,2,ownerData);bind(db,put,3,scopeData);db.bind(put,4,try checksum(after.id,ownerData,scopeData));try db.done(put)
    }
    static func consume(_ db:RoutineDatabase,id:String,owner:SyncObjectIdentity,scope:RecordingScope)throws {
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Consume reassignment in its owning writer")}
        guard let intent=try read(db,id:id) else {return}
        guard intent.owner==owner,intent.scope==scope else {throw OSwindError.invalid("Recording reassignment changed before publication")}
        let remove=try db.statement("DELETE FROM recording_reassignments WHERE memory_id=? COLLATE BINARY");defer {sqlite3_finalize(remove)};db.bind(remove,1,id);try db.done(remove)
    }
}
