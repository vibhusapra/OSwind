import Foundation

/// A synchronous publication barrier shared by active and finalizing chunks.
/// Invalidating it waits for a commit already in progress and prevents any new
/// media files or rows appearing after privacy changes, erasure or library switch.
final class ReplayCommitGate:@unchecked Sendable {
    private let lock=NSLock()
    private var valid=true
    func invalidate() {lock.lock();valid=false;lock.unlock()}
    func commit<T>(_ body:() throws -> T) throws -> T {
        lock.lock();defer {lock.unlock()}
        guard valid else {throw CancellationError()};return try body()
    }
}
