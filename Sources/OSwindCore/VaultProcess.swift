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
struct VaultVolumeProof:Sendable {
    var mount:URL
    var device:String
    var volumeUUID:String
    var root:BackupFileStamp?
    var image:BackupFileStamp
    var attachmentDevice:String
    var reportedImagePath:String
    var mounted:Bool {root != nil}
}
struct NativeVaultDriver:Sendable {
    private func images() async throws -> [[String:Any]] {
        let r=try await VaultProcess.run("/usr/bin/hdiutil",["info","-plist"])
        guard r.status==0,let data=try PropertyListSerialization.propertyList(from:r.stdout,format:nil) as? [String:Any],let images=data["images"] as? [[String:Any]] else {throw OSwindError.unavailable("Cannot inspect encrypted disk attachments")};return images
    }
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
            guard let proof=try await attachment(paths:paths),proof.mounted,proof.mount.standardizedFileURL==mount.standardizedFileURL else {throw OSwindError.invalid("The attached vault did not match its requested location")};return proof
        } catch {
            let driver=self
            let cleanup=Task.detached(priority:.utility) {
                if let proof=try await driver.attachment(paths:paths),proof.mount.standardizedFileURL==mount.standardizedFileURL {try await driver.eject(paths:paths,proof:proof)}
            }
            _=try? await cleanup.value;throw error
        }
    }
    func attachment(paths:VaultPaths) async throws -> VaultVolumeProof? {
        _=try paths.tree()
        let info=try paths.info(),saved=try? paths.session(info:info),prefix=paths.mounts.standardizedFileURL.path+"/"
        let expectedImage=paths.image.standardizedFileURL.resolvingSymlinksInPath()
        let listed=try await images()
        let found=listed.filter { item in
            let byPath=(item["image-path"] as? String).map {URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath()==expectedImage} ?? false
            let entities=item["system-entities"] as? [[String:Any]] ?? []
            let byMount=entities.contains {($0["mount-point"] as? String).map {URL(fileURLWithPath:$0).standardizedFileURL.path.hasPrefix(prefix)} ?? false}
            let byDevice=saved.map {session in entities.contains {$0["dev-entry"] as? String==session.device}} ?? false
            return byPath || byMount || byDevice
        }
        guard !found.isEmpty else {
            // A stale path alone is never proof of detach. Even with no matching
            // attachment, a saved image identity must still match its package.
            if let saved {let stamp=try BackupFileTree(root:paths.image).identity();guard stamp.device==saved.imageDevice,stamp.inode==saved.imageInode else {throw OSwindError.unavailable("The vault image moved or was replaced. Its detached state could not be verified.")}}
            return nil
        }
        guard found.count==1,found[0]["image-encrypted"] as? Bool==true,let entities=found[0]["system-entities"] as? [[String:Any]],let reported=found[0]["image-path"] as? String else {throw OSwindError.invalid("Encrypted disk attachment identity is ambiguous")}
        let backing=entities.filter {$0["content-hint"] as? String=="GUID_partition_scheme"}
        guard backing.count==1,let attachmentDevice=backing[0]["dev-entry"] as? String,attachmentDevice.hasPrefix("/dev/disk") else {throw OSwindError.invalid("Encrypted disk has an unexpected backing device")}
        let mounted=entities.filter {$0["mount-point"] as? String != nil}
        guard mounted.count<=1 else {throw OSwindError.invalid("Encrypted disk has an unexpected volume layout")}
        let volume:[String:Any],url:URL,root:BackupFileStamp?
        if let current=mounted.first,let mount=current["mount-point"] as? String {
            volume=current;url=URL(fileURLWithPath:mount,isDirectory:true)
            guard url.standardizedFileURL.path.hasPrefix(prefix),UUID(uuidString:url.lastPathComponent)?.uuidString.lowercased()==url.lastPathComponent else {throw OSwindError.invalid("The vault is mounted outside its managed session directory")}
            root=try BackupFileTree(root:url).identity()
        } else {
            let volumes=entities.filter {$0["content-hint"] as? String=="41504653-0000-11AA-AA11-00306543ECAC"}
            guard !volumes.isEmpty else {throw VaultAttachmentObservationError.unmountedVolumePending}
            guard volumes.count==1 else {throw OSwindError.invalid("The attached unmounted APFS volume is ambiguous")}
            volume=volumes[0];url=saved.map {paths.mount($0)} ?? paths.mounts;root=nil
        }
        guard let device=volume["dev-entry"] as? String,device.hasPrefix("/dev/disk") else {throw OSwindError.invalid("Cannot identify the encrypted volume device")}
        let disk=try await VaultProcess.run("/usr/sbin/diskutil",["info","-plist",device])
        guard disk.status==0,let metadata=try PropertyListSerialization.propertyList(from:disk.stdout,format:nil) as? [String:Any],let uuid=metadata["VolumeUUID"] as? String,UUID(uuidString:uuid) != nil,metadata["FilesystemType"] as? String=="apfs",metadata["DeviceIdentifier"] as? String==String(device.dropFirst(5)) else {throw OSwindError.invalid("Cannot verify the attached APFS volume")}
        let stamp=try BackupFileTree(root:paths.image).identity(),matchesPath=URL(fileURLWithPath:reported).standardizedFileURL.resolvingSymlinksInPath()==expectedImage
        if !matchesPath {
            guard let saved,device==saved.device,uuid.caseInsensitiveCompare(info.volumeUUID) == .orderedSame,stamp.device==saved.imageDevice,stamp.inode==saved.imageInode else {throw OSwindError.invalid("A moved image could not be bound to this vault session")}
            if let root {guard url.lastPathComponent==saved.mountLeaf,root.device==saved.rootDevice,root.inode==saved.rootInode else {throw OSwindError.invalid("The moved volume does not match its saved mount identity")}}
        }
        if root != nil {
            // Disk Arbitration may retain the pre-rename MountPoint. Kernel
            // statfs and the recorded device/UUID prove the actual current path.
            var filesystem=statfs();guard statfs(url.path,&filesystem)==0 else {throw OSwindError.unavailable("Cannot inspect the mounted encrypted filesystem")}
            var source=filesystem.f_mntfromname,target=filesystem.f_mntonname
            let sourceCapacity=MemoryLayout.size(ofValue:source),targetCapacity=MemoryLayout.size(ofValue:target)
            let from=withUnsafePointer(to:&source) {$0.withMemoryRebound(to:CChar.self,capacity:sourceCapacity) {String(cString:$0)}}
            let on=withUnsafePointer(to:&target) {$0.withMemoryRebound(to:CChar.self,capacity:targetCapacity) {String(cString:$0)}}
            guard from==device,URL(fileURLWithPath:on).standardizedFileURL==url.standardizedFileURL else {throw OSwindError.invalid("The kernel mount does not match the encrypted volume")}
        }
        return .init(mount:url,device:device,volumeUUID:uuid,root:root,image:stamp,attachmentDevice:attachmentDevice,reportedImagePath:reported)
    }
    private func same(_ a:VaultVolumeProof,_ b:VaultVolumeProof,allowUnmounted:Bool=false) -> Bool {
        let roots:Bool
        if let first=a.root,let second=b.root {roots=first.device==second.device && first.inode==second.inode && a.mount==b.mount}
        else {roots=(a.root==nil && b.root==nil) || (allowUnmounted && b.root==nil)}
        return roots && a.device==b.device && a.attachmentDevice==b.attachmentDevice && a.volumeUUID==b.volumeUUID && a.image.device==b.image.device && a.image.inode==b.image.inode
    }
    func detach(paths:VaultPaths,expected:VaultSession) async throws {
        guard let current=try await attachment(paths:paths) else {return}
        guard current.device==expected.device,current.volumeUUID.caseInsensitiveCompare(expected.volumeUUID) == .orderedSame,current.image.device==expected.imageDevice,current.image.inode==expected.imageInode else {throw OSwindError.invalid("The attached vault changed. No volume was detached.")}
        if let root=current.root {guard current.mount.standardizedFileURL==paths.mount(expected).standardizedFileURL,root.device==expected.rootDevice,root.inode==expected.rootInode else {throw OSwindError.invalid("The mounted vault changed. No volume was detached.")}}
        try await eject(paths:paths,proof:current)
    }
    func eject(paths:VaultPaths,proof:VaultVolumeProof) async throws {
        guard let verified=try await attachment(paths:paths) else {return}
        guard same(proof,verified) else {throw OSwindError.invalid("The image changed before detach; no volume was detached")}
        let identity=try VaultDetachIdentity(paths:paths,image:verified.image)
        let first=try await VaultProcess.run("/usr/bin/hdiutil",["detach",verified.attachmentDevice],timeout:30)
        if first.status != 0 {
            // A renamed mounted package can have a stale Disk Arbitration path.
            // A normal kernel unmount uses the freshly verified current mount.
            // EBUSY remains EBUSY; force flags are never used.
            guard verified.mounted,URL(fileURLWithPath:verified.reportedImagePath).standardizedFileURL.resolvingSymlinksInPath() != paths.image.standardizedFileURL.resolvingSymlinksInPath(),let current=try await attachment(paths:paths),same(verified,current) else {throw OSwindError.unavailable("The vault is still attached because files are in use. Close other readers and retry locking.")}
            let unmount=try await VaultProcess.run("/sbin/umount",[current.mount.path],timeout:30)
            guard unmount.status==0 else {throw OSwindError.unavailable("The moved vault is still mounted because files are in use. Close other readers and retry locking.")}
            guard let unmounted=try await attachment(paths:paths),!unmounted.mounted,same(verified,unmounted,allowUnmounted:true) else {throw OSwindError.invalid("The unmounted attachment changed. Its remaining device was preserved.")}
            let final=try await VaultProcess.run("/usr/bin/hdiutil",["detach",unmounted.attachmentDevice],timeout:30)
            guard final.status==0 else {throw OSwindError.unavailable("The filesystem is unmounted but its encrypted image is still attached. Retry locking.")}
        }
        try await VaultDetachSettlement.confirm {
            try identity.validate()
            let observed=try await attachment(paths:paths)
            // Revalidate after native IPC even when the OS now reports absent.
            try identity.validate()
            guard let observed else {return true}
            guard same(verified,observed,allowUnmounted:true) else {throw OSwindError.invalid("The attachment changed during detach verification")}
            return false
        }
    }
}
