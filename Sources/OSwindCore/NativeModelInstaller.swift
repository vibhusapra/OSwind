import Foundation
import Darwin

public struct NativeModelProgress:Codable,Sendable {
    public var phase:String
    public var completedBytes:Int64
    public var totalBytes:Int64
    public var completedFiles:Int
    public var totalFiles:Int
    public var file:String?
    public init(phase:String,completedBytes:Int64,totalBytes:Int64,completedFiles:Int,totalFiles:Int,file:String?=nil) {self.phase=phase;self.completedBytes=completedBytes;self.totalBytes=totalBytes;self.completedFiles=completedFiles;self.totalFiles=totalFiles;self.file=file}
    public var fraction:Double { totalBytes>0 ? min(1,max(0,Double(completedBytes)/Double(totalBytes))):0 }
}
public struct NativeModelInstallation:Codable,Equatable,Sendable {
    public var kind:NativeModelKind
    public var directory:URL
    public var revision:String
    public var files:Int
    public var bytes:Int64
    public var reused:Bool
    public init(kind:NativeModelKind,directory:URL,revision:String,files:Int,bytes:Int64,reused:Bool) {self.kind=kind;self.directory=directory;self.revision=revision;self.files=files;self.bytes=bytes;self.reused=reused}
    enum CodingKeys:CodingKey{case kind,directory,revision,files,bytes,reused}
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self),path=try values.decode(String.self,forKey:.directory)
        guard path.hasPrefix("/"),!path.utf8.contains(0) else {throw OSwindError.invalid("Invalid installed model path")}
        kind=try values.decode(NativeModelKind.self,forKey:.kind);directory=URL(fileURLWithPath:path,isDirectory:true);revision=try values.decode(String.self,forKey:.revision);files=try values.decode(Int.self,forKey:.files);bytes=try values.decode(Int64.self,forKey:.bytes);reused=try values.decode(Bool.self,forKey:.reused)
    }
    public func encode(to encoder:Encoder) throws {
        var values=encoder.container(keyedBy:CodingKeys.self)
        try values.encode(kind,forKey:.kind);try values.encode(directory.path,forKey:.directory);try values.encode(revision,forKey:.revision);try values.encode(files,forKey:.files);try values.encode(bytes,forKey:.bytes);try values.encode(reused,forKey:.reused)
    }

}
public enum NativeModelInstaller {
    public static var defaultCache:URL { FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("OSwind/models",isDirectory:true) }
    public static func destination(for kind:NativeModelKind,cache:URL?=nil) throws -> URL {
        let catalog=try kind.catalog();return (cache ?? defaultCache).appendingPathComponent(kind.directoryPrefix+catalog.revision.prefix(12),isDirectory:true)
    }
    public static func install(_ kind:NativeModelKind,cache:URL?=nil,progress:@escaping @Sendable (NativeModelProgress)->Void={_ in}) async throws -> NativeModelInstallation {
        try await run(kind,manifest:kind.catalog(),cache:cache ?? defaultCache,verifyOnly:false,transport:NativeHTTPTransport(),progress:progress)
    }
    public static func verify(_ kind:NativeModelKind,cache:URL?=nil,progress:@escaping @Sendable (NativeModelProgress)->Void={_ in}) async throws -> NativeModelInstallation {
        try await run(kind,manifest:kind.catalog(),cache:cache ?? defaultCache,verifyOnly:true,transport:NativeHTTPTransport(),progress:progress)
    }
    static func run(_ kind:NativeModelKind,manifest:NativeModelManifest,cache:URL,verifyOnly:Bool=false,transport:any NativeModelTransport,progress:@escaping @Sendable (NativeModelProgress)->Void={_ in}) async throws -> NativeModelInstallation {
        try Task.checkCancellation()
        let job=Task.detached(priority:.utility) { () async throws -> NativeModelInstallation in
            try manifest.validate();try Task.checkCancellation()
            guard cache.isFileURL,cache.path.hasPrefix("/"),!cache.path.utf8.contains(0),manifest.id==kind.manifestID else { throw OSwindError.invalid("Invalid native model cache or catalog identity") }
            try requireCacheOutsideLibraries(cache)
            let destination=cache.appendingPathComponent(kind.directoryPrefix+manifest.revision.prefix(12),isDirectory:true)
            if try verifyOnly && !exists(cache) { throw OSwindError.unavailable("Model is not installed; verification never downloads") }
            if !verifyOnly { try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
            let canonical=cache.standardizedFileURL.resolvingSymlinksInPath(),parent=try BackupFileTree(root:canonical)
            try parent.requireRootIdentity(at:cache)
            if !verifyOnly { _ = try BackupWorkspace.cleanupAbandoned(in:canonical,labels:["oswind-model-download"]) }
            if try exists(destination) {
                try verifyFiles(manifest,in:BackupFileTree(root:destination),progress:progress)
                try parent.requireRootIdentity(at:cache)
                return NativeModelInstallation(kind:kind,directory:destination,revision:manifest.revision,files:manifest.files.count,bytes:manifest.bytes,reused:true)
            }
            guard !verifyOnly else { throw OSwindError.unavailable("Model is not installed; verification never downloads") }
            if let available=try? canonical.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,available<manifest.bytes+64*1024*1024 { throw OSwindError.unavailable("Not enough free space for this model and its installation workspace") }
            let workspace=try BackupWorkspace(in:canonical,label:"oswind-model-download")
            defer { withExtendedLifetime(workspace) {} }
            var completed:Int64=0
            for (index,file) in manifest.files.enumerated() {
                try Task.checkCancellation();try parent.requireRootIdentity(at:cache)
                let base=completed
                progress(NativeModelProgress(phase:"Downloading",completedBytes:base,totalBytes:manifest.bytes,completedFiles:index,totalFiles:manifest.files.count,file:file.path))
                try await download(file,from:manifest.sourceURL(for:file),to:workspace.tree,transport:transport) { received in
                    progress(NativeModelProgress(phase:"Downloading",completedBytes:base+received,totalBytes:manifest.bytes,completedFiles:index,totalFiles:manifest.files.count,file:file.path))
                }
                try Task.checkCancellation()
                progress(NativeModelProgress(phase:"Verifying",completedBytes:base+file.bytes,totalBytes:manifest.bytes,completedFiles:index,totalFiles:manifest.files.count,file:file.path))
                let digest=try workspace.tree.digest(file.path)
                guard digest.bytes==file.bytes,digest.sha256==file.sha256 else { throw OSwindError.invalid("Model checksum mismatch: "+file.path) }
                completed += file.bytes
            }
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try workspace.tree.write(encoder.encode(manifest),as:"OSWIND-MODEL.json")
            try workspace.tree.write(Data((manifest.attribution+"\n"+manifest.licenseURL+"\nhttps://huggingface.co/"+manifest.repository+"\n").utf8),as:"ATTRIBUTION.txt")
            try Task.checkCancellation();try parent.requireRootIdentity(at:cache)
            try workspace.publish(as:destination)
            progress(NativeModelProgress(phase:"Installed",completedBytes:manifest.bytes,totalBytes:manifest.bytes,completedFiles:manifest.files.count,totalFiles:manifest.files.count,file:nil))
            return NativeModelInstallation(kind:kind,directory:destination,revision:manifest.revision,files:manifest.files.count,bytes:manifest.bytes,reused:false)
        }
        do {return try await withTaskCancellationHandler {try await job.value} onCancel:{job.cancel()}}
        catch let error as BackupFileError {
            let message=error.localizedDescription.replacingOccurrences(of:"The source library",with:"The model cache").replacingOccurrences(of:"backup",with:"model setup",options:.caseInsensitive).replacingOccurrences(of:"Archive",with:"Model")
            throw OSwindError.unavailable(message)
        }
    }
    private static func requireCacheOutsideLibraries(_ cache:URL) throws {
        var directory=cache.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.pathComponents.count<=128 else {throw OSwindError.invalid("Choose a shallower model cache location")}
        for _ in 0..<128 {
            if directory.pathExtension.lowercased()=="mlmodelc" || (try? exists(directory.appendingPathComponent("OSWIND-MODEL.json")))==true || (try? exists(directory.appendingPathComponent("Preprocessor.mlmodelc")))==true || (try? exists(directory.appendingPathComponent("Segmentation.mlmodelc")))==true {throw OSwindError.invalid("Choose a model cache outside installed model packages")}
            if try exists(directory.appendingPathComponent("memory.sqlite")) {throw OSwindError.invalid("Choose a model cache outside OSwind memory libraries")}
            if directory.pathExtension.lowercased()=="oswindbackup" {throw OSwindError.invalid("Choose a model cache outside backup packages")}
            if (try? exists(directory.appendingPathComponent("header.json")))==true,
               let data=try? BackupFileTree(root:directory).read("header.json",limit:65536),
               let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],object["format"] as? String=="OSwind library backup" {throw OSwindError.invalid("Choose a model cache outside backup packages")}
            let parent=directory.deletingLastPathComponent();if parent.path==directory.path {return};directory=parent
        }
    }
    private static func exists(_ url:URL) throws -> Bool {
        var metadata=stat();if lstat(url.path,&metadata)==0 { return true }
        if errno==ENOENT { return false };throw OSwindError.unavailable("Model cache is unavailable: "+String(cString:strerror(errno)))
    }
    private static func download(_ file:NativeModelManifest.File,from url:URL,to tree:BackupFileTree,transport:any NativeModelTransport,progress:@escaping @Sendable (Int64)->Void) async throws {
        var descriptor:Int32 = -1
        do {
            try tree.withNewFile(file.path) { original in
                descriptor=fcntl(original,F_DUPFD_CLOEXEC,0)
                guard descriptor>=0 else { throw OSwindError.unavailable("Cannot retain a model download file") }
            }
        } catch { if descriptor>=0 { close(descriptor) };throw error }
        defer { close(descriptor) }
        try await transport.download(url,to:descriptor,expectedBytes:file.bytes,progress:progress)
        try Task.checkCancellation()
        guard fsync(descriptor)==0 else { throw OSwindError.unavailable("Cannot flush the model download; check available disk space") }
    }
    private static func verifyFiles(_ manifest:NativeModelManifest,in tree:BackupFileTree,progress:@Sendable (NativeModelProgress)->Void) throws {
        var completed:Int64=0
        for (index,file) in manifest.files.enumerated() {
            let base=completed
            try tree.withFile(file.path) { _,stamp in guard stamp.bytes==file.bytes else { throw OSwindError.invalid("Installed model size mismatch: "+file.path) } }
            let digest=try tree.digest(file.path) { count in progress(NativeModelProgress(phase:"Verifying",completedBytes:base+count,totalBytes:manifest.bytes,completedFiles:index,totalFiles:manifest.files.count,file:file.path)) }
            guard digest.sha256==file.sha256 else { throw OSwindError.invalid("Installed model checksum mismatch: "+file.path) };completed += file.bytes
        }
        // Refuse extra model components (e.g. an unverified optional CTC head),
        // symlinks and special files. Finder metadata is harmless and bounded.
        let members=Set(manifest.files.map(\.path)),metadata:Set<String>=["OSWIND-MODEL.json","ATTRIBUTION.txt"]
        var directories=Set<String>()
        for member in members { var parts=member.split(separator:"/");while parts.count>1 { parts.removeLast();directories.insert(parts.joined(separator:"/")) } }
        func walk(_ prefix:String?=nil) throws {
            try tree.forEachEntry(in:prefix) { name in
                let member=prefix.map{$0+"/"+name} ?? name
                if members.contains(member) { return }
                if metadata.contains(member) || name==".DS_Store" { try tree.withFile(member) { _,stamp in guard stamp.bytes<=1024*1024 else { throw OSwindError.invalid("Unexpected oversized model metadata") } };return }
                guard directories.contains(member) else { throw OSwindError.invalid("Unexpected file in installed model: "+member) };try walk(member)
            }
        }
        try walk();try tree.requireRootIdentity(at:tree.root)
        progress(NativeModelProgress(phase:"Verified",completedBytes:manifest.bytes,totalBytes:manifest.bytes,completedFiles:manifest.files.count,totalFiles:manifest.files.count,file:nil))
    }
}
