import Foundation
import CSQLite
import CryptoKit

/// One connection-owned synchronous native run and provenance write.
final class SyncIncomingRunProjection {
    private let lock=NSLock()
    private var expected:(frame:Data,id:Data,payload:Data,sha:String)?
    func withRun<T>(_ frame:SyncRowSnapshot,payload:Data,_ body:()throws->T)throws->T {
        guard frame.cells.count==11,case .text(let id)=frame.cells[0],payload.count<=RoutineRunOriginal.maximumBytes else {throw OSwindError.invalid("Invalid incoming run projection")}
        let bytes=try frame.encoded(),sha=SyncProtocolLimits.hex(bytes);lock.lock()
        guard expected==nil else {lock.unlock();throw OSwindError.invalid("Incoming run projection is already active")};expected=(bytes,id,payload,sha);lock.unlock()
        defer {lock.lock();expected=nil;lock.unlock()};return try body()
    }
    private func permits(_ frame:Data)->Bool {lock.lock();defer {lock.unlock()};return expected?.frame==frame}
    private func permits(id:Data,payload:Data,sha:Data)->Bool {lock.lock();defer {lock.unlock()};guard let expected else {return false};return expected.id==id && expected.payload==payload && Data(expected.sha.utf8)==sha}
    private static func bytes(_ value:OpaquePointer?,_ type:Int32,_ limit:Int)->Data? {
        guard let value,sqlite3_value_type(value)==type else {return nil};let n=Int(sqlite3_value_bytes(value));guard n>0,n<=limit,let pointer=type==SQLITE_BLOB ? sqlite3_value_blob(value):sqlite3_value_text(value).map(UnsafeRawPointer.init) else {return nil};return Data(bytes:pointer,count:n)
    }
    static func register(_ db:RoutineDatabase,permit:SyncIncomingRunProjection=SyncIncomingRunProjection())throws {
        let flags=SQLITE_UTF8|SQLITE_INNOCUOUS,pointer=Unmanaged.passRetained(permit).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_incoming_run_projection_v1",1,flags,pointer,{context,_,values in
            guard let context,let owner=sqlite3_user_data(context),let frame=SyncIncomingRunProjection.bytes(values?[0],SQLITE_BLOB,RoutineRunOriginal.maximumBytes) else {sqlite3_result_int(context,0);return};sqlite3_result_int(context,Unmanaged<SyncIncomingRunProjection>.fromOpaque(owner).takeUnretainedValue().permits(frame) ? 1:0)
        },nil,nil,{if let p=$0 {Unmanaged<SyncIncomingRunProjection>.fromOpaque(p).release()}})==SQLITE_OK else {throw db.error()}
        let original=Unmanaged.passRetained(permit).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_incoming_run_original_v1",3,flags,original,{context,_,values in
            guard let context,let owner=sqlite3_user_data(context),let id=SyncIncomingRunProjection.bytes(values?[0],SQLITE_TEXT,1024),let payload=SyncIncomingRunProjection.bytes(values?[1],SQLITE_BLOB,RoutineRunOriginal.maximumBytes),let sha=SyncIncomingRunProjection.bytes(values?[2],SQLITE_TEXT,64) else {sqlite3_result_int(context,0);return};sqlite3_result_int(context,Unmanaged<SyncIncomingRunProjection>.fromOpaque(owner).takeUnretainedValue().permits(id:id,payload:payload,sha:sha) ? 1:0)
        },nil,nil,{if let p=$0 {Unmanaged<SyncIncomingRunProjection>.fromOpaque(p).release()}})==SQLITE_OK else {throw db.error()}
        guard sqlite3_create_function_v2(db.handle,"oswind_sync_run_fingerprint_v1",1,flags|SQLITE_DETERMINISTIC,nil,{context,_,values in
            guard let context,let data=SyncIncomingRunProjection.bytes(values?[0],SQLITE_BLOB,RoutineRunOriginal.maximumBytes),let frame=try? SyncRowSnapshot.decode(data),frame.cells.count==11 else {sqlite3_result_error(context,"Invalid native run frame",-1);return};let sha=SyncProtocolLimits.hex(data);sha.withCString {sqlite3_result_text(context,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
        },nil,nil,nil)==SQLITE_OK else {throw db.error()}
        guard sqlite3_create_function_v2(db.handle,"oswind_run_original_writer_v1",0,flags|SQLITE_DETERMINISTIC,nil,{context,_,_ in sqlite3_result_int(context,1)},nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
}
