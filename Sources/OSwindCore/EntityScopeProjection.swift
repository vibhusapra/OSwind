import Foundation
import CSQLite

/// One exact connection-owned narrowing of a turn's saved entity scope.
/// Other payload changes retain ordinary cached-version invalidation.
final class EntityScopeProjection {
    private let lock=NSLock()
    private var expected:(before:Data,after:Data)?
    func withTurn<T>(before:SyncRowSnapshot,after:SyncRowSnapshot,_ body:()throws->T)throws->T {
        guard before.cells.count==4,after.cells.count==4,before.cells.prefix(3)==after.cells.prefix(3),case .blob(let a)=before.cells[3],case .blob(let b)=after.cells[3] else {throw OSwindError.invalid("Invalid scoped turn transition")}
        let original=try JSONDecoder().decode(ChatPayload.self,from:a);var restored=try JSONDecoder().decode(ChatPayload.self,from:b)
        guard original.filter.entityID != nil,original.filter.unavailableEntityScope==nil,restored.filter.entityID==nil,restored.filter.unavailableEntityScope != nil else {throw OSwindError.invalid("Only an active entity restriction can become unavailable")}
        restored.filter.entityID=original.filter.entityID;restored.filter.unavailableEntityScope=nil
        guard try SyncProtocolLimits.encode(restored)==SyncProtocolLimits.encode(original) else {throw OSwindError.invalid("Scope retirement cannot change other turn fields")}
        let pair=(before:try before.encoded(),after:try after.encoded());lock.lock()
        guard expected==nil else {lock.unlock();throw OSwindError.invalid("Entity scope projection is already active")};expected=pair;lock.unlock()
        defer {lock.lock();expected=nil;lock.unlock()};return try body()
    }
    private func permits(before:Data,after:Data)->Bool {lock.lock();defer {lock.unlock()};return expected?.before==before && expected?.after==after}
    static func register(_ db:RoutineDatabase,permit:EntityScopeProjection?=nil)throws {
        if permit==nil {
            let row=try db.statement("SELECT 1 FROM pragma_function_list WHERE name='oswind_unavailable_scope_projection_v1' LIMIT 1");defer {sqlite3_finalize(row)}
            let code=sqlite3_step(row);if code==SQLITE_ROW {return};guard code==SQLITE_DONE else {throw db.error()}
        }
        let pointer=Unmanaged.passRetained(permit ?? EntityScopeProjection()).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_unavailable_scope_projection_v1",2,SQLITE_UTF8|SQLITE_INNOCUOUS,pointer,{context,_,values in
            guard let context,let pointer=sqlite3_user_data(context) else {sqlite3_result_int(context,0);return}
            func data(_ index:Int)->Data? {
                guard let value=values?[index],sqlite3_value_type(value)==SQLITE_BLOB else {return nil};let count=Int(sqlite3_value_bytes(value));guard count>0,count<=SyncRowSnapshot.maximumBytes,let p=sqlite3_value_blob(value) else {return nil};return Data(bytes:p,count:count)
            }
            guard let before=data(0),let after=data(1) else {sqlite3_result_int(context,0);return}
            sqlite3_result_int(context,Unmanaged<EntityScopeProjection>.fromOpaque(pointer).takeUnretainedValue().permits(before:before,after:after) ? 1:0)
        },nil,nil,{if let p=$0 {Unmanaged<EntityScopeProjection>.fromOpaque(p).release()}})==SQLITE_OK else {throw db.error()}
    }
}
