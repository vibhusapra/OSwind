import SwiftUI
import OSwindCore

/// One supervisor owns the actual attempt and every backoff sleeper. An idle
/// library has observers but no repeating timer or database probe.
@MainActor final class PendingMediaCleanupModel:ObservableObject {
    @Published private(set) var status=""
    @Published private(set) var busy=false
    @Published private(set) var lastDisposition:PendingMediaCleanupDisposition?
    private(set) var attempts=0
    private(set) var active=false
    private var knownPending=false,attention=false,wakeRequested=false
    private var rateLimited=false
    private var observationFailed=false
    private var lastAttemptStarted:ContinuousClock.Instant?
    private let minimumAttemptSpacing:Duration = .milliseconds(250)
    private(set) var wipePending=false
    var needsAttention:Bool {attention}
    var canRetry:Bool {active || observationFailed}
    private var generation=UUID(),drainers=0
    private let store:MemoryStore,delays:[Duration]
    private let beforeAttempt:(@Sendable ()throws->Void)?,afterAttempt:(@Sendable ()->Void)?
    private let onFinished:()->Void,onWipeState:(Bool)->Void
    private var observation:PendingMediaCleanupObservation?
    private var supervisor:Task<Void,Never>?,sleeper:Task<Void,Never>?
    private var worker:Task<PendingMediaCleanupAttempt,Error>?
    var hasPendingWork:Bool {supervisor != nil || worker != nil || sleeper != nil}
    init(store:MemoryStore,delays:[Duration]=[.milliseconds(250),.seconds(1),.seconds(4),.seconds(15),.seconds(30)],beforeAttempt:(@Sendable ()throws->Void)?=nil,afterAttempt:(@Sendable ()->Void)?=nil,onFinished:@escaping ()->Void={},onWipeState:@escaping (Bool)->Void={_ in}) {
        self.store=store;self.delays=delays.isEmpty ? [.seconds(30)]:delays;self.beforeAttempt=beforeAttempt;self.afterAttempt=afterAttempt;self.onFinished=onFinished;self.onWipeState=onWipeState
    }
    func start() {
        guard !active,drainers==0,!store.isClosed else {return}
        active=true;generation=UUID();knownPending=false;attention=false;wipePending=false;observationFailed=false;lastAttemptStarted=nil;lastDisposition=nil
        let current=generation
        do {observation=try store.observePendingMediaCleanup {[weak self] event in Task {@MainActor in guard let self,self.generation==current else {return};self.hint(event)}}}
        catch {active=false;attention=true;observationFailed=true;status="Deferred media cleanup needs attention: "+error.localizedDescription;return}
        request()
    }
    func resume() {
        guard active || observationFailed,drainers==0,!store.isClosed else {return}
        if observationFailed {start();return}
        guard active else {return};attention=false;wipePending=false;request()
    }
    private func hint(_ event:PendingMediaCleanupEvent) {
        guard active,!attention || (wipePending && event == .pending) else {return}
        switch event {
        case .pending:guard !knownPending else {return};knownPending=true
        case .writerReleased:guard knownPending else {return}
        }
        request()
    }
    private func request() {
        guard active,drainers==0,!store.isClosed else {return}
        wakeRequested=true
        if supervisor != nil {if !rateLimited {sleeper?.cancel()};return}
        let current=generation,store=self.store,before=beforeAttempt,after=afterAttempt
        busy=true
        supervisor=Task {
            var backoff=0
            defer {
                worker=nil;sleeper=nil;supervisor=nil;busy=false;rateLimited=false
                // A temporary stop/start may arrive while the previous worker
                // is still draining. No new worker can overlap that old one.
                if active,current != generation,wakeRequested,drainers==0 {request()}
            }
            while active,current==generation,!Task.isCancelled {
                if let lastAttemptStarted {
                    let notBefore=lastAttemptStarted.advanced(by:minimumAttemptSpacing)
                    if ContinuousClock.now<notBefore {await pause(for:ContinuousClock.now.duration(to:notBefore),rateLimit:true);continue}
                }
                wakeRequested=false
                do {
                    try Task.checkCancellation()
                    let owned=Task.detached(priority:.utility) {try before?();try Task.checkCancellation();let value=try store.resumePendingMediaCleanup();after?();return value}
                    worker=owned;attempts+=1;lastAttemptStarted = .now
                    let result=try await withTaskCancellationHandler {try await owned.value} onCancel:{owned.cancel()}
                    worker=nil
                    guard active,current==generation,!Task.isCancelled else {return}
                    lastDisposition=result.disposition
                    switch result.disposition {
                    case .idle,.finished:
                        knownPending=false;attention=false;wipePending=false;status="";onWipeState(false)
                        if result.disposition == .finished {status="Committed media cleanup completed.";onFinished()}
                        if wakeRequested {continue};return
                    case .libraryWipe:
                        knownPending=false;attention=true;wipePending=true;status="Finish the earlier library cleanup using Retry library cleanup.";onWipeState(true);return
                    case .needsAttention:
                        knownPending=true;attention=true;wipePending=false;onWipeState(false)
                        status="Committed media cleanup needs attention. "+(result.result?.warnings.joined(separator:" ") ?? "Retry cleanup in this library.");return
                    case .waitingForWriters:
                        knownPending=true;attention=false;wipePending=false;onWipeState(false);status="Committed media cleanup is waiting for active media work."
                        if wakeRequested {continue}
                        let interval=delays[min(backoff,delays.count-1)];backoff=min(backoff+1,delays.count-1)
                        await pause(for:interval)
                    }
                } catch is CancellationError {return}
                catch {
                    guard active,current==generation,!Task.isCancelled else {return}
                    attention=true;status="Deferred media cleanup needs attention: "+error.localizedDescription;return
                }
            }
        }
    }
    private func pause(for interval:Duration,rateLimit:Bool=false)async {
        rateLimited=rateLimit
        let pause=Task<Void,Never> {do {try await Task.sleep(for:interval)}catch {}}
        sleeper=pause
        await withTaskCancellationHandler {await pause.value} onCancel:{pause.cancel()}
        sleeper=nil;rateLimited=false
    }
    func stop() {
        active=false;generation=UUID();wakeRequested=false;knownPending=false;attention=false;wipePending=false;observationFailed=false;lastDisposition=nil
        observation?.cancel();observation=nil;worker?.cancel();sleeper?.cancel();supervisor?.cancel()
    }
    func cancelAndWait()async {
        drainers+=1;defer {drainers-=1}
        let pending=supervisor,attempt=worker,delay=sleeper
        stop()
        if let attempt {_ = try? await attempt.value}
        if let delay {await delay.value}
        if let pending {await pending.value}
    }
}

struct PendingMediaCleanupStatusView:View {
    @ObservedObject var model:PendingMediaCleanupModel
    var body:some View {
        if model.lastDisposition == .waitingForWriters || model.needsAttention {
            VStack(alignment:.leading,spacing:8) {
                Label("Deleted files",systemImage:model.needsAttention ? "exclamationmark.circle":"hourglass").font(.headline)
                Text(model.needsAttention ? model.status:"Files from earlier deletions are still in use. Cleanup will resume automatically.").font(.caption).textSelection(.enabled)
                if model.needsAttention && !model.wipePending {Button("Retry file cleanup") {model.resume()}.disabled(!model.canRetry || model.busy)}
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
        }
    }
}
