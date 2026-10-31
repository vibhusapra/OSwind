import Foundation
import CSQLite

/// Grants only the reviewed core erasure operation on its owning connection.
/// No caller-supplied SQL or policy/media callback runs while it is active.
final class SyncIncomingSourceErasure {
    private let lock=NSLock()
    private var connection:OpaquePointer?,active=false
    private func bind(_ db:RoutineDatabase)throws {
        lock.lock();defer {lock.unlock()}
        guard !active,connection==nil || connection==db.handle else {throw OSwindError.invalid("Source erasure permit belongs to another connection")};connection=db.handle
    }
    private func permitted()->Bool {lock.lock();defer {lock.unlock()};return active}
    func eraseSelected(_ db:RoutineDatabase,revokingObject:String)throws->RoutineDatabase.ErasedCounts {
        lock.lock();guard connection==db.handle,!active else {lock.unlock();throw OSwindError.invalid("Source erasure is already active or belongs to another connection")};active=true;lock.unlock()
        defer {lock.lock();active=false;lock.unlock()}
        return try db.eraseSelectedHistory(revokingObject:revokingObject)
    }
    static func register(_ db:RoutineDatabase,permit:SyncIncomingSourceErasure=SyncIncomingSourceErasure())throws {
        try permit.bind(db);let pointer=Unmanaged.passRetained(permit).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_incoming_source_erasure_v1",0,SQLITE_UTF8|SQLITE_INNOCUOUS,pointer,{context,_,_ in
            guard let context,let pointer=sqlite3_user_data(context) else {sqlite3_result_int(context,0);return}
            sqlite3_result_int(context,Unmanaged<SyncIncomingSourceErasure>.fromOpaque(pointer).takeUnretainedValue().permitted() ? 1:0)
        },nil,nil,{if let p=$0 {Unmanaged<SyncIncomingSourceErasure>.fromOpaque(p).release()}})==SQLITE_OK else {throw db.error()}
    }
}

enum SyncIncomingSourceErasureSchema {
    static let schemas:[String:String] = {
        var result=[String:String]()
        for table in SyncChangeCapture.tables.map(\.name)+["historical_evidence",RoutineRunOriginalSchema.table] {for operation in ["insert","update","delete"] {
            let name="source_erasure_writer_"+table+"_"+operation
            result[name]="CREATE TRIGGER \(name) BEFORE \(operation.uppercased()) ON \(table) BEGIN SELECT oswind_source_erasure_writer_v1(); END"
        }};return result
    }()
    static func register(_ db:RoutineDatabase)throws {
        guard sqlite3_create_function_v2(db.handle,"oswind_source_erasure_writer_v1",0,SQLITE_UTF8|SQLITE_INNOCUOUS|SQLITE_DETERMINISTIC,nil,{context,_,_ in sqlite3_result_int(context,1)},nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
    static func validateSourceTransition(_ db:RoutineDatabase,sourceVersion:Int32)throws {
        guard sourceVersion>=22 else {return}
        let row=try db.statement("SELECT sql FROM sqlite_master WHERE name='entity_source_delete' AND type='trigger'");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==(sourceVersion>=31 ? EntitySchema.sourceDeleteSQL:EntitySchema.legacySourceDeleteSQL) else {throw OSwindError.database("Entity source erasure protection differs or is missing")}
    }
    static func validate(_ db:RoutineDatabase)throws {
        try validateSourceTransition(db,sourceVersion:31)
        let row=try db.statement("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name GLOB 'source_erasure_writer_*'");defer {sqlite3_finalize(row)};var names=Set<String>(),code=sqlite3_step(row)
        while code==SQLITE_ROW {let name=db.text(row,0);guard schemas[name]==db.text(row,1),names.insert(name).inserted else {throw OSwindError.database("Source erasure writer protection differs")};code=sqlite3_step(row)}
        guard code==SQLITE_DONE,names==Set(schemas.keys) else {throw OSwindError.database("Source erasure writer protection is missing")}
    }
    static func install(_ db:RoutineDatabase,sourceVersion:Int32,repairMissingPins:Bool)throws {
        for (name,sql) in schemas.sorted(by:{$0.key<$1.key}) {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name);let code=sqlite3_step(row),old=code==SQLITE_ROW ? db.text(row,0):nil;sqlite3_finalize(row)
            guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
            if let old {guard old==sql else {throw OSwindError.database("Source erasure writer protection differs")}}
            else {guard sourceVersion<31 || (repairMissingPins && name.hasPrefix("source_erasure_writer_text_observation_pins_")) else {throw OSwindError.database("Source erasure writer protection is missing")};try db.execute(sql)}
        };try validate(db)
    }
}
