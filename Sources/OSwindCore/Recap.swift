import Foundation
import CSQLite

public struct RecapSource:Codable,Equatable,Sendable {
    public var id,revision,match:String
    public var score:Double
    public var passage:PassageRange?
    public init(id:String,revision:String,match:String,score:Double,passage:PassageRange?=nil) {self.id=id;self.revision=revision;self.match=match;self.score=score;self.passage=passage}
}
public struct RecapSourceCard:Identifiable,Sendable {
    public let id,title,app,revision:String
    public let timestamp:Date
    public let passage:PassageRange?
}
public struct RecapProvenance:Codable,Equatable,Sendable {
    public var provider:String
    public var sources:[RecapSource]
    public init(provider:String,sources:[RecapSource]) {self.provider=provider;self.sources=sources}
    func validated() throws -> Self {
        guard !provider.isEmpty,provider.utf8.count<=128,!provider.utf8.contains(0),(1...60).contains(sources.count),try JSONEncoder().encode(self).count<=65536 else {throw OSwindError.invalid("A linked recap needs 1–60 sources and bounded provider metadata")}
        for source in sources {
            guard !source.id.isEmpty,source.id.count<200,!source.id.utf8.contains(0),!source.revision.isEmpty,source.revision.utf8.count<=512,source.match.utf8.count<=128,source.score.isFinite,abs(source.score)<=1_000_000 else {throw OSwindError.invalid("Invalid recap source metadata")}
        }
        return self
    }
}
enum RecapSchema {
    static let closure="""
    WITH RECURSIVE affected(id) AS (
        SELECT recap_id FROM recap_sources WHERE source_id=?
        UNION SELECT r.recap_id FROM recap_sources r JOIN affected a ON r.source_id=a.id
    ) SELECT id FROM affected WHERE id<>?
    """
    static func descendants(_ root:String) -> String {"""
    WITH RECURSIVE affected(id) AS (
        SELECT recap_id FROM recap_sources WHERE source_id=\(root)
        UNION SELECT r.recap_id FROM recap_sources r JOIN affected a ON r.source_id=a.id
    ) SELECT id FROM affected WHERE id<>\(root)
    """}
    static let sql="""
    CREATE TABLE IF NOT EXISTS recap_sources(
        recap_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        source_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL CHECK(ordinal>=0 AND ordinal<60),revision TEXT NOT NULL,
        score REAL NOT NULL,match TEXT NOT NULL,passage_start INTEGER,passage_length INTEGER,
        PRIMARY KEY(recap_id,ordinal),CHECK(recap_id<>source_id)
    );
    CREATE INDEX IF NOT EXISTS recap_source ON recap_sources(source_id,recap_id);
    CREATE TRIGGER IF NOT EXISTS recap_source_erasure BEFORE DELETE ON memories BEGIN
        DELETE FROM memories WHERE id IN (\(descendants("old.id")));
    END;
    CREATE TRIGGER IF NOT EXISTS recap_source_revision BEFORE UPDATE OF title,app,text,url,timestamp,kind ON memories
    WHEN old.title IS NOT new.title OR old.app IS NOT new.app OR old.text IS NOT new.text OR old.url IS NOT new.url OR old.timestamp IS NOT new.timestamp OR old.kind IS NOT new.kind
    BEGIN DELETE FROM memories WHERE id IN (\(descendants("old.id"))); END;
    CREATE TRIGGER IF NOT EXISTS recap_cache_erasure AFTER DELETE ON memories
    WHEN old.kind='summary' AND json_type(CAST(old.payload AS TEXT),'$.recap')='object'
    BEGIN
        UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='identity';
        INSERT INTO store_metadata(key,value) VALUES('recap_cache_dirty','1') ON CONFLICT(key) DO UPDATE SET value='1';
    END;
    """
}
extension MemoryStore {
    /// Saves a local source-linked memory. Source revisions are rechecked by insert's writer transaction.
    public func saveRecap(_ answer:Answer,title:String="Saved recap",policy:PrivacyPolicy=PrivacyPolicy(),embedder:LocalEmbedder?=nil) throws -> Memory {
        try Task.checkCancellation()
        guard !answer.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,answer.text.count<=100_000,(1...60).contains(answer.sources.count),answer.sources.allSatisfy({$0.memory.searchPreview==nil}) else {throw OSwindError.invalid("Save a recap with 1–60 complete recorded sources")}
        guard answer.sources.allSatisfy({policy.exclusion(app:$0.memory.bundleID,title:$0.memory.title,url:$0.memory.url)==nil}) else {throw OSwindError.unavailable("An original is excluded by the current privacy rules. Ask again before saving.")}
        var memory=Memory(kind:.summary,app:"OSwind",title:String(policy.sanitize(title).text.prefix(300)),text:policy.sanitize(answer.text).text)
        memory.recap=RecapProvenance(provider:policy.sanitize(answer.provider).text,sources:answer.sources.map {.init(id:$0.id,revision:$0.memory.evidenceHash,match:$0.match,score:$0.score,passage:$0.passage)})
        _ = try memory.recap!.validated()
        memory.embedding=embedder?.embed(memory.searchableText);memory.embeddingModel=memory.embedding==nil ? nil:embedder?.modelID
        try Task.checkCancellation();try insert(memory);return memory
    }
    public func saveChatRecap(sessionID:String,turnID:String,title:String="Saved recap",policy:PrivacyPolicy=PrivacyPolicy(),embedder:LocalEmbedder?=nil) throws -> Memory {
        guard let turn=try chatTurns(sessionID,limit:1,turnID:turnID).first else {throw OSwindError.invalid("Conversation turn not found")}
        return try saveRecap(turn.answer,title:title,policy:policy,embedder:embedder)
    }
    public func recapSourceCards(_ id:String) throws -> [RecapSourceCard] {
        try withRoutineDatabase {db in
            try db.execute("SAVEPOINT recap_cards");defer {try? db.execute("RELEASE recap_cards")}
            guard try get(id)?.recap != nil else {throw OSwindError.invalid("Linked recap not found")}
            let row=try db.statement("SELECT m.id,substr(m.title,1,500),m.app,m.timestamp,s.revision,s.passage_start,s.passage_length FROM recap_sources s JOIN memories m ON m.id=s.source_id WHERE s.recap_id=? ORDER BY s.ordinal");defer {sqlite3_finalize(row)};db.bind(row,1,id)
            var result=[RecapSourceCard](),status=sqlite3_step(row)
            while status==SQLITE_ROW {
                guard result.count<60 else {throw OSwindError.invalid("Recap source count exceeds its bound")}
                result.append(.init(id:db.text(row,0),title:db.text(row,1),app:db.text(row,2),revision:db.text(row,4),timestamp:Date(timeIntervalSince1970:sqlite3_column_double(row,3)),passage:sqlite3_column_type(row,5)==SQLITE_NULL ? nil:PassageRange(start:Int(sqlite3_column_int64(row,5)),length:Int(sqlite3_column_int64(row,6)))))
                status=sqlite3_step(row)
            }
            guard status==SQLITE_DONE else {throw db.error()};return result
        }
    }
    public func recapEvidence(_ id:String) throws -> [SearchHit] {
        try withRoutineDatabase {db in
            try db.execute("SAVEPOINT recap_evidence");defer {try? db.execute("RELEASE recap_evidence")}
            guard let memory=try get(id),let recap=memory.recap else {throw OSwindError.invalid("Linked recap not found")}
            return try recap.sources.map {source in
                guard let current=try get(source.id),current.evidenceHash==source.revision else {throw OSwindError.unavailable("Recap evidence changed or was removed")}
                return SearchHit(memory:current,score:source.score,match:source.match,passage:source.passage)
            }
        }
    }
    func validateRecapInsertion(_ memory:Memory,deferred:Bool) throws {
        try withRoutineDatabase {db in
            let old=try db.statement("SELECT json_extract(CAST(payload AS TEXT),'$.recap') FROM memories WHERE id=?");defer {sqlite3_finalize(old)};db.bind(old,1,memory.id)
            if sqlite3_step(old)==SQLITE_ROW,let text=db.optional(old,0) {
                let prior=try JSONDecoder().decode(RecapProvenance.self,from:Data(text.utf8))
                let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
                guard let replacement=memory.recap,try encoder.encode(replacement)==encoder.encode(prior) else {throw OSwindError.invalid("A linked recap cannot silently lose or change its source links. Save a new note for an independent copy.")}
            }
            guard let recap=memory.recap else {return};_ = try recap.validated()
            guard memory.kind == .summary,memory.transcript==nil,memory.visualRecording==nil,memory.imagePath==nil,memory.audioPath==nil,memory.videoPath==nil else {throw OSwindError.invalid("Linked recaps are text summaries")}
            if !deferred {try validateRecapParents(memory.id,recap:recap,db:db)}
        }
    }
    private func validateRecapParents(_ id:String,recap:RecapProvenance,db:RoutineDatabase) throws {
        for source in recap.sources {
            try Task.checkCancellation()
            guard source.id != id,let current=try get(source.id),current.evidenceHash==source.revision else {throw OSwindError.unavailable("Recap evidence changed or was removed. Ask again before saving.")}
            if let passage=source.passage {guard passage.text(in:current.text) != nil else {throw OSwindError.invalid("Recap passage is outside its source")}}
            let cycle=try db.statement("WITH RECURSIVE parents(id) AS (SELECT ? UNION SELECT r.source_id FROM recap_sources r JOIN parents p ON r.recap_id=p.id) SELECT 1 FROM parents WHERE id=? LIMIT 1");defer {sqlite3_finalize(cycle)};db.bind(cycle,1,source.id);db.bind(cycle,2,id)
            let status=sqlite3_step(cycle);guard status==SQLITE_DONE else {if status==SQLITE_ROW {throw OSwindError.invalid("Recap source links must not form a cycle")};throw db.error()}
        }
    }
    func replaceRecapLinks(_ memory:Memory,deferred:Bool) throws {
        guard let recap=memory.recap,!deferred else {return}
        try withRoutineDatabase {db in
            try validateRecapParents(memory.id,recap:recap,db:db)
            let remove=try db.statement("DELETE FROM recap_sources WHERE recap_id=?");defer {sqlite3_finalize(remove)};db.bind(remove,1,memory.id);try db.done(remove)
            let row=try db.statement("INSERT INTO recap_sources(recap_id,source_id,ordinal,revision,score,match,passage_start,passage_length) VALUES(?,?,?,?,?,?,?,?)");defer {sqlite3_finalize(row)}
            for (i,source) in recap.sources.enumerated() {
                sqlite3_reset(row);sqlite3_clear_bindings(row);db.bind(row,1,memory.id);db.bind(row,2,source.id);sqlite3_bind_int(row,3,Int32(i));db.bind(row,4,source.revision);sqlite3_bind_double(row,5,source.score);db.bind(row,6,source.match)
                if let range=source.passage {sqlite3_bind_int64(row,7,Int64(range.start));sqlite3_bind_int64(row,8,Int64(range.length))}
                try db.done(row)
            }
        }
    }
    func rebuildRecapLinks() throws {
        try withRoutineDatabase {db in
            let rows=try db.statement("SELECT payload FROM memories WHERE json_type(CAST(payload AS TEXT),'$.recap')='object'");defer {sqlite3_finalize(rows)};var status=sqlite3_step(rows)
            while status==SQLITE_ROW {
                try autoreleasepool {
                    guard let bytes=sqlite3_column_blob(rows,0) else {throw db.error()}
                    let memory=try JSONDecoder().decode(Memory.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(rows,0))))
                    try validateRecapInsertion(memory,deferred:true);try replaceRecapLinks(memory,deferred:false)
                };status=sqlite3_step(rows)
            }
            guard status==SQLITE_DONE else {throw db.error()}
        }
    }
    func invalidateRecapDependents(_ id:String) throws {
        try withRoutineDatabase {db in let row=try db.statement("DELETE FROM memories WHERE id IN (\(RecapSchema.closure))");defer {sqlite3_finalize(row)};db.bind(row,1,id);db.bind(row,2,id);try db.done(row)}
    }
    @discardableResult func finishRecapInvalidation() -> HistoryErasureResult? {
        try? withRoutineDatabase {db in
            guard try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='recap_cache_dirty' AND value='1'")>0 else {return nil}
            return cleanupErasedAssets(db,sources:0,turns:0)
        }
    }
}
