import Foundation
import CSQLite

/// One logical implementation for a live session and an offline native owner.
/// The caller holds the exclusive media reservation and external credential
/// lease. No provider, private-inbox descriptor or physical unlink is needed.
struct SyncNativeLocalRetirement {
    static func stage(library:MemoryStore,cache:SyncVersionStore,anchor:SyncDeliveryAnchor,reservation:MediaAdmissionLease,progress:@escaping @Sendable (LibraryBackupProgress)->Void)throws->SyncNativeRetirementResult {
        try reservation.withExclusive(for:library.mediaRootIdentity) {}
        return try library.withRoutineDatabase {db in
            guard db.handle==cache.database.handle else {throw OSwindError.invalid("Erase the owning native library only")}
            try SyncLibraryContext.requireActive(db,cache:cache)
            try cache.validateIncomingDeletionContext()
            return try anchor.retireLocal(in:db) {
                let pairingLifetime=try PersonalSyncPairing.retirementLifetime(db)
                try library.nativeWriterAdmission.rotateForRetirement(db)
                try SyncOutgoingWorkQueue.discardForCollection(db,scope:cache.catalog.scope)
                try db.execute("DELETE FROM personal_sync_changes")
                try SyncPublicationQueue.retireCollectionIfInstalled(cache:cache)
                let counts=try SyncChangeCapture.withoutEcho(db,scope:cache.catalog.scope) {
                    let counts=try library.stageLibraryWipe(reservation:reservation,progress:progress)
                    try db.execute("INSERT INTO store_metadata(key,value) VALUES('library_wipe_dirty','1') ON CONFLICT(key) DO UPDATE SET value='1'")
                    return counts
                }
                let history=SyncCollectionHistory(database:db,replica:cache.journal.replica)
                guard case .needsGroupReview(let control)=try history.reviewState(journal:cache.journal) else {throw OSwindError.invalid("Capture a new local erase intent without approving its group control")}
                try SyncNativeCollectionReceiver.retireRegisters(cache:cache,creator:control.creator,counter:control.counter,frontier:control.era)
                try cache.retireCollectionCaches();try cache.catalog.retireCollectionMappings()
                let complete=try db.statement("INSERT INTO store_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");defer {sqlite3_finalize(complete)}
                db.bind(complete,1,SyncCollectionHistory.nativeCompletionKey);db.bind(complete,2,try control.digest);try db.done(complete)
                try db.execute("UPDATE personal_sync_service_state SET token='' WHERE singleton=1")
                return SyncNativeRetirementResult(counts:counts,control:control,pairingLifetime:pairingLifetime)
            }
        }
    }
}

extension LibraryWipeResult {
    func attachingLogicalCounts(_ counts:LibraryWipeCounts)->Self {
        let e=erasure
        let erasure=HistoryErasureResult(sources:counts.sources,conversationTurns:counts.turns,removedMedia:e.removedMedia,sharedMedia:e.sharedMedia,pendingMedia:e.pendingMedia,searchCacheRemoved:e.searchCacheRemoved,warnings:e.warnings,historicalVersions:counts.originals)
        return .init(erasure:erasure,conversations:counts.chats,routines:counts.routines,routineRuns:counts.runs,compacted:compacted,cleanupComplete:cleanupComplete,cancelled:cancelled)
    }
}

extension MemoryStore {
    /// A cheap routing hint from verified open/enrollment. Erasure itself still
    /// revalidates current authority. Never wait on SQLite from a UI action.
    public var requiresOwnedLibraryErasure:Bool {nativeWriterAdmission.requiresOwnedErasure}
}
