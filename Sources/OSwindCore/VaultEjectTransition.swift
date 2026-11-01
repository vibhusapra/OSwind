import Foundation

/// Closing policy independent of native IPC, so failure/observation interleavings
/// can be tested without changing the real driver's kernel identity checks.
/// Native exit status never replaces fresh attachment observations. Mutations
/// remain normal detaches, with bounded recovery for explicit busy exits and
/// the existing moved-mount fallback. No force or blind mutation retry.
enum VaultEjectTransition {
    static func run(verified:VaultVolumeProof,
                    expectedImage:@escaping @Sendable () throws ->URL,
                    validate:@escaping @Sendable () throws ->Void,
                    observe:@escaping @Sendable () async throws ->VaultVolumeProof?,
                    detach:@escaping @Sendable (String,Int32?) async throws ->VaultProcessResult,
                    unmount:@escaping @Sendable (URL,Int32?) async throws ->VaultProcessResult,
                    attempts:Int=16,
                    busyRetries:Int=2,
                    busyPause:@escaping @Sendable (Int) async throws ->Void={try await Task.sleep(for:.milliseconds($0 == 0 ? 150:400))},
                    pause:@escaping @Sendable (Int) async throws ->Void={try await Task.sleep(for:.milliseconds(VaultDetachSettlement.delayMilliseconds($0)))}) async throws {
        guard (2...16).contains(attempts) else {throw OSwindError.invalid("Invalid native detach confirmation budget")}
        guard (0...2).contains(busyRetries) else {throw OSwindError.invalid("Invalid native busy recovery budget")}
        try Task.checkCancellation();try validate()
        let confirmDetached:@Sendable () async throws ->Void = {
            try await VaultDetachSettlement.confirm(attempts:attempts,pause:pause) {
                try validate();let observed=try await observe();try validate()
                guard let observed else {return true}
                guard verified.sameIdentity(as:observed,allowUnmounted:true) else {throw OSwindError.invalid("The attachment changed during detach verification")}
                return false
            }
        }
        let afterFailure:@Sendable () async throws ->VaultVolumeProof? = {
            try await VaultDetachSettlement.inspectAfterFailure(expected:verified,validate:validate,inspect:observe)
        }
        let first=try await detach(verified.attachmentDevice,verified.root?.device)
        if !first.succeeded,let current=try await afterFailure() {
            let actual=try expectedImage().standardizedFileURL.resolvingSymlinksInPath()
            let moved=verified.mounted && current.mounted &&
                  URL(fileURLWithPath:verified.reportedImagePath).standardizedFileURL.resolvingSymlinksInPath() != actual
            let same=verified.sameIdentity(as:current)
            if !moved || !same {
                var failed=first
                for retry in 0..<busyRetries {
                    // Only the observed normal exit 16 is eligible. Signals,
                    // unknown termination and other exits never broaden policy.
                    guard failed.termination == .exit,failed.status == 16,
                          verified.mounted,current.mounted,same else {throw VaultNativeFailure(operation:.imageDetach,result:failed)}
                    try await busyPause(retry)
                    try Task.checkCancellation();try validate()
                    guard let fresh=try await afterFailure() else {try await confirmDetached();return}
                    guard verified.sameIdentity(as:fresh),fresh.mounted else {throw OSwindError.invalid("The attachment changed before busy recovery")}
                    try Task.checkCancellation();try validate()
                    let result=try await detach(fresh.attachmentDevice,fresh.root?.device)
                    if result.succeeded {try await confirmDetached();return}
                    failed=result
                    if try await afterFailure()==nil {try await confirmDetached();return}
                }
                throw VaultNativeFailure(operation:.imageDetach,result:failed)
            }
            try validate()
            let result=try await unmount(current.mount,current.root?.device)
            if !result.succeeded {
                if try await afterFailure()==nil {try await confirmDetached();return}
                throw VaultNativeFailure(operation:.filesystemUnmount,result:result)
            }
            try validate();let unmounted=try await observe();try validate()
            guard let unmounted else {try await confirmDetached();return}
            guard !unmounted.mounted,verified.sameIdentity(as:unmounted,allowUnmounted:true) else {throw OSwindError.invalid("The unmounted attachment changed. Its remaining device was preserved.")}
            let final=try await detach(unmounted.attachmentDevice,verified.root?.device)
            if !final.succeeded {
                if try await afterFailure() != nil {throw VaultNativeFailure(operation:.imageDetach,result:final)}
            }
        }
        try await confirmDetached()
    }
}
