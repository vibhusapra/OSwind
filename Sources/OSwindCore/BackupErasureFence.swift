import Foundation
import CSQLite

/// Media reservations preserve readers' files; they do not authorize publishing
/// an archive after its source history was erased. This additive metadata works
/// with ordinary schema-32 SQL writers, including already-open connections.
enum BackupErasureFence {
    static let key="backup-erasure-generation-v1"
    static let tables=["memories","historical_evidence","chat_sessions","chat_turns","routines","routine_runs","routine_run_originals","memory_entities"]
    static func name(_ table:String)->String {"oswind_backup_erasure_"+table}
    static func ddl(_ table:String)->String {
        "CREATE TRIGGER "+name(table)+" AFTER DELETE ON "+table+" BEGIN UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='"+key+"'; END"
    }
    static func install(_ db:RoutineDatabase)throws {
        try db.execute("INSERT OR IGNORE INTO store_metadata(key,value) VALUES('"+key+"',lower(hex(randomblob(16))))")
        for table in tables {try db.execute("DROP TRIGGER IF EXISTS "+name(table));try db.execute(ddl(table))}
        _=try current(db)
    }
    static func current(_ db:RoutineDatabase)throws->String {
        for table in tables {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name(table))
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==ddl(table),sqlite3_step(row)==SQLITE_DONE else {throw BackupFileError.changed("Backup erasure protection changed; reopen the intended library")}
        }
        let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,key)
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_TEXT else {throw BackupFileError.changed("Backup erasure generation is missing")}
        let value=db.text(row,0)
        guard value.utf8.count==32,value.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),sqlite3_step(row)==SQLITE_DONE else {throw BackupFileError.changed("Backup erasure generation is invalid")}
        return value
    }
}
