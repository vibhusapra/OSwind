import Foundation
import CSQLite

/// Value-only local review. It retains no file/media handles and is not
/// portable Calendar permission. UI publication and saving revalidate it.
public struct RecordedMeetingCalendarSelection:Equatable,Sendable {
    public let configuration:MeetingContextConfiguration,privacy:PrivacyPolicy,libraryIdentity:String
    let source:RecordedMeetingSource
    let expected:RecordedMeetingDetailsSnapshot?
    let scope:RecordingScope
    let settings:AppSettings
}
public extension MemoryStore {
    func recordedMeetingCalendarSelection(for source:RecordedMeetingSource,replacing expected:RecordedMeetingDetailsSnapshot?=nil)throws->RecordedMeetingCalendarSelection {
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        let audio=try recordedMeetingEvidence(source),scope=try recordingDetailsScope(audio),rows=try recordedMeetingDetails(for:source)
        guard rows==(expected.map {[$0]} ?? []),let library=try meetingLibraryIdentity(),snapshot.settings.meetings.admits(libraryIdentity:library),snapshot.settings.privacy.exclusion(app:"com.apple.iCal",title:"",url:nil)==nil else {throw OSwindError.unavailable("Choose calendars for this library in Upcoming before linking a recording")}
        let value=RecordedMeetingCalendarSelection(configuration:snapshot.settings.meetings,privacy:snapshot.settings.privacy,libraryIdentity:library,source:source,expected:expected,scope:scope,settings:snapshot.settings)
        return try withCurrentRecordedMeetingCalendarSelection(value,settingsSnapshot:snapshot) {value}
    }
    /// Worker snapshots may span the native read. Published values never keep
    /// that descriptor; the UI guard takes a short nonwaiting fresh snapshot.
    func withCurrentRecordedMeetingCalendarSelection<T>(_ value:RecordedMeetingCalendarSelection,settingsSnapshot:LibrarySettingsSnapshot?=nil,_ publish:()throws->T)throws->T {
        guard value.source.owner==recordedMeetingOwner,value.expected.map({$0.owner==recordedMeetingOwner}) ?? true else {throw RecordedMeetingRefreshError.changed}
        let current=try settingsSnapshot ?? LibrarySettingsSnapshot.capture(root:root,waitForLock:false)
        defer {if settingsSnapshot==nil {current.release()}}
        guard current.settings==value.settings else {throw RecordedMeetingRefreshError.changed}
        return try withAvailableRoutineSnapshot {db in
            guard try validateRecordedMeetingCalendarSelection(value,db:db),try meetingLibraryIdentity()==value.libraryIdentity else {throw RecordedMeetingRefreshError.changed}
            return try current.withCurrent(root:root,policy:current.settings.privacy,waitForLock:false,publish)
        }
    }
}

extension MemoryStore {
    /// Only the reviewed source and its name/conflict set gate this review.
    /// Unrelated arrivals and later members of the same session may continue.
    func validateRecordedMeetingCalendarSelection(_ value:RecordedMeetingCalendarSelection,db:RoutineDatabase)throws->Bool {
        let source=try db.statement("SELECT revision,grouped,recording_id FROM recorded_meeting_sources WHERE memory_id=?")
        defer {sqlite3_finalize(source)};db.bind(source,1,value.source.memoryID)
        let status=sqlite3_step(source);guard status==SQLITE_ROW || status==SQLITE_DONE else {throw db.error()}
        guard status==SQLITE_ROW,db.text(source,0)==value.source.revision,(sqlite3_column_int(source,1)==1)==value.source.grouped,Data(db.text(source,2).utf8)==Data(value.source.recordingID.utf8) else {return false}
        let names=try db.statement("SELECT memory_id,revision FROM recorded_meeting_details WHERE selector=? AND scope_id=? COLLATE BINARY AND (? IS NULL OR evidence_revision=?) ORDER BY memory_id COLLATE BINARY LIMIT 2")
        defer {sqlite3_finalize(names)};db.bind(names,1,value.scope.selector.rawValue);db.bind(names,2,value.scope.id);db.bind(names,3,value.scope.revision);db.bind(names,4,value.scope.revision)
        let code=sqlite3_step(names);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
        guard let expected=value.expected else {return code==SQLITE_DONE}
        guard code==SQLITE_ROW,Data(db.text(names,0).utf8)==Data(expected.id.utf8),db.text(names,1)==expected.revision else {return false}
        let next=sqlite3_step(names);guard next==SQLITE_ROW || next==SQLITE_DONE else {throw db.error()};return next==SQLITE_DONE
    }
}
