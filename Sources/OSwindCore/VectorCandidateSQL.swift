import Foundation

/// The bounded recent sample must follow time order and seek by parent.
/// A global model/revision scan per source can turn it into quadratic work.
enum VectorCandidateSQL {
    static func select(recent: Bool = false, appScoped: Bool = false) -> String {
        let source: String
        if recent {
            let timeIndex = appScoped ? "memories_app_time" : "memories_time"
            source = "FROM memories m INDEXED BY \(timeIndex) CROSS JOIN vector_keys r INDEXED BY vector_keys_parent_revision ON r.memory_id=m.id"
        } else { source = "FROM vector_keys r JOIN memories m ON m.id=r.memory_id" }
        return """
        SELECT m.id,CASE WHEN r.ordinal=0 THEN COALESCE(v.vector,CASE WHEN m.embedding_model=r.model THEN m.embedding END) ELSE p.vector END,m.timestamp,COALESCE(p.start,-1),COALESCE(p.length,0)
        \(source)
        LEFT JOIN semantic_vectors v ON v.memory_id=r.memory_id AND v.model=r.model AND r.ordinal=0
        LEFT JOIN semantic_passages p ON p.memory_id=r.memory_id AND p.model=r.model AND p.ordinal=r.ordinal
        """
    }
    static func recent(appScoped: Bool, predicate: String) -> String {
        select(recent:true,appScoped:appScoped)+" WHERE r.model=? AND r.revision<=? AND \(predicate) ORDER BY m.timestamp DESC,m.id,r.ordinal LIMIT 100"
    }
}
