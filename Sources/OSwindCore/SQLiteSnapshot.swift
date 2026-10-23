import Foundation
import CSQLite
import Darwin

struct SQLiteSnapshotProgress: Sendable {
    var copiedPages: Int
    var totalPages: Int
}

/// A pinned WAL read transaction gives one source snapshot while capture can
/// continue on other connections. This copies SQLite only; media is separate.
enum SQLiteSnapshot {
    private static func error(_ db: OpaquePointer?, _ context: String) -> OSwindError {
        .database(context+": "+String(cString:sqlite3_errmsg(db)))
    }
    private static func canonicalPath(_ url: URL) throws -> String {
        guard let path = realpath(url.path,nil) else { throw OSwindError.invalid("Snapshot path cannot be resolved") }
        defer { free(path) }; return String(cString:path)
    }
    private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw error(db,"Snapshot SQL failed") }
    }
    static func copy(source: URL, to destination: URL, pagesPerStep: Int = 512,
                     progress: (SQLiteSnapshotProgress) throws -> Void = { _ in }) throws {
        guard (1...8192).contains(pagesPerStep), source.isFileURL, destination.isFileURL,
              !source.path.utf8.contains(0), !destination.path.utf8.contains(0),
              source.standardizedFileURL != destination.standardizedFileURL else { throw OSwindError.invalid("Invalid snapshot source or page batch") }
        var attributes = stat()
        guard lstat(source.path,&attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else { throw OSwindError.invalid("Snapshot source must be an existing regular database file") }
        // macOS temporary paths commonly pass through /var -> /private/var.
        // Reject a source symlink itself, then canonicalize legitimate ancestors
        // before SQLite's stricter no-symlink open flag checks the whole path.
        let sourcePath = try canonicalPath(source)
        let destinationParent = try canonicalPath(destination.deletingLastPathComponent())
        let destinationPath = destinationParent + (destinationParent.hasSuffix("/") ? "" : "/") + destination.lastPathComponent
        var input: OpaquePointer?
        guard sqlite3_open_v2(sourcePath,&input,SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,nil) == SQLITE_OK else {
            let failure = error(input,"Cannot read the source database"); sqlite3_close(input); throw failure
        }
        defer { sqlite3_close(input) }
        sqlite3_busy_timeout(input,1000)
        try execute(input,"PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; BEGIN;")
        // Force the read version before any progress callback can allow a writer.
        var pin: OpaquePointer?
        guard sqlite3_prepare_v2(input,"SELECT COUNT(*) FROM sqlite_master",-1,&pin,nil) == SQLITE_OK else { throw error(input,"Cannot pin database snapshot") }
        let pinned = sqlite3_step(pin); sqlite3_finalize(pin)
        guard pinned == SQLITE_ROW else { throw error(input,"Cannot pin database snapshot") }
        defer { try? execute(input,"ROLLBACK") }
        try Task.checkCancellation()

        let descriptor = open(destination.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard descriptor >= 0 else { throw OSwindError.unavailable("Snapshot destination must be a new writable file") }
        close(descriptor)
        var completed = false
        defer {
            if !completed {
                for suffix in ["","-wal","-shm","-journal"] { try? FileManager.default.removeItem(atPath:destination.path+suffix) }
            }
        }
        var output: OpaquePointer?
        guard sqlite3_open_v2(destinationPath,&output,SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,nil) == SQLITE_OK else {
            let failure = error(output,"Cannot create snapshot database"); sqlite3_close(output); throw failure
        }
        defer { sqlite3_close(output) }
        sqlite3_busy_timeout(output,1000)
        try execute(output,"PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
        guard let backup = sqlite3_backup_init(output,"main",input,"main") else { throw error(output,"Cannot initialize database snapshot") }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        var busySince: Date?
        while true {
            try Task.checkCancellation()
            let status = sqlite3_backup_step(backup,Int32(pagesPerStep))
            if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                let now = Date(); if busySince == nil { busySince = now }
                guard now.timeIntervalSince(busySince!) < 10 else { throw OSwindError.unavailable("Database stayed busy during the snapshot; try again") }
                Thread.sleep(forTimeInterval:0.01); continue
            }
            guard status == SQLITE_OK || status == SQLITE_DONE else { throw error(output,"Database snapshot failed") }
            busySince = nil
            let total = Int(sqlite3_backup_pagecount(backup)), remaining = Int(sqlite3_backup_remaining(backup))
            try progress(SQLiteSnapshotProgress(copiedPages:max(0,total-remaining),totalPages:total))
            if status == SQLITE_DONE { break }
        }
        let finish = sqlite3_backup_finish(backup); finished = true
        guard finish == SQLITE_OK else { throw error(output,"Cannot finish database snapshot") }
        try Task.checkCancellation()
        // Publish one self-contained database file, never an unshipped WAL.
        try execute(output,"PRAGMA journal_mode=DELETE;")
        try quickCheck(output)
        var mode: OpaquePointer?
        guard sqlite3_prepare_v2(output,"PRAGMA journal_mode",-1,&mode,nil) == SQLITE_OK else { throw error(output,"Cannot inspect snapshot journal mode") }
        let standalone = sqlite3_step(mode) == SQLITE_ROW && sqlite3_column_text(mode,0).map { String(cString:$0) == "delete" } == true
        sqlite3_finalize(mode)
        guard standalone else { throw OSwindError.database("Snapshot still requires an external journal") }
        let file = try FileHandle(forWritingTo:destination); try file.synchronize(); try file.close()
        let closed = sqlite3_close(output)
        guard closed == SQLITE_OK else { throw error(output,"Cannot close completed snapshot") }
        output = nil
        // System SQLite can leave an unused SHM after changing a copied WAL
        // header to DELETE mode. It is not part of the standalone snapshot.
        let wal = destination.path+"-wal"
        if FileManager.default.fileExists(atPath:wal) {
            let size = (try FileManager.default.attributesOfItem(atPath:wal)[.size] as? NSNumber)?.int64Value ?? -1
            guard size == 0 else { throw OSwindError.database("Unexpected snapshot WAL remained after close") }
            try FileManager.default.removeItem(atPath:wal)
        }
        for suffix in ["-shm","-journal"] {
            let sidecar = destination.path+suffix
            if FileManager.default.fileExists(atPath:sidecar) { try FileManager.default.removeItem(atPath:sidecar) }
        }
        completed = true
    }
    private static func quickCheck(_ db: OpaquePointer?) throws {
        sqlite3_progress_handler(db,1000,{ _ in Task.isCancelled ? 1 : 0 },nil)
        defer { sqlite3_progress_handler(db,0,nil,nil) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,"PRAGMA quick_check",-1,&statement,nil) == SQLITE_OK else { throw error(db,"Cannot verify snapshot") }
        defer { sqlite3_finalize(statement) }
        var rows = 0, status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation(); rows += 1
            guard let text = sqlite3_column_text(statement,0), String(cString:text) == "ok" else { throw OSwindError.database("Snapshot integrity check failed") }
            status = sqlite3_step(statement)
        }
        try Task.checkCancellation()
        guard status == SQLITE_DONE, rows == 1 else { throw error(db,"Snapshot integrity check failed") }
    }
}
