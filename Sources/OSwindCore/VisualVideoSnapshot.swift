import Foundation

/// AVFoundation reads an immutable, privately pinned clip inside this library.
/// The source and pin are rehashed before admission. No system-temp plaintext.
final class VisualVideoSnapshot:VisualMediaSnapshot,@unchecked Sendable {
    static let maximumBytes:Int64=512*1024*1024
    let plan:VisualSourcePlan
    let sha256:String
    let bytes:Int64
    let url:URL
    private let store:MemoryStore
    private let activity:MediaAdmissionLease
    private let state=NSLock()
    private var tree:BackupFileTree?
    private var workspace:BackupWorkspace?
    private init(store:MemoryStore,plan:VisualSourcePlan,digest:BackupFileDigest,tree:BackupFileTree,workspace:BackupWorkspace,activity:MediaAdmissionLease) {
        self.store=store;self.plan=plan;sha256=digest.sha256;bytes=digest.bytes;self.tree=tree;self.workspace=workspace;self.activity=activity
        url=workspace.url.appendingPathComponent("input.mov")
    }
    static func make(store:MemoryStore,id:String) throws -> VisualVideoSnapshot? {
        let activity=try store.mediaWriteLease();var retained=false;defer {if !retained {activity.release()}}
        guard let memory=try store.get(id),let plan=try VisualSourcePlan.make(memory) else {return nil}
        guard plan.kind == .video else {throw OSwindError.invalid("Use an image reservation for a snapshot")}
        let tree=try BackupFileTree(root:store.root.standardizedFileURL.resolvingSymlinksInPath()),identity=try tree.identity()
        guard identity.device==store.mediaRootIdentity.device,identity.inode==store.mediaRootIdentity.inode else {throw OSwindError.invalid("The source library changed before replay indexing")}
        try tree.withFile(plan.path) {_,stamp in guard stamp.bytes<=maximumBytes else {throw OSwindError.invalid("Replay clip exceeds 512 MiB")}}
        let workspace=try store.libraryWorkspace("oswind-visual-index",bucket:.video)
        _ = try tree.pin(plan.path,to:workspace.tree,as:"input.mov") {guard $0<=maximumBytes else {throw OSwindError.invalid("Replay clip exceeds 512 MiB")}}
        let pinned=try workspace.tree.digest("input.mov")
        let original=try tree.digest(plan.path) {guard $0<=maximumBytes else {throw OSwindError.invalid("Replay clip exceeds 512 MiB")}}
        guard pinned==original else {throw OSwindError.unavailable("Replay changed while preparing its visual snapshot")}
        try tree.requireRootIdentity(at:store.root)
        guard let current=try store.get(id),try VisualSourcePlan.make(current)?.revision==plan.revision else {throw OSwindError.unavailable("Replay metadata changed during preparation")}
        let result=VisualVideoSnapshot(store:store,plan:plan,digest:pinned,tree:tree,workspace:workspace,activity:activity);retained=true;return result
    }
    func withAdmission<T>(for destination:MemoryStore,_ body:(Memory) throws -> T) throws -> T {
        state.lock();defer {state.unlock()}
        guard destination === store else {throw OSwindError.invalid("Use the original library's replay reservation")}
        guard let tree,let workspace else {throw OSwindError.unavailable("Replay reservation has ended")}
        return try activity.withActive(for:store.mediaRootIdentity) {
            try tree.requireRootIdentity(at:store.root)
            let original=try tree.digest(plan.path) {guard $0<=Self.maximumBytes else {throw OSwindError.invalid("Replay clip exceeds 512 MiB")}}
            let pinned=try workspace.tree.digest("input.mov")
            guard original.sha256==sha256,original.bytes==bytes,pinned==original else {throw OSwindError.unavailable("Replay bytes changed before visual admission")}
            guard let current=try store.get(plan.memoryID),try VisualSourcePlan.make(current)?.revision==plan.revision else {throw OSwindError.unavailable("Replay metadata changed before visual admission")}
            try tree.requireRootIdentity(at:store.root);return try body(current)
        }
    }
    func release() {state.lock();workspace=nil;tree=nil;activity.release();state.unlock()}
    deinit {release()}
}
