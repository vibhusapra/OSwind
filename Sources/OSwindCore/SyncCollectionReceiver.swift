import Foundation

enum SyncCollectionReceiveResult:Equatable {case missing,unchanged,applied}

/// Authenticates a body-free control before entering the owning library's
/// transaction. The required retirement adapter must perform real native/cache
/// erasure; this transport boundary is not a public synchronization service.
struct SyncCollectionReceiver {
    let library:MemoryStore
    let cache:SyncVersionStore
    let inbox:SyncObjectFolder
    let retire:(SyncClock,MediaAdmissionLease)throws->Void

    func receive(creator:String,counter:Int64)throws->SyncCollectionReceiveResult {
        try Task.checkCancellation()
        try library.withRoutineDatabase {db in
            guard db.handle==cache.database.handle,try cache.journal.cursor(for:creator) != nil else {throw OSwindError.invalid("Do not fetch controls from an unenrolled peer")}
        }
        try inbox.requireNamespace(group:cache.journal.group,epoch:cache.journal.epoch)
        guard let control=try inbox.collectionControl(creator:creator,counter:counter) else {return .missing}
        let lease=try MediaAdmissionLease.acquire(root:library.root,exclusive:true,expectedRoot:library.mediaRootIdentity);defer {lease.release()}
        return try library.withRoutineDatabase {db in
            guard db.handle==cache.database.handle else {throw OSwindError.invalid("Collection receiver belongs to another library")}
            let history=SyncCollectionHistory(database:db,replica:cache.journal.replica)
            return try history.observeVerifiedGroupControl(control,journal:cache.journal,retire:{try retire($0,lease)}) ? .applied:.unchanged
        }
    }
}
