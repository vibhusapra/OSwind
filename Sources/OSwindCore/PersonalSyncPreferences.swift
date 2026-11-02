import Foundation
import CSQLite

/// Local intent only. Neither this record nor a folder bookmark grants sync
/// authority. Portable content restore deliberately excludes store metadata.
public struct PersonalSyncPreferences:Codable,Equatable,Sendable {
    public var reconnectOnLaunch:Bool
    public var networkEnabled:Bool
    public init(reconnectOnLaunch:Bool=false,networkEnabled:Bool=true) {self.reconnectOnLaunch=reconnectOnLaunch;self.networkEnabled=networkEnabled}
}

extension MemoryStore {
    public func personalSyncPreferences()throws->PersonalSyncPreferences {
        try withRoutineDatabase {db in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-session-preferences-v1'");defer {sqlite3_finalize(row)}
            let status=sqlite3_step(row);if status==SQLITE_DONE {return .init()}
            guard status==SQLITE_ROW else {throw OSwindError.unavailable("Saved sync preferences could not be read")}
            let bytes=Data(db.text(row,0).utf8)
            guard bytes.count<=1024,let value=try? JSONDecoder().decode(PersonalSyncPreferences.self,from:bytes) else {throw OSwindError.invalid("Saved sync preferences are invalid")}
            return value
        }
    }
    public func savePersonalSyncPreferences(_ value:PersonalSyncPreferences)throws {
        try withRoutineDatabase {db in
            try Task.checkCancellation()
            let bytes=try JSONEncoder().encode(value)
            let row=try db.statement("INSERT INTO store_metadata(key,value) VALUES('sync-session-preferences-v1',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value<>excluded.value");defer {sqlite3_finalize(row)}
            db.bind(row,1,String(decoding:bytes,as:UTF8.self));try db.done(row)
        }
    }
}
