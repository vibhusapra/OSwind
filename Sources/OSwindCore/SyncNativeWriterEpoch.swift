import Foundation
import CSQLite

/// A nonsecret native writer generation. Unlike the delivery token, this does
/// not refresh implicitly on existing writers: retirement requires reopening.
/// Persistent SQL compares it even for statements prepared before retirement.
final class SyncNativeWriterEpoch {
    static let table="personal_sync_native_writer_epoch"
    private static let schema="CREATE TABLE personal_sync_native_writer_epoch(singleton INTEGER PRIMARY KEY CHECK(singleton=1),epoch TEXT NOT NULL CHECK(length(epoch)=32 AND epoch NOT GLOB '*[^0-9a-f]*'))"
    private static let hooks:[String:String]=[
        "sync_native_epoch_retained":"CREATE TRIGGER sync_native_epoch_retained BEFORE DELETE ON personal_sync_native_writer_epoch BEGIN SELECT RAISE(ABORT,'Retain native writer generation'); END",
        "sync_native_epoch_transition":"CREATE TRIGGER sync_native_epoch_transition BEFORE UPDATE ON personal_sync_native_writer_epoch WHEN new.singleton<>old.singleton OR oswind_native_sync_epoch_change_v1(old.epoch,new.epoch)<>1 BEGIN SELECT RAISE(ABORT,'Native writer generation requires its retirement owner'); END"
    ]
    static let guardCondition="(SELECT epoch FROM personal_sync_native_writer_epoch WHERE singleton=1) IS NOT oswind_native_sync_epoch_v1()"
    private let lock=NSLock()
    private var expected:String?,transition:(String,String)?
    func register(_ db:RoutineDatabase)throws {
        let current=Unmanaged.passRetained(self).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_native_sync_epoch_v1",0,SQLITE_UTF8|SQLITE_INNOCUOUS,current,{context,_,_ in
            guard let context,let pointer=sqlite3_user_data(context) else {return}
            let owner=Unmanaged<SyncNativeWriterEpoch>.fromOpaque(pointer).takeUnretainedValue()
            owner.lock.lock();let value=owner.expected;owner.lock.unlock()
            guard let value else {sqlite3_result_null(context);return}
            value.withCString {sqlite3_result_text(context,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
        },nil,nil,{if let p=$0 {Unmanaged<SyncNativeWriterEpoch>.fromOpaque(p).release()}})==SQLITE_OK else {throw db.error()}
        let changing=Unmanaged.passRetained(self).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_native_sync_epoch_change_v1",2,SQLITE_UTF8|SQLITE_INNOCUOUS,changing,{context,_,values in
            guard let context,let pointer=sqlite3_user_data(context) else {return}
            func text(_ index:Int)->String? {
                guard let value=values?[index],sqlite3_value_type(value)==SQLITE_TEXT,sqlite3_value_bytes(value)==32,let bytes=sqlite3_value_text(value) else {return nil}
                return String(decoding:UnsafeBufferPointer(start:bytes,count:32),as:UTF8.self)
            }
            let owner=Unmanaged<SyncNativeWriterEpoch>.fromOpaque(pointer).takeUnretainedValue()
            owner.lock.lock();let pending=owner.transition;owner.lock.unlock()
            sqlite3_result_int(context,pending != nil && text(0)==pending?.0 && text(1)==pending?.1 ? 1:0)
        },nil,nil,{if let p=$0 {Unmanaged<SyncNativeWriterEpoch>.fromOpaque(p).release()}})==SQLITE_OK else {throw db.error()}
    }
    func install(_ db:RoutineDatabase)throws {
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Install writer generation with native admission")}
        guard try db.eraseCount("SELECT COUNT(*) FROM sqlite_master WHERE name='personal_sync_native_writer_epoch'")==0 else {throw OSwindError.invalid("Preserve the existing native writer generation")}
        try db.execute(Self.schema)
        try db.execute("INSERT INTO personal_sync_native_writer_epoch VALUES(1,lower(hex(randomblob(16))))")
        for sql in Self.hooks.values {try db.execute(sql)}
        try adopt(db)
    }
    func validate(_ db:RoutineDatabase)throws {
        for (name,sql) in Self.hooks.merging([Self.table:Self.schema],uniquingKeysWith:{$1}) {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.unavailable("Native writer generation protection changed; use recovery")}
        }
        _=try read(db)
    }
    private func read(_ db:RoutineDatabase)throws->String {
        let row=try db.statement("SELECT epoch,(SELECT COUNT(*) FROM personal_sync_native_writer_epoch) FROM personal_sync_native_writer_epoch WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_int(row,1)==1 else {throw OSwindError.unavailable("Native writer generation is missing; use recovery")}
        let value=db.text(row,0)
        guard value.utf8.count==32,value.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw OSwindError.invalid("Invalid native writer generation")}
        return value
    }
    /// Only after external admission, or a verified rollback of this owner's
    /// transaction. Ordinary operations must never adopt a changed generation.
    func adopt(_ db:RoutineDatabase)throws {let value=try read(db);lock.lock();expected=value;lock.unlock()}
    func requireCurrent(_ db:RoutineDatabase)throws {
        let value=try read(db);lock.lock();let current=expected;lock.unlock()
        guard current==value else {throw OSwindError.unavailable("Native history retired this writer. Reopen the library before writing again.")}
    }
    func rotate(_ db:RoutineDatabase)throws {
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Rotate writers in the owning retirement transaction")}
        try requireCurrent(db)
        let old=try read(db),next=UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:"")
        lock.lock();let available=transition==nil;if available {transition=(old,next)};lock.unlock()
        guard available else {throw OSwindError.invalid("A native writer transition is already active")}
        defer {lock.lock();transition=nil;lock.unlock()}
        let row=try db.statement("UPDATE personal_sync_native_writer_epoch SET epoch=? WHERE singleton=1 AND epoch=?");defer {sqlite3_finalize(row)}
        db.bind(row,1,next);db.bind(row,2,old);try db.done(row)
        guard sqlite3_changes(db.handle)==1 else {throw OSwindError.unavailable("Native writer generation changed during retirement")}
        lock.lock();expected=next;lock.unlock()
    }
}
