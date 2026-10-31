import Foundation
import CSQLite

public struct RoutineRunOriginalInfo:Codable,Equatable,Sendable {
    public let editorOrigin:String
    public let recipeOrdinal:Int64
    public let recordedStatus:RoutineRunStatus
    public let recipeTitle:String?
    public let recipePrompt:String?
}
struct RoutineRunOriginal:Codable,Equatable {
    static let maximumBytes=128*1024
    let record:SyncPortableRecord
    let definition:SyncPortableRecord?
    func validate()throws {
        try record.validate();guard case .routineRun(let body)=record.body else {throw OSwindError.invalid("Run original is not a typed run")}
        if let definition {
            try definition.validate();guard case .routine=definition.body,definition.identity==body.recipe.routine,try definition.reference.content==body.recipe.definition else {throw OSwindError.invalid("Original recipe definition differs")}
        }else {guard body.recipe.definition==nil else {throw OSwindError.invalid("Known original recipe definition must be retained")}}
    }
    func encoded()throws->Data {try validate();let bytes=try SyncProtocolLimits.encode(self);guard bytes.count<=Self.maximumBytes else {throw OSwindError.invalid("Run original exceeds128KiB")};return bytes}
    static func decode(_ bytes:Data)throws->Self {guard bytes.count<=maximumBytes else {throw OSwindError.invalid("Run original exceeds128KiB")};let value=try JSONDecoder().decode(Self.self,from:bytes);guard try value.encoded()==bytes else {throw OSwindError.invalid("Run original encoding differs")};return value}
    var info:RoutineRunOriginalInfo {
        guard case .routineRun(let run)=record.body else {preconditionFailure("Validate run original first")}
        let recipe:SyncRoutineBody?;if let definition,case .routine(let body)=definition.body {recipe=body}else{recipe=nil}
        return .init(editorOrigin:run.recipe.editorOrigin,recipeOrdinal:run.recipe.ordinal,recordedStatus:run.status,recipeTitle:recipe?.title,recipePrompt:recipe?.prompt)
    }
}
enum RoutineRunOriginalSchema {
    static let table="routine_run_originals"
    static let run=SyncChangeCapture.tables.first {$0.name=="routine_runs"}!
    static let schemas:[String:String] = {
        let frame=run.snapshot("r"),new=run.snapshot("new")
        var result=[
            table:"CREATE TABLE routine_run_originals(run_id TEXT PRIMARY KEY REFERENCES routine_runs(id) ON DELETE CASCADE,payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload)>0 AND length(payload)<=131072),native_sha TEXT NOT NULL CHECK(length(native_sha)=64))",
            "routine_original_insert":"CREATE TRIGGER routine_original_insert BEFORE INSERT ON routine_run_originals WHEN oswind_incoming_run_original_v1(new.run_id,new.payload,new.native_sha)<>1 BEGIN SELECT RAISE(ABORT,'Use typed run original admission'); END",
            "routine_original_immutable":"CREATE TRIGGER routine_original_immutable BEFORE UPDATE ON routine_run_originals BEGIN SELECT RAISE(ABORT,'Run originals are immutable'); END",
            "routine_original_delete":"CREATE TRIGGER routine_original_delete BEFORE DELETE ON routine_run_originals WHEN EXISTS(SELECT 1 FROM routine_runs r WHERE r.id=old.run_id AND old.native_sha=oswind_sync_run_fingerprint_v1(\(frame)) AND oswind_incoming_run_projection_v1(\(frame))<>1) BEGIN SELECT RAISE(ABORT,'Erase the run with its original'); END",
            "routine_original_change":"CREATE TRIGGER routine_original_change AFTER UPDATE OF \(run.columns.joined(separator:",")) ON routine_runs WHEN CASE WHEN EXISTS(SELECT 1 FROM routine_run_originals WHERE run_id=new.id) THEN oswind_incoming_run_projection_v1(\(new))<>1 ELSE 0 END BEGIN DELETE FROM routine_run_originals WHERE run_id=new.id AND native_sha<>oswind_sync_run_fingerprint_v1(\(new)); END"
        ]
        for table in SyncChangeCapture.tables.map(\.name)+["historical_evidence",Self.table] {for op in ["insert","update","delete"] {
            let name="run_original_writer_"+table+"_"+op;result[name]="CREATE TRIGGER \(name) BEFORE \(op.uppercased()) ON \(table) BEGIN SELECT oswind_run_original_writer_v1(); END"
        }};return result
    }()
    static func validate(_ db:RoutineDatabase)throws {
        for (name,sql) in schemas {let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name);guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.database("Run original protection differs or is missing")}}
    }
    static func install(_ db:RoutineDatabase,sourceVersion:Int32,repairMissingPins:Bool)throws {
        for name in [table]+schemas.keys.filter({$0 != table}).sorted() {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name);let code=sqlite3_step(row),found=code==SQLITE_ROW ? db.text(row,0):nil;sqlite3_finalize(row)
            if let found {guard found==schemas[name] else {throw OSwindError.database("Run original protection differs")}}
            else {guard code==SQLITE_DONE,(sourceVersion<29 || (repairMissingPins && name.hasPrefix("run_original_writer_text_observation_pins_"))) else {throw OSwindError.database("Run original protection is missing")};try db.execute(schemas[name]!)}
        };try validate(db)
    }
}
struct RoutineRunOriginalStore {
    let db:RoutineDatabase
    func frame(_ id:String)throws->SyncRowSnapshot? {
        let row=try db.statement("SELECT \(RoutineRunOriginalSchema.run.snapshot("r")) FROM routine_runs r WHERE r.id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id);let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW,let p=sqlite3_column_blob(row,0) else {throw db.error()};return try .decode(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))))
    }
    func read(_ id:String)throws->RoutineRunOriginal? {
        guard try db.eraseCount("PRAGMA user_version")>=29 else {return nil}
        let row=try db.statement("SELECT payload,native_sha FROM routine_run_originals WHERE run_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id);let code=sqlite3_step(row);if code==SQLITE_DONE {return nil}
        guard code==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_BLOB,let p=sqlite3_column_blob(row,0),let actual=try frame(id),try SyncProtocolLimits.hex(actual.encoded())==db.text(row,1) else {throw OSwindError.database("Run original's native binding differs")}
        let value=try RoutineRunOriginal.decode(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))));guard case .routineRun(let body)=value.record.body,case .text(let status)=actual.cells[7],status==Data(body.projectedStatus.rawValue.utf8) else {throw OSwindError.database("Run original status projection differs")};return value
    }
    func replace(_ id:String,payload:Data,frame:SyncRowSnapshot)throws {
        let drop=try db.statement("DELETE FROM routine_run_originals WHERE run_id=?");defer {sqlite3_finalize(drop)};db.bind(drop,1,id);try db.done(drop)
        let row=try db.statement("INSERT INTO routine_run_originals VALUES(?,?,?)");defer {sqlite3_finalize(row)};db.bind(row,1,id);payload.withUnsafeBytes {_=sqlite3_bind_blob(row,2,$0.baseAddress,Int32(payload.count),db.transient)};db.bind(row,3,try SyncProtocolLimits.hex(frame.encoded()));try db.done(row)
    }
}
