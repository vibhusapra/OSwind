import Foundation
import AVFoundation

/// A deliberate dictation stays in RAM until the microphone stops. Device
/// callbacks never enqueue actor tasks or grow beyond thirty seconds of PCM.
final class DictationPCMBuffer:AudioPCMSink,@unchecked Sendable {
    static let maximumSamples=480_000
    private let lock=NSLock()
    private var samples=[Float](),active=true,failure:String?
    var full:Bool {lock.withLock {samples.count==Self.maximumSamples}}
    func add(_ input:UnsafeBufferPointer<Float>,at end:Date) {
        lock.withLock {
            guard active else {return}
            guard input.count>0,input.count<=AudioAccumulator.maximumCallbackSamples,input.allSatisfy(\.isFinite) else {
                samples.removeAll();failure="Microphone audio changed; record again.";active=false;return
            }
            samples.append(contentsOf:input.prefix(Self.maximumSamples-samples.count))
        }
    }
    func fail(_ message:String) {lock.withLock {active=false;samples.removeAll();failure=message}}
    func finish() throws ->[Float] {
        try lock.withLock {
            active=false;defer {samples.removeAll()}
            if let failure {throw OSwindError.unavailable(failure)}
            return samples
        }
    }
    func cancel() {lock.withLock {active=false;samples.removeAll();failure=nil}}
}

@MainActor public protocol DictationRecording:AnyObject {
    func start() async throws
    func finish() throws ->[Float]
    func cancel()
    var full:Bool {get}
}

/// A late permission response after cancellation cannot open a microphone.
@MainActor public final class LocalDictationRecorder:DictationRecording {
    private let authorize:() async ->Bool
    private let makeEngine:() throws ->AVAudioEngine
    private var engine:AVAudioEngine?,sink:DictationPCMBuffer?,generation=UUID()
    private var starting=false
    public convenience init() {self.init(authorize:{await AVCaptureDevice.requestAccess(for:.audio)},makeEngine:{AVAudioEngine()})}
    init(authorize:@escaping () async ->Bool,makeEngine:@escaping () throws ->AVAudioEngine) {self.authorize=authorize;self.makeEngine=makeEngine}
    public var full:Bool {sink?.full ?? false}
    public func start() async throws {
        guard !starting,engine==nil else {throw OSwindError.unavailable("Dictation microphone is already in use.")}
        starting=true;let token=UUID();generation=token
        defer {starting=false}
        let allowed=await authorize()
        try Task.checkCancellation();guard generation==token else {throw CancellationError()}
        guard allowed else {throw OSwindError.unavailable("Allow Microphone access to record dictation.")}
        let sink=DictationPCMBuffer(),engine=try makeEngine()
        let input=engine.inputNode,format=input.outputFormat(forBus:0)
        let converter=try MicrophoneAudioInput(source:format,sink:sink)
        self.sink=sink;self.engine=engine
        input.installTap(onBus:0,bufferSize:4096,format:format) {buffer,_ in converter.consume(buffer)}
        do {try engine.start()}catch {cancel();throw error}
    }
    public func finish() throws ->[Float] {
        engine?.inputNode.removeTap(onBus:0);engine?.stop();engine=nil
        guard let sink else {throw OSwindError.unavailable("No dictation is recording.")}
        self.sink=nil;return try sink.finish()
    }
    public func cancel() {
        generation=UUID()
        engine?.inputNode.removeTap(onBus:0);engine?.stop();engine=nil
        sink?.cancel();sink=nil
    }
}

public enum LocalDictation {
    public static let maximumSeconds=30
    public static func transcribe(samples:[Float],store:MemoryStore,settings:AppSettings,recognizer:SpeechRecognizer) async throws ->SpeechTranscript {
        try await transcribe(samples:samples,store:store) {file,parent in
            try await recognizer.transcribe(file:file,settings:settings,workspaceParent:parent)
        }
    }
    static func transcribe(samples:[Float],store:MemoryStore,recognize:@escaping (URL,URL) async throws ->SpeechTranscript) async throws ->SpeechTranscript {
        try Task.checkCancellation()
        guard samples.count>=1600,samples.count<=DictationPCMBuffer.maximumSamples,samples.allSatisfy(\.isFinite),AudioAccumulator.audible(samples) else {
            throw OSwindError.invalid("Record between 0.1 and 30 seconds of audible speech.")
        }
        let operation=try await store.libraryWorkspaceAsync("oswind-dictation")
        // Keep the workspace and reservation until actual native/model work
        // returns, including implementations that ignore cancellation.
        defer {withExtendedLifetime(operation) {}}
        try Task.checkCancellation();try store.validateDirectoryIdentity()
        let file=operation.url.appendingPathComponent("dictation.wav")
        try operation.tree.write(WAV.data(samples:samples),as:"dictation.wav")
        let result=try await recognize(file,operation.url)
        try Task.checkCancellation();try store.validateDirectoryIdentity()
        return try result.bounded(toSourceDuration:Double(samples.count)/16000)
    }
}
