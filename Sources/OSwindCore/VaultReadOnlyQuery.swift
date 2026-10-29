import Foundation
import Darwin

/// A verified SIGINT can interrupt a native query during launch. Discard that
/// attempt's output and allow one fresh observation, never another mutation.
/// Both attempts share one deadline and are fenced by the caller's identity.
enum VaultReadOnlyQuery {
    static func run(operation:VaultNativeOperation,timeout:Double=60,
                    validate:@Sendable () throws ->Void,
                    now:@Sendable () ->ContinuousClock.Instant={ContinuousClock.now},
                    query:@Sendable (Double) async throws ->VaultProcessResult) async throws ->VaultProcessResult {
        try Task.checkCancellation()
        guard [.attachmentInventory,.encryptionProbe,.volumeInfo].contains(operation) else {
            throw OSwindError.invalid("Only read-only vault queries can recover from an interrupt")
        }
        guard timeout.isFinite,timeout>0,timeout<=60 else {throw OSwindError.invalid("Invalid vault query deadline")}
        let deadline=now().advanced(by:.seconds(timeout))
        func remaining() throws ->Double {
            let value=now().duration(to:deadline).components
            let seconds=Double(value.seconds)+Double(value.attoseconds)/1e18
            guard seconds>0 else {throw OSwindError.unavailable("Encrypted-library system query timed out. Check its status before retrying.")}
            return min(timeout,seconds)
        }
        func fence() throws {try Task.checkCancellation();try validate();try Task.checkCancellation()}
        for attempt in 0..<2 {
            try fence()
            let result=try await query(remaining())
            try fence();_ = try remaining()
            if attempt==0,result.termination == .signal,result.status==SIGINT {continue}
            return result
        }
        preconditionFailure("Bounded native query returned no result")
    }
}

/// Read-only IPC may span an interrupted attempt. Package and manifest identity
/// and the image directory inode must remain bound across every attempt. Image
/// contents/mtime may change normally; a genuinely absent image is supported
/// only as the same absent state, never as inferred encryption or lock proof.
struct VaultQueryIdentity:Sendable {
    let paths:VaultPaths,info:LibraryVaultInfo
    private let package:BackupFileStamp,image:BackupFileStamp?
    init(paths:VaultPaths) throws {
        self.paths=paths
        let tree=try paths.tree();package=try tree.identity();info=try paths.info()
        image=try Self.imageIdentity(in:tree)
        try validate()
    }
    private static func imageIdentity(in tree:BackupFileTree) throws ->BackupFileStamp? {
        try tree.withRootDirectory {descriptor in
            var metadata=stat()
            if fstatat(descriptor,"contents.sparsebundle",&metadata,AT_SYMLINK_NOFOLLOW)==0 {
                guard metadata.st_mode & S_IFMT==S_IFDIR else {throw OSwindError.invalid("The encrypted image must remain a real directory")}
                return BackupFileStamp(metadata)
            }
            guard errno==ENOENT else {throw OSwindError.unavailable("Cannot inspect the encrypted image identity")}
            return nil
        }
    }
    func validate() throws {
        let tree=try paths.tree(),current=try tree.identity(),currentImage=try Self.imageIdentity(in:tree)
        let sameImage:Bool
        switch (image,currentImage) {
        case (nil,nil):sameImage=true
        case let (.some(first),.some(second)):sameImage=first.device==second.device && first.inode==second.inode
        default:sameImage=false
        }
        guard current.device==package.device,current.inode==package.inode,sameImage,try paths.info()==info else {
            throw OSwindError.invalid("The vault identity changed during a system query; its protected state is unconfirmed")
        }
    }
}
