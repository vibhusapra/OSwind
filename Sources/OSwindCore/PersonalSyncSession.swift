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
    private let service:SyncLibraryService
    private let pairing:PersonalSyncPairing?
    private let scheduler:SyncLibraryScheduler
    private var closed=false
    private var retirement:Task<LibraryWipeResult,Error>?
    private var stopping:Task<Void,Error>?
    init(service:SyncLibraryService,pairing:PersonalSyncPairing?=nil,schedule:SyncLibrarySchedule = .init())throws {
        guard pairing==nil || pairing!.belongs(to:service.library) else {throw OSwindError.invalid("Own pairing for the session's current library")}
        library=service.library;privateInbox=service.inbox;self.service=service;self.pairing=pairing;scheduler=try SyncLibraryScheduler(service:service,schedule:schedule)
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
        let closing:Task<Void,Error>
        if let stopping {closing=stopping}
        else {
            let pending=retirement,scheduler=scheduler,inbox=privateInbox,transport=service.transport,pairing=pairing
            pending?.cancel()
            closing=Task.detached(priority:.utility) {
                // Cancellation never acknowledges an unfinished native commit,
                // physical cleanup or external credential replacement.
                _=await pending?.result
                defer {inbox.close();transport.close();pairing?.close()}
                try await scheduler.stop()
            }
            stopping=closing
        }
        try await closing.value
    }
    /// Internal until the app supplies its joined producer and recovery paths.
    /// A terminal operation consumes this session; reconnect with a fresh owner
    /// after successful renewal. The caller must first join all other producers.
    func retireHistory(received:Bool,progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in})async throws->LibraryWipeResult {
        guard !closed,retirement==nil,let pairing else {throw OSwindError.unavailable("History retirement requires the enrolled session owner")}
        closed=true
        let service=service,scheduler=scheduler,inbox=privateInbox,transport=service.transport
        let worker=Task.detached(priority:.utility) {()throws->LibraryWipeResult in
            let outcome:Result<LibraryWipeResult,Error>
            do {
                let yielded=try await scheduler.reserveForRetirement()
                try Task.checkCancellation()
                let staged:SyncNativeRetirementResult
                if received {
                    guard case .waitingForNativeRetirement(let control)=yielded else {throw OSwindError.invalid("Apply only the peer erase yielded by this session")}
                    staged=try service.stageReceivedRetirement(control,progress:progress)
                }else {staged=try service.stageLocalRetirement(progress:progress)}
                let cleaned=try service.cleanupRetirement(progress:progress)
                if cleaned.cleanupComplete,!cleaned.cancelled {
                    if received {_=try service.completeReceivedRetirement(pairing:pairing)}
                    else {_=try service.completeLocalRetirement(pairing:pairing)}
                }
                let e=cleaned.erasure,c=staged.counts
                let erasure=HistoryErasureResult(sources:c.sources,conversationTurns:c.turns,removedMedia:e.removedMedia,sharedMedia:e.sharedMedia,pendingMedia:e.pendingMedia,searchCacheRemoved:e.searchCacheRemoved,warnings:e.warnings,historicalVersions:c.originals)
                outcome = .success(.init(erasure:erasure,conversations:c.chats,routines:c.routines,routineRuns:c.runs,compacted:cleaned.compacted,cleanupComplete:cleaned.cleanupComplete,cancelled:cleaned.cancelled))
            }catch {outcome = .failure(error)}
            // Release both credentials and every retained spool descriptor only
            // after the real operation has finished, even on canceled callers.
            defer {inbox.close();transport.close();pairing.close()}
            try await scheduler.stop()
            return try outcome.get()
        }
        retirement=worker
        return try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
    }
    public func status()async->PersonalSyncStatus {PersonalSyncStatus(await scheduler.state)}
    /// A bounded push stream replaces UI polling without another worker task.
    /// Cancelling the consumer removes its scheduler subscription.
    public func updates()async->AsyncStream<PersonalSyncStatus> {
        await scheduler.updates {PersonalSyncStatus($0)}
    }
}
