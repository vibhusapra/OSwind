import Foundation
import CSQLite

/// Rebuildable FTS cache identity, independent of source IDs and native vector keys.
/// Direct FTS rowid maintenance avoids scanning its UNINDEXED id column per source.
enum FullTextIdentitySchema {
    static let triggers:[String:String]=[
        "memory_insert":"""
        CREATE TRIGGER memory_insert AFTER INSERT ON memories BEGIN
            INSERT INTO memory_fts_keys(memory_id) VALUES(new.id);
            INSERT INTO memory_fts(rowid,id,title,app,text) SELECT key,new.id,new.title,new.app,new.text FROM memory_fts_keys WHERE memory_id=new.id;
        END
        """,
        "memory_delete":"""
        CREATE TRIGGER memory_delete BEFORE DELETE ON memories BEGIN
            DELETE FROM memory_fts WHERE rowid=(SELECT key FROM memory_fts_keys WHERE memory_id=old.id);
        END
        """,
        "memory_update":"""
        CREATE TRIGGER memory_update AFTER UPDATE OF title,app,text ON memories
        WHEN old.title IS NOT new.title OR old.app IS NOT new.app OR old.text IS NOT new.text
        BEGIN
            DELETE FROM memory_fts WHERE rowid=(SELECT key FROM memory_fts_keys WHERE memory_id=old.id);
            INSERT INTO memory_fts(rowid,id,title,app,text) SELECT key,new.id,new.title,new.app,new.text FROM memory_fts_keys WHERE memory_id=new.id;
        END
        """
    ]
    /// Called inside MemoryStore's opening writer transaction. Legacy schema-13 writers
    /// preserve these installed triggers. No payload/data-format migration is needed.
    static func install(_ db:RoutineDatabase) throws {
        // Explicit integer keys remain stable across VACUUM. A source table's implicit
        // rowid is not a persistence contract; neither source nor vector identity changes.
        try db.execute("CREATE TABLE IF NOT EXISTS memory_fts_keys(key INTEGER PRIMARY KEY AUTOINCREMENT,memory_id TEXT NOT NULL UNIQUE REFERENCES memories(id) ON DELETE CASCADE)")
        let marker=try db.statement("SELECT value FROM store_metadata WHERE key='fts_rowid_version'");defer {sqlite3_finalize(marker)}
        var current=sqlite3_step(marker)==SQLITE_ROW && db.text(marker,0)=="1"
        for name in triggers.keys.sorted() {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            if sqlite3_step(row) != SQLITE_ROW || db.text(row,0).trimmingCharacters(in:.whitespacesAndNewlines) != triggers[name]! {current=false}
        }
        guard !current else {return}
        try Task.checkCancellation()
        sqlite3_progress_handler(db.handle,1000,{_ in Task.isCancelled ? 1:0},nil)
        defer {sqlite3_progress_handler(db.handle,0,nil,nil)}
        do {
            for name in triggers.keys.sorted() {try db.execute("DROP TRIGGER IF EXISTS \(name)")}
            try db.execute("INSERT OR IGNORE INTO memory_fts_keys(memory_id) SELECT id FROM memories; DELETE FROM memory_fts; INSERT INTO memory_fts(rowid,id,title,app,text) SELECT k.key,m.id,m.title,m.app,m.text FROM memories m JOIN memory_fts_keys k ON k.memory_id=m.id")
            for name in triggers.keys.sorted() {try db.execute(triggers[name]!)}
            try db.execute("INSERT INTO store_metadata(key,value) VALUES('fts_rowid_version','1') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            try Task.checkCancellation()
        } catch {if Task.isCancelled {throw CancellationError()};throw error}
    }
}
