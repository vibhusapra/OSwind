import Foundation
import CSQLite

/// A comparison stamp, never an authority grant. Membership may advance while
/// original directory, collection generation and local account handles stay.
struct PersonalSyncOwnerWorkspaceIdentity:Equatable,Sendable {
    let device:Int32,inode:UInt64
    let origin:String,generation:String,pairingHandle:String,pairingLifetime:String,deliveryID:String
    static func read(_ store:MemoryStore)throws->Self {
        try store.validateDirectoryIdentity()
        let read:(RoutineDatabase)throws->Self={db in
            let scope=try SyncChangeCapture.scope(db)
            let row=try db.statement("SELECT p.value,l.value,d.id FROM store_metadata p,store_metadata l,personal_sync_delivery_anchor d WHERE p.key='sync-pairing-handle-v1' AND l.key='sync-pairing-library-lifetime-v1' AND d.singleton=1")
            defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("Original enrolled workspace handles are unavailable")}
            return .init(device:store.mediaRootIdentity.device,inode:store.mediaRootIdentity.inode,origin:scope.origin,generation:scope.generation,pairingHandle:db.text(row,0),pairingLifetime:db.text(row,1),deliveryID:db.text(row,2))
        }
        if store.nativeWriterAdmission.membershipQuarantined {return try store.withMembershipDatabase(read)}
        return try store.withRoutineDatabase(read)
    }
    func validate(_ store:MemoryStore)throws {
        guard try Self.read(store)==self else {throw OSwindError.unavailable("The approved library changed. Reopen the original workspace before recovering its response.")}
    }
}

/// Review tokens are
/// ephemeral capabilities for one exact session, never saved or transported.
public struct PersonalSyncOwnerReview:Equatable,Sendable {
    public let deviceName:String,requestFingerprint:String,rootFingerprint:String
    public let expires:Date
    public let currentMemberCount:Int
    let session:UUID,token:UUID
    let workspace:PersonalSyncOwnerWorkspaceIdentity
    /// Reject a different directory, database generation or account set before
    /// a quiet replacement is attached or an approval response is presented.
    public func validateReopenedStore(_ store:MemoryStore)throws {try workspace.validate(store)}
}

/// The app must retain this object before invoking apply. Construction reserves
/// original accounts but does not publish a membership intent. Failed close
/// keeps the same owner and credential leases available for explicit retry.
public final class PersonalSyncOwnerChange:@unchecked Sendable {
    private let lock=NSRecursiveLock()
    private var operation:SyncMembershipPreparationOwner?
    private let preparation:SyncMembershipPreparationOwner.ApprovalDraft?
    private let peerPreparation:SyncMembershipPreparationOwner.MembershipDraft?
    private var library:MemoryStore?
    private let recovery:(root:URL,environment:SyncNativeWriterEnvironment)?
    private var attempted=false,finished=false,closed=false
    private var response:PersonalSyncApprovedResponse?
    private var workspace:PersonalSyncOwnerWorkspaceIdentity?
    private init(operation:SyncMembershipPreparationOwner,preparation:SyncMembershipPreparationOwner.ApprovalDraft?,peerPreparation:SyncMembershipPreparationOwner.MembershipDraft?=nil,library:MemoryStore?,workspace:PersonalSyncOwnerWorkspaceIdentity) {
        self.operation=operation;self.preparation=preparation;self.peerPreparation=peerPreparation;self.library=library;self.workspace=workspace;self.recovery=nil
    }
    static func draft(library:MemoryStore,review:PersonalSyncPairingReview,environment:SyncNativeWriterEnvironment,now:Date)throws->PersonalSyncOwnerChange {
        let workspace=try PersonalSyncOwnerWorkspaceIdentity.read(library)
        let prepared=try SyncMembershipPreparationOwner.approvalDraft(library:library,review:review,environment:environment,now:now)
        return .init(operation:prepared.owner,preparation:prepared,library:library,workspace:workspace)
    }
    static func peerDraft(library:MemoryStore,proof:SyncMembershipRefresh,trusted:SyncMembershipCertificate,environment:SyncNativeWriterEnvironment)throws->PersonalSyncOwnerChange {
        let workspace=try PersonalSyncOwnerWorkspaceIdentity.read(library)
        let prepared=try SyncMembershipPreparationOwner.membershipDraft(library:library,proof:proof,trusted:trusted,environment:environment)
        return .init(operation:prepared.owner,preparation:nil,peerPreparation:prepared,library:library,workspace:workspace)
    }
    private init(root:URL,environment:SyncNativeWriterEnvironment) {
        operation=nil;preparation=nil;peerPreparation=nil;library=nil;recovery=(root,environment)
    }
    /// Create the retained operation before any storage is opened. Apply and
    /// close run in the app's joined background work; close can be retried.
    public static func recover(root:URL)->PersonalSyncOwnerChange {.init(root:root,environment:.native)}
    static func recover(root:URL,environment:SyncNativeWriterEnvironment)->PersonalSyncOwnerChange {.init(root:root,environment:environment)}
    public func belongs(to store:MemoryStore)->Bool {lock.lock();defer {lock.unlock()};return library === store}
    public func validateReopenedStore(_ store:MemoryStore)throws {
        lock.lock();defer {lock.unlock()}
        guard closed,let workspace else {throw OSwindError.unavailable("Finish closing the original membership workspace before reopening")}
        try workspace.validate(store)
    }
    public func apply()throws->PersonalSyncApprovedResponse? {try apply(clock:{Date()})}
    /// A failed attempt is closed and reopened through original-account
    /// recovery. It is never retried by generating a replacement response.
    /// Pure-proof legacy recovery can finish without a joining response.
    func apply(clock:()->Date)throws->PersonalSyncApprovedResponse? {
        lock.lock();defer {lock.unlock()}
        guard !closed else {throw OSwindError.unavailable("Membership change is closed")}
        if finished {return response}
        guard !attempted else {throw OSwindError.unavailable("Close this saved membership attempt before recovery")}
        try Task.checkCancellation();attempted=true
        if let recovery {
            let store=try MemoryStore(root:recovery.root,recoveryReadOnly:false,nativeWriterEnvironment:recovery.environment,membershipRecovery:true)
            library=store
            workspace=try PersonalSyncOwnerWorkspaceIdentity.read(store)
            operation=try SyncMembershipPreparationOwner.open(library:store,environment:recovery.environment)
        }
        guard let operation else {throw OSwindError.unavailable("Original membership operation is unavailable")}
        if workspace==nil,let library {workspace=try PersonalSyncOwnerWorkspaceIdentity.read(library)}
        if let preparation {try preparation.prepare(clock:clock)}
        try peerPreparation?.prepare()
        try operation.applyMembership()
        let saved=try operation.completedResponse()
        guard preparation==nil || saved != nil else {throw OSwindError.unavailable("The saved approval response requires recovery")}
        // A peer refresh must not present an older joining response that may
        // still be durably retained by the original pairing account.
        response=peerPreparation==nil ? saved:nil;finished=true;return response
    }
    public func close()throws {
        lock.lock();defer {lock.unlock()};guard !closed else {return}
        if let operation {try operation.close()}else {try library?.close()};closed=true
    }
}

/// Normal opening recognizes the saved handover without constructing or
/// discarding a recovery owner. Presentation contains no private authority.
public struct PersonalSyncMembershipRecoveryRequired:LocalizedError,Sendable {
    public var errorDescription:String? {"Resume the exact saved membership operation before ordinary access"}
    init() {}
}
