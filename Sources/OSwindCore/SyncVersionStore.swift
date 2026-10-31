import Foundation
import CSQLite
import CryptoKit

struct SyncPortableDependency:Equatable {
    let identity:SyncObjectIdentity
    let content:SyncContentReference?
}
extension SyncPortableRecord {
    /// Explicit immutable references, also used to admit requested historical
    /// evidence. An object-only reference never authorizes an arbitrary version.
    var dependencies:[SyncPortableDependency] {
        func object(_ id:SyncObjectIdentity)->SyncPortableDependency {.init(identity:id,content:nil)}
        func version(_ ref:SyncVersionReference)->SyncPortableDependency {.init(identity:ref.identity,content:ref.content)}
        func filter(_ f:SyncFilterBody)->[SyncPortableDependency] {f.entity.map {[object($0)]} ?? []}
        switch body {
        case .source(let v):return (v.recap?.sources ?? []).map {version($0.source)}
        case .turn(let v):return [object(v.conversation)]+filter(v.filter)
        case .conversationCitation(let v),.recapCitation(let v):return [object(v.owner),version(v.link.source)]
        case .routineRun(let v):return [.init(identity:v.recipe.routine,content:v.recipe.definition)]+(v.conversation.map {[object($0)]} ?? [])+filter(v.filter)
        case .entityAlias(let v):return [object(v.entity)]
        case .entityMention(let v):return [version(v.source),object(v.entity)]
        case .entityRejection(let v):return [version(v.source)]
        case .projectRejection(let v):return [version(v.source),object(v.entity)]
        case .evidencePin(let v):return [version(v.source)]
        case .conversation,.routine,.entity:return []
        }
    }
}

/// The owning library serializes access to this borrowed SQLite connection.
/// Explicit internal installation only. Plaintext typed records live in the
/// owning library, never settings. Current policy admission is mandatory at every
/// read/write; this is not an incoming graph adapter or transport authorization.
struct SyncVersionStore {
    let catalog:SyncIdentityCatalog
    let journal:SyncJournal
    var database:RoutineDatabase {catalog.database}
    private final class SchemaStamp {let lock=NSLock();var value:Int64?}
    private let schemaStamp=SchemaStamp()
    static let defaultBudget:Int64=256*1024*1024,maximumBudget:Int64=8*1024*1024*1024
    private static let schemas:[String:String]=[
        "personal_sync_version_state":"CREATE TABLE personal_sync_version_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),origin TEXT NOT NULL,generation TEXT NOT NULL,group_id TEXT NOT NULL,epoch TEXT NOT NULL,used_bytes INTEGER NOT NULL CHECK(typeof(used_bytes)='integer' AND used_bytes>=0 AND used_bytes<=budget),budget INTEGER NOT NULL CHECK(typeof(budget)='integer' AND budget>0 AND budget<=8589934592))",
        "personal_sync_versions":"CREATE TABLE personal_sync_versions(object_digest TEXT NOT NULL,content_sha TEXT NOT NULL,table_name TEXT NOT NULL,local_key BLOB NOT NULL CHECK(typeof(local_key)='blob' AND length(local_key)=32),bytes INTEGER NOT NULL CHECK(typeof(bytes)='integer' AND bytes>0 AND bytes<=134217728),body BLOB NOT NULL CHECK(typeof(body)='blob' AND length(body)=bytes),PRIMARY KEY(object_digest,content_sha))",
        "personal_sync_version_projection":"CREATE TABLE personal_sync_version_projection(object_digest TEXT PRIMARY KEY,content_sha TEXT NOT NULL,row_digest TEXT NOT NULL,evidence TEXT,entity_revision TEXT,FOREIGN KEY(object_digest,content_sha) REFERENCES personal_sync_versions(object_digest,content_sha) ON DELETE CASCADE)",
        "personal_sync_version_recipes":"CREATE TABLE personal_sync_version_recipes(object_digest TEXT NOT NULL,ordinal INTEGER NOT NULL CHECK(typeof(ordinal)='integer' AND ordinal>0),content_sha TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(typeof(bytes)='integer' AND bytes>0 AND bytes<=134217728),binding_sha TEXT NOT NULL CHECK(length(binding_sha)=64),PRIMARY KEY(object_digest,ordinal))",
        "personal_sync_version_sessions":"CREATE TABLE personal_sync_version_sessions(object_digest TEXT PRIMARY KEY,local_key BLOB NOT NULL CHECK(typeof(local_key)='blob' AND length(local_key)=32),token BLOB NOT NULL CHECK(typeof(token)='blob' AND length(token)>0 AND length(token)<=4096))",
        "personal_sync_version_runs":"CREATE TABLE personal_sync_version_runs(object_digest TEXT PRIMARY KEY,local_key BLOB NOT NULL CHECK(typeof(local_key)='blob' AND length(local_key)=32),routine_key BLOB NOT NULL CHECK(typeof(routine_key)='blob' AND length(routine_key)=32),local_revision INTEGER NOT NULL CHECK(typeof(local_revision)='integer' AND local_revision>0),recipe BLOB NOT NULL CHECK(typeof(recipe)='blob' AND length(recipe)>0 AND length(recipe)<=4096),recipe_sha TEXT NOT NULL CHECK(length(recipe_sha)=64))",
        "personal_sync_version_revoked":"CREATE TABLE personal_sync_version_revoked(object_digest TEXT PRIMARY KEY)"
    ]
    private static let indexes:[String:String]=[
        "sync_versions_local":"CREATE INDEX sync_versions_local ON personal_sync_versions(table_name,local_key)",
        "sync_sessions_local":"CREATE INDEX sync_sessions_local ON personal_sync_version_sessions(local_key)",
        "sync_runs_local":"CREATE INDEX sync_runs_local ON personal_sync_version_runs(local_key)"
    ]
    private static let triggers:[String:String] = {
        var result=[String:String]()
        result["sync_versions_budget"]="CREATE TRIGGER sync_versions_budget BEFORE INSERT ON personal_sync_versions BEGIN SELECT CASE WHEN (SELECT used_bytes+new.bytes+128>budget FROM personal_sync_version_state WHERE singleton=1) THEN RAISE(ABORT,'Sync version cache is full') END; END"
        result["sync_versions_added"]="CREATE TRIGGER sync_versions_added AFTER INSERT ON personal_sync_versions BEGIN UPDATE personal_sync_version_state SET used_bytes=used_bytes+new.bytes+128 WHERE singleton=1; END"
        result["sync_versions_removed"]="CREATE TRIGGER sync_versions_removed AFTER DELETE ON personal_sync_versions BEGIN UPDATE personal_sync_version_state SET used_bytes=used_bytes-old.bytes-128 WHERE singleton=1; END"
        result["sync_versions_immutable"]="CREATE TRIGGER sync_versions_immutable BEFORE UPDATE ON personal_sync_versions BEGIN SELECT RAISE(ABORT,'Sync versions are immutable'); END"
        for (table,size) in [("recipes","192"),("sessions","128+length(new.token)"),("runs","224+length(new.recipe)")] {
            let name="personal_sync_version_"+table,old=size.replacingOccurrences(of:"new.",with:"old.")
            result["sync_\(table)_budget"]="CREATE TRIGGER sync_\(table)_budget BEFORE INSERT ON \(name) BEGIN SELECT CASE WHEN (SELECT used_bytes+\(size)>budget FROM personal_sync_version_state WHERE singleton=1) THEN RAISE(ABORT,'Sync version metadata cache is full') END; END"
            result["sync_\(table)_added"]="CREATE TRIGGER sync_\(table)_added AFTER INSERT ON \(name) BEGIN UPDATE personal_sync_version_state SET used_bytes=used_bytes+\(size) WHERE singleton=1; END"
            result["sync_\(table)_removed"]="CREATE TRIGGER sync_\(table)_removed AFTER DELETE ON \(name) BEGIN UPDATE personal_sync_version_state SET used_bytes=used_bytes-(\(old)) WHERE singleton=1; END"
            result["sync_\(table)_immutable"]="CREATE TRIGGER sync_\(table)_immutable BEFORE UPDATE ON \(name) BEGIN SELECT RAISE(ABORT,'Sync version metadata is immutable'); END"
        }
        for table in SyncCanonicalTable.allCases {
            let schema=table.schema,key=schema.snapshot("old",true),whereOld="table_name='\(table.rawValue)' AND local_key=\(key)"
            let revoke="INSERT OR IGNORE INTO personal_sync_version_revoked SELECT object_digest FROM personal_sync_identities WHERE \(whereOld);"
            let purge="DELETE FROM personal_sync_versions WHERE \(whereOld);"
            let bindings=table == .source ? "DELETE FROM personal_sync_version_sessions WHERE local_key=\(key);":(table == .routineRun ? "DELETE FROM personal_sync_version_runs WHERE local_key=\(key);":(table == .routine ? "DELETE FROM personal_sync_version_recipes WHERE object_digest IN (SELECT object_digest FROM personal_sync_identities WHERE \(whereOld));":""))
            result["sync_versions_\(table.rawValue)_delete"]="CREATE TRIGGER sync_versions_\(table.rawValue)_delete BEFORE DELETE ON \(table.rawValue) BEGIN \(revoke) \(purge) \(bindings) END"
            let moved=schema.primary.map {"old.\($0) IS NOT new.\($0)"}.joined(separator:" OR ")
            result["sync_versions_\(table.rawValue)_move"]="CREATE TRIGGER sync_versions_\(table.rawValue)_move BEFORE UPDATE OF \(schema.primary.joined(separator:",")) ON \(table.rawValue) WHEN \(moved) BEGIN \(revoke) \(purge) \(bindings) END"
            let sensitive:String
            if table == .source {sensitive=schema.columns.filter {$0 != "favorite" && $0 != "payload"}.map {"old.\($0) IS NOT new.\($0)"}.joined(separator:" OR ")+" OR oswind_sync_source_revision_v1(old.payload) IS NOT oswind_sync_source_revision_v1(new.payload)"}
            else if table == .routine {continue} // Explicit immutable historical definitions remain until deletion.
            else {sensitive=schema.columns.map {"old.\($0) IS NOT new.\($0)"}.joined(separator:" OR ")}
            if table == .source {result["sync_sessions_source_change"]="CREATE TRIGGER sync_sessions_source_change BEFORE UPDATE OF payload ON memories WHEN json_extract(old.payload,'$.audioSessionID') IS NOT json_extract(new.payload,'$.audioSessionID') BEGIN DELETE FROM personal_sync_version_sessions WHERE local_key=\(key); END"}
            if table == .routineRun {result["sync_runs_recipe_change"]="CREATE TRIGGER sync_runs_recipe_change BEFORE UPDATE OF routine_id,revision ON routine_runs WHEN old.routine_id IS NOT new.routine_id OR old.revision IS NOT new.revision BEGIN DELETE FROM personal_sync_version_runs WHERE local_key=\(key); END"}
            result["sync_versions_\(table.rawValue)_change"]="CREATE TRIGGER sync_versions_\(table.rawValue)_change BEFORE UPDATE OF \(schema.columns.joined(separator:",")) ON \(table.rawValue) WHEN \(sensitive) BEGIN \(purge) END"
        }
        return result
    }()
    private static let expectedSchemas=schemas.merging(indexes,uniquingKeysWith:{$1}).merging(triggers,uniquingKeysWith:{$1})
    static func register(on db:RoutineDatabase)throws {
        guard sqlite3_create_function_v2(db.handle,"oswind_sync_source_revision_v1",1,SQLITE_UTF8|SQLITE_DETERMINISTIC|SQLITE_INNOCUOUS,nil,{context,_,values in
            guard let context,let value=values?[0],sqlite3_value_type(value)==SQLITE_BLOB,sqlite3_value_bytes(value)>0,Int(sqlite3_value_bytes(value))<=MemoryStore.maximumRecordBytes,let bytes=sqlite3_value_blob(value) else {sqlite3_result_error(context,"Invalid sync source payload",-1);return}
            do {
                var memory=try JSONDecoder().decode(Memory.self,from:Data(bytes:bytes,count:Int(sqlite3_value_bytes(value))))
                memory.favorite=false;memory.tags=[];memory.embedding=nil;memory.embeddingModel=nil;memory.searchPreview=nil
                let digest=Data(SHA256.hash(data:try SyncProtocolLimits.encode(memory)))
                digest.withUnsafeBytes {sqlite3_result_blob(context,$0.baseAddress,Int32($0.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
            }catch {sqlite3_result_error(context,"Invalid sync source payload",-1)}
        },nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
    static func install(catalog:SyncIdentityCatalog,journal:SyncJournal,budget:Int64=defaultBudget)throws->Self {
        guard catalog.database.handle==journal.database.handle,(1...maximumBudget).contains(budget) else {throw OSwindError.invalid("Sync version store context differs")}
        let value=Self(catalog:catalog,journal:journal),db=catalog.database
        return try SyncChangeCapture.transaction(db) {
            let expected=expectedSchemas
            let partial=try db.statement("SELECT name FROM sqlite_master WHERE name LIKE 'personal_sync_version%'");var installed=Set<String>(),code=sqlite3_step(partial)
            while code==SQLITE_ROW {installed.insert(db.text(partial,0));code=sqlite3_step(partial)};sqlite3_finalize(partial)
            guard code==SQLITE_DONE,installed.isEmpty || installed==Set(schemas.keys) else {throw OSwindError.database("Sync version schema is incomplete")}
            let present=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE name='personal_sync_version_state'");defer {sqlite3_finalize(present)};guard sqlite3_step(present)==SQLITE_ROW else {throw db.error()};let exists=sqlite3_column_int(present,0)==1
            for (name,sql) in expected.sorted(by:{$0.key<$1.key}) where schemas[name] != nil {try schema(db,name,sql,create:!exists)}
            let insert=try db.statement("INSERT INTO personal_sync_version_state VALUES(1,?,?,?,?,0,?) ON CONFLICT(singleton) DO NOTHING");defer {sqlite3_finalize(insert)}
            db.bind(insert,1,catalog.scope.origin);db.bind(insert,2,catalog.scope.generation);db.bind(insert,3,journal.group);db.bind(insert,4,journal.epoch);sqlite3_bind_int64(insert,5,budget);try db.done(insert)
            for (name,sql) in expected.sorted(by:{$0.key<$1.key}) where schemas[name] == nil {try schema(db,name,sql,create:!exists)}
            try value.context()
            let sum=try db.statement("SELECT (SELECT COALESCE(SUM(bytes+128),0) FROM personal_sync_versions)+(SELECT 192*COUNT(*) FROM personal_sync_version_recipes)+(SELECT COALESCE(SUM(128+length(token)),0) FROM personal_sync_version_sessions)+(SELECT COALESCE(SUM(224+length(recipe)),0) FROM personal_sync_version_runs)=(SELECT used_bytes FROM personal_sync_version_state WHERE singleton=1)");defer {sqlite3_finalize(sum)}
            guard sqlite3_step(sum)==SQLITE_ROW,sqlite3_column_int(sum,0)==1 else {throw OSwindError.database("Sync version accounting differs")}
            return value
        }
    }
    private static func schema(_ db:RoutineDatabase,_ name:String,_ sql:String,create:Bool)throws {
        let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name);let code=sqlite3_step(row)
        if code==SQLITE_ROW {guard db.text(row,0)==sql else {throw OSwindError.database("Sync version schema differs")}}
        else {guard code==SQLITE_DONE,create else {throw OSwindError.database("Sync version schema missing")};try db.execute(sql)}
    }
    private func context()throws {
        guard try SyncChangeCapture.scope(database)==catalog.scope else {throw OSwindError.invalid("Sync version capture generation differs")}
        _=try journal.cursor(for:journal.replica)
        let row=try database.statement("SELECT origin,generation,group_id,epoch,used_bytes,budget,(SELECT enabled FROM personal_sync_capture),(SELECT synchronous FROM pragma_synchronous),(SELECT recursive_triggers FROM pragma_recursive_triggers),(SELECT foreign_keys FROM pragma_foreign_keys) FROM personal_sync_version_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,database.text(row,0)==catalog.scope.origin,database.text(row,1)==catalog.scope.generation,database.text(row,2)==journal.group,database.text(row,3)==journal.epoch,sqlite3_column_type(row,4)==SQLITE_INTEGER,sqlite3_column_type(row,5)==SQLITE_INTEGER,sqlite3_column_int64(row,4)>=0,sqlite3_column_int64(row,4)<=sqlite3_column_int64(row,5),(1...Self.maximumBudget).contains(sqlite3_column_int64(row,5)),sqlite3_column_int(row,6)==1,sqlite3_column_int(row,7)>=2,sqlite3_column_int(row,8)==1,sqlite3_column_int(row,9)==1 else {throw OSwindError.invalid("Sync version scope or durability differs")}
        try requireSchema()
    }
    private func requireSchema()throws {
        let row=try database.statement("PRAGMA schema_version");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_INTEGER else {throw database.error()}
        let cookie=sqlite3_column_int64(row,0);schemaStamp.lock.lock();defer {schemaStamp.lock.unlock()}
        if schemaStamp.value==cookie {return}
        for (name,sql) in Self.expectedSchemas {try Self.schema(database,name,sql,create:false)}
        schemaStamp.value=cookie
    }
    private func bind(_ row:OpaquePointer,_ index:Int32,_ data:Data) {data.withUnsafeBytes {_ = sqlite3_bind_blob(row,index,$0.baseAddress,Int32(data.count),database.transient)}}
    private func blob(_ row:OpaquePointer,_ column:Int32,maximum:Int)throws->Data {
        let size=Int(sqlite3_column_bytes(row,column));guard sqlite3_column_type(row,column)==SQLITE_BLOB,size>0,size<=maximum,let p=sqlite3_column_blob(row,column) else {throw OSwindError.database("Invalid sync version bytes")};return Data(bytes:p,count:size)
    }
    private func owner(_ identity:SyncObjectIdentity)throws->(SyncLocalObject,Data) {
        let key=try identity.key,row=try database.statement("SELECT 1 FROM personal_sync_version_revoked WHERE object_digest=?");defer {sqlite3_finalize(row)};database.bind(row,1,key.digest)
        guard sqlite3_step(row)==SQLITE_DONE,try !journal.state(for:key).isDeleted,let object=try catalog.object(identity),!object.deleted,let primary=object.primary else {throw OSwindError.invalid("Sync version owner was deleted or is not locally mapped")}
        return (object,Data(SHA256.hash(data:try SyncIdentityCatalog.keyFrame(identity.table,primary))))
    }
    private func stored(_ reference:SyncVersionReference)throws->SyncPortableRecord? {
        try reference.validate(reference.identity.table);_=try owner(reference.identity)
        let row=try database.statement("SELECT table_name,bytes,body,local_key FROM personal_sync_versions WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(row)};database.bind(row,1,try reference.identity.key.digest);database.bind(row,2,reference.content.sha256)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW,database.text(row,0)==reference.identity.table.rawValue,sqlite3_column_type(row,1)==SQLITE_INTEGER,sqlite3_column_int64(row,1)==reference.content.bytes,try blob(row,3,maximum:32)==owner(reference.identity).1 else {throw OSwindError.database("Sync version binding differs")}
        return try SyncPortableRecord.decode(blob(row,2,maximum:Int(SyncProtocolLimits.contentBytes)),expected:reference)
    }
    private func head(_ record:SyncPortableRecord)throws->Bool {
        let state=try journal.state(for:record.identity.key);guard !state.isDeleted else {return false}
        let content=try record.reference.content;return state.heads.contains {$0.content==content}
    }
    @discardableResult func retain(_ record:SyncPortableRecord,requiredBy requester:SyncPortableRecord?=nil,admit:(SyncPortableRecord)throws->Void)throws->SyncVersionReference {
        try SyncChangeCapture.transaction(database) {
            try context();try record.validate();let reference=try record.reference,(_,localKey)=try owner(record.identity)
            var authorized=try head(record)
            if !authorized,let requester {
                try requester.validate();let authenticated=try head(requester) || stored(requester.reference) != nil
                authorized=authenticated && requester.dependencies.contains {.init(identity:record.identity,content:reference.content)==$0}
                if authorized {try admit(requester)}
            }
            let prior=try stored(reference);guard authorized || prior != nil else {throw OSwindError.invalid("Sync version is neither an admitted head nor an exact requested dependency")}
            try admit(record);try context()
            guard try owner(record.identity).1==localKey else {throw OSwindError.invalid("Sync version local owner changed during admission")}
            if prior != nil {
                guard try stored(reference) != nil else {throw OSwindError.invalid("Sync cached version disappeared during admission")};return reference
            }
            if try !head(record) {
                guard let requester,try (head(requester) || stored(requester.reference) != nil),requester.dependencies.contains(where:{$0.identity==record.identity && $0.content==reference.content}) else {throw OSwindError.invalid("Sync version authorization changed during admission")}
            }
            let data=try record.encoded(),row=try database.statement("INSERT INTO personal_sync_versions VALUES(?,?,?,?,?,?)");defer {sqlite3_finalize(row)}
            database.bind(row,1,try record.identity.key.digest);database.bind(row,2,reference.content.sha256);database.bind(row,3,record.identity.table.rawValue);bind(row,4,localKey);sqlite3_bind_int64(row,5,reference.content.bytes);bind(row,6,data);try database.done(row);try context();return reference
        }
    }
    func record(_ reference:SyncVersionReference,admit:(SyncPortableRecord)throws->Void)throws->SyncPortableRecord? {
        try SyncChangeCapture.transaction(database) {try context();guard let value=try stored(reference) else {return nil};try admit(value);try context();guard try stored(reference) != nil else {throw OSwindError.invalid("Sync evidence disappeared during admission")};return value}
    }
    private func currentRow(_ identity:SyncObjectIdentity)throws->SyncRowSnapshot {
        let (object,_)=try owner(identity),primary=object.primary!,table=identity.table
        let row=try database.statement("SELECT "+table.schema.snapshot("t")+" FROM "+table.rawValue+" t WHERE "+table.schema.primary.map {"t.\($0) IS ?"}.joined(separator:" AND "));defer {sqlite3_finalize(row)}
        for (i,cell) in primary.enumerated() {switch cell {case .text(let data):data.withUnsafeBytes {_ = sqlite3_bind_text64(row,Int32(i+1),$0.baseAddress?.assumingMemoryBound(to:CChar.self),UInt64(data.count),database.transient,UInt8(SQLITE_UTF8))};case .integer(let n):sqlite3_bind_int64(row,Int32(i+1),n);default:throw OSwindError.invalid("Invalid sync projection key")}}
        guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Sync projection source no longer exists")};return try .decode(blob(row,0,maximum:SyncRowSnapshot.maximumBytes))
    }
    func resolve(_ identity:SyncObjectIdentity,content:SyncContentReference?,admit:(SyncPortableRecord)throws->Void)throws->SyncPortableRecord {
        try SyncChangeCapture.transaction(database) {
            try context()
            if let content {guard let value=try record(.init(identity:identity,content:content),admit:admit) else {throw OSwindError.unavailable("Exact sync dependency version is unavailable")};return value}
            let row=try database.statement("SELECT content_sha,row_digest FROM personal_sync_version_projection WHERE object_digest=?");defer {sqlite3_finalize(row)};database.bind(row,1,try identity.key.digest)
            guard sqlite3_step(row)==SQLITE_ROW,SyncProtocolLimits.hex(try currentRow(identity).encoded())==database.text(row,1) else {throw OSwindError.unavailable("Sync projection is missing or changed")}
            let version=try database.statement("SELECT bytes FROM personal_sync_versions WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(version)};database.bind(version,1,try identity.key.digest);database.bind(version,2,database.text(row,0))
            guard sqlite3_step(version)==SQLITE_ROW else {throw OSwindError.database("Sync projected version missing")}
            let reference=try SyncContentReference(sha256:database.text(row,0),bytes:sqlite3_column_int64(version,0));guard let value=try record(.init(identity:identity,content:reference),admit:admit) else {throw OSwindError.database("Sync projected body missing")}
            guard SyncProtocolLimits.hex(try currentRow(identity).encoded())==database.text(row,1) else {throw OSwindError.invalid("Sync local projection changed during admission")}
            let check=try database.statement("SELECT content_sha,row_digest FROM personal_sync_version_projection WHERE object_digest=?");defer {sqlite3_finalize(check)};database.bind(check,1,try identity.key.digest)
            guard sqlite3_step(check)==SQLITE_ROW,database.text(check,0)==reference.sha256,database.text(check,1)==database.text(row,1) else {throw OSwindError.invalid("Sync projection binding changed during admission")};return value
        }
    }
    func bindProjection(_ reference:SyncVersionReference,references:SyncPortableReferences,admit:(SyncPortableRecord)throws->Void)throws {
        try SyncChangeCapture.transaction(database) {
            try context();guard let record=try self.record(reference,admit:admit) else {throw OSwindError.unavailable("Prepare the exact sync version before binding")}
            let row=try currentRow(reference.identity),rebuilt=try SyncPortableExporter(references:references).record(identity:reference.identity,row:row)
            guard try rebuilt.encoded()==record.encoded() else {throw OSwindError.invalid("Sync projection differs from its original local row")}
            try record.validateDependencies {try resolve($0,content:$1,admit:admit)}
            var evidence:String?,entity:String?
            if reference.identity.table == .source,case .blob(let data)=row.cells[8] {let memory=try JSONDecoder().decode(Memory.self,from:data);evidence=memory.evidenceHash;entity=memory.entityRevision}
            try context();guard try currentRow(reference.identity).encoded()==row.encoded(),try stored(reference) != nil else {throw OSwindError.invalid("Sync projection source changed during dependency admission")}
            try bindMetadata(record,row:row)
            let put=try database.statement("INSERT INTO personal_sync_version_projection VALUES(?,?,?,?,?) ON CONFLICT(object_digest) DO UPDATE SET content_sha=excluded.content_sha,row_digest=excluded.row_digest,evidence=excluded.evidence,entity_revision=excluded.entity_revision");defer {sqlite3_finalize(put)}
            database.bind(put,1,try reference.identity.key.digest);database.bind(put,2,reference.content.sha256);database.bind(put,3,SyncProtocolLimits.hex(try row.encoded()));database.bind(put,4,evidence);database.bind(put,5,entity);try database.done(put);try context()
        }
    }
    func sourceVersion(localID:String,revision:SyncLocalSourceRevision,admit:(SyncPortableRecord)throws->Void)throws->SyncVersionReference {
        try SyncChangeCapture.transaction(database) {
            try context();let key=Data(SHA256.hash(data:try SyncIdentityCatalog.keyFrame(.source,[.text(Data(localID.utf8))])))
            let row=try database.statement("SELECT p.object_digest,p.content_sha,p.evidence,p.entity_revision,v.body FROM personal_sync_version_projection p JOIN personal_sync_versions v ON v.object_digest=p.object_digest AND v.content_sha=p.content_sha WHERE v.table_name='memories' AND v.local_key=?");defer {sqlite3_finalize(row)};bind(row,1,key)
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("Local sync source projection is unavailable")}
            let value=try SyncPortableRecord.decode(blob(row,4,maximum:Int(SyncProtocolLimits.contentBytes)))
            let original=try currentRow(value.identity);guard case .blob(let payload)=original.cells[8] else {throw OSwindError.database("Sync source binding payload differs")}
            let memory=try JSONDecoder().decode(Memory.self,from:payload)
            guard sqlite3_column_type(row,2)==SQLITE_TEXT,sqlite3_column_type(row,3)==SQLITE_TEXT,Data(memory.evidenceHash.utf8)==Data(database.text(row,2).utf8),Data(memory.entityRevision.utf8)==Data(database.text(row,3).utf8) else {throw OSwindError.database("Sync source revision binding differs from original evidence")}
            switch revision {case .current:break;case .evidence(let expected):guard Data(expected.utf8)==Data(database.text(row,2).utf8) else {throw OSwindError.invalid("Local sync evidence revision differs")};case .entity(let expected):guard Data(expected.utf8)==Data(database.text(row,3).utf8) else {throw OSwindError.invalid("Local sync entity revision differs")}}
            let current=try resolve(value.identity,content:nil,admit:admit);guard try current.reference==value.reference else {throw OSwindError.invalid("Sync source projection changed during admission")};return try value.reference
        }
    }
    private func mappedIdentity(_ table:SyncCanonicalTable,_ primary:[SyncRowCell])throws->SyncObjectIdentity {
        let key=Data(SHA256.hash(data:try SyncIdentityCatalog.keyFrame(table,primary)))
        let row=try database.statement("SELECT i.origin,i.lifetime FROM personal_sync_identity_current c JOIN personal_sync_identities i ON i.object_digest=c.object_digest WHERE c.table_name=? AND c.local_key=? AND i.deleted=0");defer {sqlite3_finalize(row)};database.bind(row,1,table.rawValue);bind(row,2,key)
        guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("Sync local identity is not prepared")}
        let identity=try SyncObjectIdentity(table:table,origin:database.text(row,0),lifetime:database.text(row,1)),object=try owner(identity)
        guard object.1==key,object.0.primary==primary else {throw OSwindError.invalid("Sync local identity key differs")};return identity
    }
    private func recipeBindingDigest(_ object:String,_ ordinal:Int64,_ content:SyncContentReference)throws->String {
        var bytes=Data("OSwind.sync.recipe-binding.v1\0".utf8);bytes.append(try SyncRowSnapshot([.text(Data(object.utf8)),.integer(ordinal),.text(Data(content.sha256.utf8)),.integer(content.bytes)]).encoded());return SyncProtocolLimits.hex(bytes)
    }
    private func runRecipeDigest(_ data:Data)->String {SyncProtocolLimits.hex(Data("OSwind.sync.run-recipe.v1\0".utf8)+data)}
    private func bindMetadata(_ record:SyncPortableRecord,row:SyncRowSnapshot)throws {
        let digest=try record.identity.key.digest,(_,localKey)=try owner(record.identity)
        switch record.body {
        case .routine:
            guard case .integer(let ordinal)=row.cells[1],ordinal>0 else {throw OSwindError.invalid("Sync recipe local revision differs")}
            let ref=try record.reference,old=try database.statement("SELECT content_sha,bytes,binding_sha FROM personal_sync_version_recipes WHERE object_digest=? AND ordinal=?");defer {sqlite3_finalize(old)};database.bind(old,1,digest);sqlite3_bind_int64(old,2,ordinal)
            let status=sqlite3_step(old),checksum=try recipeBindingDigest(digest,ordinal,ref.content)
            guard status==SQLITE_DONE || (status==SQLITE_ROW && database.text(old,0)==ref.content.sha256 && sqlite3_column_type(old,1)==SQLITE_INTEGER && sqlite3_column_int64(old,1)==ref.content.bytes && database.text(old,2)==checksum) else {throw OSwindError.invalid("Sync recipe ordinal already names a different or corrupt definition")}
            if status==SQLITE_ROW {return}
            let put=try database.statement("INSERT INTO personal_sync_version_recipes VALUES(?,?,?,?,?) ON CONFLICT DO NOTHING");defer {sqlite3_finalize(put)};database.bind(put,1,digest);sqlite3_bind_int64(put,2,ordinal);database.bind(put,3,ref.content.sha256);sqlite3_bind_int64(put,4,ref.content.bytes);database.bind(put,5,checksum);try database.done(put)
        case .source(let body):
            if let token=body.audioSession {
                let data=try SyncProtocolLimits.encode(token),old=try database.statement("SELECT local_key,token FROM personal_sync_version_sessions WHERE object_digest=?");defer {sqlite3_finalize(old)};database.bind(old,1,digest);let status=sqlite3_step(old)
                if status==SQLITE_ROW,try blob(old,0,maximum:32)==localKey,try blob(old,1,maximum:4096)==data {return}
                guard status==SQLITE_ROW || status==SQLITE_DONE else {throw database.error()}
                let drop=try database.statement("DELETE FROM personal_sync_version_sessions WHERE object_digest=?");defer {sqlite3_finalize(drop)};database.bind(drop,1,digest);try database.done(drop)
                let put=try database.statement("INSERT INTO personal_sync_version_sessions VALUES(?,?,?)");defer {sqlite3_finalize(put)};database.bind(put,1,digest);bind(put,2,localKey);bind(put,3,data);try database.done(put)
            }
        case .routineRun(let body):
            guard case .text(let routine)=row.cells[1],case .integer(let ordinal)=row.cells[2] else {throw OSwindError.invalid("Sync run binding columns differ")}
            let recipeKey=Data(SHA256.hash(data:try SyncIdentityCatalog.keyFrame(.routine,[.text(routine)]))),data=try SyncProtocolLimits.encode(body.recipe)
            let old=try database.statement("SELECT routine_key,local_revision,recipe,recipe_sha FROM personal_sync_version_runs WHERE object_digest=?");defer {sqlite3_finalize(old)};database.bind(old,1,digest);let status=sqlite3_step(old)
            if status==SQLITE_ROW {guard try blob(old,0,maximum:32)==recipeKey,sqlite3_column_int64(old,1)==ordinal,try blob(old,2,maximum:4096)==data,database.text(old,3)==runRecipeDigest(data) else {throw OSwindError.invalid("Sync run recipe attribution already differs")}}
            else {guard status==SQLITE_DONE else {throw database.error()}}
            if status==SQLITE_ROW {return}
            let put=try database.statement("INSERT INTO personal_sync_version_runs VALUES(?,?,?,?,?,?) ON CONFLICT DO NOTHING");defer {sqlite3_finalize(put)};database.bind(put,1,digest);bind(put,2,localKey);bind(put,3,recipeKey);sqlite3_bind_int64(put,4,ordinal);bind(put,5,data);database.bind(put,6,runRecipeDigest(data));try database.done(put)
        default:break
        }
    }
    func recipeVersion(localID:String,ordinal:Int64,admit:(SyncPortableRecord)throws->Void)throws->SyncRoutineRevision {
        try SyncChangeCapture.transaction(database) {
            try context();let identity=try mappedIdentity(.routine,[.text(Data(localID.utf8))]),current=try currentRow(identity)
            guard case .integer(let actual)=current.cells[1],ordinal>0,ordinal<=actual else {throw OSwindError.invalid("Sync recipe revision is outside local history")}
            let row=try database.statement("SELECT content_sha,bytes,binding_sha FROM personal_sync_version_recipes WHERE object_digest=? AND ordinal=?");defer {sqlite3_finalize(row)};database.bind(row,1,try identity.key.digest);sqlite3_bind_int64(row,2,ordinal);let status=sqlite3_step(row)
            guard status==SQLITE_ROW || status==SQLITE_DONE else {throw database.error()}
            var content:SyncContentReference?
            if status==SQLITE_ROW {content=try SyncContentReference(sha256:database.text(row,0),bytes:sqlite3_column_int64(row,1));guard try database.text(row,2)==recipeBindingDigest(identity.key.digest,ordinal,content!) else {throw OSwindError.database("Historical sync recipe binding integrity differs")};if try record(.init(identity:identity,content:content!),admit:admit)==nil {_=try resolve(identity,content:nil,admit:admit)}}
            else {_=try resolve(identity,content:nil,admit:admit)}
            return .init(routine:identity,editorOrigin:catalog.scope.origin,ordinal:ordinal,definition:content)
        }
    }
    func sessionBinding(localID:String,admit:(Memory)throws->Void)throws->SyncSessionToken? {
        try SyncChangeCapture.transaction(database) {
            try context();let identity=try mappedIdentity(.source,[.text(Data(localID.utf8))]),row=try currentRow(identity)
            guard case .blob(let data)=row.cells[8] else {throw OSwindError.invalid("Sync session local source differs")}
            let memory=try JSONDecoder().decode(Memory.self,from:data)
            guard let session=memory.audioSessionID else {return nil}
            try admit(memory);try context();guard try currentRow(identity).encoded()==row.encoded() else {throw OSwindError.invalid("Sync session source changed during admission")}
            let binding=try database.statement("SELECT local_key,token FROM personal_sync_version_sessions WHERE object_digest=?");defer {sqlite3_finalize(binding)};database.bind(binding,1,try identity.key.digest);let status=sqlite3_step(binding)
            if status==SQLITE_ROW {
                guard try blob(binding,0,maximum:32)==owner(identity).1 else {throw OSwindError.invalid("Sync session local key differs")}
                let encoded=try blob(binding,1,maximum:4096),token=try JSONDecoder().decode(SyncSessionToken.self,from:encoded);try token.validate();guard try SyncProtocolLimits.encode(token)==encoded else {throw OSwindError.invalid("Noncanonical sync session binding")}
                if session==token.localProjection {return token}
            }else {guard status==SQLITE_DONE else {throw database.error()}}
            guard !(session.hasPrefix("sync-") && session.utf8.count==106) else {throw OSwindError.unavailable("Original sync session binding is unavailable; do not rehash a peer projection")}
            return nil
        }
    }
    func runRecipe(localRunID:String,recipeID:String,ordinal:Int64,admit:(SyncPortableRecord)throws->Void)throws->SyncRoutineRevision? {
        try SyncChangeCapture.transaction(database) {
            try context();let identity=try mappedIdentity(.routineRun,[.text(Data(localRunID.utf8))]),current=try currentRow(identity)
            guard case .text(let actualRecipe)=current.cells[1],actualRecipe==Data(recipeID.utf8),case .integer(let actualOrdinal)=current.cells[2],actualOrdinal==ordinal else {throw OSwindError.invalid("Sync run local recipe arguments differ")}
            let row=try database.statement("SELECT local_key,routine_key,local_revision,recipe,recipe_sha FROM personal_sync_version_runs WHERE object_digest=?");defer {sqlite3_finalize(row)};database.bind(row,1,try identity.key.digest);let status=sqlite3_step(row)
            if status==SQLITE_DONE {return nil};guard status==SQLITE_ROW,try blob(row,0,maximum:32)==owner(identity).1,try blob(row,1,maximum:32)==Data(SHA256.hash(data:SyncIdentityCatalog.keyFrame(.routine,[.text(Data(recipeID.utf8))]))),sqlite3_column_int64(row,2)==ordinal else {throw OSwindError.invalid("Sync run durable binding differs")}
            let encoded=try blob(row,3,maximum:4096);guard database.text(row,4)==runRecipeDigest(encoded) else {throw OSwindError.database("Sync run recipe binding integrity differs")};let recipe=try JSONDecoder().decode(SyncRoutineRevision.self,from:encoded);try recipe.validate()
            guard try SyncProtocolLimits.encode(recipe)==encoded,try recipe.routine==mappedIdentity(.routine,[.text(Data(recipeID.utf8))]) else {throw OSwindError.invalid("Sync run global recipe differs")}
            _=try resolve(recipe.routine,content:recipe.definition,admit:admit);try context();guard try currentRow(identity).encoded()==current.encoded() else {throw OSwindError.invalid("Sync run changed during admission")};return recipe
        }
    }

}
