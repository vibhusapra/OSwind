import Foundation
import CSQLite

extension MemoryStore {
    /// Called only while a supported media reservation is active. Every returned
    /// match binds current bytes, metadata and a real frame; no caption is inferred.
    func validateVisualMatch(_ match:VisualMatch,memory:Memory,tree supplied:BackupFileTree?=nil) throws {
        let tree=try supplied ?? BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath())
        let identity=try tree.identity()
        guard identity.device==mediaRootIdentity.device,identity.inode==mediaRootIdentity.inode,
              match.preprocessingID==VisualSourcePlan.preprocessingID,
              let plan=try VisualSourcePlan.make(memory),plan.revision==match.sourceRevision,
              let point=plan.points.first(where:{$0.ordinal==match.frameOrdinal}),point.time==match.frameTime,
              point.time==nil ? match.decodedTime==nil:(match.decodedTime.map {$0.isFinite && $0>=0 && abs($0-(point.time ?? 0))<=0.1} ?? false)
        else {throw OSwindError.unavailable("This visual source or frame changed. Refresh the results.")}
        try tree.requireRootIdentity(at:root)
        let maximum=plan.kind == .image ? Int64(64*1024*1024):VisualVideoSnapshot.maximumBytes
        let digest=try tree.digest(plan.path,limit:maximum)
        guard digest.sha256==match.mediaSHA256 else {throw OSwindError.unavailable("The retained image or replay changed. Rebuild visual indexing.")}
        try tree.requireRootIdentity(at:root)
    }
    func recentVisualSources(_ filter:SearchFilter) throws -> [SearchHit] {
        try withRoutineDatabase {db in
            let (scope,values)=conditions(filter),row=try db.statement("SELECT m.id FROM visual_sources p JOIN memories m ON m.id=p.memory_id WHERE \(scope) ORDER BY m.timestamp DESC,m.id LIMIT ?")
            defer {sqlite3_finalize(row)};for (index,value) in values.enumerated() {db.bind(row,Int32(index+1),value)}
            sqlite3_bind_int(row,Int32(values.count+1),Int32(min(500,max(1,filter.limit))))
            var hits=[SearchHit](),code=sqlite3_step(row)
            while code==SQLITE_ROW {try Task.checkCancellation();if let memory=try get(db.text(row,0)) {hits.append(SearchHit(memory:memory,score:memory.timestamp.timeIntervalSince1970,match:"retained visual source"))};code=sqlite3_step(row)}
            guard code==SQLITE_DONE else {throw db.error()};return hits
        }
    }
    func searchVisual(_ filter:SearchFilter,vector:[Float],modelID:String,minimumSimilarity:Double?=nil,expression:SearchExpressionPlan?=nil,policy:PrivacyPolicy?=nil) throws -> (hits:[SearchHit],invalidMedia:Int) {
        guard let scorer=CosineScorer(vector),minimumSimilarity?.isFinite ?? true else {throw OSwindError.invalid("Visual search requires a finite nonzero query vector")}
        // Lock order is reservation -> store/SQLite, including all file checks.
        let activity=try mediaWriteLease();var tree:BackupFileTree?
        defer {tree=nil;activity.release()}
        tree=try BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath())
        let identity=try tree!.identity();guard identity.device==mediaRootIdentity.device,identity.inode==mediaRootIdentity.inode else {throw OSwindError.unavailable("The visual library changed")}
        try tree!.requireRootIdentity(at:root)
        return try withRoutineDatabase {db in
            try db.execute("SAVEPOINT visual_search");defer {try? db.execute("RELEASE visual_search")}
            let (scope,values)=conditions(filter,expression:expression)
            let row=try db.statement("""
                SELECT v.memory_id,v.vector,m.timestamp,v.ordinal,v.frame_time,v.decoded_time,p.revision,a.media_sha,v.revision
                FROM visual_vectors v JOIN visual_manifests a ON a.memory_id=v.memory_id AND a.model=v.model AND a.processor=v.processor
                JOIN visual_sources p ON p.memory_id=v.memory_id AND p.revision=a.source_revision JOIN memories m ON m.id=p.memory_id
                WHERE v.model=? AND v.processor=? AND a.dimension=? AND \(scope) ORDER BY v.memory_id,v.ordinal
                """)
            defer {sqlite3_finalize(row)};db.bind(row,1,modelID);db.bind(row,2,VisualSourcePlan.preprocessingID);sqlite3_bind_int(row,3,Int32(vector.count))
            for (index,value) in values.enumerated() {db.bind(row,Int32(index+4),value)}
            var top=SemanticTopK(capacity:min(500,max(1,filter.limit))),code=sqlite3_step(row),invalid=0,lastID="",source:Memory?,sourcePlan:VisualSourcePlan?,sourceChecked=false,sourceValid=false,rows=0
            while code==SQLITE_ROW {
                if rows%128==0 {try Task.checkCancellation()};rows+=1
                let id=db.text(row,0)
                if id != lastID {lastID=id;source=nil;sourcePlan=nil;sourceChecked=false;sourceValid=false}
                if Int(sqlite3_column_bytes(row,1))==vector.count*MemoryLayout<Float>.size,let bytes=sqlite3_column_blob(row,1) {
                    let score=scorer.score(bytes.assumingMemoryBound(to:Float.self),count:vector.count)
                    // SigLIP cosine is a ranking score, not a calibrated probability.
                    // Do not borrow an arbitrary text-embedding confidence cutoff.
                    if score.isFinite,minimumSimilarity.map({score >= $0}) ?? true,top.mayImprove(score) {
                        let point=VisualSourcePlan.Point(ordinal:Int(sqlite3_column_int(row,3)),time:sqlite3_column_type(row,4)==SQLITE_NULL ? nil:sqlite3_column_double(row,4))
                        let match=VisualMatch(modelID:modelID,preprocessingID:VisualSourcePlan.preprocessingID,sourceRevision:db.text(row,6),mediaSHA256:db.text(row,7),frameOrdinal:point.ordinal,frameTime:point.time,decodedTime:sqlite3_column_type(row,5)==SQLITE_NULL ? nil:sqlite3_column_double(row,5))
                        if !sourceChecked {
                            source=try get(id);sourcePlan=try source.flatMap {try VisualSourcePlan.make($0)};sourceChecked=true
                            if let source,policy.map({VisualRetrievalEngine.allowed(source,policy:$0)}) ?? true {
                                do {try validateVisualMatch(match,memory:source,tree:tree);sourceValid=true} catch {invalid+=1}
                            }
                        }
                        if sourceValid,let plan=sourcePlan,plan.points.contains(point),
                           (try? plan.vectorRevision(mediaSHA256:match.mediaSHA256,modelID:modelID,point:point))==db.text(row,8),
                           point.time==nil ? match.decodedTime==nil:(match.decodedTime.map {$0.isFinite && $0>=0 && abs($0-(point.time ?? 0))<=0.1} ?? false) {
                            top.offer(SemanticCandidate(id:id,similarity:score,timestamp:sqlite3_column_double(row,2),visual:match))
                        }
                    }
                }
                code=sqlite3_step(row)
            }
            guard code==SQLITE_DONE else {throw db.error()};try tree!.requireRootIdentity(at:root)
            var hits=[SearchHit]()
            for item in top.sorted {if let memory=try get(item.id) {hits.append(SearchHit(memory:memory,score:item.similarity,match:"visual similarity",visual:item.visual))}}
            return (hits,invalid)
        }
    }
}
