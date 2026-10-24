import Foundation
import CSQLite
import Darwin

public struct LibraryWipeResult:Codable,Sendable {
    public let erasure:HistoryErasureResult
    public let conversations,routines,routineRuns:Int
    public let compacted,cleanupComplete,cancelled:Bool
}

/// Descriptor-relative, streaming inventory. No file contents or paths outside
/// the three retained-media buckets are inspected. Symlinks are queued, never followed.
private enum WipeInventory {
    static func walk(root:URL,expectedRoot:BackupFileStamp,stage:((String) throws -> Void)?,removeEmpty:Bool) throws {
        let tree=try BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath())
        try tree.requireRootIdentity(at:root)
        try tree.withRootDirectory {directory in
            var metadata=stat();guard fstat(directory,&metadata)==0,metadata.st_dev==expectedRoot.device,metadata.st_ino==expectedRoot.inode else {throw OSwindError.invalid("The library directory changed during media inventory")}
            for bucket in ["images","audio","video"] {try descend(directory,name:bucket,path:bucket,depth:0,stage:stage,removeEmpty:removeEmpty)}
        }
        try tree.requireRootIdentity(at:root)
    }
    private static func descend(_ parent:Int32,name:String,path:String,depth:Int,stage:((String) throws -> Void)?,removeEmpty:Bool) throws {
        guard depth<=64,path.utf8.count<=32768 else {throw OSwindError.invalid("Retained-media directory nesting exceeds safe cleanup bounds")}
        if stage != nil {try Task.checkCancellation()}
        var before=stat();guard fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW)==0,before.st_mode & S_IFMT==S_IFDIR else {throw OSwindError.unavailable("Cannot safely inspect a retained-media directory")}
        let child=openat(parent,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child>=0 else {throw OSwindError.unavailable("Cannot enumerate retained media")};defer {close(child)}
        var opened=stat();guard fstat(child,&opened)==0,opened.st_dev==before.st_dev,opened.st_ino==before.st_ino else {throw OSwindError.invalid("A retained-media directory changed")}
        let copy=dup(child);guard copy>=0 else {throw OSwindError.unavailable("Cannot enumerate retained media")}
        guard let stream=fdopendir(copy) else {close(copy);throw OSwindError.unavailable("Cannot enumerate retained media")};defer {closedir(stream)}
        while true {
            errno=0;guard let entry=readdir(stream) else {guard errno==0 else {throw OSwindError.unavailable("Retained-media inventory did not finish")};break}
            let member=withUnsafePointer(to:&entry.pointee.d_name) {pointer in pointer.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1) {String(validatingCString:$0)}}
            guard let member else {throw OSwindError.invalid("A retained-media filename is not valid UTF-8")}
            if member=="." || member==".." {continue}
            var metadata=stat();guard fstatat(child,member,&metadata,AT_SYMLINK_NOFOLLOW)==0 else {throw OSwindError.unavailable("A retained-media member changed during inventory")}
            let relative=path+"/"+member
            if metadata.st_mode & S_IFMT==S_IFDIR {try descend(child,name:member,path:relative,depth:depth+1,stage:stage,removeEmpty:removeEmpty)}
            else if let stage {try stage(relative)}
        }
        var current=stat();guard fstatat(parent,name,&current,AT_SYMLINK_NOFOLLOW)==0,current.st_dev==before.st_dev,current.st_ino==before.st_ino else {throw OSwindError.invalid("A retained-media directory changed during cleanup")}
        if removeEmpty,depth>0,unlinkat(parent,name,AT_REMOVEDIR) != 0,errno != ENOTEMPTY {throw OSwindError.unavailable("An empty retained-media directory could not be removed")}
    }
}
public extension MemoryStore {
    /// Logical deletion and durable admission of all known/orphan retained paths
    /// commit together. Files are touched only after COMMIT; failures remain retryable.
    func wipeLibrary(progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in}) throws -> LibraryWipeResult {
        progress(.init(phase:"Waiting for active media writers"))
        let lease=try MediaAdmissionLease.acquire(root:root,exclusive:true,expectedRoot:mediaRootIdentity);defer {lease.release()}
        return try withRoutineDatabase {db in
            let counts=try erasureCancellable(db) {try db.transaction { () -> (Int,Int,Int,Int,Int) in
                let sources=try db.eraseCount("SELECT total FROM memory_statistics WHERE singleton=1"),turns=try db.eraseCount("SELECT COUNT(*) FROM chat_turns"),chats=try db.eraseCount("SELECT COUNT(*) FROM chat_sessions"),routines=try db.eraseCount("SELECT COUNT(*) FROM routines"),runs=try db.eraseCount("SELECT COUNT(*) FROM routine_runs")
                progress(.init(phase:"Inventorying retained media"));let put=try db.statement("INSERT OR IGNORE INTO erasure_assets(path) VALUES(?)");defer {sqlite3_finalize(put)};var scanned:Int64=0
                try WipeInventory.walk(root:root,expectedRoot:mediaRootIdentity,stage:{path in
                    try Task.checkCancellation();sqlite3_reset(put);sqlite3_clear_bindings(put);db.bind(put,1,path);try db.done(put);scanned+=1
                    if scanned%100==0 {progress(.init(phase:"Inventorying retained media",completedItems:scanned,unit:"files"))}
                },removeEmpty:false)
                progress(.init(phase:"Deleting local history",completedItems:scanned,unit:"files"))
                try db.execute("DELETE FROM routines; DELETE FROM chat_sessions; DELETE FROM memories; DELETE FROM vector_changes; UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='identity'; INSERT INTO store_metadata(key,value) VALUES('library_wipe_dirty','1') ON CONFLICT(key) DO UPDATE SET value='1'")
                return (sources,turns,chats,routines,runs)
            }}
            progress(.init(phase:"Removing retained media"))
            return finishLibraryWipe(db,sources:counts.0,turns:counts.1,chats:counts.2,routines:counts.3,runs:counts.4,progress:progress)
        }
    }
    func hasPendingLibraryWipeCleanup() throws -> Bool {try withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='library_wipe_dirty' AND value='1'")>0}}
    /// Retries only the sealed pending paths. Never inventories newly recorded files.
    func retryLibraryWipeCleanup(progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in}) throws -> LibraryWipeResult {
        progress(.init(phase:"Waiting for active media writers"));let lease=try MediaAdmissionLease.acquire(root:root,exclusive:true,expectedRoot:mediaRootIdentity);defer {lease.release()}
        return try withRoutineDatabase {db in
            progress(.init(phase:"Retrying retained-media cleanup"))
            return finishLibraryWipe(db,sources:0,turns:0,chats:0,routines:0,runs:0,progress:progress)
        }
    }
}
private extension MemoryStore {
    func finishLibraryWipe(_ db:RoutineDatabase,sources:Int,turns:Int,chats:Int,routines:Int,runs:Int,progress:@escaping @Sendable (LibraryBackupProgress)->Void) -> LibraryWipeResult {
        cancelSearchIndexBuild();releaseSearchIndex()
        do {try requireMediaRootIdentity()} catch {
            let pending=(try? db.eraseCount("SELECT COUNT(*) FROM erasure_assets")) ?? -1
            let erasure=HistoryErasureResult(sources:sources,conversationTurns:turns,removedMedia:0,sharedMedia:0,pendingMedia:pending,searchCacheRemoved:false,warnings:["History deletion committed, but the library folder changed. Reopen the intended library and retry cleanup. No files in the replacement folder were removed."])
            return .init(erasure:erasure,conversations:chats,routines:routines,routineRuns:runs,compacted:false,cleanupComplete:false,cancelled:Task.isCancelled)
        }
        var result=cleanupErasedAssets(db,sources:sources,turns:turns,stopOnCancellation:true),directories=true,compacted=false
        if !Task.isCancelled {
            do {try WipeInventory.walk(root:root,expectedRoot:mediaRootIdentity,stage:nil,removeEmpty:true)} catch {directories=false;result=result.warning("Some media directories could not be cleaned. Retry library cleanup after checking file access.")}
            progress(.init(phase:"Compacting deleted history"))
            do {
                try db.execute("VACUUM")
                let check=try db.statement("PRAGMA wal_checkpoint(TRUNCATE)");defer {sqlite3_finalize(check)}
                guard sqlite3_step(check)==SQLITE_ROW,sqlite3_column_int(check,0)==0 else {throw OSwindError.unavailable("Other readers still hold deleted history pages")};compacted=true
            } catch {result=result.warning("Database compaction did not finish. Close other library readers and retry cleanup.")}
        }
        let complete=result.pendingMedia==0 && result.searchCacheRemoved && directories && compacted && !Task.isCancelled && result.warnings.isEmpty
        if complete {do {try db.execute("DELETE FROM store_metadata WHERE key='library_wipe_dirty'")} catch {result=result.warning("Cleanup finished but its completion marker could not be saved. Retry cleanup.")}}
        if Task.isCancelled {result=result.warning("Cleanup stopped after the history deletion committed. Pending files remain queued for retry.")}
        return .init(erasure:result,conversations:chats,routines:routines,routineRuns:runs,compacted:compacted,cleanupComplete:complete && result.warnings.isEmpty,cancelled:Task.isCancelled)
    }
}
