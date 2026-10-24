import Foundation
import CSQLite

struct IndexedVector {
    var key: UInt64
    var revision: Int64
    var vector: [Float]?
    var parentKey: UInt64 = 0
}
struct VectorSourceState {
    var identity: String
    var head: Int64
    var highKey: UInt64
    var count: Int
}
struct VectorChangeBatch {
    var records: [IndexedVector]
    var sequence: Int64
    var head: Int64
}
/// A dedicated read-only connection. Each page is a short snapshot, so a long
/// graph build does not pin a multi-gigabyte WAL while capture continues.
final class VectorIndexSource {
    private var db: OpaquePointer?
    private let modelID: String
    let dimensions: Int
    private let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(root: URL, modelID: String, dimensions: Int) throws {
        let temporaryPolicy=try VaultAccess.temporaryPolicy(at:root)
        self.modelID = modelID; self.dimensions = dimensions
        guard sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&db,SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { sqlite3_close(db); db = nil; throw OSwindError.database("Cannot read vector source") }
        sqlite3_busy_timeout(db,5000)
        do {try exec("PRAGMA temp_store=\(temporaryPolicy.rawValue)")} catch {sqlite3_close(db);db=nil;throw error}
    }
    deinit { sqlite3_close(db) }
    private func failure() -> OSwindError { .database(String(cString:sqlite3_errmsg(db))) }
    private func statement(_ sql: String) throws -> OpaquePointer { var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK, let stmt else { throw failure() }; return stmt }
    private func bind(_ stmt: OpaquePointer,_ index: Int32,_ text: String) { sqlite3_bind_text64(stmt,index,text,UInt64(text.utf8.count),transient,UInt8(SQLITE_UTF8)) }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw failure() } }
    private func snapshot<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN")
        do { let value = try body(); try exec("COMMIT"); return value } catch { try? exec("ROLLBACK"); throw error }
    }
    func state(includeCount: Bool = true) throws -> VectorSourceState { try snapshot { try stateInSnapshot(includeCount:includeCount) } }
    private func stateInSnapshot(includeCount: Bool) throws -> VectorSourceState {
        let stmt = try statement("SELECT (SELECT value FROM store_metadata WHERE key='identity'),COALESCE((SELECT MAX(seq) FROM vector_changes),0),COALESCE((SELECT MAX(key) FROM vector_keys WHERE model=?),0)," + (includeCount ? "COALESCE((SELECT entities FROM vector_statistics WHERE model=?),0)" : "-1"))
        defer { sqlite3_finalize(stmt) }; bind(stmt,1,modelID)
        if includeCount { bind(stmt,2,modelID) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let identity = sqlite3_column_text(stmt,0) else { throw failure() }
        let highKey = sqlite3_column_int64(stmt,2)
        guard highKey >= 0 else { throw OSwindError.database("Invalid vector registry key") }
        return VectorSourceState(identity:String(cString:identity),head:sqlite3_column_int64(stmt,1),highKey:UInt64(highKey),count:Int(sqlite3_column_int64(stmt,3)))
    }
    private static let vectorSelect = """
        SELECT r.key,r.revision,CASE WHEN r.ordinal=0 THEN COALESCE(v.vector,CASE WHEN m.embedding_model=r.model THEN m.embedding END) ELSE p.vector END,b.key
        FROM vector_keys r JOIN memories m ON m.id=r.memory_id
        JOIN vector_keys b ON b.memory_id=r.memory_id AND b.model=r.model AND b.ordinal=0
        LEFT JOIN semantic_vectors v ON v.memory_id=r.memory_id AND v.model=r.model AND r.ordinal=0
        LEFT JOIN semantic_passages p ON p.memory_id=r.memory_id AND p.model=r.model AND p.ordinal=r.ordinal
        """
    private func decode(_ stmt: OpaquePointer) throws -> IndexedVector {
        let key = sqlite3_column_int64(stmt,0)
        guard key > 0 else { throw OSwindError.database("Invalid vector registry key") }
        let size = Int(sqlite3_column_bytes(stmt,2)); var vector: [Float]?
        if size == dimensions*MemoryLayout<Float>.size, let bytes = sqlite3_column_blob(stmt,2) {
            let values = Array(UnsafeBufferPointer(start:bytes.assumingMemoryBound(to:Float.self),count:dimensions))
            if CosineScorer(values) != nil { vector = values }
        }
        return IndexedVector(key:UInt64(key),revision:sqlite3_column_int64(stmt,1),vector:vector,parentKey:UInt64(max(0,sqlite3_column_int64(stmt,3))))
    }
    func page(after key: UInt64, through highKey: UInt64, limit: Int = 256) throws -> [IndexedVector] {
        guard key <= UInt64(Int64.max), highKey <= UInt64(Int64.max) else { throw OSwindError.invalid("Invalid vector page bounds") }
        return try snapshot {
            let stmt = try statement(Self.vectorSelect + " WHERE r.model=? AND r.key>? AND r.key<=? ORDER BY r.key LIMIT ?"); defer { sqlite3_finalize(stmt) }
            bind(stmt,1,modelID); sqlite3_bind_int64(stmt,2,Int64(key)); sqlite3_bind_int64(stmt,3,Int64(highKey)); sqlite3_bind_int(stmt,4,Int32(min(1024,max(1,limit))))
            var rows = [IndexedVector](); var status = sqlite3_step(stmt)
            while status == SQLITE_ROW { rows.append(try decode(stmt)); status = sqlite3_step(stmt) }
            guard status == SQLITE_DONE else { throw failure() }; return rows
        }
    }
    func changes(after sequence: Int64, limit: Int = 256) throws -> VectorChangeBatch {
        try snapshot {
            let headStatement = try statement("SELECT COALESCE(MAX(seq),0) FROM vector_changes"); defer { sqlite3_finalize(headStatement) }
            guard sqlite3_step(headStatement) == SQLITE_ROW else { throw failure() }; let head = sqlite3_column_int64(headStatement,0)
            let changes = try statement("SELECT seq,vector_key FROM vector_changes WHERE model=? AND seq>? ORDER BY seq LIMIT ?"); defer { sqlite3_finalize(changes) }
            bind(changes,1,modelID); sqlite3_bind_int64(changes,2,sequence); sqlite3_bind_int(changes,3,Int32(min(2048,max(1,limit))))
            var keys = Set<UInt64>(), last = sequence, status = sqlite3_step(changes)
            while status == SQLITE_ROW {
                last = sqlite3_column_int64(changes,0); let key = sqlite3_column_int64(changes,1)
                guard key > 0 else { throw OSwindError.database("Invalid vector change key") }
                keys.insert(UInt64(key)); status = sqlite3_step(changes)
            }
            guard status == SQLITE_DONE else { throw failure() }
            if keys.isEmpty { last = head }
            let lookup = try statement(Self.vectorSelect + " WHERE r.key=? AND r.model=?"); defer { sqlite3_finalize(lookup) }
            var records = [IndexedVector]()
            for key in keys.sorted() {
                sqlite3_reset(lookup); sqlite3_clear_bindings(lookup); sqlite3_bind_int64(lookup,1,Int64(key)); bind(lookup,2,modelID)
                let status = sqlite3_step(lookup)
                if status == SQLITE_ROW { records.append(try decode(lookup)) }
                else if status == SQLITE_DONE { records.append(IndexedVector(key:key,revision:last,vector:nil)) }
                else { throw failure() }
            }
            return VectorChangeBatch(records:records,sequence:last,head:head)
        }
    }
}
