import Foundation

public enum ClipboardReadFailure:Error,LocalizedError {
    case occupied,timedOut
    public var errorDescription:String? {switch self {case .occupied:return "The previous clipboard provider is still responding";case .timedOut:return "The clipboard provider did not respond before the deadline"}}
}

private final class ClipboardReadReply<T:Sendable>:@unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<T,Error>?
    private var early:Result<T,Error>?
    private var finished=false
    var pending:Bool {lock.lock();defer {lock.unlock()};return !finished}
    func install(_ value:CheckedContinuation<T,Error>)->Bool {
        lock.lock()
        if finished {let result=early!;early=nil;lock.unlock();value.resume(with:result);return false}
        continuation=value;lock.unlock();return true
    }
    func finish(_ result:Result<T,Error>) {
        lock.lock();guard !finished else {lock.unlock();return};finished=true
        if let value=continuation {continuation=nil;lock.unlock();value.resume(with:result)}else {early=result;lock.unlock()}
    }
}

/// One global native reader prevents a hung pasteboard owner from creating a
/// thread per poll. Cancellation/deadline releases only the waiter; the worker
/// slot remains occupied until the actual provider call returns. Native
/// operations must not capture a library, admission lease or model callback.
public final class ClipboardReadWorker:@unchecked Sendable {
    public static let shared=ClipboardReadWorker()
    private let lock=NSLock()
    private var busy=false
    typealias DeadlineScheduler = @Sendable (TimeInterval,@escaping @Sendable ()->Void)->Void
    private let schedule:DeadlineScheduler
    public init() {schedule={delay,callback in DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+delay,execute:callback)}}
    init(schedule:@escaping DeadlineScheduler){self.schedule=schedule}
    public var occupied:Bool {lock.lock();defer {lock.unlock()};return busy}
    private func claim()->Bool {lock.lock();defer {lock.unlock()};guard !busy else {return false};busy=true;return true}
    private func release(){lock.lock();busy=false;lock.unlock()}
    public func read<T:Sendable>(timeout:TimeInterval=2,operation:@escaping @Sendable ()throws->T)async throws->T {
        guard timeout.isFinite,timeout>0,timeout<=2 else {throw OSwindError.invalid("Invalid clipboard deadline")}
        try Task.checkCancellation();guard claim() else {throw ClipboardReadFailure.occupied}
        let reply=ClipboardReadReply<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {continuation in
                guard reply.install(continuation) else {release();return}
                DispatchQueue.global(qos:.utility).async { [self] in
                    guard reply.pending else {release();return}
                    let result=Result {try operation()};release();reply.finish(result)
                }
                schedule(timeout) {reply.finish(.failure(ClipboardReadFailure.timedOut))}
            }
        } onCancel:{reply.finish(.failure(CancellationError()))}
    }
}
