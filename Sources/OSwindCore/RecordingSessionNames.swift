import Foundation
import CSQLite

/// Thin display metadata only. This never authorizes a scope, edit or erase.
/// A conflict has no chosen title, even when two definitions have equal text.
public struct RecordedMeetingNameSummary:Equatable,Sendable {
    public let name:String?
    public let hasConflicts:Bool
}

public extension MemoryStore {
    /// At most 512 representatives and two name rows per explicit session.
    /// Legacy single-source names require exact evidence-version validation;
    /// this API deliberately does not infer it from a source ID or title.
    func recordedMeetingSessionNames(for sources:[RecordedMeetingSource],at revision:RecordedMeetingRevision)throws->[String:RecordedMeetingNameSummary] {
        guard sources.count<=512 else {throw OSwindError.invalid("Read at most 512 recording name representatives")}
        guard revision.owner==recordedMeetingOwner,sources.allSatisfy({$0.owner==recordedMeetingOwner}) else {throw OSwindError.unavailable("Refresh recording names in this open library")}
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        guard snapshot.settings==revision.settings else {throw OSwindError.unavailable("Recording privacy or settings changed. Refresh the session list.")}
        return try withRoutineDatabase {db in
            try RecordingDetailsSchema.prepare(db);try db.execute("SAVEPOINT recording_session_names")
            do {
                let result=try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {
                    guard try RecordedMeetingRevisionSchema.read(db,owner:recordedMeetingOwner,settings:snapshot.settings)==revision else {throw RecordedMeetingRefreshError.changed}
                    try Task.checkCancellation()
                    guard try db.eraseCount("SELECT EXISTS(SELECT 1 FROM recorded_meeting_details WHERE selector='session' LIMIT 1)")==1 else {return [String:RecordedMeetingNameSummary]()}
                    var seen=Set<String>()
                    let representatives=sources.filter {$0.grouped && seen.insert($0.sessionKey).inserted}
                    guard !representatives.isEmpty else {return [String:RecordedMeetingNameSummary]()}
                    for source in representatives {
                        guard source.sessionKey==RecordedMeetingSource.key(grouped:true,id:source.recordingID) else {throw RecordedMeetingRefreshError.changed}
                    }
                    // One bound JSON argument avoids variable-count limits. Each
                    // correlated index probe returns at most one row: even a
                    // session with many conflicting names stays bounded at two.
                    let encoded=try JSONEncoder().encode(representatives.map {[$0.memoryID,$0.revision,$0.recordingID,$0.sessionKey]})
                    let rows=try db.statement("""
                    WITH wanted AS (SELECT json_extract(value,'$[0]') AS memory_id,
                        json_extract(value,'$[1]') AS revision,json_extract(value,'$[2]') AS recording_id,
                        json_extract(value,'$[3]') AS session_key FROM json_each(?))
                    SELECT w.revision,w.recording_id,w.session_key,s.revision,s.grouped,s.recording_id,s.app,s.bundle_id,s.title,s.url,
                        first.memory_id,first.name,first.app,first.bundle_id,second.memory_id,second.name,second.app,second.bundle_id
                    FROM wanted w LEFT JOIN recorded_meeting_sources s ON s.memory_id=w.memory_id
                    LEFT JOIN recorded_meeting_details first ON first.memory_id=(
                        SELECT memory_id FROM recorded_meeting_details INDEXED BY recorded_meeting_details_scope
                        WHERE selector='session' AND scope_id=w.recording_id COLLATE BINARY AND evidence_revision IS NULL
                        ORDER BY memory_id COLLATE BINARY LIMIT 1)
                    LEFT JOIN recorded_meeting_details second ON second.memory_id=(
                        SELECT memory_id FROM recorded_meeting_details INDEXED BY recorded_meeting_details_scope
                        WHERE selector='session' AND scope_id=w.recording_id COLLATE BINARY AND evidence_revision IS NULL
                        ORDER BY memory_id COLLATE BINARY LIMIT 1 OFFSET 1)
                    """)
                    defer {sqlite3_finalize(rows)};db.bind(rows,1,String(decoding:encoded,as:UTF8.self))
                    var values=[String:RecordedMeetingNameSummary](),count=0,code=sqlite3_step(rows)
                    let policy=snapshot.settings.privacy
                    while code==SQLITE_ROW {
                        try Task.checkCancellation();count+=1
                        guard db.text(rows,0)==db.text(rows,3),sqlite3_column_int(rows,4)==1,
                              Data(db.text(rows,1).utf8)==Data(db.text(rows,5).utf8) else {throw RecordedMeetingRefreshError.changed}
                        if policy.exclusion(app:db.text(rows,7).isEmpty ? db.text(rows,6):db.text(rows,7),title:db.text(rows,8),url:db.optional(rows,9))==nil {
                            var titles=[String](),hidden=false
                            for offset in [10,14] where sqlite3_column_type(rows,Int32(offset)) != SQLITE_NULL {
                                let title=db.text(rows,Int32(offset+1)),app=db.text(rows,Int32(offset+2)),bundle=db.text(rows,Int32(offset+3))
                                if title.utf8.count>32768 || policy.exclusion(app:bundle.isEmpty ? app:bundle,title:title,url:nil) != nil {hidden=true}
                                else {
                                    let clean=policy.sanitize(title).text.trimmingCharacters(in:.whitespacesAndNewlines)
                                    if clean.isEmpty {hidden=true}else {titles.append(String(clean.prefix(200)))}
                                }
                            }
                            if !hidden,!titles.isEmpty {values[db.text(rows,2)] = .init(name:titles.count==1 ? titles[0]:nil,hasConflicts:titles.count>1)}
                        }
                        code=sqlite3_step(rows)
                    }
                    guard code==SQLITE_DONE else {throw db.error()}
                    guard count==representatives.count else {throw RecordedMeetingRefreshError.changed}
                    try Task.checkCancellation();return values
                }
                try db.execute("RELEASE recording_session_names");return result
            }catch {try? db.execute("ROLLBACK TO recording_session_names; RELEASE recording_session_names");throw error}
        }
    }
}
