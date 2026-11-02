import Foundation

/// Tracks whole asynchronous producer operations, including canceled work that
/// has not returned yet. The caller invalidates its admission/generation first.
/// Child cleanup registers before its parent finishes, so a drain cannot lose
/// an outstanding device stop, encoder close or late preparation result.
@MainActor final class LibraryProducerTasks {
    private var active=Set<UUID>()
    private var waiters=[CheckedContinuation<Void,Never>]()
    private var drains=0
    var accepting:Bool {drains==0}
    func begin()->UUID {let id=UUID();active.insert(id);return id}
    func finish(_ id:UUID) {
        active.remove(id)
        if active.isEmpty {let completed=waiters;waiters=[];for continuation in completed {continuation.resume()}}
    }
    func drain()async {
        drains+=1;defer {drains-=1}
        if !active.isEmpty {await withCheckedContinuation {waiters.append($0)}}
    }
}
