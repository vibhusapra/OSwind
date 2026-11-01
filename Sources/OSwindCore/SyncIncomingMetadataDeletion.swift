import Foundation
import CSQLite

/// Content-free retirement of native metadata objects. Foreign-key children
/// follow native ownership; independent sources and conversations require their
/// own authenticated tombstones. Source erasure needs its full media adapter.
struct SyncIncomingMetadataDeletion {
    let cache:SyncVersionStore
    let beforeConversationDeletion:(SyncLocalObject)throws->Void
    var db:RoutineDatabase {cache.database}
    static let tables:Set<SyncCanonicalTable> = [.conversation,.turn,.conversationCitation,.routine,.routineRun,.evidencePin]
    static func accepts(_ kind:SyncObjectKind)->Bool {tables.contains {$0.kind==kind}}
    func apply(_ change:SyncJournalChange)throws {
        guard change.after.isDeleted else {throw OSwindError.invalid("Use an admitted metadata deletion barrier")}
        try applyKey(change.revision.key)
    }
    func applyKey(_ key:SyncObjectKey)throws {
        guard try cache.journal.state(for:key).isDeleted,Self.accepts(key.kind) else {throw OSwindError.invalid("Use the corresponding typed metadata deletion adapter")}
        // Preparation uses the ordinary catalog context. The deletion callback
        // itself runs under echo suppression and cannot nest catalog writes.
        if key.kind == .conversation,let object=try cache.catalog.object(for:key),!object.deleted {try beforeConversationDeletion(object)}
        try cache.catalog.deletePeerKey(key,journal:cache.journal) {object in
            // An unknown key only needs its durable journal barrier. There is
            // no native owner to erase and no peer body to download or trust.
            guard let object else {return}
            guard Self.tables.contains(object.identity.table) else {throw OSwindError.unavailable("Known source deletion requires complete original and media erasure admission")}
            let schema=object.identity.table.schema
            guard let primary=object.primary else {throw OSwindError.invalid("Incoming metadata deletion owner is unavailable")}
            _=try SyncIdentityCatalog.keyFrame(object.identity.table,primary)
            let row=try db.statement("DELETE FROM "+schema.name+" WHERE "+schema.primary.map {$0+" IS ?"}.joined(separator:" AND "));defer {sqlite3_finalize(row)}
            for (i,cell) in primary.enumerated() {
                let index=Int32(i+1)
                switch cell {
                case .text(let bytes):
                    let code=bytes.withUnsafeBytes {sqlite3_bind_text64(row,index,$0.baseAddress?.assumingMemoryBound(to:CChar.self),UInt64(bytes.count),db.transient,UInt8(SQLITE_UTF8))}
                    guard code==SQLITE_OK else {throw db.error()}
                case .integer(let number):guard sqlite3_bind_int64(row,index,number)==SQLITE_OK else {throw db.error()}
                default:throw OSwindError.invalid("Incoming metadata deletion key storage differs")
                }
            };try db.done(row)
        }
    }
}
