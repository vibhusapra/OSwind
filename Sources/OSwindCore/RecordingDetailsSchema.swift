import Foundation
import CSQLite

/// Rebuildable bounded metadata over canonical user-authored name records.
/// Per-row nonces distinguish identical edits/deletion/recreation. Built-in SQL
/// triggers cover compatible writers; this is never a new canonical table.
enum RecordingDetailsSchema {
    static let key="recorded_meeting_details_version",currentVersion="1",pendingVersion="pending:1"
    private static func rows(_ alias:String,_ tail:String)->String {
        let payload="CAST(\(alias).payload AS TEXT)",scope="json_extract(\(payload),'$.recordingDetails.scope')"
        return """
        SELECT \(alias).id,json_extract(\(scope),'$.selector'),json_extract(\(scope),'$.id'),json_extract(\(scope),'$.revision'),
            \(alias).title,\(alias).app,COALESCE(json_extract(\(payload),'$.bundleID'),''),json_extract(\(payload),'$.recordingDetails'),lower(hex(randomblob(16))) \(tail)
        """
    }
    static let triggers:[String:String]=[
        "recorded_details_source_insert":"""
        CREATE TRIGGER recorded_details_source_insert AFTER INSERT ON memories WHEN new.kind='recording-metadata' BEGIN
            INSERT INTO recorded_meeting_details \(rows("new",""));
        END
        """,
        "recorded_details_source_delete":"""
        CREATE TRIGGER recorded_details_source_delete AFTER DELETE ON memories BEGIN
            DELETE FROM recorded_meeting_details WHERE memory_id=old.id;
        END
        """,
        "recorded_details_source_update":"""
        CREATE TRIGGER recorded_details_source_update AFTER UPDATE OF id,payload,timestamp,app,title,url,kind ON memories
        WHEN (old.kind='recording-metadata' OR new.kind='recording-metadata') AND (old.id IS NOT new.id OR old.payload IS NOT new.payload OR old.timestamp IS NOT new.timestamp OR old.app IS NOT new.app OR old.title IS NOT new.title OR old.url IS NOT new.url OR old.kind IS NOT new.kind)
        BEGIN
            DELETE FROM recorded_meeting_details WHERE memory_id=old.id;
            INSERT INTO recorded_meeting_details \(rows("new","WHERE new.kind='recording-metadata'"));
        END
        """
    ]
    static func install(_ db:RoutineDatabase)throws {
        let row=try db.statement("SELECT 1 FROM sqlite_master WHERE type='table' AND name='recorded_meeting_details'")
        let existed=sqlite3_step(row)==SQLITE_ROW;sqlite3_finalize(row)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS recorded_meeting_details(
            memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
            selector TEXT NOT NULL CHECK(selector IN ('session','source','unavailable')),
            scope_id TEXT,evidence_revision TEXT,name TEXT NOT NULL,app TEXT NOT NULL,bundle_id TEXT NOT NULL,details TEXT NOT NULL,
            revision TEXT NOT NULL CHECK(length(revision)=32),
            CHECK((selector='unavailable' AND scope_id IS NULL AND evidence_revision IS NULL) OR
                  (selector='session' AND scope_id IS NOT NULL AND length(CAST(scope_id AS BLOB))>0 AND evidence_revision IS NULL) OR
                  (selector='source' AND scope_id IS NOT NULL AND length(CAST(scope_id AS BLOB))>0 AND evidence_revision IS NOT NULL))
        );
        CREATE INDEX IF NOT EXISTS recorded_meeting_details_scope ON recorded_meeting_details(selector,scope_id COLLATE BINARY,evidence_revision,memory_id);
        """)
        let marker=try db.statement("SELECT value FROM store_metadata WHERE key='\(key)'")
        let version=sqlite3_step(marker)==SQLITE_ROW ? db.text(marker,0):nil;sqlite3_finalize(marker)
        var ready=existed && (version==currentVersion || version==pendingVersion)
        for (name,expected) in triggers {
            let s=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(s,1,name)
            if sqlite3_step(s) != SQLITE_ROW || db.text(s,0).trimmingCharacters(in:.whitespacesAndNewlines) != expected {ready=false};sqlite3_finalize(s)
        }
        if !ready {
            try db.execute("DELETE FROM recorded_meeting_details")
            for (name,sql) in triggers {try db.execute("DROP TRIGGER IF EXISTS \(name)");try db.execute(sql)}
            let any=try db.statement("SELECT 1 FROM memories WHERE kind='recording-metadata' LIMIT 1")
            let code=sqlite3_step(any);sqlite3_finalize(any);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
            let status=code==SQLITE_ROW ? pendingVersion:currentVersion
            let state=try db.statement("INSERT INTO store_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            defer {sqlite3_finalize(state)};db.bind(state,1,key);db.bind(state,2,status);try db.done(state)
            // Repair must invalidate already prepared values even for an empty
            // cache. Initial installation has no nonce yet; its owner adds one.
            try db.execute("UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='\(RecordedMeetingRevisionSchema.key)'")
        }
    }
    static func prepare(_ db:RoutineDatabase,managesProgressHandler:Bool=true)throws {
        let marker=try db.statement("SELECT value FROM store_metadata WHERE key='\(key)'")
        let value=sqlite3_step(marker)==SQLITE_ROW ? db.text(marker,0):nil;sqlite3_finalize(marker)
        if value==currentVersion {return}
        guard value==pendingVersion else {throw OSwindError.unavailable("Reopen the library to prepare its recording names")}
        if sqlite3_get_autocommit(db.handle)==0 {try populate(db,managesProgressHandler:managesProgressHandler)}else {try db.transaction {try populate(db,managesProgressHandler:managesProgressHandler)}}
    }
    private static func populate(_ db:RoutineDatabase,managesProgressHandler:Bool)throws {
        try Task.checkCancellation()
        if managesProgressHandler {sqlite3_progress_handler(db.handle,1000,{_ in Task.isCancelled ? 1:0},nil)}
        defer {if managesProgressHandler {sqlite3_progress_handler(db.handle,0,nil,nil)}}
        try db.execute("DELETE FROM recorded_meeting_details")
        try db.execute("INSERT INTO recorded_meeting_details \(rows("m","FROM memories m WHERE m.kind='recording-metadata'"))")
        try db.execute("UPDATE store_metadata SET value='\(currentVersion)' WHERE key='\(key)'");try Task.checkCancellation()
    }
    static func revision(_ db:RoutineDatabase,id:String)throws->String {
        let row=try db.statement("SELECT revision FROM recorded_meeting_details WHERE memory_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id)
        guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("The saved recording name changed. Refresh before editing.")}
        return db.text(row,0)
    }
    /// Erasure must remove stale private labels even if a rebuildable row was
    /// corrupted to point at a different canonical owner. Healthy projections
    /// incur no writes; repair reads only bounded name records, not transcripts.
    static func reconcileAfterErasure(_ db:RoutineDatabase)throws {
        let sql="""
        SELECT EXISTS(
            SELECT 1 FROM recorded_meeting_details d LEFT JOIN memories m ON m.id=d.memory_id
            WHERE m.kind IS NOT 'recording-metadata' OR d.name IS NOT m.title OR d.app IS NOT m.app
                OR d.bundle_id IS NOT COALESCE(json_extract(CAST(m.payload AS TEXT),'$.bundleID'),'')
                OR d.selector IS NOT json_extract(CAST(m.payload AS TEXT),'$.recordingDetails.scope.selector')
                OR d.scope_id IS NOT json_extract(CAST(m.payload AS TEXT),'$.recordingDetails.scope.id')
                OR d.evidence_revision IS NOT json_extract(CAST(m.payload AS TEXT),'$.recordingDetails.scope.revision')
                OR d.details IS NOT json_extract(CAST(m.payload AS TEXT),'$.recordingDetails')
            UNION ALL SELECT 1 FROM memories m LEFT JOIN recorded_meeting_details d ON d.memory_id=m.id
                WHERE m.kind='recording-metadata' AND d.memory_id IS NULL
        )
        """
        if try db.eraseCount(sql)==1 {
            try db.execute("UPDATE store_metadata SET value='\(pendingVersion)' WHERE key='\(key)'")
            try prepare(db,managesProgressHandler:false)
        }
    }
}
