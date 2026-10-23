import Foundation
@preconcurrency import CoreML
import FluidAudio

public struct DiarizationConfiguration: Codable, Equatable, Sendable {
    public var enabled=false
    public var modelDirectory=""
    public init() {}
    enum CodingKeys:CodingKey { case enabled,modelDirectory }
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        enabled=try values.decodeIfPresent(Bool.self,forKey:.enabled) ?? false
        modelDirectory=try values.decodeIfPresent(String.self,forKey:.modelDirectory) ?? ""
    }
    public func localDirectory() throws -> URL {
        guard modelDirectory.hasPrefix("/"),!modelDirectory.utf8.contains(0) else { throw OSwindError.invalid("Choose an absolute local speaker-model directory") }
        let directory=URL(fileURLWithPath:modelDirectory,isDirectory:true).resolvingSymlinksInPath()
        var flag:ObjCBool=false
        guard FileManager.default.fileExists(atPath:directory.path,isDirectory:&flag),flag.boolValue else { throw OSwindError.unavailable("Speaker-model directory is unavailable") }
        for name in ["Segmentation.mlmodelc","FBank.mlmodelc","Embedding.mlmodelc","PldaRho.mlmodelc","plda-parameters.json"] {
            guard FileManager.default.fileExists(atPath:directory.appendingPathComponent(name).path) else { throw OSwindError.unavailable("Speaker model is incomplete: missing "+name) }
        }
        return directory
    }
}
protocol SpeakerDiarizationBackend:Sendable { func turns(file:URL) async throws -> [SpeakerTurn] }
enum SpeakerNativePolicy {
    static let version="overlap-preserving-v1"
    static func configuration() -> OfflineDiarizerConfig {
        var config=OfflineDiarizerConfig.default
        // The product's mixed-span attribution must see both active voices.
        // Exclusive SDK output trims overlap before that safeguard can run.
        config.postProcessing.exclusiveSegments=false
        config.embeddingExportPath=nil;config.exposeChunkEmbeddings=false
        return config
    }
}
private actor CoreMLSpeakerBackend:SpeakerDiarizationBackend {
    let manager:OfflineDiarizerManager
    init(models:OfflineDiarizerModels) {
        // No embedding/profile export, even when the upstream SDK adds options.
        let config=SpeakerNativePolicy.configuration()
        manager=OfflineDiarizerManager(config:config); manager.initialize(models:models)
    }
    func turns(file:URL) async throws -> [SpeakerTurn] {
        let result=try await manager.process(file); try Task.checkCancellation()
        // Voice embeddings exist only inside this operation; never serialize or
        // persist the SDK's speaker database/chunk embedding payloads.
        return result.segments.map { SpeakerTurn(start:Double($0.startTimeSeconds),end:Double($0.endTimeSeconds),speaker:$0.speakerId) }
    }
    static func load(_ directory:URL) async throws -> any SpeakerDiarizationBackend {
        let worker=Task.detached(priority:.utility) {
            try Task.checkCancellation()
            let started=Date()
            func model(_ name:String,cpu:Bool=false) throws -> MLModel {
                try Task.checkCancellation()
                let config=MLModelConfiguration(); config.computeUnits=cpu ? .cpuOnly:.all
                return try MLModel(contentsOf:directory.appendingPathComponent(name),configuration:config)
            }
            let psi=try SpeakerModelParameters.psi(in:directory)
            let models=try OfflineDiarizerModels(segmentationModel:model("Segmentation.mlmodelc"),fbankModel:model("FBank.mlmodelc",cpu:true),embeddingModel:model("Embedding.mlmodelc"),pldaRhoModel:model("PldaRho.mlmodelc"),pldaPsi:psi,compilationDuration:Date().timeIntervalSince(started))
            try Task.checkCancellation()
            return CoreMLSpeakerBackend(models:models)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
// Match the upstream PLDA contract while keeping loading exact/local and bounded.
// OfflineDiarizerModels.load may download; manager.prepareModels may purge a
// caller's cache after an error. Neither API is used for recognition here.
enum SpeakerModelParameters {
    static func psi(in directory:URL) throws -> [Double] {
        struct Document:Decodable {
            struct Tensor:Decodable { var shape:[Int]; var dtype:String; var data_base64:String }
            var tensors:[String:Tensor]
        }
        let data=try BackupFileTree(root:directory).read("plda-parameters.json",limit:1024*1024)
        let document=try JSONDecoder().decode(Document.self,from:data)
        guard let psi=document.tensors["psi"],psi.shape==[128],psi.dtype=="float32",let bytes=Data(base64Encoded:psi.data_base64),bytes.count==512 else { throw OSwindError.invalid("Invalid speaker PLDA parameters") }
        let values=bytes.withUnsafeBytes { buffer in (0..<128).map { Double(Float(bitPattern:UInt32(littleEndian:buffer.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self)))) } }
        guard values.allSatisfy({$0.isFinite && $0>0}) else { throw OSwindError.invalid("Non-finite or non-positive speaker PLDA parameters") }
        return values
    }
}

public actor SpeakerDiarizer {
    public static let policyVersion=SpeakerNativePolicy.version
    public static var supported:Bool { if #available(macOS 15,*) { return true }; return false }
    private let loader:@Sendable (URL) async throws -> any SpeakerDiarizationBackend
    private let supportedOS:@Sendable () -> Bool
    private var backend:(any SpeakerDiarizationBackend)?
    private var loadedDirectory:URL?
    private var busy=false
    private var waiters=[(UUID,CheckedContinuation<Void,Error>)]()
    var queuedRequestCount:Int { waiters.count }
    public init() {
        AppLogger.minimumLevel = .warning; AppLogger.mirrorsToConsole=false
        loader={ try await CoreMLSpeakerBackend.load($0) }; supportedOS={Self.supported}
    }
    init(loader:@escaping @Sendable (URL) async throws -> any SpeakerDiarizationBackend,supported:@escaping @Sendable () -> Bool={true}) { self.loader=loader; self.supportedOS=supported }
    private func acquire(_ id:UUID) async throws {
        try Task.checkCancellation()
        if !busy { busy=true; return }
        guard waiters.count<8 else { throw OSwindError.unavailable("Speaker recognition queue is full") }
        try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { waiters.append((id,$0)) } } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id:UUID) { if let index=waiters.firstIndex(where:{$0.0==id}) { waiters.remove(at:index).1.resume(throwing:CancellationError()) } }
    private func release() { if waiters.isEmpty { busy=false } else { waiters.removeFirst().1.resume() } }
    public func unload() async throws { try await acquire(UUID()); defer { release() }; try Task.checkCancellation(); backend=nil; loadedDirectory=nil }
    public func annotate(_ transcript:SpeechTranscript,file:URL,configuration:DiarizationConfiguration,timeout:Double=1800) async throws -> SpeechTranscript {
        try Task.checkCancellation(); _ = try transcript.validated()
        guard configuration.enabled else { return transcript }
        let result=try await timeline(file:file,duration:transcript.duration,configuration:configuration,timeout:timeout)
        return try SpeakerAttribution.attach(result.turns,to:transcript,model:result.model)
    }
    /// The caller supplies the duration of the normalized input, independent of
    /// ASR word coverage. CLI callers obtain it from AudioClipSnapshot.
    public func timeline(file:URL,duration:Double,configuration:DiarizationConfiguration,timeout:Double=1800) async throws -> SpeakerTimeline {
        try Task.checkCancellation()
        _ = try SpeakerTimeline(duration:duration,model:"validation",turns:[]).validated()
        guard configuration.enabled else {throw OSwindError.invalid("Enable speaker recognition before requesting a timeline")}
        let turns=try await recognize(file:file,configuration:configuration,timeout:timeout)
        return try SpeakerTimeline(duration:duration,model:"Community-1 · \(Self.policyVersion) · local Core ML / FluidAudio 0.17.7",turns:turns).validated()
    }
    private func recognize(file:URL,configuration:DiarizationConfiguration,timeout:Double) async throws -> [SpeakerTurn] {
        // SDK documents a crash-prone BNNS path on macOS 14; never enter it.
        guard supportedOS() else { throw OSwindError.unavailable("Speaker diarization requires macOS 15 or later; turn it off to use transcription on macOS 14") }
        guard timeout.isFinite,timeout>0,timeout<=86400 else { throw OSwindError.invalid("Invalid speaker recognition time budget") }
        let directory=try configuration.localDirectory(),deadline=ContinuousClock.now.advanced(by:.seconds(timeout))
        try await acquire(UUID()); defer { release() }; try Task.checkCancellation()
        if loadedDirectory != directory || backend==nil {
            backend=nil; loadedDirectory=nil
            let candidate=try await loader(directory); try Task.checkCancellation()
            backend=candidate; loadedDirectory=directory
        }
        guard let backend,ContinuousClock.now<deadline else { throw OSwindError.unavailable("Speaker recognition exceeded its time budget") }
        let operation=Task { try await backend.turns(file:file) }
        let watchdog=Task { try await ContinuousClock().sleep(until:deadline); operation.cancel() }; defer { watchdog.cancel() }
        do {
            let turns=try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            guard ContinuousClock.now<deadline else { throw OSwindError.unavailable("Speaker recognition exceeded its time budget") }
            return turns
        } catch {
            try Task.checkCancellation()
            if ContinuousClock.now>=deadline { throw OSwindError.unavailable("Speaker recognition exceeded its time budget") }
            throw error
        }
    }
}
