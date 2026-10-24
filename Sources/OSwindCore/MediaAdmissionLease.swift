import Foundation
import Darwin

/// Shared by supported retained-media writers; full-library inventory/cleanup takes
/// an exclusive lease. Acquired before SQLite/store locks, never while holding them.
public final class MediaAdmissionLease:@unchecked Sendable {
    private let lock=NSLock()
    private var file:Int32
    private init(_ file:Int32) {self.file=file}
    public func release() {lock.lock();defer {lock.unlock()};if file>=0 {flock(file,LOCK_UN);close(file);file = -1}}
    deinit {release()}
    static func acquire(root:URL,exclusive:Bool,timeout:TimeInterval=30,expectedRoot:BackupFileStamp?=nil) throws -> MediaAdmissionLease {
        try Task.checkCancellation()
        let directory=open(root.standardizedFileURL.resolvingSymlinksInPath().path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory>=0 else {throw OSwindError.unavailable("Cannot open the media admission directory")};defer {close(directory)}
        if let expectedRoot {var current=stat();guard fstat(directory,&current)==0,current.st_dev==expectedRoot.device,current.st_ino==expectedRoot.inode else {throw OSwindError.invalid("The library directory changed. Reopen the intended library before writing or wiping.")}}
        let name=".media-admission.lock",file=openat(directory,name,O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard file>=0 else {throw OSwindError.unavailable("Cannot open the media admission lock")}
        var retained=false;defer {if !retained {close(file)}}
        var initial=stat();guard fstat(file,&initial)==0,initial.st_mode & S_IFMT==S_IFREG,initial.st_uid==getuid(),initial.st_nlink==1,initial.st_mode & 0o077==0 else {throw OSwindError.invalid("The media admission lock must be a private regular file")}
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while flock(file,(exclusive ? LOCK_EX:LOCK_SH) | LOCK_NB) != 0 {
            guard errno==EWOULDBLOCK || errno==EAGAIN || errno==EINTR else {throw OSwindError.unavailable("Cannot reserve retained-media access")}
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime<deadline else {throw OSwindError.unavailable("Retained media is busy. Let the active recording or cleanup finish, then retry.")}
            Thread.sleep(forTimeInterval:0.02)
        }
        var current=stat();guard fstatat(directory,name,&current,AT_SYMLINK_NOFOLLOW)==0,current.st_dev==initial.st_dev,current.st_ino==initial.st_ino else {throw OSwindError.invalid("The media admission lock changed")}
        try Task.checkCancellation();retained=true;return MediaAdmissionLease(file)
    }
}
public extension MemoryStore {
    /// Keep the lease until newly written retained files have either been admitted
    /// to SQLite or removed. Raw manual file writers must opt into this protocol.
    func mediaWriteLease() throws -> MediaAdmissionLease {try MediaAdmissionLease.acquire(root:root,exclusive:false,expectedRoot:mediaRootIdentity)}
}

extension MemoryStore {
    func requireMediaRootIdentity() throws {
        let tree=try BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath())
        try tree.withRootDirectory {file in var current=stat();guard fstat(file,&current)==0,current.st_dev==mediaRootIdentity.device,current.st_ino==mediaRootIdentity.inode else {throw OSwindError.invalid("The library directory changed. Reopen the intended library before cleanup.")}}
        try tree.requireRootIdentity(at:root)
    }
}
