import Foundation

enum VaultNativeOperation:String,Codable,Sendable {
    case attachmentInventory,encryptionProbe,volumeInfo,imageDetach,filesystemUnmount
    var tool:String {switch self {case .volumeInfo:return "diskutil";case .filesystemUnmount:return "umount";default:return "hdiutil"}}
    var mutates:Bool {self == .imageDetach || self == .filesystemUnmount}
}

/// Safe to retain with an error: no arguments, paths, UUIDs, credentials, native
/// output text or timestamps. A nonzero native status is not proof of EBUSY.
struct VaultNativeSummary:Codable,Equatable,Sendable {
    let operation:VaultNativeOperation,status:Int32,stdoutBytes:Int,stderrBytes:Int,stdoutSHA256:String,stderrSHA256:String
    let termination:VaultProcessTermination
    init(operation:VaultNativeOperation,result:VaultProcessResult) {
        self.operation=operation;status=result.status;stdoutBytes=result.stdout.count;stderrBytes=result.stderr.count
        termination=result.termination
        stdoutSHA256=BackupSHA256.hex(result.stdout);stderrSHA256=BackupSHA256.hex(result.stderr)
    }
}

/// Explicit internal observation for owned fixtures only. Inventory/device
/// stdout is never included: it may contain unrelated user image metadata.
/// Public LibraryVault entry points install no observer and emit no trace.
struct VaultNativeDiagnostic:Codable,Sendable {
    let summary:VaultNativeSummary,stdoutSuffix:String?,stderrSuffix:String,durationSeconds:Double
    init(operation:VaultNativeOperation,result:VaultProcessResult,durationSeconds:Double=0) {
        summary=VaultNativeSummary(operation:operation,result:result)
        self.durationSeconds=durationSeconds
        stdoutSuffix=operation.mutates ? String(decoding:result.stdout.suffix(4096),as:UTF8.self):nil
        stderrSuffix=String(decoding:result.stderr.suffix(4096),as:UTF8.self)
    }
}

struct VaultNativeFailure:Error,LocalizedError,CustomStringConvertible,CustomDebugStringConvertible,Sendable {
    let summary:VaultNativeSummary,invalidOutput:Bool
    init(operation:VaultNativeOperation,result:VaultProcessResult,invalidOutput:Bool=false) {
        summary=VaultNativeSummary(operation:operation,result:result);self.invalidOutput=invalidOutput
    }
    var errorDescription:String? {
        let code="\(summary.operation.tool) \(summary.termination.label) \(summary.status)"
        switch summary.operation {
        case .attachmentInventory:return "Cannot inspect encrypted disk attachments (\(code)\(invalidOutput ? ", invalid inventory":"")). Check vault status before retrying."
        case .volumeInfo:return "Cannot verify the attached APFS volume (\(code)\(invalidOutput ? ", invalid volume information":"")). Its protected state is unconfirmed."
        case .encryptionProbe:return "Cannot verify encrypted disk image (\(code)\(invalidOutput ? ", invalid encryption information":""))."
        case .imageDetach:return "The encrypted-image detach action failed (\(code)). If files are in use, close those readers and retry locking. Check vault status before assuming it is locked."
        case .filesystemUnmount:return "The filesystem unmount action reported an error (\(code)). If files are in use, close those readers and retry locking. Check vault status before assuming it is locked."
        }
    }
    var description:String {errorDescription!}
    var debugDescription:String {description}
}
