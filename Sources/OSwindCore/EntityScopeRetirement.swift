import Foundation
import CSQLite

enum EntityScopeSchema {
    // A schema32 writer understands unavailable restrictions. The distinct
    // function name also makes already-open schema31 connections refuse DML,
    // including empty statements, after another process upgrades the library.
    static let writers:[String:String] = {
        var result=[String:String]()
        for table in SyncChangeCapture.tables.map(\.name)+["historical_evidence",RoutineRunOriginalSchema.table] {for operation in ["insert","update","delete"] {
            let name="unavailable_scope_writer_"+table+"_"+operation
            result[name]="CREATE TRIGGER \(name) BEFORE \(operation.uppercased()) ON \(table) BEGIN SELECT oswind_unavailable_scope_writer_v1(); END"
        }};return result
    }()
    static func register(_ db:RoutineDatabase)throws {
        guard sqlite3_create_function_v2(db.handle,"oswind_unavailable_scope_writer_v1",0,SQLITE_UTF8|SQLITE_INNOCUOUS|SQLITE_DETERMINISTIC,nil,{context,_,_ in sqlite3_result_int(context,1)},nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
    static let indexes:[String:String] = [
        "entity_scope_turn":"CREATE INDEX entity_scope_turn ON chat_turns(json_extract(CAST(payload AS TEXT),'$.filter.entityID')) WHERE json_type(CAST(payload AS TEXT),'$.filter.entityID')='text'",
        "entity_scope_run":"CREATE INDEX entity_scope_run ON routine_runs(json_extract(CAST(scope AS TEXT),'$.entityID')) WHERE json_type(CAST(scope AS TEXT),'$.entityID')='text'"
    ]
    static func validate(_ db:RoutineDatabase)throws {
        for (name,sql) in indexes {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.database("Unavailable entity scope index differs or is missing")}
        }
        let row=try db.statement("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name GLOB 'unavailable_scope_writer_*'");defer {sqlite3_finalize(row)};var names=Set<String>()
        while true {let code=sqlite3_step(row);if code==SQLITE_DONE {break};guard code==SQLITE_ROW,writers[db.text(row,0)]==db.text(row,1),names.insert(db.text(row,0)).inserted else {throw OSwindError.database("Unavailable scope writer protection differs")}}
        guard names==Set(writers.keys) else {throw OSwindError.database("Unavailable scope writer protection is missing")}
    }
    static func install(_ db:RoutineDatabase,sourceVersion:Int32,repairMissingPins:Bool=false)throws {
        for (name,sql) in indexes {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name);let code=sqlite3_step(row),found=code==SQLITE_ROW ? db.text(row,0):nil;sqlite3_finalize(row)
            if let found {guard found==sql else {throw OSwindError.database("Unavailable entity scope index differs")}}
            else {guard code==SQLITE_DONE,sourceVersion<32 else {throw OSwindError.database("Unavailable entity scope index is missing")};try db.execute(sql)}
        }
        for (name,sql) in writers.sorted(by:{$0.key<$1.key}) {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name);let code=sqlite3_step(row),found=code==SQLITE_ROW ? db.text(row,0):nil;sqlite3_finalize(row)
            guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
            if let found {guard found==sql else {throw OSwindError.database("Unavailable scope writer protection differs")}}
            else {guard sourceVersion<32 || (repairMissingPins && name.hasPrefix("unavailable_scope_writer_text_observation_pins_")) else {throw OSwindError.database("Unavailable scope writer protection is missing")};try db.execute(sql)}
        };try validate(db)
    }
}
extension MemoryStore {
    /// Caller owns the serialized connection/transaction. Bounded ID batches
    /// use sparse JSON indexes; only one complete payload is read at a time.
    func retireEntityScopes(_ entity:String,marker:UnavailableEntityScope,db:RoutineDatabase,around:((SyncCanonicalTable,String,()throws->Void)throws->Void)?=nil)throws {
        try withRoutineDatabase {connection in guard connection.handle==db.handle,sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Entity scope retirement requires its owning transaction")}}
        try EntityScopeSchema.validate(db)
        for table:SyncCanonicalTable in [.turn,.routineRun] {
            let column=table == .turn ? "payload":"scope",path=table == .turn ? "$.filter.entityID":"$.entityID",index=table == .turn ? "entity_scope_turn":"entity_scope_run"
            var after:Int64?
            while true {
                try Task.checkCancellation()
                let ids:[(Int64,String)] = try {
                    let row=try db.statement("SELECT rowid,id FROM "+table.rawValue+" INDEXED BY "+index+" WHERE json_type(CAST("+column+" AS TEXT),'"+path+"')='text' AND json_extract(CAST("+column+" AS TEXT),'"+path+"')=?"+(after==nil ? "":" AND rowid>?")+" ORDER BY rowid LIMIT 128");defer {sqlite3_finalize(row)};db.bind(row,1,entity);if let after {sqlite3_bind_int64(row,2,after)}
                    var result=[(Int64,String)]()
                    while true {let code=sqlite3_step(row);if code==SQLITE_DONE {break};guard code==SQLITE_ROW else {throw db.error()};result.append((sqlite3_column_int64(row,0),db.text(row,1)))}
                    return result
                }()
                guard !ids.isEmpty else {break}
                for (position,id) in ids {
                    try autoreleasepool {
                    try Task.checkCancellation();after=position
                    let before=try entityScopeFrame(table,id:id,db:db),cell=table == .turn ? 3:10
                    guard case .blob(let payload)=before.cells[cell] else {throw OSwindError.invalid("Entity scope payload storage differs")}
                    let updated:Data
                    if table == .turn {
                        var value=try JSONDecoder().decode(ChatPayload.self,from:payload)
                        guard value.filter.entityID.map({Data($0.utf8)})==Data(entity.utf8),value.filter.unavailableEntityScope==nil else {throw OSwindError.invalid("Turn scope changed before retirement")}
                        value.filter.entityID=nil;value.filter.unavailableEntityScope=marker;updated=try SyncProtocolLimits.encode(value)
                    }else {
                        var value=try JSONDecoder().decode(SearchFilter.self,from:payload)
                        guard value.entityID.map({Data($0.utf8)})==Data(entity.utf8),value.unavailableEntityScope==nil else {throw OSwindError.invalid("Run scope changed before retirement")}
                        value.entityID=nil;value.unavailableEntityScope=marker;updated=try SyncProtocolLimits.encode(value)
                    }
                    var cells=before.cells;cells[cell] = .blob(updated);let next=try SyncRowSnapshot(cells),original=table == .routineRun ? try RoutineRunOriginalStore(db:db).read(id):nil
                    var applied=false
                    let update:()throws->Void = {
                        guard !applied,try self.entityScopeFrame(table,id:id,db:db)==before else {throw OSwindError.invalid("Scoped history changed before retirement")};applied=true
                        func write()throws {
                            let row=try db.statement("UPDATE "+table.rawValue+" SET "+column+"=? WHERE id=? AND "+column+"=?");defer {sqlite3_finalize(row)}
                            updated.withUnsafeBytes {_=sqlite3_bind_blob(row,1,$0.baseAddress,Int32(updated.count),db.transient)};db.bind(row,2,id);payload.withUnsafeBytes {_=sqlite3_bind_blob(row,3,$0.baseAddress,Int32(payload.count),db.transient)};try db.done(row)
                            guard sqlite3_changes(db.handle)==1 else {throw OSwindError.invalid("Scoped history changed during retirement")}
                        }
                        if let original {
                            let bytes=try original.encoded()
                            try self.incomingRunProjection.withRun(next,payload:bytes) {try write();try RoutineRunOriginalStore(db:db).replace(id,payload:bytes,frame:next)}
                            guard try RoutineRunOriginalStore(db:db).read(id)?.encoded()==bytes else {throw OSwindError.invalid("Scope retirement changed original run provenance")}
                        }else if table == .turn {try self.entityScopeProjection.withTurn(before:before,after:next) {try write()}}
                        else{try write()}
                        guard try self.entityScopeFrame(table,id:id,db:db)==next else {throw OSwindError.invalid("Scope retirement changed other history fields")}
                    }
                    if let around {try around(table,id,update)}else{try update()}
                    guard applied else {throw OSwindError.invalid("Scoped history retirement was not applied")}
                    }
                }
            }
        }
        try Task.checkCancellation()
    }
    private func entityScopeFrame(_ table:SyncCanonicalTable,id:String,db:RoutineDatabase)throws->SyncRowSnapshot {
        guard table == .turn || table == .routineRun else {throw OSwindError.invalid("Only turn and run filters have entity scopes")}
        let row=try db.statement("SELECT "+table.schema.snapshot("t")+" FROM "+table.rawValue+" t WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id)
        guard sqlite3_step(row)==SQLITE_ROW,let p=sqlite3_column_blob(row,0) else {throw OSwindError.unavailable("Scoped history is no longer available")}
        return try .decode(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))))
    }
}

extension RoutineDatabase {
    func entityCanPrune(_ id:String,includeProjectRejections:Bool=false)throws->Bool {
        let row=try statement("SELECT 1 FROM memory_entities WHERE id=? AND curated=0 AND NOT EXISTS(SELECT 1 FROM entity_mentions WHERE entity_id=?)"+(includeProjectRejections ? " AND NOT EXISTS(SELECT 1 FROM entity_project_ignored WHERE entity_id=?)":""));defer {sqlite3_finalize(row)};bind(row,1,id);bind(row,2,id);if includeProjectRejections {bind(row,3,id)}
        let code=sqlite3_step(row);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw error()};return code==SQLITE_ROW
    }
}

extension MemoryStore {
    /// Match the native source-pruning trigger before it removes the last
    /// uncurated definition. Peer source projection/erasure preserves entities.
    func retireEntityScopesForSourceRevision(_ source:String,db:RoutineDatabase)throws {
        try retirePrunedEntityScopes(db:db,selection:"SELECT ?",values:[source,source,source,source])
    }
    func retireEntityScopesForErasedSources(_ db:RoutineDatabase)throws {
        try retirePrunedEntityScopes(db:db,selection:"SELECT id FROM temp.erasure_ids",values:[])
    }
    private func retirePrunedEntityScopes(db:RoutineDatabase,selection:String,values:[String])throws {
        var after:Int64?
        while true {
            try Task.checkCancellation()
            let ids:[(Int64,String)] = try {
                let sql="SELECT e.rowid,e.id FROM memory_entities e WHERE e.curated=0 AND e.id IN (SELECT entity_id FROM entity_mentions WHERE memory_id IN ("+selection+") UNION SELECT entity_id FROM entity_project_ignored WHERE memory_id IN ("+selection+")) AND NOT EXISTS(SELECT 1 FROM entity_mentions m WHERE m.entity_id=e.id AND m.memory_id NOT IN ("+selection+")) AND NOT EXISTS(SELECT 1 FROM entity_project_ignored p WHERE p.entity_id=e.id AND p.memory_id NOT IN ("+selection+"))"+(after==nil ? "":" AND e.rowid>?")+" ORDER BY e.rowid LIMIT 128"
                let row=try db.statement(sql);defer {sqlite3_finalize(row)};for (i,value) in values.enumerated() {db.bind(row,Int32(i+1),value)};if let after {sqlite3_bind_int64(row,Int32(values.count+1),after)}
                var result=[(Int64,String)]();while true {let code=sqlite3_step(row);if code==SQLITE_DONE {break};guard code==SQLITE_ROW else {throw db.error()};result.append((sqlite3_column_int64(row,0),db.text(row,1)))};return result
            }()
            guard !ids.isEmpty else {return}
            for (position,id) in ids {after=position;try retireEntityScopes(id,marker:.init(),db:db)}
        }
    }
}
