import Foundation

/// Once attach starts, acquire its complete verified proof independently of the
/// caller's cancellation. A cancelled caller may return only after cleanup of
/// that exact proof completes; cleanup failures stay visible for recovery.
enum VaultAttachCompletion {
    static func run<Proof:Sendable>(action:@escaping @Sendable () async throws -> Proof,
                                    cancelled:@escaping @Sendable (Proof) async throws -> Void) async throws -> Proof {
        try Task.checkCancellation()
        let work=Task.detached(priority:.utility,operation:action)
        let proof=try await work.value
        if Task.isCancelled {
            let cleanup=Task.detached(priority:.utility) {try await cancelled(proof)}
            try await cleanup.value
            throw CancellationError()
        }
        return proof
    }
}
