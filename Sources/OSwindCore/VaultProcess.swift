import Foundation
import Darwin

struct VaultProcessResult:Sendable {var status:Int32;var stdout:Data;var stderr:Data}
/// Native helper output may include paths, but never emit the passphrase or
/// command output into public logs. No shell, environment password or key argv.
enum VaultProcess {
    static func run(_ executable:String,_ arguments:[String],secret:Data?=nil,timeout:Double=60) async throws -> VaultProcessResult {
        if let secret {guard !secret.isEmpty,secret.count<=4096,!secret.contains(0) else {throw OSwindError.invalid("Use a nonempty passphrase without NUL characters")}}
        let job=Task.detached(priority:.utility) {() throws -> VaultProcessResult in
            try Task.checkCancellation()
            let process=Process(),input=Pipe(),output=Pipe(),error=Pipe();process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments;process.standardInput=input;process.standardOutput=output;process.standardError=error
            let stdout=VaultPipeBuffer(),stderr=VaultPipeBuffer()
            defer {try? output.fileHandleForReading.close();try? error.fileHandleForReading.close()}
            try process.run()
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate();let deadline=ProcessInfo.processInfo.systemUptime+2
                    while process.isRunning && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
                    if process.isRunning {kill(process.processIdentifier,SIGKILL)}
                    while process.isRunning {Thread.sleep(forTimeInterval:0.01)}
                }
            }
            try output.fileHandleForWriting.close();try error.fileHandleForWriting.close()
            for file in [output.fileHandleForReading,error.fileHandleForReading] {_ = fcntl(file.fileDescriptor,F_SETFL,fcntl(file.fileDescriptor,F_GETFL)|O_NONBLOCK)}
            func drain(_ handle:FileHandle,_ buffer:VaultPipeBuffer) {
                var bytes=[UInt8](repeating:0,count:16384),total=0
                while total<256*1024 {
                    let count=read(handle.fileDescriptor,&bytes,bytes.count)
                    guard count>0 else {break};buffer.append(Data(bytes.prefix(count)));total+=count
                }
            }
            if let secret {
                guard !secret.isEmpty,secret.count<=4096,!secret.contains(0) else {throw OSwindError.invalid("Use a nonempty passphrase without NUL characters")}
                var payload=secret;payload.append(0);try input.fileHandleForWriting.write(contentsOf:payload);payload.resetBytes(in:0..<payload.count)
            }
            try input.fileHandleForWriting.close();try input.fileHandleForReading.close()
            let deadline=ContinuousClock.now.advanced(by:.seconds(timeout))
            while process.isRunning {drain(output.fileHandleForReading,stdout);drain(error.fileHandleForReading,stderr);guard !stdout.oversized,!stderr.oversized else {throw OSwindError.unavailable("Encrypted-library system output exceeded its limit")};try Task.checkCancellation();guard ContinuousClock.now<deadline else {throw OSwindError.unavailable("Encrypted-library system operation timed out. Check its status before retrying.")};Thread.sleep(forTimeInterval:0.02)}
            for _ in 0..<32 {drain(output.fileHandleForReading,stdout);drain(error.fileHandleForReading,stderr)}
            guard !stdout.oversized,!stderr.oversized else {throw OSwindError.unavailable("Encrypted-library system output exceeded its limit")}
            try Task.checkCancellation();return .init(status:process.terminationStatus,stdout:stdout.data,stderr:stderr.data)
        }
        return try await withTaskCancellationHandler {try await job.value} onCancel:{job.cancel()}
    }
}
private final class VaultPipeBuffer:@unchecked Sendable {
    private let lock=NSLock();private var bytes=Data();private var overflow=false
    func append(_ data:Data) {lock.lock();defer {lock.unlock()};if bytes.count+data.count<=4*1024*1024 {bytes.append(data)} else {overflow=true}}
    var data:Data {lock.lock();defer {lock.unlock()};return bytes}
    var oversized:Bool {lock.lock();defer {lock.unlock()};return overflow}
}
struct VaultVolumeProof:Sendable {var mount:URL;var device:String;var volumeUUID:String;var root:BackupFileStamp;var image:BackupFileStamp}
struct NativeVaultDriver:Sendable {
    func create(paths:VaultPaths,capacityGiB:Int,secret:Data) async throws {
        let result=try await VaultProcess.run("/usr/bin/hdiutil",["create","-size","\(capacityGiB)g","-type","SPARSEBUNDLE","-fs","APFS","-encryption","AES-256","-volname","OSwind Private Library","-uid",String(getuid()),"-gid",String(getgid()),"-mode","0700","-stdinpass",paths.image.path],secret:secret,timeout:120)
        guard result.status==0 else {throw OSwindError.unavailable("The encrypted disk image could not be created. The incomplete package remains available for inspection.")}
    }
    func encrypted(paths:VaultPaths) async throws -> Bool {
        let r=try await VaultProcess.run("/usr/bin/hdiutil",["isencrypted","-plist",paths.image.path]);guard r.status==0,let p=try PropertyListSerialization.propertyList(from:r.stdout,format:nil) as? [String:Any] else {throw OSwindError.invalid("Cannot verify encrypted disk image")};return p["encrypted"] as? Bool==true
    }
    func attach(paths:VaultPaths,mount:URL,secret:Data) async throws -> VaultVolumeProof {
        guard try await encrypted(paths:paths) else {throw OSwindError.invalid("The selected disk image is not encrypted")}
        do {
            let r=try await VaultProcess.run("/usr/bin/hdiutil",["attach","-nobrowse","-noautoopen","-owners","on","-mountpoint",mount.path,"-stdinpass","-plist",paths.image.path],secret:secret,timeout:120)
            guard r.status==0 else {throw OSwindError.unavailable("The vault could not be unlocked. Check the passphrase and image availability.")}
            guard let proof=try await attachment(paths:paths),proof.mount.standardizedFileURL==mount.standardizedFileURL else {throw OSwindError.invalid("The attached vault did not match its requested location")};return proof
        } catch {
            // The helper may have mounted successfully just before cancellation
            // was observed. Inspect and compensate on an uncancelled task, but
            // only for this fresh, exact requested private mount path.
            let driver=self
            let cleanup=Task.detached(priority:.utility) {
                if let proof=try await driver.attachment(paths:paths),proof.mount.standardizedFileURL==mount.standardizedFileURL {try await driver.eject(paths:paths,proof:proof)}
            }
            _=try? await cleanup.value;throw error
        }
    }
    func attachment(paths:VaultPaths) async throws -> VaultVolumeProof? {
        _ = try paths.tree()
        let r=try await VaultProcess.run("/usr/bin/hdiutil",["info","-plist"]);guard r.status==0,let data=try PropertyListSerialization.propertyList(from:r.stdout,format:nil) as? [String:Any],let images=data["images"] as? [[String:Any]] else {throw OSwindError.unavailable("Cannot inspect encrypted disk attachments")}
        let found=images.filter {($0["image-path"] as? String).map {URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath()==paths.image.standardizedFileURL.resolvingSymlinksInPath()} ?? false}
        guard !found.isEmpty else {return nil};guard found.count==1,found[0]["image-encrypted"] as? Bool==true,let entities=found[0]["system-entities"] as? [[String:Any]] else {throw OSwindError.invalid("Encrypted disk attachment identity is ambiguous")}
        let volumes=entities.filter {$0["mount-point"] as? String != nil};guard volumes.count==1,let mount=volumes[0]["mount-point"] as? String,let device=volumes[0]["dev-entry"] as? String,device.hasPrefix("/dev/disk") else {throw OSwindError.invalid("Encrypted disk has an unexpected volume layout")}
        let url=URL(fileURLWithPath:mount,isDirectory:true),prefix=paths.mounts.standardizedFileURL.path+"/";guard url.standardizedFileURL.path.hasPrefix(prefix),UUID(uuidString:url.lastPathComponent)?.uuidString.lowercased()==url.lastPathComponent else {throw OSwindError.invalid("The vault is mounted outside its managed session directory")}
        let disk=try await VaultProcess.run("/usr/sbin/diskutil",["info","-plist",device]);guard disk.status==0,let metadata=try PropertyListSerialization.propertyList(from:disk.stdout,format:nil) as? [String:Any],let uuid=metadata["VolumeUUID"] as? String,UUID(uuidString:uuid) != nil,metadata["FilesystemType"] as? String=="apfs",metadata["MountPoint"] as? String==url.path else {throw OSwindError.invalid("Cannot verify the mounted vault volume")}
        return .init(mount:url,device:device,volumeUUID:uuid,root:try BackupFileTree(root:url).identity(),image:try BackupFileTree(root:paths.image).identity())
    }
    func detach(paths:VaultPaths,expected:VaultSession) async throws {
        guard let current=try await attachment(paths:paths) else {return}
        guard current.mount.standardizedFileURL==paths.mount(expected).standardizedFileURL,current.device==expected.device,current.volumeUUID.caseInsensitiveCompare(expected.volumeUUID) == .orderedSame,current.root.device==expected.rootDevice,current.root.inode==expected.rootInode,current.image.device==expected.imageDevice,current.image.inode==expected.imageInode else {throw OSwindError.invalid("The mounted vault changed. No volume was detached.")}
        try await eject(paths:paths,proof:current)
    }
    private func eject(paths:VaultPaths,proof:VaultVolumeProof) async throws {
        guard let verified=try await attachment(paths:paths) else {return}
        guard verified.mount==proof.mount,verified.device==proof.device,verified.volumeUUID==proof.volumeUUID,verified.root.device==proof.root.device,verified.root.inode==proof.root.inode,verified.image.device==proof.image.device,verified.image.inode==proof.image.inode else {throw OSwindError.invalid("The image changed before detach; no volume was detached")}
        let r=try await VaultProcess.run("/usr/bin/hdiutil",["detach",verified.mount.path],timeout:30)
        guard r.status==0 else {throw OSwindError.unavailable("The vault is still mounted because files are in use. Close other readers and retry locking.")}
        guard try await attachment(paths:paths)==nil else {throw OSwindError.unavailable("The vault is still mounted. Retry locking.")}
    }
}
