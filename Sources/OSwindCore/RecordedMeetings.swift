import Foundation
import CryptoKit
import CSQLite

public struct RecordedMeetingSource:Identifiable,Equatable,Sendable {
    public let memoryID:String,sessionKey:String,title:String,app:String,revision:String,id:String
    public let timestamp:Date,observedEnd:Date?,duration:Double
    public var belongsToSession:Bool {grouped}
    public var hasObservedInterval:Bool {observedEnd != nil}
    let owner:UUID,grouped:Bool,recordingID:String
    init(memoryID:String,sessionKey:String,title:String,app:String,revision:String,timestamp:Date,observedEnd:Date?,duration:Double,owner:UUID,grouped:Bool,recordingID:String) {
        self.memoryID=memoryID;self.sessionKey=sessionKey;self.title=title;self.app=app;self.revision=revision;self.id=Self.key(grouped:false,id:memoryID)
        self.timestamp=timestamp;self.observedEnd=observedEnd;self.duration=duration;self.owner=owner;self.grouped=grouped;self.recordingID=recordingID
    }
    static func key(grouped:Bool,id:String)->String {
        let prefix=grouped ? "recording\u{0}":"single-source\u{0}"
        let digest=SHA256.hash(data:Data(prefix.utf8)+Data(id.utf8)),digits=Array("0123456789abcdef".utf8)
        var bytes=[UInt8]();bytes.reserveCapacity(64)
        for byte in digest {bytes.append(digits[Int(byte>>4)]);bytes.append(digits[Int(byte&15)])}
        return String(decoding:bytes,as:UTF8.self)
    }
}
public struct RecordedMeetingCursor:Sendable {
    let owner:UUID,timestamp:Double,id:String
}
public enum RecordedMeetingRefreshError:Error {case changed,busy}
public struct RecordedMeetingRevision:Equatable,Sendable {
    let owner:UUID,value:String
    let settings:AppSettings
    public func hasSamePrivacy(as other:Self)->Bool {settings.privacy==other.settings.privacy}
}
public struct RecordedMeetingWindow:Sendable {
    public let pages:[RecordedMeetingPage]
    public let retained:[RecordedMeetingSource]
}
public struct RecordedMeetingPage:Sendable {
    public let sources:[RecordedMeetingSource]
    public let next:RecordedMeetingCursor?
    public let examined:Int,excluded:Int
    public let revision:RecordedMeetingRevision
    let owner:UUID,settings:AppSettings
}
public struct RecordedMeeting:Identifiable,Equatable,Sendable {
    public let id:String,title:String,sources:[RecordedMeetingSource]
    public let first:Date,latest:Date
    public let hasUnobservedTimes:Bool,observedSeconds:Double,clipSeconds:Double
    init(id:String,title:String,sources:[RecordedMeetingSource]) {
        precondition(!sources.isEmpty)
        self.id=id;self.title=title;self.sources=sources
        first=sources.map(\.timestamp).min()!
        latest=sources.map {$0.observedEnd ?? $0.timestamp}.max()!
        hasUnobservedTimes=sources.contains {!$0.hasObservedInterval}
        observedSeconds=Self.coveredSeconds(in:sources)
        clipSeconds=sources.reduce(0) {$0+$1.duration}
    }
    /// Union of observed live spans avoids double-counting microphone/system
    /// channels. Gaps remain gaps; import dates do not imply recording times.
    private static func coveredSeconds(in sources:[RecordedMeetingSource])->Double {
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
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        return try withRoutineDatabase {db in
            try RecordedMeetingReader.prepare(db)
            return try RecordedMeetingReader.snapshot(db) {try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {
                let revision=try RecordedMeetingRevisionSchema.read(db,owner:recordedMeetingOwner,settings:snapshot.settings)
                return try RecordedMeetingReader.page(db,cursor:cursor,limit:limit,owner:recordedMeetingOwner,settings:snapshot.settings,revision:revision)
            }}
        }
    }
    /// Reread the same bounded page budget from the current head. Preserve
    /// selected source references by re-reading their thin rows, never reusing
    /// old values. The cursor covers the contiguous head window: pinned older
    /// selection rows do not skip the unexamined gap during later pagination.
    func recordedMeetingWindow(pages:Int,retaining references:[RecordedMeetingSource])throws->RecordedMeetingWindow {
        guard pages>0,references.allSatisfy({$0.owner==recordedMeetingOwner}) else {throw OSwindError.invalid("Refresh a current recording window")}
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        return try withRoutineDatabase {db in
            try RecordedMeetingReader.prepare(db)
            return try RecordedMeetingReader.snapshot(db) {
                let revision=try RecordedMeetingRevisionSchema.read(db,owner:recordedMeetingOwner,settings:snapshot.settings)
                var result=[RecordedMeetingPage](),cursor:RecordedMeetingCursor?,known=[String:RecordedMeetingSource]()
                for _ in 0..<pages {
                    try Task.checkCancellation()
                    let page=try RecordedMeetingReader.page(db,cursor:cursor,limit:512,owner:recordedMeetingOwner,settings:snapshot.settings,revision:revision)
                    result.append(page);for source in page.sources {known[source.id]=source};cursor=page.next;if cursor==nil {break}
                }
                var retained=[RecordedMeetingSource](),seen=Set<String>()
                // Each reference contains only an opaque source ID. A changed
                // row may move to a different group or disappear entirely.
                for ref in references {
                    try Task.checkCancellation()
                    guard seen.insert(ref.id).inserted else {continue}
                    if let current=known[ref.id] {retained.append(current)}
                    else {retained += try RecordedMeetingReader.source(db,id:ref.memoryID,owner:recordedMeetingOwner,settings:snapshot.settings)}
                }
                return try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {.init(pages:result,retained:retained)}
            }
        }
    }
    func recordedMeetingRevision()throws->RecordedMeetingRevision {
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        return try withRoutineDatabase {db in try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {
            try RecordedMeetingRevisionSchema.read(db,owner:recordedMeetingOwner,settings:snapshot.settings)
        }}
    }
    /// Publish separately prepared name values only at their exact revision.
    /// This is a nonwaiting, read-only admission check for the main actor.
    func withCurrentRecordedMeetingRevision<T>(_ revision:RecordedMeetingRevision,_ publish:()throws->T)throws->T {
        guard revision.owner==recordedMeetingOwner else {throw RecordedMeetingRefreshError.changed}
        let current=try LibrarySettingsSnapshot.capture(root:root,waitForLock:false);defer {current.release()}
        guard current.settings==revision.settings else {throw RecordedMeetingRefreshError.changed}
        return try withAvailableRoutineSnapshot {db in
            guard try RecordedMeetingRevisionSchema.read(db,owner:recordedMeetingOwner,settings:current.settings)==revision else {throw RecordedMeetingRefreshError.changed}
            return try current.withCurrent(root:root,policy:current.settings.privacy,waitForLock:false,publish)
        }
    }
    /// A value page retains no file/media handles. Recheck semantic settings at
    /// UI publication under a nonwaiting, read-only SQL/settings snapshot.
    /// Freshness is as of that read; a later commit is a subsequent change.
    /// The callback must not write to this library.
    func withCurrentRecordedMeetingPage<T>(_ page:RecordedMeetingPage,_ publish:()throws->T)throws->T {
        guard page.owner==recordedMeetingOwner else {throw OSwindError.unavailable("Refresh recordings in this open library")}
        let current=try LibrarySettingsSnapshot.capture(root:root,waitForLock:false);defer {current.release()}
        guard current.settings==page.settings else {throw OSwindError.unavailable("Recording privacy or settings changed. Refresh the session list.")}
        return try withAvailableRoutineSnapshot {db in
            guard try RecordedMeetingRevisionSchema.read(db,owner:recordedMeetingOwner,settings:current.settings)==page.revision else {throw RecordedMeetingRefreshError.changed}
            return try current.withCurrent(root:root,policy:current.settings.privacy,waitForLock:false,publish)
        }
    }
    /// References are ephemeral and belong to this exact open store. Metadata
    /// edits, deletion/recreation or regrouping invalidate their row nonce.
    /// Callers route the hydrated source through their normal PII/detail gate.
    func recordedMeetingEvidence(_ source:RecordedMeetingSource)throws->Memory {
        guard source.owner==recordedMeetingOwner else {throw OSwindError.unavailable("Refresh recordings in this library before opening a source")}
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()};let policy=snapshot.settings.privacy
        return try withRoutineDatabase {db in try db.transaction {try snapshot.withCurrent(root:root,policy:policy) {
            try recordedMeetingEvidence(source,db:db,policy:policy)
        }}}
    }
    internal func recordedMeetingEvidence(_ source:RecordedMeetingSource,db:RoutineDatabase,policy:PrivacyPolicy)throws->Memory {
        guard source.owner==recordedMeetingOwner else {throw OSwindError.unavailable("Refresh recordings in this library before opening a source")}
            let row=try db.statement("SELECT revision FROM recorded_meeting_sources WHERE memory_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,source.memoryID)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==source.revision,let memory=try get(source.memoryID),memory.kind == .audio else {throw OSwindError.unavailable("This recording changed. Refresh before opening it.")}
            let group=memory.audioSessionID != nil,id=memory.audioSessionID ?? memory.id
            guard RecordedMeetingSource.key(grouped:group,id:id)==source.sessionKey,policy.exclusion(app:memory.bundleID.isEmpty ? memory.app:memory.bundleID,title:memory.title,url:memory.url)==nil else {throw OSwindError.unavailable("This recording is no longer in the selected session or privacy scope")}
            return memory
    }
}

private enum RecordedMeetingReader {
    static let columns="memory_id,grouped,recording_id,started,observed_end,duration,title,app,bundle_id,url,revision"
    static func prepare(_ db:RoutineDatabase)throws {
        try RecordingDetailsSchema.prepare(db)
        let row=try db.statement("SELECT value FROM store_metadata WHERE key='recorded_meeting_index_version'")
        let ready=sqlite3_step(row)==SQLITE_ROW && db.text(row,0)==RecordedMeetingSchema.currentVersion;sqlite3_finalize(row)
        if !ready {try db.transaction {try RecordedMeetingSchema.populateIfNeeded(db)}}
    }
    static func snapshot<T>(_ db:RoutineDatabase,_ read:()throws->T)throws->T {
        try db.execute("SAVEPOINT recording_metadata_read")
        do {let value=try read();try db.execute("RELEASE recording_metadata_read");return value}
        catch {try? db.execute("ROLLBACK TO recording_metadata_read");try? db.execute("RELEASE recording_metadata_read");throw error}
    }
    static func page(_ db:RoutineDatabase,cursor:RecordedMeetingCursor?,limit:Int,owner:UUID,settings:AppSettings,revision:RecordedMeetingRevision)throws->RecordedMeetingPage {
        let whereSQL=cursor==nil ? "":"WHERE started<? OR (started=? AND memory_id<?)"
        let row=try db.statement("SELECT "+columns+" FROM recorded_meeting_sources \(whereSQL) ORDER BY started DESC,memory_id DESC LIMIT ?")
        defer {sqlite3_finalize(row)}
        if let cursor {sqlite3_bind_double(row,1,cursor.timestamp);sqlite3_bind_double(row,2,cursor.timestamp);db.bind(row,3,cursor.id)}
        sqlite3_bind_int(row,cursor==nil ? 1:4,Int32(limit+1))
        var sources=[RecordedMeetingSource](),examined=0,excluded=0,next:RecordedMeetingCursor?,last:RecordedMeetingCursor?
        var code=sqlite3_step(row)
        while code==SQLITE_ROW {
            try Task.checkCancellation()
            if examined==limit {next=last;break}
            examined+=1
            last = .init(owner:owner,timestamp:sqlite3_column_double(row,3),id:db.text(row,0))
            if let source=try source(row,db:db,owner:owner,settings:settings) {sources.append(source)}else {excluded+=1}
            code=sqlite3_step(row)
        }
        guard code==SQLITE_DONE || next != nil else {throw db.error()}
        return .init(sources:sources,next:next,examined:examined,excluded:excluded,revision:revision,owner:owner,settings:settings)
    }
    static func source(_ row:OpaquePointer,db:RoutineDatabase,owner:UUID,settings:AppSettings)throws->RecordedMeetingSource? {
        let id=db.text(row,0),grouped=sqlite3_column_int(row,1)==1,recordingID=db.text(row,2),started=sqlite3_column_double(row,3),duration=sqlite3_column_double(row,5)
        guard started.isFinite,duration.isFinite,duration>=0,duration<=86400 else {throw OSwindError.invalid("Recording metadata needs repair")}
        let rawTitle=db.text(row,6),app=db.text(row,7),bundle=db.text(row,8),url=db.optional(row,9),policy=settings.privacy
        guard policy.exclusion(app:bundle.isEmpty ? app:bundle,title:rawTitle,url:url)==nil else {return nil}
        let end=sqlite3_column_type(row,4)==SQLITE_NULL ? nil:Date(timeIntervalSince1970:sqlite3_column_double(row,4))
        return .init(memoryID:id,sessionKey:RecordedMeetingSource.key(grouped:grouped,id:recordingID),title:String(policy.sanitize(rawTitle).text.prefix(500)),app:String(policy.sanitize(app).text.prefix(200)),revision:db.text(row,10),timestamp:Date(timeIntervalSince1970:started),observedEnd:end,duration:duration,owner:owner,grouped:grouped,recordingID:recordingID)
    }
    static func source(_ db:RoutineDatabase,id:String,owner:UUID,settings:AppSettings)throws->[RecordedMeetingSource] {
        let row=try db.statement("SELECT "+columns+" FROM recorded_meeting_sources WHERE memory_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return []};guard code==SQLITE_ROW else {throw db.error()}
        return try source(row,db:db,owner:owner,settings:settings).map {[$0]} ?? []
    }
}
