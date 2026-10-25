import Foundation
import Darwin

public struct LibraryVaultInfo:Codable,Equatable,Sendable {
    public var format="OSwind encrypted library"
    public var version=1
    public var id:String
    public var name:String
    public var capacityGiB:Int
    public var volumeUUID:String
    public var createdAt:Date
    public var setupComplete:Bool=false
    public var keychainEnabled:Bool
    public var encryption="AES-256 disk image"
    public init(id:String=UUID().uuidString.lowercased(),name:String,capacityGiB:Int,volumeUUID:String,createdAt:Date=Date(),keychainEnabled:Bool=false) {self.id=id;self.name=name;self.capacityGiB=capacityGiB;self.volumeUUID=volumeUUID;self.createdAt=createdAt;self.keychainEnabled=keychainEnabled}
    func validate() throws {
        guard format=="OSwind encrypted library",version==1,UUID(uuidString:id)?.uuidString.lowercased()==id,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=128,!name.utf8.contains(0),(1...4096).contains(capacityGiB),UUID(uuidString:volumeUUID) != nil,createdAt.timeIntervalSince1970.isFinite,encryption=="AES-256 disk image" else {throw OSwindError.invalid("Unsupported or invalid encrypted-library manifest")}
    }
}
public enum LibraryVaultState:String,Codable,Sendable {case locked,unlocked,opening,closing,unavailable}
public struct LibraryVaultStatus:Codable,Sendable {
    public var info:LibraryVaultInfo
    public var state:LibraryVaultState
    public var libraryPath:String
    public var message:String
    public var volumeMounted:Bool=false
    public var imageAttached:Bool=false
    public init(info:LibraryVaultInfo,state:LibraryVaultState,libraryPath:String,message:String,volumeMounted:Bool=false,imageAttached:Bool=false) {self.info=info;self.state=state;self.libraryPath=libraryPath;self.message=message;self.volumeMounted=volumeMounted;self.imageAttached=imageAttached}
}
public struct LibraryVaultMigrationResult:Codable,Sendable {
    public var status:LibraryVaultStatus
    public var snapshot:LibraryBackupInfo
    public var sourceStable:Bool
    public var originalRetained:Bool=true
}
struct VaultMigrationDetails:Sendable {var snapshot:LibraryBackupInfo;var sourceStable:Bool}
struct VaultSession:Codable,Sendable {
    var version=1
    var vaultID:String
    var nonce:String
    var phase:LibraryVaultState
    var mountLeaf:String
    var device:String
    var volumeUUID:String
    var rootDevice:Int32
    var rootInode:UInt64
    var imageDevice:Int32
    var imageInode:UInt64
    func validate(info:LibraryVaultInfo) throws {
        guard version==1,vaultID==info.id,UUID(uuidString:nonce)?.uuidString.lowercased()==nonce,mountLeaf==nonce,[.opening,.unlocked,.closing].contains(phase),device.hasPrefix("/dev/disk"),device.utf8.allSatisfy({(48...57).contains($0)||(97...122).contains($0)||$0==47}),volumeUUID.caseInsensitiveCompare(info.volumeUUID) == .orderedSame,rootInode>0,imageInode>0 else {throw OSwindError.invalid("Encrypted-library session metadata is invalid")}
    }
}
struct VaultLibraryMarker:Codable {
    var format="OSwind managed encrypted library"
    var version=1
    var vaultID:String
    var packagePath:String
}
struct VaultPaths:Sendable {
    static let manifestName="oswind-vault.json"
    static let markerName=".oswind-vault-library.json"
    let package:URL
    private let initialIdentity:BackupFileStamp?
    var image:URL {package.appendingPathComponent("contents.sparsebundle",isDirectory:true)}
    var library:URL {package.appendingPathComponent("Library")}
    var mounts:URL {package.appendingPathComponent(".mounts",isDirectory:true)}
    var manifest:URL {package.appendingPathComponent(Self.manifestName)}
    func mount(_ session:VaultSession) -> URL {mounts.appendingPathComponent(session.mountLeaf,isDirectory:true)}
    init(_ package:URL) throws {
        guard package.isFileURL,!package.path.utf8.contains(0) else {throw OSwindError.invalid("Choose a local encrypted-library package")}
        let standardized=package.standardizedFileURL
        guard let parent=realpath(standardized.deletingLastPathComponent().path,nil) else {throw OSwindError.unavailable("The encrypted-library parent folder is unavailable")};defer {free(parent)}
        self.package=URL(fileURLWithPath:String(cString:parent),isDirectory:true).appendingPathComponent(standardized.lastPathComponent,isDirectory:true)
        var metadata=stat();if lstat(self.package.path,&metadata)==0 {guard metadata.st_mode & S_IFMT==S_IFDIR else {throw OSwindError.invalid("The vault package must be a real directory")};initialIdentity=BackupFileStamp(metadata)} else {guard errno==ENOENT else {throw OSwindError.unavailable("Cannot inspect the vault package")};initialIdentity=nil}
    }
    func tree() throws -> BackupFileTree {let tree=try BackupFileTree(root:package,writable:true);if let initialIdentity {let actual=try tree.identity();guard actual.device==initialIdentity.device,actual.inode==initialIdentity.inode else {throw OSwindError.invalid("The vault package moved or was replaced during the operation")}};return tree}
    func info() throws -> LibraryVaultInfo {let value=try JSONDecoder().decode(LibraryVaultInfo.self,from:tree().read(Self.manifestName,limit:65536));try value.validate();return value}
    func session(info:LibraryVaultInfo) throws -> VaultSession? {
        do {let value=try JSONDecoder().decode(VaultSession.self,from:tree().read("session.json",limit:65536));try value.validate(info:info);return value}
        catch BackupFileError.missing {return nil}
    }
    func write<T:Encodable>(_ value:T,as name:String) throws {
        let tree=try tree(),temporary=".metadata-"+UUID().uuidString.lowercased();try tree.write(JSONEncoder().encode(value),as:temporary)
        var committed=false;defer {if !committed {try? tree.remove(temporary)}}
        try tree.withRootDirectory {fd in
            var old=stat();if fstatat(fd,name,&old,AT_SYMLINK_NOFOLLOW)==0 {guard old.st_mode & S_IFMT==S_IFREG,old.st_uid==getuid(),old.st_nlink==1 else {throw OSwindError.invalid("Encrypted-library metadata was replaced")}}
            else {guard errno==ENOENT else {throw OSwindError.unavailable("Cannot inspect encrypted-library metadata")}}
            guard renameat(fd,temporary,fd,name)==0,fsync(fd)==0 else {throw OSwindError.unavailable("Cannot publish encrypted-library metadata")}
        };committed=true
    }
    func closeAlias() throws {
        let tree=try tree(),temporary=".closed-"+UUID().uuidString.lowercased();try tree.write(Data("OSwind locked encrypted-library handle\n".utf8),as:temporary)
        var committed=false;defer {if !committed {try? tree.remove(temporary)}}
        try tree.withRootDirectory {fd in
            var old=stat();if fstatat(fd,"Library",&old,AT_SYMLINK_NOFOLLOW)==0 {guard old.st_mode & S_IFMT==S_IFLNK || (old.st_mode & S_IFMT==S_IFREG && old.st_uid==getuid() && old.st_nlink==1) else {throw OSwindError.invalid("The encrypted-library handle was replaced")}}
            else {guard errno==ENOENT else {throw OSwindError.unavailable("Cannot inspect the encrypted-library handle")}}
            guard renameat(fd,temporary,fd,"Library")==0,fsync(fd)==0 else {throw OSwindError.unavailable("Cannot close the encrypted-library handle")}
        };committed=true
    }
    func openAlias(session:VaultSession) throws {
        let tree=try tree(),temporary=".opened-"+UUID().uuidString.lowercased(),destination=".mounts/"+session.mountLeaf+"/Library"
        try tree.withRootDirectory {fd in
            guard symlinkat(destination,fd,temporary)==0 else {throw OSwindError.unavailable("Cannot prepare the encrypted-library handle")}
            defer {unlinkat(fd,temporary,0)}
            var current=stat();guard fstatat(fd,"Library",&current,AT_SYMLINK_NOFOLLOW)==0,current.st_mode & S_IFMT==S_IFREG,current.st_uid==getuid(),current.st_nlink==1 else {throw OSwindError.invalid("Close the existing encrypted-library handle before reopening it")}
            guard renameat(fd,temporary,fd,"Library")==0,fsync(fd)==0 else {throw OSwindError.unavailable("Cannot publish the encrypted-library handle")}
        }
    }
}
/// A cross-process operation lock, outside the encrypted image. Never force a
/// competing create/unlock/lock operation; readers do not need this lock.
final class VaultOperationLease {
    private let file:Int32
    init(paths:VaultPaths) throws {
        let tree=try paths.tree(),opened=tree.withRootDirectory {openat($0,".operation.lock",O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)}
        guard opened>=0 else {throw OSwindError.unavailable("Cannot reserve the encrypted library")}
        var s=stat();guard fstat(opened,&s)==0,s.st_mode & S_IFMT==S_IFREG,s.st_uid==getuid(),s.st_nlink==1,s.st_mode & 0o077==0 else {close(opened);throw OSwindError.invalid("Unsafe encrypted-library operation lock")}
        guard flock(opened,LOCK_EX|LOCK_NB)==0 else {close(opened);throw OSwindError.unavailable("Another encrypted-library operation is running. Wait for it to finish.")}
        // Publish ownership only after every throwing check. A fully initialized
        // instance also runs deinit when init throws; an earlier assignment plus
        // manual close can release an unrelated descriptor reused by a thread.
        file=opened
    }
    deinit {flock(file,LOCK_UN);close(file)}
}
