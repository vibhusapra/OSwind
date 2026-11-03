import Foundation
import CSQLite

/// Re-publish existing authenticated history for a later peer without moving
/// the public service head or ordinary sent cursor backwards. No new dot,
/// source body, privacy approval or peer acknowledgement is invented.
enum SyncMembershipReplay {
    static let key="sync-membership-replay-v1"
    struct Cursor:Codable,Equatable {
        let format:String,version:Int,head:String,after:Int64,through:Int64
        init(head:String,after:Int64,through:Int64)throws {
            try SyncProtocolLimits.digest(head)
            guard after>=0,through>0,after<through,through<Int64.max else {throw OSwindError.invalid("Invalid membership replay bounds")}
            format="OSwind.sync.membership-replay";version=1;self.head=head;self.after=after;self.through=through
        }
        func validate()throws {
            guard format=="OSwind.sync.membership-replay",version==1 else {throw OSwindError.invalid("Unsupported membership replay")}
            _=try Self(head:head,after:after,through:through)
        }
    }
    private static func put(_ cursor:Cursor?,_ db:RoutineDatabase)throws {
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Save replay progress with its native checkpoint")}
        if let cursor {
            try cursor.validate();let row=try db.statement("INSERT INTO store_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");defer {sqlite3_finalize(row)}
            db.bind(row,1,key);db.bind(row,2,String(decoding:try SyncProtocolLimits.encode(cursor),as:UTF8.self));try db.done(row)
        }else {let row=try db.statement("DELETE FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,key);try db.done(row)}
    }
    /// Membership application is the only seed/reset boundary. Replaying the
    /// exact native application transaction yields the same initial cursor.
    static func seed(head:String,through:Int64,db:RoutineDatabase)throws {
        guard through>=0,try db.eraseCount("PRAGMA user_version")==36,try SyncNativeMembershipState.read(db)==SyncNativeMembershipState.Value.active(head) else {throw OSwindError.invalid("Seed replay only for the exact activated native membership")}
        try put(through==0 ? nil:Cursor(head:head,after:0,through:through),db)
    }
    static func current(_ db:RoutineDatabase,sent:Int64)throws->Cursor? {
        let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,key)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil}
        guard code==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_TEXT,sqlite3_column_bytes(row,0)>0,sqlite3_column_bytes(row,0)<=2048 else {throw OSwindError.unavailable("Membership replay cursor is missing or exceeds its bound")}
        let cursor=try SyncPairingFormat.decode(Cursor.self,Data(db.text(row,0).utf8),limit:2048);try cursor.validate()
        guard cursor.through<=sent,try db.eraseCount("PRAGMA user_version")==36,try SyncNativeMembershipState.read(db)==SyncNativeMembershipState.Value.active(cursor.head) else {throw OSwindError.unavailable("Membership replay differs from the active native floor")}
        return cursor
    }
    static func advance(_ expected:Cursor?,through:Int64,sent:Int64,db:RoutineDatabase)throws {
        guard let expected else {return}
        guard try current(db,sent:sent)==expected,through>expected.after,through<=sent else {throw OSwindError.unavailable("The exact replay batch did not advance within its published history")}
        if through>=expected.through {try put(nil,db)}
        else {try put(Cursor(head:expected.head,after:through,through:expected.through),db)}
    }
    /// Old replay intent must not survive a logically committed whole erasure.
    /// The caller already owns that retirement's native transaction/checkpoint.
    static func retire(_ db:RoutineDatabase)throws {try put(nil,db)}
}
