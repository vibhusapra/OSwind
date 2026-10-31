import Foundation
import CSQLite
import CryptoKit

struct SyncOriginalEvidence:Sendable {
    let reference:SyncVersionReference
    let memory:Memory
    var handle:String {memory.originalEvidence!.handle}
}

/// Immutable native evidence projections are separate from canonical memories.
/// No duplicate timeline row, identity, capture intent or outgoing operation is
/// created. This internal layer requires current record and media admission;
/// incoming citation bindings/native service integration remain separate work.
struct SyncOriginalEvidenceStore {
    let cache:SyncVersionStore
    var database:RoutineDatabase {cache.database}
    static let defaultBudget:Int64=64*1024*1024,maximumBudget:Int64=8*1024*1024*1024
    private static let schemas:[String:String]=[
        "personal_sync_evidence_state":"CREATE TABLE personal_sync_evidence_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),origin TEXT NOT NULL,generation TEXT NOT NULL,group_id TEXT NOT NULL,epoch TEXT NOT NULL,used_bytes INTEGER NOT NULL CHECK(typeof(used_bytes)='integer' AND used_bytes>=0 AND used_bytes<=budget),budget INTEGER NOT NULL CHECK(typeof(budget)='integer' AND budget>0 AND budget<=8589934592))",
        "personal_sync_evidence":"CREATE TABLE personal_sync_evidence(handle TEXT PRIMARY KEY,object_digest TEXT NOT NULL,content_sha TEXT NOT NULL,paths BLOB NOT NULL CHECK(typeof(paths)='blob' AND length(paths)<=65536),parents BLOB NOT NULL CHECK(typeof(parents)='blob' AND length(parents)<=65536),projection_sha TEXT NOT NULL,UNIQUE(object_digest,content_sha),FOREIGN KEY(object_digest,content_sha) REFERENCES personal_sync_versions(object_digest,content_sha) ON DELETE CASCADE)",
        "sync_evidence_budget":"CREATE TRIGGER sync_evidence_budget BEFORE INSERT ON personal_sync_evidence BEGIN SELECT CASE WHEN (SELECT used_bytes+192+length(new.paths)+length(new.parents)>budget FROM personal_sync_evidence_state WHERE singleton=1) THEN RAISE(ABORT,'Sync original evidence metadata is full') END; END",
        "sync_evidence_added":"CREATE TRIGGER sync_evidence_added AFTER INSERT ON personal_sync_evidence BEGIN UPDATE personal_sync_evidence_state SET used_bytes=used_bytes+192+length(new.paths)+length(new.parents) WHERE singleton=1; END",
        "sync_evidence_removed":"CREATE TRIGGER sync_evidence_removed AFTER DELETE ON personal_sync_evidence BEGIN UPDATE personal_sync_evidence_state SET used_bytes=used_bytes-192-length(old.paths)-length(old.parents) WHERE singleton=1; END",
        "sync_evidence_immutable":"CREATE TRIGGER sync_evidence_immutable BEFORE UPDATE ON personal_sync_evidence BEGIN SELECT RAISE(ABORT,'Sync original evidence projections are immutable'); END"
    ]
    static func install(cache:SyncVersionStore,budget:Int64=defaultBudget)throws->Self {
        guard (1...maximumBudget).contains(budget) else {throw OSwindError.invalid("Invalid original evidence budget")}
        let value=Self(cache:cache),db=cache.database
        return try SyncChangeCapture.transaction(db) {
            let row=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('personal_sync_evidence','personal_sync_evidence_state')");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};let count=sqlite3_column_int(row,0)
            guard count==0 || count==2 else {throw OSwindError.database("Original evidence schema is incomplete")}
            if count==0 {
                for name in ["personal_sync_evidence_state","personal_sync_evidence"] {try db.execute(schemas[name]!)}
                let insert=try db.statement("INSERT INTO personal_sync_evidence_state VALUES(1,?,?,?,?,0,?)");defer {sqlite3_finalize(insert)}
                db.bind(insert,1,cache.catalog.scope.origin);db.bind(insert,2,cache.catalog.scope.generation);db.bind(insert,3,cache.journal.group);db.bind(insert,4,cache.journal.epoch);sqlite3_bind_int64(insert,5,budget);try db.done(insert)
                for name in schemas.keys.sorted() where name.hasPrefix("sync_evidence_") {try db.execute(schemas[name]!)}
            }
            try value.context()
            let sum=try db.statement("SELECT (SELECT COALESCE(SUM(192+length(paths)+length(parents)),0) FROM personal_sync_evidence)=used_bytes FROM personal_sync_evidence_state WHERE singleton=1");defer {sqlite3_finalize(sum)}
            guard sqlite3_step(sum)==SQLITE_ROW,sqlite3_column_int(sum,0)==1 else {throw OSwindError.database("Original evidence accounting differs")}
            return value
        }
    }
    private func context()throws {
        for (name,sql) in Self.schemas {
            let s=try database.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(s)};database.bind(s,1,name)
            guard sqlite3_step(s)==SQLITE_ROW,database.text(s,0)==sql else {throw OSwindError.database("Original evidence protection schema differs")}
        }
        guard try SyncChangeCapture.scope(database)==cache.catalog.scope else {throw OSwindError.invalid("Original evidence capture generation changed")}
        _=try cache.journal.cursor(for:cache.journal.replica)
        let s=try database.statement("SELECT origin,generation,group_id,epoch,(SELECT enabled FROM personal_sync_capture),(SELECT synchronous FROM pragma_synchronous),(SELECT foreign_keys FROM pragma_foreign_keys),(SELECT recursive_triggers FROM pragma_recursive_triggers) FROM personal_sync_evidence_state WHERE singleton=1");defer {sqlite3_finalize(s)}
        guard sqlite3_step(s)==SQLITE_ROW,database.text(s,0)==cache.catalog.scope.origin,database.text(s,1)==cache.catalog.scope.generation,database.text(s,2)==cache.journal.group,database.text(s,3)==cache.journal.epoch,sqlite3_column_int(s,4)==1,sqlite3_column_int(s,5)>=2,sqlite3_column_int(s,6)==1,sqlite3_column_int(s,7)==1 else {throw OSwindError.invalid("Original evidence scope or durability differs")}
    }
    private func blob(_ row:OpaquePointer,_ column:Int32)throws->Data {
        let n=Int(sqlite3_column_bytes(row,column));guard sqlite3_column_type(row,column)==SQLITE_BLOB,n>0,n<=65536,let p=sqlite3_column_blob(row,column) else {throw OSwindError.database("Invalid original evidence metadata")};return Data(bytes:p,count:n)
    }
    private func bind(_ row:OpaquePointer,_ column:Int32,_ data:Data) {data.withUnsafeBytes {_ = sqlite3_bind_blob(row,column,$0.baseAddress,Int32(data.count),database.transient)}}
    private struct Row:Equatable {let object:String,sha:String,paths:Data,parents:Data,projection:String}
    private struct Audited {let value:Row,reference:SyncVersionReference}
    private func projectionDigest(_ memory:Memory,handle:String,reference:SyncVersionReference)throws->String {
        let binding=[handle,cache.catalog.scope.origin,cache.catalog.scope.generation,cache.journal.group,cache.journal.epoch,try reference.identity.key.digest,reference.content.sha256,String(reference.content.bytes)]
        var hash=SHA256();hash.update(data:Data("OSwind.sync.original-evidence.v1\0".utf8));hash.update(data:try SyncProtocolLimits.encode(binding));hash.update(data:Data([0]));hash.update(data:try SyncProtocolLimits.encode(memory));return hash.finalize().map {String(format:"%02x",$0)}.joined()
    }
    private func finish(_ audit:[String:Audited])throws {
        try context()
        // All policy/media callbacks have finished. Revalidate every visited
        // node without invoking another callback that could invalidate an
        // earlier node. This also covers grandparents and repeated DAG nodes.
        for (handle,original) in audit {
            guard try row(handle)==original.value,try cache.record(original.reference,admit:{_ in}) != nil else {throw OSwindError.invalid("Original evidence graph changed during admission")}
        }
        try context()
    }
    private func row(_ handle:String)throws->Row? {
        try SyncProtocolLimits.uuid(handle)
        let s=try database.statement("SELECT object_digest,content_sha,paths,parents,projection_sha FROM personal_sync_evidence WHERE handle=?");defer {sqlite3_finalize(s)};database.bind(s,1,handle)
        let code=sqlite3_step(s);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw database.error()}
        let value=try Row(object:database.text(s,0),sha:database.text(s,1),paths:blob(s,2),parents:blob(s,3),projection:database.text(s,4))
        try SyncProtocolLimits.digest(value.object);try SyncProtocolLimits.digest(value.sha);try SyncProtocolLimits.digest(value.projection);return value
    }
    private func source(_ value:Row,admit:(SyncPortableRecord)throws->Void)throws->SyncPortableRecord {
        let s=try database.statement("SELECT body FROM personal_sync_versions WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(s)};database.bind(s,1,value.object);database.bind(s,2,value.sha)
        guard sqlite3_step(s)==SQLITE_ROW,let p=sqlite3_column_blob(s,0),sqlite3_column_bytes(s,0)>0,Int(sqlite3_column_bytes(s,0))<=Int(SyncProtocolLimits.contentBytes) else {throw OSwindError.unavailable("Original evidence exact body is unavailable")}
        let original=try SyncPortableRecord.decode(Data(bytes:p,count:Int(sqlite3_column_bytes(s,0)))),ref=try original.reference
        guard original.identity.table == .source,try original.identity.key.digest==value.object,ref.content.sha256==value.sha,let checked=try cache.record(ref,admit:admit) else {throw OSwindError.database("Original evidence body identity differs")};return checked
    }
    private func paths(_ data:Data)throws->[SyncMediaRole:String] {
        let decoded=try JSONDecoder().decode([String:String].self,from:data)
        guard decoded.count<=3,try SyncProtocolLimits.encode(decoded)==data else {throw OSwindError.database("Original evidence media metadata differs")}
        var result=[SyncMediaRole:String]()
        for (key,path) in decoded {
            guard let role=SyncMediaRole(rawValue:key),path.utf8.count<=4096,!path.utf8.contains(0),!path.hasPrefix("/"),!path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0=="." || $0==".."}),path.hasPrefix(role == .image ? "images/":(role == .audio ? "audio/":"video/")) else {throw OSwindError.invalid("Original evidence media path is outside its role")}
            result[role]=path
        };return result
    }
    /// Callers retain the appropriate media lease/pins through actual playback.
    /// admitMedia must verify current file ownership/content and policy; paths
    /// alone are not authenticated bytes or authority to access an asset.
    func read(_ handle:String,admit:(SyncPortableRecord)throws->Void,admitMedia:(SyncVersionReference,[SyncMediaManifest],[SyncMediaRole:String])throws->Void)throws->SyncOriginalEvidence {
        try SyncChangeCapture.transaction(database) {
            var visiting=Set<String>(),remaining=512,audit=[String:Audited]()
            let result=try read(handle,visiting:&visiting,remaining:&remaining,audit:&audit,admit:admit,admitMedia:admitMedia)
            try finish(audit);return result
        }
    }
    private func read(_ handle:String,visiting:inout Set<String>,remaining:inout Int,audit:inout [String:Audited],admit:(SyncPortableRecord)throws->Void,admitMedia:(SyncVersionReference,[SyncMediaManifest],[SyncMediaRole:String])throws->Void)throws->SyncOriginalEvidence {
        try context();try Task.checkCancellation()
        guard remaining>0,visiting.count<32,visiting.insert(handle).inserted else {throw OSwindError.unavailable("Original evidence graph is cyclic or exceeds its read bound")};remaining-=1;defer {visiting.remove(handle)}
        guard let value=try row(handle) else {throw OSwindError.unavailable("Original evidence projection no longer exists")}
        let original=try source(value,admit:admit),ref=try original.reference
        guard case .source(let body)=original.body else {throw OSwindError.invalid("Original evidence is not a source")}
        let localPaths=try paths(value.paths),parents=try JSONDecoder().decode([String].self,from:value.parents)
        guard try SyncProtocolLimits.encode(parents)==value.parents,parents.count==(body.recap?.sources.count ?? 0) else {throw OSwindError.database("Original evidence recap bindings differ")}
        var evidence=[SyncOriginalEvidence]()
        for (index,parent) in parents.enumerated() {
            let child=try read(parent,visiting:&visiting,remaining:&remaining,audit:&audit,admit:admit,admitMedia:admitMedia)
            guard child.reference==body.recap!.sources[index].source else {throw OSwindError.database("Original evidence recap version differs")};evidence.append(child)
        }
        try admitMedia(ref,body.media,localPaths)
        var offset=0
        var memory=try body.projectedMemory(id:"original-"+handle,paths:localPaths) {expected in
            guard offset<evidence.count,evidence[offset].reference==expected else {throw OSwindError.invalid("Original evidence dependency order differs")}
            defer {offset+=1};return(evidence[offset].memory.id,evidence[offset].memory.evidenceHash)
        }
        guard try projectionDigest(memory,handle:handle,reference:ref)==value.projection else {throw OSwindError.database("Original evidence projection integrity differs")}
        try context();guard let after=try row(handle),after.object==value.object,after.sha==value.sha,after.paths==value.paths,after.parents==value.parents,after.projection==value.projection,try cache.record(ref,admit:admit) != nil else {throw OSwindError.invalid("Original evidence changed during admission")}
        // A later policy callback may erase a recursively read dependency too.
        for child in evidence {guard try row(child.handle) != nil,try cache.record(child.reference,admit:admit) != nil else {throw OSwindError.invalid("Original evidence dependency disappeared")}}
        if let previous=audit[handle] {guard previous.value==value,previous.reference==ref else {throw OSwindError.invalid("Original evidence revisited a changed node")}}
        audit[handle] = .init(value:value,reference:ref)
        memory.originalEvidence = .init(handle:handle,contentSHA256:ref.content.sha256)
        return .init(reference:ref,memory:memory)
    }
    /// Prepare only already-admitted exact cached bodies. All recursive metadata
    /// and its accounting commit together; no canonical row or journal mutation.
    func prepare(_ reference:SyncVersionReference,pathsFor:(SyncVersionReference,[SyncMediaManifest])throws->[SyncMediaRole:String],admit:(SyncPortableRecord)throws->Void,admitMedia:(SyncVersionReference,[SyncMediaManifest],[SyncMediaRole:String])throws->Void)throws->SyncOriginalEvidence {
        try SyncChangeCapture.transaction(database) {
            var visiting=Set<String>(),remaining=512,audit=[String:Audited]()
            let result=try prepare(reference,visiting:&visiting,remaining:&remaining,audit:&audit,pathsFor:pathsFor,admit:admit,admitMedia:admitMedia)
            try finish(audit);return result
        }
    }
    private func prepare(_ reference:SyncVersionReference,visiting:inout Set<String>,remaining:inout Int,audit:inout [String:Audited],pathsFor:(SyncVersionReference,[SyncMediaManifest])throws->[SyncMediaRole:String],admit:(SyncPortableRecord)throws->Void,admitMedia:(SyncVersionReference,[SyncMediaManifest],[SyncMediaRole:String])throws->Void)throws->SyncOriginalEvidence {
        try context();try reference.validate(.source);try Task.checkCancellation()
        let key=try reference.identity.key.digest+reference.content.sha256
        guard remaining>0,visiting.count<32,visiting.insert(key).inserted else {throw OSwindError.unavailable("Original evidence graph is cyclic or exceeds its preparation bound")};remaining-=1;defer {visiting.remove(key)}
        let existing=try database.statement("SELECT handle FROM personal_sync_evidence WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(existing)};database.bind(existing,1,try reference.identity.key.digest);database.bind(existing,2,reference.content.sha256)
        let code=sqlite3_step(existing)
        if code==SQLITE_ROW {var reading=Set<String>();return try read(database.text(existing,0),visiting:&reading,remaining:&remaining,audit:&audit,admit:admit,admitMedia:admitMedia)}
        guard code==SQLITE_DONE,let original=try cache.record(reference,admit:admit),case .source(let body)=original.body else {throw OSwindError.unavailable("Prepare the admitted exact source body before its original evidence projection")}
        var parents=[SyncOriginalEvidence]()
        for link in body.recap?.sources ?? [] {parents.append(try prepare(link.source,visiting:&visiting,remaining:&remaining,audit:&audit,pathsFor:pathsFor,admit:admit,admitMedia:admitMedia))}
        let handle=UUID().uuidString.lowercased(),localPaths=try pathsFor(reference,body.media),encodedPaths=try SyncProtocolLimits.encode(Dictionary(uniqueKeysWithValues:localPaths.map {($0.key.rawValue,$0.value)}));_=try paths(encodedPaths)
        try admitMedia(reference,body.media,localPaths);var offset=0
        let memory=try body.projectedMemory(id:"original-"+handle,paths:localPaths) {expected in
            guard offset<parents.count,parents[offset].reference==expected else {throw OSwindError.invalid("Original evidence dependency order differs")};defer {offset+=1};return(parents[offset].memory.id,parents[offset].memory.evidenceHash)
        }
        let encodedParents=try SyncProtocolLimits.encode(parents.map(\.handle)),put=try database.statement("INSERT INTO personal_sync_evidence VALUES(?,?,?,?,?,?)");defer {sqlite3_finalize(put)}
        database.bind(put,1,handle);database.bind(put,2,try reference.identity.key.digest);database.bind(put,3,reference.content.sha256);bind(put,4,encodedPaths);bind(put,5,encodedParents);database.bind(put,6,try projectionDigest(memory,handle:handle,reference:reference));try database.done(put)
        var reading=Set<String>();return try read(handle,visiting:&reading,remaining:&remaining,audit:&audit,admit:admit,admitMedia:admitMedia)
    }
}
