import Foundation
import CSQLite

/// Device calendar receipt metadata has no titles, links or participant data.
/// A library wipe removes the dedicated authorization token and receipt row.
/// Claims are at-most-once notification attempts, not proof of OS delivery.
private struct MeetingReminderLedger:Codable,Equatable {
    struct Receipt:Codable,Equatable {let attempted:Date;let expires:Date}
    let version:Int
    let library:String
    var receipts:[String:Receipt]
    static let key="meeting-reminder-receipts-v1"
    static let maximum=512
    func validate()throws {
        guard version==1,MeetingIdentity.isHex(library,bytes:32),receipts.count<=Self.maximum else {throw OSwindError.invalid("Meeting reminder receipts are invalid; reminders stay paused.")}
        for (key,value) in receipts {
            guard MeetingIdentity.isHex(key,bytes:64),value.attempted.timeIntervalSinceReferenceDate.isFinite,value.expires.timeIntervalSinceReferenceDate.isFinite,value.expires>value.attempted,value.expires.timeIntervalSince(value.attempted)<=8*86400 else {throw OSwindError.invalid("Meeting reminder receipt is invalid; reminders stay paused.")}
        }
    }
}
extension MemoryStore {
    /// Read without creating authorization. The general store identity is a
    /// mutable cache epoch, so it cannot bind a calendar selection.
    public func meetingLibraryIdentity()throws->String? {
        try Task.checkCancellation();try validateDirectoryIdentity()
        return try withRoutineDatabase {db in try Self.meetingIdentity(db)}
    }
    private static func meetingText(_ row:OpaquePointer,limit:Int)throws->String {
        let count=Int(sqlite3_column_bytes(row,0))
        guard sqlite3_column_type(row,0)==SQLITE_TEXT,count<=limit,let pointer=sqlite3_column_text(row,0),let text=String(data:Data(bytes:pointer,count:count),encoding:.utf8),!text.utf8.contains(0) else {throw OSwindError.invalid("Calendar authorization or reminder metadata is malformed.")}
        return text
    }
    private static func meetingIdentity(_ db:RoutineDatabase)throws->String? {
        let row=try db.statement("SELECT value FROM store_metadata WHERE key='meeting-library-lifetime-v1'");defer {sqlite3_finalize(row)}
        let status=sqlite3_step(row);if status==SQLITE_DONE {return nil}
        guard status==SQLITE_ROW else {throw db.error()}
        let identity=try meetingText(row,limit:32);guard MeetingIdentity.isHex(identity,bytes:32) else {throw OSwindError.database("Calendar library authorization is invalid.")};return identity
    }
    /// Called only on an explicit selection, never by background startup/read.
    /// Stable across ordinary edits and reopening; wipe removes it atomically.
    public func authorizeMeetingLibrary()throws->String {
        let activity=try mediaWriteLease();defer {activity.release()}
        return try withRoutineDatabase {db in
            try activity.withActive(for:mediaRootIdentity) {}
            let prior=try db.eraseCount("PRAGMA synchronous");if prior<2 {try db.execute("PRAGMA synchronous=FULL")}
            defer {if prior<2 {try? db.execute("PRAGMA synchronous=\(prior)")}}
            return try SyncChangeCapture.transaction(db) {
                if let identity=try Self.meetingIdentity(db) {return identity}
                let identity=UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:"")
                let row=try db.statement("INSERT INTO store_metadata(key,value) VALUES('meeting-library-lifetime-v1',?)");defer {sqlite3_finalize(row)};db.bind(row,1,identity);try db.done(row)
                try activity.withActive(for:mediaRootIdentity) {};try Task.checkCancellation();return identity
            }
        }
    }
    /// Claim one bounded due group before the UI or OS notification attempt.
    /// Competing connections share SQLite's write transaction. FULL durability
    /// is scoped to this short transaction and restores the prior connection mode.
    public func claimMeetingReminders(_ events:[MeetingOccurrence],configuration:MeetingContextConfiguration,expectedLibrary:String,now:Date)throws->[String] {
        try configuration.validate()
        guard configuration.reminders,configuration.admits(libraryIdentity:expectedLibrary),events.count<=32,now.timeIntervalSinceReferenceDate.isFinite else {throw OSwindError.invalid("Meeting reminders are disabled or their batch exceeds 32 occurrences.")}
        guard !events.isEmpty else {return []}
        let activity=try mediaWriteLease();defer {activity.release()}
        return try withRoutineDatabase {db in
            try activity.withActive(for:mediaRootIdentity) {}
            let prior=try db.eraseCount("PRAGMA synchronous")
            if prior<2 {try db.execute("PRAGMA synchronous=FULL")}
            defer {if prior<2 {try? db.execute("PRAGMA synchronous=\(prior)")}}
            return try SyncChangeCapture.transaction(db) {
                guard try Self.meetingIdentity(db)==expectedLibrary else {throw OSwindError.unavailable("The library changed. Review Calendar before resuming reminders.")}
                var ledger=MeetingReminderLedger(version:1,library:expectedLibrary,receipts:[:])
                let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");db.bind(row,1,MeetingReminderLedger.key)
                do {
                    let status=sqlite3_step(row)
                    if status==SQLITE_ROW {
                        let text=try Self.meetingText(row,limit:160*1024)
                        let stored=try JSONDecoder().decode(MeetingReminderLedger.self,from:Data(text.utf8));try stored.validate()
                        // A completed wipe/new restore has a new identity. The
                        // caller still needs a freshly bound explicit selection.
                        if stored.library==expectedLibrary {ledger=stored}
                    }else if status != SQLITE_DONE {throw db.error()}
                    sqlite3_finalize(row)
                }catch {sqlite3_finalize(row);throw error}
                let before=ledger
                ledger.receipts=ledger.receipts.filter {$0.value.expires>now}
                var claimed=[String]()
                for event in events {
                    try Task.checkCancellation()
                    guard configuration.containsCalendar(event.calendarID),!event.allDay,!event.cancelled,!event.declined,event.start.addingTimeInterval(-Double(configuration.leadMinutes)*60)<=now,now<=event.start.addingTimeInterval(120) else {throw OSwindError.invalid("Use only currently due, selected calendar occurrences.")}
                    let key=event.reminderKey(leadMinutes:configuration.leadMinutes)
                    guard ledger.receipts[key]==nil else {continue}
                    guard ledger.receipts.count<MeetingReminderLedger.maximum else {throw OSwindError.unavailable("Meeting reminder history is full. Reminders stay paused until older receipts expire.")}
                    ledger.receipts[key] = .init(attempted:now,expires:now.addingTimeInterval(7*86400));claimed.append(key)
                }
                guard ledger != before else {return claimed}
                try ledger.validate();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let data=try encoder.encode(ledger)
                guard data.count<=160*1024 else {throw OSwindError.invalid("Meeting reminder history exceeds its storage bound.")}
                let save=try db.statement("INSERT INTO store_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");defer {sqlite3_finalize(save)}
                db.bind(save,1,MeetingReminderLedger.key);db.bind(save,2,String(decoding:data,as:UTF8.self));try db.done(save)
                try activity.withActive(for:mediaRootIdentity) {};try Task.checkCancellation();return claimed
            }
        }
    }
}
