import Foundation
import Darwin

/// A configured operation chooses its policy from this immutable snapshot and
/// validates it at publication. Keep it only for that operation; release is
/// idempotent. An original file descriptor prevents inode-reuse ABA on atomic
/// saves, including saves of identical bytes. No settings lock spans preparation.
public final class LibrarySettingsSnapshot:@unchecked Sendable {
    public let settings:AppSettings
    private let mutex=NSLock()
    private var tree:BackupFileTree?
    private var file:Int32
    private let stamp:BackupFileStamp?
    private let bytes:Data?
    private init(settings:AppSettings,tree:BackupFileTree,current:SettingsFileAccess.Current) {
        self.settings=settings;self.tree=tree;file=current.file;stamp=current.stamp;bytes=current.bytes
    }
    public static func capture(root:URL) throws -> LibrarySettingsSnapshot {
        let tree=try BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath(),writable:true)
        return try SettingsFileAccess.withLock(tree:tree,exclusive:false) {
            try tree.requireRootIdentity(at:root)
            let current=try SettingsFileAccess.read(tree:tree)
            do {
                let settings:AppSettings
                if let bytes=current.bytes {
                    do {settings=try JSONDecoder().decode(AppSettings.self,from:bytes)}
                    catch {throw OSwindError.invalid("Saved settings are malformed. Repair them before importing.")}
                } else {settings=AppSettings()}
                return LibrarySettingsSnapshot(settings:settings,tree:tree,current:current)
            } catch {if current.file>=0 {close(current.file)};throw error}
        }
    }
    public func release() {
        mutex.lock();defer {mutex.unlock()}
        if file>=0 {close(file);file = -1};tree=nil
    }
    deinit {release()}
    // Lock order: media activity -> SQL -> snapshot mutex -> settings file lock.
    // A settings saver must never acquire SQL while holding the file lock.
    func withCurrent<T>(root:URL,policy:PrivacyPolicy,_ body:()throws->T) throws -> T {
        mutex.lock();defer {mutex.unlock()}
        guard let tree,settings.privacy==policy else {throw OSwindError.invalid("Use an active settings snapshot and its privacy policy for this import")}
        return try SettingsFileAccess.withLock(tree:tree,exclusive:false) {
            try tree.requireRootIdentity(at:root)
            let current=try SettingsFileAccess.read(tree:tree);defer {if current.file>=0 {close(current.file)}}
            guard current.stamp==stamp,current.bytes==bytes else {throw OSwindError.unavailable("Saved settings changed during import preparation. Retry the import using the current settings.")}
            try Task.checkCancellation();return try body()
        }
    }
}

/// Cooperative current-version settings writers share a descriptor-bound lock.
/// Manual/older same-user writers do not participate in this protocol. The lock
/// is short and bounded, and is never held over model work or an await.
enum SettingsFileAccess {
    static let maximumBytes=4*1024*1024
    struct Current {var file:Int32 = -1;var stamp:BackupFileStamp?;var bytes:Data?}
    static func withLock<T>(tree:BackupFileTree,exclusive:Bool,_ body:()throws->T) throws -> T {
        try tree.withRootDirectory {directory in
            let name=".settings-admission.lock",file=openat(directory,name,O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,0o600)
            guard file>=0 else {throw OSwindError.unavailable("Cannot open the settings admission lock")};defer {close(file)}
            var initial=stat()
            guard fstat(file,&initial)==0,initial.st_mode & S_IFMT==S_IFREG,initial.st_uid==getuid(),initial.st_nlink==1,initial.st_mode & 0o077==0 else {throw OSwindError.invalid("The settings admission lock must be a private regular file")}
            let deadline=ProcessInfo.processInfo.systemUptime+1
            while flock(file,(exclusive ? LOCK_EX:LOCK_SH) | LOCK_NB) != 0 {
                guard errno==EWOULDBLOCK || errno==EAGAIN || errno==EINTR else {throw OSwindError.unavailable("Cannot reserve settings access")}
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime<deadline else {throw OSwindError.unavailable("Settings are busy. Retry after the current save or import commits.")}
                Thread.sleep(forTimeInterval:0.005)
            }
            defer {flock(file,LOCK_UN)}
            var current=stat()
            guard fstatat(directory,name,&current,AT_SYMLINK_NOFOLLOW)==0,current.st_dev==initial.st_dev,current.st_ino==initial.st_ino else {throw OSwindError.invalid("The settings admission lock changed")}
            try Task.checkCancellation();return try body()
        }
    }
    static func read(tree:BackupFileTree) throws -> Current {
        try tree.withRootDirectory {directory in
            let file=openat(directory,"settings.json",O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if file<0,errno==ENOENT {return .init()}
            guard file>=0 else {throw OSwindError.unavailable("Cannot open saved settings")}
            var retained=false;defer {if !retained {close(file)}}
            var initial=stat()
            guard fstat(file,&initial)==0,initial.st_mode & S_IFMT==S_IFREG,initial.st_uid==getuid(),initial.st_nlink==1,initial.st_mode & 0o077==0,initial.st_size>=0,initial.st_size<=maximumBytes else {throw OSwindError.invalid("Saved settings must be a private regular file under 4 MiB")}
            var bytes=Data(),buffer=[UInt8](repeating:0,count:16384)
            while true {
                try Task.checkCancellation();let count=Darwin.read(file,&buffer,buffer.count)
                if count<0,errno==EINTR {continue}
                guard count>=0,count<=maximumBytes-bytes.count else {throw OSwindError.invalid("Cannot read bounded saved settings")}
                if count==0 {break};bytes.append(contentsOf:buffer.prefix(count))
            }
            var final=stat(),named=stat()
            guard fstat(file,&final)==0,fstatat(directory,"settings.json",&named,AT_SYMLINK_NOFOLLOW)==0,
                  BackupFileStamp(initial)==BackupFileStamp(final),BackupFileStamp(initial)==BackupFileStamp(named),bytes.count==initial.st_size else {throw OSwindError.unavailable("Saved settings changed while being read")}
            retained=true;return .init(file:file,stamp:BackupFileStamp(initial),bytes:bytes)
        }
    }
    static func save(_ data:Data,root:URL) throws {
        guard data.count<=maximumBytes else {throw OSwindError.invalid("Settings exceed 4 MiB")}
        try Paths.ensure(root)
        let tree=try BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath(),writable:true)
        try withLock(tree:tree,exclusive:true) {
            try tree.requireRootIdentity(at:root)
            try tree.withRootDirectory {directory in
                var old=stat()
                if fstatat(directory,"settings.json",&old,AT_SYMLINK_NOFOLLOW)==0 {
                    guard old.st_mode & S_IFMT==S_IFREG,old.st_uid==getuid(),old.st_nlink==1 else {throw OSwindError.invalid("Cannot replace settings that are not an owned regular file")}
                } else if errno != ENOENT {throw OSwindError.unavailable("Cannot inspect saved settings")}
                let temporary=".settings-write-"+UUID().uuidString
                try tree.write(data,as:temporary);defer {try? tree.remove(temporary)}
                try tree.requireRootIdentity(at:root);try Task.checkCancellation()
                guard renameat(directory,temporary,directory,"settings.json")==0 else {throw OSwindError.unavailable("Cannot publish saved settings")}
            }
        }
    }
}
