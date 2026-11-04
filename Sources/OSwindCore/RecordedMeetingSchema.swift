import Foundation
import CSQLite

/// Rebuildable metadata over existing audio sources. Audio recording IDs remain
/// canonical source fields; this index stores no transcript or independent copy.
/// SQL triggers also cover older source writers and erasure/restore adapters.
enum RecordedMeetingSchema {
    static let currentVersion="2",pendingVersion="pending:2"
    private static func rows(_ alias:String,_ tail:String)->String {
        let payload="CAST(\(alias).payload AS TEXT)",session="json_extract(\(payload),'$.audioSessionID')"
        // Source admission bounds Swift graphemes, not SQLite codepoints.
        // BLOB length tests emptiness without truncating at an embedded NUL.
        // Never normalize, trim or reinterpret an accepted canonical ID here.
        let grouped="json_type(\(payload),'$.audioSessionID')='text' AND length(CAST(\(session) AS BLOB))>0"
        let end="json_extract(\(payload),'$.endTimestamp')+978307200.0",duration="json_extract(\(payload),'$.transcript.duration')"
        return """
        SELECT \(alias).id,CASE WHEN \(grouped) THEN 1 ELSE 0 END,
            CASE WHEN \(grouped) THEN \(session) ELSE \(alias).id END,
            \(alias).timestamp,
            CASE WHEN \(end)>=\(alias).timestamp AND \(end)<=\(alias).timestamp+86400 THEN \(end) ELSE NULL END,
            CASE WHEN \(duration)>0 AND \(duration)<=86400 THEN \(duration) ELSE 0 END,
            \(alias).title,\(alias).app,COALESCE(json_extract(\(payload),'$.bundleID'),''),\(alias).url,lower(hex(randomblob(16)))
        \(tail)
        """
    }
    static let triggers:[String:String]=[
        "recorded_meeting_insert":"""
        CREATE TRIGGER recorded_meeting_insert AFTER INSERT ON memories WHEN new.kind='audio' BEGIN
            INSERT INTO recorded_meeting_sources \(rows("new",""));
        END
        """,
        "recorded_meeting_delete":"""
        CREATE TRIGGER recorded_meeting_delete AFTER DELETE ON memories BEGIN
            DELETE FROM recorded_meeting_sources WHERE memory_id=old.id;
        END
        """,
        "recorded_meeting_update":"""
        CREATE TRIGGER recorded_meeting_update AFTER UPDATE OF id,payload,timestamp,app,title,url,kind ON memories
        WHEN old.id IS NOT new.id OR old.payload IS NOT new.payload OR old.timestamp IS NOT new.timestamp OR old.app IS NOT new.app OR old.title IS NOT new.title OR old.url IS NOT new.url OR old.kind IS NOT new.kind
        BEGIN
            DELETE FROM recorded_meeting_sources WHERE memory_id=old.id;
            INSERT INTO recorded_meeting_sources \(rows("new","WHERE new.kind='audio'"));
        END
        """
    ]
    static func install(_ db:RoutineDatabase)throws {
        try Task.checkCancellation()
        sqlite3_progress_handler(db.handle,1000,{_ in Task.isCancelled ? 1:0},nil)
        defer {sqlite3_progress_handler(db.handle,0,nil,nil)}
        do {
            let table=try db.statement("SELECT 1 FROM sqlite_master WHERE type='table' AND name='recorded_meeting_sources'")
            let existed=sqlite3_step(table)==SQLITE_ROW;sqlite3_finalize(table)
            try db.execute("""
            CREATE TABLE IF NOT EXISTS recorded_meeting_sources(
                memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
                grouped INTEGER NOT NULL CHECK(grouped IN (0,1)), recording_id TEXT NOT NULL,
                started REAL NOT NULL, observed_end REAL, duration REAL NOT NULL,
                title TEXT NOT NULL, app TEXT NOT NULL, bundle_id TEXT NOT NULL, url TEXT,
                revision TEXT NOT NULL CHECK(length(revision)=32)
            );
            """)
            let marker=try db.statement("SELECT value FROM store_metadata WHERE key='recorded_meeting_index_version'")
            let version=sqlite3_step(marker)==SQLITE_ROW ? db.text(marker,0):nil;sqlite3_finalize(marker)
            var current=existed && (version==currentVersion || version==pendingVersion)
            for name in triggers.keys.sorted() {
                let row=try db.statement("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?");db.bind(row,1,name)
                if sqlite3_step(row) != SQLITE_ROW || db.text(row,0).trimmingCharacters(in:.whitespacesAndNewlines) != triggers[name]! {current=false}
                sqlite3_finalize(row)
            }
            if !current {
                try db.execute("DROP INDEX IF EXISTS recorded_meeting_time; DROP INDEX IF EXISTS recorded_meeting_group; DELETE FROM recorded_meeting_sources;")
                for name in triggers.keys.sorted() {try db.execute("DROP TRIGGER IF EXISTS \(name)");try db.execute(triggers[name]!)}
                // Normal library opening never scans transcript bodies. Keep
                // new/old writers coherent immediately, then populate the
                // historical rows in the owned, cancellable Recordings job.
                let anySource=try db.statement("SELECT 1 FROM memories LIMIT 1")
                let status=sqlite3_step(anySource);sqlite3_finalize(anySource)
                guard status==SQLITE_ROW || status==SQLITE_DONE else {throw db.error()}
                let empty=status==SQLITE_DONE
                let state=empty ? currentVersion:pendingVersion
                try db.execute("INSERT INTO store_metadata(key,value) VALUES('recorded_meeting_index_version','\(state)') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            }
            try db.execute("""
            CREATE INDEX IF NOT EXISTS recorded_meeting_time ON recorded_meeting_sources(started DESC,memory_id DESC);
            CREATE INDEX IF NOT EXISTS recorded_meeting_group ON recorded_meeting_sources(grouped,recording_id,started,memory_id);
            """)
            try Task.checkCancellation()
        }catch {if Task.isCancelled {throw CancellationError()};throw error}
    }
    /// Caller owns an IMMEDIATE transaction. A cancelled/failed build rolls
    /// back both rows and readiness; another connection cannot observe a
    /// partial page. No source or media handle is retained after publication.
    static func populateIfNeeded(_ db:RoutineDatabase)throws {
        let marker=try db.statement("SELECT value FROM store_metadata WHERE key='recorded_meeting_index_version'")
        let version=sqlite3_step(marker)==SQLITE_ROW ? db.text(marker,0):nil;sqlite3_finalize(marker)
        if version==currentVersion {return}
        guard version==pendingVersion else {throw OSwindError.unavailable("Reopen the library to prepare its recording index")}
        try Task.checkCancellation()
        sqlite3_progress_handler(db.handle,1000,{_ in Task.isCancelled ? 1:0},nil)
        defer {sqlite3_progress_handler(db.handle,0,nil,nil)}
        do {
            try db.execute("DELETE FROM recorded_meeting_sources")
            try db.execute("INSERT INTO recorded_meeting_sources \(rows("m","FROM memories m WHERE m.kind='audio'"))")
            try db.execute("UPDATE store_metadata SET value='\(currentVersion)' WHERE key='recorded_meeting_index_version'")
            try Task.checkCancellation()
        }catch {if Task.isCancelled {throw CancellationError()};throw error}
    }
}
