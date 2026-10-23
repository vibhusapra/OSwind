import Foundation
import CSQLite

public final class MemoryStore: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var metalScopeCache: MetalScopeCache?
    private var coverageCache = [(key:MetalScopeKey,indexed:Int,total:Int)]()
    private let annCache: ANNCache
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(root: URL = Paths.data) throws {
        self.root = root; annCache = ANNCache(root:root); try Paths.ensure(root); try Paths.ensure(root.appendingPathComponent("images")); try Paths.ensure(root.appendingPathComponent("audio"))
        let path = root.appendingPathComponent("memory.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw OSwindError.database("Cannot open memory store") }
        sqlite3_busy_timeout(db, 5000)
        let versionStatement = try prepare("PRAGMA user_version")
        let version = sqlite3_step(versionStatement) == SQLITE_ROW ? sqlite3_column_int(versionStatement,0) : Int32.max; sqlite3_finalize(versionStatement)
        guard version <= 5 else { sqlite3_close(db); db = nil; throw OSwindError.unavailable("This memory store was created by a newer OSwind version. Update OSwind before opening it.") }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON;")
        try exec("BEGIN IMMEDIATE")
        do {
        try exec("""
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY, timestamp REAL NOT NULL, kind TEXT NOT NULL, app TEXT NOT NULL,
            title TEXT NOT NULL, url TEXT, text TEXT NOT NULL, favorite INTEGER NOT NULL DEFAULT 0,
            payload BLOB NOT NULL, embedding BLOB, embedding_model TEXT
        );
        CREATE INDEX IF NOT EXISTS memories_time ON memories(timestamp DESC);
        CREATE INDEX IF NOT EXISTS memories_app_time ON memories(app, timestamp DESC);
        CREATE INDEX IF NOT EXISTS memories_embedding_model ON memories(embedding_model);
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(id UNINDEXED, title, app, text, tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS memory_insert AFTER INSERT ON memories BEGIN
            INSERT INTO memory_fts(id,title,app,text) VALUES(new.id,new.title,new.app,new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_delete AFTER DELETE ON memories BEGIN
            DELETE FROM memory_fts WHERE id=old.id;
        END;
        CREATE TRIGGER IF NOT EXISTS memory_update AFTER UPDATE ON memories BEGIN
            DELETE FROM memory_fts WHERE id=old.id;
            INSERT INTO memory_fts(id,title,app,text) VALUES(new.id,new.title,new.app,new.text);
        END;
        CREATE TABLE IF NOT EXISTS semantic_vectors (
            memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            model TEXT NOT NULL, dimension INTEGER NOT NULL, vector BLOB NOT NULL,
            content_hash TEXT NOT NULL, PRIMARY KEY(memory_id,model)
        );
        CREATE INDEX IF NOT EXISTS semantic_model ON semantic_vectors(model);
        CREATE TRIGGER IF NOT EXISTS semantic_content_update AFTER UPDATE OF title,app,text,url ON memories
        WHEN old.title IS NOT new.title OR old.app IS NOT new.app OR old.text IS NOT new.text OR old.url IS NOT new.url
        BEGIN DELETE FROM semantic_vectors WHERE memory_id=new.id; END;
        CREATE TABLE IF NOT EXISTS chat_sessions (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chat_turns (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL, payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS chat_session_time ON chat_turns(session_id,timestamp);
        CREATE TABLE IF NOT EXISTS chat_sources (
            turn_id TEXT NOT NULL REFERENCES chat_turns(id) ON DELETE CASCADE,
            memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL, score REAL NOT NULL, match TEXT NOT NULL,
            PRIMARY KEY(turn_id,ordinal)
        );
        CREATE INDEX IF NOT EXISTS chat_source_memory ON chat_sources(memory_id);
        DROP TRIGGER IF EXISTS chat_source_erasure;
        CREATE TRIGGER chat_source_erasure BEFORE DELETE ON memories BEGIN
            UPDATE chat_sessions SET title='Conversation' WHERE id IN (SELECT t.session_id FROM chat_turns t JOIN chat_sources s ON s.turn_id=t.id WHERE s.memory_id=old.id);
            DELETE FROM chat_turns WHERE id IN (SELECT turn_id FROM chat_sources WHERE memory_id=old.id);
        END;
        DROP TRIGGER IF EXISTS chat_source_revision;
        CREATE TRIGGER chat_source_revision BEFORE UPDATE OF title,app,text,url,timestamp,kind ON memories
        WHEN old.title IS NOT new.title OR old.app IS NOT new.app OR old.text IS NOT new.text OR old.url IS NOT new.url OR old.timestamp IS NOT new.timestamp OR old.kind IS NOT new.kind
        BEGIN
            UPDATE chat_sessions SET title='Conversation' WHERE id IN (SELECT t.session_id FROM chat_turns t JOIN chat_sources s ON s.turn_id=t.id WHERE s.memory_id=old.id);
            DELETE FROM chat_turns WHERE id IN (SELECT turn_id FROM chat_sources WHERE memory_id=old.id);
        END;
        """)
        try exec(VectorJournalSchema.sql)
        if version < 4 { try exec(VectorJournalSchema.backfill) }
        try exec(StatisticsSchema.sql)
        try exec(SearchScopeSchema.sql)
        let statisticsState = try prepare("SELECT total=COALESCE((SELECT SUM(count) FROM application_statistics),0) FROM memory_statistics WHERE singleton=1")
        let statisticsNeedRepair = sqlite3_step(statisticsState) != SQLITE_ROW || sqlite3_column_int(statisticsState,0) != 1
        sqlite3_finalize(statisticsState)
        if version < 5 || statisticsNeedRepair { try exec(StatisticsSchema.backfill) }
        if version < 5 { try exec(StatisticsSchema.selectiveFTSUpdate) }
        try exec("PRAGMA user_version=5; COMMIT")
        } catch { try? exec("ROLLBACK"); sqlite3_close(db); db = nil; throw error }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    deinit { annCache.cancel(); sqlite3_close(db) }
    private func exec(_ sql: String) throws { if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw failure() } }
    private func failure() -> OSwindError { .database(String(cString: sqlite3_errmsg(db))) }
    private func prepare(_ sql: String) throws -> OpaquePointer { var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }; return stmt }
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) { if let value { sqlite3_bind_text(stmt, index, value, -1, transient) } else { sqlite3_bind_null(stmt, index) } }
    private func string(_ stmt: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "" }
    private func decode(_ stmt: OpaquePointer, column: Int32 = 0) throws -> Memory {
        guard let bytes = sqlite3_column_blob(stmt, column) else { throw OSwindError.database("Missing payload") }
        return try JSONDecoder().decode(Memory.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column))))
    }
    public func insert(_ memory: Memory) throws {
        lock.lock(); defer { lock.unlock() }
        guard !memory.id.isEmpty, memory.id.count < 200, memory.text.count <= 1_000_000 else { throw OSwindError.invalid("Invalid memory size or identifier") }
        for path in [memory.imagePath, memory.audioPath].compactMap({$0}) { guard assetURL(path) != nil else { throw OSwindError.invalid("Asset path must stay inside the memory store") } }
        let stmt = try prepare("INSERT INTO memories(id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET timestamp=excluded.timestamp,kind=excluded.kind,app=excluded.app,title=excluded.title,url=excluded.url,text=excluded.text,favorite=excluded.favorite,payload=excluded.payload,embedding=excluded.embedding,embedding_model=excluded.embedding_model")
        defer { sqlite3_finalize(stmt) }
        var payload = memory; payload.embedding = nil
        let data = try JSONEncoder().encode(payload)
        bind(stmt, 1, memory.id); sqlite3_bind_double(stmt, 2, memory.timestamp.timeIntervalSince1970); bind(stmt, 3, memory.kind.rawValue); bind(stmt, 4, memory.app); bind(stmt, 5, memory.title); bind(stmt, 6, memory.url); bind(stmt, 7, memory.text); sqlite3_bind_int(stmt, 8, memory.favorite ? 1 : 0)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 9, $0.baseAddress, Int32(data.count), transient) }
        if let vector = memory.embedding, !vector.isEmpty, vector.allSatisfy({$0.isFinite}) { _ = vector.withUnsafeBytes { sqlite3_bind_blob(stmt, 10, $0.baseAddress, Int32($0.count), transient) } }
        bind(stmt, 11, memory.embeddingModel)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    public func assetURL(_ relative: String) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, ["images", "audio"].contains(String(parts[0])), !relative.hasPrefix("/"), !parts.contains(".."), !parts.contains("") else { return nil }
        var walking = root
        for part in parts {
            walking.appendPathComponent(String(part))
            if let attrs = try? FileManager.default.attributesOfItem(atPath: walking.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { return nil }
        }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { return nil }
        return candidate
    }
    public func get(_ id: String) throws -> Memory? {
        lock.lock(); defer { lock.unlock() }; let stmt = try prepare("SELECT payload FROM memories WHERE id=?"); defer { sqlite3_finalize(stmt) }; bind(stmt, 1, id); return sqlite3_step(stmt) == SQLITE_ROW ? try decode(stmt) : nil
    }
    private func conditions(_ filter: SearchFilter, prefix: String = "m.") -> (String, [String]) {
        var parts = ["1=1"]; var values = [String]()
        if let app = filter.app, !app.isEmpty { parts.append("\(prefix)app=?"); values.append(app) }
        if let kind = filter.kind { parts.append("\(prefix)kind=?"); values.append(kind.rawValue) }
        if let start = filter.start { parts.append("\(prefix)timestamp>=?"); values.append(String(start.timeIntervalSince1970)) }
        if let end = filter.end { parts.append("\(prefix)timestamp<?"); values.append(String(end.timeIntervalSince1970)) }
        if filter.favoritesOnly { parts.append("\(prefix)favorite=1") }
        if let tag = filter.tag { parts.append("EXISTS (SELECT 1 FROM json_each(CAST(\(prefix)payload AS TEXT), '$.tags') WHERE value=?)"); values.append(tag) }
        return (parts.joined(separator: " AND "), values)
    }
    public static func queryTerms(_ input: String) -> [String] {
        let stopwords: Set<String> = ["a","an","the","and","or","is","are","was","were","be","been","being","to","of","for","in","on","at","by","from","with","as","it","its","s","t","do","does","did","can","could","would","should","will","we","our","i","my","me","you","your","they","their","this","that","these","those","what","which","who","when","where","how","why","about","before","after","la","le","les","el","los","las","de","del","du","des","un","une","en","et","y","que","qui","comment","por","para"]
        let all = input.lowercased().split(whereSeparator:{ !$0.isLetter && !$0.isNumber }).map(String.init)
        let content = all.filter { !stopwords.contains($0) }
        return Array((content.isEmpty ? all : content).prefix(24))
    }
    public static func ftsQuery(_ input: String) -> String { queryTerms(input).map { "\"\($0)\"*" }.joined(separator:" OR ") }
    private static func keywordBonus(query: String, memory: Memory, rank: Int) -> Double {
        let terms = queryTerms(query); guard !terms.isEmpty else { return 0 }
        let words = memory.searchableText.lowercased().split(whereSeparator:{ !$0.isLetter && !$0.isNumber })
        let coverage = Double(terms.filter { term in words.contains { $0.hasPrefix(term) } }.count)/Double(terms.count)
        // A bounded lexical bonus breaks close semantic ties without letting a
        // single matching question word overwhelm a cross-language match.
        return 0.08 * coverage / (1 + Double(rank)*0.1)
    }
    public func search(_ filter: SearchFilter, mode: SearchMode = .hybrid, vector: [Float]? = nil, modelID: String? = nil, minimumSimilarity: Double = 0.15, similarityFusion: Bool = false, indexPolicy: SearchIndexPolicy = .exact, indexedCount: Int? = nil, allowIndexOnLowPower: Bool = false, execution: ((SearchExecution) -> Void)? = nil) throws -> [SearchHit] {
        try Task.checkCancellation()
        var indexStatus: SearchIndexStatus?
        let scoped = conditions(filter).0 != "1=1"
        // Current measured native predicate callbacks cost more than a scoped
        // exact scan. Keep Automatic conservative until scoped indexing improves.
        if mode != .keyword, !Self.ftsQuery(filter.query).isEmpty, let vector, let modelID, indexPolicy != .exact, indexPolicy == .indexed || !scoped {
            let count = try indexedCount ?? vectorCount(modelID:modelID,filter:filter)
            if indexPolicy == .indexed || count >= 20_000 { indexStatus = annCache.prepare(modelID:modelID,dimensions:vector.count,count:count,allowLowPower:allowIndexOnLowPower) }
        }
        lock.lock(); defer { lock.unlock() }
        try exec("SAVEPOINT search_snapshot"); defer { try? exec("RELEASE search_snapshot") }
        var strategy = "exact", diagnostics = [String]()
        let limit = min(500, max(1, filter.limit)); let (whereSQL, values) = conditions(filter)
        let query = Self.ftsQuery(filter.query)
        var keyword = [Memory](); var scored = [String: SearchHit]()
        if query.isEmpty || mode != .semantic {
            let sql = query.isEmpty ? "SELECT m.payload FROM memories m WHERE \(whereSQL) ORDER BY m.timestamp DESC LIMIT ?" : "SELECT m.payload FROM memory_fts f JOIN memories m ON m.id=f.id WHERE memory_fts MATCH ? AND \(whereSQL) ORDER BY bm25(memory_fts,0,3,1,1) LIMIT ?"
            let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }; var index: Int32 = 1
            if !query.isEmpty { bind(stmt, index, query); index += 1 }
            for value in values { bind(stmt, index, value); index += 1 }; sqlite3_bind_int(stmt, index, Int32(query.isEmpty ? limit : max(limit, 100)))
            while sqlite3_step(stmt) == SQLITE_ROW { keyword.append(try decode(stmt)) }
            for (rank, memory) in keyword.enumerated() { scored[memory.id] = SearchHit(memory: memory, score: query.isEmpty ? memory.timestamp.timeIntervalSince1970 : (similarityFusion && mode == .hybrid ? Self.keywordBonus(query:filter.query,memory:memory,rank:rank) : 1 / Double(60 + rank)), match: query.isEmpty ? "recent" : "keyword") }
        }
        if !query.isEmpty, mode != .keyword, let vector, let modelID, let scorer = CosineScorer(vector) {
            var indexed: [SemanticCandidate]?
            var candidateStrategy = "ann-exact-rerank"
            if indexStatus != nil {
                do { indexed = try indexedCandidates(filter,modelID:modelID,dimensions:vector.count,scorer:scorer,minimumSimilarity:minimumSimilarity,limit:max(limit,100),strategy:{ candidateStrategy = $0 }) }
                catch { diagnostics.append("Fast index unavailable; exact search used. "+error.localizedDescription) }
                if indexed == nil && diagnostics.isEmpty {
                    diagnostics.append(indexStatus!.state == "ready" ? "Fast index is catching up; exact search used." : indexStatus!.message + " · exact search used.")
                }
            }
            let best: [SemanticCandidate]
            if let indexed { best = indexed; strategy = candidateStrategy }
            else {
            let vectorJoin = whereSQL == "1=1" ? "semantic_vectors v JOIN memories m ON m.id=v.memory_id" : "memories m CROSS JOIN semantic_vectors v ON m.id=v.memory_id"
            let stmt = try prepare("SELECT m.id,m.embedding,m.timestamp FROM memories m WHERE \(whereSQL) AND embedding IS NOT NULL AND embedding_model=? AND NOT EXISTS (SELECT 1 FROM semantic_vectors v WHERE v.memory_id=m.id AND v.model=m.embedding_model) UNION ALL SELECT m.id,v.vector,m.timestamp FROM \(vectorJoin) WHERE \(whereSQL) AND v.model=?")
            defer { sqlite3_finalize(stmt) }; for (i,v) in values.enumerated() { bind(stmt, Int32(i+1), v) }; bind(stmt, Int32(values.count + 1), modelID)
            for (i,v) in values.enumerated() { bind(stmt,Int32(values.count+2+i),v) }; bind(stmt,Int32(2*values.count+2),modelID)
            var candidates = SemanticTopK(capacity:max(limit,100))
            var scanned = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                scanned += 1; if scanned % 256 == 0 { try Task.checkCancellation() }
                let size = Int(sqlite3_column_bytes(stmt, 1)); guard size == vector.count * MemoryLayout<Float>.size, let bytes = sqlite3_column_blob(stmt, 1) else { continue }
                let similarity = scorer.score(bytes.assumingMemoryBound(to:Float.self),count:vector.count)
                if similarity > minimumSimilarity, candidates.mayImprove(similarity) { candidates.offer(SemanticCandidate(id:string(stmt,0),similarity:similarity,timestamp:sqlite3_column_double(stmt,2))) }
            }
            best = candidates.sorted
            }
            for (rank, pair) in best.enumerated() {
                if var hit = scored[pair.id] { hit.score += similarityFusion ? pair.similarity : 1 / Double(60 + rank); hit.match = "hybrid"; scored[pair.id] = hit }
                else if let memory = try get(pair.id) { scored[pair.id] = SearchHit(memory: memory, score: mode == .semantic || similarityFusion ? pair.similarity : 1 / Double(60 + rank), match: "semantic") }
            }
        }
        try Task.checkCancellation(); execution?(SearchExecution(strategy:strategy,warnings:diagnostics))
        return Array(scored.values.sorted { a,b in a.score != b.score ? a.score > b.score : a.memory.timestamp != b.memory.timestamp ? a.memory.timestamp > b.memory.timestamp : a.id < b.id }.prefix(limit))
    }
    public func matchingCount(_ filter: SearchFilter = SearchFilter()) throws -> Int {
        lock.lock(); defer { lock.unlock() }; let (whereSQL,values) = conditions(filter)
        let stmt = try prepare(whereSQL == "1=1" ? "SELECT total FROM memory_statistics WHERE singleton=1" : "SELECT COUNT(*) FROM memories m WHERE \(whereSQL)"); defer { sqlite3_finalize(stmt) }
        for (i,v) in values.enumerated() { bind(stmt,Int32(i+1),v) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt,0)) : 0
    }
    public func vectorCount(modelID: String, filter: SearchFilter = SearchFilter()) throws -> Int {
        lock.lock(); defer { lock.unlock() }; let (whereSQL,values) = conditions(filter)
        let sql = whereSQL == "1=1" ? "SELECT COUNT(*) FROM vector_keys WHERE model=?" : "SELECT COUNT(*) FROM memories m CROSS JOIN vector_keys r ON r.memory_id=m.id WHERE r.model=? AND \(whereSQL)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }; bind(stmt,1,modelID); for (i,v) in values.enumerated() { bind(stmt,Int32(i+2),v) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt,0)) : 0
    }
    /// Coverage counts have the same scope as retrieval, independent of query
    /// words. Reuse only within an unchanged transactional metadata/vector state.
    public func indexCoverage(modelID: String, filter: SearchFilter = SearchFilter()) throws -> (indexed:Int,total:Int) {
        lock.lock(); defer { lock.unlock() }
        try exec("SAVEPOINT coverage_snapshot"); defer { try? exec("RELEASE coverage_snapshot") }
        let state = try prepare("SELECT (SELECT value FROM store_metadata WHERE key='identity'),COALESCE((SELECT MAX(seq) FROM vector_changes),0),(SELECT hex(revision) FROM search_scope_revision WHERE singleton=1)")
        defer { sqlite3_finalize(state) }; guard sqlite3_step(state) == SQLITE_ROW else { throw failure() }
        let (predicate,values) = conditions(filter), revision = string(state,2)
        let key = MetalScopeKey(identity:string(state,0),model:modelID,sequence:sqlite3_column_int64(state,1),revision:revision,predicate:predicate,values:values)
        coverageCache.removeAll { $0.key.identity != key.identity || $0.key.model != key.model || $0.key.sequence != key.sequence || $0.key.revision != key.revision }
        if !revision.isEmpty, let index = coverageCache.firstIndex(where:{$0.key == key}) {
            let cached = coverageCache.remove(at:index); coverageCache.append(cached); return (cached.indexed,cached.total)
        }
        let indexed = try vectorCount(modelID:modelID,filter:filter), total = try matchingCount(filter)
        if !revision.isEmpty { coverageCache.append((key,indexed,total)); if coverageCache.count > 4 { coverageCache.removeFirst() } }
        return (indexed,total)
    }
    public func memoriesNeedingVectors(modelID: String, afterID: String = "", limit: Int = 16) throws -> [Memory] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT m.payload FROM memories m LEFT JOIN semantic_vectors v ON v.memory_id=m.id AND v.model=? WHERE v.memory_id IS NULL AND m.id>? ORDER BY m.id LIMIT ?")
        defer { sqlite3_finalize(stmt) }; bind(stmt,1,modelID); bind(stmt,2,afterID); sqlite3_bind_int(stmt,3,Int32(min(32,max(1,limit))))
        var memories = [Memory](); while sqlite3_step(stmt) == SQLITE_ROW { memories.append(try decode(stmt)) }; return memories
    }
    @discardableResult public func saveVectors(_ records: [VectorRecord], modelID: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }; try exec("BEGIN IMMEDIATE"); var count = 0
        do {
            for record in records {
                guard !record.vector.isEmpty, record.vector.count <= 8192, record.vector.allSatisfy(\.isFinite), let memory = try get(record.memoryID), memory.contentHash == record.contentHash else { continue }
                let stmt = try prepare("INSERT INTO semantic_vectors(memory_id,model,dimension,vector,content_hash) VALUES(?,?,?,?,?) ON CONFLICT(memory_id,model) DO UPDATE SET dimension=excluded.dimension,vector=excluded.vector,content_hash=excluded.content_hash")
                defer { sqlite3_finalize(stmt) }; bind(stmt,1,record.memoryID); bind(stmt,2,modelID); sqlite3_bind_int(stmt,3,Int32(record.vector.count)); _ = record.vector.withUnsafeBytes { sqlite3_bind_blob(stmt,4,$0.baseAddress,Int32($0.count),transient) }; bind(stmt,5,record.contentHash)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }; count += 1
            }
            try exec("COMMIT"); return count
        } catch { try? exec("ROLLBACK"); throw error }
    }
    public func semanticIndexes() throws -> [String:Int] {
        lock.lock(); defer { lock.unlock() }; let stmt = try prepare("SELECT model,COUNT(*) FROM semantic_vectors GROUP BY model"); defer { sqlite3_finalize(stmt) }; var result = [String:Int](); while sqlite3_step(stmt) == SQLITE_ROW { result[string(stmt,0)] = Int(sqlite3_column_int(stmt,1)) }; return result
    }
    public func timelineSample(_ filter: SearchFilter, limit: Int = 24) throws -> [Memory] {
        lock.lock(); defer { lock.unlock() }
        let count = min(100, max(2, limit)), (whereSQL, values) = conditions(filter)
        let stmt = try prepare("WITH ranked AS (SELECT payload,ROW_NUMBER() OVER (ORDER BY timestamp) AS rn,COUNT(*) OVER () AS total FROM memories m WHERE \(whereSQL)) SELECT payload FROM ranked WHERE rn=1 OR rn=total OR (rn-1) % MAX(1,CAST((total-1)/? AS INTEGER))=0 ORDER BY rn")
        defer { sqlite3_finalize(stmt) }
        for (index,value) in values.enumerated() { bind(stmt,Int32(index+1),value) }; sqlite3_bind_int(stmt,Int32(values.count+1),Int32(count-1))
        var memories = [Memory](); while sqlite3_step(stmt) == SQLITE_ROW { memories.append(try decode(stmt)) }
        if memories.count <= count { return memories }
        return (0..<count).map { memories[Int(Double($0)*Double(memories.count-1)/Double(count-1))] }
    }
    public func setFavorite(_ id: String, value: Bool) throws { if var m = try get(id) { m.favorite = value; try updateMetadata(m) } }
    public func setTags(_ id: String, tags: [String]) throws { if var m = try get(id) { m.tags = Array(Set(tags.filter { !$0.isEmpty })).sorted(); try updateMetadata(m) } }
    private func updateMetadata(_ m: Memory) throws {
        lock.lock(); defer { lock.unlock() }; let stmt = try prepare("UPDATE memories SET payload=?,favorite=? WHERE id=?"); defer { sqlite3_finalize(stmt) }; let data = try JSONEncoder().encode(m); _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), transient) }; sqlite3_bind_int(stmt, 2, m.favorite ? 1 : 0); bind(stmt, 3, m.id); guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    public func delete(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }; let m = try get(id); let stmt = try prepare("DELETE FROM memories WHERE id=?"); defer { sqlite3_finalize(stmt) }; bind(stmt, 1, id); guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        for path in [m?.imagePath, m?.audioPath].compactMap({$0}) { if let url = assetURL(path) { try? FileManager.default.removeItem(at: url) } }
    }
    @discardableResult public func prune(before: Date, maxBytes: Int64? = nil) throws -> Int {
        lock.lock(); defer { lock.unlock() }; var ids = [String](); let stmt = try prepare("SELECT id FROM memories WHERE timestamp<?"); sqlite3_bind_double(stmt, 1, before.timeIntervalSince1970); while sqlite3_step(stmt) == SQLITE_ROW { ids.append(string(stmt,0)) }; sqlite3_finalize(stmt)
        let titles = try prepare("UPDATE chat_sessions SET title='Conversation' WHERE id IN (SELECT session_id FROM chat_turns WHERE timestamp<?)"); sqlite3_bind_double(titles,1,before.timeIntervalSince1970); guard sqlite3_step(titles) == SQLITE_DONE else { sqlite3_finalize(titles); throw failure() }; sqlite3_finalize(titles)
        let chats = try prepare("DELETE FROM chat_turns WHERE timestamp<?"); sqlite3_bind_double(chats,1,before.timeIntervalSince1970); guard sqlite3_step(chats) == SQLITE_DONE else { sqlite3_finalize(chats); throw failure() }; sqlite3_finalize(chats)
        for id in ids { try delete(id) }; var deleted = ids.count
        if let maxBytes, diskBytes() > maxBytes {
            // Drop rebuildable graph storage before sacrificing recorded evidence.
            try exec("UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='identity'")
            metalScopeCache = nil; coverageCache.removeAll(); annCache.reset(); let cache = root.appendingPathComponent("indexes")
            if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.removeItem(at:cache) }
        }
        if let maxBytes, diskBytes() > maxBytes { try exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"); var size = diskBytes(); let stmt = try prepare("SELECT id FROM memories ORDER BY timestamp"); var oldest = [String](); while sqlite3_step(stmt) == SQLITE_ROW { oldest.append(string(stmt,0)) }; sqlite3_finalize(stmt)
            for (index,id) in oldest.enumerated() {
                guard size > maxBytes else { break }
                try delete(id); deleted += 1
                // Reclaim freed SQLite pages periodically, rather than deleting the entire
                // archive against an allocated database file that never shrinks.
                if index % 16 == 15 || index == oldest.count-1 { try exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;") }
                size = diskBytes()
            }
        }
        if deleted > 0 { try exec("PRAGMA wal_checkpoint(TRUNCATE);") }
        return deleted
    }
    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do { try exec("DELETE FROM chat_sessions; DELETE FROM memories; DELETE FROM vector_changes; UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='identity'; COMMIT") } catch { try? exec("ROLLBACK"); throw error }
        metalScopeCache = nil; coverageCache.removeAll(); annCache.reset(); let cache = root.appendingPathComponent("indexes")
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.removeItem(at:cache) }
        try exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        for folder in ["images", "audio"] { let url = root.appendingPathComponent(folder); try FileManager.default.removeItem(at: url); try Paths.ensure(url) }
    }
    public func diskBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0; for case let url as URL in enumerator { if let values = try? url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey]), values.isRegularFile == true { total += Int64(values.fileSize ?? 0) } }; return total
    }
    /// Counts and extrema are a short consistent SQL snapshot. File traversal
    /// runs after releasing the store lock, so it cannot stall capture/search.
    public func stats(includeDiskUsage: Bool = true) throws -> StoreStats {
        var stats = try metadataStatistics()
        if includeDiskUsage { stats.bytes = diskBytes() }
        return stats
    }
    private func metadataStatistics() throws -> StoreStats {
        lock.lock(); defer { lock.unlock() }
        try exec("SAVEPOINT statistics_snapshot"); defer { try? exec("RELEASE statistics_snapshot") }
        var stats = StoreStats()
        let stmt = try prepare("SELECT total,screens,audio,embedded,(SELECT timestamp FROM memories ORDER BY timestamp LIMIT 1),(SELECT timestamp FROM memories ORDER BY timestamp DESC LIMIT 1) FROM memory_statistics WHERE singleton=1")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw OSwindError.database("Statistics metadata is missing; reopen or repair the store") }
        stats.count = Int(sqlite3_column_int64(stmt,0)); stats.screenshots = Int(sqlite3_column_int64(stmt,1)); stats.audioSegments = Int(sqlite3_column_int64(stmt,2)); stats.embedded = Int(sqlite3_column_int64(stmt,3))
        if stats.count > 0 { stats.oldest = Date(timeIntervalSince1970:sqlite3_column_double(stmt,4)); stats.newest = Date(timeIntervalSince1970:sqlite3_column_double(stmt,5)) }
        let apps = try prepare("SELECT app,count FROM application_statistics ORDER BY count DESC,app")
        defer { sqlite3_finalize(apps) }; var status = sqlite3_step(apps)
        while status == SQLITE_ROW { stats.apps[string(apps,0)] = Int(sqlite3_column_int64(apps,1)); status = sqlite3_step(apps) }
        guard status == SQLITE_DONE else { throw failure() }; return stats
    }
    public func exportJSON(to url: URL) throws {
        lock.lock(); defer { lock.unlock() }; let stmt = try prepare("SELECT payload FROM memories ORDER BY timestamp"); defer { sqlite3_finalize(stmt) }; var memories = [Memory](); while sqlite3_step(stmt) == SQLITE_ROW { memories.append(try decode(stmt)) }; let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601; try encoder.encode(memories).write(to: url, options: .atomic)
    }
    @discardableResult public func importJSON(from url: URL, embedder: LocalEmbedder? = nil, policy: PrivacyPolicy = PrivacyPolicy()) throws -> Int {
        let data = try Data(contentsOf: url); guard data.count <= 100_000_000 else { throw OSwindError.invalid("Import exceeds 100 MB") }; let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let memories: [Memory]
        do { memories = try decoder.decode([Memory].self, from: data) } catch { memories = try JSONDecoder().decode([Memory].self, from: data) }
        lock.lock(); defer { lock.unlock() }; try exec("BEGIN IMMEDIATE"); do {
            var count = 0
            for var m in memories { if policy.exclusion(app: m.bundleID, title: m.title, url: m.url) != nil { continue }; m.text = policy.sanitize(m.text).text; m.title = policy.sanitize(m.title).text; m.url = m.url.map { policy.sanitize($0).text }; m.imagePath = nil; m.audioPath = nil; m.regions = []; m.embedding = embedder?.embed(m.searchableText); m.embeddingModel = m.embedding == nil ? nil : embedder?.modelID; try insert(m); count += 1 }
            try exec("COMMIT"); return count
        } catch { try? exec("ROLLBACK"); throw error }
    }
}

extension MemoryStore {
    public var searchIndexStatus: SearchIndexStatus { annCache.status }
    @discardableResult public func buildSearchIndex(modelID: String, dimensions: Int, rebuild: Bool = false, allowLowPower: Bool = false) async throws -> SearchIndexStatus {
        let count = try vectorCount(modelID:modelID)
        guard count > 0 else { throw OSwindError.unavailable("No vectors exist for this model. Build its embedding index first.") }
        annCache.prepare(modelID:modelID,dimensions:dimensions,count:count,force:rebuild,allowLowPower:allowLowPower,replayAll:true,resumeBuild:true)
        return try await annCache.waitForBuild()
    }
    public func embeddingDimensions(modelID: String) throws -> Int? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT dimension FROM semantic_vectors WHERE model=? LIMIT 1"); defer { sqlite3_finalize(stmt) }; bind(stmt,1,modelID)
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int(stmt,0)) }
        let legacy = try prepare("SELECT length(embedding)/4 FROM memories WHERE embedding_model=? AND embedding IS NOT NULL LIMIT 1"); defer { sqlite3_finalize(legacy) }; bind(legacy,1,modelID)
        return sqlite3_step(legacy) == SQLITE_ROW ? Int(sqlite3_column_int(legacy,0)) : nil
    }
    public func cancelSearchIndexBuild(pauseAutomatic: Bool = false) { annCache.cancel(pauseAutomatic:pauseAutomatic) }
    public func releaseSearchIndex() { lock.lock(); metalScopeCache = nil; coverageCache.removeAll(); lock.unlock(); annCache.reset() }
    public func checkpointSearchIndexIfIdle(allowLowPower: Bool = false) throws { try annCache.checkpointIfIdle(allowLowPower:allowLowPower) }
}

extension MemoryStore {
    public func createChat(title: String = "New conversation") throws -> ChatSession {
        lock.lock(); defer { lock.unlock() }
        let session = ChatSession(id:UUID().uuidString,title:String(title.prefix(160)),created:Date(),updated:Date(),turnCount:0)
        let stmt = try prepare("INSERT INTO chat_sessions(id,title,created,updated) VALUES(?,?,?,?)"); defer { sqlite3_finalize(stmt) }
        bind(stmt,1,session.id); bind(stmt,2,session.title); sqlite3_bind_double(stmt,3,session.created.timeIntervalSince1970); sqlite3_bind_double(stmt,4,session.updated.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }; return session
    }
    public func chats(limit: Int = 100) throws -> [ChatSession] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT s.id,s.title,s.created,s.updated,COUNT(t.id) FROM chat_sessions s LEFT JOIN chat_turns t ON t.session_id=s.id GROUP BY s.id ORDER BY s.updated DESC,s.id LIMIT ?"); defer { sqlite3_finalize(stmt) }; sqlite3_bind_int(stmt,1,Int32(min(500,max(1,limit))))
        var sessions = [ChatSession]()
        while sqlite3_step(stmt) == SQLITE_ROW { sessions.append(ChatSession(id:string(stmt,0),title:string(stmt,1),created:Date(timeIntervalSince1970:sqlite3_column_double(stmt,2)),updated:Date(timeIntervalSince1970:sqlite3_column_double(stmt,3)),turnCount:Int(sqlite3_column_int(stmt,4)))) }
        return sessions
    }
    public func chat(_ id: String) throws -> ChatSession? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT title,created,updated,(SELECT COUNT(*) FROM chat_turns WHERE session_id=?) FROM chat_sessions WHERE id=?"); defer { sqlite3_finalize(stmt) }; bind(stmt,1,id); bind(stmt,2,id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return ChatSession(id:id,title:string(stmt,0),created:Date(timeIntervalSince1970:sqlite3_column_double(stmt,1)),updated:Date(timeIntervalSince1970:sqlite3_column_double(stmt,2)),turnCount:Int(sqlite3_column_int(stmt,3)))
    }
    public func deleteChat(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }; let stmt = try prepare("DELETE FROM chat_sessions WHERE id=?"); defer { sqlite3_finalize(stmt) }; bind(stmt,1,id); guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    @discardableResult public func appendChatTurn(sessionID: String, question: String, answer: Answer, filter: SearchFilter = SearchFilter(), policy: PrivacyPolicy = PrivacyPolicy()) throws -> ChatTurn {
        lock.lock(); defer { lock.unlock() }
        guard !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, question.count <= 8000, answer.text.count <= 100000, answer.sources.count <= 60 else { throw OSwindError.invalid("Invalid conversation turn size") }
        try exec("BEGIN IMMEDIATE")
        do {
            guard let session = try chat(sessionID) else { throw OSwindError.invalid("Conversation no longer exists") }
            for hit in answer.sources { guard let current = try get(hit.id), current.evidenceHash == hit.memory.evidenceHash else { throw OSwindError.unavailable("Evidence changed during the answer. Ask again using the remaining memories.") } }
            var scope = filter; scope.query = ""
            let payload = ChatPayload(question:policy.sanitize(question).text,text:policy.sanitize(answer.text).text,provider:answer.provider,duration:answer.duration,warnings:answer.warnings,filter:scope)
            let id = UUID().uuidString, timestamp = Date(), data = try JSONEncoder().encode(payload)
            let stmt = try prepare("INSERT INTO chat_turns(id,session_id,timestamp,payload) VALUES(?,?,?,?)"); defer { sqlite3_finalize(stmt) }
            bind(stmt,1,id); bind(stmt,2,sessionID); sqlite3_bind_double(stmt,3,timestamp.timeIntervalSince1970); _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt,4,$0.baseAddress,Int32(data.count),transient) }; guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            for (ordinal,hit) in answer.sources.enumerated() {
                let source = try prepare("INSERT INTO chat_sources(turn_id,memory_id,ordinal,score,match) VALUES(?,?,?,?,?)"); defer { sqlite3_finalize(source) }
                bind(source,1,id); bind(source,2,hit.id); sqlite3_bind_int(source,3,Int32(ordinal)); sqlite3_bind_double(source,4,hit.score); bind(source,5,hit.match); guard sqlite3_step(source) == SQLITE_DONE else { throw failure() }
            }
            let update = try prepare("UPDATE chat_sessions SET title=?,updated=? WHERE id=?"); defer { sqlite3_finalize(update) }
            bind(update,1,session.turnCount == 0 ? String(payload.question.replacingOccurrences(of:"\n",with:" ").prefix(80)) : session.title); sqlite3_bind_double(update,2,timestamp.timeIntervalSince1970); bind(update,3,sessionID); guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
            try exec("COMMIT")
            var cleanAnswer = answer; cleanAnswer.text = payload.text
            return ChatTurn(id:id,sessionID:sessionID,timestamp:timestamp,question:payload.question,answer:cleanAnswer,filter:scope)
        } catch { try? exec("ROLLBACK"); throw error }
    }
    public func chatTurns(_ sessionID: String, limit: Int = 100) throws -> [ChatTurn] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT id,timestamp,payload FROM chat_turns WHERE session_id=? ORDER BY timestamp DESC,id DESC LIMIT ?"); defer { sqlite3_finalize(stmt) }; bind(stmt,1,sessionID); sqlite3_bind_int(stmt,2,Int32(min(1000,max(1,limit))))
        var turns = [ChatTurn]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = string(stmt,0), date = Date(timeIntervalSince1970:sqlite3_column_double(stmt,1))
            guard let bytes = sqlite3_column_blob(stmt,2) else { throw OSwindError.database("Missing conversation payload") }
            let payload = try JSONDecoder().decode(ChatPayload.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(stmt,2))))
            let source = try prepare("SELECT m.payload,s.score,s.match FROM chat_sources s JOIN memories m ON m.id=s.memory_id WHERE s.turn_id=? ORDER BY s.ordinal"); defer { sqlite3_finalize(source) }; bind(source,1,id)
            var hits = [SearchHit]()
            while sqlite3_step(source) == SQLITE_ROW { hits.append(SearchHit(memory:try decode(source),score:sqlite3_column_double(source,1),match:string(source,2))) }
            turns.append(ChatTurn(id:id,sessionID:sessionID,timestamp:date,question:payload.question,answer:Answer(text:payload.text,sources:hits,provider:payload.provider,duration:payload.duration,warnings:payload.warnings),filter:payload.filter))
        }
        return turns.reversed()
    }
}

extension MemoryStore {
    /// Called inside the search's SQL snapshot. Only current, matching rows can
    /// become evidence. Mutations newer than the graph are searched exactly.
    func indexedCandidates(_ filter: SearchFilter, modelID: String, dimensions: Int, scorer: CosineScorer, minimumSimilarity: Double, limit: Int, strategy: (String) -> Void = { _ in }) throws -> [SemanticCandidate]? {
        lock.lock(); defer { lock.unlock() }
        try exec("SAVEPOINT index_candidate_snapshot"); defer { try? exec("RELEASE index_candidate_snapshot") }
        let state = try prepare("SELECT (SELECT value FROM store_metadata WHERE key='identity'),COALESCE((SELECT MAX(seq) FROM vector_changes),0),(SELECT hex(revision) FROM search_scope_revision WHERE singleton=1)")
        defer { sqlite3_finalize(state) }
        guard sqlite3_step(state) == SQLITE_ROW else { throw failure() }
        let identity = string(state,0), head = sqlite3_column_int64(state,1), scopeRevision = string(state,2), (whereSQL,values) = conditions(filter)
        return try annCache.withReady(modelID:modelID,dimensions:dimensions,identity:identity,snapshotHead:head) { native,sequence -> [SemanticCandidate]? in
            strategy(native.strategy)
            let keyCount = min(2000,max(100,limit*2))
            var keys: [UInt64]
            if whereSQL == "1=1" { keys = try native.search(scorer.queryVector,count:keyCount) }
            else if native is MetalFlatIndex {
                let scopeKey = MetalScopeKey(identity:identity,model:modelID,sequence:sequence,revision:scopeRevision,predicate:whereSQL,values:values)
                let allowedKeys: Set<UInt64>
                if !scopeRevision.isEmpty, let cached = metalScopeCache?.lookup(scopeKey) { allowedKeys = cached }
                else {
                    // One bounded mask, invalidated by transactional metadata
                    // nonce and graph replay sequence. Query words are excluded
                    // so typing/follow-ups reuse the same scope safely.
                    let allowed = try prepare("SELECT r.key FROM vector_keys r JOIN memories m ON m.id=r.memory_id WHERE r.model=? AND r.revision<=? AND \(whereSQL)")
                    defer { sqlite3_finalize(allowed) }; bind(allowed,1,modelID); sqlite3_bind_int64(allowed,2,sequence)
                    for (i,value) in values.enumerated() { bind(allowed,Int32(i+3),value) }
                    var loaded = Set<UInt64>(), status = sqlite3_step(allowed)
                    while status == SQLITE_ROW {
                        if loaded.count%4096 == 0 { try Task.checkCancellation() }
                        // Avoid a large unbounded CPU allocation on high-volume
                        // low-dimensional archives. Full exact stays available.
                        if loaded.count >= 2_000_000 { metalScopeCache = nil; return nil }
                        let key = sqlite3_column_int64(allowed,0); if key > 0 { loaded.insert(UInt64(key)) }; status = sqlite3_step(allowed)
                    }
                    guard status == SQLITE_DONE else { throw failure() }
                    allowedKeys = loaded
                    if !scopeRevision.isEmpty {
                        if metalScopeCache == nil { metalScopeCache = MetalScopeCache() }
                        metalScopeCache?.insert(MetalScopeSnapshot(key:scopeKey,allowed:loaded))
                    }
                }
                keys = try native.search(scorer.queryVector,count:keyCount,include:{ allowedKeys.contains($0) })
            }
            else {
                let allowed = try prepare("SELECT 1 FROM vector_keys r JOIN memories m ON m.id=r.memory_id WHERE r.key=? AND r.model=? AND r.revision<=? AND \(whereSQL)")
                defer { sqlite3_finalize(allowed) }; var databaseError: Error?; let filterLock = NSLock()
                keys = try native.search(scorer.queryVector,count:keyCount) { key in
                    guard key <= UInt64(Int64.max) else { return false }
                    filterLock.lock(); defer { filterLock.unlock() }
                    sqlite3_reset(allowed); sqlite3_clear_bindings(allowed); sqlite3_bind_int64(allowed,1,Int64(key)); self.bind(allowed,2,modelID); sqlite3_bind_int64(allowed,3,sequence)
                    for (i,value) in values.enumerated() { self.bind(allowed,Int32(i+4),value) }
                    let status = sqlite3_step(allowed)
                    if status != SQLITE_ROW && status != SQLITE_DONE { databaseError = self.failure() }
                    return status == SQLITE_ROW
                }
                if let databaseError { throw databaseError }
            }
            let select = """
            SELECT m.id,COALESCE(v.vector,CASE WHEN m.embedding_model=r.model THEN m.embedding END),m.timestamp
            FROM vector_keys r JOIN memories m ON m.id=r.memory_id
            LEFT JOIN semantic_vectors v ON v.memory_id=r.memory_id AND v.model=r.model
            """
            let candidate = try prepare(select+" WHERE r.key=? AND r.model=? AND r.revision<=? AND \(whereSQL)")
            defer { sqlite3_finalize(candidate) }; var best = SemanticTopK(capacity:limit), valid = 0, seen = Set<String>()
            func consume(_ stmt: OpaquePointer) {
                guard sqlite3_column_bytes(stmt,1) == dimensions*MemoryLayout<Float>.size, let bytes = sqlite3_column_blob(stmt,1) else { return }
                let id = string(stmt,0); guard seen.insert(id).inserted else { return }
                valid += 1
                let score = scorer.score(bytes.assumingMemoryBound(to:Float.self),count:dimensions)
                if score > minimumSimilarity, best.mayImprove(score) { best.offer(SemanticCandidate(id:id,similarity:score,timestamp:sqlite3_column_double(stmt,2))) }
            }
            for key in keys {
                try Task.checkCancellation()
                guard key <= UInt64(Int64.max) else { continue }
                sqlite3_reset(candidate); sqlite3_clear_bindings(candidate); sqlite3_bind_int64(candidate,1,Int64(key)); bind(candidate,2,modelID); sqlite3_bind_int64(candidate,3,sequence)
                for (i,value) in values.enumerated() { bind(candidate,Int32(i+4),value) }
                let status = sqlite3_step(candidate)
                if status == SQLITE_ROW { consume(candidate) } else if status != SQLITE_DONE { throw failure() }
            }
            let nativeValid = valid
            // A bounded recent sample keeps repeated identical captures from
            // arbitrarily hiding the newest source behind native tie ordering.
            let recent = try prepare("SELECT m.id,COALESCE(v.vector,CASE WHEN m.embedding_model=r.model THEN m.embedding END),m.timestamp FROM memories m CROSS JOIN vector_keys r ON r.memory_id=m.id LEFT JOIN semantic_vectors v ON v.memory_id=r.memory_id AND v.model=r.model WHERE r.model=? AND r.revision<=? AND \(whereSQL) ORDER BY m.timestamp DESC,m.id LIMIT 100")
            defer { sqlite3_finalize(recent) }; bind(recent,1,modelID); sqlite3_bind_int64(recent,2,sequence)
            for (i,value) in values.enumerated() { bind(recent,Int32(i+3),value) }
            var recentStatus = sqlite3_step(recent)
            while recentStatus == SQLITE_ROW { consume(recent); recentStatus = sqlite3_step(recent) }
            guard recentStatus == SQLITE_DONE else { throw failure() }
            // Large concurrent backfills deliberately fall back to a full exact
            // scan rather than silently dropping new evidence.
            let delta = try prepare(select+" WHERE r.model=? AND r.revision>? AND \(whereSQL) LIMIT 5001")
            defer { sqlite3_finalize(delta) }; bind(delta,1,modelID); sqlite3_bind_int64(delta,2,sequence)
            for (i,value) in values.enumerated() { bind(delta,Int32(i+3),value) }
            var changed = 0, status = sqlite3_step(delta)
            while status == SQLITE_ROW { changed += 1; if changed % 256 == 0 { try Task.checkCancellation() }; if changed > 5000 { return nil }; consume(delta); status = sqlite3_step(delta) }
            guard status == SQLITE_DONE else { throw failure() }
            if keys.count == keyCount && nativeValid < min(5,max(1,filter.limit)) { return nil }
            return best.sorted
        } ?? nil
    }
}
