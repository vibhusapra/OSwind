import Foundation
import Darwin

public extension MemoryStore {
    /// Logical regular-file sizes, not allocated/APFS physical space. The
    /// traversal can observe concurrent changes; failures/cancellation never
    /// return a partial value as a completed estimate.
    func storageUsageBytes(includeStaging:Bool=true)throws->Int64 {
        try measureStorageUsage(includeStaging:includeStaging,observeEntry:nil)
    }
}
extension MemoryStore {
    func measureStorageUsage(includeStaging:Bool=true,observeEntry:(@Sendable (String)throws->Void)?)throws->Int64 {
        try Task.checkCancellation()
        let activity=try mediaWriteLease();defer {activity.release()}
        let tree=try BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath())
        try tree.requireRootIdentity(at:root)
        let result=try tree.withRootDirectory {directory in
            var identity=stat();guard fstat(directory,&identity)==0,identity.st_dev==mediaRootIdentity.device,identity.st_ino==mediaRootIdentity.inode else {throw OSwindError.invalid("The library directory changed. Reopen the intended library.")}
            var total:Int64=0
            func walk(_ parent:Int32,prefix:String,depth:Int)throws {
                try Task.checkCancellation()
                guard depth<=64 else {throw OSwindError.unavailable("Storage directory nesting exceeds the estimate limit")}
                let copy=dup(parent);guard copy>=0 else {throw OSwindError.unavailable("Cannot inspect library storage")}
                guard let stream=fdopendir(copy) else {Darwin.close(copy);throw OSwindError.unavailable("Cannot enumerate library storage")};defer {closedir(stream)}
                while true {
                    try Task.checkCancellation()
                    errno=0;guard let entry=readdir(stream) else {guard errno==0 else {throw OSwindError.unavailable("Library storage enumeration did not complete")};break}
                    let name=withUnsafePointer(to:&entry.pointee.d_name) {pointer in pointer.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1) {String(validatingCString:$0)}}
                    guard let name else {throw OSwindError.invalid("A storage filename cannot be represented as UTF-8")}
                    if name=="." || name==".." {continue}
                    let relative=prefix+name
                    guard relative.utf8.count<=32768 else {throw OSwindError.unavailable("A storage path exceeds the estimate limit")}
                    try observeEntry?(relative);try Task.checkCancellation()
                    var metadata=stat()
                    guard fstatat(parent,name,&metadata,AT_SYMLINK_NOFOLLOW)==0 else {
                        if errno==ENOENT {continue}
                        throw OSwindError.unavailable("A library storage entry could not be inspected")
                    }
                    switch metadata.st_mode & S_IFMT {
                    case S_IFREG:
                        guard metadata.st_size>=0 else {throw OSwindError.unavailable("A storage size is invalid")}
                        let value=total.addingReportingOverflow(Int64(metadata.st_size));guard !value.overflow else {throw OSwindError.unavailable("Library storage exceeds the estimate range")};total=value.partialValue
                    case S_IFDIR:
                        if !includeStaging,name==".staging",["images/","audio/","video/"].contains(prefix) {continue}
                        let child=openat(parent,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard child>=0 else {
                            if errno==ENOENT || errno==ENOTDIR || errno==ELOOP {continue}
                            throw OSwindError.unavailable("A library storage directory could not be opened")
                        }
                        defer {Darwin.close(child)}
                        var current=stat();guard fstat(child,&current)==0,current.st_dev==metadata.st_dev,current.st_ino==metadata.st_ino else {throw OSwindError.invalid("A library storage directory changed during traversal")}
                        try walk(child,prefix:relative+"/",depth:depth+1)
                    default:continue // Never follow symlinks, sockets or devices.
                    }
                }
            }
            try walk(directory,prefix:"",depth:0);try Task.checkCancellation();return total
        }
        try tree.requireRootIdentity(at:root);return result
    }
}
