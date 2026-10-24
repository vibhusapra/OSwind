import Foundation
import CSQLite

enum VisualIndexSchema {
    static let sql="""
    CREATE TABLE IF NOT EXISTS visual_sources(
        memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
        revision TEXT NOT NULL,kind TEXT NOT NULL,path TEXT NOT NULL,points INTEGER NOT NULL CHECK(points>0 AND points<=240));
    CREATE TABLE IF NOT EXISTS visual_manifests(
        memory_id TEXT NOT NULL REFERENCES visual_sources(memory_id) ON DELETE CASCADE,
        model TEXT NOT NULL,processor TEXT NOT NULL,source_revision TEXT NOT NULL,media_sha TEXT NOT NULL,
        media_bytes INTEGER NOT NULL CHECK(media_bytes>=0),dimension INTEGER NOT NULL CHECK(dimension>0 AND dimension<=8192),
        PRIMARY KEY(memory_id,model,processor));
    CREATE INDEX IF NOT EXISTS visual_manifest_model ON visual_manifests(model,processor,memory_id);
    CREATE TABLE IF NOT EXISTS visual_vectors(
        memory_id TEXT NOT NULL,model TEXT NOT NULL,processor TEXT NOT NULL,ordinal INTEGER NOT NULL CHECK(ordinal>=0 AND ordinal<240),
        frame_time REAL,decoded_time REAL,revision TEXT NOT NULL,vector BLOB NOT NULL,
        PRIMARY KEY(memory_id,model,processor,ordinal),
        FOREIGN KEY(memory_id,model,processor) REFERENCES visual_manifests(memory_id,model,processor) ON DELETE CASCADE);
    CREATE INDEX IF NOT EXISTS visual_vector_model ON visual_vectors(model,processor,memory_id,ordinal);
    """
}
struct VisualFrameVector:Sendable {
    var point:VisualSourcePlan.Point
    var decodedTime:Double?
    var vector:[Float]
}
public struct VisualIndexCoverage:Codable,Sendable {
    public var sources:Int
    public var indexedSources:Int
    public var frames:Int
    public var indexedFrames:Int
}
public struct VisualMatch:Codable,Equatable,Sendable {
    public var modelID:String
    public var preprocessingID:String
    public var sourceRevision:String
    public var mediaSHA256:String
    public var frameOrdinal:Int
    public var frameTime:Double?
    public var decodedTime:Double?
}
extension MemoryStore {
    func removeVisualVectors(_ id:String,modelID:String) throws {
        try withRoutineDatabase {db in
            let row=try db.statement("DELETE FROM visual_manifests WHERE memory_id=? AND model=? AND processor=?");defer {sqlite3_finalize(row)}
            db.bind(row,1,id);db.bind(row,2,modelID);db.bind(row,3,VisualSourcePlan.preprocessingID);try db.done(row)
        }
    }
    func replaceVisualProjection(_ memory:Memory) throws {
        try withRoutineDatabase {db in
            guard let plan=try? VisualSourcePlan.make(memory) else {
                let remove=try db.statement("DELETE FROM visual_sources WHERE memory_id=?");defer {sqlite3_finalize(remove)};db.bind(remove,1,memory.id);try db.done(remove);return
            }
            let invalidate=try db.statement("DELETE FROM visual_manifests WHERE memory_id=? AND source_revision<>?");defer {sqlite3_finalize(invalidate)}
            db.bind(invalidate,1,memory.id);db.bind(invalidate,2,plan.revision);try db.done(invalidate)
            let row=try db.statement("INSERT INTO visual_sources(memory_id,revision,kind,path,points) VALUES(?,?,?,?,?) ON CONFLICT(memory_id) DO UPDATE SET revision=excluded.revision,kind=excluded.kind,path=excluded.path,points=excluded.points")
            defer {sqlite3_finalize(row)};db.bind(row,1,memory.id);db.bind(row,2,plan.revision);db.bind(row,3,plan.kind.rawValue);db.bind(row,4,plan.path);sqlite3_bind_int(row,5,Int32(plan.points.count));try db.done(row)
        }
    }
    func visualSources(afterID:String="",limit:Int=16,missingFor modelID:String?=nil) throws -> [Memory] {
        try withRoutineDatabase {db in
            let pending=modelID==nil ? "":" AND NOT EXISTS(SELECT 1 FROM visual_manifests a WHERE a.memory_id=p.memory_id AND a.source_revision=p.revision AND a.model=? AND a.processor=?)"
            let row=try db.statement("SELECT m.payload FROM visual_sources p JOIN memories m ON m.id=p.memory_id WHERE m.id>?\(pending) ORDER BY m.id LIMIT ?");defer {sqlite3_finalize(row)}
            db.bind(row,1,afterID)
            if let modelID {db.bind(row,2,modelID);db.bind(row,3,VisualSourcePlan.preprocessingID)}
            sqlite3_bind_int(row,modelID==nil ? 2:4,Int32(min(64,max(1,limit))))
            var values=[Memory](),code=sqlite3_step(row)
            while code==SQLITE_ROW {
                try Task.checkCancellation();guard let bytes=sqlite3_column_blob(row,0) else {throw db.error()}
                values.append(try JSONDecoder().decode(Memory.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(row,0)))));code=sqlite3_step(row)
            }
            guard code==SQLITE_DONE else {throw db.error()};return values
        }
    }
    public func visualCoverage(modelID:String,filter:SearchFilter=SearchFilter()) throws -> VisualIndexCoverage {
        try withRoutineDatabase {db in
            let (scope,values)=conditions(filter)
            let row=try db.statement("SELECT COUNT(*),COALESCE(SUM(CASE WHEN v.memory_id IS NOT NULL THEN 1 ELSE 0 END),0),COALESCE(SUM(p.points),0),COALESCE(SUM(CASE WHEN v.memory_id IS NOT NULL THEN p.points ELSE 0 END),0) FROM visual_sources p JOIN memories m ON m.id=p.memory_id LEFT JOIN visual_manifests v ON v.memory_id=p.memory_id AND v.source_revision=p.revision AND v.model=? AND v.processor=? WHERE \(scope)")
            defer {sqlite3_finalize(row)};db.bind(row,1,modelID);db.bind(row,2,VisualSourcePlan.preprocessingID)
            for (index,value) in values.enumerated() {db.bind(row,Int32(index+3),value)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()}
            return VisualIndexCoverage(sources:Int(sqlite3_column_int64(row,0)),indexedSources:Int(sqlite3_column_int64(row,1)),frames:Int(sqlite3_column_int64(row,2)),indexedFrames:Int(sqlite3_column_int64(row,3)))
        }
    }
    func visualVectorsCurrent(plan:VisualSourcePlan,mediaSHA256:String,modelID:String) throws -> Bool {
        try withRoutineDatabase {db in
            let row=try db.statement("SELECT 1 FROM visual_manifests v JOIN visual_sources p ON p.memory_id=v.memory_id WHERE v.memory_id=? AND v.model=? AND v.processor=? AND v.media_sha=? AND v.source_revision=? AND p.revision=v.source_revision AND (SELECT COUNT(*) FROM visual_vectors x WHERE x.memory_id=v.memory_id AND x.model=v.model AND x.processor=v.processor)=p.points")
            defer {sqlite3_finalize(row)};for (index,value) in [plan.memoryID,modelID,VisualSourcePlan.preprocessingID,mediaSHA256,plan.revision].enumerated() {db.bind(row,Int32(index+1),value)}
            let code=sqlite3_step(row);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()};return code==SQLITE_ROW
        }
    }
    @discardableResult func saveVisualVectors(_ records:[VisualFrameVector],snapshot:any VisualMediaSnapshot,modelID:String) throws -> Int {
        guard records.count==snapshot.plan.points.count,Set(records.map(\.point.ordinal)).count==records.count,
              let dimension=records.first?.vector.count,(1...8192).contains(dimension),
              records.allSatisfy({record in record.vector.count==dimension && CosineScorer(record.vector) != nil && snapshot.plan.points.contains(record.point) && (record.point.time==nil ? record.decodedTime==nil:(record.decodedTime.map {$0.isFinite && $0>=0 && abs($0-(record.point.time ?? 0))<=0.1} ?? false))})
        else {throw OSwindError.invalid("Visual indexing requires a complete, finite frame set with verified decode timing")}
        return try snapshot.withAdmission(for:self) {memory in
            try withRoutineDatabase {db in try db.transaction {
                guard let current=try get(memory.id),try VisualSourcePlan.make(current)?.revision==snapshot.plan.revision else {throw OSwindError.unavailable("Visual source changed before index admission")}
                try replaceVisualProjection(current)
                let remove=try db.statement("DELETE FROM visual_manifests WHERE memory_id=? AND model=? AND processor=?");defer {sqlite3_finalize(remove)}
                db.bind(remove,1,memory.id);db.bind(remove,2,modelID);db.bind(remove,3,VisualSourcePlan.preprocessingID);try db.done(remove)
                let manifest=try db.statement("INSERT INTO visual_manifests(memory_id,model,processor,source_revision,media_sha,media_bytes,dimension) VALUES(?,?,?,?,?,?,?)");defer {sqlite3_finalize(manifest)}
                for (index,value) in [memory.id,modelID,VisualSourcePlan.preprocessingID,snapshot.plan.revision,snapshot.sha256].enumerated() {db.bind(manifest,Int32(index+1),value)}
                sqlite3_bind_int64(manifest,6,snapshot.bytes);sqlite3_bind_int(manifest,7,Int32(dimension));try db.done(manifest)
                let row=try db.statement("INSERT INTO visual_vectors(memory_id,model,processor,ordinal,frame_time,decoded_time,revision,vector) VALUES(?,?,?,?,?,?,?,?)");defer {sqlite3_finalize(row)}
                for record in records {
                    try Task.checkCancellation();sqlite3_reset(row);sqlite3_clear_bindings(row)
                    db.bind(row,1,memory.id);db.bind(row,2,modelID);db.bind(row,3,VisualSourcePlan.preprocessingID);sqlite3_bind_int(row,4,Int32(record.point.ordinal))
                    if let time=record.point.time {sqlite3_bind_double(row,5,time)} else {sqlite3_bind_null(row,5)}
                    if let time=record.decodedTime {sqlite3_bind_double(row,6,time)} else {sqlite3_bind_null(row,6)}
                    db.bind(row,7,try snapshot.plan.vectorRevision(mediaSHA256:snapshot.sha256,modelID:modelID,point:record.point))
                    _ = record.vector.withUnsafeBytes {sqlite3_bind_blob(row,8,$0.baseAddress,Int32($0.count),db.transient)};try db.done(row)
                }
                return records.count
            }}
        }
    }
}
