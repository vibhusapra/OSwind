import Foundation
import CryptoKit
import CSQLite

public struct RecordedMeetingSource:Identifiable,Equatable,Sendable {
    public let memoryID:String,sessionKey:String,title:String,app:String,revision:String
    public var id:String {Self.key(grouped:false,id:memoryID)}
    public let timestamp:Date,observedEnd:Date?,duration:Double
    public var hasObservedInterval:Bool {observedEnd != nil}
    let owner:UUID,grouped:Bool,recordingID:String
    static func key(grouped:Bool,id:String)->String {
        let prefix=grouped ? "recording\u{0}":"single-source\u{0}"
        return SHA256.hash(data:Data(prefix.utf8)+Data(id.utf8)).map {String(format:"%02x",$0)}.joined()
    }
}
public struct RecordedMeetingCursor:Sendable {
    let owner:UUID,timestamp:Double,id:String
}
public struct RecordedMeetingPage:Sendable {
    public let sources:[RecordedMeetingSource]
    public let next:RecordedMeetingCursor?
    public let examined:Int,excluded:Int
    let owner:UUID,settings:AppSettings
}
public struct RecordedMeeting:Identifiable,Equatable,Sendable {
    public let id:String,title:String,sources:[RecordedMeetingSource]
    public var first:Date {sources.map(\.timestamp).min()!}
    public var latest:Date {sources.map {$0.observedEnd ?? $0.timestamp}.max()!}
    public var hasUnobservedTimes:Bool {sources.contains {!$0.hasObservedInterval}}
    /// Union of observed live spans avoids double-counting microphone/system
    /// channels. Gaps remain gaps; import dates do not imply recording times.
    public var observedSeconds:Double {
        let intervals=sources.compactMap {source->DateInterval? in
            guard let end=source.observedEnd,end>source.timestamp else {return nil};return .init(start:source.timestamp,end:end)
        }.sorted {$0.start<$1.start}
        var current:DateInterval?,total=0.0
        for interval in intervals {
            if let prior=current {
                if interval.start<=prior.end {current=DateInterval(start:prior.start,end:max(prior.end,interval.end))}
                else {total+=prior.duration;current=interval}
            }else {current=interval}
        }
        return total+(current?.duration ?? 0)
    }
    public var clipSeconds:Double {sources.reduce(0) {$0+$1.duration}}
}
public enum RecordedMeetingPlanner {
    /// Group only explicit source recording IDs. Similar titles, matching
    /// speaker labels or adjacent timestamps never establish a shared meeting.
    public static func group(_ sources:[RecordedMeetingSource])->[RecordedMeeting] {
        let unique=Dictionary(sources.map {(Data($0.memoryID.utf8),$0)},uniquingKeysWith:{$1})
        let groups=Dictionary(grouping:unique.values,by:\.sessionKey)
        return groups.map {key,values in
            let ordered=values.sorted {$0.timestamp == $1.timestamp ? Data($0.memoryID.utf8).lexicographicallyPrecedes(Data($1.memoryID.utf8)):$0.timestamp<$1.timestamp}
            let titles=Set(ordered.map {Data($0.title.utf8)}.filter {!$0.isEmpty})
            let title=titles.count==1 ? ordered.first(where:{!$0.title.isEmpty})!.title:(ordered.count==1 ? "Untitled recording":"Recording session")
            return RecordedMeeting(id:key,title:title,sources:ordered)
        }.sorted {$0.latest == $1.latest ? $0.id<$1.id:$0.latest>$1.latest}
    }
}
public extension MemoryStore {
    /// Reads a bounded thin metadata page, never a transcript or media file.
    /// Excluded rows still advance the cursor so privacy cannot trap pagination.
    func recordedMeetingPage(before cursor:RecordedMeetingCursor?=nil,limit:Int=512)throws->RecordedMeetingPage {
        guard (1...512).contains(limit),cursor.map({$0.owner==recordedMeetingOwner}) ?? true else {throw OSwindError.invalid("Use a current recording cursor and a page size of 1–512")}
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()};let policy=snapshot.settings.privacy
        return try withRoutineDatabase {db in try db.transaction {try snapshot.withCurrent(root:root,policy:policy) {
            let whereSQL=cursor==nil ? "":"WHERE started<? OR (started=? AND memory_id<?)"
            let row=try db.statement("SELECT memory_id,grouped,recording_id,started,observed_end,duration,title,app,bundle_id,url,revision FROM recorded_meeting_sources \(whereSQL) ORDER BY started DESC,memory_id DESC LIMIT ?")
            defer {sqlite3_finalize(row)}
            if let cursor {sqlite3_bind_double(row,1,cursor.timestamp);sqlite3_bind_double(row,2,cursor.timestamp);db.bind(row,3,cursor.id)}
            sqlite3_bind_int(row,cursor==nil ? 1:4,Int32(limit+1))
            var sources=[RecordedMeetingSource](),examined=0,excluded=0,next:RecordedMeetingCursor?,last:RecordedMeetingCursor?
            var code=sqlite3_step(row)
            while code==SQLITE_ROW {
                try Task.checkCancellation()
                if examined==limit {next=last;break}
                examined+=1
                let id=db.text(row,0),grouped=sqlite3_column_int(row,1)==1,recordingID=db.text(row,2),started=sqlite3_column_double(row,3),duration=sqlite3_column_double(row,5)
                guard started.isFinite,duration.isFinite,duration>=0,duration<=86400 else {throw OSwindError.invalid("Recording metadata needs repair")}
                last = .init(owner:recordedMeetingOwner,timestamp:started,id:id)
                let rawTitle=db.text(row,6),app=db.text(row,7),bundle=db.text(row,8),url=db.optional(row,9)
                if policy.exclusion(app:bundle.isEmpty ? app:bundle,title:rawTitle,url:url) != nil {excluded+=1;code=sqlite3_step(row);continue}
                let end=sqlite3_column_type(row,4)==SQLITE_NULL ? nil:Date(timeIntervalSince1970:sqlite3_column_double(row,4))
                sources.append(.init(memoryID:id,sessionKey:RecordedMeetingSource.key(grouped:grouped,id:recordingID),title:String(policy.sanitize(rawTitle).text.prefix(500)),app:String(policy.sanitize(app).text.prefix(200)),revision:db.text(row,10),timestamp:Date(timeIntervalSince1970:started),observedEnd:end,duration:duration,owner:recordedMeetingOwner,grouped:grouped,recordingID:recordingID))
                code=sqlite3_step(row)
            }
            guard code==SQLITE_DONE || next != nil else {throw db.error()}
            return .init(sources:sources,next:next,examined:examined,excluded:excluded,owner:recordedMeetingOwner,settings:snapshot.settings)
        }}}
    }
    /// A value page retains no file/media handles. Recheck semantic settings at
    /// UI publication under the current settings lock, then release immediately.
    func withCurrentRecordedMeetingPage<T>(_ page:RecordedMeetingPage,_ publish:()throws->T)throws->T {
        guard page.owner==recordedMeetingOwner,!isClosed else {throw OSwindError.unavailable("Refresh recordings in this open library")}
        let current=try LibrarySettingsSnapshot.capture(root:root);defer {current.release()}
        guard current.settings==page.settings else {throw OSwindError.unavailable("Recording privacy or settings changed. Refresh the session list.")}
        return try current.withCurrent(root:root,policy:current.settings.privacy,publish)
    }
    /// References are ephemeral and belong to this exact open store. Metadata
    /// edits, deletion/recreation or regrouping invalidate their row nonce.
    /// Callers route the hydrated source through their normal PII/detail gate.
    func recordedMeetingEvidence(_ source:RecordedMeetingSource)throws->Memory {
        guard source.owner==recordedMeetingOwner else {throw OSwindError.unavailable("Refresh recordings in this library before opening a source")}
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()};let policy=snapshot.settings.privacy
        return try withRoutineDatabase {db in try db.transaction {try snapshot.withCurrent(root:root,policy:policy) {
            let row=try db.statement("SELECT revision FROM recorded_meeting_sources WHERE memory_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,source.memoryID)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==source.revision,let memory=try get(source.memoryID),memory.kind == .audio else {throw OSwindError.unavailable("This recording changed. Refresh before opening it.")}
            let group=memory.audioSessionID != nil,id=memory.audioSessionID ?? memory.id
            guard RecordedMeetingSource.key(grouped:group,id:id)==source.sessionKey,policy.exclusion(app:memory.bundleID.isEmpty ? memory.app:memory.bundleID,title:memory.title,url:memory.url)==nil else {throw OSwindError.unavailable("This recording is no longer in the selected session or privacy scope")}
            return memory
        }}}
    }
}
