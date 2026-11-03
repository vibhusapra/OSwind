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

/// Only the current session creates this exact review. It contains no keys and
/// cannot authorize a different local erase after the library changes.
public struct PersonalSyncEraseReview:Equatable,Sendable {
    public let deviceNames:[String]
    fileprivate let control:SyncCollectionControl
    fileprivate let session:UUID
}

/// The app can own an enrolled session without receiving wire types or keys.
/// The pairing factory prepares enrollment, native writer and rollback authority
/// before returning this paused owner. A stopped owner session can transfer one
/// exact reviewed addition into a separately retained membership operation.
public actor PersonalSyncSession {
    private nonisolated let library:MemoryStore
    public nonisolated let isGroupOwner:Bool
    private let privateInbox:SyncObjectFolder
    private let service:SyncLibraryService
    private let pairing:PersonalSyncPairing?
    private let scheduler:SyncLibraryScheduler
    private var closed=false
    private var retirement:Task<LibraryWipeResult,Error>?
    private var stopping:Task<Void,Error>?
    private var reviewing:Task<Void,Error>?
    private let reviewOwner=UUID()
    private var ownerAdditionReview:(review:PersonalSyncOwnerReview,request:PersonalSyncPairingReview,environment:SyncNativeWriterEnvironment)?
    private var ownerAdditionTransferred=false
    init(service:SyncLibraryService,pairing:PersonalSyncPairing?=nil,schedule:SyncLibrarySchedule = .init())throws {
        guard pairing==nil || pairing!.belongs(to:service.library) else {throw OSwindError.invalid("Own pairing for the session's current library")}
        library=service.library;privateInbox=service.inbox;self.service=service;self.pairing=pairing;scheduler=try SyncLibraryScheduler(service:service,schedule:schedule)
        if let pairing {isGroupOwner=try pairing.status().phase == .owner}else {isGroupOwner=false}
    }
    public nonisolated func belongs(to store:MemoryStore)->Bool {library === store}
    public nonisolated var ownsHistoryRetirement:Bool {pairing != nil}
    public func reviewOwnerAddition(_ text:String)throws->PersonalSyncOwnerReview {try reviewOwnerAddition(text,now:Date())}
    public func ownerChangeAfterStopping(_ review:PersonalSyncOwnerReview)async throws->PersonalSyncOwnerChange {try await ownerChangeAfterStopping(review,clock:{Date()})}
    /// Deterministic clock adapters remain internal to Core tests. Normal
    /// delivery ticks do not replace pairing authority.
    func reviewOwnerAddition(_ text:String,now:Date)throws->PersonalSyncOwnerReview {
        guard !closed,stopping==nil,retirement==nil,reviewing==nil,!ownerAdditionTransferred,let pairing else {throw OSwindError.unavailable("Review from the current enrolled owner session")}
        try Task.checkCancellation()
        let request=try pairing.reviewDeliveredRequest(text,now:now)
        guard !request.alreadyAdmitted else {throw OSwindError.invalid("This Mac is already admitted; recover its saved response")}
        let status=try pairing.status()
        guard status.phase == .owner,let root=status.rootFingerprint else {throw OSwindError.invalid("Only the original group owner can approve a device")}
        guard status.memberNames.count<SyncProtocolLimits.peers else {throw OSwindError.invalid("This group is at its device limit")}
        let environment=try pairing.ownerChangeEnvironment()
        let workspace=try PersonalSyncOwnerWorkspaceIdentity.read(library)
        let review=PersonalSyncOwnerReview(deviceName:request.deviceName,requestFingerprint:request.requestFingerprint,rootFingerprint:root,expires:request.expires,currentMemberCount:status.memberNames.count,session:reviewOwner,token:UUID(),workspace:workspace)
        try Task.checkCancellation();ownerAdditionReview=(review,request,environment);return review
    }
    /// Caller first retires/drains the exact app model, then explicitly joins
    /// this session's stop. Reserve the one-use transfer before awaiting so
    /// actor reentrancy cannot construct two credential owners.
    func ownerChangeAfterStopping(_ review:PersonalSyncOwnerReview,clock:@Sendable ()->Date)async throws->PersonalSyncOwnerChange {
        guard closed,let stopping,!ownerAdditionTransferred,let stored=ownerAdditionReview,
              stored.review==review,review.session==reviewOwner else {throw OSwindError.unavailable("Stop and join the exact reviewed session before approval")}
        ownerAdditionTransferred=true;ownerAdditionReview=nil
        try await stopping.value
        try Task.checkCancellation()
        return try PersonalSyncOwnerChange.draft(library:library,review:stored.request,environment:stored.environment,now:clock())
    }
    public func setProcessingEnabled(_ enabled:Bool)async throws {
        guard !closed,reviewing==nil else {throw OSwindError.unavailable("This sync session is stopped or reviewing erasure")}
        if enabled {try await scheduler.resumeProcessing()}else{await scheduler.pauseProcessing()}
    }
    public func setNetworkEnabled(_ enabled:Bool)async throws {
        guard !closed,reviewing==nil else {throw OSwindError.unavailable("This sync session is stopped or reviewing erasure")}
        try await scheduler.setNetworkEnabled(enabled)
    }
    public func stop()async throws {
        closed=true
        let closing:Task<Void,Error>
        if let stopping {closing=stopping}
        else {
            let pending=retirement,review=reviewing,scheduler=scheduler,inbox=privateInbox,transport=service.transport,pairing=pairing
            pending?.cancel();review?.cancel()
            closing=Task.detached(priority:.utility) {
                // Cancellation never acknowledges an unfinished native commit,
                // physical cleanup or external credential replacement.
                _=await pending?.result
                _=await review?.result
                defer {inbox.close();transport.close();pairing?.close()}
                try await scheduler.stop()
            }
            stopping=closing
        }
        try await closing.value
    }
    /// The app first stops and joins its capture/import/model producers. These
    /// terminal methods consume the session, including on a failed/canceled
    /// attempt. Pending committed cleanup requires restricted recovery.
    public func eraseLocalHistory(progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in})async throws->LibraryWipeResult {
        try await retireHistory(received:false,progress:progress)
    }
    public func applyReceivedErase(progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in})async throws->LibraryWipeResult {
        try await retireHistory(received:true,progress:progress)
    }
    public func localEraseReview()async throws->PersonalSyncEraseReview? {
        let state=await scheduler.state
        guard !closed,reviewing==nil,let pairing else {throw OSwindError.unavailable("Review erasure from the current enrolled session")}
        guard case .waitingForLocalReview(let control)=state else {return nil}
        return try .init(deviceNames:pairing.status().memberNames,control:control,session:reviewOwner)
    }
    /// Explicit approval leaves processing suspended. The app rechecks its
    /// current lock/onboarding/network intent before resuming this session.
    public func approveLocalErase(_ review:PersonalSyncEraseReview)async throws {
        let state=await scheduler.state
        guard !closed,reviewing==nil,pairing != nil,review.session==reviewOwner,
              case .waitingForLocalReview(let current)=state,current==review.control else {throw OSwindError.unavailable("Review this session's current local erase first")}
        let service=service,scheduler=scheduler,control=review.control
        let worker=Task.detached(priority:.utility) {
            await scheduler.pauseProcessing();try Task.checkCancellation()
            try service.approveLocalGroupErase(control)
            try await scheduler.resolveLocalReview(control)
        }
        reviewing=worker;defer {reviewing=nil}
        try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
    }
    /// Internal until the app supplies its joined producer and recovery paths.
    /// A terminal operation consumes this session; reconnect with a fresh owner
    /// after successful renewal. The caller must first join all other producers.
    func retireHistory(received:Bool,progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in})async throws->LibraryWipeResult {
        guard !closed,retirement==nil,reviewing==nil,let pairing else {throw OSwindError.unavailable("History retirement requires the enrolled session owner")}
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
                outcome = .success(cleaned.attachingLogicalCounts(staged.counts))
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
