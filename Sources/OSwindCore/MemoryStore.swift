import Foundation
import CSQLite

public final class MemoryStore: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(root: URL = Paths.data) throws {
        self.root = root; try Paths.ensure(root); try Paths.ensure(root.appendingPathComponent("images")); try Paths.ensure(root.appendingPathComponent("audio"))
        let path = root.appendingPathComponent("memory.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw OSwindError.database("Cannot open memory store") }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON;")
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
        PRAGMA user_version=2;
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    deinit { sqlite3_close(db) }
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
    public func search(_ filter: SearchFilter, mode: SearchMode = .hybrid, vector: [Float]? = nil, modelID: String? = nil, minimumSimilarity: Double = 0.15, similarityFusion: Bool = false) throws -> [SearchHit] {
        lock.lock(); defer { lock.unlock() }
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
        if !query.isEmpty, mode != .keyword, let vector, let modelID {
            let stmt = try prepare("SELECT m.id,m.embedding FROM memories m WHERE \(whereSQL) AND embedding IS NOT NULL AND embedding_model=? UNION ALL SELECT m.id,v.vector FROM semantic_vectors v JOIN memories m ON m.id=v.memory_id WHERE \(whereSQL) AND v.model=?")
            defer { sqlite3_finalize(stmt) }; for (i,v) in values.enumerated() { bind(stmt, Int32(i+1), v) }; bind(stmt, Int32(values.count + 1), modelID)
            for (i,v) in values.enumerated() { bind(stmt,Int32(values.count+2+i),v) }; bind(stmt,Int32(2*values.count+2),modelID)
            var best = [(String, Double)]()
            while sqlite3_step(stmt) == SQLITE_ROW {
                let size = Int(sqlite3_column_bytes(stmt, 1)); guard size == vector.count * MemoryLayout<Float>.size, let bytes = sqlite3_column_blob(stmt, 1) else { continue }
                let stored = Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Float.self), count: vector.count))
                let similarity = LocalEmbedder.cosine(vector, stored)
                if similarity > minimumSimilarity { best.append((string(stmt, 0), similarity)) }
            }
            best.sort { $0.1 > $1.1 }
            for (rank, pair) in best.prefix(max(limit, 100)).enumerated() {
                if var hit = scored[pair.0] { hit.score += similarityFusion ? pair.1 : 1 / Double(60 + rank); hit.match = "hybrid"; scored[pair.0] = hit }
                else if let memory = try get(pair.0) { scored[pair.0] = SearchHit(memory: memory, score: mode == .semantic || similarityFusion ? pair.1 : 1 / Double(60 + rank), match: "semantic") }
            }
        }
        return Array(scored.values.sorted { $0.score == $1.score ? $0.memory.timestamp > $1.memory.timestamp : $0.score > $1.score }.prefix(limit))
    }
    public func matchingCount(_ filter: SearchFilter = SearchFilter()) throws -> Int {
        lock.lock(); defer { lock.unlock() }; let (whereSQL,values) = conditions(filter)
        let stmt = try prepare("SELECT COUNT(*) FROM memories m WHERE \(whereSQL)"); defer { sqlite3_finalize(stmt) }
        for (i,v) in values.enumerated() { bind(stmt,Int32(i+1),v) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt,0)) : 0
    }
    public func vectorCount(modelID: String, filter: SearchFilter = SearchFilter()) throws -> Int {
        lock.lock(); defer { lock.unlock() }; let (whereSQL,values) = conditions(filter)
        let stmt = try prepare("SELECT COUNT(DISTINCT m.id) FROM memories m LEFT JOIN semantic_vectors v ON v.memory_id=m.id AND v.model=? WHERE \(whereSQL) AND (m.embedding_model=? AND m.embedding IS NOT NULL OR v.memory_id IS NOT NULL)")
        defer { sqlite3_finalize(stmt) }; bind(stmt,1,modelID); for (i,v) in values.enumerated() { bind(stmt,Int32(i+2),v) }; bind(stmt,Int32(values.count+2),modelID)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt,0)) : 0
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
        for id in ids { try delete(id) }; var deleted = ids.count
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
        lock.lock(); defer { lock.unlock() }; try exec("DELETE FROM memories; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        for folder in ["images", "audio"] { let url = root.appendingPathComponent(folder); try FileManager.default.removeItem(at: url); try Paths.ensure(url) }
    }
    public func diskBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0; for case let url as URL in enumerator { if let values = try? url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey]), values.isRegularFile == true { total += Int64(values.fileSize ?? 0) } }; return total
    }
    public func stats() throws -> StoreStats {
        lock.lock(); defer { lock.unlock() }; var stats = StoreStats(); let stmt = try prepare("SELECT COUNT(*),SUM(kind='screen'),SUM(kind='audio'),SUM(embedding IS NOT NULL),MIN(timestamp),MAX(timestamp) FROM memories"); defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { stats.count = Int(sqlite3_column_int(stmt,0)); stats.screenshots = Int(sqlite3_column_int(stmt,1)); stats.audioSegments = Int(sqlite3_column_int(stmt,2)); stats.embedded = Int(sqlite3_column_int(stmt,3)); if stats.count > 0 { stats.oldest = Date(timeIntervalSince1970: sqlite3_column_double(stmt,4)); stats.newest = Date(timeIntervalSince1970: sqlite3_column_double(stmt,5)) } }
        let apps = try prepare("SELECT app,COUNT(*) FROM memories GROUP BY app ORDER BY COUNT(*) DESC"); defer { sqlite3_finalize(apps) }; while sqlite3_step(apps) == SQLITE_ROW { stats.apps[string(apps,0)] = Int(sqlite3_column_int(apps,1)) }; stats.bytes = diskBytes(); return stats
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
