import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia

public enum WAV {
    public static func data(samples: [Float], sampleRate: UInt32 = 16000) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples { var value = Int16((sample.isFinite ? max(-1, min(1, sample)) : 0) * Float(Int16.max)).littleEndian; withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) } }
        var data = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        number(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8)); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(sampleRate); number(sampleRate * 2); number(UInt16(2)); number(UInt16(16)); data.append(Data("data".utf8)); number(UInt32(pcm.count)); data.append(pcm); return data
    }
    public static func rms(_ samples: [Float]) -> Double { guard !samples.isEmpty else { return 0 }; return sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)) }
}
public enum Whisper {
    public static func transcribe(file: URL, binary: String, model: String, language: String = "en", timeout: Double = 120) async throws -> String {
        try await detailed(file:file,binary:binary,model:model,language:language,timeout:timeout).text
    }
    public static func detailed(file: URL, binary: String, model: String, language: String = "en", timeout: Double = 120) async throws -> SpeechTranscript {
        guard timeout.isFinite,timeout>0,FileManager.default.isExecutableFile(atPath:binary),FileManager.default.fileExists(atPath:model) else { throw OSwindError.unavailable("Install whisper.cpp and choose a downloaded ggml model in Settings → Audio") }
        let task=Task.detached(priority:.utility) {
            _ = try BackupWorkspace.cleanupAbandoned(labels:["oswind-transcription","oswind-audio-chunk"])
            let scratch=try BackupWorkspace(label:"oswind-transcription"), prefix=scratch.url.appendingPathComponent("transcript")
            defer { withExtendedLifetime(scratch) {} }
            let log=prefix.appendingPathExtension("log"); try Data().write(to:log); let handle=try FileHandle(forWritingTo:log); defer { try? handle.close() }
            let process=Process(); process.executableURL=URL(fileURLWithPath:binary); process.arguments=["-m",model,"-f",file.path,"-l",language,"-oj","-of",prefix.path,"-np","-t","4"]; process.standardOutput=handle; process.standardError=handle
            try Task.checkCancellation(); try process.run(); defer { if process.isRunning { process.terminate() } }
            let deadline=ContinuousClock.now.advanced(by:.seconds(timeout))
            while process.isRunning && ContinuousClock.now<deadline { try await Task.sleep(nanoseconds:100_000_000) }
            if process.isRunning { process.terminate(); throw OSwindError.unavailable("Transcription exceeded its time budget") }
            try Task.checkCancellation()
            guard process.terminationStatus==0 else { throw OSwindError.unavailable("whisper.cpp could not transcribe the segment; verify the model and input format") }
            return try parseJSON(scratch.tree.read("transcript.json",limit:32*1024*1024),model:"whisper:"+URL(fileURLWithPath:model).lastPathComponent)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public static func parseJSON(_ data: Data, model: String) throws -> SpeechTranscript {
        struct Document: Decodable {
            struct Segment: Decodable { struct Offsets: Decodable {var from: Double; var to: Double}; var offsets: Offsets; var text: String }
            var transcription: [Segment]
        }
        guard data.count<=32*1024*1024 else { throw OSwindError.invalid("Whisper output is too large") }
        let document=try JSONDecoder().decode(Document.self,from:data)
        let segments=document.transcription.map { TranscriptSegment(start:$0.offsets.from/1000,end:$0.offsets.to/1000,text:$0.text.trimmingCharacters(in:.whitespacesAndNewlines)) }
        let text=segments.map(\.text).joined(separator:" "), duration=segments.map(\.end).max() ?? 0
        return try SpeechTranscript(text:text,duration:duration,segments:segments,model:model).validated()
    }
}
private final class AudioAccumulator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.oswind.audio-buffer", qos: .utility)
    private var samples = [Float]()
    private var active = true
    let emit: ([Float], Date) -> Void
    init(emit: @escaping ([Float], Date) -> Void) { self.emit = emit }
    func add(_ input: [Float]) { queue.async { guard self.active else { return }; self.samples.append(contentsOf: input); if self.samples.count >= 480000 { let chunk = Array(self.samples.prefix(480000)); self.samples.removeFirst(480000); if WAV.rms(chunk) > 0.003 { self.emit(chunk, Date().addingTimeInterval(-30)) } } } }
    func finish() -> [Float] { queue.sync { active = false; let remaining = samples; samples.removeAll(); return remaining } }
    func stop() { queue.sync { active = false; samples.removeAll(keepingCapacity: false) } }
}
@MainActor public final class AudioController: NSObject, ObservableObject, SCStreamOutput {
    @Published public private(set) var running = false
    @Published public private(set) var status = "Audio off"
    @Published public private(set) var transcribed = 0
    public var onCapture: ((Memory) -> Void)?
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var micSink: AudioAccumulator?
    private var systemSink: AudioAccumulator?
    private let audioQueue = DispatchQueue(label: "com.oswind.system-audio", qos: .utility)
    private var pending: [(samples: [Float], date: Date, source: String)] = []
    private var processing = false
    private var finishing = false
    private var transcriptionTask: Task<SpeechTranscript,Error>?
    private var sessionID = UUID().uuidString
    private var privacyTimer: Timer?
    private var epoch = UUID()
    private let store: MemoryStore
    private let embedder: LocalEmbedder
    public var settings: AppSettings
    public init(store: MemoryStore, embedder: LocalEmbedder, settings: AppSettings) { self.store = store; self.embedder = embedder; self.settings = settings }
    public func start() async {
        guard !running else { return }
        guard !SessionState.locked else { status = "Locked · audio suspended"; return }
        guard FileManager.default.isExecutableFile(atPath: settings.whisperBinary), FileManager.default.fileExists(atPath: settings.whisperModel) else { status = "Choose a local Whisper model first"; return }
        guard settings.audioEnabled || settings.systemAudioEnabled else { status = "Enable an audio source in Settings"; return }
        epoch = UUID(); sessionID = UUID().uuidString; finishing = false; running = true
        do {
            if settings.audioEnabled {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw OSwindError.unavailable("Microphone access required") }
                let sink = AudioAccumulator { [weak self] samples,date in Task { @MainActor in self?.enqueue(samples, date: date, source: "Microphone") } }; micSink = sink
                let engine = AVAudioEngine(); let input = engine.inputNode; let source = input.outputFormat(forBus: 0)
                guard source.sampleRate > 0, let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false), let converter = AVAudioConverter(from: source, to: target) else { throw OSwindError.unavailable("Microphone audio format unavailable") }
                input.installTap(onBus: 0, bufferSize: 4096, format: source) { buffer,_ in
                    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / source.sampleRate + 16)) else { return }
                    var supplied = false; var error: NSError?
                    converter.convert(to: output, error: &error) { _,status in if supplied { status.pointee = .noDataNow; return nil }; supplied = true; status.pointee = .haveData; return buffer }
                    if error == nil, let floats = output.floatChannelData?[0] { sink.add(Array(UnsafeBufferPointer(start: floats, count: Int(output.frameLength)))) }
                }
                try engine.start(); self.engine = engine
            }
            if settings.systemAudioEnabled {
                guard CGPreflightScreenCaptureAccess() else { throw OSwindError.unavailable("Screen Recording permission is needed for system audio") }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw OSwindError.unavailable("No display for audio capture") }
                let excluded = content.applications.filter { settings.privacy.excludedApps.contains($0.bundleIdentifier) || $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                let config = SCStreamConfiguration(); config.capturesAudio = true; config.excludesCurrentProcessAudio = true; config.sampleRate = 16000; config.channelCount = 1; config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
                let sink = AudioAccumulator { [weak self] samples,date in Task { @MainActor in self?.enqueue(samples, date: date, source: "System audio") } }; systemSink = sink
                let stream = SCStream(filter: filter, configuration: config, delegate: nil); try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue); try await stream.startCapture(); self.stream = stream
            }
            status = "Transcribing locally · 30 s segments"
            privacyTimer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in self?.checkPrivacy() } }
        } catch { stop(); status = error.localizedDescription }
    }
    public func stop() { privacyTimer?.invalidate(); privacyTimer = nil; transcriptionTask?.cancel(); finishing = false; running = false; epoch = UUID(); engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil; if let stream { Task { try? await stream.stopCapture() } }; stream = nil; micSink?.stop(); systemSink?.stop(); micSink = nil; systemSink = nil; pending.removeAll(); status = "Audio off" }
    public func finish() {
        guard running else { return }
        privacyTimer?.invalidate(); privacyTimer = nil; finishing = true
        let microphone = micSink?.finish() ?? [], system = systemSink?.finish() ?? []
        for (samples, source) in [(microphone,"Microphone"),(system,"System audio")] where samples.count >= 1600 && WAV.rms(samples) > 0.003 {
            enqueue(samples,date:Date().addingTimeInterval(-Double(samples.count)/16000),source:source)
        }
        engine?.inputNode.removeTap(onBus:0); engine?.stop(); engine = nil
        if let stream { Task { try? await stream.stopCapture() } }; stream = nil; micSink = nil; systemSink = nil
        running = false; status = pending.isEmpty && !processing ? "Audio off" : "Finishing local transcript…"
    }
    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, let description = sampleBuffer.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee, asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32, asbd.mChannelsPerFrame == 1 else { return }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)); var block: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard result == noErr, let pointer = list.mBuffers.mData else { return }
        let samples = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Float.self), count: Int(list.mBuffers.mDataByteSize)/4))
        Task { @MainActor in self.systemSink?.add(samples) }
    }
    private func checkPrivacy() {
        guard running else { return }
        if SessionState.locked { stop(); status = "Locked · audio stopped"; return }
        if let context = AccessibilityContext.current(), let reason = settings.privacy.exclusion(app:context.bundle,title:context.title,url:context.url,isBrowser:context.browser) {
            stop(); status = "Audio stopped · " + reason
        }
    }
    private func enqueue(_ samples: [Float], date: Date, source: String) {
        guard running || finishing, !SessionState.locked else { return }
        if let c = AccessibilityContext.current(), settings.privacy.exclusion(app: c.bundle, title: c.title, url: c.url, isBrowser: c.browser) != nil { status = "Audio segment discarded by privacy rule"; return }
        guard pending.count < 3 else { status = "Transcription backpressure · dropped segment"; return }
        pending.append((samples,date,source)); if !processing { Task { await drain() } }
    }
    private func drain() async {
        guard !processing else { return }; processing = true; defer { processing = false }
        while !pending.isEmpty {
            let chunk = pending.removeFirst(), token = epoch, config = settings
            guard let operation=try? BackupWorkspace(label:"oswind-audio-chunk") else { status="Cannot create private audio workspace"; continue }
            defer { withExtendedLifetime(operation) {} }
            let file=operation.url.appendingPathComponent("capture.wav")
            do {
                try WAV.data(samples: chunk.samples).write(to:file,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path); defer { try? FileManager.default.removeItem(at: file) }
                let task = Task { try await Whisper.detailed(file:file,binary:config.whisperBinary,model:config.whisperModel,language:config.transcriptionLanguage) }; transcriptionTask = task
                var transcript = try await task.value; transcriptionTask = nil
                guard token == epoch && !SessionState.locked else { continue }
                if let context=AccessibilityContext.current(),settings.privacy.exclusion(app:context.bundle,title:context.title,url:context.url,isBrowser:context.browser) != nil { continue }
                transcript.duration=Double(chunk.samples.count)/16000
                let m=try AudioAdmission.save(transcript,file:file,store:store,settings:settings,timestamp:chunk.date,source:chunk.source,sessionID:sessionID,embedder:embedder)
                transcribed += 1; status = "\(transcribed) segments transcribed locally"; onCapture?(m)
                do { if settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled { try store.indexApplePassages(m,embedder:embedder) } }
                catch { status="Transcript saved · additional indexing pending" }
            } catch { if !(error is CancellationError) { status = error.localizedDescription }; try? FileManager.default.removeItem(at: file) }
        }
    }
}
