import Foundation
import CSQLite

/// A whole-source tombstone includes answers and recaps identified by retained
/// wire citations, even when a current native projection differs. Owner keys
/// are resolved by lifetime so retired mappings cannot erase replacement rows.
enum SyncPeerSourceErasurePlan {
    static func select(_ db:RoutineDatabase,object:String)throws->[SyncObjectIdentity] {
        try SyncVersionStore.validateForErasure(db)
        let catalog=try SyncIdentityCatalog(database:db,scope:SyncChangeCapture.scope(db))
        var versions=[String:Set<String>](),reverse=[String:Set<String>](),owners=[String:SyncObjectIdentity](),identities=[String:SyncObjectIdentity]()
        for table in ["personal_sync_versions","historical_evidence"] {
            let row=try db.statement("SELECT object_digest,content_sha,body FROM \(table)");defer {sqlite3_finalize(row)}
            var code=sqlite3_step(row)
            while code==SQLITE_ROW {
                try Task.checkCancellation()
                try autoreleasepool {
                    let digest=db.text(row,0),sha=db.text(row,1),size=Int(sqlite3_column_bytes(row,2))
                    guard sqlite3_column_type(row,2)==SQLITE_BLOB,size>0,size<=SyncProtocolLimits.contentBytes,let bytes=sqlite3_column_blob(row,2) else {throw OSwindError.database("Invalid source erasure evidence")}
                    let record=try SyncPortableRecord.decode(Data(bytes:bytes,count:size))
                    guard try record.identity.key.digest==digest,try record.reference.content.sha256==sha else {throw OSwindError.database("Source erasure evidence integrity differs")}
                    let key=digest+sha;versions[digest,default:[]].insert(key);identities[digest]=record.identity
                    for dependency in record.dependencies {
                        if let content=dependency.content {reverse[try dependency.identity.key.digest+content.sha256,default:[]].insert(key)}
                    }
                    switch record.body {
                    case .conversationCitation(let citation),.recapCitation(let citation):owners[key]=citation.owner
                    case .source(let source) where source.recap != nil:owners[key]=record.identity
                    default:break
                    }
                }
                code=sqlite3_step(row)
            }
            guard code==SQLITE_DONE else {throw db.error()}
        }
        var queue=Array(versions[object] ?? []),seen=Set(queue),selectedOwners=Set<String>(),cursor=0
        func enqueue(_ keys:Set<String>) {for key in keys where seen.insert(key).inserted {queue.append(key)}}
        func nativeRoots()throws {
            let row=try db.statement("SELECT object_digest||content_sha FROM historical_evidence WHERE handle IN (SELECT handle FROM temp.erasure_historical_ids)");defer {sqlite3_finalize(row)}
            var code=sqlite3_step(row)
            while code==SQLITE_ROW {enqueue([db.text(row,0)]);code=sqlite3_step(row)}
            guard code==SQLITE_DONE else {throw db.error()}
        }
        try nativeRoots()
        while cursor<queue.count {
            try Task.checkCancellation();let key=queue[cursor];cursor+=1
            enqueue(reverse[key] ?? [])
            guard let owner=owners[key] else {continue}
            let digest=try owner.key.digest
            guard selectedOwners.insert(digest).inserted else {continue}
            enqueue(versions[digest] ?? [])
            let histories=try db.statement("INSERT OR IGNORE INTO temp.erasure_historical_ids SELECT handle,0 FROM historical_evidence WHERE object_digest=?")
            db.bind(histories,1,digest);defer {sqlite3_finalize(histories)};try db.done(histories)
            if let current=try catalog.object(owner),!current.deleted,let primary=current.primary {
                guard primary.count==1,case .text(let raw)=primary[0],owner.table == .source || owner.table == .turn else {throw OSwindError.database("Source erasure owner key differs")}
                let table=owner.table == .source ? "erasure_ids":"erasure_explicit_turn_ids",native=owner.table == .source ? "memories":"chat_turns"
                let put=try db.statement("INSERT OR IGNORE INTO temp.\(table) SELECT id FROM \(native) WHERE id IS ?");defer {sqlite3_finalize(put)}
                raw.withUnsafeBytes {_=sqlite3_bind_text64(put,1,$0.baseAddress?.assumingMemoryBound(to:CChar.self),UInt64(raw.count),db.transient,UInt8(SQLITE_UTF8))};try db.done(put)
            }
            try db.expandErasureSelection();try nativeRoots()
        }
        let insert=try db.statement("INSERT OR IGNORE INTO temp.erasure_extra_version_ids VALUES(?,?)");defer {sqlite3_finalize(insert)}
        for key in seen {
            try Task.checkCancellation();sqlite3_reset(insert);sqlite3_clear_bindings(insert);db.bind(insert,1,String(key.prefix(64)));db.bind(insert,2,String(key.suffix(64)));try db.done(insert)
        }
        return Set(seen.map {String($0.prefix(64))}).sorted().compactMap {identities[$0]}
    }
}
