import Foundation
import CryptoKit
import Darwin

/// Real retained-file adapter. The owner holds a media lease and current settings
/// admission throughout each call. Only encrypted chunks enter the local inbox.
struct SyncServiceMedia {
    let library:MemoryStore
    let inbox:SyncObjectFolder
    let policy:SyncServicePolicy
    var maximumAssetBytes:Int64=512*1024*1024

    func prepare(_ memory:Memory)throws->[SyncMediaManifest] {
        try policy.admit(memory)
        let files:[(SyncMediaRole,String?)]=[(.image,memory.imagePath),(.audio,memory.audioPath),(.video,memory.videoPath)]
        let tree=try BackupFileTree(root:library.root.standardizedFileURL.resolvingSymlinksInPath())
        try library.requireMediaRootIdentity()
        var result=[SyncMediaManifest]()
        for (role,path) in files {
            guard let path else {continue}
            try requirePath(path,role:role)
            let manifest=try tree.withFile(path) {file,initial -> SyncMediaManifest in
                guard initial.bytes>0,initial.bytes<=maximumAssetBytes else {throw OSwindError.unavailable("Sync asset exceeds the configured transfer bound")}
                var hash=SHA256(),chunks=[SyncContentReference](),remaining=initial.bytes
                while remaining>0 {
                    let data=try read(file,count:Int(min(remaining,Int64(SyncMediaManifest.chunkBytes))))
                    hash.update(data:data);remaining-=Int64(data.count)
                    let reference=try SyncContentReference(data:data)
                    try inbox.publishContent(data,reference:reference);chunks.append(reference)
                }
                var final=stat()
                guard fstat(file,&final)==0,BackupFileStamp(final)==initial else {throw OSwindError.unavailable("Sync source media changed during preparation")}
                return .init(role:role,sha256:hash.finalize().map{String(format:"%02x",$0)}.joined(),bytes:initial.bytes,chunks:chunks)
            }
            try manifest.validate()
            // Reopen the named member as well as checking the original fd: an
            // atomic replacement can leave the original descriptor unchanged.
            let named=try tree.digest(path,limit:manifest.bytes)
            guard named.sha256==manifest.sha256,named.bytes==manifest.bytes else {throw OSwindError.unavailable("Named sync media changed during preparation")}
            result.append(manifest)
        }
        try tree.requireRootIdentity(at:library.root)
        return result.sorted {$0.role.rawValue<$1.role.rawValue}
    }

    /// Adopt one verified asset atomically into the ordinary native media tree.
    /// Failed transactions may leave an unreferenced content-addressed file;
    /// native whole-library cleanup inventories those files like other media.
    func paths(_ reference:SyncVersionReference,_ manifests:[SyncMediaManifest],fetch:(SyncContentReference)throws->Data)throws->[SyncMediaRole:String] {
        try reference.validate(.source)
        guard manifests.count<=3,Set(manifests.map(\.role)).count==manifests.count else {throw OSwindError.invalid("Sync media roles differ")}
        let tree=try BackupFileTree(root:library.root.standardizedFileURL.resolvingSymlinksInPath(),writable:true)
        try library.requireMediaRootIdentity()
        var paths=[SyncMediaRole:String]()
        for manifest in manifests {
            try manifest.validate()
            guard manifest.bytes<=maximumAssetBytes else {throw OSwindError.unavailable("Sync asset exceeds the configured transfer bound")}
            let bucket=Self.bucket(manifest.role),name="sync-"+manifest.sha256+Self.suffix(manifest.role),path=bucket+"/"+name
            let directory=try tree.privateDirectory(bucket)
            do {
                let existing=try directory.digest(name,limit:manifest.bytes)
                guard existing.sha256==manifest.sha256,existing.bytes==manifest.bytes else {throw OSwindError.invalid("Existing sync media differs from its content address")}
            } catch BackupFileError.missing {
                let temporary=".sync-stage-"+UUID().uuidString.lowercased()
                defer {try? directory.remove(temporary)}
                try directory.withNewFile(temporary) {file in
                    try manifest.verify {chunk in
                        let data=try fetch(chunk)
                        try Self.write(file,data)
                        return data
                    }
                }
                try Task.checkCancellation()
                try directory.withRootDirectory {file in
                    if linkat(file,temporary,file,name,0) != 0 {
                        guard errno==EEXIST else {throw OSwindError.unavailable("Cannot publish verified sync media")}
                        let existing=try directory.digest(name,limit:manifest.bytes)
                        guard existing.sha256==manifest.sha256,existing.bytes==manifest.bytes else {throw OSwindError.invalid("Concurrent sync media differs")}
                    }
                    guard fsync(file)==0 else {throw OSwindError.unavailable("Cannot flush verified sync media")}
                }
            }
            paths[manifest.role]=path
        }
        try library.verifyHistoricalMedia(reference,manifests,paths)
        try tree.requireRootIdentity(at:library.root)
        return paths
    }

    func verify(_ reference:SyncVersionReference,_ manifests:[SyncMediaManifest],_ paths:[SyncMediaRole:String])throws {
        for (role,path) in paths {try requirePath(path,role:role)}
        try library.verifyHistoricalMedia(reference,manifests,paths)
    }
    private static func bucket(_ role:SyncMediaRole)->String {switch role {case .image:return "images";case .audio:return "audio";case .video:return "video"}}
    private static func suffix(_ role:SyncMediaRole)->String {switch role {case .image:return ".png";case .audio:return ".wav";case .video:return ".mp4"}}
    private func requirePath(_ path:String,role:SyncMediaRole)throws {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count==2,parts[0]==Self.bucket(role),!parts[1].isEmpty,parts[1] != ".",parts[1] != "..",!path.utf8.contains(0) else {throw OSwindError.invalid("Sync media must belong to its native media directory")}
    }
    private func read(_ file:Int32,count:Int)throws->Data {
        var bytes=Data(count:count),offset=0
        try bytes.withUnsafeMutableBytes {buffer in
            while offset<count {
                try Task.checkCancellation()
                let n=Darwin.read(file,buffer.baseAddress!.advanced(by:offset),count-offset)
                if n<0,errno==EINTR {continue}
                guard n>0 else {throw OSwindError.unavailable("Sync source media was truncated")};offset+=n
            }
        };return bytes
    }
    private static func write(_ file:Int32,_ data:Data)throws {
        try data.withUnsafeBytes {buffer in
            var offset=0
            while offset<buffer.count {
                try Task.checkCancellation()
                let n=Darwin.write(file,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if n<0,errno==EINTR {continue}
                guard n>0 else {throw OSwindError.unavailable("Cannot stage sync media")};offset+=n
            }
        }
    }
}
