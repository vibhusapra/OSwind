import Foundation
import CSQLite

/// Rebuildable source metadata. SQL triggers keep schema20 writers coherent
/// without depending on their Swift implementation or hydrating sources.
enum TagIndexSchema {
    static let triggers:[String:String]=[
        "tag_index_insert":"""
        CREATE TRIGGER tag_index_insert AFTER INSERT ON memories BEGIN
            INSERT OR IGNORE INTO memory_tags(memory_id,tag,timestamp,app,kind,favorite)
                SELECT new.id,value,new.timestamp,new.app,new.kind,new.favorite
                FROM json_each(CAST(new.payload AS TEXT),'$.tags') WHERE type='text';
        END
        """,
        "tag_index_delete":"""
        CREATE TRIGGER tag_index_delete AFTER DELETE ON memories BEGIN
            DELETE FROM memory_tags WHERE memory_id=old.id;
        END
        """,
        "tag_index_update":"""
        CREATE TRIGGER tag_index_update AFTER UPDATE OF id,payload,timestamp,app,kind,favorite ON memories
        WHEN old.id IS NOT new.id OR old.payload IS NOT new.payload OR old.timestamp IS NOT new.timestamp OR old.app IS NOT new.app OR old.kind IS NOT new.kind OR old.favorite IS NOT new.favorite
        BEGIN
            DELETE FROM memory_tags WHERE memory_id=old.id;
            INSERT OR IGNORE INTO memory_tags(memory_id,tag,timestamp,app,kind,favorite)
                SELECT new.id,value,new.timestamp,new.app,new.kind,new.favorite
                FROM json_each(CAST(new.payload AS TEXT),'$.tags') WHERE type='text';
        END
        """
    ]
    /// Called within the opening migration transaction. Interrupted installation
    /// rolls back the table, triggers, data and readiness marker together.
    static func install(_ db:RoutineDatabase) throws {
        try Task.checkCancellation()
        sqlite3_progress_handler(db.handle,1000,{_ in Task.isCancelled ? 1:0},nil)
        defer {sqlite3_progress_handler(db.handle,0,nil,nil)}
        do {
            let table=try db.statement("SELECT 1 FROM sqlite_master WHERE type='table' AND name='memory_tags'")
            let existed=sqlite3_step(table)==SQLITE_ROW;sqlite3_finalize(table)
            try db.execute("""
            CREATE TABLE IF NOT EXISTS memory_tags(
                memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                tag TEXT NOT NULL, timestamp REAL NOT NULL, app TEXT NOT NULL,
                kind TEXT NOT NULL, favorite INTEGER NOT NULL,
                PRIMARY KEY(memory_id,tag)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS memories_activity_time ON memories(timestamp DESC,app,kind,favorite,id);
            """)
            let marker=try db.statement("SELECT value FROM store_metadata WHERE key='tag_index_version'")
            var current=existed && sqlite3_step(marker)==SQLITE_ROW && db.text(marker,0)=="1";sqlite3_finalize(marker)
            for name in triggers.keys.sorted() {
                let row=try db.statement("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?");db.bind(row,1,name)
                if sqlite3_step(row) != SQLITE_ROW || db.text(row,0).trimmingCharacters(in:.whitespacesAndNewlines) != triggers[name]! {current=false}
                sqlite3_finalize(row)
            }
            guard !current else {
                try db.execute("CREATE INDEX IF NOT EXISTS memory_tags_scope ON memory_tags(tag,timestamp DESC,app,kind,favorite,memory_id)")
                try Task.checkCancellation();return
            }
            // Build the secondary covering index once after bulk installation,
            // instead of maintaining its random timestamp ordering per row.
            try db.execute("DROP INDEX IF EXISTS memory_tags_scope")
            try db.execute("""
            DELETE FROM memory_tags;
            INSERT OR IGNORE INTO memory_tags(memory_id,tag,timestamp,app,kind,favorite)
                SELECT m.id,t.value,m.timestamp,m.app,m.kind,m.favorite
                FROM memories m,json_each(CAST(m.payload AS TEXT),'$.tags') t WHERE t.type='text';
            """)
            try db.execute("CREATE INDEX memory_tags_scope ON memory_tags(tag,timestamp DESC,app,kind,favorite,memory_id)")
            for name in triggers.keys.sorted() {try db.execute("DROP TRIGGER IF EXISTS \(name)");try db.execute(triggers[name]!)}
            try db.execute("INSERT INTO store_metadata(key,value) VALUES('tag_index_version','1') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            try Task.checkCancellation()
        } catch {if Task.isCancelled {throw CancellationError()};throw error}
    }
}
