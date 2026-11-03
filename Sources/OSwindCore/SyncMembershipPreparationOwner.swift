import Foundation

/// Internal preparation owner, unavailable to app/CLI until full handover and
/// new-peer bootstrap are implemented. It opens no provider and changes no
/// private membership. Cancellation keeps native36's old-writer fence.
final class SyncMembershipPreparationOwner:@unchecked Sendable {
    private let lock=NSRecursiveLock(),library:MemoryStore,anchor:SyncDeliveryAnchor
    private let pairing:PersonalSyncPairing?,pairingLease:SyncCredentialExclusiveLease?
    private var closed=false
    static func prepare(root:URL,proof:SyncMembershipRefresh,environment:SyncNativeWriterEnvironment = .native)throws->Self {
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("memory.sqlite").path) else {throw OSwindError.invalid("Select the existing enrolled native library")}
        let library=try MemoryStore(root:root,recoveryReadOnly:false,nativeWriterEnvironment:environment)
        do {return try prepare(library:library,proof:proof,environment:environment)}
        catch {try? library.close();throw error}
    }
    /// The caller transfers its stopped, producer-drained store on success.
    /// On failure it remains the caller's responsibility to close that store.
    static func prepare(library:MemoryStore,proof:SyncMembershipRefresh,environment:SyncNativeWriterEnvironment)throws->Self {
        let pairing=try PersonalSyncPairing.openMembershipPairing(library:library,environment:environment)
        do {
            let (anchor,snapshot)=try pairing.openMembershipPreparationAnchor(proof)
            do {try anchor.prepareMembership(proof,snapshot:snapshot);return Self(library:library,anchor:anchor,pairing:pairing,pairingLease:nil)}
            catch {anchor.close();throw error}
        }catch {pairing.close();throw error}
    }
    static func open(root:URL,environment:SyncNativeWriterEnvironment = .native)throws->Self {
        let library=try MemoryStore(root:root,recoveryReadOnly:false,nativeWriterEnvironment:environment,membershipRecovery:true)
        do {
            let anchor=try SyncDeliveryAnchor.openMembershipPreparation(library:library,environment:environment)
            do {
                guard let id=anchor.membershipPairingID else {throw OSwindError.unavailable("Original membership pairing account is missing")}
                let lease=try SyncCredentialExclusiveLease(id:id,stateRoot:environment.stateRoot)
                do {try anchor.validateMembershipPreparation();return Self(library:library,anchor:anchor,pairing:nil,pairingLease:lease)}
                catch {lease.close();throw error}
            }catch {anchor.close();throw error}
        }catch {try? library.close();throw error}
    }
    private init(library:MemoryStore,anchor:SyncDeliveryAnchor,pairing:PersonalSyncPairing?,pairingLease:SyncCredentialExclusiveLease?) {self.library=library;self.anchor=anchor;self.pairing=pairing;self.pairingLease=pairingLease}
    func resumeFence()throws {
        lock.lock();defer {lock.unlock()};guard !closed else {throw OSwindError.unavailable("Membership preparation owner is closed")}
        try anchor.continueMembershipFence()
    }
    func cancelBeforeHandover()throws {
        lock.lock();defer {lock.unlock()};guard !closed else {throw OSwindError.unavailable("Membership preparation owner is closed")}
        try anchor.cancelMembershipBeforeHandover()
    }
    func close()throws {
        lock.lock();defer {lock.unlock()};guard !closed else {return}
        anchor.close();pairing?.close();pairingLease?.close();try library.close();closed=true
    }
    deinit {anchor.close();pairing?.close();pairingLease?.close();try? library.close()}
}
