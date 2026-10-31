import Foundation
import CSQLite

/// Nullable historical links prevent old INNER JOIN readers from silently
/// substituting a mutable source. Both ordinary and historical owners retain FKs.
enum CitationSchema {
    static func chat(_ name:String="chat_sources")->String {"""
    CREATE TABLE \(name)(
        turn_id TEXT NOT NULL REFERENCES chat_turns(id) ON DELETE CASCADE,
        memory_id TEXT REFERENCES memories(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,score REAL NOT NULL,match TEXT NOT NULL,passage_start INTEGER,passage_length INTEGER,
        owner_id TEXT REFERENCES memories(id) ON DELETE CASCADE,
        historical_handle TEXT REFERENCES historical_evidence(handle) ON DELETE CASCADE,
        PRIMARY KEY(turn_id,ordinal),
        CHECK((historical_handle IS NULL AND memory_id IS NOT NULL AND owner_id IS NULL) OR (historical_handle IS NOT NULL AND memory_id IS NULL AND owner_id IS NOT NULL))
    )
    """}
    static func recap(_ name:String="recap_sources")->String {"""
    CREATE TABLE \(name)(
        recap_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        source_id TEXT REFERENCES memories(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL CHECK(ordinal>=0 AND ordinal<60),revision TEXT NOT NULL,
        score REAL NOT NULL,match TEXT NOT NULL,passage_start INTEGER,passage_length INTEGER,
        owner_id TEXT REFERENCES memories(id) ON DELETE CASCADE,
        historical_handle TEXT REFERENCES historical_evidence(handle) ON DELETE CASCADE,
        PRIMARY KEY(recap_id,ordinal),CHECK(recap_id<>COALESCE(owner_id,source_id)),
        CHECK((historical_handle IS NULL AND source_id IS NOT NULL AND owner_id IS NULL) OR (historical_handle IS NOT NULL AND source_id IS NULL AND owner_id IS NOT NULL))
    )
    """}
    static func legacy(_ table:SyncCanonicalTable)->SyncCaptureTable {
        table == .conversationCitation ? .init("chat_sources","turn_id,memory_id,ordinal,score,match,passage_start,passage_length","turn_id,ordinal"):.init("recap_sources","recap_id,source_id,ordinal,revision,score,match,passage_start,passage_length","recap_id,ordinal")
    }
    static func validate(_ db:RoutineDatabase)throws {
        for table in [SyncCanonicalTable.conversationCitation,.recapCitation] {
            let expected=table == .conversationCitation ? chat():recap(),quoted=expected.replacingOccurrences(of:"CREATE TABLE "+table.rawValue+"(",with:"CREATE TABLE \""+table.rawValue+"\"(")
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE type='table' AND name=?");defer {sqlite3_finalize(row)};db.bind(row,1,table.rawValue)
            guard sqlite3_step(row)==SQLITE_ROW,[expected,quoted].contains(db.text(row,0)) else {throw OSwindError.database("Historical citation table protection differs")}
        }
    }
    private static func validateLegacyTable(_ db:RoutineDatabase,_ table:SyncCanonicalTable)throws {
        let expected=legacy(table),row=try db.statement("SELECT name,pk,hidden FROM pragma_table_xinfo(?)");defer {sqlite3_finalize(row)};db.bind(row,1,table.rawValue);var columns=Set<String>(),primary=[(Int32,String)](),code=sqlite3_step(row)
        while code==SQLITE_ROW {guard sqlite3_column_int(row,2)==0 else {throw OSwindError.database("Unsupported generated legacy citation column")};let name=db.text(row,0);columns.insert(name);let ordinal=sqlite3_column_int(row,1);if ordinal>0 {primary.append((ordinal,name))};code=sqlite3_step(row)}
        guard code==SQLITE_DONE,columns==Set(expected.columns),primary.sorted(by:{$0.0<$1.0}).map({$0.1})==expected.primary else {throw OSwindError.database("Legacy citation table shape differs")}
        let fk=try db.statement("SELECT \"from\",\"table\",\"to\",on_delete,on_update,seq FROM pragma_foreign_key_list(?)");defer {sqlite3_finalize(fk)};db.bind(fk,1,table.rawValue);var foreign=Set<String>();code=sqlite3_step(fk)
        while code==SQLITE_ROW {guard sqlite3_column_int(fk,5)==0 else {throw OSwindError.database("Unsupported composite legacy citation key")};foreign.insert((0..<5).map {db.text(fk,Int32($0))}.joined(separator:"|"));code=sqlite3_step(fk)}
        let owner=table == .conversationCitation ? "turn_id|chat_turns|id|CASCADE|NO ACTION":"recap_id|memories|id|CASCADE|NO ACTION",source=table == .conversationCitation ? "memory_id":"source_id"
        guard code==SQLITE_DONE,foreign==[owner,source+"|memories|id|CASCADE|NO ACTION"] else {throw OSwindError.database("Legacy citation foreign keys differ")}
    }
    private static func bytes(_ row:OpaquePointer,_ column:Int32)throws->Data {
        let size=Int(sqlite3_column_bytes(row,column));guard sqlite3_column_type(row,column)==SQLITE_BLOB,size>0,size<=SyncRowSnapshot.maximumBytes,let p=sqlite3_column_blob(row,column) else {throw OSwindError.database("Invalid citation migration frame")};return Data(bytes:p,count:size)
    }
    private static func bind(_ db:RoutineDatabase,_ row:OpaquePointer,_ primary:[SyncRowCell])throws {
        for (index,cell) in primary.enumerated() {switch cell {
        case .text(let data):data.withUnsafeBytes {_ = sqlite3_bind_text64(row,Int32(index+1),$0.baseAddress?.assumingMemoryBound(to:CChar.self),UInt64(data.count),db.transient,UInt8(SQLITE_UTF8))}
        case .integer(let value):sqlite3_bind_int64(row,Int32(index+1),value)
        default:throw OSwindError.database("Invalid citation migration key")
        }}
    }
    private static func migrateProjectionDigests(_ db:RoutineDatabase,_ table:SyncCanonicalTable)throws {
        let exists=try db.statement("SELECT 1 FROM sqlite_master WHERE name='personal_sync_version_projection'");let present=sqlite3_step(exists)==SQLITE_ROW;sqlite3_finalize(exists);guard present else {return}
        let old=legacy(table),rows=try db.statement("SELECT p.object_digest,p.row_digest,i.key_frame FROM personal_sync_version_projection p JOIN personal_sync_versions v ON v.object_digest=p.object_digest AND v.content_sha=p.content_sha JOIN personal_sync_identities i ON i.object_digest=p.object_digest WHERE v.table_name=? AND i.deleted=0");defer {sqlite3_finalize(rows)};db.bind(rows,1,table.rawValue);var code=sqlite3_step(rows)
        while code==SQLITE_ROW {
            let frame=try bytes(rows,2),primary=try SyncRowSnapshot.decode(frame).cells;guard try SyncIdentityCatalog.keyFrame(table,primary)==frame else {throw OSwindError.database("Citation migration lifetime key differs")}
            let source=try db.statement("SELECT "+old.snapshot("t")+" FROM "+old.name+" t WHERE "+old.primary.map {"t.\($0) IS ?"}.joined(separator:" AND "));defer {sqlite3_finalize(source)};try bind(db,source,primary)
            if sqlite3_step(source)==SQLITE_ROW {
                let actual=try bytes(source,0),digest=db.text(rows,1)
                // A legitimately stale projection stays stale until processing;
                // only an exact old current-row binding can be extended here.
                if SyncProtocolLimits.hex(actual)==digest {
                    let updated=try SyncRowSnapshot(SyncRowSnapshot.decode(actual).cells+[.null,.null]).encoded(),write=try db.statement("UPDATE personal_sync_version_projection SET row_digest=? WHERE object_digest=? AND row_digest=?");defer {sqlite3_finalize(write)}
                    db.bind(write,1,SyncProtocolLimits.hex(updated));db.bind(write,2,db.text(rows,0));db.bind(write,3,digest);try db.done(write)
                }
            }
            code=sqlite3_step(rows)
        };guard code==SQLITE_DONE else {throw db.error()}
    }
    private static func migratePending(_ db:RoutineDatabase,_ table:SyncCanonicalTable)throws {
        let exists=try db.statement("SELECT 1 FROM sqlite_master WHERE name='personal_sync_changes'");let present=sqlite3_step(exists)==SQLITE_ROW;sqlite3_finalize(exists);guard present else {return}
        let rows=try db.statement("SELECT seq,after_row FROM personal_sync_changes WHERE table_name=? AND after_row IS NOT NULL ORDER BY seq");defer {sqlite3_finalize(rows)};db.bind(rows,1,table.rawValue);var code=sqlite3_step(rows)
        while code==SQLITE_ROW {
            let frame=try SyncRowSnapshot.decode(bytes(rows,1));guard frame.cells.count==legacy(table).columns.count else {throw OSwindError.database("Legacy citation intent width differs")}
            let data=try SyncRowSnapshot(frame.cells+[.null,.null]).encoded(),write=try db.statement("UPDATE personal_sync_changes SET after_row=? WHERE seq=?");defer {sqlite3_finalize(write)}
            data.withUnsafeBytes {_ = sqlite3_bind_blob(write,1,$0.baseAddress,Int32(data.count),db.transient)};sqlite3_bind_int64(write,2,sqlite3_column_int64(rows,0));try db.done(write);code=sqlite3_step(rows)
        };guard code==SQLITE_DONE else {throw db.error()}
    }
    @discardableResult static func migrate(_ db:RoutineDatabase,sourceVersion:Int32)throws->Bool {
        var rebuilt=false
        for table in [SyncCanonicalTable.conversationCitation,.recapCitation] {
            let row=try db.statement("SELECT COUNT(*) FROM pragma_table_info(?) WHERE name IN ('owner_id','historical_handle')");db.bind(row,1,table.rawValue);guard sqlite3_step(row)==SQLITE_ROW else {sqlite3_finalize(row);throw db.error()};let count=sqlite3_column_int(row,0);sqlite3_finalize(row)
            if count==2 {continue}
            guard sourceVersion<26,count==0 else {throw OSwindError.database("Historical citation schema is incomplete")}
            try validateLegacyTable(db,table)
            if sourceVersion>=25 {try SyncChangeCapture.validateLegacyCitationTriggers(db,table:table);try SyncVersionStore.validateLegacyCitationTriggers(db,table:table)}
            try migrateProjectionDigests(db,table);try migratePending(db,table)
            let temporary=table.rawValue+"_v26",create=table == .conversationCitation ? chat(temporary):recap(temporary),old=legacy(table)
            try db.execute("PRAGMA legacy_alter_table=ON")
            do {
                try db.execute(create)
                try db.execute("INSERT INTO "+temporary+"("+old.columns.joined(separator:",")+") SELECT "+old.columns.joined(separator:",")+" FROM "+table.rawValue)
                try db.execute("DROP TABLE "+table.rawValue)
                try db.execute("ALTER TABLE "+temporary+" RENAME TO "+table.rawValue)
                try db.execute("PRAGMA legacy_alter_table=OFF")
            }catch {try? db.execute("PRAGMA legacy_alter_table=OFF");throw error}
            rebuilt=true
        }
        try db.execute("CREATE INDEX IF NOT EXISTS chat_source_memory ON chat_sources(memory_id); CREATE INDEX IF NOT EXISTS chat_source_owner ON chat_sources(owner_id); CREATE INDEX IF NOT EXISTS chat_source_original ON chat_sources(historical_handle); CREATE INDEX IF NOT EXISTS recap_source ON recap_sources(source_id,recap_id); CREATE INDEX IF NOT EXISTS recap_owner ON recap_sources(owner_id,recap_id); CREATE INDEX IF NOT EXISTS recap_original ON recap_sources(historical_handle)")
        try validate(db)
        if rebuilt {try SyncVersionStore.repairCitationUpgradeTriggers(db)}
        return rebuilt
    }
}
