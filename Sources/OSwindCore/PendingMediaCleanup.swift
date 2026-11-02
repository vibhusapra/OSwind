import Foundation
import Dispatch
import CMacNotifications

/// Notifications are untrusted hints. The native queue, root identity and media
/// reservation are revalidated by the actual attempt; no path/content is sent.
public enum PendingMediaCleanupEvent:Sendable {case pending,writerReleased}
enum PendingMediaCleanupSignal {
    static func name(device:Int32,inode:UInt64,event:PendingMediaCleanupEvent)->String {
        "org.oswind.media-cleanup.v1.\(device).\(inode)."+(event == .pending ? "pending":"released")
    }
    static func post(device:Int32,inode:UInt64,event:PendingMediaCleanupEvent) {
        _=notify_post(name(device:device,inode:inode,event:event))
    }
}

public final class PendingMediaCleanupObservation:@unchecked Sendable {
    private let lock=NSLock()
    private var tokens=[Int32]()
    init(identity:BackupFileStamp,handler:@escaping @Sendable (PendingMediaCleanupEvent)->Void)throws {
        do {
            for event in [PendingMediaCleanupEvent.pending,.writerReleased] {
                var token:Int32=0
                let status=notify_register_dispatch(PendingMediaCleanupSignal.name(device:identity.device,inode:identity.inode,event:event),&token,DispatchQueue.global(qos:.utility)) {_ in handler(event)}
                guard status==0 else {throw OSwindError.unavailable("Cannot observe deferred media cleanup (notification status \(status))")}
                tokens.append(token)
            }
        } catch {cancel();throw error}
    }
    public func cancel() {lock.lock();let owned=tokens;tokens=[];lock.unlock();for token in owned {_=notify_cancel(token)}}
    deinit {cancel()}
}

public enum PendingMediaCleanupDisposition:Sendable {case idle,finished,waitingForWriters,needsAttention,libraryWipe}
public struct PendingMediaCleanupAttempt:Sendable {
    public let disposition:PendingMediaCleanupDisposition
    public let result:HistoryErasureResult?
}
public extension MemoryStore {
    func observePendingMediaCleanup(_ handler:@escaping @Sendable (PendingMediaCleanupEvent)->Void)throws->PendingMediaCleanupObservation {
        guard !isClosed else {throw OSwindError.unavailable("The library connection is closed")}
        try requireMediaRootIdentity()
        return try PendingMediaCleanupObservation(identity:mediaRootIdentity,handler:handler)
    }
    /// Only resumes committed media/cache work. It neither prunes history nor
    /// inventories files, compacts the database or completes a library wipe.
    func resumePendingMediaCleanup()throws->PendingMediaCleanupAttempt {
        try Task.checkCancellation()
        return try withRoutineDatabase {db in
            func pending()throws->(wipe:Bool,work:Bool) {
                try NativeMediaSchema.validate(db);try requireMediaRootIdentity()
                let wipe=try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='library_wipe_dirty' AND value='1'")>0
                let files=try db.eraseCount("SELECT EXISTS(SELECT 1 FROM erasure_assets)"),cache=try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='recap_cache_dirty_v33' AND value='1'")
                return (wipe,files>0 || cache>0)
            }
            let initial=try pending()
            if initial.wipe {return .init(disposition:.libraryWipe,result:nil)}
            if !initial.work {return .init(disposition:.idle,result:nil)}
            try Task.checkCancellation()
            var writerBusy=false
            let lease:MediaAdmissionLease
            do {lease=try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:0,expectedRoot:mediaRootIdentity,onBusy:{writerBusy=true})}
            catch {if error is CancellationError {throw error};if writerBusy {return .init(disposition:.waitingForWriters,result:nil)};throw error}
            defer {lease.release()}
            // Another process may have finished a wipe between the first probe
            // and reservation. A wipe owns this marker until its own retry.
            if try pending().wipe {return .init(disposition:.libraryWipe,result:nil)}
            try Task.checkCancellation()
            let result=cleanupErasedAssets(db,sources:0,turns:0,stopOnCancellation:true,reservation:lease)
            let complete=result.pendingMedia==0 && result.searchCacheRemoved && result.warnings.isEmpty
            return .init(disposition:complete ? .finished:.needsAttention,result:result)
        }
    }
}
