import Foundation

enum SyncLibrarySchedulerState:Equatable,Sendable {
    case ready,running(SyncLibraryServiceStep?),suspended,stopping,stopped
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
    private var stoppingTask:Task<Void,Error>?
    private var finished=false
    private var reconfiguring=false
    private var retirementReserved=false
    private var processingPaused=false,pausing=false
    private var networkEnabled=true
    private var generation=UUID()
    private struct Observer:Sendable {
        let yield:@Sendable (SyncLibrarySchedulerState)->Void
        let finish:@Sendable ()->Void
    }
    private var observers=[UUID:Observer]()
    private(set) var state:SyncLibrarySchedulerState = .ready
    init(service:SyncLibraryService,schedule:SyncLibrarySchedule=SyncLibrarySchedule())throws {
        try schedule.validate();self.service=service;self.schedule=schedule
    }
    deinit {task?.cancel();for observer in observers.values {observer.finish()}}
    func updates<Value:Sendable>(_ transform:@escaping @Sendable (SyncLibrarySchedulerState)->Value)->AsyncStream<Value> {
        let id=UUID()
        return AsyncStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            continuation.yield(transform(state))
            if finished,state != .stopping {continuation.finish();return}
            observers[id]=Observer(yield:{continuation.yield(transform($0))},finish:{continuation.finish()})
            continuation.onTermination={ [weak self] _ in Task {await self?.removeObserver(id)} }
        }
    }
    private func removeObserver(_ id:UUID) {observers[id]=nil}
    private func update(_ value:SyncLibrarySchedulerState) {
        guard value != state else {return};state=value
        for observer in observers.values {observer.yield(value)}
    }
    func start(networkEnabled:Bool?=nil)throws {
        guard task==nil,!finished,!retirementReserved,!reconfiguring,!processingPaused,!pausing else {throw OSwindError.invalid("Create a fresh sync scheduler after stopping or replacing its owner")}
        if let networkEnabled {self.networkEnabled=networkEnabled}
        launch()
    }
    private func launch() {
        update(.running(nil))
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
    private func publish(_ value:SyncLibrarySchedulerState,scope:UUID) {if !finished,generation==scope {update(value)}}
    /// Sleep/onboarding suspension stops all processing, not just provider I/O.
    /// Keep the worker registered until it has actually joined, including when
    /// a concurrent reconfiguration or terminal stop is joining the same task.
    func pauseProcessing()async {
        guard !finished else {return}
        processingPaused=true
        if pausing {let worker=task;await worker?.value;return}
        pausing=true;defer {pausing=false}
        generation=UUID();let worker=task;worker?.cancel();await worker?.value
        guard !finished else {return}
        task=nil
        switch state {case .waitingForLocalReview,.waitingForNativeRetirement:break;default:update(.suspended)}
    }
    /// Join the actual scheduler worker without closing its credential owner.
    /// Reservation is terminal: only the retirement owner or stop may proceed.
    func reserveForRetirement()async throws->SyncLibrarySchedulerState {
        guard !finished,!retirementReserved,!reconfiguring,!pausing else {throw OSwindError.unavailable("Sync is stopping or changing; reopen before retiring history")}
        retirementReserved=true
        await pauseProcessing()
        guard !finished else {throw OSwindError.unavailable("Sync stopped before retirement began")}
        return state
    }
    func resolveLocalReview(_ control:SyncCollectionControl)throws {
        guard !finished,!retirementReserved,!reconfiguring,!pausing,processingPaused,task==nil,
              case .waitingForLocalReview(let current)=state,current==control else {throw OSwindError.unavailable("The local erase changed while its review was saving")}
        update(.suspended)
    }
    func resumeProcessing()throws {
        guard !finished,!retirementReserved,!reconfiguring,!pausing else {throw OSwindError.unavailable("Sync scheduling is stopping or changing")}
        processingPaused=false
        switch state {case .waitingForLocalReview,.waitingForNativeRetirement:return;default:break}
        if task==nil {launch()}
    }
    /// Pause/resume acknowledges the joined old network worker. A replacement
    /// continues local preparation; no old task may publish a late UI state.
    func setNetworkEnabled(_ enabled:Bool)async throws {
        guard !finished,!retirementReserved,!reconfiguring else {throw OSwindError.unavailable("Sync scheduling is stopping or changing")}
        guard enabled != networkEnabled else {return}
        networkEnabled=enabled
        if processingPaused {return}
        switch state {case .waitingForLocalReview,.waitingForNativeRetirement:return;default:break}
        guard let worker=task else {return}
        reconfiguring=true;defer {reconfiguring=false}
        // Retain ownership across the actor suspension: a concurrent stop must
        // join this same worker before its library can be closed or replaced.
        generation=UUID();worker.cancel();await worker.value
        guard !finished,!processingPaused else {return}
        launch()
    }
    func stop()async throws {
        // Every overlapping stop joins the same actual worker and metadata
        // close. No caller may mistake a cleared task slot for completed work.
        let closing:Task<Void,Error>
        if let existing=stoppingTask {closing=existing}
        else {
            finished=true;generation=UUID();update(.stopping)
            let worker=task,service=service;worker?.cancel()
            closing=Task.detached(priority:.utility) {await worker?.value;try service.stop()}
            stoppingTask=closing
        }
        do {try await closing.value;task=nil;update(.stopped)}
        catch {task=nil;update(.failed);for observer in observers.values {observer.finish()};observers.removeAll();throw error}
        for observer in observers.values {observer.finish()};observers.removeAll()
    }
}
