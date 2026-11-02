import Foundation
import Darwin
import IOKit
import CSQLite

protocol SyncMachineFingerprint:Sendable {func fingerprint()throws->String}
struct MacSyncMachineFingerprint:SyncMachineFingerprint {
    func fingerprint()throws->String {
        let service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else {throw OSwindError.unavailable("This Mac's local sync binding is unavailable")}
        defer {IOObjectRelease(service)}
        guard let value=IORegistryEntryCreateCFProperty(service,"IOPlatformUUID" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String,
              let uuid=UUID(uuidString:value) else {throw OSwindError.unavailable("This Mac's local sync binding is unavailable")}
        // Keep the hardware identifier out of preferences, packets and logs.
        // This is software admission, not a Secure Enclave/device-only claim.
        return SyncProtocolLimits.hex(Data("OSwind.sync.machine-binding.v1\0\(uuid.uuidString.lowercased())".utf8))
    }
}

enum SyncLocalCredentialState {
    static var root:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("OSwindSync",isDirectory:true)}
    /// Foundation applies directory attributes after creating the directory.
    /// Concurrent creators could therefore observe its transient broader mode.
    /// mkdir installs the private mode atomically; existing directories are
    /// validated rather than chmod'ed into apparent trust.
    static func ensurePrivateDirectory(_ root:URL,depth:Int=0)throws {
        guard root.isFileURL,!root.path.utf8.contains(0),depth<64,root.path != "/" else {throw OSwindError.invalid("Invalid private sync state directory")}
        if mkdir(root.path,0o700) != 0 {
            let code=errno
            if code==ENOENT {
                try ensurePrivateDirectory(root.deletingLastPathComponent(),depth:depth+1)
                try ensurePrivateDirectory(root,depth:depth+1);return
            }
            guard code==EEXIST else {throw OSwindError.unavailable("Cannot create private sync state")}
        }
        _=try BackupFileTree(root:root,writable:true)
    }
    /// Creation is explicit for first enrollment. Existing enrolled libraries
    /// must use create:false: a missing identity is a recovery condition.
    static func installationID(at root:URL,create:Bool)throws->String {
        if create {try ensurePrivateDirectory(root)}
        let tree=try BackupFileTree(root:root,writable:true),member="installation-v1"
        func read()throws->String {
            try tree.requireRootIdentity(at:root)
            let bytes=try tree.read(member,limit:128)
            guard let string=String(data:bytes,encoding:.utf8) else {throw OSwindError.invalid("Invalid saved sync installation identity")}
            let lines=string.split(separator:"\n",omittingEmptySubsequences:false)
            guard lines.count==3,lines[0]=="OSwind.sync.installation.v1",lines[2].isEmpty else {throw OSwindError.invalid("Invalid saved sync installation identity")}
            let id=String(lines[1]);try SyncProtocolLimits.uuid(id);try tree.requireRootIdentity(at:root);return id
        }
        do {return try read()}catch BackupFileError.missing {
            guard create else {throw OSwindError.unavailable("The saved sync installation identity is missing; reconnect through recovery")}
        }
        let bytes=Data("OSwind.sync.installation.v1\n\(UUID().uuidString.lowercased())\n".utf8),temporary=".installation-stage-"+UUID().uuidString.lowercased()
        try tree.withNewFile(temporary) {file in
            try bytes.withUnsafeBytes {buffer in
                var offset=0
                while offset<buffer.count {
                    try Task.checkCancellation()
                    let count=Darwin.write(file,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                    if count<0,errno==EINTR {continue}
                    guard count>0 else {throw OSwindError.unavailable("Cannot save the sync installation identity")};offset+=count
                }
            }
        }
        defer {try? tree.remove(temporary)}
        let result=tree.withRootDirectory {linkat($0,temporary,$0,member,0)}
        guard result==0 || errno==EEXIST else {throw OSwindError.unavailable("Cannot install the sync installation identity")}
        try tree.withRootDirectory {guard fsync($0)==0 else {throw OSwindError.unavailable("Cannot flush the sync installation identity")}}
        return try read()
    }
}

/// Cooperative ownership outside the database/vault. Never unlink a released
/// lock file: reusing an inode could otherwise allow overlapping owners.
final class SyncCredentialExclusiveLease:@unchecked Sendable {
    private let lock=NSLock(),root:URL,member:String,identity:BackupFileStamp
    private var tree:BackupFileTree?,descriptor:Int32 = -1
    init(id:String,stateRoot:URL=SyncLocalCredentialState.root)throws {
        try SyncCredentialStorageLimits.validate(id:id)
        try SyncLocalCredentialState.ensurePrivateDirectory(stateRoot)
        let root=stateRoot.appendingPathComponent("locks",isDirectory:true);try SyncLocalCredentialState.ensurePrivateDirectory(root)
        let tree=try BackupFileTree(root:root,writable:true),member="credential-"+id
        let file=tree.withRootDirectory {openat($0,member,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)}
        guard file>=0 else {throw OSwindError.unavailable("Cannot open sync credential ownership")}
        var retained=false;defer {if !retained {Darwin.close(file)}}
        var stamp=stat()
        guard fstat(file,&stamp)==0,stamp.st_mode&S_IFMT==S_IFREG,stamp.st_uid==getuid(),stamp.st_nlink==1,stamp.st_mode&0o077==0 else {throw OSwindError.invalid("Sync credential ownership file is unsafe")}
        try tree.requireRootIdentity(at:root)
        guard flock(file,LOCK_EX|LOCK_NB)==0 else {throw OSwindError.unavailable("This sync credential is already owned by another open connection")}
        try tree.requireRootIdentity(at:root)
        self.root=root;self.member=member;identity=BackupFileStamp(stamp);self.tree=tree;descriptor=file;retained=true
    }
    deinit {close()}
    func requireCurrentIdentity()throws {
        lock.lock();defer {lock.unlock()}
        guard descriptor>=0,let tree else {throw OSwindError.unavailable("Sync credential ownership is closed")}
        try tree.requireRootIdentity(at:root)
        var current=stat(),named=stat()
        guard fstat(descriptor,&current)==0,tree.withRootDirectory({fstatat($0,member,&named,AT_SYMLINK_NOFOLLOW)})==0,
              current.st_mode&S_IFMT==S_IFREG,named.st_mode&S_IFMT==S_IFREG,current.st_nlink==1,named.st_nlink==1,
              current.st_dev==identity.device,current.st_ino==identity.inode,named.st_dev==current.st_dev,named.st_ino==current.st_ino else {throw OSwindError.unavailable("Sync credential ownership changed; reopen the connection")}
    }
    func close() {
        lock.lock();defer {lock.unlock()}
        guard descriptor>=0 else {return}
        flock(descriptor,LOCK_UN);Darwin.close(descriptor);descriptor = -1;tree=nil
    }
}

struct SyncEnrollmentBinding:Codable,Equatable,Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    let format:String,version:Int,id:String,protection:SyncCredentialProtection
    let machine:String,installation:String,origin:String,generation:String,volume:String,inode:UInt64
    let publicationLifetime:String?
    let group:String,epoch:String,replica:String,rootFingerprint:String
    static func capture(store:MemoryStore,material:SyncCredentialMaterial,id:String,protection:SyncCredentialProtection,machine:any SyncMachineFingerprint,installation:String)throws->Self {
        try SyncCredentialStorageLimits.validate(id:id);try SyncProtocolLimits.uuid(installation)
        let fingerprint=try machine.fingerprint();try SyncProtocolLimits.digest(fingerprint)
        let tree=try BackupFileTree(root:store.root.standardizedFileURL.resolvingSymlinksInPath())
        try tree.requireRootIdentity(at:store.root)
        try tree.withRootDirectory {file in
            var stamp=stat()
            guard fstat(file,&stamp)==0,stamp.st_dev==store.mediaRootIdentity.device,stamp.st_ino==store.mediaRootIdentity.inode else {throw OSwindError.unavailable("The open native library directory was replaced")}
        }
        guard let value=try store.root.resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString,let uuid=UUID(uuidString:value) else {throw OSwindError.unavailable("This filesystem cannot provide a stable sync library identity")}
        let (scope,lifetime)=try store.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
            let scope=try SyncChangeCapture.scope(db)
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-publication-library-lifetime-v1'");defer {sqlite3_finalize(row)}
            let code=sqlite3_step(row);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw db.error()}
            return (scope,code==SQLITE_ROW ? db.text(row,0):nil)
        }}
        let joined=material.joined
        let result=Self(format:"OSwind.sync.library-binding",version:1,id:id,protection:protection,machine:fingerprint,installation:installation,origin:scope.origin,generation:scope.generation,volume:uuid.uuidString.lowercased(),inode:store.mediaRootIdentity.inode,publicationLifetime:lifetime,group:joined.certificate.body.group,epoch:joined.certificate.body.epoch,replica:joined.replica,rootFingerprint:try SyncPairingFormat.fingerprint(joined.certificate.body.rootPublicKey))
        try result.validate();try tree.requireRootIdentity(at:store.root);return result
    }
    func validate()throws {
        guard format=="OSwind.sync.library-binding",version==1,inode>0 else {throw OSwindError.invalid("Invalid saved sync library binding")}
        for value in [id,installation,origin,generation,volume,group,epoch,replica] {try SyncProtocolLimits.uuid(value)}
        try SyncProtocolLimits.digest(machine);try SyncProtocolLimits.digest(rootFingerprint)
        if let lifetime=publicationLifetime {
            let uuid=UUID(uuidString:lifetime)?.uuidString.lowercased()==lifetime
            let hex=lifetime.utf8.count==32 && lifetime.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)})
            guard uuid || hex else {throw OSwindError.invalid("Invalid saved sync publication lifetime")}
        }
    }
    func verify(store:MemoryStore,material:SyncCredentialMaterial,protection:SyncCredentialProtection,machine:any SyncMachineFingerprint,installation:String)throws {
        try validate()
        let current=try Self.capture(store:store,material:material,id:id,protection:protection,machine:machine,installation:installation)
        guard current==self else {throw OSwindError.unavailable("The saved sync identity belongs to a different Mac, installation or library lifetime; use recovery")}
    }
    var description:String {"<redacted sync library binding>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["binding":"redacted"])}
}
