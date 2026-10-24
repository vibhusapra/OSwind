import Foundation
import CryptoKit

/// Keeps a cooperative media reservation through image inference/admission.
/// Bytes stay in memory. Revalidation checks the current source and file, rather
/// than accepting an old embedding after a path or pixel replacement.
final class VisualImageSnapshot:@unchecked Sendable {
    let plan:VisualSourcePlan
    let data:Data
    let sha256:String
    private let store:MemoryStore
    private let activity:MediaAdmissionLease
    private let state=NSLock()
    private var tree:BackupFileTree?
    private init(store:MemoryStore,plan:VisualSourcePlan,data:Data,activity:MediaAdmissionLease,tree:BackupFileTree) {
        self.store=store;self.plan=plan;self.data=data;self.activity=activity;self.tree=tree
        sha256=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
    }
    static func make(store:MemoryStore,id:String) throws -> VisualImageSnapshot? {
        let activity=try store.mediaWriteLease();var retained=false
        defer {if !retained {activity.release()}}
        guard let memory=try store.get(id),let plan=try VisualSourcePlan.make(memory) else {return nil}
        guard plan.kind == .image else {throw OSwindError.invalid("Use a video workspace for replay frame decoding")}
        let tree=try BackupFileTree(root:store.root.standardizedFileURL.resolvingSymlinksInPath())
        let actual=try tree.identity()
        guard actual.device==store.mediaRootIdentity.device,actual.inode==store.mediaRootIdentity.inode else {throw OSwindError.invalid("The source library changed before visual indexing")}
        let data=try tree.read(plan.path,limit:64*1024*1024)
        try tree.requireRootIdentity(at:store.root)
        guard let current=try store.get(id),try VisualSourcePlan.make(current)?.revision==plan.revision else {throw OSwindError.unavailable("The visual source changed while reading its image")}
        let snapshot=VisualImageSnapshot(store:store,plan:plan,data:data,activity:activity,tree:tree)
        retained=true;return snapshot
    }
    func validatedMemory() throws -> Memory {
        state.lock();defer {state.unlock()}
        guard let tree else {throw OSwindError.unavailable("The visual source reservation has ended")}
        return try activity.withActive(for:store.mediaRootIdentity) {
            try Task.checkCancellation();try tree.requireRootIdentity(at:store.root)
            guard let current=try store.get(plan.memoryID),try VisualSourcePlan.make(current)?.revision==plan.revision else {throw OSwindError.unavailable("The visual source changed or was removed")}
            let currentBytes=try tree.read(plan.path,limit:64*1024*1024)
            guard currentBytes.count==data.count,SHA256.hash(data:currentBytes).map({String(format:"%02x",$0)}).joined()==sha256 else {throw OSwindError.unavailable("The retained image pixels changed")}
            try tree.requireRootIdentity(at:store.root)
            guard let final=try store.get(plan.memoryID),try VisualSourcePlan.make(final)?.revision==plan.revision else {throw OSwindError.unavailable("The visual source changed during validation")}
            return final
        }
    }
    /// Release the directory descriptor before the reservation, so a completed
    /// close can detach a managed volume even if this value remains referenced.
    func release() {state.lock();tree=nil;activity.release();state.unlock()}
    deinit {release()}
}
