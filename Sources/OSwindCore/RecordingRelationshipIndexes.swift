import Foundation
import CSQLite

/// Canonical expression indexes: SQLite maintains these from the actual source
/// payload. Rebuildable display projections never authorize destructive edges.
enum RecordingRelationshipIndexes {
    static let names="memory_recording_names_v1",sessions="memory_recording_sessions_v1"
    static func selector(_ alias:String)->String {"json_extract(CAST(\(alias).payload AS TEXT),'$.recordingDetails.scope.selector')"}
    static func scopeID(_ alias:String)->String {"json_extract(CAST(\(alias).payload AS TEXT),'$.recordingDetails.scope.id')"}
    static func sessionID(_ alias:String)->String {"json_extract(CAST(\(alias).payload AS TEXT),'$.audioSessionID')"}
    static let nameSQL="CREATE INDEX memory_recording_names_v1 ON memories(json_extract(CAST(payload AS TEXT),'$.recordingDetails.scope.selector'),json_extract(CAST(payload AS TEXT),'$.recordingDetails.scope.id'),id) WHERE kind='recording-metadata'"
    static let sessionSQL="CREATE INDEX memory_recording_sessions_v1 ON memories(json_extract(CAST(payload AS TEXT),'$.audioSessionID'),id) WHERE kind='audio'"
    private static func ensure(_ db:RoutineDatabase,name:String,sql:String)throws {
        let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name)
        let code=sqlite3_step(row),found=code==SQLITE_ROW ? db.text(row,0):nil;sqlite3_finalize(row)
        guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
        if let found {guard found==sql else {throw OSwindError.database("Canonical recording relationship index differs")}}
        else {try Task.checkCancellation();try db.execute(sql);try Task.checkCancellation()}
    }
    static func ensureNames(_ db:RoutineDatabase)throws {try ensure(db,name:names,sql:nameSQL)}
    static func ensureSessions(_ db:RoutineDatabase)throws {try ensure(db,name:sessions,sql:sessionSQL)}
    static func install(_ db:RoutineDatabase)throws {
        try ensureNames(db)
        // Fresh libraries maintain this from their first audio row. Existing
        // large audio archives defer its one-time build until session erasure
        // needs it, inside erasure's cancellable transaction. Saving a name or
        // reopening a named archive must not parse every audio payload.
        if try db.eraseCount("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='\(sessions)')")==1 ||
           db.eraseCount("SELECT EXISTS(SELECT 1 FROM memories WHERE kind='audio' LIMIT 1)")==0 {
            try ensureSessions(db)
        }
    }
}
