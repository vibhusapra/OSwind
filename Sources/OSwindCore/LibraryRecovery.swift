import Foundation
import CSQLite

/// Read existing local content without sync credentials or migrations. Recovery
/// exports never authorize old sync identity reuse; Restore creates a new local
/// library using the existing explicit content-table allowlist.
public enum LibraryRecovery {
    @discardableResult public static func createBackup(from root:URL,destination:URL,progress:(LibraryBackupProgress)throws->Void={_ in})throws->LibraryBackupInfo {
        guard root.isFileURL,FileManager.default.fileExists(atPath:root.appendingPathComponent("memory.sqlite").path) else {throw OSwindError.invalid("Select an existing native library for recovery")}
        try Task.checkCancellation()
        let source=try MemoryStore(root:root,recoveryReadOnly:true)
        do {
            let result=try LibraryBackup.create(store:source,destination:destination,progress:progress)
            try source.close();return result
        }catch {try? source.close();throw error}
    }
    /// A backup must take BEGIN IMMEDIATE for its final erasure-fence check.
    /// SQLITE_OPEN_READONLY cannot supply that reservation. Keep an RW handle
    /// whose authorizer denies EVERY data/schema mutation, including writes in
    /// triggers, instead of weakening the check or migrating the source.
    static func installReadAdmission(_ db:RoutineDatabase)throws {
        guard sqlite3_set_authorizer(db.handle,{_,action,first,second,_,_ in
            switch action {
            case SQLITE_READ,SQLITE_SELECT,SQLITE_FUNCTION,SQLITE_TRANSACTION,SQLITE_SAVEPOINT,SQLITE_RECURSIVE:
                return SQLITE_OK
            case SQLITE_PRAGMA:
                guard let first else {return SQLITE_DENY}
                let name=String(cString:first).lowercased()
                // Read-only inspection pragmas; settings are never accepted.
                let inspection:Set<String>=["user_version","schema_version","table_info","table_xinfo","table_list","foreign_key_list","index_list","index_info","index_xinfo","integrity_check","quick_check","foreign_key_check","database_list"]
                guard inspection.contains(name) else {return SQLITE_DENY}
                if ["user_version","schema_version"].contains(name),second != nil {return SQLITE_DENY}
                return SQLITE_OK
            default:return SQLITE_DENY
            }
        },nil)==SQLITE_OK else {throw OSwindError.unavailable("Cannot install local recovery read admission")}
    }
}
