import Foundation

enum LibraryWorkspaceBucket:String {case audio,video}
extension MemoryStore {
    /// Future encrypted volumes must contain intermediate plaintext as well as
    /// admitted source files. The reservation remains owned by this workspace.
    func libraryWorkspace(_ label:String,bucket:LibraryWorkspaceBucket = .audio) throws -> BackupWorkspace {
        let activity=try mediaWriteLease()
        do {
            let base=try BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath(),writable:true),identity=try base.identity()
            guard identity.device==mediaRootIdentity.device,identity.inode==mediaRootIdentity.inode else {throw OSwindError.invalid("The library directory changed before workspace creation")}
            let parent=try base.privateDirectory(bucket.rawValue+"/.staging"),parentStamp=try parent.identity()
            try base.requireRootIdentity(at:root)
            _ = try BackupWorkspace.cleanupAbandoned(in:parent.root,labels:[label],expectedParent:parentStamp)
            return try BackupWorkspace(in:parent.root,label:label,mediaActivity:activity,parentIdentity:parentStamp)
        } catch {activity.release();throw error}
    }
    func libraryWorkspaceAsync(_ label:String,bucket:LibraryWorkspaceBucket = .audio) async throws -> BackupWorkspace {
        let worker=Task.detached(priority:.utility) {try self.libraryWorkspace(label,bucket:bucket)}
        return try await withTaskCancellationHandler {try await worker.value} onCancel: {worker.cancel()}
    }
}
