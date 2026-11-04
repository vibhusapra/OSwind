import Foundation
import CSQLite
import CryptoKit

/// Durable operational proof, not canonical user data or a transcript cache.
/// Native names may be purged from the wire cache without losing this exact
/// owner/scope affiliation. A nil reference records explicit unavailability.
enum RecordingAffiliationStore {
    static let defaultBudget=8*1024*1024,maximumBudget=32*1024*1024
    private static let charge="192+length(CAST(new.memory_id AS BLOB))+length(new.owner)+length(new.scope)+COALESCE(length(new.reference),0)"
    static let schemas:[String:String]=[
        "recording_affiliation_state":"CREATE TABLE recording_affiliation_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),used_bytes INTEGER NOT NULL CHECK(used_bytes>=0),budget INTEGER NOT NULL CHECK(budget BETWEEN 1 AND 33554432 AND used_bytes<=budget))",
        "recording_affiliations":"CREATE TABLE recording_affiliations(memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE CHECK(length(CAST(memory_id AS BLOB)) BETWEEN 1 AND 4096),owner BLOB NOT NULL CHECK(typeof(owner)='blob' AND length(owner) BETWEEN 1 AND 1024 AND json_valid(CAST(owner AS TEXT))),scope BLOB NOT NULL CHECK(typeof(scope)='blob' AND length(scope) BETWEEN 1 AND 8192 AND json_valid(CAST(scope AS TEXT))),reference BLOB CHECK(reference IS NULL OR (typeof(reference)='blob' AND length(reference) BETWEEN 1 AND 1024 AND json_valid(CAST(reference AS TEXT)))),checksum TEXT NOT NULL CHECK(length(checksum)=64)) WITHOUT ROWID",
        "recording_affiliation_budget":"CREATE TRIGGER recording_affiliation_budget BEFORE INSERT ON recording_affiliations BEGIN SELECT CASE WHEN (SELECT used_bytes+\(charge)>budget FROM recording_affiliation_state WHERE singleton=1) THEN RAISE(ABORT,'Recording affiliation metadata is full') END; END",
        "recording_affiliation_added":"CREATE TRIGGER recording_affiliation_added AFTER INSERT ON recording_affiliations BEGIN UPDATE recording_affiliation_state SET used_bytes=used_bytes+\(charge) WHERE singleton=1; END",
        "recording_affiliation_removed":"CREATE TRIGGER recording_affiliation_removed AFTER DELETE ON recording_affiliations BEGIN UPDATE recording_affiliation_state SET used_bytes=used_bytes-(\(charge.replacingOccurrences(of:"new.",with:"old."))) WHERE singleton=1; END",
        "recording_affiliation_immutable":"CREATE TRIGGER recording_affiliation_immutable BEFORE UPDATE ON recording_affiliations BEGIN SELECT RAISE(ABORT,'Recording affiliation bindings are immutable'); END",
        "recording_affiliation_native_change":"""
        CREATE TRIGGER recording_affiliation_native_change BEFORE UPDATE OF id,kind,payload ON memories
        WHEN old.id IS NOT new.id OR old.kind IS NOT new.kind OR CASE WHEN old.kind='recording-metadata' AND new.kind='recording-metadata' THEN
            json_extract(CAST(old.payload AS TEXT),'$.recordingDetails.scope.selector') IS NOT json_extract(CAST(new.payload AS TEXT),'$.recordingDetails.scope.selector') OR
            json_extract(CAST(old.payload AS TEXT),'$.recordingDetails.scope.id') IS NOT json_extract(CAST(new.payload AS TEXT),'$.recordingDetails.scope.id') OR
            json_extract(CAST(old.payload AS TEXT),'$.recordingDetails.scope.revision') IS NOT json_extract(CAST(new.payload AS TEXT),'$.recordingDetails.scope.revision')
        ELSE 0 END
        BEGIN DELETE FROM recording_affiliations WHERE memory_id=old.id; END
        """
    ]
    struct Binding:Equatable {
        let owner:SyncObjectIdentity,scope:RecordingScope,reference:SyncVersionReference?
    }
    static func install(_ db:RoutineDatabase)throws {
        try SyncChangeCapture.transaction(db) {
            var found=0
            for (name,sql) in schemas {
                let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name)
                let code=sqlite3_step(row)
                if code==SQLITE_ROW {guard db.text(row,0)==sql else {sqlite3_finalize(row);throw OSwindError.database("Recording affiliation schema differs; preserve its proof")};found+=1}
                else if code != SQLITE_DONE {sqlite3_finalize(row);throw db.error()}
                sqlite3_finalize(row)
            }
            guard found==0 || found==schemas.count else {throw OSwindError.database("Recording affiliation schema is incomplete; preserve its proof")}
            if found==0 {
                for name in ["recording_affiliation_state","recording_affiliations"] {try db.execute(schemas[name]!)}
                try db.execute("INSERT INTO recording_affiliation_state VALUES(1,0,\(defaultBudget))")
                for (name,sql) in schemas.sorted(by:{$0.key<$1.key}) where name != "recording_affiliation_state" && name != "recording_affiliations" {try db.execute(sql)}
            }
            try checkAccounting(db)
        }
    }
    static func validate(_ db:RoutineDatabase)throws {
        for (name,sql) in schemas {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.database("Recording affiliation protection differs")}
        }
        let row=try db.statement("SELECT used_bytes,budget FROM recording_affiliation_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_INTEGER,sqlite3_column_type(row,1)==SQLITE_INTEGER,(1...Int64(maximumBudget)).contains(sqlite3_column_int64(row,1)),sqlite3_column_int64(row,0)>=0,sqlite3_column_int64(row,0)<=sqlite3_column_int64(row,1) else {throw OSwindError.database("Recording affiliation budget differs")}
    }
    static func checkAccounting(_ db:RoutineDatabase)throws {
        try validate(db)
        let sum=charge.replacingOccurrences(of:"new.",with:"")
        let row=try db.statement("SELECT used_bytes=(SELECT COALESCE(SUM(\(sum)),0) FROM recording_affiliations) FROM recording_affiliation_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_int(row,0)==1 else {throw OSwindError.database("Recording affiliation accounting differs")}
    }
    private static func checksum(id:String,owner:Data,scope:Data,reference:Data?)throws->String {
        SyncProtocolLimits.hex(try SyncRowSnapshot([.text(Data(id.utf8)),.blob(owner),.blob(scope),reference.map { .blob($0) } ?? .null]).encoded())
    }
    private static func bytes(_ row:OpaquePointer,_ column:Int32,maximum:Int)throws->Data {
        guard sqlite3_column_type(row,column)==SQLITE_BLOB,sqlite3_column_bytes(row,column)>0,Int(sqlite3_column_bytes(row,column))<=maximum,let pointer=sqlite3_column_blob(row,column) else {throw OSwindError.database("Recording affiliation payload differs")}
        return Data(bytes:pointer,count:Int(sqlite3_column_bytes(row,column)))
    }
    private static func bind(_ db:RoutineDatabase,_ row:OpaquePointer,_ column:Int32,_ data:Data?) {
        if let data {_ = data.withUnsafeBytes {sqlite3_bind_blob(row,column,$0.baseAddress,Int32(data.count),db.transient)}}else {sqlite3_bind_null(row,column)}
    }
    static func read(_ db:RoutineDatabase,id:String)throws->Binding? {
        try validate(db)
        let row=try db.statement("SELECT owner,scope,reference,checksum FROM recording_affiliations WHERE memory_id=? COLLATE BINARY");defer {sqlite3_finalize(row)};db.bind(row,1,id)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw db.error()}
        let owner=try bytes(row,0,maximum:1024),scope=try bytes(row,1,maximum:8192),reference=try sqlite3_column_type(row,2)==SQLITE_NULL ? nil:bytes(row,2,maximum:1024)
        let value=try Binding(owner:JSONDecoder().decode(SyncObjectIdentity.self,from:owner),scope:JSONDecoder().decode(RecordingScope.self,from:scope),reference:reference.map {try JSONDecoder().decode(SyncVersionReference.self,from:$0)})
        _=try value.owner.key;try value.reference?.validate(.source)
        guard value.owner.table == .source,value.scope.selector == .source,try SyncProtocolLimits.encode(value.owner)==owner,try SyncProtocolLimits.encode(value.scope)==scope,try value.reference.map({try SyncProtocolLimits.encode($0)})==reference,try checksum(id:id,owner:owner,scope:scope,reference:reference)==db.text(row,3) else {throw OSwindError.database("Recording affiliation checksum or identity differs")}
        return value
    }
    /// Upgrade an existing checked metadata projection before a native edit
    /// purges its wire body. This copies only the affiliation, never its name.
    /// No source body is created or recovered here; normal use still requires
    /// the live owner, exact admitted audio version and current policy.
    static func rememberProjection(_ db:RoutineDatabase,memory:Memory)throws {
        guard memory.kind == .recordingMetadata,let scope=memory.recordingDetails?.scope,scope.selector == .source else {return}
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Preserve affiliation in the native writer transaction")}
        if try read(db,id:memory.id) != nil {return}
        guard try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name='personal_sync_version_projection'")==1 else {return}
        let frame=try SyncIdentityCatalog.keyFrame(.source,[.text(Data(memory.id.utf8))]),key=Data(SHA256.hash(data:frame))
        let row=try db.statement("""
        SELECT i.origin,i.lifetime,i.object_digest,i.key_frame,p.content_sha,p.evidence,p.entity_revision,v.bytes,v.body,m.payload
        FROM memories m JOIN personal_sync_identity_current c ON c.table_name='memories' AND c.local_key=?
        JOIN personal_sync_identities i ON i.object_digest=c.object_digest AND i.local_key=c.local_key AND i.table_name='memories' AND i.deleted=0
        JOIN personal_sync_version_projection p ON p.object_digest=c.object_digest
        JOIN personal_sync_versions v ON v.object_digest=p.object_digest AND v.content_sha=p.content_sha
        WHERE m.id=? COLLATE BINARY
        """);defer {sqlite3_finalize(row)};bind(db,row,1,key);db.bind(row,2,memory.id)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return};guard code==SQLITE_ROW else {throw db.error()}
        let owner=try SyncObjectIdentity(table:.source,origin:db.text(row,0),lifetime:db.text(row,1))
        guard try owner.key.digest==db.text(row,2),try bytes(row,3,maximum:4096)==frame,sqlite3_column_type(row,7)==SQLITE_INTEGER else {throw OSwindError.database("Recording projection owner differs before native edit")}
        let reference=try SyncVersionReference(identity:owner,content:.init(sha256:db.text(row,4),bytes:sqlite3_column_int64(row,7)))
        let record=try SyncPortableRecord.decode(bytes(row,8,maximum:65536),expected:reference)
        let current=try JSONDecoder().decode(Memory.self,from:bytes(row,9,maximum:32768))
        guard try SyncProtocolLimits.encode(current)==SyncProtocolLimits.encode(memory) else {throw OSwindError.invalid("Recording metadata changed before native edit")}
        guard case .source(let body)=record.body,body.kind == .recordingMetadata,let details=body.recordingDetails,details.scope.selector != .session else {return}
        var projected=try body.projectedMemory(id:memory.id,paths:[:]) {_ in (scope.id!,scope.revision!)}
        if details.scope.selector == .unavailable {projected.recordingDetails = .init(scope:scope,calendar:details.calendar)}
        guard Data(projected.evidenceHash.utf8)==Data(db.text(row,5).utf8),Data(projected.entityRevision.utf8)==Data(db.text(row,6).utf8),Data(memory.evidenceHash.utf8)==Data(db.text(row,5).utf8) else {return}
        try save(db,id:memory.id,owner:owner,scope:scope,reference:details.scope.source)
    }
    /// Called only after complete canonical/wire equality and exact dependency
    /// admission in the owning sync writer transaction.
    static func save(_ db:RoutineDatabase,id:String,owner:SyncObjectIdentity,scope:RecordingScope,reference:SyncVersionReference?)throws {
        guard sqlite3_get_autocommit(db.handle)==0,owner.table == .source,scope.selector == .source else {throw OSwindError.invalid("Bind a recording affiliation in its owning writer")}
        try validate(db);_=try owner.key;try reference?.validate(.source)
        let previous=try read(db,id:id)
        // Unavailable wire projection does not erase a known exact pointer.
        // Reusing that pointer still requires the same live source lifetime,
        // the actual exact body and current policy; a matching hash cannot help.
        let retained=reference ?? (previous?.owner==owner && previous?.scope==scope ? previous?.reference:nil)
        let ownerData=try SyncProtocolLimits.encode(owner),scopeData=try SyncProtocolLimits.encode(scope),refData=try retained.map {try SyncProtocolLimits.encode($0)}
        let digest=try checksum(id:id,owner:ownerData,scope:scopeData,reference:refData)
        if previous == Binding(owner:owner,scope:scope,reference:retained) {return}
        let remove=try db.statement("DELETE FROM recording_affiliations WHERE memory_id=? COLLATE BINARY");defer {sqlite3_finalize(remove)};db.bind(remove,1,id);try db.done(remove)
        let put=try db.statement("INSERT INTO recording_affiliations VALUES(?,?,?,?,?)");defer {sqlite3_finalize(put)};db.bind(put,1,id);bind(db,put,2,ownerData);bind(db,put,3,scopeData);bind(db,put,4,refData);db.bind(put,5,digest);try db.done(put)
    }
}
