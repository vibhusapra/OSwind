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
        return .init(sources:sources+next.sources,conversationTurns:conversationTurns+next.conversationTurns,removedMedia:removedMedia+next.removedMedia,sharedMedia:sharedMedia+next.sharedMedia,pendingMedia:next.pendingMedia,searchCacheRemoved:searchCacheRemoved && next.searchCacheRemoved,warnings:messages)
    }
    func warning(_ text:String) -> Self {.init(sources:sources,conversationTurns:conversationTurns,removedMedia:removedMedia,sharedMedia:sharedMedia,pendingMedia:pendingMedia,searchCacheRemoved:searchCacheRemoved,warnings:warnings+[text])}
}
private extension RoutineDatabase {
    func deletedSources(_ body:() throws -> Void) throws -> (sources:Int,turns:Int) {
        let turns=try eraseCount("SELECT COUNT(*) FROM chat_turns")
        try body();let count=Int(sqlite3_changes(handle)),removed=turns-(try eraseCount("SELECT COUNT(*) FROM chat_turns"))
        if count>0 {try execute("UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='identity'")}
        return (count,removed)
    }
}
extension MemoryStore {
    /// Logical deletion commits with durable media admission. Postcommit cleanup failures
    /// return warnings and pending paths rather than falsely reporting no deletion.
    @discardableResult public func delete(_ id:String) throws -> HistoryErasureResult {
        try withRoutineDatabase {db in
            let deleted=try erasureCancellable(db) {try db.transaction {
                try db.deletedSources {
                    let row=try db.statement("DELETE FROM memories WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id);try db.done(row)
                }
            }}
            guard deleted.sources>0 else {return .empty}
            return cleanupErasedAssets(db,sources:deleted.sources,turns:deleted.turns)
        }
    }
    /// Compatibility wrapper. Native/CLI callers use pruneHistory to surface file/budget outcomes.
    @discardableResult public func prune(before:Date,maxBytes:Int64?=nil) throws -> Int {try pruneHistory(before:before,maxBytes:maxBytes).erasure.sources}
    public func pruneHistory(before:Date,maxBytes:Int64?=nil) throws -> RetentionCleanupResult {
        guard before.timeIntervalSince1970.isFinite,maxBytes.map({$0>0}) ?? true else {throw OSwindError.invalid("Use a finite retention date and positive storage budget")}
        return try withRoutineDatabase {db in
            let initial=try erasureCancellable(db) {try db.transaction { () -> (sources:Int,turns:Int) in
                let beforeTurns=try db.eraseCount("SELECT COUNT(*) FROM chat_turns")
                let titles=try db.statement("UPDATE chat_sessions SET title='Conversation' WHERE id IN (SELECT session_id FROM chat_turns WHERE timestamp<?)");defer {sqlite3_finalize(titles)};sqlite3_bind_double(titles,1,before.timeIntervalSince1970);try db.done(titles)
                let chats=try db.statement("DELETE FROM chat_turns WHERE timestamp<?");defer {sqlite3_finalize(chats)};sqlite3_bind_double(chats,1,before.timeIntervalSince1970);try db.done(chats)
                let row=try db.statement("DELETE FROM memories WHERE timestamp<?");defer {sqlite3_finalize(row)};sqlite3_bind_double(row,1,before.timeIntervalSince1970);try db.done(row);let count=Int(sqlite3_changes(db.handle))
                if count>0 {try db.execute("UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='identity'")}
                return (count,beforeTurns-(try db.eraseCount("SELECT COUNT(*) FROM chat_turns")))
            }}
            var result=HistoryErasureResult.empty
            let pending=try db.eraseCount("SELECT COUNT(*) FROM erasure_assets")
            if initial.sources>0 || pending>0 {result=cleanupErasedAssets(db,sources:initial.sources,turns:initial.turns)}
            else {result = .init(sources:0,conversationTurns:initial.turns,removedMedia:0,sharedMedia:0,pendingMedia:0,searchCacheRemoved:true,warnings:[])}
            var bytes=diskBytes(),stopped=false
            if let maxBytes,bytes>maxBytes,result.pendingMedia==0,result.searchCacheRemoved,!Task.isCancelled {
                // Rebuildable graph storage goes first, before sacrificing source evidence.
                do {
                    try db.transaction {try db.execute("UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='identity'")}
                    result=result.adding(cleanupErasedAssets(db,sources:0,turns:0))
                    if result.searchCacheRemoved {try db.execute("PRAGMA wal_checkpoint(TRUNCATE); VACUUM")}
                } catch {result=result.warning("Storage compaction did not finish; remaining history was retained.");stopped=true}
                bytes=diskBytes()
            }
            while let maxBytes,bytes>maxBytes,!stopped,result.pendingMedia==0,result.searchCacheRemoved,!Task.isCancelled {
                do {
                    let batch=try erasureCancellable(db) {try db.transaction {
                        try db.deletedSources {try db.execute("DELETE FROM memories WHERE id IN (SELECT id FROM memories ORDER BY timestamp,id LIMIT 16)")}
                    }}
                    guard batch.sources>0 else {break}
                    // No per-source archive scan. Each bounded oldest-first batch commits and
                    // drains once; a failed queue stops further destructive budget trimming.
                    result=result.adding(cleanupErasedAssets(db,sources:batch.sources,turns:batch.turns))
                    if result.pendingMedia==0 {try db.execute("PRAGMA wal_checkpoint(TRUNCATE); VACUUM")}
                    bytes=diskBytes()
                } catch is CancellationError {stopped=true}
                catch {result=result.warning("Storage cleanup stopped after committed deletions; remaining history was retained.");stopped=true}
            }
            if Task.isCancelled {result=result.warning("Cleanup was cancelled after committed work; remaining history was retained.")}
            if let maxBytes,bytes>maxBytes {result=result.warning("The storage target was not reached. Check pending media, file access or other library files before removing more history.")}
            return .init(erasure:result,bytesAfter:bytes,budgetBytes:maxBytes,budgetMet:maxBytes.map {bytes<=$0},cancelled:Task.isCancelled)
        }
    }
}
