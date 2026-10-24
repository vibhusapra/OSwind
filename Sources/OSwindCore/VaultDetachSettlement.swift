import Foundation

/// A known image can briefly remain in hdiutil's inventory after a successful
/// detach while its APFS volume entity is already gone. This is not proof of lock.
enum VaultAttachmentObservationError:LocalizedError {
    case unmountedVolumePending
    var errorDescription:String? {"Cannot identify the attached unmounted APFS volume"}
}

/// Retry observation only, after a successful normal detach. It never performs
/// another detach or turns an unknown/changed identity into a locked state.
/// Success requires two consecutive fresh absent observations.
enum VaultDetachSettlement {
    static func confirm(attempts:Int=8,
                        pause:@Sendable (Int) async throws ->Void={_ in try await Task.sleep(for:.milliseconds(50))},
                        inspect:@Sendable () async throws ->Bool) async throws {
        guard (1...16).contains(attempts) else {throw OSwindError.invalid("Invalid detach verification budget")}
        var consecutiveAbsences=0
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                let absent=try await inspect();try Task.checkCancellation()
                consecutiveAbsences=absent ? consecutiveAbsences+1:0
                if consecutiveAbsences==2 {return}
            } catch VaultAttachmentObservationError.unmountedVolumePending {consecutiveAbsences=0}
            try Task.checkCancellation()
            if attempt+1<attempts {try await pause(attempt)}
        }
        throw OSwindError.unavailable("The encrypted image detach could not be verified yet. Retry locking.")
    }
}

/// The image directory can change its contents during detach, but its inode,
/// package and manifest identity cannot change during a verified operation.
struct VaultDetachIdentity:Sendable {
    let paths:VaultPaths,image:BackupFileStamp,vaultID:String,volumeUUID:String,setupComplete:Bool
    init(paths:VaultPaths,image:BackupFileStamp) throws {
        self.paths=paths;self.image=image
        let info=try paths.info();vaultID=info.id;volumeUUID=info.volumeUUID;setupComplete=info.setupComplete
        try validate()
    }
    func validate() throws {
        _ = try paths.tree();let info=try paths.info(),current=try BackupFileTree(root:paths.image).identity()
        guard info.id==vaultID,info.volumeUUID.caseInsensitiveCompare(volumeUUID) == .orderedSame,info.setupComplete==setupComplete,
              current.device==image.device,current.inode==image.inode else {throw OSwindError.invalid("The vault identity changed during detach verification")}
    }
}
