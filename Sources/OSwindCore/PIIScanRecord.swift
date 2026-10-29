import Foundation
import CryptoKit
import CSQLite

/// A library-owned record of an experimental import check, not an attestation
/// that PII is absent. Only admitted-output content is bound; no separate
/// pre-mask source, original-source digest or span list is stored.
public struct PIIScanRecord:Codable,Equatable,Sendable {
    public let version:Int,coverage:String,contentSHA256:String
    public let modelID:String,compute:PIIComputePolicy,threshold:Double
    public let checkedAt:Date,redacted:Bool,fields:Int,windows:Int,framedTokens:Int
    init(memory:Memory,result:PIIImportScanner.Result,scanner:PIIImportScanner) throws {
        version=1;coverage="oswind-import-text-fields-v1";contentSHA256=try PIIScanContent.digest(memory)
        modelID=scanner.modelID;compute=scanner.compute;threshold=scanner.threshold
        checkedAt=result.checkedAt;redacted=result.redacted;fields=result.fields;windows=result.windows;framedTokens=result.framedTokens
        guard valid else {throw OSwindError.invalid("Invalid PII import check record")}
    }
    var valid:Bool {
        version==1 && coverage=="oswind-import-text-fields-v1" && contentSHA256.utf8.count==64 && contentSHA256.utf8.allSatisfy {(48...57).contains($0)||(97...102).contains($0)} &&
        !modelID.isEmpty && modelID.utf8.count<=512 && modelID.utf8.allSatisfy {(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||[45,46,58,95].contains($0)} &&
        threshold.isFinite && threshold>0 && threshold<1 && checkedAt.timeIntervalSince1970.isFinite && abs(checkedAt.timeIntervalSince1970)<1e11 &&
        (1...4096).contains(fields) && (1...PIIDocument.maximumWindows).contains(windows) && (1...PIIDocument.maximumFramedTokens).contains(framedTokens)
    }
}
public struct PIIScanStatus:Encodable,Equatable,Sendable {
    public enum State:String,Encodable,Sendable {case recorded,changed,notRecorded,unavailable}
    public let memoryID:String,state:State,record:PIIScanRecord?
    public let privacyAcceptance=false
}
/// Versioned, exact UTF-8 content binding. Favorites, vectors and media paths
/// are outside this text-only check. All other typed fields are covered.
enum PIIScanContent {
    static let maximumBytes=1024*1024
    static func digest(_ memory:Memory) throws -> String {
        try Task.checkCancellation()
        guard memory.searchPreview==nil else {throw OSwindError.invalid("A privacy check requires a complete memory")}
        var value=memory;value.favorite=false;value.embedding=nil;value.embeddingModel=nil
        value.imagePath=nil;value.audioPath=nil;value.videoPath=nil
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let data=try encoder.encode(value)
        guard data.count<=maximumBytes else {throw OSwindError.invalid("PII check content binding exceeds 1 MiB")}
        try Task.checkCancellation();return SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
    }
}
enum PIIScanSchema {
    static let sql="""
    CREATE TABLE IF NOT EXISTS pii_scan_records(
        memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
        content_sha256 TEXT NOT NULL CHECK(length(content_sha256)=64),
        is_current INTEGER NOT NULL CHECK(is_current IN (0,1)),
        receipt BLOB NOT NULL CHECK(length(receipt)>0 AND length(receipt)<=8192)
    );
    CREATE TRIGGER IF NOT EXISTS pii_scan_source_changed
    AFTER UPDATE OF payload,timestamp,kind,app,title,url,text ON memories BEGIN
        UPDATE pii_scan_records SET is_current=0 WHERE memory_id=NEW.id;
    END;
    """
}
extension MemoryStore {
    /// Preparation already computed the content binding outside the writer.
    /// Called only inside the import's final transaction after source insertion.
    func savePIIScanRecord(_ record:PIIScanRecord,for id:String) throws {
        guard record.valid else {throw OSwindError.invalid("Invalid PII import check record")}
        try withRoutineDatabase {db in
            guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("PII records require the source import transaction")}
            let row=try db.statement("INSERT INTO pii_scan_records(memory_id,content_sha256,is_current,receipt) VALUES(?,?,1,?) ON CONFLICT(memory_id) DO UPDATE SET content_sha256=excluded.content_sha256,is_current=1,receipt=excluded.receipt")
            defer {sqlite3_finalize(row)};db.bind(row,1,id);db.bind(row,2,record.contentSHA256);try db.bind(row,3,json:record);try db.done(row)
        }
    }
    func piiScanFavoriteToken(_ id:String) throws -> String? {
        try withRoutineDatabase {db in
            guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Favorite scan preservation requires its source transaction")}
            let row=try db.statement("SELECT content_sha256 FROM pii_scan_records WHERE memory_id=? AND is_current=1");defer {sqlite3_finalize(row)};db.bind(row,1,id)
            switch sqlite3_step(row) {case SQLITE_ROW:return db.text(row,0);case SQLITE_DONE:return nil;default:throw db.error()}
        }
    }
    func preservePIIScanAfterFavorite(_ id:String,token:String) throws {
        try withRoutineDatabase {db in
            guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Favorite scan preservation requires its source transaction")}
            let row=try db.statement("UPDATE pii_scan_records SET is_current=1 WHERE memory_id=? AND content_sha256=?");defer {sqlite3_finalize(row)};db.bind(row,1,id);db.bind(row,2,token);try db.done(row)
        }
    }
    /// One indexed read copies a consistent source/record snapshot. Parsing and
    /// hashing occur after releasing SQL. Lists/search never perform this work.
    public func piiScanStatus(_ id:String,matching expected:Memory?=nil) throws -> PIIScanStatus {
        try Task.checkCancellation()
        guard !id.isEmpty,id.count<200,!id.utf8.contains(0) else {throw OSwindError.invalid("Invalid memory id")}
        if let expected {guard Data(expected.id.utf8)==Data(id.utf8),expected.searchPreview==nil else {throw OSwindError.invalid("Privacy check source identity or completeness mismatch")}}
        struct Snapshot {let current:Bool,receipt:Data?,digest:String?,payload:Data?}
        let snapshot:Snapshot=try withRoutineDatabase {db in
            let row=try db.statement("SELECT p.is_current,p.receipt,p.content_sha256,CASE WHEN p.is_current=1 THEN m.payload END FROM memories m LEFT JOIN pii_scan_records p ON p.memory_id=m.id WHERE m.id=?")
            defer {sqlite3_finalize(row)};db.bind(row,1,id)
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Memory not found or unavailable")}
            func blob(_ column:Int32,maximum:Int)->Data? {
                let count=Int(sqlite3_column_bytes(row,column));guard count>0,count<=maximum,let bytes=sqlite3_column_blob(row,column) else {return nil};return Data(bytes:bytes,count:count)
            }
            if sqlite3_column_type(row,0)==SQLITE_NULL {return .init(current:false,receipt:nil,digest:nil,payload:nil)}
            return .init(current:sqlite3_column_int(row,0)==1,receipt:blob(1,maximum:8192),digest:db.text(row,2),payload:blob(3,maximum:PIIScanContent.maximumBytes))
        }
        try Task.checkCancellation()
        func status(_ state:PIIScanStatus.State,_ record:PIIScanRecord?=nil)->PIIScanStatus {.init(memoryID:id,state:state,record:record)}
        guard snapshot.digest != nil else {return status(.notRecorded)}
        guard let data=snapshot.receipt,let record=try? JSONDecoder().decode(PIIScanRecord.self,from:data),record.valid,record.contentSHA256==snapshot.digest else {return status(.unavailable)}
        guard snapshot.current else {return status(.changed,record)}
        guard let payload=snapshot.payload,let memory=try? JSONDecoder().decode(Memory.self,from:payload),Data(memory.id.utf8)==Data(id.utf8) else {return status(.unavailable)}
        let digest:String
        do {digest=try PIIScanContent.digest(memory)} catch is CancellationError {throw CancellationError()} catch {return status(.unavailable)}
        guard digest==record.contentSHA256 else {return status(.changed,record)}
        if let expected,try PIIScanContent.digest(expected) != digest {return status(.changed,record)}
        try Task.checkCancellation();return status(.recorded,record)
    }
}
