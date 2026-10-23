import Foundation
@preconcurrency import CoreML
import FluidAudio

public enum SpeechEngine: String, Codable, CaseIterable, Sendable {
    case whisper, parakeet
    public var title: String { self == .whisper ? "Whisper.cpp" : "Parakeet v3 · Core ML" }
}
public enum SpeechCompute: String, Codable, CaseIterable, Sendable {
    case neuralEngine, gpu, cpu
    public var title: String { switch self { case .neuralEngine:return "Neural Engine + CPU"; case .gpu:return "GPU + CPU"; case .cpu:return "CPU only" } }
    var units: MLComputeUnits { switch self { case .neuralEngine:return .cpuAndNeuralEngine; case .gpu:return .cpuAndGPU; case .cpu:return .cpuOnly } }
}
public struct SpeechConfiguration: Codable, Equatable, Sendable {
    public var engine: SpeechEngine = .whisper
    public var compute: SpeechCompute = .neuralEngine
    public var modelDirectory = ""
    public init() {}
    enum CodingKeys: CodingKey { case engine, compute, modelDirectory }
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        engine=try values.decodeIfPresent(SpeechEngine.self,forKey:.engine) ?? .whisper
        compute=try values.decodeIfPresent(SpeechCompute.self,forKey:.compute) ?? .neuralEngine
        modelDirectory=try values.decodeIfPresent(String.self,forKey:.modelDirectory) ?? ""
    }
    public func validateLocalModel() throws -> URL {
        guard !modelDirectory.isEmpty,!modelDirectory.utf8.contains(0),modelDirectory.hasPrefix("/") else { throw OSwindError.invalid("Choose an absolute local Parakeet v3 model directory") }
        let directory=URL(fileURLWithPath:modelDirectory,isDirectory:true).resolvingSymlinksInPath()
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:directory.path,isDirectory:&isDirectory),isDirectory.boolValue else { throw OSwindError.unavailable("Parakeet model directory is unavailable") }
        for name in ["Preprocessor.mlmodelc","Encoder.mlmodelc","Decoder.mlmodelc","JointDecisionv3.mlmodelc","parakeet_vocab.json"] {
            guard FileManager.default.fileExists(atPath:directory.appendingPathComponent(name).path) else { throw OSwindError.unavailable("Parakeet model is incomplete: missing "+name) }
        }
        return directory
    }
}

protocol NativeSpeechBackend: Sendable {
    func transcribe(file:URL,language:String) async throws -> SpeechTranscript
}
private struct ParakeetSpeechBackend: NativeSpeechBackend {
    let manager: AsrManager
    func transcribe(file:URL,language:String) async throws -> SpeechTranscript {
        let hint:Language?
        if language == "auto" { hint=nil }
        else { guard let value=Language(rawValue:language) else { throw OSwindError.invalid("Unsupported Parakeet language hint; use auto or a supported language code") }; hint=value }
        // Fresh decoder state for every independent clip. Resident weights never
        // imply carrying linguistic state between libraries/conversations.
        var state=try TdtDecoderState()
        let result=try await manager.transcribe(file,decoderState:&state,language:hint)
        try Task.checkCancellation()
        let words=buildWordTimings(from:result.tokenTimings ?? [])
        let segments=words.map { TranscriptSegment(start:$0.startTime,end:$0.endTime,text:$0.word) }
        return try SpeechTranscript(text:result.text.trimmingCharacters(in:.whitespacesAndNewlines),duration:result.duration,segments:segments,model:"parakeet-v3:FluidAudio-0.17.7").validated()
    }
    static func load(_ configuration:SpeechConfiguration) async throws -> any NativeSpeechBackend {
        #if !arch(arm64)
        guard configuration.compute == .cpu else { throw OSwindError.unavailable("Choose CPU only for Parakeet on Intel, or use Whisper") }
        #endif
        let directory=try configuration.validateLocalModel()
        // loadLocal never resolves a model repository, downloads, or deletes a
        // caller's model cache. Core ML compilation may not be interruptible.
        let job=Task.detached(priority:.utility) {
            try Task.checkCancellation()
            let config=MLModelConfiguration(); config.computeUnits=configuration.compute.units
            let models=try AsrModels.loadLocal(from:directory,version:.v3,configuration:config,encoderComputeUnits:configuration.compute.units)
            try Task.checkCancellation()
            return ParakeetSpeechBackend(manager:AsrManager(models:models))
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}

/// One resident native model, with FIFO serialization across live capture and
/// imports. Cancellation removes queued work; an in-flight Core ML call may
/// finish, but its cancelled result is never admitted to the memory store.
public actor SpeechRecognizer {
    private var backend:(any NativeSpeechBackend)?
    private var loadedConfiguration:SpeechConfiguration?
    private var busy=false
    private var waiters:[(UUID,CheckedContinuation<Void,Error>)]=[]
    var queuedRequestCount:Int { waiters.count }
    private let loader:@Sendable (SpeechConfiguration) async throws -> any NativeSpeechBackend
    public init() {
        // The SDK's debug defaults may include transcript text. Disable those
        // messages at every sink and console mirroring for higher levels too.
        AppLogger.minimumLevel = .warning; AppLogger.mirrorsToConsole=false
        loader={ try await ParakeetSpeechBackend.load($0) }
    }
    init(loader:@escaping @Sendable (SpeechConfiguration) async throws -> any NativeSpeechBackend) { self.loader=loader }
    private func acquire(_ id:UUID) async throws {
        try Task.checkCancellation()
        if !busy { busy=true; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id,$0)) }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id:UUID) {
        if let i=waiters.firstIndex(where:{$0.0==id}) { waiters.remove(at:i).1.resume(throwing:CancellationError()) }
    }
    private func release() {
        if waiters.isEmpty { busy=false } else { waiters.removeFirst().1.resume() }
    }
    public func unload() async throws {
        try await acquire(UUID()); defer { release() }; try Task.checkCancellation()
        backend=nil; loadedConfiguration=nil
    }
    public func prepare(settings:AppSettings) async throws {
        guard settings.speech.engine == .parakeet else { return }
        try await acquire(UUID()); defer { release() }; try Task.checkCancellation()
        _ = try await preparedBackend(settings.speech)
    }
    private func preparedBackend(_ configuration:SpeechConfiguration) async throws -> any NativeSpeechBackend {
        if loadedConfiguration != configuration || backend == nil {
            backend=nil; loadedConfiguration=nil
            let candidate=try await loader(configuration)
            try Task.checkCancellation()
            backend=candidate; loadedConfiguration=configuration
        }
        guard let backend else { throw OSwindError.unavailable("Native recognizer is unavailable") }
        return backend
    }
    public func transcribe(file:URL,settings:AppSettings,timeout:Double=120) async throws -> SpeechTranscript {
        try Task.checkCancellation()
        guard timeout.isFinite,timeout>0,timeout<=86400 else { throw OSwindError.invalid("Speech time budget must be between zero and 24 hours") }
        if settings.speech.engine == .whisper {
            return try await Whisper.detailed(file:file,binary:settings.whisperBinary,model:settings.whisperModel,language:settings.transcriptionLanguage,timeout:timeout)
        }
        let deadline=ContinuousClock.now.advanced(by:.seconds(timeout))
        try await acquire(UUID()); defer { release() }; try Task.checkCancellation()
        let backend=try await preparedBackend(settings.speech)
        guard ContinuousClock.now<deadline else { throw OSwindError.unavailable("Transcription exceeded its time budget") }
        let operation=Task { try await backend.transcribe(file:file,language:settings.transcriptionLanguage) }
        let watchdog=Task { try await ContinuousClock().sleep(until:deadline); operation.cancel() }
        defer { watchdog.cancel() }
        do {
            let result=try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            guard ContinuousClock.now<deadline else { throw OSwindError.unavailable("Transcription exceeded its time budget") }
            return try result.validated()
        } catch {
            try Task.checkCancellation()
            if ContinuousClock.now>=deadline { throw OSwindError.unavailable("Transcription exceeded its time budget") }
            throw error
        }
    }
}
