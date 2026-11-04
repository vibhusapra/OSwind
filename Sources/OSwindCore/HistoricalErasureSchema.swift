import Foundation
import CSQLite

/// SQLite-maintained expression indexes over immutable originals. No mutable
/// scope cache or registry of ordinary memories is introduced. Domain-only
/// scans read the covering URL index rather than decoding source bodies.
enum HistoricalErasureSchema {
    static func field(_ name:String)->String {"json_extract(CAST(body AS TEXT),'$.body.source._0.\(name)')"}
    static let timestamp="(\(field("timestamp"))+978307200)"
    static let end="(\(field("endTimestamp"))+978307200)"
    static let url=field("url")
    static let schemas:[String:String] = {
        var result=[String:String]()
        result["historical_scope_revoked_versions"]="CREATE TABLE historical_scope_revoked_versions(object_digest TEXT NOT NULL,content_sha TEXT NOT NULL,PRIMARY KEY(object_digest,content_sha)) WITHOUT ROWID"
        for (name,expression) in [("start",timestamp),("end",end),("app",field("app")),("bundle",field("bundleID")),("kind",field("kind")),("url",url)] {
            let key="historical_scope_"+name
            result[key]="CREATE INDEX \(key) ON historical_evidence(\(expression),handle,source_id)"
        }
        for table in SyncChangeCapture.tables.map(\.name)+["historical_evidence"] {for operation in ["insert","update","delete"] {
            let name="historical_scope_writer_"+table+"_"+operation
            result[name]="CREATE TRIGGER \(name) BEFORE \(operation.uppercased()) ON \(table) BEGIN SELECT oswind_historical_scope_writer_v1(); END"
        }}
        return result
    }()
    static func register(_ db:RoutineDatabase)throws {
        guard sqlite3_create_function_v2(db.handle,"oswind_historical_scope_writer_v1",0,SQLITE_UTF8|SQLITE_INNOCUOUS|SQLITE_DETERMINISTIC,nil,{context,_,_ in sqlite3_result_int(context,1)},nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
    static func validate(_ db:RoutineDatabase)throws {
        let row=try db.statement("SELECT name,sql FROM sqlite_master WHERE name GLOB 'historical_scope_*'");defer {sqlite3_finalize(row)};var found=Set<String>(),code=sqlite3_step(row)
        while code==SQLITE_ROW {let name=db.text(row,0);guard schemas[name]==db.text(row,1),found.insert(name).inserted else {throw OSwindError.database("Historical erasure scope protection differs")};code=sqlite3_step(row)}
        guard code==SQLITE_DONE,found==Set(schemas.keys) else {throw OSwindError.database("Historical erasure scope protection differs")}
    }
    static func install(_ db:RoutineDatabase,sourceVersion:Int32,repairMissingPins:Bool)throws {
        if sourceVersion<27 {
            let rows=try db.statement("SELECT object_digest,content_sha,body FROM historical_evidence");defer {sqlite3_finalize(rows)};var code=sqlite3_step(rows)
            while code==SQLITE_ROW {
                try Task.checkCancellation()
                _=try autoreleasepool {try source(db,rows)};code=sqlite3_step(rows)
            };guard code==SQLITE_DONE else {throw db.error()}
        }
        for (name,sql) in schemas.sorted(by:{$0.key<$1.key}) {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name);let code=sqlite3_step(row),old=code==SQLITE_ROW ? db.text(row,0):nil;sqlite3_finalize(row)
            guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
            if let old {guard old==sql else {throw OSwindError.database("Historical erasure scope protection differs")}}
            else {
                guard sourceVersion<27 || (repairMissingPins && name.hasPrefix("historical_scope_writer_text_observation_pins_")) else {throw OSwindError.database("Historical erasure scope protection is missing")}
                try db.execute(sql)
            }
        }
        try validate(db)
    }
    private static func source(_ db:RoutineDatabase,_ row:OpaquePointer)throws->SyncSourceBody {
        let size=Int(sqlite3_column_bytes(row,2));guard sqlite3_column_type(row,2)==SQLITE_BLOB,size>0,size<=SyncProtocolLimits.contentBytes,let p=sqlite3_column_blob(row,2) else {throw OSwindError.database("Invalid historical source during scope migration")}
        let packet=try SyncPortableRecord.decode(Data(bytes:p,count:size))
        guard case .source(let body)=packet.body,try packet.identity.key.digest==db.text(row,0),try packet.reference.content.sha256==db.text(row,1) else {throw OSwindError.database("Historical source integrity differs during scope migration")}
        return body
    }
    /// A deletion preview needs authenticated recorded metadata, not playable
    /// media or a resolvable parent DAG. Missing parents must not block erasure.
    static func sample(_ db:RoutineDatabase,handle:String)throws->HistoryErasureSample {
        try SyncProtocolLimits.uuid(handle)
        let row=try db.statement("SELECT object_digest,content_sha,body FROM historical_evidence WHERE handle=?");defer {sqlite3_finalize(row)};db.bind(row,1,handle)
        guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("Original version changed during preview")}
        let body=try source(db,row)
        return .init(id:"original-"+handle,app:body.app,title:String(body.title.prefix(300)),timestamp:body.timestamp)
    }
    /// Standalone low-level sync fixtures may predate a native library schema.
    /// A current library must contain its compiled revocation table.
    static func isRevoked(_ db:RoutineDatabase,_ reference:SyncVersionReference)throws->Bool {
        guard try db.eraseCount("PRAGMA user_version")>=27 else {return false}
        let row=try db.statement("SELECT 1 FROM historical_scope_revoked_versions WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(row)}
        db.bind(row,1,try reference.identity.key.digest);db.bind(row,2,reference.content.sha256)
        let code=sqlite3_step(row);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()};return code==SQLITE_ROW
    }
    static func hasRevokedVersion(_ db:RoutineDatabase,_ record:SyncPortableRecord)throws->Bool {
        if try isRevoked(db,record.reference) {return true}
        for dependency in record.dependencies {
            if let content=dependency.content,try isRevoked(db,.init(identity:dependency.identity,content:content)) {return true}
        }
        return false
    }
    /// Revoke the exact archived versions and any cached versions that depend
    /// on them, before deleting archival roots in the same transaction. The
    /// native current owner and unrelated versions keep their lifetimes.
    static func revokeSelected(_ db:RoutineDatabase,additionalObject:String?=nil)throws {
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS erasure_version_ids(object_digest TEXT NOT NULL,content_sha TEXT NOT NULL,PRIMARY KEY(object_digest,content_sha)) WITHOUT ROWID; DELETE FROM temp.erasure_version_ids; INSERT INTO temp.erasure_version_ids SELECT h.object_digest,h.content_sha FROM historical_evidence h JOIN temp.erasure_historical_ids e ON e.handle=h.handle")
        defer {try? db.execute("DELETE FROM temp.erasure_version_ids")}
        let hasCache=try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name='personal_sync_versions'")>0
        if let additionalObject {
            try SyncProtocolLimits.digest(additionalObject)
            try db.execute("INSERT OR IGNORE INTO temp.erasure_version_ids SELECT object_digest,content_sha FROM temp.erasure_extra_version_ids")
            if hasCache {
                try SyncVersionStore.validateForErasure(db)
                let root=try db.statement("INSERT OR IGNORE INTO temp.erasure_version_ids SELECT object_digest,content_sha FROM personal_sync_versions WHERE object_digest=?");defer {sqlite3_finalize(root)};db.bind(root,1,additionalObject);try db.done(root)
                let revoke=try db.statement("INSERT OR IGNORE INTO personal_sync_version_revoked VALUES(?)");defer {sqlite3_finalize(revoke)};db.bind(revoke,1,additionalObject);try db.done(revoke)
            }
        }
        guard try db.eraseCount("SELECT count(*) FROM temp.erasure_version_ids")>0 else {return}
        if hasCache {
            try SyncVersionStore.validateForErasure(db)
            var reverse=[String:[String]](),queue=[String]()
            let roots=try db.statement("SELECT object_digest||content_sha FROM temp.erasure_version_ids");defer {sqlite3_finalize(roots)};var code=sqlite3_step(roots)
            while code==SQLITE_ROW {queue.append(db.text(roots,0));code=sqlite3_step(roots)};guard code==SQLITE_DONE else {throw db.error()}
            let rows=try db.statement("SELECT object_digest,content_sha,body FROM personal_sync_versions");defer {sqlite3_finalize(rows)};code=sqlite3_step(rows)
            while code==SQLITE_ROW {
                try Task.checkCancellation()
                try autoreleasepool {
                    let object=db.text(rows,0),sha=db.text(rows,1),size=Int(sqlite3_column_bytes(rows,2))
                    guard sqlite3_column_type(rows,2)==SQLITE_BLOB,size>0,size<=SyncProtocolLimits.contentBytes,let bytes=sqlite3_column_blob(rows,2) else {throw OSwindError.database("Invalid sync cache during original erasure")}
                    let record=try SyncPortableRecord.decode(Data(bytes:bytes,count:size))
                    guard try record.identity.key.digest==object,try record.reference.content.sha256==sha else {throw OSwindError.database("Sync cache integrity differs during original erasure")}
                    for dependency in record.dependencies {
                        if let content=dependency.content {reverse[try dependency.identity.key.digest+content.sha256,default:[]].append(object+sha)}
                    }
                };code=sqlite3_step(rows)
            };guard code==SQLITE_DONE else {throw db.error()}
            var seen=Set(queue),cursor=0
            let insert=try db.statement("INSERT OR IGNORE INTO temp.erasure_version_ids VALUES(?,?)");defer {sqlite3_finalize(insert)}
            while cursor<queue.count {
                try Task.checkCancellation();let key=queue[cursor];cursor+=1
                for dependent in reverse[key] ?? [] where seen.insert(dependent).inserted {
                    queue.append(dependent);sqlite3_reset(insert);sqlite3_clear_bindings(insert);db.bind(insert,1,String(dependent.prefix(64)));db.bind(insert,2,String(dependent.suffix(64)));try db.done(insert)
                }
            }
        }
        try db.execute("INSERT OR IGNORE INTO historical_scope_revoked_versions SELECT object_digest,content_sha FROM temp.erasure_version_ids")
        if hasCache {
            // Cache-only original projections may own local media even when no
            // canonical or historical row remains. Stage before FK removal.
            if try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name='personal_sync_evidence'")>0 {
                try SyncOriginalEvidenceStore.validateForErasure(db)
                try db.execute("INSERT OR IGNORE INTO erasure_assets SELECT j.value FROM personal_sync_evidence e,json_each(CAST(e.paths AS TEXT)) j WHERE (e.object_digest,e.content_sha) IN (SELECT object_digest,content_sha FROM temp.erasure_version_ids)")
            }
            try db.execute("DELETE FROM personal_sync_versions WHERE (object_digest,content_sha) IN (SELECT object_digest,content_sha FROM temp.erasure_version_ids)")
            try SyncRecordingReconciliation.markErasure(db)
        }
    }
    struct Query {let sql:String;let bind:(OpaquePointer)throws->Void}
    static func query(_ scope:HistoryErasureScope,db:RoutineDatabase)->Query {
        enum Value {case date(Double),text(String)}
        var clauses=[String](),parameters=[Value]()
        // Split the timestamp/end overlap into independent indexed ranges.
        // SQLite otherwise chooses a body-table scan for the three-way OR.
        for range in scope.start==nil ? ["none"]:["start","end"] {
            var predicates=[String](),hint:String?
            if let start=scope.start {
                if range=="start" {predicates.append("\(timestamp)>=?");parameters.append(.date(start.timeIntervalSince1970));hint="start"}
                else {predicates.append("\(end)>=? AND (\(end)>? OR json_type(CAST(body AS TEXT),'$.body.source._0.textObservation')='object')");parameters += [.date(start.timeIntervalSince1970),.date(start.timeIntervalSince1970)];hint="end"}
            }
            if let end=scope.end {predicates.append("\(timestamp)<?");parameters.append(.date(end.timeIntervalSince1970));if hint==nil {hint="start"}}
            if let app=scope.app {predicates.append("\(field("app"))=?");parameters.append(.text(app));hint="app"}
            if let bundle=scope.bundleID {predicates.append("\(field("bundleID"))=?");parameters.append(.text(bundle));if scope.app==nil {hint="bundle"}}
            if let kind=scope.kind {predicates.append("\(field("kind"))=?");parameters.append(.text(kind.rawValue));if scope.app==nil && scope.bundleID==nil {hint="kind"}}
            if hint==nil && scope.domain != nil {hint="url"}
            clauses.append("SELECT handle,source_id"+(scope.domain==nil ? "":",\(url)")+" FROM historical_evidence"+(hint.map {" INDEXED BY historical_scope_"+$0} ?? "")+(predicates.isEmpty ? "":" WHERE "+predicates.joined(separator:" AND ")))
        }
        return Query(sql:clauses.joined(separator:" UNION "),bind:{row in
            for (index,value) in parameters.enumerated() {switch value {case .date(let date):sqlite3_bind_double(row,Int32(index+1),date);case .text(let text):db.bind(row,Int32(index+1),text)}}
        })
    }
}
