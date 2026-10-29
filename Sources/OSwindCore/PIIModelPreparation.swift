import Foundation
import Darwin
import CryptoKit

struct PIISetupCatalog:Codable,Sendable {
    struct Download:Codable,Sendable {var path:String,bytes:Int64,sha256:String,url:URL}
    struct Patch:Codable,Sendable {var offset:Int64,before:String,after:String,meaning:String}
    struct Sample:Codable,Sendable {
        struct Mask:Codable,Sendable {var location:Int,length:Int}
        var id:String,text:String,sourceSHA256:String,ranges:[Mask],labels:[Int]
    }
    var format:Int,id:String,revision:String,runtimeVersion:String,files:[Download]
    var runtimeMember:String,runtimeBytes:Int64,runtimeSHA256:String,runtimeLicenseMember:String,runtimeLicenseSHA256:String
    var bucketBytes:Int64,bucketSHA256:String,patches:[Patch],samples:[Sample],attribution:String,modelLicense:String
    var downloadBytes:Int64 {files.reduce(0){let (sum,overflow)=$0.addingReportingOverflow($1.bytes);return overflow ? Int64.max:sum}}
    var installedFiles:[NativeModelManifest.File] {
        files.filter {$0.path != "runtime.whl"}.map {.init(path:$0.path,bytes:$0.bytes,sha256:$0.sha256)} + [
            .init(path:"model/onnx/model-bucket128.onnx",bytes:bucketBytes,sha256:bucketSHA256),
            .init(path:"runtime/libonnxruntime.1.24.2.dylib",bytes:runtimeBytes,sha256:runtimeSHA256),
            .init(path:"licenses/ONNXRuntime-MIT.txt",bytes:1073,sha256:runtimeLicenseSHA256),
            .init(path:"licenses/GLiNER-Apache-2.0.txt",bytes:Int64(modelLicense.utf8.count),sha256:BackupSHA256.hex(Data(modelLicense.utf8))),
            .init(path:"ATTRIBUTION.txt",bytes:Int64(attribution.utf8.count),sha256:BackupSHA256.hex(Data(attribution.utf8)))
        ]
    }
    static func current()throws->Self {
        let data=Data(embeddedJSON.utf8)
        guard BackupSHA256.hex(data)==buildID else {throw OSwindError.invalid("PII preparation recipe integrity failed")}
        let value=try JSONDecoder().decode(Self.self,from:data);try value.validate();return value
    }
    func validate()throws {
        func hash(_ value:String)->Bool {value.utf8.count==64 && value.utf8.allSatisfy {(48...57).contains($0)||(97...102).contains($0)}}
        func path(_ value:String)->Bool {
            let parts=value.split(separator:"/",omittingEmptySubsequences:false)
            return (1...8).contains(parts.count) && value.utf8.count<512 && parts.allSatisfy {!$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy {(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||[45,46,95].contains($0)}}
        }
        guard format==1,id=="gliner-pii-edge-native-v1",revision.utf8.count==40,revision.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),runtimeVersion=="1.24.2",files.count==8,
              Set(files.map {$0.path.lowercased()}).count==files.count,downloadBytes>0,downloadBytes<250_000_000,
              files.allSatisfy({path($0.path) && $0.bytes>0 && $0.bytes<=200_000_000 && hash($0.sha256) && $0.url.scheme=="https" && $0.url.host != nil && $0.url.user==nil && $0.url.password==nil}),
              files.contains(where:{$0.path=="runtime.whl"}),files.contains(where:{$0.path=="model/onnx/model.onnx"}),
              path(runtimeMember),path(runtimeLicenseMember),runtimeBytes==27651368,hash(runtimeSHA256),hash(runtimeLicenseSHA256),
              bucketBytes==181078847,hash(bucketSHA256),patches.count==6,samples.count==2,modelLicense.utf8.count<20000,attribution.utf8.count<8192 else {throw OSwindError.invalid("Invalid PII preparation recipe")}
        var end:Int64=0
        for patch in patches {
            let before=try Self.bytes(patch.before),after=try Self.bytes(patch.after)
            guard patch.offset>=end,!before.isEmpty,before.count<=256,!after.isEmpty,after.count<=256,patch.offset<=181078966-Int64(before.count) else {throw OSwindError.invalid("Invalid PII graph metadata patch")}
            end=patch.offset+Int64(before.count)
        }
        for sample in samples {
            guard sample.text.utf8.count<1024,hash(sample.sourceSHA256),BackupSHA256.hex(Data(sample.text.utf8))==sample.sourceSHA256,
                  sample.ranges.count==sample.labels.count,(1...8).contains(sample.ranges.count),sample.labels.allSatisfy({(0..<12).contains($0)}),
                  sample.ranges.allSatisfy({$0.location>=0 && $0.length>0 && $0.location<=(sample.text as NSString).length && $0.length<=(sample.text as NSString).length-$0.location}) else {throw OSwindError.invalid("Invalid PII compatibility sample")}
        }
    }
    static func bytes(_ hex:String)throws->Data {
        guard hex.utf8.count%2==0,hex.utf8.count<=512 else {throw OSwindError.invalid("Invalid PII patch bytes")}
        let chars=Array(hex.utf8);var result=Data()
        func digit(_ x:UInt8)throws->UInt8 {if (48...57).contains(x) {return x-48};if (97...102).contains(x) {return x-87};throw OSwindError.invalid("Invalid PII patch hex")}
        for i in stride(from:0,to:chars.count,by:2) {result.append(try digit(chars[i])*16+digit(chars[i+1]))};return result
    }
}

public struct PIIModelInstallation:Encodable,Equatable,Sendable {
    public let directory:URL,buildID:String,bytes:Int64,downloadBytes:Int64,reused:Bool
    public var modelDirectory:URL {directory.appendingPathComponent("model")}
    public var runtimeLibrary:URL {directory.appendingPathComponent("runtime/libonnxruntime.1.24.2.dylib")}
    public init(directory:URL,buildID:String,bytes:Int64,downloadBytes:Int64,reused:Bool) {self.directory=directory;self.buildID=buildID;self.bytes=bytes;self.downloadBytes=downloadBytes;self.reused=reused}
    enum CodingKeys:CodingKey {case directory,modelDirectory,runtimeLibrary,buildID,bytes,downloadBytes,reused}
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(directory.path,forKey:.directory);try c.encode(modelDirectory.path,forKey:.modelDirectory);try c.encode(runtimeLibrary.path,forKey:.runtimeLibrary)
        try c.encode(buildID,forKey:.buildID);try c.encode(bytes,forKey:.bytes);try c.encode(downloadBytes,forKey:.downloadBytes);try c.encode(reused,forKey:.reused)
    }
}

struct PIISetupReceipt:Codable {
    let format:Int,buildID:String,modelRevision:String,runtimeVersion:String,compatibilitySamples:Int,computePolicies:[PIIComputePolicy],preparedOS:String
    func validate(catalog:PIISetupCatalog)throws {
        guard format==1,buildID==PIISetupCatalog.buildID,modelRevision==catalog.revision,runtimeVersion==catalog.runtimeVersion,
              compatibilitySamples==4,computePolicies == [.cpu,.coreML],!preparedOS.isEmpty,preparedOS.utf8.count<512 else {throw OSwindError.invalid("PII preparation receipt is missing or incompatible")}
    }
}

public enum PIIModelPreparation {
    public static var defaultCache:URL {NativeModelInstaller.defaultCache.appendingPathComponent("pii")}
    public static func prepare(cache:URL?=nil,progress:@escaping @Sendable (NativeModelProgress)->Void={_ in}) async throws -> PIIModelInstallation {
        #if !arch(arm64)
        throw OSwindError.unavailable("This pinned PII runtime requires Apple Silicon macOS14 or newer")
        #else
        return try await perform(cache:cache ?? defaultCache,verifyOnly:false,transport:NativeHTTPTransport(),progress:progress)
        #endif
    }
    /// Verify known assets and the preparation receipt only. Never downloads,
    /// creates a cache, extracts an archive, or runs native model inference.
    public static func verify(cache:URL?=nil) async throws -> PIIModelInstallation {
        try await perform(cache:cache ?? defaultCache,verifyOnly:true,transport:NativeHTTPTransport(),progress:{_ in})
    }
    private static func perform(cache:URL,verifyOnly:Bool,transport:any NativeModelTransport,progress:@escaping @Sendable (NativeModelProgress)->Void) async throws -> PIIModelInstallation {
        let job=Task.detached(priority:.utility) {try await run(cache:cache,verifyOnly:verifyOnly,catalog:PIISetupCatalog.current(),transport:transport,progress:progress)}
        return try await withTaskCancellationHandler {try await job.value} onCancel:{job.cancel()}
    }
    static func run(cache:URL,verifyOnly:Bool,catalog:PIISetupCatalog,transport:any NativeModelTransport,
                    extractor:(@Sendable (URL,URL,[Int32]) async throws -> Void)?=nil,
                    qualifier:(@Sendable (URL,URL,PIISetupCatalog) async throws -> Void)?=nil,
                    progress:@escaping @Sendable (NativeModelProgress)->Void={_ in}) async throws -> PIIModelInstallation {
        try Task.checkCancellation();try catalog.validate()
        guard cache.isFileURL,cache.path.hasPrefix("/"),!cache.path.utf8.contains(0) else {throw OSwindError.invalid("Choose an absolute local PII cache directory")}
        try NativeModelInstaller.requireCacheOutsideLibraries(cache)
        if verifyOnly {guard try NativeModelInstaller.exists(cache) else {throw OSwindError.unavailable("PII models are not prepared; verification never downloads")}}
        if !verifyOnly {try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        let canonical=cache.standardizedFileURL.resolvingSymlinksInPath(),parent=try BackupFileTree(root:canonical)
        try parent.requireRootIdentity(at:cache)
        let destination=canonical.appendingPathComponent("gliner-pii-"+PIISetupCatalog.buildID.prefix(16),isDirectory:true)
        func installed(_ reused:Bool)->PIIModelInstallation {.init(directory:destination,buildID:PIISetupCatalog.buildID,bytes:catalog.installedFiles.reduce(0){$0+$1.bytes},downloadBytes:catalog.downloadBytes,reused:reused)}
        if verifyOnly {try verify(destination,catalog:catalog);try parent.requireRootIdentity(at:cache);return installed(true)}
        let lock=try parent.withRootDirectory {openat($0,".pii-prepare.lock",O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)}
        guard lock>=0 else {throw OSwindError.unavailable("Cannot reserve PII preparation")};defer {flock(lock,LOCK_UN);close(lock)}
        var stamp=stat();guard fstat(lock,&stamp)==0,stamp.st_mode&S_IFMT==S_IFREG,stamp.st_nlink==1,stamp.st_uid==getuid(),flock(lock,LOCK_EX|LOCK_NB)==0 else {throw OSwindError.unavailable("PII preparation is already running, or its cache lock is invalid")}
        _ = try BackupWorkspace.cleanupAbandoned(in:canonical,labels:["oswind-pii-prepare"])
        if try NativeModelInstaller.exists(destination) {try verify(destination,catalog:catalog);try parent.requireRootIdentity(at:cache);return installed(true)}
        if let available=try? canonical.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,available<1024*1024*1024 {throw OSwindError.unavailable("Allow at least1 GB of free space to prepare local PII models")}
        let workspace=try BackupWorkspace(in:canonical,label:"oswind-pii-prepare"),payload=try BackupWorkspace(in:canonical,label:"oswind-pii-prepare")
        defer {withExtendedLifetime(workspace){};withExtendedLifetime(payload){}}
        var downloaded:Int64=0
        for (index,file) in catalog.files.enumerated() {
            try Task.checkCancellation();try parent.requireRootIdentity(at:cache)
            let start=downloaded
            try await NativeModelInstaller.download(.init(path:file.path,bytes:file.bytes,sha256:file.sha256),from:file.url,to:workspace.tree,transport:transport) {received in
                progress(.init(phase:"Downloading public PII models",completedBytes:start+received,totalBytes:catalog.downloadBytes,completedFiles:index,totalFiles:catalog.files.count,file:file.path))
            }
            try check(file.path,bytes:file.bytes,hash:file.sha256,tree:workspace.tree);downloaded+=file.bytes
            if file.path != "runtime.whl" {_ = try workspace.tree.pin(file.path,to:payload.tree,as:file.path)}
        }
        try Task.checkCancellation();try parent.requireRootIdentity(at:cache)
        progress(.init(phase:"Preparing native runtime",completedBytes:0,totalBytes:0,completedFiles:0,totalFiles:1))
        // Hash and retain our private downloaded archive, then seal it read-only.
        // The guardian retains workspace reservations; the extractor inherits
        // only stdio and opens this owned pathname, never user-supplied input.
        let archive=try workspace.tree.withFile("runtime.whl") {fd,metadata -> Int32 in
            var hash=SHA256(),buffer=[UInt8](repeating:0,count:65536),count:Int64=0
            while true {
                try Task.checkCancellation();let n=Darwin.read(fd,&buffer,buffer.count)
                if n<0 && errno==EINTR {continue};guard n>=0 else {throw OSwindError.unavailable("Cannot read pinned PII runtime archive")};if n==0 {break}
                count+=Int64(n);guard count<=20_000_000 else {throw OSwindError.invalid("PII runtime archive exceeds its bound")};hash.update(data:Data(buffer.prefix(n)))
            }
            let wheel=catalog.files.first {$0.path=="runtime.whl"}!
            let digest=hash.finalize().map {String(format:"%02x",$0)}.joined();var after=stat()
            guard count==wheel.bytes,digest==wheel.sha256,fstat(fd,&after)==0,BackupFileStamp(after)==metadata,fchmod(fd,0o400)==0,lseek(fd,0,SEEK_SET)==0 else {throw OSwindError.invalid("PII runtime archive changed before extraction")}
            let copy=fcntl(fd,F_DUPFD_CLOEXEC,128);guard copy>=0 else {throw OSwindError.unavailable("Cannot retain pinned PII archive")};return copy
        }
        defer {close(archive)}
        let reservation=try workspace.retainedLifetimeDescriptor();defer {close(reservation)}
        let extracted=workspace.url.appendingPathComponent("extracted",isDirectory:true)
        try FileManager.default.createDirectory(at:extracted,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let archiveURL=workspace.url.appendingPathComponent("runtime.whl")
        if let extractor {try await extractor(archiveURL,extracted,[lock,reservation])}
        else {
            guard let guardian=PreparationProcess.guardian else {throw OSwindError.unavailable("Bundled preparation guardian is missing")}
            let result=try await PreparationProcess.run(URL(fileURLWithPath:"/usr/bin/unzip"),["-qq",archiveURL.path,catalog.runtimeMember,catalog.runtimeLicenseMember,"-d",extracted.path],environment:["PATH":"/usr/bin:/bin","TMPDIR":workspace.url.path],timeout:120,outputLimit:65536,guardian:guardian,keepAlive:[lock,reservation])
            guard result.status==0 else {throw OSwindError.unavailable("Native PII runtime extraction failed; no installation published")}
        }
        try Task.checkCancellation();try parent.requireRootIdentity(at:cache)
        try workspace.tree.withFile("runtime.whl") {_,current in
            var retained=stat();guard fstat(archive,&retained)==0,current==BackupFileStamp(retained) else {throw OSwindError.invalid("PII runtime archive moved during extraction")}
        }
        let extractedTree=try BackupFileTree(root:extracted)
        try check(catalog.runtimeMember,bytes:catalog.runtimeBytes,hash:catalog.runtimeSHA256,tree:extractedTree)
        try check(catalog.runtimeLicenseMember,bytes:1073,hash:catalog.runtimeLicenseSHA256,tree:extractedTree)
        _ = try extractedTree.pin(catalog.runtimeMember,to:payload.tree,as:"runtime/libonnxruntime.1.24.2.dylib")
        _ = try extractedTree.pin(catalog.runtimeLicenseMember,to:payload.tree,as:"licenses/ONNXRuntime-MIT.txt")
        try payload.tree.write(Data(catalog.modelLicense.utf8),as:"licenses/GLiNER-Apache-2.0.txt")
        try payload.tree.write(Data(catalog.attribution.utf8),as:"ATTRIBUTION.txt")
        progress(.init(phase:"Preparing Core ML input shapes",completedBytes:0,totalBytes:181078966,completedFiles:0,totalFiles:1))
        try deriveBucket(in:payload.tree,catalog:catalog)
        for file in catalog.installedFiles {try check(file.path,bytes:file.bytes,hash:file.sha256,tree:payload.tree)}
        progress(.init(phase:"Checking local CPU and Core ML compatibility",completedBytes:0,totalBytes:0,completedFiles:0,totalFiles:4))
        if let qualifier {try await qualifier(payload.url.appendingPathComponent("model"),payload.url.appendingPathComponent("runtime/libonnxruntime.1.24.2.dylib"),catalog)}
        else {try await qualify(model:payload.url.appendingPathComponent("model"),library:payload.url.appendingPathComponent("runtime/libonnxruntime.1.24.2.dylib"),catalog:catalog)}
        try Task.checkCancellation()
        let receipt=PIISetupReceipt(format:1,buildID:PIISetupCatalog.buildID,modelRevision:catalog.revision,runtimeVersion:catalog.runtimeVersion,compatibilitySamples:4,computePolicies:[.cpu,.coreML],preparedOS:ProcessInfo.processInfo.operatingSystemVersionString)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try payload.tree.write(encoder.encode(receipt),as:"OSWIND-PII.json")
        try verify(payload.url,catalog:catalog);try Task.checkCancellation();try parent.requireRootIdentity(at:cache)
        try payload.publish(as:destination)
        progress(.init(phase:"Local PII inspection models ready",completedBytes:catalog.downloadBytes,totalBytes:catalog.downloadBytes,completedFiles:catalog.files.count,totalFiles:catalog.files.count))
        return installed(false)
    }
    private static func check(_ path:String,bytes:Int64,hash:String,tree:BackupFileTree)throws {
        let value=try tree.digest(path,limit:bytes)
        guard value.bytes==bytes,value.sha256==hash else {throw OSwindError.invalid("Pinned PII asset checksum mismatch: "+path)}
    }
    private static func verify(_ directory:URL,catalog:PIISetupCatalog)throws {
        let tree=try BackupFileTree(root:directory)
        for file in catalog.installedFiles {try Task.checkCancellation();try check(file.path,bytes:file.bytes,hash:file.sha256,tree:tree)}
        try JSONDecoder().decode(PIISetupReceipt.self,from:tree.read("OSWIND-PII.json",limit:16384)).validate(catalog:catalog)
    }
    static func deriveBucket(in tree:BackupFileTree,catalog:PIISetupCatalog)throws {
        let source=catalog.files.first {$0.path=="model/onnx/model.onnx"}!
        try check(source.path,bytes:source.bytes,hash:source.sha256,tree:tree)
        try tree.withFile(source.path) {input,metadata in
            guard metadata.bytes==source.bytes else {throw OSwindError.invalid("PII graph size changed before shape preparation")}
            try tree.withNewFile("model/onnx/model-bucket128.onnx") {output in
            var position:Int64=0,hash=SHA256(),buffer=[UInt8](repeating:0,count:65536)
            func consume(_ length:Int64,copy:Bool)throws->Data {
                var remaining=length,result=Data()
                while remaining>0 {
                    try Task.checkCancellation();let n=Darwin.read(input,&buffer,min(buffer.count,Int(remaining)))
                    if n<0 && errno==EINTR {continue};guard n>0 else {throw OSwindError.invalid("PII graph changed during shape preparation")}
                    let data=Data(buffer.prefix(n));hash.update(data:data)
                    if copy {try write(data,to:output)} else {result.append(data)}
                    remaining-=Int64(n);position+=Int64(n)
                };return result
            }
            for patch in catalog.patches {
                _ = try consume(patch.offset-position,copy:true)
                let before=try PIISetupCatalog.bytes(patch.before),after=try PIISetupCatalog.bytes(patch.after)
                guard try consume(Int64(before.count),copy:false)==before else {throw OSwindError.invalid("PII graph metadata differs from the pinned recipe")}
                try write(after,to:output)
            }
            _ = try consume(source.bytes-position,copy:true)
            var after=stat();let digest=hash.finalize().map {String(format:"%02x",$0)}.joined()
            guard digest==source.sha256,fstat(input,&after)==0,BackupFileStamp(after)==metadata else {throw OSwindError.invalid("PII graph changed during shape preparation")}
        }}
        try check("model/onnx/model-bucket128.onnx",bytes:catalog.bucketBytes,hash:catalog.bucketSHA256,tree:tree)
    }
    private static func write(_ data:Data,to fd:Int32)throws {
        try data.withUnsafeBytes {raw in
            var offset=0
            while offset<raw.count {
                try Task.checkCancellation();let n=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                if n<0 && errno==EINTR {continue};guard n>0 else {throw OSwindError.unavailable("Cannot write PII model; check available disk space")};offset+=n
            }
        }
    }
    private static func qualify(model:URL,library:URL,catalog:PIISetupCatalog) async throws {
        for compute:PIIComputePolicy in [.cpu,.coreML] {
            let inspector=PIIInspector(modelDirectory:model,runtimeLibrary:library,compute:compute)
            await inspector.setRetention(.untilQuit)
            do {
                for sample in catalog.samples {
                    let result=try await inspector.inspect(sample.text,threshold:0.5)
                    guard result.sourceSHA256==sample.sourceSHA256,result.modelID==PIIInspector.expectedModelID(compute),
                          result.modelMasks.map(\.startUTF16)==sample.ranges.map(\.location),result.modelMasks.map(\.lengthUTF16)==sample.ranges.map(\.length),
                          result.spans.map(\.label)==sample.labels.map({PIITokenizer.labels[$0]}) else {throw OSwindError.invalid("Native PII compatibility sample did not match; no model installed")}
                }
                await inspector.shutdown()
            } catch {await inspector.shutdown();throw error}
        }
    }
}
