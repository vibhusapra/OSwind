import Foundation

/// Internal existing-library migration; no public UI or provider access.
/// Caller transfers a stopped, producer-drained store only on success.
final class SyncMembershipFloorOwner:@unchecked Sendable {
    private let lock=NSRecursiveLock(),library:MemoryStore,anchor:SyncDeliveryAnchor
    private let pairing:PersonalSyncPairing?,pairingLease:SyncCredentialExclusiveLease?
    let requiresUpgrade:Bool
    private var closed=false,completed=false
    static func prepare(root:URL,environment:SyncNativeWriterEnvironment = .native)throws->Self {
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("memory.sqlite").path) else {throw OSwindError.invalid("Select the existing enrolled native library")}
        let library=try MemoryStore(root:root,recoveryReadOnly:false,nativeWriterEnvironment:environment)
        do {return try prepare(library:library,environment:environment)}catch {try? library.close();throw error}
    }
    static func prepare(library:MemoryStore,environment:SyncNativeWriterEnvironment,checkBeforeIntent:()throws->Void={try Task.checkCancellation()})throws->Self {
        let pairing=try PersonalSyncPairing.openMembershipPairing(library:library,environment:environment)
        do {
            let (anchor,snapshot)=try pairing.openMembershipFloorAnchor()
            do {
                let needed=try anchor.prepareMembershipFloor(snapshot:snapshot,checkBeforeIntent:checkBeforeIntent)
                return Self(library:library,anchor:anchor,pairing:pairing,pairingLease:nil,requiresUpgrade:needed)
            }catch {anchor.close();throw error}
        }catch {pairing.close();throw error}
    }
    static func open(root:URL,environment:SyncNativeWriterEnvironment = .native)throws->Self {
        let library=try MemoryStore(root:root,recoveryReadOnly:false,nativeWriterEnvironment:environment,membershipFloorRecovery:true)
        do {
            let anchor=try SyncDeliveryAnchor.openMembershipFloorPreparation(library:library,environment:environment)
            do {
                guard let id=anchor.membershipFloorPairingID else {throw OSwindError.unavailable("Original floor pairing account is missing")}
                let lease=try SyncCredentialExclusiveLease(id:id,stateRoot:environment.stateRoot)
                do {try anchor.validateMembershipFloorPreparation();return Self(library:library,anchor:anchor,pairing:nil,pairingLease:lease,requiresUpgrade:true)}catch {lease.close();throw error}
            }catch {anchor.close();throw error}
        }catch {try? library.close();throw error}
    }
    /// Transfers the stopped/drained store for the whole async operation.
    /// Cancellation is checked before intent; an uncancelled worker is always
    /// joined through completion and close, including ambiguous failure paths.
    static func upgrade(library:MemoryStore,environment:SyncNativeWriterEnvironment)async throws->Bool {
        let cancellation=CancellationGate()
        let worker=Task.detached(priority:.utility) {()throws->Bool in
            do {
                let owner=try prepare(library:library,environment:environment,checkBeforeIntent:{try cancellation.check()})
                do {try owner.complete();try owner.close();return owner.requiresUpgrade}
                catch {try? owner.close();throw error}
            }catch {try? library.close();throw error}
        }
        return try await withTaskCancellationHandler(operation:{
            if Task.isCancelled {cancellation.cancel()}
            return try await worker.value
        },onCancel:{cancellation.cancel()})
    }
    private final class CancellationGate:@unchecked Sendable {
        private let lock=NSLock();private var cancelled=false
        func cancel() {lock.lock();cancelled=true;lock.unlock()}
        func check()throws {lock.lock();let value=cancelled;lock.unlock();if value {throw CancellationError()}}
    }
    private init(library:MemoryStore,anchor:SyncDeliveryAnchor,pairing:PersonalSyncPairing?,pairingLease:SyncCredentialExclusiveLease?,requiresUpgrade:Bool) {self.library=library;self.anchor=anchor;self.pairing=pairing;self.pairingLease=pairingLease;self.requiresUpgrade=requiresUpgrade}
    func complete()throws {
        lock.lock();defer {lock.unlock()};guard !closed else {throw OSwindError.unavailable("Membership floor owner is closed")}
        if completed || !requiresUpgrade {return}
        try anchor.completeMembershipFloor {
            guard let id=self.anchor.membershipFloorPairingID else {throw OSwindError.unavailable("Original floor pairing account is missing")}
            if let pairing=self.pairing {try pairing.requireMembershipLease(id:id)}
            else {guard let lease=self.pairingLease else {throw OSwindError.unavailable("Original floor pairing lease is missing")};try lease.requireCurrentIdentity()}
        }
        completed=true
    }
    func close()throws {
        lock.lock();defer {lock.unlock()};guard !closed else {return}
        anchor.close();pairing?.close();pairingLease?.close();try library.close();closed=true
    }
    deinit {anchor.close();pairing?.close();pairingLease?.close();try? library.close()}
}
