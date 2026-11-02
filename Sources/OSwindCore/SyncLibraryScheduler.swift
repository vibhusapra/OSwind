import Foundation

enum SyncLibrarySchedulerState:Equatable,Sendable {
    case ready,running(SyncLibraryServiceStep?),stopped
    case waitingForLocalReview(SyncCollectionControl)
    case waitingForNativeRetirement(SyncCollectionControl)
    case retryingPolicy, retryingDelivery, failed
}

struct SyncLibrarySchedule:Sendable {
    var activeSeconds:Double=0.25,idleSeconds:Double=15,retrySeconds:Double=30
    func delay(_ step:SyncLibraryServiceStep,lowPower:Bool,thermalLimited:Bool)->Double {
        let base:Double
        switch step {
        case .preparing:base=activeSeconds
        case .transferred(let sent,let received,_):base=sent+received>0 ? activeSeconds:idleSeconds
        case .needsGroupReview,.needsNativeCollectionRetirement:base=idleSeconds
        }
        return base*(thermalLimited ? 8:lowPower ? 4:1)
    }
    func validate()throws {
        guard [activeSeconds,idleSeconds,retrySeconds].allSatisfy({$0.isFinite && $0>=0.001 && $0<=3600}) else {throw OSwindError.invalid("Invalid sync scheduling bounds")}
    }
}

/// The UI observes state; no callback runs on the worker or can join itself.
/// Group retirement stops polling and yields to the app's destructive lifecycle
/// owner. This actor owns only sync, not capture/import/model producers.
actor SyncLibraryScheduler {
    private let service:SyncLibraryService
    private let schedule:SyncLibrarySchedule
    private var task:Task<Void,Never>?
    private var finished=false
    private(set) var state:SyncLibrarySchedulerState = .ready
    init(service:SyncLibraryService,schedule:SyncLibrarySchedule=SyncLibrarySchedule())throws {
        try schedule.validate();self.service=service;self.schedule=schedule
    }
    deinit {task?.cancel()}
    func start()throws {
        guard task==nil,!finished else {throw OSwindError.invalid("Create a fresh sync scheduler after stopping or replacing its owner")}
        state = .running(nil)
        let service=service,schedule=schedule
        task=Task.detached(priority:.utility) {[weak self] in
            while !Task.isCancelled {
                let delay:Double
                do {
                    let step=try service.tick()
                    switch step {
                    case .needsGroupReview(let control):await self?.publish(.waitingForLocalReview(control));return
                    case .needsNativeCollectionRetirement(let control):await self?.publish(.waitingForNativeRetirement(control));return
                    default:await self?.publish(.running(step))
                    }
                    let process=ProcessInfo.processInfo
                    delay=schedule.delay(step,lowPower:process.isLowPowerModeEnabled,thermalLimited:process.thermalState == .serious || process.thermalState == .critical)
                } catch is CancellationError {break}
                catch is SyncPublicationPolicyDenied {await self?.publish(.retryingPolicy);delay=schedule.retrySeconds}
                catch OSwindError.unavailable {await self?.publish(.retryingDelivery);delay=schedule.retrySeconds}
                catch {await self?.publish(.failed);return}
                do {try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))}catch {break}
            }
        }
    }
    private func publish(_ value:SyncLibrarySchedulerState) {if !finished {state=value}}
    func stop()async throws {
        // Publish terminal ownership before awaiting: start cannot race a new
        // worker into the actor during cancellation/join of the prior one.
        finished=true
        let worker=task;task=nil;worker?.cancel();await worker?.value
        try await Task.detached(priority:.utility) {try self.service.stop()}.value
        state = .stopped
    }
}
