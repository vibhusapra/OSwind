import Foundation
import CSQLite
import Darwin

/// Private scratch indexes and read-only snapshot readers share bounded SQLite
/// IO helpers. Never execute SQL read from an archive.
final class BackupDatabase {
    private(set) var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(_ url: URL, createPrivate: Bool = false) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw BackupFileError.invalid("Invalid backup database path") }
        let temporaryPolicy=try VaultAccess.temporaryPolicy(at:url)
        let parent = url.deletingLastPathComponent()
        guard let resolved = realpath(parent.path,nil) else { throw BackupFileError.invalid("Cannot resolve backup database directory") }
        defer { free(resolved) }
        let path = String(cString:resolved)+"/"+url.lastPathComponent
        if createPrivate {
            let file = open(path,O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,0o600)
            guard file >= 0 else { throw BackupFileError.invalid("Backup scratch database must be new") }; Darwin.close(file)
        }
        let flags = (createPrivate ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(path,&handle,flags,nil) == SQLITE_OK else { let failure = error("Cannot open backup database"); sqlite3_close(handle); handle = nil; throw failure }
        sqlite3_busy_timeout(handle,1000)
        sqlite3_limit(handle,SQLITE_LIMIT_LENGTH,Int32(2*MemoryStore.maximumRecordBytes+1_048_576))
        sqlite3_limit(handle,SQLITE_LIMIT_SQL_LENGTH,1_048_576)
        sqlite3_limit(handle,SQLITE_LIMIT_EXPR_DEPTH,128)
        sqlite3_progress_handler(handle,1000,{ _ in Task.isCancelled ? 1 : 0 },nil)
        do {
            try execute("PRAGMA trusted_schema=OFF; PRAGMA cache_size=-4096; PRAGMA temp_store=\(temporaryPolicy.rawValue);")
            try execute(createPrivate ? "PRAGMA journal_mode=DELETE; PRAGMA synchronous=NORMAL;" : "PRAGMA query_only=ON;")
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { close() }
    func close() { if let handle { sqlite3_close_v2(handle); self.handle = nil } }
    func error(_ context: String) -> OSwindError { .database(context+": "+String(cString:sqlite3_errmsg(handle))) }
    func execute(_ sql: String) throws { guard sqlite3_exec(handle,sql,nil,nil,nil) == SQLITE_OK else { throw error("Backup SQL failed") } }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(handle,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw error("Cannot prepare backup SQL") }; return statement
    }
    func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) { sqlite3_bind_text64(statement,index,value,UInt64(value.utf8.count),transient,UInt8(SQLITE_UTF8)) }
    func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement,column) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement,column),
              let result = String(bytes:UnsafeBufferPointer(start:bytes,count:Int(sqlite3_column_bytes(statement,column))),encoding:.utf8) else { throw BackupFileError.invalid("Backup database has an invalid text field") }
        return result
    }
    func integer(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement,0) == SQLITE_INTEGER else { throw error("Backup count unavailable") }; return sqlite3_column_int64(statement,0)
    }
    func requireTable(_ name: String) throws {
        let statement = try prepare("SELECT type,sql FROM sqlite_master WHERE name=?"); defer { sqlite3_finalize(statement) }; bind(statement,1,name)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw BackupFileError.invalid("Backup is missing its \(name) table") }
        let kind = try text(statement,0), sql = try text(statement,1)
        guard kind == "table", !sql.uppercased().contains("CREATE VIRTUAL TABLE") else { throw BackupFileError.invalid("Backup requires an ordinary \(name) table") }
        guard name.utf8.allSatisfy({ (97...122).contains($0) || $0==95 }) else { throw BackupFileError.invalid("Invalid backup table name") }
        let columns = try prepare("PRAGMA table_xinfo(\(name))"); defer { sqlite3_finalize(columns) }; var status = sqlite3_step(columns)
        while status == SQLITE_ROW { guard sqlite3_column_int(columns,6)==0 else { throw BackupFileError.invalid("Generated backup columns are unsupported") }; status = sqlite3_step(columns) }
        guard status == SQLITE_DONE else { throw error("Cannot inspect backup table columns") }
    }
}
