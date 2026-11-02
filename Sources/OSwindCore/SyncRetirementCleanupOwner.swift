import Foundation

/// Internal crash-recovery owner for a saved logical retirement. It exposes no
/// ordinary MemoryStore, keys or provider writer to the app. Local binding renewal is explicit;
/// received-erase/public session integration remains unfinished.
final class SyncRetirementCleanupOwner:@unchecked Sendable {
    private let lock=NSRecursiveLock(),library:MemoryStore,anchor:SyncDeliveryAnchor,pairing:PersonalSyncPairing
    private var closed=false
    static func open(root:URL,environment:SyncNativeWriterEnvironment = .native)throws->SyncRetirementCleanupOwner {
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("memory.sqlite").path) else {throw OSwindError.invalid("Select the existing retired native library")}
        let library=try MemoryStore(root:root,recoveryReadOnly:false,nativeWriterEnvironment:environment,retirementRecovery:true)
        do {
            let pairing=try PersonalSyncPairing.openRetirement(store:library,environment:environment)
            do {return try Self(library:library,anchor:SyncDeliveryAnchor.openRetirement(library:library,environment:environment),pairing:pairing)}
            catch {pairing.close();throw error}
        }
        catch {try? library.close();throw error}
    }
    private init(library:MemoryStore,anchor:SyncDeliveryAnchor,pairing:PersonalSyncPairing) {self.library=library;self.anchor=anchor;self.pairing=pairing}
    func cleanup(progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in})throws->LibraryWipeResult {
        lock.lock();defer {lock.unlock()}
        guard !closed else {throw OSwindError.unavailable("This retirement recovery owner is closed")}
        return try anchor.cleanupRetirement(progress:progress)
    }
    func close()throws {
        lock.lock();defer {lock.unlock()};guard !closed else {return}
        anchor.close();pairing.close();try library.close();closed=true
    }
    func completeLocalRetirement()throws->SyncCollectionControl {
        lock.lock();defer {lock.unlock()}
        guard !closed else {throw OSwindError.unavailable("This retirement recovery owner is closed")}
        return try anchor.completeLocalRetirement(pairing:pairing.retirementRenewalPreparation())
    }
    deinit {anchor.close();pairing.close();try? library.close()}
}
