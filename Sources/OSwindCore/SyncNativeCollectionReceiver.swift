import Foundation
import CSQLite

/// Internal full-native adapter for a newly authenticated group control. The
/// future service must quiesce and join all producers before entering it. Media
/// admission alone cannot stop a text producer holding a pre-erasure snapshot.
/// Physical cleanup is durable and separate, after this receipt commits.
struct SyncNativeCollectionReceiver {
    let library:MemoryStore
    let cache:SyncVersionStore
    let inbox:SyncObjectFolder

    func receive(creator:String,counter:Int64)throws->SyncCollectionReceiveResult {
        try SyncCollectionReceiver(library:library,cache:cache,inbox:inbox,retire:{frontier,reservation in
            _=try retire(creator:creator,counter:counter,frontier:frontier,reservation:reservation)
        }).receive(creator:creator,counter:counter)
    }

    /// The service has verified this exact control from its signed transport.
    /// Use its existing exclusive lease and outer checkpoint transaction.
    func receiveVerified(_ control:SyncCollectionControl,reservation:MediaAdmissionLease,progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in})throws->LibraryWipeCounts {
        try reservation.withExclusive(for:library.mediaRootIdentity) {}
        return try library.withRoutineDatabase {db in
            guard sqlite3_get_autocommit(db.handle)==0,control.creator != cache.journal.replica else {throw OSwindError.invalid("Receive a peer retirement in its owning checkpoint transaction")}
            try SyncLibraryContext.requireActive(db,cache:cache)
            let history=SyncCollectionHistory(database:db,replica:cache.journal.replica)
            var counts:LibraryWipeCounts?
            let applied=try history.observeVerifiedGroupControl(control,journal:cache.journal,retire:{frontier in
                counts=try retire(creator:control.creator,counter:control.counter,frontier:frontier,reservation:reservation,progress:progress)
            })
            guard applied,let counts else {throw OSwindError.invalid("This peer retirement was already observed; preserve the later native lifetime")}
            return counts
        }
    }

    private func retire(creator:String,counter:Int64,frontier:SyncClock,reservation:MediaAdmissionLease,progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in})throws->LibraryWipeCounts {
        try library.withRoutineDatabase {db in
            guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Retire native history with its authenticated receipt")}
            try SyncLibraryContext.requireActive(db,cache:cache)
            try cache.validateIncomingDeletionContext()
            let history=SyncCollectionHistory(database:db,replica:cache.journal.replica)
            guard try history.current()==frontier,frontier[creator]==counter else {throw OSwindError.invalid("Collection retirement differs from its observed control")}
            let receipt=try db.statement("SELECT digest,control FROM personal_sync_collection_received_controls WHERE replica=? AND counter=?");defer {sqlite3_finalize(receipt)}
            db.bind(receipt,1,creator);sqlite3_bind_int64(receipt,2,counter)
            guard sqlite3_step(receipt)==SQLITE_ROW,let bytes=sqlite3_column_blob(receipt,1) else {throw OSwindError.invalid("Collection retirement has no received control")}
            let control=try SyncCollectionControl.decode(Data(bytes:bytes,count:Int(sqlite3_column_bytes(receipt,1))))
            guard control.creator==creator,control.counter==counter,control.group==cache.journal.group,control.epoch==cache.journal.epoch,try control.digest==db.text(receipt,0) else {throw OSwindError.invalid("Collection retirement receipt differs")}

            // A new creator axis cannot already belong to admitted native rows.
            // Refuse stale/manual reuse rather than erase a later lifetime.
            for table in SyncCanonicalTable.allCases {
                let row=try db.statement("SELECT 1 FROM "+table.rawValue+" t JOIN personal_sync_collection_births b ON b.table_name=? AND b.key_digest="+table.schema.snapshot("t",true)+" WHERE COALESCE(json_extract(CAST(b.era AS TEXT),?),0)>=? LIMIT 1")
                defer {sqlite3_finalize(row)};db.bind(row,1,table.rawValue);db.bind(row,2,"$.\""+creator+"\"");sqlite3_bind_int64(row,3,counter)
                guard sqlite3_step(row)==SQLITE_DONE else {throw OSwindError.invalid("A later native lifetime cannot be retired by this control")}
            }
            try Self.retireRegisters(cache:cache,creator:creator,counter:counter,frontier:frontier)
            try SyncOutgoingWorkQueue.discardForCollection(db,scope:cache.catalog.scope)
            try SyncMembershipReplay.retire(db)
            try db.execute("DELETE FROM personal_sync_changes")
            guard try db.eraseCount("SELECT used_bytes FROM personal_sync_capture WHERE singleton=1")==0 else {throw OSwindError.database("Raw collection accounting differs")}
            try SyncPublicationQueue.retireCollectionIfInstalled(cache:cache)
            let counts=try SyncChangeCapture.withoutEcho(db,scope:cache.catalog.scope) {
                let counts=try library.stageLibraryWipe(reservation:reservation,progress:progress)
                try LibraryWipeState.markReceived(db)
                return counts
            }
            try cache.retireCollectionCaches()
            try cache.catalog.retireCollectionMappings()
            for table in SyncCanonicalTable.allCases {
                guard try db.eraseCount("SELECT COUNT(*) FROM "+table.rawValue)==0 else {throw OSwindError.database("Native collection retirement left canonical rows")}
            }
            guard try db.eraseCount("SELECT COUNT(*) FROM historical_evidence")==0,try db.eraseCount("SELECT used_bytes FROM historical_evidence_state WHERE singleton=1")==0 else {throw OSwindError.database("Native collection retirement left archived originals or accounting")}
            // Commit completion only after the full native/cache/original
            // retirement succeeds. Physical cleanup remains a separate gate.
            try SyncCollectionHistory.requireNativeCompletionHooks(db)
            let complete=try db.statement("INSERT INTO store_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");defer {sqlite3_finalize(complete)}
            db.bind(complete,1,SyncCollectionHistory.nativeCompletionKey);db.bind(complete,2,try control.digest);try db.done(complete)
            return counts
        }
    }

    static func retireRegisters(cache:SyncVersionStore,creator:String,counter:Int64,frontier:SyncClock)throws {
        let db=cache.database;var lastKind="",lastDigest=""
        while true {
            try Task.checkCancellation()
            let row=try db.statement("SELECT kind,digest FROM personal_sync_registers WHERE kind>? OR (kind=? AND digest>?) ORDER BY kind,digest LIMIT 128")
            db.bind(row,1,lastKind);db.bind(row,2,lastKind);db.bind(row,3,lastDigest)
            var keys=[SyncObjectKey](),code=sqlite3_step(row)
            do {
                while code==SQLITE_ROW {
                    guard let kind=SyncObjectKind(rawValue:db.text(row,0)) else {throw OSwindError.database("Invalid collection register kind")}
                    keys.append(try SyncObjectKey(kind:kind,digest:db.text(row,1)));code=sqlite3_step(row)
                }
                guard code==SQLITE_DONE else {throw db.error()}
            } catch {sqlite3_finalize(row);throw error}
            sqlite3_finalize(row)
            guard let last=keys.last else {return};lastKind=last.kind.rawValue;lastDigest=last.digest
            for key in keys {
                let state=try cache.journal.state(for:key)
                guard state.heads.allSatisfy({($0.creationEra ?? .empty)[creator]<counter}) else {throw OSwindError.invalid("A later register lifetime cannot be retired by this control")}
                // Real native erasure follows in this same outer transaction;
                // none of these register barriers can commit independently.
                _=try cache.journal.retireKnownCollectionObject(key,frontier:frontier,apply:{_ in})
            }
        }
    }
}
