import Foundation
import CryptoKit
import Darwin
import CPIIRuntime

public enum PIIComputePolicy:String,Codable,Sendable {case cpu,coreML}

public struct PIIInspection:Codable,Sendable {
    public struct Span:Codable,Sendable {
        public let startUTF16:Int,lengthUTF16:Int,label:String,category:String,confidence:Float
    }
    public struct Mask:Codable,Sendable {public let startUTF16:Int,lengthUTF16:Int}
    public let sourceSHA256:String,modelID:String,compute:PIIComputePolicy,threshold:Double
    public let text:String,spans:[Span],modelMasks:[Mask],masks:[Mask]
    public let modelRedacted:Bool,patternRedacted:Bool,redacted:Bool,suppressMedia:Bool
}

struct PIINativeOutput:Sendable {
    let sourceSHA256:String,modelID:String,shape:[Int],logits:[Float]
}
protocol PIINativeBackend:Sendable {
    func predict(_ text:String) async throws -> PIINativeOutput
    func close()
}

/// Explicit, experimental local inspection. Does not open desktop history,
/// capture, select a production privacy policy, or claim exhaustive detection.
/// One session owns a FIFO queue; shutdown waits for native work to finish.
public actor PIIInspector {
    private let compute:PIIComputePolicy,modelID:String
    private let loader:@Sendable () async throws -> any PIINativeBackend
    private var backend:(any PIINativeBackend)?
    private var busy=false,closed=false
    private var generation=UUID()
    private var waiters:[(UUID,CheckedContinuation<Void,Error>)]=[]
    private var shutdownWaiters:[CheckedContinuation<Void,Never>]=[]
    private var idleTimer=NativeModelIdleTimer()
    public private(set) var retentionPolicy=NativeModelRetention.twoMinutes
    /// Session ownership, not a measurement of physical or device memory.
    public var modelResident:Bool {backend != nil}
    var queuedRequestCount:Int {waiters.count}
    var isShutDown:Bool {closed}

    public init(modelDirectory:URL,runtimeLibrary:URL,compute:PIIComputePolicy) {
        self.compute=compute;modelID=PIILocalBackend.identifier(compute)
        loader={try await PIILocalBackend.load(directory:modelDirectory,library:runtimeLibrary,compute:compute)}
    }
    init(compute:PIIComputePolicy = .cpu,loader:@escaping @Sendable () async throws -> any PIINativeBackend,
         idleSleep:@escaping @Sendable (Double) async throws -> Void={try await Task.sleep(for:.seconds($0))}) {
        self.compute=compute;modelID=PIILocalBackend.identifier(compute);self.loader=loader
        idleTimer=NativeModelIdleTimer(sleep:idleSleep)
    }
    static func expectedModelID(_ compute:PIIComputePolicy)->String {PIILocalBackend.identifier(compute)}
    private func acquire(_ id:UUID) async throws {
        try Task.checkCancellation()
        guard !closed else {throw OSwindError.unavailable("PII inspector is shut down")}
        idleTimer.cancel()
        if !busy {busy=true;return}
        guard waiters.count<32 else {throw OSwindError.unavailable("PII queue is full; no scan returned")}
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {waiters.append((id,$0))}
        } onCancel: {Task {await self.cancelWaiter(id)}}
    }
    private func cancelWaiter(_ id:UUID) {
        if let index=waiters.firstIndex(where:{$0.0==id}) {waiters.remove(at:index).1.resume(throwing:CancellationError())}
    }
    private func closeBackend() {backend?.close();backend=nil;idleTimer.cancel()}
    private func release() {
        if closed {
            closeBackend();busy=false
            let acknowledgments=shutdownWaiters;shutdownWaiters=[]
            for acknowledgment in acknowledgments {acknowledgment.resume()}
        } else if !waiters.isEmpty {waiters.removeFirst().1.resume()}
        else {busy=false;scheduleIdle()}
    }
    public func setRetention(_ policy:NativeModelRetention) {
        retentionPolicy=policy;idleTimer.cancel();if !busy && !closed {scheduleIdle()}
    }
    private func scheduleIdle() {
        guard backend != nil else {return}
        if retentionPolicy == .afterUse {closeBackend();return}
        idleTimer.schedule(retentionPolicy) {[weak self] token in await self?.expire(token)}
    }
    private func expire(_ token:UUID) {
        guard token==idleTimer.generation,!busy,!closed,waiters.isEmpty else {return};closeBackend()
    }
    public func unload() async throws {
        try await acquire(UUID());defer {release()};try Task.checkCancellation();closeBackend()
    }
    /// Terminal and idempotent. Cancellation of a shutdown caller cannot skip
    /// its drain barrier or acknowledge before the native session is destroyed.
    public func shutdown() async {
        closed=true;generation=UUID();idleTimer.cancel()
        let queued=waiters;waiters=[]
        for waiter in queued {waiter.1.resume(throwing:CancellationError())}
        if !busy {closeBackend();return}
        await withCheckedContinuation {shutdownWaiters.append($0)}
    }
    public func inspect(_ text:String,threshold:Double) async throws -> PIIInspection {
        guard threshold.isFinite,threshold>0,threshold<1 else {throw OSwindError.invalid("PII threshold must be strictly between zero and one")}
        let source=try PIIDecoding.Source(text)
        guard !source.words.isEmpty else {throw OSwindError.invalid("PII input has no non-whitespace words")}
        try await acquire(UUID());defer {release()}
        try Task.checkCancellation()
        guard !closed else {throw CancellationError()};let token=generation
        if backend==nil {
            let candidate=try await loader()
            guard !closed,generation==token,!Task.isCancelled else {candidate.close();throw CancellationError()}
            backend=candidate
        }
        guard let backend else {throw OSwindError.unavailable("PII model is unavailable")}
        do {
            let output=try await backend.predict(text)
            try Task.checkCancellation()
            guard !closed,generation==token else {throw CancellationError()}
            guard output.sourceSHA256==source.sha256,output.modelID==modelID else {throw OSwindError.invalid("PII output belongs to another source or model")}
            let detection=try PIIDecoding.decode(source:source,shape:output.shape,logits:output.logits,threshold:threshold)
            let masked=try PIIDecoding.redact(text,detection:detection)
            let patterns=PrivacyPolicy().sensitiveRanges(in:text)
            let final=try PIIDecoding.mask(text,ranges:masked.ranges+patterns)
            try Task.checkCancellation()
            let redacted=final.redacted
            return PIIInspection(sourceSHA256:source.sha256,modelID:modelID,compute:compute,threshold:threshold,
                text:final.text,spans:detection.spans.map {.init(startUTF16:$0.range.location,lengthUTF16:$0.range.length,label:$0.promptLabel,category:$0.category,confidence:$0.confidence)},
                modelMasks:masked.ranges.map {.init(startUTF16:$0.location,lengthUTF16:$0.length)},
                masks:final.ranges.map {.init(startUTF16:$0.location,lengthUTF16:$0.length)},
                modelRedacted:masked.redacted,patternRedacted:!patterns.isEmpty,redacted:redacted,suppressMedia:redacted)
        } catch {closeBackend();throw error}
    }
}

/// Lock also protects destruction against an accidentally retained backend
/// reference. Cancellation joins synchronous native work before releasing it.
private final class PIILocalBackend:PIINativeBackend,@unchecked Sendable {
    private let tokenizer:PIITokenizer,compute:PIIComputePolicy,snapshot:URL
    private let lock=NSLock()
    private var session:OpaquePointer?
    static func identifier(_ compute:PIIComputePolicy)->String {
        "gliner-pii-edge:9b7f39b0a2da971a5beea78d35f1539d4009c891:token-v1:grapheme-v1:\(compute.rawValue)"
    }
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
    static func load(directory:URL,library:URL,compute:PIIComputePolicy) async throws -> any PIINativeBackend {
        let job=Task.detached(priority:.utility) {try PIILocalBackend(directory:directory,library:library,compute:compute)}
        return try await withTaskCancellationHandler {
            let result=try await job.value
            if Task.isCancelled {result.close();throw CancellationError()};return result
        } onCancel: {job.cancel()}
    }
    private init(directory:URL,library:URL,compute:PIIComputePolicy)throws {
        self.compute=compute;tokenizer=try PIITokenizer(directory:directory)
        let modelTree=try BackupFileTree(root:directory)
        let model=try modelTree.read(compute == .cpu ? "onnx/model.onnx":"onnx/model-bucket128.onnx",limit:181078966)
        let expected=compute == .cpu ? "4ca588722e6d79447ad4c9c230eeba3d9d472c672a9598184a34e9f77fc35836":"a6a66d8a988b9507b6d8d714a727ca47fcacef6b5090825f79b86be917e3e136"
        guard Self.digest(model)==expected else {throw OSwindError.invalid("PII graph differs from the pinned model")}
        let runtimeTree=try BackupFileTree(root:library.deletingLastPathComponent())
        let runtime=try runtimeTree.read(library.lastPathComponent,limit:27651368)
        guard runtime.count==27651368,Self.digest(runtime)=="94e1e79a7eae49dd6dec88c2ada0bf30ed2f04f02dd03abc12d7d8ebed92cdfa" else {throw OSwindError.invalid("PII runtime differs from pinned macOS arm64 ONNX Runtime1.24.2")}
        try Task.checkCancellation()
        snapshot=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-pii-runtime-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:snapshot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            let file=snapshot.appendingPathComponent("runtime.dylib")
            let fd=open(file.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd>=0 else {throw OSwindError.unavailable("Cannot create private PII runtime snapshot")}
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            do {try handle.write(contentsOf:runtime);guard fchmod(fd,0o400)==0 else {throw OSwindError.unavailable("Cannot seal private PII runtime snapshot")};try handle.close()}
            catch {try? handle.close();throw error}
            try Task.checkCancellation()
            let snapshotTree=try BackupFileTree(root:snapshot)
            var native:OpaquePointer?,error=Array(repeating:CChar(0),count:2048)
            let status=try snapshotTree.withFile("runtime.dylib") {descriptor,_ in
                model.withUnsafeBytes {bytes in
                    OSWPiiCreate("/dev/fd/\(descriptor)",bytes.baseAddress,bytes.count,compute == .coreML ? 1:0,&native,&error,error.count)
                }
            }
            guard status==0,let native else {throw OSwindError.unavailable("Pinned native PII model initialization failed; no scan returned")}
            session=native
            if Task.isCancelled {close();throw CancellationError()}
        } catch {try? FileManager.default.removeItem(at:snapshot);throw error}
    }
    func close() {
        lock.lock();defer {lock.unlock()}
        if let session {self.session=nil;OSWPiiDestroy(session)}
        try? FileManager.default.removeItem(at:snapshot)
    }
    deinit {close()}
    func predict(_ text:String) async throws -> PIINativeOutput {
        let job=Task.detached(priority:.utility) {try self.run(text)}
        return try await withTaskCancellationHandler {
            let output=try await job.value;try Task.checkCancellation();return output
        } onCancel: {job.cancel()}
    }
    private func run(_ text:String)throws->PIINativeOutput {
        lock.lock();defer {lock.unlock()};try Task.checkCancellation()
        guard let session else {throw OSwindError.unavailable("PII native session is closed")}
        let input=try tokenizer.encode(text)
        var ids=input.inputIDs,attention=input.attentionMask,mask=input.wordsMask
        if compute == .coreML {
            guard ids.count<=128 else {throw OSwindError.invalid("PII input exceeds the fixed128 Core ML bucket; no truncated scan returned")}
            let padding=128-ids.count;ids += Array(repeating:50283,count:padding)
            attention += Array(repeating:0,count:padding);mask += Array(repeating:0,count:padding)
        }
        let count=input.words.count*36
        var logits=Array(repeating:Float(0),count:count),error=Array(repeating:CChar(0),count:2048)
        let status=ids.withUnsafeBufferPointer {ids in attention.withUnsafeBufferPointer {attention in mask.withUnsafeBufferPointer {mask in
            OSWPiiRun(session,ids.baseAddress,attention.baseAddress,mask.baseAddress,ids.count,input.textLength,&logits,count,&error,error.count)
        }}}
        try Task.checkCancellation()
        guard status==0 else {throw OSwindError.unavailable("Native PII inference failed; no scan returned")}
        return PIINativeOutput(sourceSHA256:Self.digest(Data(text.utf8)),modelID:Self.identifier(compute),shape:[1,input.words.count,12,3],logits:logits)
    }
}
