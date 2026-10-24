import Foundation
import Darwin
import CSQLite
import CryptoKit

/// Owns only OSwind-created encrypted-image packages. The public Library path is
/// a closed regular file while detached, preventing accidental plaintext fallback.
public actor LibraryVault {
    let paths:VaultPaths
    private let driver=NativeVaultDriver()
    var acceptedPassphraseDigest:Data?
    private var migrationDetails:VaultMigrationDetails?
    public nonisolated let libraryURL:URL
    public nonisolated let packageURL:URL
    public init(package:URL) throws {let paths=try VaultPaths(package);self.paths=paths;packageURL=paths.package;libraryURL=paths.library}
    public static func package(containing url:URL) throws -> URL? {try VaultAccess.package(containing:url)?.package}
    public static func create(at package:URL,name:String,capacityGiB:Int=128,passphrase:Data,keepUnlocked:Bool=false) async throws -> LibraryVaultStatus {
        let result=try await build(at:package,name:name,capacityGiB:capacityGiB,passphrase:passphrase,keepUnlocked:keepUnlocked,source:nil,progress:{_ in})
        return result.1
    }
    public static func migrate(from source:MemoryStore,to package:URL,name:String,capacityGiB:Int=128,passphrase:Data,keepUnlocked:Bool=false,progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in}) async throws -> LibraryVaultMigrationResult {
        guard try !source.hasPendingLibraryWipeCleanup() else {throw OSwindError.unavailable("Finish library cleanup before copying history into a vault")}
        let original=try BackupFileTree(root:source.root.standardizedFileURL.resolvingSymlinksInPath()),parent=try BackupFileTree(root:package.deletingLastPathComponent())
        guard try !original.isAncestor(of:parent) else {throw OSwindError.invalid("Create the vault outside the original library folder")}
        let result=try await build(at:package,name:name,capacityGiB:capacityGiB,passphrase:passphrase,keepUnlocked:keepUnlocked,source:source,progress:progress)
        guard let details=await result.0.migrationDetails else {throw OSwindError.unavailable("The encrypted copy did not produce a verified snapshot")}
        return .init(status:result.1,snapshot:details.snapshot,sourceStable:details.sourceStable)
    }
    private static func build(at package:URL,name:String,capacityGiB:Int,passphrase:Data,keepUnlocked:Bool,source:MemoryStore?,progress:@escaping @Sendable (LibraryBackupProgress)->Void) async throws -> (LibraryVault,LibraryVaultStatus) {
        try Task.checkCancellation();try validateSecret(passphrase)
        var paths=try VaultPaths(package)
        var info=LibraryVaultInfo(name:name,capacityGiB:capacityGiB,volumeUUID:"00000000-0000-0000-0000-000000000000");try info.validate()
        try BackupWorkspace.requireNewDestination(paths.package)
        guard mkdir(paths.package.path,0o700)==0 else {throw OSwindError.unavailable("Cannot create the encrypted-library package")}
        paths=try VaultPaths(paths.package)
        let lease=try VaultOperationLease(paths:paths);defer {withExtendedLifetime(lease){}}
        try paths.write(info,as:VaultPaths.manifestName);try paths.closeAlias()
        let driver=NativeVaultDriver();try await driver.create(paths:paths,capacityGiB:capacityGiB,secret:passphrase)
        let vault=try LibraryVault(package:paths.package)
        // create owns the operation lease; unlock uses the same implementation
        // without trying to acquire a second exclusive reservation.
        let status=try await vault.openUnderLease(passphrase:passphrase,allowSetup:true,source:source,progress:progress)
        if keepUnlocked {return (vault,status)}
        return (vault,try await vault.closeUnderLease(store:nil))
    }
    public func status() async throws -> LibraryVaultStatus {
        let info=try paths.info(),session=try paths.session(info:info)
        guard let mounted=try await driver.attachment(paths:paths) else {return .init(info:info,state:info.setupComplete ? .locked:.unavailable,libraryPath:paths.library.path,message:info.setupComplete ? "Encrypted volume is detached":"Setup is incomplete. Use the passphrase to finish setup; existing files are preserved.")}
        guard mounted.volumeUUID.caseInsensitiveCompare(info.volumeUUID) == .orderedSame,let session,session.mountLeaf==mounted.mount.lastPathComponent else {return .init(info:info,state:.unavailable,libraryPath:paths.library.path,message:"An attached image does not match a complete managed session. No volume has been detached.",volumeMounted:true)}
        if session.phase == .unlocked,(try? VaultAccess.context(at:paths.library)) != nil {return .init(info:info,state:.unlocked,libraryPath:paths.library.path,message:"Encrypted library is open on this Mac",volumeMounted:true)}
        return .init(info:info,state:session.phase == .closing ? .closing:.opening,libraryPath:paths.library.path,message:"The encrypted volume is still mounted. Finish the current operation or retry locking.",volumeMounted:true)
    }
    public func unlock(passphrase:Data) async throws -> LibraryVaultStatus {
        try Task.checkCancellation();try Self.validateSecret(passphrase);let lease=try VaultOperationLease(paths:paths);defer {withExtendedLifetime(lease){}}
        return try await openUnderLease(passphrase:passphrase,allowSetup:true)
    }
    public func lock(store:MemoryStore?=nil) async throws -> LibraryVaultStatus {
        let lease=try VaultOperationLease(paths:paths);defer {withExtendedLifetime(lease){}}
        return try await closeUnderLease(store:store)
    }
    private func openUnderLease(passphrase:Data,allowSetup:Bool,source:MemoryStore?=nil,progress:@escaping @Sendable (LibraryBackupProgress)->Void={_ in}) async throws -> LibraryVaultStatus {
        var info=try paths.info();let proof:VaultVolumeProof;let attachedHere:Bool
        if let attached=try await driver.attachment(paths:paths) {
            if info.setupComplete,(try? VaultAccess.context(at:paths.library)) != nil {return .init(info:info,state:.unlocked,libraryPath:paths.library.path,message:"Encrypted library is already open",volumeMounted:true)}
            proof=attached;attachedHere=false
        }
        else {
            let nonce=UUID().uuidString.lowercased(),tree=try paths.tree();_ = try tree.privateDirectory(".mounts")
            let mount=paths.mounts.appendingPathComponent(nonce,isDirectory:true)
            guard mkdir(mount.path,0o700)==0 else {throw OSwindError.unavailable("Cannot create a private vault mount directory")}
            proof=try await driver.attach(paths:paths,mount:mount,secret:passphrase);attachedHere=true
        }
        let session=VaultSession(vaultID:info.id,nonce:proof.mount.lastPathComponent,phase:.opening,mountLeaf:proof.mount.lastPathComponent,device:proof.device,volumeUUID:proof.volumeUUID,rootDevice:proof.root.device,rootInode:proof.root.inode,imageDevice:proof.image.device,imageInode:proof.image.inode)
        var sessionWritten=false
        do {
            let incomplete=info.volumeUUID=="00000000-0000-0000-0000-000000000000" && !info.setupComplete
            guard incomplete && allowSetup || proof.volumeUUID.caseInsensitiveCompare(info.volumeUUID) == .orderedSame else {throw OSwindError.invalid("This encrypted volume does not match the vault manifest. No library was opened.")}
            if incomplete {info.volumeUUID=proof.volumeUUID;try paths.write(info,as:VaultPaths.manifestName)}
            try paths.write(session,as:"session.json");sessionWritten=true;try paths.closeAlias()
            let permit=VaultInitializationPermit(package:paths.package,nonce:session.nonce)
            try VaultAccess.$initialization.withValue(permit) {
                let library=proof.mount.appendingPathComponent("Library",isDirectory:true)
                if let source {
                    guard !info.setupComplete,!FileManager.default.fileExists(atPath:library.path) else {throw OSwindError.invalid("Copy history only into a new empty encrypted library")}
                    migrationDetails=try copyHistory(source:source,mount:proof.mount,destination:library,progress:progress)
                } else if !info.setupComplete {
                    var s=stat()
                    if lstat(library.path,&s)==0 {
                        let tree=try BackupFileTree(root:library)
                        let marker=try? JSONDecoder().decode(VaultLibraryMarker.self,from:tree.read(VaultPaths.markerName,limit:65536))
                        if marker?.vaultID != info.id {guard try FileManager.default.contentsOfDirectory(atPath:library.path).isEmpty else {throw OSwindError.invalid("Unrecognized data exists in the incomplete vault. Files were preserved for recovery.")}}
                    } else {guard errno==ENOENT,mkdir(library.path,0o700)==0 else {throw OSwindError.unavailable("Cannot create the encrypted library directory")}}
                }
                let tree=try BackupFileTree(root:library,writable:true)
                if info.setupComplete {
                    let marker=try JSONDecoder().decode(VaultLibraryMarker.self,from:tree.read(VaultPaths.markerName,limit:65536));guard marker.vaultID==info.id else {throw OSwindError.invalid("The encrypted library marker does not match")}
                }
                // Refresh the package location after a user moves a detached
                // package; the volume UUID and vault ID remain the same.
                let marker=VaultLibraryMarker(vaultID:info.id,packagePath:paths.package.path)
                let markerURL=library.appendingPathComponent(VaultPaths.markerName)
                if FileManager.default.fileExists(atPath:markerURL.path) {try tree.remove(VaultPaths.markerName)}
                try tree.write(JSONEncoder().encode(marker),as:VaultPaths.markerName)
                let store=try MemoryStore(root:library);try store.close()
            }
            try Task.checkCancellation()
            info.setupComplete=true;try paths.write(info,as:VaultPaths.manifestName)
            var opened=session;opened.phase = .unlocked;try paths.write(opened,as:"session.json");try paths.openAlias(session:opened)
            _ = try VaultAccess.context(at:paths.library)
            if attachedHere {acceptedPassphraseDigest=Data(SHA256.hash(data:passphrase))}
            return .init(info:info,state:.unlocked,libraryPath:paths.library.path,message:"Encrypted library unlocked",volumeMounted:true)
        } catch {
            acceptedPassphraseDigest=nil
            var closing=session;closing.phase = .closing
            if sessionWritten {try? paths.write(closing,as:"session.json");try? paths.closeAlias()}
            if attachedHere || sessionWritten {
                // Cleanup is deliberately independent of cancellation of the
                // caller. Never leave an owned image open merely because its
                // enclosing task was cancelled; a busy image remains closing.
                let driver=self.driver,paths=self.paths,expected=closing
                let cleanup=Task.detached(priority:.utility) {try await driver.detach(paths:paths,expected:expected)}
                do {try await cleanup.value;if sessionWritten {try? paths.tree().remove("session.json")}} catch {}
            }
            throw error
        }
    }
    private func closeUnderLease(store:MemoryStore?) async throws -> LibraryVaultStatus {
        acceptedPassphraseDigest=nil
        let info=try paths.info()
        guard let proof=try await driver.attachment(paths:paths) else {try paths.closeAlias();if (try paths.session(info:info)) != nil {try paths.tree().remove("session.json")};return .init(info:info,state:.locked,libraryPath:paths.library.path,message:"Encrypted volume is detached")}
        guard proof.volumeUUID.caseInsensitiveCompare(info.volumeUUID) == .orderedSame else {throw OSwindError.invalid("The attached volume does not match. No volume was detached.")}
        var session=VaultSession(vaultID:info.id,nonce:proof.mount.lastPathComponent,phase:.closing,mountLeaf:proof.mount.lastPathComponent,device:proof.device,volumeUUID:proof.volumeUUID,rootDevice:proof.root.device,rootInode:proof.root.inode,imageDevice:proof.image.device,imageInode:proof.image.inode)
        // An explicit lock can recover missing/corrupt/stale session JSON only
        // after independently verifying the owned image, UUID and private mount.
        if let existing=try? paths.session(info:info),existing.nonce==session.nonce,existing.rootDevice==session.rootDevice,existing.rootInode==session.rootInode {session=existing;session.phase = .closing}
        try paths.write(session,as:"session.json")
        if let store,!store.isClosed {
            let resolved=try vaultResolvedURL(store.root).path
            guard resolved==proof.mount.appendingPathComponent("Library").path else {throw OSwindError.invalid("Close the store belonging to this vault")}
            let worker=Task.detached(priority:.utility) {try store.close()}
            try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
        }
        // Close the public handle before detaching its target. Old executables
        // following that handle encounter a regular file, never a fresh folder.
        try paths.closeAlias();try await driver.detach(paths:paths,expected:session);try paths.tree().remove("session.json")
        return .init(info:info,state:.locked,libraryPath:paths.library.path,message:"Encrypted volume is detached")
    }
    private func copyHistory(source:MemoryStore,mount:URL,destination:URL,progress:@escaping @Sendable (LibraryBackupProgress)->Void) throws -> VaultMigrationDetails {
        let activity=try source.mediaWriteLease(),workspace:BackupWorkspace
        do {workspace=try BackupWorkspace(in:mount,label:"oswind-vault-migration",mediaActivity:activity)} catch {activity.release();throw error}
        defer {withExtendedLifetime(workspace){}}
        let initial=try source.vaultMigrationToken();progress(.init(phase:"Copying history into encrypted storage"))
        let archive=workspace.url.appendingPathComponent("Verified.oswindbackup")
        let snapshot=try LibraryBackup.createForVaultMigration(store:source,destination:archive,workspace:workspace,progress:progress)
        let restored=try LibraryBackup.restore(archive,to:destination,expectedFingerprint:snapshot.archiveFingerprint,progress:progress)
        guard restored.memories==snapshot.memories,restored.conversations==snapshot.conversations,restored.turns==snapshot.turns,restored.mediaFiles==snapshot.mediaFiles else {throw OSwindError.invalid("The encrypted copy does not match its verified snapshot")}
        try Task.checkCancellation()
        let stable=try source.vaultMigrationToken()==initial
        let audit:[String:Any]=["format":"OSwind encrypted migration snapshot v1","snapshotCreatedAt":snapshot.createdAt,"sourceStable":stable,"originalRetained":true,"memories":snapshot.memories,"mediaFiles":snapshot.mediaFiles]
        try BackupFileTree(root:destination,writable:true).write(JSONSerialization.data(withJSONObject:audit,options:[.sortedKeys]),as:".oswind-migration.json")
        return .init(snapshot:snapshot,sourceStable:stable)
    }
    static func validateSecret(_ data:Data) throws {
        guard (12...4096).contains(data.count),!data.contains(0),String(data:data,encoding:.utf8) != nil else {throw OSwindError.invalid("Use a UTF-8 passphrase of 12–4096 bytes without NUL characters")}
    }
}

extension MemoryStore {
    func vaultMigrationToken() throws -> String {
        let tree=try BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath())
        let settings:String
        do {settings=try tree.digest("settings.json").sha256} catch BackupFileError.missing {settings="absent"}
        return try withRoutineDatabase {db in
            let row=try db.statement("PRAGMA data_version");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.database("Cannot read migration source revision")}
            return String(sqlite3_column_int64(row,0))+":"+String(sqlite3_total_changes64(db.handle))+":"+settings
        }
    }
}
