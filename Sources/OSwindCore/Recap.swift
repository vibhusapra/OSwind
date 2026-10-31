import Foundation
import CSQLite

public struct RecapSource:Codable,Equatable,Sendable {
    public var id,revision,match:String
    public var score:Double
    public var passage:PassageRange?
    public var historicalHandle:String? = nil
    public init(id:String,revision:String,match:String,score:Double,passage:PassageRange?=nil) {self.id=id;self.revision=revision;self.match=match;self.score=score;self.passage=passage}
}
public struct RecapSourceCard:Identifiable,Sendable {
    public let id,title,app,revision:String
    public let timestamp:Date
    public let passage:PassageRange?
    public var historicalHandle:String? = nil
}
public struct RecapProvenance:Codable,Equatable,Sendable {
    public var provider:String
    public var sources:[RecapSource]
    public init(provider:String,sources:[RecapSource]) {self.provider=provider;self.sources=sources}
    func validated() throws -> Self {
        guard !provider.isEmpty,provider.utf8.count<=128,!provider.utf8.contains(0),(1...60).contains(sources.count),try JSONEncoder().encode(self).count<=65536 else {throw OSwindError.invalid("A linked recap needs 1–60 sources and bounded provider metadata")}
        for source in sources {
            if let handle=source.historicalHandle {try SyncProtocolLimits.uuid(handle)}
            guard !source.id.isEmpty,source.id.count<200,!source.id.utf8.contains(0),!source.revision.isEmpty,source.revision.utf8.count<=512,source.match.utf8.count<=128,source.score.isFinite,abs(source.score)<=1_000_000 else {throw OSwindError.invalid("Invalid recap source metadata")}
        }
        return self
    }
}
enum RecapSchema {
    static let closure="""
    WITH RECURSIVE affected(id) AS (
        SELECT recap_id FROM recap_sources WHERE COALESCE(owner_id,source_id)=?
        UNION SELECT r.recap_id FROM recap_sources r JOIN affected a ON COALESCE(r.owner_id,r.source_id)=a.id
    ) SELECT id FROM affected WHERE id<>?
    """
    static func descendants(_ root:String) -> String {"""
    WITH RECURSIVE affected(id) AS (
        SELECT recap_id FROM recap_sources WHERE COALESCE(owner_id,source_id)=\(root)
        UNION SELECT r.recap_id FROM recap_sources r JOIN affected a ON COALESCE(r.owner_id,r.source_id)=a.id
    ) SELECT id FROM affected WHERE id<>\(root)
    """}
    static let sql="""
    \(CitationSchema.recap().replacingOccurrences(of:"CREATE TABLE ",with:"CREATE TABLE IF NOT EXISTS "));
    CREATE INDEX IF NOT EXISTS recap_source ON recap_sources(source_id,recap_id);
    DROP TRIGGER IF EXISTS recap_source_erasure;
    DROP TRIGGER IF EXISTS recap_source_revision;
    CREATE TRIGGER recap_source_erasure BEFORE DELETE ON memories BEGIN
        DELETE FROM memories WHERE id IN (\(descendants("old.id")));
    END;
    CREATE TRIGGER recap_source_revision BEFORE UPDATE OF title,app,text,url,timestamp,kind ON memories
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
        guard !answer.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,answer.text.count<=100_000,(1...60).contains(answer.sources.count),answer.sources.allSatisfy({$0.memory.searchPreview==nil && $0.memory.originalEvidence==nil}) else {throw OSwindError.invalid("Save a recap with 1–60 complete recorded sources")}
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
        guard let memory=try get(id) else {throw OSwindError.invalid("Linked recap not found")}
        return try recapSourceCards(memory)
    }
    /// Historical recaps carry ordered explicit parent handles. Neither this
    /// path nor card navigation may resolve those links through current IDs.
    public func recapSourceCards(_ memory:Memory) throws -> [RecapSourceCard] {
        try recapEvidence(memory).map {hit in
            .init(id:hit.id,title:String(hit.memory.title.prefix(500)),app:hit.memory.app,revision:hit.memory.evidenceHash,timestamp:hit.memory.timestamp,passage:hit.passage,historicalHandle:hit.memory.originalEvidence?.handle)
        }
    }
    public func recapEvidence(_ id:String) throws -> [SearchHit] {
        guard let memory=try get(id) else {throw OSwindError.invalid("Linked recap not found")}
        return try recapEvidence(memory)
    }
    public func recapEvidence(_ memory:Memory) throws -> [SearchHit] {
        let activity=try mediaWriteLease();defer {activity.release()}
        return try withRoutineDatabase {db in
            try db.execute("SAVEPOINT recap_evidence");defer {try? db.execute("RELEASE recap_evidence")}
            let current=try hydrate(memory)
            guard let recap=current.recap,current.recap==memory.recap else {throw OSwindError.invalid("Linked recap changed or was removed")}
            _=try recap.validated()
            return try recap.sources.map {source in
                let parent=try recapParent(source,db:db)
                return SearchHit(memory:parent,score:source.score,match:source.match,passage:source.passage)
            }
        }
    }
    public func recapSourceMemory(_ card:RecapSourceCard) throws -> Memory {
        let current:Memory
        if let handle=card.historicalHandle {current=try historicalMemory(handle)}
        else {guard let value=try get(card.id) else {throw OSwindError.unavailable("This original was removed")};current=value}
        guard current.id==card.id,current.evidenceHash==card.revision else {throw OSwindError.unavailable("This original changed or was removed. Open the current history instead.")}
        if let passage=card.passage,passage.text(in:current.text)==nil {throw OSwindError.invalid("The saved source anchor is no longer available")}
        return current
    }
    private func recapParent(_ source:RecapSource,db:RoutineDatabase) throws -> Memory {
        let current:Memory
        if let handle=source.historicalHandle {
            let native=source.id=="original-"+handle
            current=try historicalEvidence(db,handle,sourceID:native ? nil:source.id).memory
        } else {
            guard let value=try get(source.id) else {throw OSwindError.unavailable("Recap evidence was removed")};current=value
        }
        guard current.evidenceHash==source.revision else {throw OSwindError.unavailable("Recap evidence changed or was removed")}
        if let passage=source.passage,passage.text(in:current.text)==nil {throw OSwindError.invalid("Recap passage is outside its source")}
        return current
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
            guard source.id != id else {throw OSwindError.invalid("Recap source links must not form a cycle")}
            _=try recapParent(source,db:db)
            let cycle=try db.statement("WITH RECURSIVE parents(id) AS (SELECT ? UNION SELECT COALESCE(r.owner_id,r.source_id) FROM recap_sources r JOIN parents p ON r.recap_id=p.id) SELECT 1 FROM parents WHERE id=? LIMIT 1");defer {sqlite3_finalize(cycle)};db.bind(cycle,1,source.id);db.bind(cycle,2,id)
            let status=sqlite3_step(cycle);guard status==SQLITE_DONE else {if status==SQLITE_ROW {throw OSwindError.invalid("Recap source links must not form a cycle")};throw db.error()}
        }
    }
    func replaceRecapLinks(_ memory:Memory,deferred:Bool) throws {
        guard let recap=memory.recap,!deferred else {return}
        try withRoutineDatabase {db in
            try validateRecapParents(memory.id,recap:recap,db:db)
            let remove=try db.statement("DELETE FROM recap_sources WHERE recap_id=?");defer {sqlite3_finalize(remove)};db.bind(remove,1,memory.id);try db.done(remove)
            let row=try db.statement("INSERT INTO recap_sources(recap_id,source_id,ordinal,revision,score,match,passage_start,passage_length,owner_id,historical_handle) VALUES(?,?,?,?,?,?,?,?,?,?)");defer {sqlite3_finalize(row)}
            for (i,source) in recap.sources.enumerated() {
                sqlite3_reset(row);sqlite3_clear_bindings(row);db.bind(row,1,memory.id);if let handle=source.historicalHandle {db.bind(row,9,source.id);db.bind(row,10,handle)} else {db.bind(row,2,source.id)};sqlite3_bind_int(row,3,Int32(i));db.bind(row,4,source.revision);sqlite3_bind_double(row,5,source.score);db.bind(row,6,source.match)
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
            // A killed full wipe owns this queue. Opening the library must not
            // synchronously drain its orphan inventory or bypass its admission barrier.
            guard try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='library_wipe_dirty' AND value='1'")==0 else {return nil}
            guard try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='recap_cache_dirty' AND value='1'")>0 else {return nil}
            return cleanupErasedAssets(db,sources:0,turns:0)
        }
    }
}
