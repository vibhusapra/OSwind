import Foundation

/// One-shot native erase authority. It opens no shared folder or network worker,
/// so local history can be erased when a provider is unavailable. The app must
/// first join its other producers and stop any existing enrolled session.
public actor PersonalSyncLocalErasure {
    private let library:MemoryStore,cache:SyncVersionStore,anchor:SyncDeliveryAnchor,pairing:PersonalSyncPairing
    private var consumed=false
    private var operation:Task<LibraryWipeResult,Error>?
    init(library:MemoryStore,cache:SyncVersionStore,anchor:SyncDeliveryAnchor,pairing:PersonalSyncPairing) {self.library=library;self.cache=cache;self.anchor=anchor;self.pairing=pairing}
    public func erase(progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in})async throws->LibraryWipeResult {
        guard !consumed else {throw OSwindError.unavailable("This local erasure owner is already consumed")}
        consumed=true
        let library=library,cache=cache,anchor=anchor,pairing=pairing
        let worker=Task.detached(priority:.utility) {
            defer {anchor.close();pairing.close()}
            try Task.checkCancellation()
            let staged=try Self.stage(library:library,cache:cache,anchor:anchor,progress:progress)
            let cleaned=try anchor.cleanupRetirement(progress:progress)
            if cleaned.cleanupComplete,!cleaned.cancelled {_=try anchor.completeRetirement(pairing:pairing.retirementRenewalPreparation(),expectedKind:.local)}
            return cleaned.attachingLogicalCounts(staged.counts)
        }
        operation=worker
        return try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
    }
    private nonisolated static func stage(library:MemoryStore,cache:SyncVersionStore,anchor:SyncDeliveryAnchor,progress:@escaping @Sendable (LibraryBackupProgress)->Void)throws->SyncNativeRetirementResult {
        let media=try MediaAdmissionLease.acquire(root:library.root,exclusive:true,expectedRoot:library.mediaRootIdentity);defer {media.release()}
        return try SyncNativeLocalRetirement.stage(library:library,cache:cache,anchor:anchor,reservation:media,progress:progress)
    }
    public func stop()async {
        consumed=true
        let pending=operation;pending?.cancel();_=await pending?.result
        anchor.close();pairing.close()
    }
    deinit {
        let pending=operation,anchor=anchor,pairing=pairing;pending?.cancel()
        if let pending {Task.detached {_=await pending.result;anchor.close();pairing.close()}}
        else {anchor.close();pairing.close()}
    }
}
