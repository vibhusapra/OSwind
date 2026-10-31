import Foundation
import CSQLite

/// Schema 30 prevents a schema-29 client from recreating the old pruning
/// trigger while imported entity definitions have an independent lifetime.
enum SyncIncomingEntitySchema {
    static let schemas:[String:String] = {
        var result=[String:String]()
        for table in SyncChangeCapture.tables.map(\.name)+["historical_evidence",RoutineRunOriginalSchema.table] {for operation in ["insert","update","delete"] {
            let name="incoming_entity_writer_"+table+"_"+operation
            result[name]="CREATE TRIGGER \(name) BEFORE \(operation.uppercased()) ON \(table) BEGIN SELECT oswind_incoming_entity_writer_v1(); END"
        }};return result
    }()
    static func register(_ db:RoutineDatabase)throws {
        guard sqlite3_create_function_v2(db.handle,"oswind_incoming_entity_writer_v1",0,SQLITE_UTF8|SQLITE_INNOCUOUS|SQLITE_DETERMINISTIC,nil,{context,_,_ in sqlite3_result_int(context,1)},nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
    static func validateSourceTransition(_ db:RoutineDatabase,sourceVersion:Int32)throws {
        guard sourceVersion>=22 else {return}
        let row=try db.statement("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='entity_source_revision'");defer {sqlite3_finalize(row)}
        let expected=sourceVersion>=30 ? EntitySchema.sourceRevisionSQL:EntitySchema.legacySourceRevisionSQL
        guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==expected else {throw OSwindError.database("Entity source revision protection differs or is missing")}
    }
    static func validate(_ db:RoutineDatabase)throws {
        try validateSourceTransition(db,sourceVersion:30)
        let row=try db.statement("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name GLOB 'incoming_entity_writer_*'");defer {sqlite3_finalize(row)}
        var names=Set<String>(),code=sqlite3_step(row)
        while code==SQLITE_ROW {let name=db.text(row,0);guard schemas[name]==db.text(row,1),names.insert(name).inserted else {throw OSwindError.database("Incoming entity writer protection differs")};code=sqlite3_step(row)}
        guard code==SQLITE_DONE,names==Set(schemas.keys) else {throw OSwindError.database("Incoming entity writer protection is missing")}
    }
    static func install(_ db:RoutineDatabase,sourceVersion:Int32,repairMissingPins:Bool)throws {
        for (name,sql) in schemas.sorted(by:{$0.key<$1.key}) {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name);let code=sqlite3_step(row),old=code==SQLITE_ROW ? db.text(row,0):nil;sqlite3_finalize(row)
            guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
            if let old {guard old==sql else {throw OSwindError.database("Incoming entity writer protection differs")}}
            else {guard sourceVersion<30 || (repairMissingPins && name.hasPrefix("incoming_entity_writer_text_observation_pins_")) else {throw OSwindError.database("Incoming entity writer protection is missing")};try db.execute(sql)}
        };try validate(db)
    }
}
