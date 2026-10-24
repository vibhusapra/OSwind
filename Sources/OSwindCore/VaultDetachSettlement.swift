import Foundation

/// A known image can briefly remain in hdiutil's inventory after a successful
/// detach while its APFS volume entity is already gone. This is not proof of lock.
enum VaultAttachmentObservationError:LocalizedError {
    case unmountedVolumePending
    var errorDescription:String? {"Cannot identify the attached unmounted APFS volume"}
}

/// Retry observation only, after a successful normal detach. It never performs
/// another detach or turns an unknown/changed identity into a locked state.
/// Success requires two consecutive fresh absent observations. The first retry
/// remains 50 ms; later pauses back off to 1 second, totaling at most 11.55 s
/// across 16 observations. Native inspections retain their separate deadlines.
enum VaultDetachSettlement {
    static func delayMilliseconds(_ attempt:Int)->Int {min(1000,50 << min(5,max(0,attempt)))}
    static func confirm(attempts:Int=16,
                        pause:@Sendable (Int) async throws ->Void={attempt in try await Task.sleep(for:.milliseconds(delayMilliseconds(attempt)))},
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
    let paths:VaultPaths,image:BackupFileStamp,package:BackupFileStamp,vaultID:String,volumeUUID:String,setupComplete:Bool
    init(paths:VaultPaths,image:BackupFileStamp) throws {
        self.paths=paths;self.image=image;package=try paths.tree().identity()
        let info=try paths.info();vaultID=info.id;volumeUUID=info.volumeUUID;setupComplete=info.setupComplete
        try validate()
    }
    func validate() throws {
        let currentPackage=try paths.tree().identity()
        guard currentPackage.device==package.device,currentPackage.inode==package.inode else {throw OSwindError.invalid("The vault package changed during detach verification")}
        let info=try paths.info(),current=try BackupFileTree(root:paths.image).identity()
        guard info.id==vaultID,info.volumeUUID.caseInsensitiveCompare(volumeUUID) == .orderedSame,info.setupComplete==setupComplete,
              current.device==image.device,current.inode==image.inode else {throw OSwindError.invalid("The vault identity changed during detach verification")}
    }
}
