import Foundation

/// App-facing progress contains no keys, native records or protocol authority.
public struct PersonalSyncStatus:Equatable,Sendable {
    public enum Phase:Equatable,Sendable {case ready,preparing,working,upToDate,networkPaused,suspended,needsLocalEraseReview,needsReceivedErase,waitingForPolicy,waitingForDelivery,waitingForStorage,stopping,stopped,failed}
    public let phase:Phase
    public let sent:Int,received:Int,pending:Int,withheld:Int
    init(_ state:SyncLibrarySchedulerState) {
        var sent=0,received=0,pending=0,withheld=0
        let phase:Phase
        switch state {
        case .ready:phase = .ready
        case .suspended:phase = .suspended
        case .stopping:phase = .stopping
        case .stopped:phase = .stopped
        case .failed:phase = .failed
        case .retryingPolicy:phase = .waitingForPolicy
        case .retryingDelivery:phase = .waitingForDelivery
        case .retryingStorage:phase = .waitingForStorage
        case .waitingForLocalReview:phase = .needsLocalEraseReview
        case .waitingForNativeRetirement:phase = .needsReceivedErase
        case .running(let step):
            switch step {
            case .none:phase = .working
            case .preparing,.reviewingPolicy:phase = .preparing
            case .waitingForPolicy(let count):phase = .waitingForPolicy;withheld=count
            case .networkPaused(let count):phase = .networkPaused;withheld=count
            case .needsGroupReview:phase = .needsLocalEraseReview
            case .needsNativeCollectionRetirement:phase = .needsReceivedErase
            case .transferred(let a,let b,let c):sent=a;received=b;pending=c;phase = a+b+c==0 ? .upToDate:.working
            }
        }
        self.phase=phase;self.sent=sent;self.received=received;self.pending=pending;self.withheld=withheld
    }
}

/// The app can own an enrolled session without receiving wire types or keys.
/// Construction remains internal until enrollment/capability/rollback authority
/// is delivered. Accepting a prepared session never grants membership itself.
public actor PersonalSyncSession {
    private nonisolated let library:MemoryStore
    private let privateInbox:SyncObjectFolder
    private let scheduler:SyncLibraryScheduler
    private var closed=false
    init(service:SyncLibraryService,schedule:SyncLibrarySchedule = .init())throws {
        library=service.library;privateInbox=service.inbox;scheduler=try SyncLibraryScheduler(service:service,schedule:schedule)
    }
    public nonisolated func belongs(to store:MemoryStore)->Bool {library === store}
    public func setProcessingEnabled(_ enabled:Bool)async throws {
        guard !closed else {throw OSwindError.unavailable("This sync session is stopped")}
        if enabled {try await scheduler.resumeProcessing()}else{await scheduler.pauseProcessing()}
    }
    public func setNetworkEnabled(_ enabled:Bool)async throws {
        guard !closed else {throw OSwindError.unavailable("This sync session is stopped")}
        try await scheduler.setNetworkEnabled(enabled)
    }
    public func stop()async throws {
        closed=true
        // The private spool is inside the native vault. Its retained directory
        // descriptor must be released before the owner unmounts that vault.
        defer {privateInbox.close()}
        try await scheduler.stop()
    }
    public func status()async->PersonalSyncStatus {PersonalSyncStatus(await scheduler.state)}
    /// A bounded push stream replaces UI polling without another worker task.
    /// Cancelling the consumer removes its scheduler subscription.
    public func updates()async->AsyncStream<PersonalSyncStatus> {
        await scheduler.updates {PersonalSyncStatus($0)}
    }
}
