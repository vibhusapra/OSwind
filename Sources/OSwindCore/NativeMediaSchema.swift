import Foundation
import CSQLite

public enum MemoryStoreUpgradePhase:String,Sendable {
    case mediaQueueCopied,beforeCommit,afterCommit
}

/// Schema33 prevents initialized older implementations from consuming the
/// erasure queue without the current reservation protocol. The scalar is a
/// connection capability, not peer authentication or an arbitrary-SQL sandbox.
enum NativeMediaSchema {
    static let function="oswind_media_admission_writer_v1"
    static let dirtyKey="recap_cache_dirty_v33"
    static let cacheDirectory="indexes-v33"
    static let backing="erasure_assets_v33"
    static let tableSQL="CREATE TABLE erasure_assets_v33(path TEXT PRIMARY KEY) WITHOUT ROWID"
    static let viewSQL="CREATE VIEW erasure_assets AS SELECT path FROM erasure_assets_v33 WHERE oswind_media_admission_writer_v1()=1"
    static let queueTriggers:[String:String]=[
        "erasure_assets_insert_v33":"CREATE TRIGGER erasure_assets_insert_v33 INSTEAD OF INSERT ON erasure_assets BEGIN SELECT oswind_media_admission_writer_v1(); INSERT OR IGNORE INTO erasure_assets_v33(path) VALUES(new.path); END",
        "erasure_assets_delete_v33":"CREATE TRIGGER erasure_assets_delete_v33 INSTEAD OF DELETE ON erasure_assets BEGIN SELECT oswind_media_admission_writer_v1(); DELETE FROM erasure_assets_v33 WHERE path=old.path; END",
        "erasure_assets_update_v33":"CREATE TRIGGER erasure_assets_update_v33 INSTEAD OF UPDATE ON erasure_assets BEGIN SELECT oswind_media_admission_writer_v1(); UPDATE erasure_assets_v33 SET path=new.path WHERE path=old.path; END"
    ]
    static var metadataTriggers:[String:String] {
        Dictionary(uniqueKeysWithValues:["INSERT","UPDATE","DELETE"].map {operation in
            let name="store_metadata_media_v33_"+operation.lowercased()
            return (name,"CREATE TRIGGER "+name+" BEFORE "+operation+" ON store_metadata BEGIN SELECT oswind_media_admission_writer_v1(); END")
        })
    }
    static func register(_ db:RoutineDatabase)throws {
        let flags=SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS
        guard sqlite3_create_function_v2(db.handle,function,0,flags,nil,{context,_,_ in sqlite3_result_int(context,1)},nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
    private static func object(_ db:RoutineDatabase,_ name:String)throws->(String,String)? {
        let row=try db.statement("SELECT type,sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw db.error()}
        let result=(db.text(row,0),db.text(row,1));guard sqlite3_step(row)==SQLITE_DONE else {throw db.error()};return result
    }
    static func install(_ db:RoutineDatabase,sourceVersion:Int32,observe:(@Sendable (MemoryStoreUpgradePhase)->Void)?=nil)throws {
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.database("Media safety migration requires its native writer transaction")}
        guard let queue=try object(db,"erasure_assets") else {throw OSwindError.database("Missing native erasure queue")}
        if queue.0=="table" {
            guard sourceVersion<33,try object(db,backing)==nil else {throw OSwindError.database("Invalid native media safety format")}
            let columns=try db.statement("PRAGMA table_xinfo(erasure_assets)");defer {sqlite3_finalize(columns)}
            guard sqlite3_step(columns)==SQLITE_ROW,db.text(columns,1)=="path",db.text(columns,2)=="TEXT",sqlite3_column_int(columns,3)==1,sqlite3_column_type(columns,4)==SQLITE_NULL,sqlite3_column_int(columns,5)==1,sqlite3_column_int(columns,6)==0,sqlite3_step(columns)==SQLITE_DONE,queue.1.uppercased().contains("WITHOUT ROWID") else {throw OSwindError.database("Unsupported native erasure queue")}
            // Do not ALTER RENAME: SQLite would retarget producer triggers to
            // the private backing table and bypass the compatibility view.
            try db.execute(tableSQL)
            try Task.checkCancellation()
            try db.execute("INSERT INTO erasure_assets_v33(path) SELECT path FROM erasure_assets")
            observe?(.mediaQueueCopied);try Task.checkCancellation()
            try db.execute("DROP TABLE erasure_assets")
            try db.execute(viewSQL)
            for name in queueTriggers.keys.sorted() {try db.execute(queueTriggers[name]!)}
            try db.execute("INSERT INTO store_metadata(key,value) SELECT '\(dirtyKey)','1' FROM store_metadata WHERE key='recap_cache_dirty' AND value='1' ON CONFLICT(key) DO UPDATE SET value='1'; DELETE FROM store_metadata WHERE key='recap_cache_dirty'")
            for name in metadataTriggers.keys.sorted() {try db.execute(metadataTriggers[name]!)}
        }
        try validate(db)
    }
    static func validate(_ db:RoutineDatabase)throws {
        guard try db.eraseCount("SELECT oswind_media_admission_writer_v1()")==1 else {throw OSwindError.database("Native media safety capability is unavailable")}
        guard let queue=try object(db,"erasure_assets"),queue.0=="view",queue.1==viewSQL,
              let storage=try object(db,backing),storage.0=="table",storage.1==tableSQL else {throw OSwindError.database("Native media safety queue protection changed")}
        for (name,sql) in queueTriggers.merging(metadataTriggers,uniquingKeysWith:{$1}) {
            guard let actual=try object(db,name),actual.0=="trigger",actual.1==sql else {throw OSwindError.database("Native media safety writer protection changed")}
        }
    }
}
