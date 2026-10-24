import Foundation
import CSQLite

public final class MemoryStore: @unchecked Sendable {
    public static let schemaVersion = 15
    public static let maximumRecordBytes = 128*1024*1024
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var metalScopeCache: MetalScopeCache?
    private var coverageCache = [(key:MetalScopeKey,indexed:Int,total:Int)]()
    private let annCache: ANNCache
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(root: URL = Paths.data) throws {
        self.root = root; annCache = ANNCache(root:root)
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("header.json").path) else { throw OSwindError.invalid("Use Restore Backup to open a backup package as a new library") }
        try Paths.ensure(root); try Paths.ensure(root.appendingPathComponent("images")); try Paths.ensure(root.appendingPathComponent("audio"));try Paths.ensure(root.appendingPathComponent("video"))
        let path = root.appendingPathComponent("memory.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw OSwindError.database("Cannot open memory store") }
        sqlite3_busy_timeout(db, 5000)
        let versionStatement = try prepare("PRAGMA user_version")
        let version = sqlite3_step(versionStatement) == SQLITE_ROW ? sqlite3_column_int(versionStatement,0) : Int32.max; sqlite3_finalize(versionStatement)
        guard version <= Int32(Self.schemaVersion) else { sqlite3_close(db); db = nil; throw OSwindError.unavailable("This memory store was created by a newer OSwind version. Update OSwind before opening it.") }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON; PRAGMA temp_store=FILE; PRAGMA temp.cache_size=-4096;")
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
            ordinal INTEGER NOT NULL, score REAL NOT NULL, match TEXT NOT NULL, passage_start INTEGER, passage_length INTEGER,
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
        if version > 0 && version < 6 {
            let info = try prepare("SELECT 1 FROM pragma_table_info('chat_sources') WHERE name='passage_start'")
            let needsPassageColumns = sqlite3_step(info) != SQLITE_ROW; sqlite3_finalize(info)
            if needsPassageColumns { try exec("ALTER TABLE chat_sources ADD COLUMN passage_start INTEGER; ALTER TABLE chat_sources ADD COLUMN passage_length INTEGER;") }
        }
        if version >= 4 && version < 6 { try exec(VectorJournalSchema.migrateV5) }
        try exec(RoutineSchema.sql)
        try exec(HistoryErasureSchema.sql)
        try exec(RecapSchema.sql)
        try exec(VectorJournalSchema.sql)
        try exec(PassageSchema.sql)
        try exec(VectorStatisticsSchema.sql)
        if version < 6 { try exec(VectorStatisticsSchema.backfill) }
        if version < 4 { try exec(VectorJournalSchema.backfill) }
        try exec(StatisticsSchema.sql)
        try exec(SearchScopeSchema.sql)
        try exec(SpeakerSearchSchema.sql)
        try exec(SearchPreviewSchema.sql)
        if version < 11 {
            let audio=try prepare("SELECT payload FROM memories WHERE kind='audio'")
            defer { sqlite3_finalize(audio) }
            var status=sqlite3_step(audio)
            while status==SQLITE_ROW {
                try autoreleasepool {let memory=try decode(audio);if version<10 {try replaceSpeakerProjection(memory)};try replaceSearchPreview(memory)}
                status=sqlite3_step(audio)
            }
            guard status==SQLITE_DONE else {throw failure()}
        }
        let statisticsState = try prepare("SELECT total=COALESCE((SELECT SUM(count) FROM application_statistics),0) FROM memory_statistics WHERE singleton=1")
        let statisticsNeedRepair = sqlite3_step(statisticsState) != SQLITE_ROW || sqlite3_column_int(statisticsState,0) != 1
        sqlite3_finalize(statisticsState)
        if version < 5 || statisticsNeedRepair { try exec(StatisticsSchema.backfill) }
        if version < 5 { try exec(StatisticsSchema.selectiveFTSUpdate) }
        try FullTextIdentitySchema.install(RoutineDatabase(handle:db!))
        if version<15 {try rebuildRecapLinks()}
        try exec("PRAGMA user_version=\(Self.schemaVersion); COMMIT")
        } catch { try? exec("ROLLBACK"); sqlite3_close(db); db = nil; throw error }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        _ = finishRecapInvalidation()
    }
    deinit { annCache.cancel(); sqlite3_close(db) }
    func withRoutineDatabase<T>(_ body:(RoutineDatabase) throws -> T) throws -> T {
        lock.lock();defer {lock.unlock()}
        guard let db else {throw OSwindError.database("Library connection closed")}
        return try body(RoutineDatabase(handle:db))
    }
    private func exec(_ sql: String) throws { if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw failure() } }
    private func failure() -> OSwindError { .database(String(cString: sqlite3_errmsg(db))) }
    private func prepare(_ sql: String) throws -> OpaquePointer { var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }; return stmt }
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) { if let value { sqlite3_bind_text64(stmt,index,value,UInt64(value.utf8.count),transient,UInt8(SQLITE_UTF8)) } else { sqlite3_bind_null(stmt, index) } }
    private func string(_ stmt: OpaquePointer, _ column: Int32) -> String { guard let text = sqlite3_column_text(stmt,column) else { return "" }; return String(decoding:UnsafeBufferPointer(start:text,count:Int(sqlite3_column_bytes(stmt,column))),as:UTF8.self) }
    private func decode(_ stmt: OpaquePointer, column: Int32 = 0) throws -> Memory {
        guard let bytes = sqlite3_column_blob(stmt, column) else { throw OSwindError.database("Missing payload") }
        return try JSONDecoder().decode(Memory.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column))))
    }
    public func insert(_ memory:Memory) throws {try insertValidated(memory,deferRecapLinks:false)}
    func insertRestoringRecap(_ memory:Memory) throws {try insertValidated(memory,deferRecapLinks:true)}
    private func insertValidated(_ memory:Memory,deferRecapLinks:Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard memory.searchPreview==nil else { throw OSwindError.invalid("Hydrate a search preview before saving a source") }
        guard !memory.id.isEmpty, memory.id.count < 200, memory.text.count <= 1_000_000 else { throw OSwindError.invalid("Invalid memory size or identifier") }
        if let transcript=memory.transcript { _ = try transcript.validated(); guard memory.kind == .audio,memory.text == transcript.text else { throw OSwindError.invalid("Transcript and source text differ") } }
        if let visual=memory.visualRecording {_ = try visual.validated();guard memory.kind == .screen,memory.text==visual.text else {throw OSwindError.invalid("Visual recording and source text differ")}}
        guard memory.videoPath==nil || memory.visualRecording != nil else {throw OSwindError.invalid("A replay asset requires frame metadata")}
        guard memory.audioSessionID.map({!$0.isEmpty && $0.count<=200}) ?? true else { throw OSwindError.invalid("Invalid audio session identifier") }
        for path in [memory.imagePath, memory.audioPath,memory.videoPath].compactMap({$0}) { guard assetURL(path) != nil else { throw OSwindError.invalid("Asset path must stay inside the memory store") } }
        // Reserve the writer before reading old evidence. A deferred read then
        // write can fail immediately with SQLITE_BUSY across store connections.
        let ownsTransaction=sqlite3_get_autocommit(db) != 0
        try exec(ownsTransaction ? "BEGIN IMMEDIATE":"SAVEPOINT memory_insert")
        do {
        try validateRecapInsertion(memory,deferred:deferRecapLinks)
        if memory.kind == .audio || memory.kind == .screen,let current=try get(memory.id),current.transcript != memory.transcript || current.visualRecording != memory.visualRecording { try invalidateAudioEvidence(memory.id) }
        let stmt = try prepare("INSERT INTO memories(id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET timestamp=excluded.timestamp,kind=excluded.kind,app=excluded.app,title=excluded.title,url=excluded.url,text=excluded.text,favorite=excluded.favorite,payload=excluded.payload,embedding=excluded.embedding,embedding_model=excluded.embedding_model")
        defer { sqlite3_finalize(stmt) }
        var payload = memory; payload.embedding = nil
        let data = try JSONEncoder().encode(payload)
        guard data.count <= Self.maximumRecordBytes else { throw OSwindError.invalid("Memory payload exceeds 128 MiB") }
        bind(stmt, 1, memory.id); sqlite3_bind_double(stmt, 2, memory.timestamp.timeIntervalSince1970); bind(stmt, 3, memory.kind.rawValue); bind(stmt, 4, memory.app); bind(stmt, 5, memory.title); bind(stmt, 6, memory.url); bind(stmt, 7, memory.text); sqlite3_bind_int(stmt, 8, memory.favorite ? 1 : 0)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 9, $0.baseAddress, Int32(data.count), transient) }
        if let vector = memory.embedding, !vector.isEmpty, vector.allSatisfy({$0.isFinite}) { _ = vector.withUnsafeBytes { sqlite3_bind_blob(stmt, 10, $0.baseAddress, Int32($0.count), transient) } }
        bind(stmt, 11, memory.embeddingModel)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        try replaceSpeakerProjection(memory);try replaceSearchPreview(memory);try replaceRecapLinks(memory,deferred:deferRecapLinks)
        try Task.checkCancellation();try exec(ownsTransaction ? "COMMIT":"RELEASE memory_insert")
        if ownsTransaction {_ = finishRecapInvalidation()}
        } catch { try? exec(ownsTransaction ? "ROLLBACK":"ROLLBACK TO memory_insert; RELEASE memory_insert"); throw error }
    }
    private func replaceSearchPreview(_ memory:Memory) throws {
        guard memory.searchPreview==nil else { throw OSwindError.invalid("Cannot cache an incomplete source") }
        guard memory.kind == .audio,let transcript=memory.transcript else {
            let remove=try prepare("DELETE FROM audio_search_previews WHERE memory_id=?");defer {sqlite3_finalize(remove)};bind(remove,1,memory.id)
            guard sqlite3_step(remove)==SQLITE_DONE else {throw failure()};return
        }
        var preview=memory;preview.transcript=nil;preview.embedding=nil
        preview.searchPreview=MemorySearchPreview(memory:memory,transcript:transcript)
        let data=try JSONEncoder().encode(preview)
        let stmt=try prepare("INSERT INTO audio_search_previews(memory_id,payload) VALUES(?,?) ON CONFLICT(memory_id) DO UPDATE SET payload=excluded.payload")
        defer {sqlite3_finalize(stmt)};bind(stmt,1,memory.id)
        _ = data.withUnsafeBytes {sqlite3_bind_blob(stmt,2,$0.baseAddress,Int32(data.count),transient)}
        guard sqlite3_step(stmt)==SQLITE_DONE else {throw failure()}
    }
    private func getForSearch(_ id:String,detail:SearchDetail) throws -> Memory? {
        if detail == .full {return try get(id)}
        let stmt=try prepare("SELECT COALESCE(p.payload,m.payload) FROM memories m LEFT JOIN audio_search_previews p ON p.memory_id=m.id WHERE m.id=?")
        defer {sqlite3_finalize(stmt)};bind(stmt,1,id)
        return sqlite3_step(stmt)==SQLITE_ROW ? try decode(stmt):nil
    }
    /// Revalidate and load complete evidence in one read snapshot. Deleted or
    /// revised sources fail explicitly, rather than silently retargeting offsets.
    public func hydrate(_ hits:[SearchHit]) throws -> [SearchHit] {
        lock.lock();defer {lock.unlock()};try Task.checkCancellation()
        try exec("SAVEPOINT hydrate_sources");defer {try? exec("RELEASE hydrate_sources")}
        return try hits.map { hit in
            try Task.checkCancellation()
            let expected=hit.memory.searchPreview?.sourceRevision ?? hit.memory.evidenceHash
            guard let current=try get(hit.id),current.searchPreview==nil,current.evidenceHash==expected else {throw OSwindError.unavailable("This source changed or was removed. Refresh the results and open it again.")}
            guard hit.passage.map({$0.text(in:current.text) != nil}) ?? true else {throw OSwindError.invalid("The source passage is no longer valid")}
            return SearchHit(memory:current,score:hit.score,match:hit.match,passage:hit.passage)
        }
    }
    public func hydrate(_ memory:Memory) throws -> Memory {try hydrate([SearchHit(memory:memory,score:0,match:"")])[0].memory}
    private func replaceSpeakerProjection(_ memory:Memory) throws {
        let labels=memory.kind == .audio ? Set(memory.transcript?.segments.compactMap(\.speaker) ?? []):[]
        let existing=try prepare("SELECT label FROM audio_speakers WHERE memory_id=?"); defer { sqlite3_finalize(existing) }; bind(existing,1,memory.id)
        var old=Set<String>(); while sqlite3_step(existing)==SQLITE_ROW { old.insert(string(existing,0)) }
        guard old != labels else { return }
        let remove=try prepare("DELETE FROM audio_speakers WHERE memory_id=?"); defer { sqlite3_finalize(remove) }; bind(remove,1,memory.id)
        guard sqlite3_step(remove)==SQLITE_DONE else { throw failure() }
        let add=try prepare("INSERT INTO audio_speakers(memory_id,label,label_key) VALUES(?,?,?)"); defer { sqlite3_finalize(add) }
        for label in labels.sorted() {
            sqlite3_reset(add); sqlite3_clear_bindings(add); bind(add,1,memory.id); bind(add,2,label); bind(add,3,SpeakerLabel.key(label))
            guard sqlite3_step(add)==SQLITE_DONE else { throw failure() }
        }
    }
    private func invalidateAudioEvidence(_ id:String) throws {
        try invalidateRecapDependents(id)
        let title=try prepare("UPDATE chat_sessions SET title='Conversation' WHERE id IN (SELECT t.session_id FROM chat_turns t JOIN chat_sources s ON s.turn_id=t.id WHERE s.memory_id=?)"); defer { sqlite3_finalize(title) }; bind(title,1,id)
        guard sqlite3_step(title)==SQLITE_DONE else { throw failure() }
        let turns=try prepare("DELETE FROM chat_turns WHERE id IN (SELECT turn_id FROM chat_sources WHERE memory_id=?)"); defer { sqlite3_finalize(turns) }; bind(turns,1,id)
        guard sqlite3_step(turns)==SQLITE_DONE else { throw failure() }
    }
    public func assetURL(_ relative: String) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, ["images", "audio","video"].contains(String(parts[0])), !relative.hasPrefix("/"), !parts.contains(".."), !parts.contains("") else { return nil }
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
    private func conditions(_ filter: SearchFilter, prefix: String = "m.", expression: SearchExpressionPlan? = nil) -> (String, [String]) {
        var parts = ["1=1"]; var values = [String]()
        if let app = filter.app, !app.isEmpty { parts.append("\(prefix)app=?"); values.append(app) }
        if let kind = filter.kind { parts.append("\(prefix)kind=?"); values.append(kind.rawValue) }
        if let start = filter.start { parts.append("\(prefix)timestamp>=?"); values.append(String(start.timeIntervalSince1970)) }
        if let end = filter.end { parts.append("\(prefix)timestamp<?"); values.append(String(end.timeIntervalSince1970)) }
        if filter.favoritesOnly { parts.append("\(prefix)favorite=1") }
        if let tag = filter.tag { parts.append("EXISTS (SELECT 1 FROM json_each(CAST(\(prefix)payload AS TEXT), '$.tags') WHERE value=?)"); values.append(tag) }
        if let speaker=filter.speaker { parts.append("EXISTS (SELECT 1 FROM audio_speakers s WHERE s.memory_id=\(prefix)id AND s.label_key=?)"); values.append(SpeakerLabel.key(speaker)) }
        if let constraint = expression?.constraint {
            if expression?.materialized == true { parts.append("\(prefix)id IN (SELECT id FROM temp.search_expression_scope)") }
            else { parts.append(constraint.predicate(prefix:prefix,values:&values)) }
        }
        return (parts.joined(separator: " AND "), values)
    }
    /// FTS operands can match many rows. Re-running their IN subqueries for
    /// every native candidate made a 20k Metal query take seconds. Keep a private
    /// disk-backed ID set for this one SQLite snapshot, then use indexed lookups.
    private func materializeExpression(_ input: SearchExpressionPlan) throws -> SearchExpressionPlan {
        guard let constraint = input.constraint,!input.materialized else { return input }
        try Task.checkCancellation()
        sqlite3_progress_handler(db,1000,{ _ in Task.isCancelled ? 1:0 },nil)
        defer { sqlite3_progress_handler(db,0,nil,nil) }
        do {
            try exec("CREATE TEMP TABLE IF NOT EXISTS search_expression_scope(id TEXT PRIMARY KEY) WITHOUT ROWID; DELETE FROM temp.search_expression_scope; PRAGMA temp.cache_size=-4096;")
            var values = [String](); let predicate = constraint.predicate(prefix:"m.",values:&values)
            let statement = try prepare("INSERT INTO temp.search_expression_scope SELECT m.id FROM memories m WHERE "+predicate); defer { sqlite3_finalize(statement) }
            for (offset,value) in values.enumerated() { bind(statement,Int32(offset+1),value) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        } catch { if Task.isCancelled { throw CancellationError() }; throw error }
        var result = input; result.materialized = true; return result
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
    public func search(_ filter: SearchFilter, mode: SearchMode = .hybrid, vector: [Float]? = nil, modelID: String? = nil, minimumSimilarity: Double = 0.15, similarityFusion: Bool = false, indexPolicy: SearchIndexPolicy = .exact, indexedCount: Int? = nil, allowIndexOnLowPower: Bool = false, detail:SearchDetail = .full, expression:SearchExpressionPlan? = nil, execution: ((SearchExecution) -> Void)? = nil) throws -> [SearchHit] {
        try Task.checkCancellation()
        var queryPlan = try expression ?? SearchExpressionPlan.make(filter.query)
        var indexStatus: SearchIndexStatus?
        let scoped = conditions(filter,expression:queryPlan).0 != "1=1"
        // Current measured native predicate callbacks cost more than a scoped
        // exact scan. Keep Automatic conservative until scoped indexing improves.
        if mode != .keyword, !queryPlan.keywordFTS.isEmpty, let vector, let modelID, indexPolicy != .exact, indexPolicy == .indexed || !scoped {
            let count = try vectorEntityCount(modelID:modelID)
            if indexPolicy == .indexed || count >= 20_000 { indexStatus = annCache.prepare(modelID:modelID,dimensions:vector.count,count:count,allowLowPower:allowIndexOnLowPower) }
        }
        lock.lock(); defer { lock.unlock() }
        try exec("SAVEPOINT search_snapshot"); defer {
            if queryPlan.hasConstraints { try? exec("DELETE FROM temp.search_expression_scope") }
            try? exec("RELEASE search_snapshot")
        }
        queryPlan = try materializeExpression(queryPlan)
        var strategy = "exact", diagnostics = [String]()
        let limit = min(500, max(1, filter.limit)); let (whereSQL, values) = conditions(filter,expression:queryPlan)
        let query = queryPlan.keywordFTS
        let payload=detail == .preview ? "COALESCE(preview.payload,m.payload)":"m.payload"
        let previewJoin=detail == .preview ? " LEFT JOIN audio_search_previews preview ON preview.memory_id=m.id":""
        var keyword = [Memory](); var scored = [String: SearchHit]()
        if query.isEmpty || mode != .semantic {
            let sql = query.isEmpty ? "SELECT \(payload) FROM memories m\(previewJoin) WHERE \(whereSQL) ORDER BY m.timestamp DESC LIMIT ?" : "SELECT \(payload) FROM memory_fts f JOIN memories m ON m.id=f.id\(previewJoin) WHERE memory_fts MATCH ? AND f.rank MATCH 'bm25(0,3,1,1)' AND \(whereSQL) ORDER BY f.rank LIMIT ?"
            let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }; var index: Int32 = 1
            if !query.isEmpty { bind(stmt, index, query); index += 1 }
            for value in values { bind(stmt, index, value); index += 1 }; sqlite3_bind_int(stmt, index, Int32(query.isEmpty || mode == .keyword ? limit : max(limit, 100)))
            var keywordStatus = sqlite3_step(stmt)
            while keywordStatus == SQLITE_ROW { try Task.checkCancellation(); keyword.append(try decode(stmt)); keywordStatus = sqlite3_step(stmt) }
            guard keywordStatus == SQLITE_DONE else { throw failure() }
            for (rank, memory) in keyword.enumerated() { scored[memory.id] = SearchHit(memory: memory, score: query.isEmpty ? memory.timestamp.timeIntervalSince1970 : (similarityFusion && mode == .hybrid ? Self.keywordBonus(query:filter.query,memory:memory,rank:rank) : 1 / Double(60 + rank)), match: query.isEmpty ? "recent" : "keyword") }
            if !query.isEmpty {
                let names=try prepare("SELECT m.id FROM speaker_fts f JOIN memories m ON m.id=f.memory_id WHERE speaker_fts MATCH ? AND \(whereSQL) GROUP BY m.id ORDER BY m.timestamp DESC,m.id LIMIT ?")
                defer { sqlite3_finalize(names) }; bind(names,1,queryPlan.speakerFTS)
                for (offset,value) in values.enumerated() { bind(names,Int32(offset+2),value) }; sqlite3_bind_int(names,Int32(values.count+2),Int32(max(limit,100)))
                var rank=0
                var speakerStatus = sqlite3_step(names)
                while speakerStatus == SQLITE_ROW {
                    try Task.checkCancellation()
                    let id=string(names,0)
                    let score=similarityFusion && mode == .hybrid ? 0.08/(1+Double(rank)*0.1):1/Double(60+rank)
                    if var hit=scored[id] { hit.score += score*0.25; hit.match="keyword + speaker"; scored[id]=hit }
                    else if let memory=try getForSearch(id,detail:detail) { scored[id]=SearchHit(memory:memory,score:score,match:"speaker name") }
                    rank += 1; speakerStatus = sqlite3_step(names)
                }
                guard speakerStatus == SQLITE_DONE else { throw failure() }
            }
        }
        if !query.isEmpty, mode != .keyword, let vector, let modelID, let scorer = CosineScorer(vector) {
            var indexed: [SemanticCandidate]?
            var candidateStrategy = "ann-exact-rerank"
            if indexStatus != nil {
                do { indexed = try indexedCandidates(filter,modelID:modelID,dimensions:vector.count,scorer:scorer,minimumSimilarity:minimumSimilarity,limit:max(limit,100),expression:queryPlan,strategy:{ candidateStrategy = $0 }) }
                catch { diagnostics.append("Fast index unavailable; exact search used. "+error.localizedDescription) }
                if indexed == nil && diagnostics.isEmpty {
                    diagnostics.append(indexStatus!.state == "ready" ? "Fast index is catching up; exact search used." : indexStatus!.message + " · exact search used.")
                }
            }
            let best: [SemanticCandidate]
            if let indexed { best = indexed; strategy = candidateStrategy }
            else {
            let vectorJoin = whereSQL == "1=1" ? "semantic_vectors v JOIN memories m ON m.id=v.memory_id" : "memories m CROSS JOIN semantic_vectors v ON m.id=v.memory_id"
            let stmt = try prepare("SELECT m.id,m.embedding,m.timestamp,-1,0 FROM memories m WHERE \(whereSQL) AND embedding IS NOT NULL AND embedding_model=? AND NOT EXISTS (SELECT 1 FROM semantic_vectors v WHERE v.memory_id=m.id AND v.model=m.embedding_model) UNION ALL SELECT m.id,v.vector,m.timestamp,-1,0 FROM \(vectorJoin) WHERE \(whereSQL) AND v.model=? UNION ALL SELECT m.id,p.vector,m.timestamp,p.start,p.length FROM semantic_passages p JOIN memories m ON m.id=p.memory_id WHERE \(whereSQL) AND p.model=?")
            defer { sqlite3_finalize(stmt) }; for (i,v) in values.enumerated() { bind(stmt, Int32(i+1), v) }; bind(stmt, Int32(values.count + 1), modelID)
            for (i,v) in values.enumerated() { bind(stmt,Int32(values.count+2+i),v) }; bind(stmt,Int32(2*values.count+2),modelID)
            for (i,v) in values.enumerated() { bind(stmt,Int32(2*values.count+3+i),v) }; bind(stmt,Int32(3*values.count+3),modelID)
            var candidates = SemanticTopK(capacity:max(limit,100))
            var scanned = 0
            var vectorStatus = sqlite3_step(stmt)
            while vectorStatus == SQLITE_ROW {
                defer { vectorStatus = sqlite3_step(stmt) }
                scanned += 1; if scanned % 256 == 0 { try Task.checkCancellation() }
                let size = Int(sqlite3_column_bytes(stmt, 1)); guard size == vector.count * MemoryLayout<Float>.size, let bytes = sqlite3_column_blob(stmt, 1) else { continue }
                let similarity = scorer.score(bytes.assumingMemoryBound(to:Float.self),count:vector.count)
                if similarity > minimumSimilarity, candidates.mayImprove(similarity) { candidates.offer(SemanticCandidate(id:string(stmt,0),similarity:similarity,timestamp:sqlite3_column_double(stmt,2),passage:sqlite3_column_int64(stmt,3) < 0 ? nil : PassageRange(start:Int(sqlite3_column_int64(stmt,3)),length:Int(sqlite3_column_int64(stmt,4))))) }
            }
            guard vectorStatus == SQLITE_DONE else { throw failure() }
            best = candidates.sorted
            }
            for (rank, pair) in best.enumerated() {
                if var hit = scored[pair.id] { hit.score += similarityFusion ? pair.similarity : 1 / Double(60 + rank); hit.match = "hybrid"; hit.passage = pair.passage; scored[pair.id] = hit }
                else if let memory = try getForSearch(pair.id,detail:detail) { scored[pair.id] = SearchHit(memory: memory, score: mode == .semantic || similarityFusion ? pair.similarity : 1 / Double(60 + rank), match: "semantic",passage:pair.passage) }
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
        let sql = whereSQL == "1=1" ? "SELECT COALESCE((SELECT parents FROM vector_statistics WHERE model=?),0)" : "SELECT COUNT(*) FROM memories m CROSS JOIN vector_keys r ON r.memory_id=m.id WHERE r.ordinal=0 AND r.model=? AND \(whereSQL)"
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
    public func resolveQueryScope(_ filter: SearchFilter, interpret: Bool = true, now: Date = Date(), timeZone: TimeZone = .current) throws -> QueryResolution {
        lock.lock(); defer { lock.unlock() }
        try exec("SAVEPOINT query_scope_snapshot"); defer { try? exec("RELEASE query_scope_snapshot") }
        return try QueryScopeResolver.resolve(filter,now:now,timeZone:timeZone,interpret:interpret) { app in
            let exact = try self.prepare("SELECT 1 FROM application_statistics WHERE app=?")
            defer { sqlite3_finalize(exact) }; self.bind(exact,1,app)
            let exactStatus = sqlite3_step(exact)
            if exactStatus == SQLITE_ROW { return app }
            guard exactStatus == SQLITE_DONE else { throw self.failure() }
            // App catalogs are small; Foundation folding handles non-ASCII
            // names which SQLite's built-in NOCASE does not cover.
            let statement = try self.prepare("SELECT app FROM application_statistics ORDER BY app LIMIT 10001")
            defer { sqlite3_finalize(statement) }
            var names = [String](), status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if names.count%256 == 0 { try Task.checkCancellation() }
                names.append(self.string(statement,0)); status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw self.failure() }
            guard names.count <= 10000 else { throw QuerySyntaxError("Choose the application's exact spelling from the application menu.") }
            return try QueryScopeResolver.canonicalAppName(app,names:names)
        }
    }
    public func memoriesNeedingVectors(modelID: String, afterID: String = "", limit: Int = 16) throws -> [Memory] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT m.payload FROM memories m LEFT JOIN semantic_vectors v ON v.memory_id=m.id AND v.model=? LEFT JOIN passage_manifests p ON p.memory_id=m.id AND p.model=? AND p.version=? WHERE m.id>? AND ((v.memory_id IS NULL AND NOT(m.embedding IS NOT NULL AND m.embedding_model IS ?)) OR (length(CAST(m.text AS BLOB))>2400 AND p.memory_id IS NULL)) ORDER BY m.id LIMIT ?")
        defer { sqlite3_finalize(stmt) }; bind(stmt,1,modelID); bind(stmt,2,modelID); sqlite3_bind_int(stmt,3,Int32(SemanticPassagePlan.version)); bind(stmt,4,afterID); bind(stmt,5,modelID); sqlite3_bind_int(stmt,6,Int32(min(32,max(1,limit))))
        var memories = [Memory](); while sqlite3_step(stmt) == SQLITE_ROW { memories.append(try decode(stmt)) }; return memories
    }
    @discardableResult public func saveVectors(_ records: [VectorRecord], modelID: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }; try exec("BEGIN IMMEDIATE"); var count = 0
        do {
            for record in records {
                guard !record.vector.isEmpty, record.vector.count <= 8192, record.vector.allSatisfy(\.isFinite), let memory = try get(record.memoryID), memory.contentHash == record.contentHash else { continue }
                let invalidate = try prepare("DELETE FROM semantic_passages WHERE memory_id=? AND model=? AND dimension<>?")
                defer { sqlite3_finalize(invalidate) }; bind(invalidate,1,record.memoryID); bind(invalidate,2,modelID); sqlite3_bind_int(invalidate,3,Int32(record.vector.count))
                guard sqlite3_step(invalidate) == SQLITE_DONE else { throw failure() }
                if sqlite3_changes(db)>0 {
                    let clear = try prepare("DELETE FROM passage_manifests WHERE memory_id=? AND model=?"); defer { sqlite3_finalize(clear) }; bind(clear,1,record.memoryID); bind(clear,2,modelID); guard sqlite3_step(clear) == SQLITE_DONE else { throw failure() }
                }
                let stmt = try prepare("INSERT INTO semantic_vectors(memory_id,model,dimension,vector,content_hash) VALUES(?,?,?,?,?) ON CONFLICT(memory_id,model) DO UPDATE SET dimension=excluded.dimension,vector=excluded.vector,content_hash=excluded.content_hash")
                defer { sqlite3_finalize(stmt) }; bind(stmt,1,record.memoryID); bind(stmt,2,modelID); sqlite3_bind_int(stmt,3,Int32(record.vector.count)); _ = record.vector.withUnsafeBytes { sqlite3_bind_blob(stmt,4,$0.baseAddress,Int32($0.count),transient) }; bind(stmt,5,record.contentHash)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }; count += 1
            }
            try exec("COMMIT"); return count
        } catch { try? exec("ROLLBACK"); throw error }
    }
    public func semanticIndexes() throws -> [String:Int] {
        lock.lock(); defer { lock.unlock() }; let stmt = try prepare("SELECT model,parents FROM vector_statistics WHERE parents>0"); defer { sqlite3_finalize(stmt) }; var result = [String:Int](); while sqlite3_step(stmt) == SQLITE_ROW { result[string(stmt,0)] = Int(sqlite3_column_int(stmt,1)) }; return result
    }
    public func timelineSample(_ filter: SearchFilter, limit: Int = 24, detail:SearchDetail = .full) throws -> [Memory] {
        lock.lock(); defer { lock.unlock() }
        let count = min(100, max(2, limit)), (whereSQL, values) = conditions(filter)
        let payload=detail == .preview ? "COALESCE(preview.payload,m.payload)":"m.payload"
        let previewJoin=detail == .preview ? " LEFT JOIN audio_search_previews preview ON preview.memory_id=m.id":""
        // Rank thin IDs first; never sort every full transcript into a temporary table.
        let stmt = try prepare("WITH ranked AS (SELECT id,ROW_NUMBER() OVER (ORDER BY timestamp,id) AS rn,COUNT(*) OVER () AS total FROM memories m WHERE \(whereSQL)), chosen AS (SELECT id,rn FROM ranked WHERE rn=1 OR rn=total OR (rn-1) % MAX(1,CAST((total-1)/? AS INTEGER))=0) SELECT \(payload) FROM chosen r JOIN memories m ON m.id=r.id\(previewJoin) ORDER BY r.rn")
        defer { sqlite3_finalize(stmt) }
        for (index,value) in values.enumerated() { bind(stmt,Int32(index+1),value) }; sqlite3_bind_int(stmt,Int32(values.count+1),Int32(count-1))
        var memories = [Memory](); while sqlite3_step(stmt) == SQLITE_ROW { memories.append(try decode(stmt)) }
        if memories.count <= count { return memories }
        return (0..<count).map { memories[Int(Double($0)*Double(memories.count-1)/Double(count-1))] }
    }
    private func changeMetadata(_ id:String,change:(inout Memory)->Void) throws {
        lock.lock();defer {lock.unlock()};try exec("BEGIN IMMEDIATE")
        do {if var memory=try get(id) {change(&memory);try updateMetadata(memory)};try exec("COMMIT")}
        catch {try? exec("ROLLBACK");throw error}
    }
    public func setFavorite(_ id: String, value: Bool) throws {try changeMetadata(id) {$0.favorite=value}}
    public func setTags(_ id: String, tags: [String]) throws {try changeMetadata(id) {$0.tags=Array(Set(tags.filter {!$0.isEmpty})).sorted()}}
    public func renameAudioSpeaker(_ id:String,from speaker:String,to name:String,policy:PrivacyPolicy=PrivacyPolicy()) throws -> Memory {
        lock.lock(); defer { lock.unlock() }; try Task.checkCancellation()
        let label=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !label.isEmpty,label.count<=128,!label.utf8.contains(0),!policy.sanitize(label).redacted else { throw OSwindError.invalid("Use a speaker name of 1–128 characters without secrets") }
        try exec("BEGIN IMMEDIATE")
        do {
            guard var memory=try get(id),memory.kind == .audio,var transcript=memory.transcript,transcript.text==memory.text,transcript.segments.contains(where:{$0.speaker==speaker}) else { throw OSwindError.invalid("Speaker or recording no longer exists") }
            guard label==speaker || !transcript.segments.contains(where:{$0.speaker != speaker && $0.speaker.map(SpeakerLabel.key)==SpeakerLabel.key(label)}) else { throw OSwindError.invalid("Another speaker in this recording already has that name") }
            for index in transcript.segments.indices where transcript.segments[index].speaker==speaker { transcript.segments[index].speaker=label }
            if label != speaker { try invalidateAudioEvidence(id) }
            memory.transcript=try transcript.validated(); try Task.checkCancellation(); try updateMetadata(memory); try exec("COMMIT");_ = finishRecapInvalidation(); return memory
        } catch { try? exec("ROLLBACK"); throw error }
    }
    private func updateMetadata(_ m: Memory) throws {
        lock.lock(); defer { lock.unlock() }; let stmt = try prepare("UPDATE memories SET payload=?,favorite=? WHERE id=?"); defer { sqlite3_finalize(stmt) }; let data = try JSONEncoder().encode(m); _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), transient) }; sqlite3_bind_int(stmt, 2, m.favorite ? 1 : 0); bind(stmt, 3, m.id); guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }; try replaceSpeakerProjection(m); try replaceSearchPreview(m)
    }
    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do { try exec("DELETE FROM routines; DELETE FROM chat_sessions; DELETE FROM memories; DELETE FROM erasure_assets; DELETE FROM vector_changes; UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='identity'; COMMIT") } catch { try? exec("ROLLBACK"); throw error }
        metalScopeCache = nil; coverageCache.removeAll(); annCache.reset(); let cache = root.appendingPathComponent("indexes")
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.removeItem(at:cache) }
        try exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        for folder in ["images", "audio","video"] { let url = root.appendingPathComponent(folder); try FileManager.default.removeItem(at: url); try Paths.ensure(url) }
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
        lock.lock(); defer { lock.unlock() }; let stmt = try prepare("SELECT payload FROM memories ORDER BY timestamp"); defer { sqlite3_finalize(stmt) }; var memories = [Memory](); while sqlite3_step(stmt) == SQLITE_ROW { memories.append(try decode(stmt)) }; let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .custom { date, encoder in try ISOTime.encode(date,to:encoder) }; try encoder.encode(memories).write(to: url, options: .atomic)
    }
    @discardableResult public func importJSON(from url:URL,embedder:LocalEmbedder?=nil,policy:PrivacyPolicy=PrivacyPolicy()) throws -> Int {try importJSONDetailed(from:url,embedder:embedder,policy:policy).imported}
    public func importJSONDetailed(from url:URL,embedder:LocalEmbedder?=nil,policy:PrivacyPolicy=PrivacyPolicy()) throws -> JSONImportResult {
        try Task.checkCancellation()
        let data=try Data(contentsOf:url);guard data.count<=100_000_000 else {throw OSwindError.invalid("Import exceeds 100 MB")}
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .custom {try ISOTime.decode(from:$0)}
        let memories:[Memory]
        do {memories=try decoder.decode([Memory].self,from:data)} catch {memories=try JSONDecoder().decode([Memory].self,from:data)}
        let ordered=try RecapImport.ordered(memories),inputIDs=Set(memories.map(\.id))
        lock.lock();defer {lock.unlock()};try exec("BEGIN IMMEDIATE")
        do {
            var report=JSONImportResult(),blocked=Set<String>()
            for var m in ordered {
                try Task.checkCancellation()
                if policy.exclusion(app:m.bundleID,title:m.title,url:m.url) != nil {blocked.insert(m.id);report.excluded+=1;continue}
                if let recap=m.recap {
                    var omit=false
                    for reference in recap.sources {
                        if blocked.contains(reference.id) {omit=true;break}
                        guard let current=try get(reference.id) else {throw OSwindError.invalid("Linked recap import is missing a source. Import the complete JSON library or restore a full backup.")}
                        if !inputIDs.contains(reference.id),policy.exclusion(app:current.bundleID,title:current.title,url:current.url) != nil {omit=true;break}
                        if current.evidenceHash != reference.revision {omit=true;break}
                    }
                    if omit {blocked.insert(m.id);report.skippedLinkedRecaps+=1;continue}
                }
                if let visual=m.visualRecording {
                    guard m.text==visual.text else {throw OSwindError.invalid("Visual recording and source text differ")}
                    let clean=try visual.sanitized(policy:policy);m.visualRecording=clean;m.text=clean.text
                } else if let transcript=m.transcript {
                    guard m.text==transcript.text else {throw OSwindError.invalid("Transcript and source text differ")}
                    let clean=try transcript.sanitized(policy:policy).transcript;m.transcript=clean;m.text=clean.text
                } else {m.text=policy.sanitize(m.text).text}
                if var recap=m.recap {recap.provider=policy.sanitize(recap.provider).text;m.recap=recap}
                m.title=policy.sanitize(m.title).text;m.url=m.url.map {policy.sanitize($0).text};m.imagePath=nil;m.audioPath=nil;m.videoPath=nil;m.regions=[]
                m.embedding=embedder?.embed(m.searchableText);m.embeddingModel=m.embedding==nil ? nil:embedder?.modelID
                try insert(m);if let embedder {try indexApplePassages(m,embedder:embedder)};report.imported+=1
            }
            try Task.checkCancellation();try exec("COMMIT");_ = finishRecapInvalidation();return report
        } catch {try? exec("ROLLBACK");throw error}
    }

}

extension MemoryStore {
    public var searchIndexStatus: SearchIndexStatus { annCache.status }
    @discardableResult public func buildSearchIndex(modelID: String, dimensions: Int, rebuild: Bool = false, allowLowPower: Bool = false) async throws -> SearchIndexStatus {
        let count = try vectorEntityCount(modelID:modelID)
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
        let ownsTransaction=sqlite3_get_autocommit(db) != 0
        try exec(ownsTransaction ? "BEGIN IMMEDIATE":"SAVEPOINT chat_append")
        do {
            guard let session = try chat(sessionID) else { throw OSwindError.invalid("Conversation no longer exists") }
            for hit in answer.sources { guard hit.memory.searchPreview==nil,let current = try get(hit.id), current.evidenceHash == hit.memory.evidenceHash else { throw OSwindError.unavailable("Evidence changed during the answer. Ask again using the remaining memories.") } }
            var scope = answer.resolution?.filter ?? filter; scope.query = ""
            scope.speaker=scope.speaker.map { policy.sanitize($0).text }
            let payload = ChatPayload(question:policy.sanitize(question).text,text:policy.sanitize(answer.text).text,provider:answer.provider,duration:answer.duration,warnings:answer.warnings,filter:scope,timeZone:answer.resolution?.timeZone)
            let id = UUID().uuidString, timestamp = Date(), data = try JSONEncoder().encode(payload)
            let stmt = try prepare("INSERT INTO chat_turns(id,session_id,timestamp,payload) VALUES(?,?,?,?)"); defer { sqlite3_finalize(stmt) }
            bind(stmt,1,id); bind(stmt,2,sessionID); sqlite3_bind_double(stmt,3,timestamp.timeIntervalSince1970); _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt,4,$0.baseAddress,Int32(data.count),transient) }; guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            for (ordinal,hit) in answer.sources.enumerated() {
                let source = try prepare("INSERT INTO chat_sources(turn_id,memory_id,ordinal,score,match,passage_start,passage_length) VALUES(?,?,?,?,?,?,?)"); defer { sqlite3_finalize(source) }
                bind(source,1,id); bind(source,2,hit.id); sqlite3_bind_int(source,3,Int32(ordinal)); sqlite3_bind_double(source,4,hit.score); bind(source,5,hit.match)
                if let passage = hit.passage, passage.text(in:hit.memory.text) != nil { sqlite3_bind_int64(source,6,Int64(passage.start)); sqlite3_bind_int64(source,7,Int64(passage.length)) }
                guard sqlite3_step(source) == SQLITE_DONE else { throw failure() }
            }
            let update = try prepare("UPDATE chat_sessions SET title=?,updated=? WHERE id=?"); defer { sqlite3_finalize(update) }
            bind(update,1,session.turnCount == 0 ? String(payload.question.replacingOccurrences(of:"\n",with:" ").prefix(80)) : session.title); sqlite3_bind_double(update,2,timestamp.timeIntervalSince1970); bind(update,3,sessionID); guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
            try exec(ownsTransaction ? "COMMIT":"RELEASE chat_append")
            var cleanAnswer = answer; cleanAnswer.text = payload.text
            if var resolution = cleanAnswer.resolution {
                if resolution.originalQuery != payload.question { resolution.clauses = [] }
                resolution.originalQuery = payload.question; resolution.filter = scope
                cleanAnswer.resolution = resolution
            }
            return ChatTurn(id:id,sessionID:sessionID,timestamp:timestamp,question:payload.question,answer:cleanAnswer,filter:scope,timeZone:payload.timeZone)
        } catch { try? exec(ownsTransaction ? "ROLLBACK":"ROLLBACK TO chat_append; RELEASE chat_append"); throw error }
    }
    public func chatTurns(_ sessionID:String,limit:Int=100,turnID:String?=nil) throws -> [ChatTurn] {
        lock.lock(); defer { lock.unlock() }
        let selector=turnID==nil ? "":" AND id=?"
        let stmt=try prepare("SELECT id,timestamp,payload FROM chat_turns WHERE session_id=?\(selector) ORDER BY timestamp DESC,id DESC LIMIT ?");defer {sqlite3_finalize(stmt)};bind(stmt,1,sessionID)
        if let turnID {bind(stmt,2,turnID)};sqlite3_bind_int(stmt,turnID==nil ? 2:3,Int32(min(1000,max(1,limit))))
        var turns = [ChatTurn]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = string(stmt,0), date = Date(timeIntervalSince1970:sqlite3_column_double(stmt,1))
            guard let bytes = sqlite3_column_blob(stmt,2) else { throw OSwindError.database("Missing conversation payload") }
            let payload = try JSONDecoder().decode(ChatPayload.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(stmt,2))))
            let source = try prepare("SELECT m.payload,s.score,s.match,s.passage_start,s.passage_length FROM chat_sources s JOIN memories m ON m.id=s.memory_id WHERE s.turn_id=? ORDER BY s.ordinal"); defer { sqlite3_finalize(source) }; bind(source,1,id)
            var hits = [SearchHit]()
            while sqlite3_step(source) == SQLITE_ROW { hits.append(SearchHit(memory:try decode(source),score:sqlite3_column_double(source,1),match:string(source,2),passage:sqlite3_column_type(source,3) == SQLITE_NULL ? nil : PassageRange(start:Int(sqlite3_column_int64(source,3)),length:Int(sqlite3_column_int64(source,4))))) }
            turns.append(ChatTurn(id:id,sessionID:sessionID,timestamp:date,question:payload.question,answer:Answer(text:payload.text,sources:hits,provider:payload.provider,duration:payload.duration,warnings:payload.warnings),filter:payload.filter,timeZone:payload.timeZone))
        }
        return turns.reversed()
    }
}

extension MemoryStore {
    /// Called inside the search's SQL snapshot. Only current, matching rows can
    /// become evidence. Mutations newer than the graph are searched exactly.
    func indexedCandidates(_ filter: SearchFilter, modelID: String, dimensions: Int, scorer: CosineScorer, minimumSimilarity: Double, limit: Int, expression:SearchExpressionPlan? = nil, strategy: (String) -> Void = { _ in }) throws -> [SemanticCandidate]? {
        lock.lock(); defer { lock.unlock() }
        let ownsExpression = expression?.hasConstraints == true && expression?.materialized == false
        var scopedExpression = expression
        try exec("SAVEPOINT index_candidate_snapshot"); defer {
            if ownsExpression { try? exec("DELETE FROM temp.search_expression_scope") }
            try? exec("RELEASE index_candidate_snapshot")
        }
        if let expression { scopedExpression = try materializeExpression(expression) }
        let state = try prepare("SELECT (SELECT value FROM store_metadata WHERE key='identity'),COALESCE((SELECT MAX(seq) FROM vector_changes),0),(SELECT hex(revision) FROM search_scope_revision WHERE singleton=1)")
        defer { sqlite3_finalize(state) }
        guard sqlite3_step(state) == SQLITE_ROW else { throw failure() }
        let identity = string(state,0), head = sqlite3_column_int64(state,1), scopeRevision = string(state,2), (whereSQL,values) = conditions(filter,expression:scopedExpression)
        return try annCache.withReady(modelID:modelID,dimensions:dimensions,identity:identity,snapshotHead:head) { native,sequence -> [SemanticCandidate]? in
            strategy(native.strategy)
            let keyCount = min(2000,max(100,limit*2))
            var keys: [UInt64]
            if whereSQL == "1=1" { keys = try native.search(scorer.queryVector,count:keyCount) }
            else if native is MetalFlatIndex {
                let scopeKey = MetalScopeKey(identity:identity,model:modelID,sequence:sequence,revision:scopeRevision,predicate:whereSQL,values:values,expression:scopedExpression?.cacheIdentity)
                let allowedKeys: Set<UInt64>
                if !scopeRevision.isEmpty, let cached = metalScopeCache?.lookup(scopeKey) { allowedKeys = cached }
                else {
                    // One bounded mask, invalidated by transactional metadata
                    // nonce and graph replay sequence. Soft ranking words are
                    // excluded; required phrase/Boolean predicates and values
                    // are part of the key, so constraints never reuse a wrong mask.
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
            let select = VectorCandidateSQL.select()
            let candidate = try prepare(select+" WHERE r.key=? AND r.model=? AND r.revision<=? AND \(whereSQL)")
            defer { sqlite3_finalize(candidate) }; var best = SemanticTopK(capacity:limit), validParents = Set<String>()
            func consume(_ stmt: OpaquePointer) {
                guard sqlite3_column_bytes(stmt,1) == dimensions*MemoryLayout<Float>.size, let bytes = sqlite3_column_blob(stmt,1) else { return }
                let id = string(stmt,0); validParents.insert(id)
                let score = scorer.score(bytes.assumingMemoryBound(to:Float.self),count:dimensions)
                if score > minimumSimilarity, best.mayImprove(score) { best.offer(SemanticCandidate(id:id,similarity:score,timestamp:sqlite3_column_double(stmt,2),passage:sqlite3_column_int64(stmt,3) < 0 ? nil : PassageRange(start:Int(sqlite3_column_int64(stmt,3)),length:Int(sqlite3_column_int64(stmt,4))))) }
            }
            for key in keys {
                try Task.checkCancellation()
                guard key <= UInt64(Int64.max) else { continue }
                sqlite3_reset(candidate); sqlite3_clear_bindings(candidate); sqlite3_bind_int64(candidate,1,Int64(key)); bind(candidate,2,modelID); sqlite3_bind_int64(candidate,3,sequence)
                for (i,value) in values.enumerated() { bind(candidate,Int32(i+4),value) }
                let status = sqlite3_step(candidate)
                if status == SQLITE_ROW { consume(candidate) } else if status != SQLITE_DONE { throw failure() }
            }
            let nativeValid = validParents.count
            // A bounded recent sample keeps repeated identical captures from
            // arbitrarily hiding the newest source behind native tie ordering.
            let recent = try prepare(VectorCandidateSQL.recent(appScoped:filter.app != nil,predicate:whereSQL))
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
            if !(native is MetalFlatIndex) && keys.count == keyCount {
                let parents = try vectorCount(modelID:modelID,filter:filter)
                if nativeValid < min(limit,parents) { return nil }
            }
            return best.sorted
        } ?? nil
    }
}

extension MemoryStore {
    func vectorEntityCount(modelID: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT COALESCE((SELECT entities FROM vector_statistics WHERE model=?),0)"); defer { sqlite3_finalize(stmt) }; bind(stmt,1,modelID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }; return Int(sqlite3_column_int64(stmt,0))
    }
    func passagesCurrent(_ memory: Memory, modelID: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !SemanticPassagePlan.needed(memory) { return true }
        let stmt = try prepare("SELECT 1 FROM passage_manifests WHERE memory_id=? AND model=? AND content_hash=? AND version=?")
        defer { sqlite3_finalize(stmt) }; bind(stmt,1,memory.id); bind(stmt,2,modelID); bind(stmt,3,memory.contentHash); sqlite3_bind_int(stmt,4,Int32(SemanticPassagePlan.version))
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    public func passageBacklog(modelID: String, filter: SearchFilter) throws -> Int {
        lock.lock(); defer { lock.unlock() }; let (predicate,values) = conditions(filter)
        // UTF-8 length is a conservative fast upper bound; a short multibyte
        // record receives an empty completion manifest during its next pass.
        let stmt = try prepare("SELECT COUNT(*) FROM memories m INDEXED BY memories_passage_candidates WHERE \(predicate) AND length(CAST(m.text AS BLOB))>2400 AND NOT EXISTS(SELECT 1 FROM passage_manifests p WHERE p.memory_id=m.id AND p.model=? AND p.version=?)")
        defer { sqlite3_finalize(stmt) }; for (i,value) in values.enumerated() { bind(stmt,Int32(i+1),value) }; bind(stmt,Int32(values.count+1),modelID); sqlite3_bind_int(stmt,Int32(values.count+2),Int32(SemanticPassagePlan.version))
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }; return Int(sqlite3_column_int64(stmt,0))
    }
    /// Replace all passages atomically only while the source revision and base
    /// vector still match. Cancellation saves earlier sources, never half a source.
    @discardableResult func savePassages(memory: Memory, modelID: String, records: [PassageVector]) throws -> Bool {
        let plan = SemanticPassagePlan.make(memory)
        guard records.count == plan.count, zip(records,plan).allSatisfy({ $0.range == $1.range }), records.allSatisfy({ (1...8192).contains($0.vector.count) && CosineScorer($0.vector) != nil }), Set(records.map { $0.vector.count }).count <= 1 else { throw OSwindError.invalid("Invalid or incomplete passage vectors") }
        lock.lock(); defer { lock.unlock() }; try Task.checkCancellation(); try exec("SAVEPOINT passage_commit")
        do {
            guard let current = try get(memory.id), current.contentHash == memory.contentHash else { try exec("RELEASE passage_commit"); return false }
            let base = try prepare("SELECT length(COALESCE(v.vector,CASE WHEN m.embedding_model=? THEN m.embedding END))/4 FROM memories m LEFT JOIN semantic_vectors v ON v.memory_id=m.id AND v.model=? WHERE m.id=?")
            defer { sqlite3_finalize(base) }; bind(base,1,modelID); bind(base,2,modelID); bind(base,3,memory.id)
            guard sqlite3_step(base) == SQLITE_ROW, sqlite3_column_int(base,0)>0, records.first.map({$0.vector.count == Int(sqlite3_column_int(base,0))}) ?? true else { throw OSwindError.invalid("Passage and source vector dimensions must match") }
            let remove = try prepare("DELETE FROM semantic_passages WHERE memory_id=? AND model=?"); defer { sqlite3_finalize(remove) }; bind(remove,1,memory.id); bind(remove,2,modelID); guard sqlite3_step(remove) == SQLITE_DONE else { throw failure() }
            let insert = try prepare("INSERT INTO semantic_passages(memory_id,model,ordinal,start,length,dimension,vector) VALUES(?,?,?,?,?,?,?)"); defer { sqlite3_finalize(insert) }
            for (i,record) in records.enumerated() {
                if i%64 == 0 { try Task.checkCancellation() }
                sqlite3_reset(insert); sqlite3_clear_bindings(insert); bind(insert,1,memory.id); bind(insert,2,modelID); sqlite3_bind_int(insert,3,Int32(i+1)); sqlite3_bind_int64(insert,4,Int64(record.range.start)); sqlite3_bind_int64(insert,5,Int64(record.range.length)); sqlite3_bind_int(insert,6,Int32(record.vector.count)); _ = record.vector.withUnsafeBytes { sqlite3_bind_blob(insert,7,$0.baseAddress,Int32($0.count),transient) }; guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
            }
            let manifest = try prepare("INSERT INTO passage_manifests(memory_id,model,content_hash,version,count) VALUES(?,?,?,?,?) ON CONFLICT(memory_id,model) DO UPDATE SET content_hash=excluded.content_hash,version=excluded.version,count=excluded.count")
            defer { sqlite3_finalize(manifest) }; bind(manifest,1,memory.id); bind(manifest,2,modelID); bind(manifest,3,memory.contentHash); sqlite3_bind_int(manifest,4,Int32(SemanticPassagePlan.version)); sqlite3_bind_int(manifest,5,Int32(records.count)); guard sqlite3_step(manifest) == SQLITE_DONE else { throw failure() }
            try Task.checkCancellation(); try exec("RELEASE passage_commit"); return true
        } catch { try? exec("ROLLBACK TO passage_commit; RELEASE passage_commit"); throw error }
    }
}

extension MemoryStore {
    func indexApplePassages(_ memory: Memory, embedder: LocalEmbedder) throws {
        guard memory.embeddingModel == embedder.modelID, SemanticPassagePlan.needed(memory), try !passagesCurrent(memory,modelID:embedder.modelID) else { return }
        var records = [PassageVector]()
        for passage in SemanticPassagePlan.make(memory) {
            try Task.checkCancellation()
            guard let vector = embedder.embed(passage.input) else { throw OSwindError.unavailable("Apple passage embeddings unavailable") }
            records.append(PassageVector(range:passage.range,vector:vector))
        }
        _ = try savePassages(memory:memory,modelID:embedder.modelID,records:records)
    }
}

extension MemoryStore {
    /// Only the fresh, unpublished restore library uses this operation.
    func withRestoreTransaction(_ body: (OpaquePointer) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard let db, try matchingCount()==0 else { throw OSwindError.invalid("Restore requires an empty unpublished library") }
        // A private single-writer restore does not need WAL. Rollback can then
        // discard newly appended pages without a large checkpoint on cancel.
        try exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA cache_size=-8192; BEGIN IMMEDIATE;")
        sqlite3_progress_handler(db,1000,{ _ in Task.isCancelled ? 1 : 0 },nil)
        defer { sqlite3_progress_handler(db,0,nil,nil) }
        do { try body(db); try Task.checkCancellation(); try exec("COMMIT") }
        catch { sqlite3_progress_handler(db,0,nil,nil); try? exec("ROLLBACK"); try Task.checkCancellation(); throw error }
    }
    func sealRestoredLibrary() throws {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw OSwindError.database("Restore library is closed") }
        sqlite3_progress_handler(db,1000,{ _ in Task.isCancelled ? 1 : 0 },nil)
        defer { if let db = self.db { sqlite3_progress_handler(db,0,nil,nil) } }
        let integrity = try prepare("PRAGMA quick_check")
        guard sqlite3_step(integrity)==SQLITE_ROW, string(integrity,0)=="ok", sqlite3_step(integrity)==SQLITE_DONE else { sqlite3_finalize(integrity); try Task.checkCancellation(); throw OSwindError.database("Restored library integrity check failed") }
        sqlite3_finalize(integrity)
        let foreign = try prepare("PRAGMA foreign_key_check")
        let status = sqlite3_step(foreign); sqlite3_finalize(foreign)
        guard status==SQLITE_DONE else { throw OSwindError.database("Restored library has invalid source references") }
        try Task.checkCancellation()
        // All prepared statements must close before the folder is published.
        sqlite3_progress_handler(db,0,nil,nil)
        guard sqlite3_close(db)==SQLITE_OK else { throw failure() }; self.db = nil
    }
    func discardRestoreConnection() {
        lock.lock(); defer { lock.unlock() }; if let db { sqlite3_close_v2(db); self.db = nil }
    }
}
