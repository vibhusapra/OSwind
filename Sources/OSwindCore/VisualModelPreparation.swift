import Foundation
import Darwin

public struct VisualModelInstallation:Encodable,Sendable {
    public var directory:URL
    public var modelID:String
    public var bytes:Int64
    public var reused:Bool
    enum CodingKeys:CodingKey {case directory,modelID,bytes,reused}
    public func encode(to encoder:Encoder) throws {
        var values=encoder.container(keyedBy:CodingKeys.self)
        try values.encode(directory.path,forKey:.directory);try values.encode(modelID,forKey:.modelID);try values.encode(bytes,forKey:.bytes);try values.encode(reused,forKey:.reused)
    }
}
struct VisualPreparationRuntime:Decodable,Sendable {
    struct Asset:Decodable,Sendable {var path:String;var bytes:Int64;var sha256:String}
    var version:String;var source:String;var url:String;var bytes:Int64;var sha256:String
    var member:String;var executableBytes:Int64;var executableSHA256:String;var license:String;var python:String;var assets:[Asset]
    static func current() throws -> Self {try JSONDecoder().decode(Self.self,from:Data(VisualPreparationCatalog.json.utf8))}
    var buildID:String {String(BackupSHA256.hex(Data(VisualPreparationCatalog.json.utf8)).prefix(16))}
}
struct VisualPreparationQualification:Codable,Sendable {
    struct Measurement:Codable,Sendable {var encoder:String;var requestedCompute:String;var minimumCosine:Double;var passed:Bool}
    var recipe:String
    var measurements:[Measurement]
    func validate() throws {
        let expected:Set<String>=["image/CPU_ONLY","text/CPU_ONLY","image/CPU_AND_GPU","text/CPU_AND_GPU"]
        guard recipe==VisualModelBundle.recipe,measurements.count==4,Set(measurements.map {$0.encoder+"/"+$0.requestedCompute})==expected,
              measurements.allSatisfy({$0.passed && $0.minimumCosine.isFinite && $0.minimumCosine>=0.999 && $0.minimumCosine<=1.00001}) else {throw OSwindError.invalid("Visual model CPU/GPU qualification is incomplete or failed")}
    }
}
struct VisualPreparationReceipt:Codable,Sendable {
    var modelID:String
    var buildID:String
    var runtimeVersion:String
    var pythonVersion:String
    var qualification:VisualPreparationQualification
    func validate(modelID:String,buildID:String) throws {
        guard self.modelID==modelID,self.buildID==buildID else {throw OSwindError.invalid("The prepared model's qualification identity changed")}
        try qualification.validate()
    }
}
private final class VisualPreparationEvents:@unchecked Sendable {
    private var pending=Data()
    private let progress:@Sendable (NativeModelProgress)->Void
    init(_ progress:@escaping @Sendable (NativeModelProgress)->Void) {self.progress=progress}
    // Called synchronously only from the single process-drain worker.
    func append(_ bytes:Data) {
        pending.append(bytes)
        while let end=pending.firstIndex(of:10) {
            let line=pending.prefix(upTo:end);pending.removeSubrange(...end)
            guard line.count<=65536,let text=String(data:line,encoding:.utf8),text.hasPrefix("OSWIND_SETUP "),let data=text.dropFirst(13).data(using:.utf8) else {continue}
            struct Event:Decodable {var phase:String;var completedBytes:Int64?;var totalBytes:Int64?}
            guard let event=try? JSONDecoder().decode(Event.self,from:data),event.phase.count<=100 else {continue}
            let total=event.totalBytes ?? 0,completed=event.completedBytes ?? 0
            guard (0...4_000_000_000).contains(total),(0...total).contains(completed) else {continue}
            progress(.init(phase:event.phase,completedBytes:completed,totalBytes:total,completedFiles:0,totalFiles:1,file:nil))
        }
        if pending.count>65536 {pending.removeAll()}
    }
}

public enum VisualModelPreparation {
    public static var defaultCache:URL {FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("OSwind/visual-model-preparation")}
    public static var defaultAssetsRoot:URL? {
        var candidates=[URL]()
        if let resource=Bundle.main.resourceURL {candidates.append(resource)}
        if let executable=Bundle.main.executableURL,executable.deletingLastPathComponent().lastPathComponent=="MacOS",executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent=="Contents" {candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"))}
        return candidates.first {FileManager.default.fileExists(atPath:$0.appendingPathComponent("scripts/convert-visual-model.py.lock").path)}
    }
    public static func prepare(cache:URL?=nil,assetsRoot:URL?=nil,progress:@escaping @Sendable (NativeModelProgress)->Void={_ in}) async throws -> VisualModelInstallation {
        #if !arch(arm64)
        throw OSwindError.unavailable("Preparing this visual model requires Apple Silicon macOS. A prepared local bundle can still be selected manually.")
        #else
        let cache=cache ?? defaultCache,assetsRoot=assetsRoot ?? defaultAssetsRoot
        guard let assetsRoot else {throw OSwindError.unavailable("The packaged visual preparation tools are missing")}
        let job=Task.detached(priority:.utility) {try await run(cache:cache,assetsRoot:assetsRoot,runtime:VisualPreparationRuntime.current(),transport:NativeHTTPTransport(),progress:progress)}
        let result=try await withTaskCancellationHandler {try await job.value} onCancel:{job.cancel()}
        try Task.checkCancellation();return result
        #endif
    }
    static func environment(cache:URL,temporary:URL) -> [String:String] {
        ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","TMPDIR":temporary.path,"UV_CACHE_DIR":cache.appendingPathComponent("packages").path,
         "UV_PYTHON_INSTALL_DIR":cache.appendingPathComponent("python").path,"UV_PYTHON_BIN_DIR":cache.appendingPathComponent("python-bin").path,
         "UV_CREDENTIALS_DIR":cache.appendingPathComponent("empty-credentials").path,"UV_KEYRING_PROVIDER":"disabled",
         "UV_DEFAULT_INDEX":"https://pypi.org/simple","UV_NO_ENV_FILE":"1","UV_NO_CONFIG":"1","NETRC":"/dev/null","NO_COLOR":"1",
         "HF_HOME":cache.appendingPathComponent("empty-huggingface").path,"HF_HUB_OFFLINE":"1","HF_HUB_DISABLE_TELEMETRY":"1",
         "TRANSFORMERS_OFFLINE":"1","DO_NOT_TRACK":"1","PYTHONNOUSERSITE":"1","PYTHONUNBUFFERED":"1"]
    }
    static func verifiedAssets(_ root:URL,runtime:VisualPreparationRuntime) throws -> [String:Data] {
        let tree=try BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath());var assets=[String:Data]()
        for asset in runtime.assets {
            guard (1...2_000_000).contains(asset.bytes) else {throw OSwindError.invalid("Invalid bundled preparation asset")}
            let data=try tree.read(asset.path,limit:2_000_000)
            guard data.count==asset.bytes,BackupSHA256.hex(data)==asset.sha256 else {throw OSwindError.invalid("Bundled visual preparation tools changed; rebuild or reinstall OSwind")}
            assets[asset.path]=data
        }
        try tree.requireRootIdentity(at:root);return assets
    }
    static func run(cache:URL,assetsRoot:URL,runtime:VisualPreparationRuntime,transport:any NativeModelTransport,progress:@escaping @Sendable (NativeModelProgress)->Void) async throws -> VisualModelInstallation {
        try Task.checkCancellation();try NativeModelInstaller.requireCacheOutsideLibraries(cache)
        let assets=try verifiedAssets(assetsRoot,runtime:runtime)
        guard let guardian=PreparationProcess.guardian else {throw OSwindError.unavailable("The bundled preparation guardian is missing; rebuild or reinstall OSwind")}
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let canonical=cache.standardizedFileURL.resolvingSymlinksInPath(),parent=try BackupFileTree(root:canonical)
        try parent.requireRootIdentity(at:cache)
        let lock=try parent.withRootDirectory {openat($0,".visual-prepare.lock",O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,0o600)}
        guard lock>=0 else {throw OSwindError.unavailable("Cannot reserve the visual model cache")};defer {flock(lock,LOCK_UN);close(lock)}
        var stamp=stat();guard fstat(lock,&stamp)==0,stamp.st_mode&S_IFMT==S_IFREG,stamp.st_nlink==1,stamp.st_uid==getuid(),flock(lock,LOCK_EX | LOCK_NB)==0 else {throw OSwindError.unavailable("Visual model setup is already running, or its cache lock is invalid")}
        // A crash after atomic model publication can still leave conversion
        // scratch. Clean dead, unlocked jobs even on the ready-model path,
        // and before requiring additional free space for new preparation.
        _ = try BackupWorkspace.cleanupAbandoned(in:canonical,labels:["oswind-visual-prepare"])
        let destination=canonical.appendingPathComponent("siglip2-qualified-"+runtime.buildID)
        if try NativeModelInstaller.exists(destination) {
            progress(.init(phase:"Verifying local visual models",completedBytes:0,totalBytes:0,completedFiles:0,totalFiles:1,file:nil))
            let directory=destination.appendingPathComponent("model"),verified=try VisualModelBundle.verify(at:directory),container=try BackupFileTree(root:destination)
            let receipt=try JSONDecoder().decode(VisualPreparationReceipt.self,from:container.read("qualification.json",limit:131072))
            try receipt.validate(modelID:verified.modelID,buildID:runtime.buildID);try parent.requireRootIdentity(at:cache)
            return .init(directory:directory,modelID:verified.modelID,bytes:verified.bundle.model.bytes,reused:true)
        }
        if let available=try? canonical.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,available<10*1024*1024*1024 {throw OSwindError.unavailable("Allow at least 10 GB of free space to prepare the visual model and its local tools")}
        let workspace=try BackupWorkspace(in:canonical,label:"oswind-visual-prepare");defer {withExtendedLifetime(workspace){}}
        for (path,data) in assets {try workspace.tree.write(data,as:"runner/"+path)}
        let temporary=workspace.url.appendingPathComponent("temporary");try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let reservation=try workspace.retainedLifetimeDescriptor();defer {close(reservation)}
        let environment=environment(cache:canonical,temporary:temporary)
        let uv=try await runtimeTool(cache:canonical,parent:parent,runtime:runtime,transport:transport,environment:environment,guardian:guardian,keepAlive:[lock,reservation],license:assets["ThirdParty/VisualPreparation/UV-LICENSE-MIT.txt"],progress:progress)
        try parent.requireRootIdentity(at:cache);try Task.checkCancellation()
        progress(.init(phase:"Preparing local Python and model tools",completedBytes:0,totalBytes:0,completedFiles:0,totalFiles:1,file:nil))
        let script=workspace.url.appendingPathComponent("runner/scripts/convert-visual-model.py"),output=workspace.url.appendingPathComponent("converted"),events=VisualPreparationEvents(progress)
        let result=try await PreparationProcess.run(uv,["--no-config","run","--isolated","--frozen","--no-env-file","--managed-python","--python",runtime.python,"--script",script.path,"--source",canonical.appendingPathComponent("source").path,"--output",output.path,"--download","--retry-partials","--progress-json"],environment:environment,guardian:guardian,keepAlive:[lock,reservation],onOutput:{events.append($0)})
        if result.status != 0 {
            struct Diagnostic:Encodable {var status:Int32;var stderr:String}
            if let data=try? JSONEncoder().encode(Diagnostic(status:result.status,stderr:String(decoding:result.stderr,as:UTF8.self))) {
                try? workspace.tree.write(data,as:"last-error.json")
                try? parent.withRootDirectory {destination in try workspace.tree.withRootDirectory {source in
                    guard renameat(source,"last-error.json",destination,"last-visual-setup-error.json")==0 else {throw OSwindError.unavailable("Cannot save preparation diagnostics")}
                }}
            }
        }
        guard result.status==0 else {throw OSwindError.unavailable("Visual model preparation did not finish (tool exit \(result.status)). Verified public downloads remain cached. Check network access, disk space and the preparation guide, then retry.")}
        try Task.checkCancellation();progress(.init(phase:"Installing qualified visual models",completedBytes:0,totalBytes:0,completedFiles:0,totalFiles:1,file:nil))
        let qualification=try JSONDecoder().decode(VisualPreparationQualification.self,from:workspace.tree.read("converted.conversion/qualification.json",limit:131072));try qualification.validate()
        let verified=try VisualModelBundle.verify(at:output),tree=try BackupFileTree(root:output),payload=try BackupWorkspace(in:canonical,label:"oswind-visual-prepare")
        defer {withExtendedLifetime(payload){}}
        for file in verified.bundle.model.files {_ = try tree.pin(file.path,to:payload.tree,as:"model/"+file.path)}
        _ = try tree.pin("OSWIND-VISION.json",to:payload.tree,as:"model/OSWIND-VISION.json")
        let final=try VisualModelBundle.verify(at:payload.url.appendingPathComponent("model"));guard final.modelID==verified.modelID else {throw OSwindError.invalid("Prepared model changed before publication")}
        let receipt=VisualPreparationReceipt(modelID:final.modelID,buildID:runtime.buildID,runtimeVersion:runtime.version,pythonVersion:runtime.python,qualification:qualification),encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try payload.tree.write(encoder.encode(receipt),as:"qualification.json")
        try Task.checkCancellation();try parent.requireRootIdentity(at:cache);try payload.publish(as:destination)
        progress(.init(phase:"Local visual model ready",completedBytes:final.bundle.model.bytes,totalBytes:final.bundle.model.bytes,completedFiles:1,totalFiles:1,file:nil))
        return .init(directory:destination.appendingPathComponent("model"),modelID:final.modelID,bytes:final.bundle.model.bytes,reused:false)
    }
    static func runtimeTool(cache:URL,parent:BackupFileTree,runtime:VisualPreparationRuntime,transport:any NativeModelTransport,environment:[String:String],guardian:URL?=nil,keepAlive:[Int32]=[],license:Data?=nil,progress:@escaping @Sendable (NativeModelProgress)->Void) async throws -> URL {
        let destination=cache.appendingPathComponent("uv-"+runtime.version),executable=destination.appendingPathComponent("uv")
        if try NativeModelInstaller.exists(destination) {
            let tree=try BackupFileTree(root:destination,writable:license != nil),digest=try tree.digest("uv")
            guard digest.bytes==runtime.executableBytes,digest.sha256==runtime.executableSHA256 else {throw OSwindError.invalid("The cached preparation tool changed; choose a fresh preparation cache")}
            if let license {
                if try NativeModelInstaller.exists(destination.appendingPathComponent("LICENSE-MIT.txt")) {guard try tree.read("LICENSE-MIT.txt",limit:65536)==license else {throw OSwindError.invalid("The cached preparation license changed")}}
                else {try tree.write(license,as:"LICENSE-MIT.txt")}
            }
            return executable
        }
        let workspace=try BackupWorkspace(in:cache,label:"oswind-visual-prepare");defer {withExtendedLifetime(workspace){}}
        let file=NativeModelManifest.File(path:"uv.tar.gz",bytes:runtime.bytes,sha256:runtime.sha256)
        guard let url=URL(string:runtime.url),url.scheme=="https",url.host=="github.com" else {throw OSwindError.invalid("Invalid pinned preparation tool URL")}
        try await NativeModelInstaller.download(file,from:url,to:workspace.tree,transport:transport) {bytes in progress(.init(phase:"Downloading local preparation tool",completedBytes:bytes,totalBytes:runtime.bytes,completedFiles:0,totalFiles:1,file:nil))}
        let digest=try workspace.tree.digest(file.path);guard digest.bytes==runtime.bytes,digest.sha256==runtime.sha256 else {throw OSwindError.invalid("Preparation tool checksum mismatch")}
        let reservation=try workspace.retainedLifetimeDescriptor();defer {close(reservation)}
        let extracted=try await PreparationProcess.run(URL(fileURLWithPath:"/usr/bin/tar"),["-xf",workspace.url.appendingPathComponent(file.path).path,"-C",workspace.url.path,runtime.member],environment:environment,timeout:60,guardian:guardian,keepAlive:keepAlive+[reservation])
        guard extracted.status==0 else {throw OSwindError.unavailable("Cannot unpack the verified preparation tool")}
        let actual=try workspace.tree.digest(runtime.member);guard actual.bytes==runtime.executableBytes,actual.sha256==runtime.executableSHA256 else {throw OSwindError.invalid("Preparation executable checksum mismatch")}
        let payload=try BackupWorkspace(in:cache,label:"oswind-visual-prepare");defer {withExtendedLifetime(payload){}}
        _ = try workspace.tree.pin(runtime.member,to:payload.tree,as:"uv")
        if let license {try payload.tree.write(license,as:"LICENSE-MIT.txt")}
        try payload.tree.withFile("uv") {fd,_ in guard fchmod(fd,0o700)==0 else {throw OSwindError.unavailable("Cannot make the verified preparation tool executable")}}
        try parent.requireRootIdentity(at:cache);try Task.checkCancellation();try payload.publish(as:destination)
        return executable
    }
}
