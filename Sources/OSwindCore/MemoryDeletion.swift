import Foundation
import CSQLite

public struct RetentionCleanupResult:Codable,Sendable {
    public let erasure:HistoryErasureResult
    public let bytesAfter:Int64
    public let budgetBytes:Int64?
    public let budgetMet:Bool?
    public let cancelled:Bool
}
extension HistoryErasureResult {
    static var empty:Self {.init(sources:0,conversationTurns:0,removedMedia:0,sharedMedia:0,pendingMedia:0,searchCacheRemoved:true,warnings:[])}
    func adding(_ next:Self) -> Self {
        var messages=warnings;for text in next.warnings where !messages.contains(text) {messages.append(text)}
        return .init(sources:sources+next.sources,conversationTurns:conversationTurns+next.conversationTurns,removedMedia:removedMedia+next.removedMedia,sharedMedia:sharedMedia+next.sharedMedia,pendingMedia:next.pendingMedia,searchCacheRemoved:searchCacheRemoved && next.searchCacheRemoved,warnings:messages,historicalVersions:historicalVersions+next.historicalVersions)
    }
    func warning(_ text:String) -> Self {.init(sources:sources,conversationTurns:conversationTurns,removedMedia:removedMedia,sharedMedia:sharedMedia,pendingMedia:pendingMedia,searchCacheRemoved:searchCacheRemoved,warnings:warnings+[text],historicalVersions:historicalVersions)}
}
private extension RoutineDatabase {
    /// A successful SQL step alone does not mean a checkpoint obtained its reader locks.
    /// VACUUM writes a new WAL, which must also be reclaimed before measuring the budget.
    func compactRetentionStorage() throws {
        func checkpoint() throws {
            let row=try statement("PRAGMA wal_checkpoint(TRUNCATE)");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw error()}
            guard sqlite3_column_int(row,0)==0 else {throw OSwindError.database("Storage checkpoint is busy; retain remaining history")}
            guard sqlite3_step(row)==SQLITE_DONE else {throw error()}
        }
        try checkpoint();try execute("VACUUM");try checkpoint()
    }

}
extension MemoryStore {
    /// Logical deletion commits with durable media admission. Postcommit cleanup failures
    /// return warnings and pending paths rather than falsely reporting no deletion.
    @discardableResult public func delete(_ id:String) throws -> HistoryErasureResult {
        try withRoutineDatabase {db in
            defer {try? db.clearErasureSelection()}
            let deleted=try erasureCancellable(db) {try db.transaction {
                try db.prepareCanonicalErasure(id);try retireEntityScopesForErasedSources(db);return try db.eraseSelectedHistory()
            }}
            guard deleted.sources>0 || deleted.historical>0 else {return .empty}
            return cleanupErasedAssets(db,sources:deleted.sources,turns:deleted.turns,histories:deleted.historical)
        }
    }
    /// Compatibility wrapper. Native/CLI callers use pruneHistory to surface file/budget outcomes.
    @discardableResult public func prune(before:Date,maxBytes:Int64?=nil) throws -> Int {try pruneHistory(before:before,maxBytes:maxBytes).erasure.sources}
    public func pruneHistory(before:Date,maxBytes:Int64?=nil) throws -> RetentionCleanupResult {
        guard before.timeIntervalSince1970.isFinite,maxBytes.map({$0>0}) ?? true else {throw OSwindError.invalid("Use a finite retention date and positive storage budget")}
        return try withRoutineDatabase {db in
            defer {try? db.clearErasureSelection()}
            let initial=try erasureCancellable(db) {try db.transaction { () -> RoutineDatabase.ErasedCounts in
                let beforeTurns=try db.eraseCount("SELECT COUNT(*) FROM chat_turns")
                let titles=try db.statement("UPDATE chat_sessions SET title='Conversation' WHERE id IN (SELECT session_id FROM chat_turns WHERE timestamp<?)");defer {sqlite3_finalize(titles)};sqlite3_bind_double(titles,1,before.timeIntervalSince1970);try db.done(titles)
                let chats=try db.statement("DELETE FROM chat_turns WHERE timestamp<?");defer {sqlite3_finalize(chats)};sqlite3_bind_double(chats,1,before.timeIntervalSince1970);try db.done(chats)
                _=try db.prepareErasure(.init(end:before));try retireEntityScopesForErasedSources(db);let erased=try db.eraseSelectedHistory()
                return .init(sources:erased.sources,turns:beforeTurns-(try db.eraseCount("SELECT COUNT(*) FROM chat_turns")),historical:erased.historical)
            }}
            var result=HistoryErasureResult.empty
            let pending=try db.eraseCount("SELECT COUNT(*) FROM erasure_assets"),dirty=try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='recap_cache_dirty_v33' AND value='1'")
            if initial.sources>0 || initial.historical>0 || pending>0 || dirty>0 {result=cleanupErasedAssets(db,sources:initial.sources,turns:initial.turns,histories:initial.historical)}
            else {result = .init(sources:0,conversationTurns:initial.turns,removedMedia:0,sharedMedia:0,pendingMedia:0,searchCacheRemoved:true,warnings:[])}
            var bytes=diskBytes(includeStaging:false),stopped=false
            if let maxBytes,bytes>maxBytes,result.pendingMedia==0,result.searchCacheRemoved,!Task.isCancelled {
                // Rebuildable graph storage goes first, before sacrificing source evidence.
                do {
                    try db.transaction {try db.execute("UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='identity'")}
                    result=result.adding(cleanupErasedAssets(db,sources:0,turns:0))
                    if result.searchCacheRemoved {try db.compactRetentionStorage()}
                } catch {result=result.warning("Storage compaction did not finish; remaining history was retained.");stopped=true}
                bytes=diskBytes(includeStaging:false)
            }
            while let maxBytes,bytes>maxBytes,!stopped,result.pendingMedia==0,result.searchCacheRemoved,!Task.isCancelled {
                do {
                    let batch=try erasureCancellable(db) {try db.transaction {
                        try db.prepareOldestErasure(limit:16);try retireEntityScopesForErasedSources(db);return try db.eraseSelectedHistory()
                    }}
                    guard batch.sources>0 || batch.historical>0 else {break}
                    // No per-source archive scan. Each bounded oldest-first batch commits and
                    // drains once; a failed queue stops further destructive budget trimming.
                    result=result.adding(cleanupErasedAssets(db,sources:batch.sources,turns:batch.turns,histories:batch.historical))
                    if result.pendingMedia==0 {try db.compactRetentionStorage()}
                    bytes=diskBytes(includeStaging:false)
                } catch is CancellationError {stopped=true}
                catch {result=result.warning("Storage cleanup stopped after committed deletions; remaining history was retained.");stopped=true}
            }
            if Task.isCancelled {result=result.warning("Cleanup was cancelled after committed work; remaining history was retained.")}
            if let maxBytes,bytes>maxBytes {result=result.warning("The storage target was not reached. Check pending media, file access or other library files before removing more history.")}
            return .init(erasure:result,bytesAfter:bytes,budgetBytes:maxBytes,budgetMet:maxBytes.map {bytes<=$0},cancelled:Task.isCancelled)
        }
    }
}
