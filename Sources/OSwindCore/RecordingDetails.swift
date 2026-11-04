import Foundation
import CSQLite

/// Data about an explicit association, never Calendar access or execution
/// authority. No attendee names, event title, description or join URL is copied.
public struct RecordingCalendarLink:Codable,Equatable,Sendable {
    public let libraryIdentity:String,calendarID:String,seriesID:String
    public let originalOccurrence:Date?,start:Date,end:Date
    public let occurrenceID:String,reviewedRevision:String
    public init(event:MeetingOccurrence,libraryIdentity:String)throws {
        guard !event.cancelled,!event.declined,MeetingIdentity.isHex(libraryIdentity,bytes:32) else {throw OSwindError.invalid("Choose an available occurrence in the reviewed library")}
        self.libraryIdentity=libraryIdentity;calendarID=event.calendarID;seriesID=event.seriesID
        originalOccurrence=event.originalOccurrence;start=event.start;end=event.end
        occurrenceID=event.id;reviewedRevision=event.revision
    }
    private enum CodingKeys:String,CodingKey {case libraryIdentity,calendarID,seriesID,originalOccurrence,start,end,occurrenceID,reviewedRevision}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        libraryIdentity=try c.decode(String.self,forKey:.libraryIdentity);calendarID=try c.decode(String.self,forKey:.calendarID);seriesID=try c.decode(String.self,forKey:.seriesID)
        originalOccurrence=try c.decodeIfPresent(Date.self,forKey:.originalOccurrence);start=try c.decode(Date.self,forKey:.start);end=try c.decode(Date.self,forKey:.end)
        occurrenceID=try c.decode(String.self,forKey:.occurrenceID);reviewedRevision=try c.decode(String.self,forKey:.reviewedRevision)
        guard MeetingIdentity.isHex(libraryIdentity,bytes:32),MeetingIdentity.isHex(reviewedRevision,bytes:64) else {throw OSwindError.invalid("Invalid recording/calendar association")}
        let event=try MeetingOccurrence(calendarID:calendarID,seriesID:seriesID,originalOccurrence:originalOccurrence,start:start,end:end,title:"")
        guard occurrenceID==event.id else {throw OSwindError.invalid("Recording calendar occurrence identity differs")}
    }
    public func matches(_ event:MeetingOccurrence,libraryIdentity:String)->Bool {
        self.libraryIdentity==libraryIdentity && event.id==occurrenceID && event.revision==reviewedRevision && !event.cancelled && !event.declined
    }
    public static func ==(a:Self,b:Self)->Bool {
        a.libraryIdentity==b.libraryIdentity && Data(a.calendarID.utf8)==Data(b.calendarID.utf8) && Data(a.seriesID.utf8)==Data(b.seriesID.utf8) && a.originalOccurrence==b.originalOccurrence && a.start==b.start && a.end==b.end && a.occurrenceID==b.occurrenceID && a.reviewedRevision==b.reviewedRevision
    }
}
/// Session labels follow exact explicit recording IDs. Legacy single clips use
/// the same exact-evidence-version restriction as recording-scoped Ask.
public struct RecordingDetails:Codable,Equatable,Sendable {
    public let version:Int
    public let scope:RecordingScope
    public let calendar:RecordingCalendarLink?
    public init(scope:RecordingScope,calendar:RecordingCalendarLink?=nil) {
        version=1;self.scope=scope;self.calendar=calendar
    }
    private enum CodingKeys:String,CodingKey {case version,scope,calendar}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version);scope=try c.decode(RecordingScope.self,forKey:.scope);calendar=try c.decodeIfPresent(RecordingCalendarLink.self,forKey:.calendar)
        guard version==1 else {throw OSwindError.invalid("Unsupported recording-details version")}
    }
    static func name(_ input:String)throws->String {
        let value=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.count<=200,value.utf8.count<=8192,!value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else {throw OSwindError.invalid("Use a recording name of 1–200 characters without control characters")}
        return value
    }
    static func sameTarget(_ a:RecordingScope,_ b:RecordingScope)->Bool {
        a.selector==b.selector && a.id.map({Data($0.utf8)})==b.id.map({Data($0.utf8)}) && a.revision==b.revision
    }
}
extension Memory {
    func validateRecordingDetails()throws {
        guard kind == .recordingMetadata || recordingDetails != nil else {return}
        guard kind == .recordingMetadata,let details=recordingDetails,details.version==1,
              timestamp.timeIntervalSinceReferenceDate.isFinite,endTimestamp==nil,url==nil,display==nil,
              imagePath==nil,audioPath==nil,videoPath==nil,transcript==nil,visualRecording==nil,textObservation==nil,recap==nil,audioSessionID==nil,regions.isEmpty,
              Data(try RecordingDetails.name(title).utf8)==Data(title.utf8) else {throw OSwindError.invalid("Recording names must be separate, complete metadata without captured media")}
        var canonical=self;canonical.embedding=nil;canonical.originalEvidence=nil;canonical.searchPreview=nil
        guard try JSONEncoder().encode(canonical).count<=32768 else {throw OSwindError.invalid("Recording metadata exceeds 32 KiB")}
    }
}
public struct RecordedMeetingDetailsSnapshot:Equatable,Sendable,Identifiable {
    /// revision is an opaque local row nonce, not a content hash or wire version.
    public let id:String,name:String,revision:String,details:RecordingDetails
    let owner:UUID
    public static func ==(a:Self,b:Self)->Bool {
        Data(a.id.utf8)==Data(b.id.utf8) && Data(a.name.utf8)==Data(b.name.utf8) && a.revision==b.revision && a.details==b.details && a.owner==b.owner
    }
}
public extension MemoryStore {
    /// Read value snapshots for explicit editing. Multiple records are exposed
    /// as a conflict; never choose one silently by name, title or timestamp.
    func recordedMeetingDetails(for source:RecordedMeetingSource)throws->[RecordedMeetingDetailsSnapshot] {
        guard source.owner==recordedMeetingOwner else {throw RecordedMeetingRefreshError.changed}
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        return try withRoutineDatabase {db in
            try RecordingDetailsSchema.prepare(db)
            try db.execute("SAVEPOINT recording_details_read")
            do {
                let result=try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {
                    let memory=try recordedMeetingEvidence(source,db:db,policy:snapshot.settings.privacy)
                    return try recordingDetailsRows(scope:recordingDetailsScope(memory),db:db,policy:snapshot.settings.privacy).map {try recordingDetailsSnapshot($0.memory,revision:$0.revision,policy:snapshot.settings.privacy)}
                }
                try db.execute("RELEASE recording_details_read");return result
            }catch {try? db.execute("ROLLBACK TO recording_details_read; RELEASE recording_details_read");throw error}
        }
    }
    /// A metadata edit does not mutate any audio source, recording ID,
    /// transcript, timestamp or clip evidence hash. Optimistic comparison is
    /// inside the writer transaction and current settings-file guard.
    @discardableResult func saveRecordedMeetingName(_ name:String,for source:RecordedMeetingSource,replacing expected:RecordedMeetingDetailsSnapshot?=nil)throws->RecordedMeetingDetailsSnapshot {
        guard source.owner==recordedMeetingOwner,expected.map({$0.owner==recordedMeetingOwner}) ?? true else {throw RecordedMeetingRefreshError.changed}
        let activity=try mediaWriteLease();defer {activity.release()}
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        let result=try withRoutineDatabase {db in
            try SyncChangeCapture.transaction(db) {
                try RecordingDetailsSchema.prepare(db)
                return try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {
                try activity.withActive(for:mediaRootIdentity) {};try Task.checkCancellation()
                let target=try recordedMeetingEvidence(source,db:db,policy:snapshot.settings.privacy),scope=try recordingDetailsScope(target)
                let rows=try recordingDetailsRows(scope:scope,db:db,policy:snapshot.settings.privacy)
                guard rows.count<=1 else {throw OSwindError.unavailable("This recording has multiple saved names. Review the conflicting metadata before editing.")}
                let current=try rows.first.map {try recordingDetailsSnapshot($0.memory,revision:$0.revision,policy:snapshot.settings.privacy)}
                guard current==expected,expected.map({$0.owner==recordedMeetingOwner}) ?? true else {throw RecordedMeetingRefreshError.changed}
                let clean=try RecordingDetails.name(snapshot.settings.privacy.sanitize(RecordingDetails.name(name)).text)
                guard snapshot.settings.privacy.exclusion(app:"com.oswind.desktop",title:clean,url:nil)==nil else {throw OSwindError.unavailable("This recording name is excluded by Privacy")}
                var value=rows.first?.memory ?? Memory(kind:.recordingMetadata,app:"OSwind",bundleID:"com.oswind.desktop",title:clean,text:"User-authored recording name; this label does not establish calendar attendance or transcript contents.")
                if value.title != clean {value.embedding=nil;value.embeddingModel=nil}
                value.title=clean;value.recordingDetails = .init(scope:value.recordingDetails?.scope ?? scope,calendar:value.recordingDetails?.calendar)
                try insert(value);try activity.withActive(for:mediaRootIdentity) {};try Task.checkCancellation()
                return try recordingDetailsSnapshot(value,revision:RecordingDetailsSchema.revision(db,id:value.id),policy:snapshot.settings.privacy)
            }}
        }
        _=finishRecapInvalidation();return result
    }
}
extension MemoryStore {
    private func recordingDetailsScope(_ memory:Memory)throws->RecordingScope {
        if let session=memory.audioSessionID {return try .init(sessionID:session)}
        return try .init(sourceID:memory.id,revision:memory.evidenceHash)
    }
    private func recordingDetailsRows(scope:RecordingScope,db:RoutineDatabase,policy:PrivacyPolicy)throws->[(memory:Memory,revision:String)] {
        let row=try db.statement("SELECT memory_id,revision FROM recorded_meeting_details WHERE selector=? AND scope_id=? COLLATE BINARY AND (? IS NULL OR evidence_revision=?) ORDER BY memory_id COLLATE BINARY LIMIT 129")
        defer {sqlite3_finalize(row)};db.bind(row,1,scope.selector.rawValue);db.bind(row,2,scope.id);db.bind(row,3,scope.revision);db.bind(row,4,scope.revision)
        var values=[(memory:Memory,revision:String)](),code=sqlite3_step(row)
        while code==SQLITE_ROW {
            guard values.count<128,let memory=try get(db.text(row,0)),memory.kind == .recordingMetadata,let details=memory.recordingDetails,RecordingDetails.sameTarget(details.scope,scope) else {throw OSwindError.unavailable("Recording metadata is unavailable or exceeds its review bound")}
            guard policy.exclusion(app:memory.bundleID.isEmpty ? memory.app:memory.bundleID,title:memory.title,url:memory.url)==nil else {throw OSwindError.unavailable("Saved recording metadata is excluded by Privacy")}
            values.append((memory,db.text(row,1)));code=sqlite3_step(row)
        }
        guard code==SQLITE_DONE else {throw db.error()};return values
    }
    private func recordingDetailsSnapshot(_ memory:Memory,revision:String,policy:PrivacyPolicy)throws->RecordedMeetingDetailsSnapshot {
        try memory.validateRecordingDetails();guard let details=memory.recordingDetails else {throw OSwindError.invalid("Recording metadata is missing")}
        return .init(id:memory.id,name:policy.sanitize(memory.title).text,revision:revision,details:details,owner:recordedMeetingOwner)
    }
}
