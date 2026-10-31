import Foundation
import CSQLite
import CryptoKit

struct HistoricalEvidence {
    let record:SyncPortableRecord
    let sourceID:String
    let memory:Memory
    var reference:SyncVersionReference {get throws {try record.reference}}
    var handle:String {memory.originalEvidence!.handle}
}

/// Canonical archival data, not device enrollment or journal authority. Unlike
/// the sync cache, these exact originals are explicitly copied by quiet restore.
struct HistoricalEvidenceStore {
    let database:RoutineDatabase
    private final class SchemaStamp {let lock=NSLock();var value:Int64?}
    private let schemaStamp=SchemaStamp()
    init(database:RoutineDatabase) {self.database=database}
    static let defaultBudget:Int64=256*1024*1024,maximumBudget:Int64=8*1024*1024*1024
    static let charge="256+length(new.body)+length(new.paths)+length(new.parents)+128*json_array_length(CAST(new.parents AS TEXT))"
    static func ancestors(_ root:String)->String {"WITH RECURSIVE affected(handle) AS (SELECT \(root) UNION SELECT d.child FROM historical_evidence_dependencies d JOIN affected a ON d.parent=a.handle) SELECT handle FROM affected"}
    static let schemas:[String:String] = {
        let affected=ancestors("old.handle"),cost=charge,oldCost=charge.replacingOccurrences(of:"new.",with:"old.")
        var result:[String:String] = [
            "historical_evidence_state":"CREATE TABLE historical_evidence_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),used_bytes INTEGER NOT NULL CHECK(typeof(used_bytes)='integer' AND used_bytes>=0 AND used_bytes<=budget),budget INTEGER NOT NULL CHECK(typeof(budget)='integer' AND budget>0 AND budget<=8589934592),revision BLOB NOT NULL CHECK(typeof(revision)='blob' AND length(revision)=16))",
            "historical_evidence":"CREATE TABLE historical_evidence(handle TEXT PRIMARY KEY,source_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,object_digest TEXT NOT NULL,content_sha TEXT NOT NULL,body BLOB NOT NULL CHECK(typeof(body)='blob' AND length(body)>0 AND length(body)<=134217728),paths BLOB NOT NULL CHECK(typeof(paths)='blob' AND length(paths)<=65536 AND json_valid(CAST(paths AS TEXT))),parents BLOB NOT NULL CHECK(typeof(parents)='blob' AND length(parents)<=65536 AND json_valid(CAST(parents AS TEXT))),projection_sha TEXT NOT NULL,UNIQUE(object_digest,content_sha))",
            "historical_evidence_dependencies":"CREATE TABLE historical_evidence_dependencies(child TEXT NOT NULL REFERENCES historical_evidence(handle) ON DELETE CASCADE,parent TEXT NOT NULL REFERENCES historical_evidence(handle) ON DELETE CASCADE,PRIMARY KEY(child,parent),CHECK(child<>parent))",
            "historical_evidence_pins":"CREATE TABLE historical_evidence_pins(memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,handle TEXT NOT NULL REFERENCES historical_evidence(handle) ON DELETE CASCADE)",
            "historical_budget":"CREATE TRIGGER historical_budget BEFORE INSERT ON historical_evidence BEGIN SELECT CASE WHEN (SELECT used_bytes+\(cost)>budget FROM historical_evidence_state WHERE singleton=1) THEN RAISE(ABORT,'Historical evidence storage is full') END; END",
            "historical_added":"CREATE TRIGGER historical_added AFTER INSERT ON historical_evidence BEGIN UPDATE historical_evidence_state SET used_bytes=used_bytes+\(cost),revision=randomblob(16) WHERE singleton=1; END",
            "historical_removed":"CREATE TRIGGER historical_removed AFTER DELETE ON historical_evidence BEGIN UPDATE historical_evidence_state SET used_bytes=used_bytes-(\(oldCost)),revision=randomblob(16) WHERE singleton=1; END",
            "historical_immutable":"CREATE TRIGGER historical_immutable BEFORE UPDATE ON historical_evidence BEGIN SELECT RAISE(ABORT,'Historical evidence is immutable'); END",
            "historical_owner_revision":"CREATE TRIGGER historical_owner_revision BEFORE UPDATE OF timestamp,kind,app,title,url,text,payload ON memories WHEN EXISTS(SELECT 1 FROM historical_evidence WHERE source_id=old.id) AND (old.timestamp IS NOT new.timestamp OR old.kind IS NOT new.kind OR old.app IS NOT new.app OR old.title IS NOT new.title OR old.url IS NOT new.url OR old.text IS NOT new.text OR oswind_sync_source_revision_v1(old.payload) IS NOT oswind_sync_source_revision_v1(new.payload)) BEGIN DELETE FROM historical_evidence WHERE source_id=old.id; END",
            "historical_owner_delete":"CREATE TRIGGER historical_owner_delete BEFORE DELETE ON memories BEGIN DELETE FROM historical_evidence WHERE source_id=old.id; END",
            "historical_erasure":"""
            CREATE TRIGGER historical_erasure BEFORE DELETE ON historical_evidence BEGIN
                INSERT OR IGNORE INTO erasure_assets SELECT value FROM json_each(CAST(old.paths AS TEXT));
                UPDATE chat_sessions SET title='Conversation' WHERE id IN (SELECT session_id FROM chat_turns WHERE id IN (SELECT turn_id FROM chat_sources WHERE historical_handle IN (\(affected))));
                DELETE FROM chat_turns WHERE id IN (SELECT turn_id FROM chat_sources WHERE historical_handle IN (\(affected)));
                DELETE FROM memories WHERE id IN (SELECT recap_id FROM recap_sources WHERE historical_handle IN (\(affected)));
                DELETE FROM text_observation_pins WHERE memory_id IN (SELECT memory_id FROM historical_evidence_pins WHERE handle IN (\(affected)));
                DELETE FROM historical_evidence WHERE handle<>old.handle AND handle IN (\(affected));
            END
            """
        ]
        result["historical_owner_index"]="CREATE INDEX historical_owner_index ON historical_evidence(source_id)"
        result["historical_parent_index"]="CREATE INDEX historical_parent_index ON historical_evidence_dependencies(parent,child)"
        result["historical_pin_index"]="CREATE INDEX historical_pin_index ON historical_evidence_pins(handle,memory_id)"
        result["historical_pin_delete"]="CREATE TRIGGER historical_pin_delete BEFORE DELETE ON text_observation_pins BEGIN DELETE FROM historical_evidence_pins WHERE memory_id=old.memory_id; END"
        result["historical_pin_move"]="CREATE TRIGGER historical_pin_move BEFORE UPDATE OF memory_id ON text_observation_pins WHEN old.memory_id IS NOT new.memory_id BEGIN DELETE FROM historical_evidence_pins WHERE memory_id=old.memory_id; END"
        result["historical_owner_move"]="CREATE TRIGGER historical_owner_move BEFORE UPDATE OF id ON memories WHEN old.id IS NOT new.id BEGIN DELETE FROM historical_evidence WHERE source_id=old.id; END"
        for table in SyncChangeCapture.tables {for operation in ["insert","update","delete"] {
            let name="historical_writer_"+table.name+"_"+operation
            result[name]="CREATE TRIGGER \(name) BEFORE \(operation.uppercased()) ON \(table.name) BEGIN SELECT oswind_historical_writer_v1(); END"
        }}
        return result
    }()
    static func registerWriter(_ db:RoutineDatabase)throws {
        guard sqlite3_create_function_v2(db.handle,"oswind_historical_writer_v1",0,SQLITE_UTF8|SQLITE_DETERMINISTIC|SQLITE_INNOCUOUS,nil,{context,_,_ in sqlite3_result_int(context,1)},nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
    static func install(_ db:RoutineDatabase,sourceVersion:Int32,repairMissingPins:Bool=false)throws {
        for name in ["historical_evidence_state","historical_evidence","historical_evidence_dependencies","historical_evidence_pins"]+schemas.keys.filter({$0.hasPrefix("historical_") && !["historical_evidence_state","historical_evidence","historical_evidence_dependencies","historical_evidence_pins"].contains($0)}).sorted() {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name);let code=sqlite3_step(row),found=code==SQLITE_ROW ? db.text(row,0):nil;sqlite3_finalize(row)
            guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
            if let found {guard found==schemas[name]! else {throw OSwindError.database("Historical evidence protection schema differs")}}
            else {guard sourceVersion<26 || (repairMissingPins && (name.hasPrefix("historical_writer_text_observation_pins_") || name=="historical_pin_delete" || name=="historical_pin_move")) else {throw OSwindError.database("Historical evidence schema is missing")};try db.execute(schemas[name]!)}
        }
        if sourceVersion>=26 {let existing=try db.statement("SELECT COUNT(*) FROM historical_evidence_state");defer {sqlite3_finalize(existing)};guard sqlite3_step(existing)==SQLITE_ROW,sqlite3_column_int(existing,0)==1 else {throw OSwindError.database("Historical evidence accounting is missing")}}
        let row=try db.statement("INSERT INTO historical_evidence_state VALUES(1,0,?,randomblob(16)) ON CONFLICT(singleton) DO NOTHING");defer {sqlite3_finalize(row)};sqlite3_bind_int64(row,1,defaultBudget);try db.done(row)
        try Self(database:db).checkAccounting(allowLegacyCitationUpgrade:sourceVersion<26)
    }
    private func context(writing:Bool=false,requireCitations:Bool=true)throws {
        let cookieRow=try database.statement("PRAGMA schema_version");defer {sqlite3_finalize(cookieRow)};guard sqlite3_step(cookieRow)==SQLITE_ROW else {throw database.error()};let cookie=sqlite3_column_int64(cookieRow,0)
        schemaStamp.lock.lock()
        do {
            if !requireCitations || schemaStamp.value != cookie {
                for (name,sql) in Self.schemas {let row=try database.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};database.bind(row,1,name);guard sqlite3_step(row)==SQLITE_ROW,database.text(row,0)==sql else {throw OSwindError.database("Historical evidence protection differs")}}
                if requireCitations {try CitationSchema.validate(database);schemaStamp.value=cookie}
            }
            schemaStamp.lock.unlock()
        }catch {schemaStamp.lock.unlock();throw error}
        let row=try database.statement("SELECT used_bytes,budget,(SELECT foreign_keys FROM pragma_foreign_keys),(SELECT recursive_triggers FROM pragma_recursive_triggers) FROM historical_evidence_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_INTEGER,sqlite3_column_type(row,1)==SQLITE_INTEGER,(0...sqlite3_column_int64(row,1)).contains(sqlite3_column_int64(row,0)),(1...Self.maximumBudget).contains(sqlite3_column_int64(row,1)),((!writing && sqlite3_db_readonly(database.handle,"main")==1) || (sqlite3_column_int(row,2)==1 && sqlite3_column_int(row,3)==1)) else {throw OSwindError.database("Historical evidence accounting or writer protection differs")}
    }
    struct Row:Equatable {let source:String,object:String,sha:String,body:Data,paths:Data,parents:Data,projection:String}
    func checkAccounting(allowLegacyCitationUpgrade:Bool=false)throws {
        try context(requireCitations:!allowLegacyCitationUpgrade)
        let row=try database.statement("SELECT used_bytes=(SELECT COALESCE(SUM(256+length(body)+length(paths)+length(parents)+128*json_array_length(CAST(parents AS TEXT))),0) FROM historical_evidence) FROM historical_evidence_state WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_int(row,0)==1 else {throw OSwindError.database("Historical evidence accounting differs")}
    }
    private func snapshot<T>(_ body:()throws->T)throws->T {
        if sqlite3_db_readonly(database.handle,"main") != 1 {return try SyncChangeCapture.transaction(database,body)}
        try database.execute("SAVEPOINT historical_read")
        do {let value=try body();try Task.checkCancellation();try database.execute("RELEASE historical_read");return value}
        catch {try? database.execute("ROLLBACK TO historical_read; RELEASE historical_read");throw error}
    }
    private func blob(_ row:OpaquePointer,_ column:Int32,_ maximum:Int)throws->Data {let n=Int(sqlite3_column_bytes(row,column));guard sqlite3_column_type(row,column)==SQLITE_BLOB,n>0,n<=maximum,let p=sqlite3_column_blob(row,column) else {throw OSwindError.database("Invalid historical evidence bytes")};return Data(bytes:p,count:n)}
    private func bind(_ row:OpaquePointer,_ column:Int32,_ data:Data) {data.withUnsafeBytes {_ = sqlite3_bind_blob(row,column,$0.baseAddress,Int32(data.count),database.transient)}}
    func row(_ handle:String)throws->Row? {
        try SyncProtocolLimits.uuid(handle);let row=try database.statement("SELECT source_id,object_digest,content_sha,body,paths,parents,projection_sha FROM historical_evidence WHERE handle=?");defer {sqlite3_finalize(row)};database.bind(row,1,handle)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw database.error()}
        return try .init(source:database.text(row,0),object:database.text(row,1),sha:database.text(row,2),body:blob(row,3,Int(SyncProtocolLimits.contentBytes)),paths:blob(row,4,65536),parents:blob(row,5,65536),projection:database.text(row,6))
    }
    private func ownerExists(_ source:String)throws {
        guard !source.isEmpty,source.utf8.count<800 else {throw OSwindError.database("Invalid historical source owner")}
        let row=try database.statement("SELECT 1 FROM memories WHERE id=?");defer {sqlite3_finalize(row)};database.bind(row,1,source);guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("Historical evidence owner was erased")}
    }
    static func paths(_ bytes:Data)throws->[SyncMediaRole:String] {
        let values=try JSONDecoder().decode([String:String].self,from:bytes);guard values.count<=3,try SyncProtocolLimits.encode(values)==bytes else {throw OSwindError.invalid("Invalid historical media paths")}
        var result=[SyncMediaRole:String]()
        for (key,path) in values {guard let role=SyncMediaRole(rawValue:key),path.utf8.count<=4096,!path.utf8.contains(0),!path.hasPrefix("/"),!path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0=="." || $0==".."}),path.hasPrefix(role == .image ? "images/":(role == .audio ? "audio/":"video/")) else {throw OSwindError.invalid("Historical media path is outside its role")};result[role]=path};return result
    }
    private func fingerprint(_ memory:Memory,handle:String,source:String,record:SyncPortableRecord)throws->String {
        let ref=try record.reference,binding=[handle,source,try ref.identity.key.digest,ref.content.sha256,String(ref.content.bytes)]
        var hash=SHA256();hash.update(data:Data("OSwind.historical-evidence.v1\0".utf8));hash.update(data:try SyncProtocolLimits.encode(binding));hash.update(data:Data([0]));hash.update(data:try SyncProtocolLimits.encode(memory));return hash.finalize().map {String(format:"%02x",$0)}.joined()
    }
    private func finish(_ audit:[String:Row])throws {
        try context()
        for (handle,value) in audit {
            try ownerExists(value.source);guard try row(handle)==value else {throw OSwindError.invalid("Historical evidence changed during admission")}
            let row=try database.statement("SELECT parent FROM historical_evidence_dependencies WHERE child=?");defer {sqlite3_finalize(row)};database.bind(row,1,handle);var parents=Set<String>(),code=sqlite3_step(row)
            while code==SQLITE_ROW {parents.insert(database.text(row,0));code=sqlite3_step(row)}
            guard code==SQLITE_DONE,parents==Set(try JSONDecoder().decode([String].self,from:value.parents)) else {throw OSwindError.invalid("Historical erasure graph changed during admission")}
        }
    }
    func read(_ handle:String,sourceID:String?=nil,verifyMedia:(SyncVersionReference,[SyncMediaManifest],[SyncMediaRole:String])throws->Void)throws->HistoricalEvidence {
        try snapshot {var visiting=Set<String>(),remaining=512,audit=[String:Row]();let result=try read(handle,visiting:&visiting,remaining:&remaining,audit:&audit,verifyMedia:verifyMedia);if let sourceID {guard Data(result.sourceID.utf8)==Data(sourceID.utf8) else {throw OSwindError.invalid("Historical citation owner differs")}};try finish(audit);return result}
    }
    private func read(_ handle:String,visiting:inout Set<String>,remaining:inout Int,audit:inout [String:Row],verifyMedia:(SyncVersionReference,[SyncMediaManifest],[SyncMediaRole:String])throws->Void)throws->HistoricalEvidence {
        try context();try Task.checkCancellation();guard remaining>0,visiting.count<32,visiting.insert(handle).inserted else {throw OSwindError.unavailable("Historical evidence graph exceeds its read bound")};remaining-=1;defer {visiting.remove(handle)}
        guard let value=try row(handle) else {throw OSwindError.unavailable("The exact original is unavailable; current text was not substituted")};try ownerExists(value.source)
        let record=try SyncPortableRecord.decode(value.body),ref=try record.reference
        guard case .source(let body)=record.body,try record.identity.key.digest==value.object,ref.content.sha256==value.sha else {throw OSwindError.database("Historical source identity differs")}
        let paths=try Self.paths(value.paths),parents=try JSONDecoder().decode([String].self,from:value.parents);guard try SyncProtocolLimits.encode(parents)==value.parents,parents.count==(body.recap?.sources.count ?? 0) else {throw OSwindError.database("Historical parent metadata differs")}
        let edges=try database.statement("SELECT parent FROM historical_evidence_dependencies WHERE child=?");defer {sqlite3_finalize(edges)};database.bind(edges,1,handle);var actual=Set<String>(),code=sqlite3_step(edges)
        while code==SQLITE_ROW {actual.insert(database.text(edges,0));code=sqlite3_step(edges)};guard code==SQLITE_DONE,actual==Set(parents) else {throw OSwindError.database("Historical erasure dependency graph differs")}
        var children=[HistoricalEvidence]()
        for (index,parent) in parents.enumerated() {let child=try read(parent,visiting:&visiting,remaining:&remaining,audit:&audit,verifyMedia:verifyMedia);guard try child.reference==body.recap!.sources[index].source else {throw OSwindError.database("Historical recap version differs")};children.append(child)}
        try verifyMedia(ref,body.media,paths);var index=0
        var memory=try body.projectedMemory(id:"original-"+handle,paths:paths) {expected in guard index<children.count,try children[index].reference==expected else {throw OSwindError.invalid("Historical parent order differs")};defer {index+=1};return(children[index].memory.id,children[index].memory.evidenceHash)}
        for i in children.indices {memory.recap!.sources[i].historicalHandle=children[i].handle}
        guard try fingerprint(memory,handle:handle,source:value.source,record:record)==value.projection else {throw OSwindError.database("Historical projection integrity differs")}
        if let old=audit[handle] {guard old==value else {throw OSwindError.invalid("Historical graph revisited a changed node")}};audit[handle]=value
        memory.originalEvidence = .init(handle:handle,contentSHA256:ref.content.sha256);return .init(record:record,sourceID:value.source,memory:memory)
    }
    /// Only an already admitted exact cache body can become archival data.
    func adopt(_ reference:SyncVersionReference,cache:SyncVersionStore,pathsFor:(SyncVersionReference,[SyncMediaManifest])throws->[SyncMediaRole:String],admit:(SyncPortableRecord)throws->Void,verifyMedia:(SyncVersionReference,[SyncMediaManifest],[SyncMediaRole:String])throws->Void)throws->HistoricalEvidence {
        guard cache.database.handle==database.handle else {throw OSwindError.invalid("Use the owning historical evidence connection")}
        return try SyncChangeCapture.transaction(database) {
            var visiting=Set<String>(),remaining=512,audit=[String:Row](),references=[SyncVersionReference]()
            let result=try adopt(reference,cache:cache,visiting:&visiting,remaining:&remaining,audit:&audit,references:&references,pathsFor:pathsFor,admit:admit,verifyMedia:verifyMedia)
            try finish(audit)
            for ref in references {guard try cache.record(ref,admit:{_ in}) != nil else {throw OSwindError.invalid("Historical source admission changed")}}
            return result
        }
    }
    private func adopt(_ reference:SyncVersionReference,cache:SyncVersionStore,visiting:inout Set<String>,remaining:inout Int,audit:inout [String:Row],references:inout [SyncVersionReference],pathsFor:(SyncVersionReference,[SyncMediaManifest])throws->[SyncMediaRole:String],admit:(SyncPortableRecord)throws->Void,verifyMedia:(SyncVersionReference,[SyncMediaManifest],[SyncMediaRole:String])throws->Void)throws->HistoricalEvidence {
        try context();try reference.validate(.source);let object=try reference.identity.key.digest,key=object+reference.content.sha256
        guard remaining>0,visiting.count<32,visiting.insert(key).inserted else {throw OSwindError.unavailable("Historical evidence graph exceeds its adoption bound")};remaining-=1;defer {visiting.remove(key)}
        guard let record=try cache.record(reference,admit:admit),case .source(let body)=record.body,let mapped=try cache.catalog.object(record.identity),!mapped.deleted,let primary=mapped.primary,primary.count==1,case .text(let bytes)=primary[0],let source=String(data:bytes,encoding:.utf8) else {throw OSwindError.unavailable("Admit the exact source and its local owner before retaining history")};references.append(reference)
        let existing=try database.statement("SELECT handle,source_id FROM historical_evidence WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(existing)};database.bind(existing,1,object);database.bind(existing,2,reference.content.sha256)
        let code=sqlite3_step(existing)
        if code==SQLITE_ROW {guard Data(database.text(existing,1).utf8)==bytes else {throw OSwindError.invalid("Historical version belongs to another source")};var reading=Set<String>();return try read(database.text(existing,0),visiting:&reading,remaining:&remaining,audit:&audit,verifyMedia:verifyMedia)}
        guard code==SQLITE_DONE else {throw database.error()};var children=[HistoricalEvidence]()
        for link in body.recap?.sources ?? [] {children.append(try adopt(link.source,cache:cache,visiting:&visiting,remaining:&remaining,audit:&audit,references:&references,pathsFor:pathsFor,admit:admit,verifyMedia:verifyMedia))}
        let paths=try pathsFor(reference,body.media);try verifyMedia(reference,body.media,paths)
        let handle=UUID().uuidString.lowercased();try insert(handle:handle,source:source,record:record,paths:paths,parents:children)
        var reading=Set<String>();return try read(handle,visiting:&reading,remaining:&remaining,audit:&audit,verifyMedia:verifyMedia)
    }
    /// Trusted restore validates the original archive row first, remaps verified
    /// media, and rebuilds this device-independent archival projection/checksum.
    func insert(handle:String,source:String,record:SyncPortableRecord,paths:[SyncMediaRole:String],parents:[HistoricalEvidence])throws {
        try context(writing:true);try SyncProtocolLimits.uuid(handle);try ownerExists(source);guard case .source(let body)=record.body else {throw OSwindError.invalid("Historical evidence must be a source")}
        let encodedPaths=try SyncProtocolLimits.encode(Dictionary(uniqueKeysWithValues:paths.map {($0.key.rawValue,$0.value)}));_=try Self.paths(encodedPaths);var index=0
        var memory=try body.projectedMemory(id:"original-"+handle,paths:paths) {ref in guard index<parents.count,try parents[index].reference==ref else {throw OSwindError.invalid("Historical restored parent differs")};defer {index+=1};return(parents[index].memory.id,parents[index].memory.evidenceHash)}
        guard index==parents.count else {throw OSwindError.invalid("Historical parent count differs")}
        for i in parents.indices {memory.recap!.sources[i].historicalHandle=parents[i].handle}
        let row=try database.statement("INSERT INTO historical_evidence VALUES(?,?,?,?,?,?,?,?)");defer {sqlite3_finalize(row)};database.bind(row,1,handle);database.bind(row,2,source);database.bind(row,3,try record.identity.key.digest);database.bind(row,4,try record.reference.content.sha256);bind(row,5,try record.encoded());bind(row,6,encodedPaths);bind(row,7,try SyncProtocolLimits.encode(parents.map(\.handle)));database.bind(row,8,try fingerprint(memory,handle:handle,source:source,record:record));try database.done(row)
        for parent in Set(parents.map(\.handle)) {let edge=try database.statement("INSERT INTO historical_evidence_dependencies VALUES(?,?)");defer {sqlite3_finalize(edge)};database.bind(edge,1,handle);database.bind(edge,2,parent);try database.done(edge)}
    }
}

extension HistoricalEvidenceStore {
    func wireReference(_ handle:String,sourceID:String,admit:(SyncPortableRecord)throws->Void,verify:(HistoricalEvidence)throws->Void)throws->SyncVersionReference {
        let native=sourceID=="original-"+handle
        let value=try read(handle,sourceID:native ? nil:sourceID,verifyMedia:{_,_,_ in});try admit(value.record);try verify(value)
        let after=try read(handle,sourceID:value.sourceID,verifyMedia:{_,_,_ in})
        guard try after.record.encoded()==value.record.encoded(),try SyncProtocolLimits.encode(after.memory)==SyncProtocolLimits.encode(value.memory) else {throw OSwindError.invalid("Historical egress changed during admission")};return try value.reference
    }
    func decorating(_ base:SyncPortableReferences,admit:@escaping (SyncPortableRecord)throws->Void,verify:@escaping (HistoricalEvidence)throws->Void)->SyncPortableReferences {
        var result=base
        result.historical={handle,owner in try wireReference(handle,sourceID:owner,admit:admit,verify:verify)}
        result.pin={owner in
            let row=try database.statement("SELECT handle FROM historical_evidence_pins WHERE memory_id=?");defer {sqlite3_finalize(row)};database.bind(row,1,owner);let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw database.error()};return try wireReference(database.text(row,0),sourceID:owner,admit:admit,verify:verify)
        }
        return result
    }
}
