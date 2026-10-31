import Foundation
import CSQLite

/// One synchronous, connection-owned transition, never a registry of memories.
/// Ordinary writes have no permit. The UDF is deliberately non-deterministic:
/// the same arguments must not reuse a result across separate scoped writes.
final class SyncIncomingSourceProjection {
    private let lock=NSLock()
    private struct Source {let owner:Data,payload:Data}
    private struct Binding {let owner:Data,handle:Data,oldRevision:Data,newRevision:Data}
    private var source:Source?,binding:Binding?
    private func payload(_ memory:Memory)throws->Data {var value=memory;value.embedding=nil;return try SyncProtocolLimits.encode(value)}
    func permits(_ memory:Memory)throws->Bool {
        lock.lock();let expected=source;lock.unlock()
        guard let expected,expected.owner==Data(memory.id.utf8) else {return false}
        return try expected.payload==payload(memory)
    }
    func withSource<T>(_ memory:Memory,_ body:()throws->T)throws->T {
        let expected=Source(owner:Data(memory.id.utf8),payload:try payload(memory));lock.lock()
        guard source==nil,binding==nil else {lock.unlock();throw OSwindError.invalid("Incoming source projection is already active")};source=expected;lock.unlock()
        defer {lock.lock();source=nil;lock.unlock()};return try body()
    }
    func withBinding<T>(owner:String,handle:String,oldRevision:String,newRevision:String,_ body:()throws->T)throws->T {
        let expected=Binding(owner:Data(owner.utf8),handle:Data(handle.utf8),oldRevision:Data(oldRevision.utf8),newRevision:Data(newRevision.utf8));lock.lock()
        guard source==nil,binding==nil else {lock.unlock();throw OSwindError.invalid("Incoming evidence rebinding is already active")};binding=expected;lock.unlock()
        defer {lock.lock();binding=nil;lock.unlock()};return try body()
    }
    private func permits(owner:Data,payload bytes:Data)->Bool {
        lock.lock();let expected=source;lock.unlock()
        guard let expected,owner==expected.owner,let memory=try? JSONDecoder().decode(Memory.self,from:bytes),Data(memory.id.utf8)==owner else {return false}
        return (try? payload(memory))==expected.payload
    }
    private func permits(table:Data,old:Data,new:Data)->Bool {
        lock.lock();let expected=binding;lock.unlock()
        guard let expected,let before=try? SyncRowSnapshot.decode(old).cells,let after=try? SyncRowSnapshot.decode(new).cells else {return false}
        let recap=table==Data("recap_sources".utf8),count=recap ? 10:9,owner=count-2,handle=count-1
        guard recap || table==Data("chat_sources".utf8),before.count==count,after.count==count,before[1] == .text(expected.owner),before[owner] == .null,before[handle] == .null,after[1] == .null,after[owner] == .text(expected.owner),after[handle] == .text(expected.handle) else {return false}
        var changed:Set<Int>=[1,owner,handle]
        if recap {guard before[3] == .text(expected.oldRevision),after[3] == .text(expected.newRevision) else {return false};changed.insert(3)}
        return before.indices.allSatisfy {changed.contains($0) || before[$0]==after[$0]}
    }
    private static func bytes(_ value:OpaquePointer?,type:Int32,maximum:Int)->Data? {
        guard let value,sqlite3_value_type(value)==type else {return nil};let n=Int(sqlite3_value_bytes(value));guard n>0,n<=maximum else {return nil}
        guard let p=type==SQLITE_BLOB ? sqlite3_value_blob(value):UnsafeRawPointer(sqlite3_value_text(value)) else {return nil};return Data(bytes:p,count:n)
    }
    static func register(_ db:RoutineDatabase,permit:SyncIncomingSourceProjection=SyncIncomingSourceProjection())throws {
        let flags=SQLITE_UTF8|SQLITE_INNOCUOUS
        let source=Unmanaged.passRetained(permit).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_incoming_source_projection_v1",2,flags,source,{context,_,values in
            guard let context,let data=sqlite3_user_data(context),let owner=SyncIncomingSourceProjection.bytes(values?[0],type:SQLITE_TEXT,maximum:1024),let payload=SyncIncomingSourceProjection.bytes(values?[1],type:SQLITE_BLOB,maximum:MemoryStore.maximumRecordBytes) else {sqlite3_result_int(context,0);return}
            sqlite3_result_int(context,Unmanaged<SyncIncomingSourceProjection>.fromOpaque(data).takeUnretainedValue().permits(owner:owner,payload:payload) ? 1:0)
        },nil,nil,{if let p=$0 {Unmanaged<SyncIncomingSourceProjection>.fromOpaque(p).release()}})==SQLITE_OK else {throw db.error()}
        let binding=Unmanaged.passRetained(permit).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_incoming_binding_projection_v1",3,flags,binding,{context,_,values in
            guard let context,let data=sqlite3_user_data(context),let table=SyncIncomingSourceProjection.bytes(values?[0],type:SQLITE_TEXT,maximum:32),let old=SyncIncomingSourceProjection.bytes(values?[1],type:SQLITE_BLOB,maximum:SyncRowSnapshot.maximumBytes),let new=SyncIncomingSourceProjection.bytes(values?[2],type:SQLITE_BLOB,maximum:SyncRowSnapshot.maximumBytes) else {sqlite3_result_int(context,0);return}
            sqlite3_result_int(context,Unmanaged<SyncIncomingSourceProjection>.fromOpaque(data).takeUnretainedValue().permits(table:table,old:old,new:new) ? 1:0)
        },nil,nil,{if let p=$0 {Unmanaged<SyncIncomingSourceProjection>.fromOpaque(p).release()}})==SQLITE_OK else {throw db.error()}
    }
}

enum SyncIncomingSourceSchema {
    static let schemas:[String:String] = {
        var result=[String:String]()
        for table in SyncChangeCapture.tables.map(\.name)+["historical_evidence"] {for operation in ["insert","update","delete"] {
            let name="incoming_source_writer_"+table+"_"+operation
            result[name]="CREATE TRIGGER \(name) BEFORE \(operation.uppercased()) ON \(table) BEGIN SELECT oswind_incoming_source_writer_v1(); END"
        }}
        return result
    }()
    static func register(_ db:RoutineDatabase)throws {
        guard sqlite3_create_function_v2(db.handle,"oswind_incoming_source_writer_v1",0,SQLITE_UTF8|SQLITE_INNOCUOUS|SQLITE_DETERMINISTIC,nil,{context,_,_ in sqlite3_result_int(context,1)},nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
    static func validate(_ db:RoutineDatabase)throws {
        let row=try db.statement("SELECT name,sql FROM sqlite_master WHERE name GLOB 'incoming_source_writer_*'");defer {sqlite3_finalize(row)};var names=Set<String>(),code=sqlite3_step(row)
        while code==SQLITE_ROW {let name=db.text(row,0);guard schemas[name]==db.text(row,1),names.insert(name).inserted else {throw OSwindError.database("Incoming source writer protection differs")};code=sqlite3_step(row)}
        guard code==SQLITE_DONE,names==Set(schemas.keys) else {throw OSwindError.database("Incoming source writer protection is missing")}
    }
    static func install(_ db:RoutineDatabase,sourceVersion:Int32,repairMissingPins:Bool)throws {
        for (name,sql) in schemas.sorted(by:{$0.key<$1.key}) {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name);let code=sqlite3_step(row),old=code==SQLITE_ROW ? db.text(row,0):nil;sqlite3_finalize(row)
            guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
            if let old {guard old==sql else {throw OSwindError.database("Incoming source writer protection differs")}}
            else {guard sourceVersion<28 || (repairMissingPins && name.hasPrefix("incoming_source_writer_text_observation_pins_")) else {throw OSwindError.database("Incoming source writer protection is missing")};try db.execute(sql)}
        }
        try validate(db)
    }
}
