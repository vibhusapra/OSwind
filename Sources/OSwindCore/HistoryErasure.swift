import Foundation
import CSQLite
import CryptoKit

/// Exact metadata selectors. At least one bound is required; never interprets search syntax.
public struct HistoryErasureScope: Codable, Equatable, Sendable {
    public var start: Date?
    public var end: Date?
    public var app: String?
    public var bundleID: String?
    public var domain: String?
    public var includeSubdomains: Bool
    public var kind: MemoryKind?
    public init(start:Date?=nil,end:Date?=nil,app:String?=nil,bundleID:String?=nil,domain:String?=nil,includeSubdomains:Bool=true,kind:MemoryKind?=nil) {
        self.start=start;self.end=end;self.app=app;self.bundleID=bundleID;self.domain=domain;self.includeSubdomains=includeSubdomains;self.kind=kind
    }
    public func validated() throws -> Self {
        var result=self
        for value in [start,end].compactMap({$0}) {guard value.timeIntervalSince1970.isFinite else {throw OSwindError.invalid("Use finite erasure dates")}}
        if let start,let end {guard start<end else {throw OSwindError.invalid("Erasure start must precede end")}}
        for value in [app,bundleID].compactMap({$0}) {guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,value.count<=500,!value.utf8.contains(0) else {throw OSwindError.invalid("Use a nonempty application name or bundle ID")}}
        if let domain {
            let value=domain.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
            guard !value.isEmpty,value.count<=253,!value.contains(where: {":/\\%@?#*".contains($0)}),
                  let components=URLComponents(string:"https://"+value),let host=components.url?.host,components.port==nil,components.user==nil,components.password==nil else {throw OSwindError.invalid("Enter a website hostname, without a scheme, path, wildcard or port")}
            let normalized=host.lowercased().hasSuffix(".") ? String(host.lowercased().dropLast()):host.lowercased()
            let labels=normalized.split(separator:".",omittingEmptySubsequences:false)
            guard !normalized.isEmpty,labels.allSatisfy({label in !label.isEmpty && label.count<=63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy({(97...122).contains($0) || (48...57).contains($0) || $0==45})}) else {throw OSwindError.invalid("Invalid website hostname")}
            result.domain=normalized
        }
        guard start != nil || end != nil || app != nil || bundleID != nil || domain != nil || kind != nil else {throw OSwindError.invalid("Select a time, application, website or source type before erasing")}
        return result
    }
    func matches(url:String?) -> Bool {
        guard let domain else {return true}
        guard let url,let parts=URLComponents(string:url),["http","https"].contains(parts.scheme?.lowercased() ?? ""),let host=parts.url?.host?.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:".")) else {return false}
        return host==domain || includeSubdomains && host.hasSuffix("."+domain)
    }
}
public struct HistoryErasureSample: Codable, Sendable {
    public let id,app,title:String
    public let timestamp:Date
}
public struct HistoryErasurePreview: Codable, Sendable {
    public let scope:HistoryErasureScope
    public let token:String
    public let sources,conversationTurns,mediaReferences:Int
    public let samples:[HistoryErasureSample]
}
public struct HistoryErasureResult: Codable, Sendable {
    public let sources,conversationTurns:Int
    public let removedMedia,sharedMedia,pendingMedia:Int
    public let searchCacheRemoved:Bool
    public let warnings:[String]
}
enum HistoryErasureSchema {
    // Additive queue: older writers preserve it. No source text or credentials are stored.
    static let sql="CREATE TABLE IF NOT EXISTS erasure_assets(path TEXT PRIMARY KEY) WITHOUT ROWID;"
}
private extension RoutineDatabase {
    func eraseCount(_ sql:String) throws -> Int {let row=try statement(sql);defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw error()};return Int(sqlite3_column_int64(row,0))}
    func prepareErasure(_ scope:HistoryErasureScope) throws {
        try execute("CREATE TEMP TABLE IF NOT EXISTS erasure_ids(id TEXT PRIMARY KEY) WITHOUT ROWID; DELETE FROM temp.erasure_ids;")
        var predicates=["1=1"],values=[String]()
        if scope.start != nil {predicates.append("(timestamp>=? OR json_extract(CAST(payload AS TEXT),'$.endTimestamp')+978307200>?)")}
        if scope.end != nil {predicates.append("timestamp<?")}
        if let app=scope.app {predicates.append("app=?");values.append(app)}
        if let bundle=scope.bundleID {predicates.append("json_extract(CAST(payload AS TEXT),'$.bundleID')=?");values.append(bundle)}
        if let kind=scope.kind {predicates.append("kind=?");values.append(kind.rawValue)}
        let row=try statement("SELECT id,url FROM memories WHERE "+predicates.joined(separator:" AND "));defer {sqlite3_finalize(row)}
        var index:Int32=1
        if let start=scope.start {sqlite3_bind_double(row,index,start.timeIntervalSince1970);sqlite3_bind_double(row,index+1,start.timeIntervalSince1970);index+=2}
        if let end=scope.end {sqlite3_bind_double(row,index,end.timeIntervalSince1970);index+=1}
        for value in values {bind(row,index,value);index+=1}
        let insert=try statement("INSERT INTO temp.erasure_ids VALUES(?)");defer {sqlite3_finalize(insert)}
        var status=sqlite3_step(row)
        while status==SQLITE_ROW {
            try Task.checkCancellation()
            if scope.matches(url:optional(row,1)) {sqlite3_reset(insert);sqlite3_clear_bindings(insert);bind(insert,1,text(row,0));try done(insert)}
            status=sqlite3_step(row)
        }
        guard status==SQLITE_DONE else {throw error()}
    }
    static let affectedTurns="SELECT DISTINCT s.turn_id FROM chat_sources s JOIN temp.erasure_ids e ON e.id=s.memory_id"
    static let selectedAssets="""
    SELECT json_extract(CAST(payload AS TEXT),'$.imagePath') AS path FROM memories m JOIN temp.erasure_ids e ON e.id=m.id
    UNION SELECT json_extract(CAST(payload AS TEXT),'$.audioPath') FROM memories m JOIN temp.erasure_ids e ON e.id=m.id
    UNION SELECT json_extract(CAST(payload AS TEXT),'$.videoPath') FROM memories m JOIN temp.erasure_ids e ON e.id=m.id
    """
    func erasurePreview(_ scope:HistoryErasureScope) throws -> HistoryErasurePreview {
        var hash=SHA256();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];hash.update(data:try encoder.encode(scope))
        // Any source mutation invalidates a preview. Dependency IDs also catch new cited answers.
        for sql in ["SELECT value FROM store_metadata WHERE key='identity'","SELECT hex(revision) FROM search_scope_revision WHERE singleton=1","\(Self.affectedTurns) ORDER BY s.turn_id"] {
            let row=try statement(sql);defer {sqlite3_finalize(row)};var status=sqlite3_step(row)
            while status==SQLITE_ROW {hash.update(data:Data((text(row,0)+"\n").utf8));status=sqlite3_step(row)}
            guard status==SQLITE_DONE else {throw error()}
        }
        var samples=[HistoryErasureSample]();let row=try statement("SELECT m.id,m.app,m.title,m.timestamp FROM memories m JOIN temp.erasure_ids e ON e.id=m.id ORDER BY m.timestamp DESC,m.id LIMIT 5");defer {sqlite3_finalize(row)}
        var status=sqlite3_step(row);while status==SQLITE_ROW {samples.append(.init(id:text(row,0),app:text(row,1),title:String(text(row,2).prefix(300)),timestamp:Date(timeIntervalSince1970:sqlite3_column_double(row,3))));status=sqlite3_step(row)};guard status==SQLITE_DONE else {throw error()}
        return HistoryErasurePreview(scope:scope,token:hash.finalize().map {String(format:"%02x",$0)}.joined(),sources:try eraseCount("SELECT COUNT(*) FROM temp.erasure_ids"),conversationTurns:try eraseCount("SELECT COUNT(*) FROM (\(Self.affectedTurns))"),mediaReferences:try eraseCount("SELECT COUNT(*) FROM (\(Self.selectedAssets)) WHERE path IS NOT NULL"),samples:samples)
    }
}
private func erasureCancellable<T>(_ db:RoutineDatabase,_ body:() throws -> T) throws -> T {
    try Task.checkCancellation()
    sqlite3_progress_handler(db.handle,1000,{_ in Task.isCancelled ? 1:0},nil)
    defer {sqlite3_progress_handler(db.handle,0,nil,nil)}
    do {return try body()} catch {if Task.isCancelled {throw CancellationError()};throw error}
}
extension MemoryStore {
    public func previewErasure(_ scope:HistoryErasureScope) throws -> HistoryErasurePreview {
        let scope=try scope.validated()
        return try withRoutineDatabase {db in
            try db.execute("CREATE TEMP TABLE IF NOT EXISTS erasure_ids(id TEXT PRIMARY KEY) WITHOUT ROWID; SAVEPOINT erasure_preview")
            defer {try? db.execute("DELETE FROM temp.erasure_ids");try? db.execute("RELEASE erasure_preview")}
            do {return try erasureCancellable(db) {try db.prepareErasure(scope);let preview=try db.erasurePreview(scope);try Task.checkCancellation();return preview}}
            catch {try? db.execute("ROLLBACK TO erasure_preview");throw error}
        }
    }
    /// Requires a preview from this library and unchanged source/dependency state. No remote tool exposure.
    public func eraseHistory(_ scope:HistoryErasureScope,expectedToken:String) throws -> HistoryErasureResult {
        let scope=try scope.validated()
        guard expectedToken.count==64 else {throw OSwindError.invalid("Preview the erasure scope first")}
        return try withRoutineDatabase {db in
            defer {try? db.execute("DELETE FROM temp.erasure_ids")}
            let preview=try erasureCancellable(db) {try db.transaction {
                try db.prepareErasure(scope);let preview=try db.erasurePreview(scope)
                guard preview.token==expectedToken else {throw OSwindError.invalid("History changed after preview. Pause capture and preview again before erasing.")}
                try db.execute("INSERT OR IGNORE INTO erasure_assets SELECT path FROM (\(RoutineDatabase.selectedAssets)) WHERE path IS NOT NULL")
                try db.execute("DELETE FROM memories WHERE id IN (SELECT id FROM temp.erasure_ids)")
                // Existing source triggers remove entire cited turns, labels, previews, passages and vectors.
                if preview.sources>0 {try db.execute("UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='identity'")}
                return preview
            }}
            // Cancellation after COMMIT cannot turn a successful erase into a misleading failure.
            return cleanupErasedAssets(db,sources:preview.sources,turns:preview.conversationTurns)
        }
    }
    /// Retries durable pending media work after an interruption or file-system failure.
    public func retryErasureCleanup() -> HistoryErasureResult {
        (try? withRoutineDatabase {cleanupErasedAssets($0,sources:0,turns:0)}) ?? .init(sources:0,conversationTurns:0,removedMedia:0,sharedMedia:0,pendingMedia:0,searchCacheRemoved:false,warnings:["Could not open erasure cleanup state."])
    }
    private func erasureAssetKey(_ path:String) throws -> String {
        guard let url=assetURL(path) else {throw OSwindError.invalid("An asset reference could not be safely resolved")}
        do {
            // Foundation resolves actual on-disk spelling, including APFS case aliases. Different
            // hard-link directory entries retain different paths, so unlinking one remains safe.
            guard let canonical=try url.resourceValues(forKeys:[.canonicalPathKey]).canonicalPath else {throw OSwindError.invalid("An asset reference has no canonical path")}
            return canonical
        } catch let error as NSError where error.domain==NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(error.code) {return url.standardizedFileURL.path}
    }
    private func cleanupErasedAssets(_ db:RoutineDatabase,sources:Int,turns:Int) -> HistoryErasureResult {
        var removed=0,shared=0,warnings=[String](),cursor=""
        do {
            try db.execute("BEGIN IMMEDIATE")
            do {
                // One source scan and indexed lookups, rather than decoding the entire archive per asset.
                // This writer reservation protects a shared path against concurrent reference admission.
                try db.execute("CREATE TEMP TABLE IF NOT EXISTS erasure_live_assets(path TEXT PRIMARY KEY) WITHOUT ROWID; DELETE FROM temp.erasure_live_assets")
                if try db.eraseCount("SELECT COUNT(*) FROM erasure_assets")>0 {
                    let live=try db.statement("""
                    SELECT path FROM (
                        SELECT json_extract(CAST(payload AS TEXT),'$.imagePath') AS path FROM memories
                        UNION SELECT json_extract(CAST(payload AS TEXT),'$.audioPath') FROM memories
                        UNION SELECT json_extract(CAST(payload AS TEXT),'$.videoPath') FROM memories
                    ) WHERE path IS NOT NULL
                    """)
                    defer {sqlite3_finalize(live)}
                    let put=try db.statement("INSERT OR IGNORE INTO temp.erasure_live_assets VALUES(?)");defer {sqlite3_finalize(put)}
                    var status=sqlite3_step(live)
                    while status==SQLITE_ROW {
                        let key=try erasureAssetKey(db.text(live,0))
                        sqlite3_reset(put);sqlite3_clear_bindings(put);db.bind(put,1,key);try db.done(put)
                        status=sqlite3_step(live)
                    }
                    guard status==SQLITE_DONE else {throw db.error()}
                }
                while true {
                    let row=try db.statement("SELECT path FROM erasure_assets WHERE path>? ORDER BY path LIMIT 100");db.bind(row,1,cursor);var paths=[String]();var status=sqlite3_step(row)
                    while status==SQLITE_ROW {paths.append(db.text(row,0));status=sqlite3_step(row)};sqlite3_finalize(row);guard status==SQLITE_DONE else {throw db.error()};guard !paths.isEmpty else {break}
                    for path in paths {
                        cursor=path
                        do {
                            let ref=try db.statement("SELECT 1 FROM temp.erasure_live_assets WHERE path=?");db.bind(ref,1,try erasureAssetKey(path));let code=sqlite3_step(ref);sqlite3_finalize(ref);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
                            if code==SQLITE_ROW {shared+=1}
                            else if let url=assetURL(path) {
                                do {
                                    let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
                                    guard attributes[.type] as? FileAttributeType == .typeRegular else {throw OSwindError.invalid("An erased asset is not a regular file")}
                                    try FileManager.default.removeItem(at:url);removed+=1
                                } catch let error as NSError where error.domain==NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(error.code) { /* Already absent. */ }
                            } else {throw OSwindError.invalid("An erased asset path could not be safely resolved")}
                            let drop=try db.statement("DELETE FROM erasure_assets WHERE path=?");defer {sqlite3_finalize(drop)};db.bind(drop,1,path);try db.done(drop)
                        } catch {if warnings.isEmpty {warnings.append("Some retained media could not be removed. Retry media cleanup after checking file access.")}}
                    }
                }
                try db.execute("DELETE FROM temp.erasure_live_assets; COMMIT")
            } catch {try? db.execute("ROLLBACK");throw error}
        } catch {warnings.append("Pending media cleanup did not finish; retry cleanup.")}
        cancelSearchIndexBuild();releaseSearchIndex()
        var cacheRemoved=true
        do {let cache=root.appendingPathComponent("indexes");if FileManager.default.fileExists(atPath:cache.path) {try FileManager.default.removeItem(at:cache)}} catch {cacheRemoved=false;warnings.append("Disposable search files could not be removed. They are invalidated; retry cleanup to remove the files.")}
        // Best effort: concurrent readers may keep WAL pages. This is logical deletion, not secure wiping.
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let pending=(try? db.eraseCount("SELECT COUNT(*) FROM erasure_assets")) ?? -1
        return .init(sources:sources,conversationTurns:turns,removedMedia:removed,sharedMedia:shared,pendingMedia:pending,searchCacheRemoved:cacheRemoved,warnings:warnings)
    }
}
