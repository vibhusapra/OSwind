import Foundation

/// Offsets address the original source text in UTF-16; never embedding prefixes.
public struct PassageRange: Codable, Hashable, Sendable {
    public var start: Int
    public var length: Int
    public init(start: Int, length: Int) { self.start = start; self.length = length }
    public func text(in source: String) -> String? {
        guard start >= 0, length > 0, start <= source.utf16.count, length <= source.utf16.count-start,
              (source as NSString).rangeOfComposedCharacterSequences(for:NSRange(location:start,length:length)) == NSRange(location:start,length:length) else { return nil }
        return (source as NSString).substring(with:NSRange(location:start,length:length))
    }
}
struct SemanticPassage: Sendable {
    var ordinal: Int
    var range: PassageRange
    var input: String
}
enum SemanticPassagePlan {
    static let version = 1
    static let threshold = 2400
    static func needed(_ memory: Memory) -> Bool { memory.text.utf16.count > threshold }
    /// Streaming indices avoid copying a million-character source to an array.
    /// Every character is covered; there is no silent passage-count cutoff.
    static func make(_ memory: Memory) -> [SemanticPassage] {
        guard needed(memory) else { return [] }
        let text = memory.text
        let context = [String(memory.title.prefix(160)),String(memory.app.prefix(80)),String((memory.url ?? "").prefix(240))].joined(separator:"\n")
        var start = text.startIndex, offset = 0, passages = [SemanticPassage]()
        while start < text.endIndex {
            let end = text.index(start,offsetBy:1200,limitedBy:text.endIndex) ?? text.endIndex
            let body = String(text[start..<end])
            passages.append(SemanticPassage(ordinal:passages.count+1,range:PassageRange(start:offset,length:body.utf16.count),input:context+"\n"+body))
            if end == text.endIndex { break }
            let next = text.index(start,offsetBy:1000,limitedBy:end) ?? end
            offset += text[start..<next].utf16.count; start = next
        }
        return passages
    }
}
struct PassageVector: Sendable { var range: PassageRange; var vector: [Float] }
enum PassageSchema {
    static let sql = """
    CREATE INDEX IF NOT EXISTS vector_keys_parent_revision ON vector_keys(memory_id,model,revision,ordinal);
    CREATE INDEX IF NOT EXISTS memories_passage_candidates ON memories(id) WHERE length(CAST(text AS BLOB))>2400;
    CREATE TABLE IF NOT EXISTS semantic_passages (
        memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        model TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>0),
        start INTEGER NOT NULL CHECK(start>=0), length INTEGER NOT NULL CHECK(length>0),
        dimension INTEGER NOT NULL, vector BLOB NOT NULL,
        PRIMARY KEY(memory_id,model,ordinal)
    );
    CREATE TABLE IF NOT EXISTS passage_manifests (
        memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        model TEXT NOT NULL, content_hash TEXT NOT NULL, version INTEGER NOT NULL, count INTEGER NOT NULL,
        PRIMARY KEY(memory_id,model)
    );
    CREATE INDEX IF NOT EXISTS semantic_passages_model ON semantic_passages(model);
    CREATE TRIGGER IF NOT EXISTS passage_base_removed AFTER DELETE ON vector_keys WHEN old.ordinal=0 BEGIN
        DELETE FROM semantic_passages WHERE memory_id=old.memory_id AND model=old.model;
        DELETE FROM passage_manifests WHERE memory_id=old.memory_id AND model=old.model;
    END;
    CREATE TRIGGER IF NOT EXISTS passage_insert AFTER INSERT ON semantic_passages BEGIN
        INSERT INTO vector_keys(memory_id,model,ordinal) VALUES(new.memory_id,new.model,new.ordinal) ON CONFLICT(memory_id,model,ordinal) DO NOTHING;
        INSERT INTO vector_changes(vector_key,model) SELECT key,model FROM vector_keys WHERE memory_id=new.memory_id AND model=new.model AND ordinal=new.ordinal;
        UPDATE vector_keys SET revision=(SELECT MAX(seq) FROM vector_changes) WHERE memory_id=new.memory_id AND model=new.model AND ordinal=new.ordinal;
    END;
    CREATE TRIGGER IF NOT EXISTS passage_delete AFTER DELETE ON semantic_passages BEGIN
        DELETE FROM vector_keys WHERE memory_id=old.memory_id AND model=old.model AND ordinal=old.ordinal;
    END;
    CREATE TRIGGER IF NOT EXISTS passage_content_update AFTER UPDATE OF title,app,text,url ON memories
    WHEN old.title IS NOT new.title OR old.app IS NOT new.app OR old.text IS NOT new.text OR old.url IS NOT new.url BEGIN
        DELETE FROM semantic_passages WHERE memory_id=new.id;
        DELETE FROM passage_manifests WHERE memory_id=new.id;
    END;
    """
}

public extension SearchHit {
    func excerpt(query: String, budget: Int = 800, summary: Bool = false) -> String {
        guard !summary, let passage, let body = passage.text(in:memory.text) else { return EvidenceText.excerpt(memory.text,query:query,budget:budget,summary:summary) }
        let excerpt = EvidenceText.excerpt(body,query:query,budget:budget)
        return (passage.start > 0 ? "… " : "") + excerpt + (passage.start+passage.length < memory.text.utf16.count ? " …" : "")
    }
}
