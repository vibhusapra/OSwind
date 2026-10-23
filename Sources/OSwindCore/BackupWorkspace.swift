import Foundation
import Darwin

struct BackupWorkspaceMarker: Codable {
    var format = "OSwind unpublished workspace"
    var version = 1
    var jobID: String
    var label: String
    var workspaceName: String
    var device: Int32
    var inode: UInt64
    var pid: Int32
    var createdAt: Double
}

/// The private companion holds its lease/marker outside the package payload.
/// A successful atomic publication never ships these operation-control files.
final class BackupWorkspace {
    static let operationLabels = ["oswind-visual-recording","oswind-model-download","oswind-audio-import","oswind-audio-chunk","oswind-transcription","oswind-backup","oswind-backup-pins","oswind-backup-inspect","oswind-backup-partial","oswind-restore-input","oswind-restore-partial"]
    let tree: BackupFileTree
    let url: URL
    private let parent: Int32
    private let name: String
    private let device: Int32
    private let inode: UInt64
    private let control: BackupFileTree
    private let controlName: String
    private let controlDevice: Int32
    private let controlInode: UInt64
    private let lease: Int32
    private var published = false
    init(in parentURL: URL = FileManager.default.temporaryDirectory, label: String = "oswind-backup") throws {
        guard parentURL.isFileURL, !parentURL.path.utf8.contains(0), try BackupFileTree.components(label).count == 1 else { throw BackupFileError.invalid("Invalid backup workspace parent") }
        guard let canonical = realpath(parentURL.path,nil) else { throw BackupFileError.invalid("Backup destination directory is unavailable") }; defer { free(canonical) }
        let parentPath = String(cString:canonical), directory = open(canonical,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw BackupFileError.io("Cannot open backup workspace parent") }
        let id = UUID().uuidString.lowercased(), member = "."+label+"-"+id, companion = ".oswind-job-"+id
        guard mkdirat(directory,member,0o700)==0 else { close(directory); throw BackupFileError.io("Cannot create private backup workspace") }
        let file = openat(directory,member,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard file>=0 else { unlinkat(directory,member,AT_REMOVEDIR); close(directory); throw BackupFileError.io("Cannot retain backup workspace") }
        var metadata = stat()
        guard fstat(file,&metadata)==0 else { close(file); unlinkat(directory,member,AT_REMOVEDIR); close(directory); throw BackupFileError.io("Cannot inspect backup workspace") }
        let path = URL(fileURLWithPath:parentPath+"/"+member,isDirectory:true)
        let payload: BackupFileTree
        do { payload = try BackupFileTree(takingDirectory:file,root:path,writable:true) }
        catch { unlinkat(directory,member,AT_REMOVEDIR); close(directory); throw error }
        var controlTree: BackupFileTree?, lockFile: Int32 = -1, controlMeta = stat()
        do {
            guard mkdirat(directory,companion,0o700)==0 else { throw BackupFileError.io("Cannot create backup staging lease") }
            let controlFD = openat(directory,companion,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard controlFD>=0 else { throw BackupFileError.io("Cannot retain backup staging lease") }
            guard fstat(controlFD,&controlMeta)==0 else { close(controlFD); throw BackupFileError.io("Cannot inspect backup staging lease") }
            let holder = try BackupFileTree(takingDirectory:controlFD,root:URL(fileURLWithPath:parentPath+"/"+companion,isDirectory:true),writable:true); controlTree = holder
            lockFile = holder.withRootDirectory { openat($0,"lease",O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,0o600) }
            guard lockFile>=0, flock(lockFile,LOCK_EX | LOCK_NB)==0 else { throw BackupFileError.io("Cannot acquire backup staging lease") }
            let marker = BackupWorkspaceMarker(jobID:id,label:label,workspaceName:member,device:metadata.st_dev,inode:metadata.st_ino,pid:getpid(),createdAt:Date().timeIntervalSince1970)
            try holder.write(JSONEncoder().encode(marker),as:"marker.json")
        } catch {
            if lockFile>=0 { close(lockFile) }; try? controlTree?.removeAllChildren(); unlinkat(directory,companion,AT_REMOVEDIR); try? payload.removeAllChildren(); unlinkat(directory,member,AT_REMOVEDIR); close(directory); throw error
        }
        tree = payload; url = path; parent = directory; name = member; device = metadata.st_dev; inode = metadata.st_ino
        control = controlTree!; controlName = companion; controlDevice = controlMeta.st_dev; controlInode = controlMeta.st_ino; lease = lockFile
    }
    static func requireNewDestination(_ destination: URL) throws {
        guard destination.isFileURL,!destination.path.utf8.contains(0),try BackupFileTree.components(destination.lastPathComponent).count==1 else { throw BackupFileError.invalid("Invalid backup destination") }
        var metadata = stat()
        if lstat(destination.path,&metadata)==0 { throw BackupFileError.invalid("Choose a new destination; an existing file or folder will not be overwritten") }
        guard errno==ENOENT else { throw BackupFileError.io("Cannot inspect backup destination") }
    }
    deinit { try? cleanup(); flock(lease,LOCK_UN); close(lease); close(parent) }
    func cleanup() throws {
        if !published {
            var current = stat()
            if fstatat(parent,name,&current,AT_SYMLINK_NOFOLLOW)==0 {
                guard current.st_dev==device,current.st_ino==inode,current.st_mode & S_IFMT==S_IFDIR else { throw BackupFileError.changed("Unpublished backup workspace was replaced") }
                try tree.removeAllChildren(); guard unlinkat(parent,name,AT_REMOVEDIR)==0 else { throw BackupFileError.io("Cannot remove unpublished backup workspace") }
            } else if errno != ENOENT { throw BackupFileError.io("Cannot inspect unpublished backup workspace") }
        }
        var current = stat()
        if fstatat(parent,controlName,&current,AT_SYMLINK_NOFOLLOW)==0 {
            guard current.st_dev==controlDevice,current.st_ino==controlInode else { throw BackupFileError.changed("Backup staging lease directory was replaced") }
            try control.removeAllChildren(); guard unlinkat(parent,controlName,AT_REMOVEDIR)==0 else { throw BackupFileError.io("Cannot remove backup staging lease directory") }
        } else if errno != ENOENT { throw BackupFileError.io("Cannot inspect backup staging lease directory") }
    }
    func publish(as destination: URL) throws {
        guard !published,destination.isFileURL,!destination.path.utf8.contains(0),try BackupFileTree.components(destination.lastPathComponent).count==1 else { throw BackupFileError.invalid("Invalid backup publication path") }
        guard let path = realpath(destination.deletingLastPathComponent().path,nil) else { throw BackupFileError.invalid("Backup publication parent is unavailable") }; defer { free(path) }
        let expected = open(path,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard expected>=0 else { throw BackupFileError.invalid("Cannot open backup publication parent") }; defer { close(expected) }
        var a = stat(), b = stat(), current = stat()
        guard fstat(parent,&a)==0,fstat(expected,&b)==0,a.st_dev==b.st_dev,a.st_ino==b.st_ino,
              fstatat(parent,name,&current,AT_SYMLINK_NOFOLLOW)==0,current.st_dev==device,current.st_ino==inode else { throw BackupFileError.changed("Backup workspace or parent changed before publication") }
        try Task.checkCancellation()
        guard renameatx_np(parent,name,parent,destination.lastPathComponent,UInt32(RENAME_EXCL))==0 else { throw BackupFileError.io("Backup destination exists or cannot be published") }
        published = true
        guard fsync(parent)==0 else { throw BackupFileError.io("Backup was published but its directory could not be flushed") }
    }
    /// Only recognized, private, unlocked jobs whose creator is gone qualify.
    /// A published payload is absent at its old name, so only its lease is removed.
    @discardableResult static func cleanupAbandoned(in parentURL: URL = FileManager.default.temporaryDirectory,
                                                    labels: [String] = operationLabels) throws -> Int {
        guard try labels.allSatisfy({ try BackupFileTree.components($0).count==1 }) else { throw BackupFileError.invalid("Invalid backup cleanup label") }
        let parentTree = try BackupFileTree(root:parentURL); var removed = 0
        try parentTree.forEachEntry(ignoreInvalidNames:true) { name in
            try Task.checkCancellation()
            guard name.hasPrefix(".oswind-job-"),let uuid = UUID(uuidString:String(name.dropFirst(12))),name==".oswind-job-"+uuid.uuidString.lowercased() else { return }
            let parent = parentTree.withRootDirectory { $0 }
            var metadata = stat()
            guard fstatat(parent,name,&metadata,AT_SYMLINK_NOFOLLOW)==0,metadata.st_uid==getuid(),metadata.st_mode & S_IFMT==S_IFDIR,metadata.st_mode & 0o077==0 else { return }
            let root = openat(parent,name,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard root>=0 else { return }
            var openedControl = stat()
            guard fstat(root,&openedControl)==0, openedControl.st_dev==metadata.st_dev, openedControl.st_ino==metadata.st_ino else { close(root); return }
            let holder: BackupFileTree
            do { holder = try BackupFileTree(takingDirectory:root,root:parentURL.appendingPathComponent(name),writable:true) } catch { return }
            let lockFile = holder.withRootDirectory { openat($0,"lease",O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
            guard lockFile>=0 else { return }; defer { close(lockFile) }
            var lockMeta = stat(); guard fstat(lockFile,&lockMeta)==0,lockMeta.st_mode & S_IFMT==S_IFREG,flock(lockFile,LOCK_EX | LOCK_NB)==0 else { return }; defer { flock(lockFile,LOCK_UN) }
            guard let data = try? holder.read("marker.json",limit:4096),let marker = try? JSONDecoder().decode(BackupWorkspaceMarker.self,from:data),
                  marker.format=="OSwind unpublished workspace",marker.version==1,marker.jobID==uuid.uuidString.lowercased(),labels.contains(marker.label),
                  marker.workspaceName=="."+marker.label+"-"+marker.jobID,marker.pid>0,marker.createdAt.isFinite,marker.pid != getpid() else { return }
            errno = 0
            guard kill(marker.pid,0) != 0,errno==ESRCH else { return }
            var workspaceMeta = stat()
            if fstatat(parent,marker.workspaceName,&workspaceMeta,AT_SYMLINK_NOFOLLOW)==0 {
                guard workspaceMeta.st_uid==getuid(),workspaceMeta.st_mode & S_IFMT==S_IFDIR,workspaceMeta.st_mode & 0o077==0,workspaceMeta.st_dev==marker.device,workspaceMeta.st_ino==marker.inode else { return }
                let workspaceFD = openat(parent,marker.workspaceName,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard workspaceFD>=0 else { return }
                var openedPayload = stat()
                guard fstat(workspaceFD,&openedPayload)==0,openedPayload.st_dev==workspaceMeta.st_dev,openedPayload.st_ino==workspaceMeta.st_ino else { close(workspaceFD); return }
                let payload = try BackupFileTree(takingDirectory:workspaceFD,root:parentURL.appendingPathComponent(marker.workspaceName),writable:true)
                try payload.removeAllChildren()
                var currentPayload = stat()
                guard fstatat(parent,marker.workspaceName,&currentPayload,AT_SYMLINK_NOFOLLOW)==0,currentPayload.st_dev==workspaceMeta.st_dev,currentPayload.st_ino==workspaceMeta.st_ino else { throw BackupFileError.changed("Abandoned backup workspace changed during cleanup") }
                guard unlinkat(parent,marker.workspaceName,AT_REMOVEDIR)==0 else { throw BackupFileError.io("Cannot remove abandoned backup workspace") }
            } else if errno != ENOENT { return }
            var now = stat(); guard fstatat(parent,name,&now,AT_SYMLINK_NOFOLLOW)==0,now.st_dev==metadata.st_dev,now.st_ino==metadata.st_ino else { return }
            try holder.removeAllChildren(); guard unlinkat(parent,name,AT_REMOVEDIR)==0 else { throw BackupFileError.io("Cannot remove abandoned backup lease") }; removed += 1
        }
        return removed
    }
}
