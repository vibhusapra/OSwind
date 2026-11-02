import Foundation

enum SyncLibrarySchedulerState:Equatable,Sendable {
    case ready,running(SyncLibraryServiceStep?),stopped
    case waitingForLocalReview(SyncCollectionControl)
    case waitingForNativeRetirement(SyncCollectionControl)
    case retryingPolicy, retryingDelivery, retryingStorage, failed
}

struct SyncLibrarySchedule:Sendable {
    var activeSeconds:Double=0.25,idleSeconds:Double=15,retrySeconds:Double=30
    func delay(_ step:SyncLibraryServiceStep,lowPower:Bool,thermalLimited:Bool)->Double {
        let base:Double
        switch step {
        case .preparing,.reviewingPolicy:base=activeSeconds
        case .transferred(let sent,let received,_):base=sent+received>0 ? activeSeconds:idleSeconds
        case .needsGroupReview,.needsNativeCollectionRetirement,.waitingForPolicy,.networkPaused:base=idleSeconds
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
    private var reconfiguring=false
    private var networkEnabled=true
    private var generation=UUID()
    private(set) var state:SyncLibrarySchedulerState = .ready
    init(service:SyncLibraryService,schedule:SyncLibrarySchedule=SyncLibrarySchedule())throws {
        try schedule.validate();self.service=service;self.schedule=schedule
    }
    deinit {task?.cancel()}
    func start(networkEnabled:Bool?=nil)throws {
        guard task==nil,!finished,!reconfiguring else {throw OSwindError.invalid("Create a fresh sync scheduler after stopping or replacing its owner")}
        if let networkEnabled {self.networkEnabled=networkEnabled}
        launch()
    }
    private func launch() {
        state = .running(nil)
        let service=service,schedule=schedule,enabled=networkEnabled,scope=UUID();generation=scope
        task=Task.detached(priority:.utility) {[weak self] in
            while !Task.isCancelled {
                let delay:Double
                do {
                    let step=try service.tick(networkEnabled:enabled)
                    switch step {
                    case .needsGroupReview(let control):await self?.publish(.waitingForLocalReview(control),scope:scope);return
                    case .needsNativeCollectionRetirement(let control):await self?.publish(.waitingForNativeRetirement(control),scope:scope);return
                    default:await self?.publish(.running(step),scope:scope)
                    }
                    let process=ProcessInfo.processInfo
                    delay=schedule.delay(step,lowPower:process.isLowPowerModeEnabled,thermalLimited:process.thermalState == .serious || process.thermalState == .critical)
                } catch is CancellationError {break}
                catch is SyncPublicationPolicyDenied {await self?.publish(.retryingPolicy,scope:scope);delay=schedule.retrySeconds}
                catch let error where SyncWithheldWork.isNativeHold(error) {await self?.publish(.retryingPolicy,scope:scope);delay=schedule.retrySeconds}
                catch let error where SyncWithheldWork.isMetadataFull(error) {await self?.publish(.retryingStorage,scope:scope);delay=schedule.retrySeconds}
                catch OSwindError.unavailable {await self?.publish(.retryingDelivery,scope:scope);delay=schedule.retrySeconds}
                catch {await self?.publish(.failed,scope:scope);return}
                do {try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))}catch {break}
            }
        }
    }
    private func publish(_ value:SyncLibrarySchedulerState,scope:UUID) {if !finished,generation==scope {state=value}}
    /// Pause/resume acknowledges the joined old network worker. A replacement
    /// continues local preparation; no old task may publish a late UI state.
    func setNetworkEnabled(_ enabled:Bool)async throws {
        guard !finished,!reconfiguring else {throw OSwindError.unavailable("Sync scheduling is stopping or changing")}
        guard enabled != networkEnabled else {return}
        networkEnabled=enabled
        switch state {case .waitingForLocalReview,.waitingForNativeRetirement:return;default:break}
        guard let worker=task else {return}
        reconfiguring=true;defer {reconfiguring=false}
        // Retain ownership across the actor suspension: a concurrent stop must
        // join this same worker before its library can be closed or replaced.
        generation=UUID();worker.cancel();await worker.value
        guard !finished else {return}
        launch()
    }
    func stop()async throws {
        // Publish terminal ownership before awaiting: start cannot race a new
        // worker into the actor during cancellation/join of the prior one.
        finished=true
        generation=UUID()
        let worker=task;task=nil;worker?.cancel();await worker?.value
        try await Task.detached(priority:.utility) {try self.service.stop()}.value
        state = .stopped
    }
}
