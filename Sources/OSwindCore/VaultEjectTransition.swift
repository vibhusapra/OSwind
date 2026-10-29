import Foundation

/// Closing policy independent of native IPC, so failure/observation interleavings
/// can be tested without changing the real driver's kernel identity checks.
/// Native exit status never replaces fresh attachment observations. Mutations
/// remain one normal detach, with the existing moved-mount fallback only.
enum VaultEjectTransition {
    static func run(verified:VaultVolumeProof,
                    expectedImage:@escaping @Sendable () throws ->URL,
                    validate:@escaping @Sendable () throws ->Void,
                    observe:@escaping @Sendable () async throws ->VaultVolumeProof?,
                    detach:@escaping @Sendable (String,Int32?) async throws ->VaultProcessResult,
                    unmount:@escaping @Sendable (URL,Int32?) async throws ->VaultProcessResult,
                    attempts:Int=16,
                    pause:@escaping @Sendable (Int) async throws ->Void={try await Task.sleep(for:.milliseconds(VaultDetachSettlement.delayMilliseconds($0)))}) async throws {
        guard (2...16).contains(attempts) else {throw OSwindError.invalid("Invalid native detach confirmation budget")}
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
            guard verified.mounted,current.mounted,
                  URL(fileURLWithPath:verified.reportedImagePath).standardizedFileURL.resolvingSymlinksInPath() != actual,
                  verified.sameIdentity(as:current) else {throw VaultNativeFailure(operation:.imageDetach,result:first)}
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
