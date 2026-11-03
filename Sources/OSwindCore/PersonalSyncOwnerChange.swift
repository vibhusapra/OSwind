import Foundation

/// Internal until the complete app lifecycle is integrated. Review tokens are
/// ephemeral capabilities for one exact session, never saved or transported.
struct PersonalSyncOwnerReview:Equatable,Sendable {
    let deviceName:String,requestFingerprint:String,rootFingerprint:String
    let expires:Date
    let currentMemberCount:Int
    let session:UUID,token:UUID
}

/// The app must retain this object before invoking apply. Construction reserves
/// original accounts but does not publish a membership intent. Failed close
/// keeps the same owner and credential leases available for explicit retry.
final class PersonalSyncOwnerChange:@unchecked Sendable {
    private let lock=NSRecursiveLock()
    private let operation:SyncMembershipPreparationOwner
    private let preparation:SyncMembershipPreparationOwner.ApprovalDraft?
    private let library:MemoryStore?
    private var attempted=false,finished=false,closed=false
    private var response:PersonalSyncApprovedResponse?
    private init(operation:SyncMembershipPreparationOwner,preparation:SyncMembershipPreparationOwner.ApprovalDraft?,library:MemoryStore?) {
        self.operation=operation;self.preparation=preparation;self.library=library
    }
    static func draft(library:MemoryStore,review:PersonalSyncPairingReview,environment:SyncNativeWriterEnvironment,now:Date)throws->PersonalSyncOwnerChange {
        let prepared=try SyncMembershipPreparationOwner.approvalDraft(library:library,review:review,environment:environment,now:now)
        return .init(operation:prepared.owner,preparation:prepared,library:library)
    }
    static func recover(root:URL,environment:SyncNativeWriterEnvironment = .native)throws->PersonalSyncOwnerChange {
        let operation=try SyncMembershipPreparationOwner.open(root:root,environment:environment)
        return .init(operation:operation,preparation:nil,library:nil)
    }
    func belongs(to store:MemoryStore)->Bool {library === store}
    /// A failed attempt is closed and reopened through original-account
    /// recovery. It is never retried by generating a replacement response.
    /// Pure-proof legacy recovery can finish without a joining response.
    func apply(clock:()->Date={Date()})throws->PersonalSyncApprovedResponse? {
        lock.lock();defer {lock.unlock()}
        guard !closed else {throw OSwindError.unavailable("Membership change is closed")}
        if finished {return response}
        guard !attempted else {throw OSwindError.unavailable("Close this saved membership attempt before recovery")}
        attempted=true
        if let preparation {try preparation.prepare(clock:clock)}
        try operation.applyMembership()
        let saved=try operation.completedResponse()
        guard preparation==nil || saved != nil else {throw OSwindError.unavailable("The saved approval response requires recovery")}
        response=saved;finished=true;return saved
    }
    func close()throws {
        lock.lock();defer {lock.unlock()};guard !closed else {return}
        try operation.close();closed=true
    }
}
