import Foundation

/// Applies to OSwind's resident speech/speaker weights, not a shared Ollama
/// server or disk model cache. Idle starts only when the runtime queue is empty.
public enum NativeModelRetention:String,Codable,CaseIterable,Sendable {
    case afterUse,twoMinutes,tenMinutes,untilQuit
    public var title:String {
        switch self {
        case .afterUse:return "After each use"
        case .twoMinutes:return "After 2 idle minutes"
        case .tenMinutes:return "After 10 idle minutes"
        case .untilQuit:return "Until quit or manual release"
        }
    }
    var seconds:Double? {
        switch self {case .afterUse:return 0;case .twoMinutes:return 120;case .tenMinutes:return 600;case .untilQuit:return nil}
    }
}

/// Actor-owned timer. A generation check protects against an expired callback
/// already queued when new work invalidates it. Sleep injection is test-only.
struct NativeModelIdleTimer:Sendable {
    private var task:Task<Void,Never>?
    private(set) var generation=UUID()
    private let sleep:@Sendable (Double) async throws -> Void
    init(sleep:@escaping @Sendable (Double) async throws -> Void={try await Task.sleep(for:.seconds($0))}) {self.sleep=sleep}
    mutating func cancel() {generation=UUID();task?.cancel();task=nil}
    mutating func schedule(_ policy:NativeModelRetention,expire:@escaping @Sendable (UUID) async -> Void) {
        cancel();guard let seconds=policy.seconds else {return}
        let token=generation,sleep=self.sleep
        task=Task {
            do {try await sleep(seconds);try Task.checkCancellation();await expire(token)} catch {}
        }
    }
}
