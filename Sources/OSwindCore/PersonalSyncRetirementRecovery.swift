import Foundation

/// Retry only an already saved, externally verified erasure. This opens no
/// ordinary library or service and never touches a provider folder. The app
/// closes its previous store and joins this entire operation before departure.
public enum PersonalSyncRetirementRecovery {
    public static func retry(root:URL,progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in})async throws->LibraryWipeResult {
        try await retry(root:root,environment:.native,progress:progress)
    }
    static func retry(root:URL,environment:SyncNativeWriterEnvironment,progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in})async throws->LibraryWipeResult {
        let worker=Task.detached(priority:.utility) {
            try Task.checkCancellation()
            let owner=try SyncRetirementCleanupOwner.open(root:root,environment:environment)
            let outcome:Result<LibraryWipeResult,Error>
            do {
                let result=try owner.cleanup(progress:progress)
                if result.cleanupComplete,!result.cancelled {_=try owner.completeRetirement()}
                outcome = .success(result)
            }catch {outcome = .failure(error)}
            // A canceled cleanup must still acquire the close reservation and
            // release SQLite/credential leases. Join an uncanceled close task.
            try await Task.detached(priority:.utility) {try owner.close()}.value
            return try outcome.get()
        }
        return try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
    }
}
