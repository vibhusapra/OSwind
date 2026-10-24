import Foundation

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
    public init(start: Double, end: Double, text: String, speaker: String? = nil) { self.start=start; self.end=end; self.text=text; self.speaker=speaker }
}
public struct SpeechTranscript: Codable, Equatable, Sendable {
    public var text: String
    public var duration: Double
    public var segments: [TranscriptSegment]
    public var model: String
    public var diarization:DiarizationInfo?
    public init(text: String, duration: Double, segments: [TranscriptSegment], model: String, diarization:DiarizationInfo?=nil) { self.text=text; self.duration=duration; self.segments=segments; self.model=model; self.diarization=diarization }
    public func validated() throws -> Self {
        guard duration.isFinite,duration>0,duration<=86400,text.count<=1_000_000,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,segments.count<=100000,!model.isEmpty,model.utf8.count<=1024 else { throw OSwindError.invalid("Invalid or oversized speech transcript") }
        if let info=diarization {
            guard info.scope=="recording",!info.model.isEmpty,info.model.utf8.count<=1024,(0...256).contains(info.detectedSpeakers),info.unassignedSegments==segments.filter({$0.speaker==nil}).count,Set(segments.compactMap(\.speaker)).count<=info.detectedSpeakers else { throw OSwindError.invalid("Invalid diarization metadata") }
        }
        var previous = 0.0
        for segment in segments {
            guard segment.start.isFinite,segment.end.isFinite,segment.start>=0,segment.start>=previous,segment.end>=segment.start,segment.end<=duration+0.5,segment.text.count<=100000,segment.speaker.map({!$0.isEmpty && $0.count<=128}) ?? true else { throw OSwindError.invalid("Invalid transcript timestamps or speaker label") }
            previous=segment.start
        }
        return self
    }
    /// Align decoder metadata to the independently measured input duration.
    /// A segment crossing EOF keeps its text and is clipped to the source.
    /// A positive-length segment wholly beyond EOF remains an error; do not
    /// fabricate source time or silently drop recognized content.
    public func bounded(toSourceDuration sourceDuration:Double) throws -> Self {
        _ = try validated()
        guard sourceDuration.isFinite,sourceDuration>0,sourceDuration<=86400 else {throw OSwindError.invalid("Invalid source audio duration")}
        var result=self;result.duration=sourceDuration
        for index in result.segments.indices {
            let segment=result.segments[index]
            guard segment.start<=sourceDuration,segment.start<sourceDuration || segment.end==segment.start else {throw OSwindError.invalid("Transcript segment is outside the source audio")}
            result.segments[index].end=min(segment.end,sourceDuration)
        }
        return try result.validated()
    }
    /// Pattern-based redaction cannot alter the underlying voice recording.
    /// Any detected secret therefore suppresses retention of the entire clip.
    private static let spokenCredential = try? NSRegularExpression(pattern:#"\b(?:password|passcode|pass[ -]?phrase|pin|api[ -]?key|access[ -]?token|secret[ -]?key|credit[ -]?card\s+number|social\s+security\s+number)\s+(?:is|was|equals|colon)\b"#,options:.caseInsensitive)
    private static func hasSpokenCredential(_ text: String) -> Bool { spokenCredential?.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) != nil }
    public func sanitized(policy: PrivacyPolicy) throws -> (transcript: Self, suppressAudio: Bool) {
        _ = try validated(); guard policy.redactSecrets else { return (self,false) }
        var result=self; result.model=policy.sanitize(model).text
        if let info=diarization { result.diarization?.model=policy.sanitize(info.model).text }
        let main=policy.sanitize(text), joined=segments.map(\.text).joined(separator:" ")
        let spoken=Self.hasSpokenCredential(text) || Self.hasSpokenCredential(joined)
        result.text=spoken ? "[REDACTED SENSITIVE SPEECH]":main.text
        var changed=main.redacted || policy.sanitize(joined).redacted || spoken
        result.segments=segments.map { segment in
            var clean=segment; let value=policy.sanitize(segment.text); clean.text=value.text; changed = changed || value.redacted
            if let speaker=segment.speaker { let value=policy.sanitize(speaker); clean.speaker=value.text; changed = changed || value.redacted }
            return clean
        }
        // Segment boundaries can split a key/value. Without a trustworthy text
        // alignment, retaining fragments could expose a value already redacted
        // in the full text. Conservatively hide all timed text for this clip.
        if changed { for index in result.segments.indices { result.segments[index].text="[REDACTED]" } }
        return (result,changed)
    }

}
public enum AudioAdmission {
    /// The caller owns the input clip. It is never moved/deleted here. A failed
    /// insert removes only this operation's newly created retained copy.
    public static func save(_ transcript: SpeechTranscript, file: URL, store: MemoryStore, settings: AppSettings,
                            timestamp: Date, source: String, title: String? = nil, sessionID: String? = nil, recordedLive: Bool = true,
                            embedder: LocalEmbedder? = nil,admission:MediaAdmissionLease?=nil) throws -> Memory {
        try Task.checkCancellation()
        let clean=try transcript.sanitized(policy:settings.privacy)
        guard timestamp.timeIntervalSince1970.isFinite,source.count<=512,sessionID.map({!$0.isEmpty && $0.count<=200}) ?? true else { throw OSwindError.invalid("Invalid audio source metadata") }
        let label=settings.privacy.sanitize(title ?? source+" transcript").text
        var memory=Memory(timestamp:timestamp,endTimestamp:recordedLive ? timestamp.addingTimeInterval(clean.transcript.duration):nil,kind:.audio,app:settings.privacy.sanitize(source).text,title:label,text:clean.transcript.text)
        memory.transcript=clean.transcript; memory.audioSessionID=sessionID
        if let embedder { memory.embedding=embedder.embed(memory.searchableText); memory.embeddingModel=memory.embedding == nil ? nil : embedder.modelID }
        let owned:MediaAdmissionLease?
        if admission==nil {owned=try store.mediaWriteLease()} else {owned=nil}
        defer {owned?.release()}
        guard let lease=admission ?? owned else {throw OSwindError.invalid("Audio requires a media reservation")}
        return try lease.withActive(for:store.mediaRootIdentity) {
        try store.requireMediaRootIdentity()
        var retained: String?, committed=false;var ownedOutput:BackupFileTree?
        defer {if !committed,let retained {try? ownedOutput?.remove(retained)}}
        if settings.retainAudio && !clean.suppressAudio {
            let input=try BackupFileTree(root:file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()), output=try BackupFileTree(root:store.root.standardizedFileURL.resolvingSymlinksInPath(),writable:true)
            let outputIdentity=try output.identity();guard outputIdentity.device==store.mediaRootIdentity.device,outputIdentity.inode==store.mediaRootIdentity.inode else {throw OSwindError.invalid("The library directory changed before audio retention")}
            ownedOutput=output
            let suffix=file.pathExtension.lowercased(); guard !suffix.isEmpty,suffix.count<=12,suffix.utf8.allSatisfy({(97...122).contains($0)||(48...57).contains($0)}) else { throw OSwindError.invalid("Audio clip needs a supported filename extension") }
            let member="audio/"+UUID().uuidString+"."+suffix; retained=member
            _ = try input.copy(file.lastPathComponent,to:output,as:member)
            memory.audioPath=member
        }
        try Task.checkCancellation();try store.requireMediaRootIdentity();try store.insert(memory);committed=true;return memory
        }
    }
}

/// Immutable operation-owned input for ASR and subsequent retention. Keep this
/// object alive until both have finished; callers use withExtendedLifetime.
public final class AudioClipSnapshot: @unchecked Sendable {
    private let workspace: BackupWorkspace
    public let file: URL
    public let speechFile: URL
    public let duration: Double
    public var mediaActivity:MediaAdmissionLease? {workspace.mediaActivity}
    public init(source: URL,store:MemoryStore?=nil) throws {
        guard source.isFileURL else { throw OSwindError.invalid("Choose a local audio file") }
        let suffix=source.pathExtension.lowercased()
        guard !suffix.isEmpty,suffix.count<=12,suffix.utf8.allSatisfy({(97...122).contains($0)||(48...57).contains($0)}) else { throw OSwindError.invalid("Audio file needs a supported extension") }
        let workspace:BackupWorkspace
        if let store {workspace=try store.libraryWorkspace("oswind-audio-import")}
        else {_ = try BackupWorkspace.cleanupAbandoned(labels:["oswind-audio-import"]);workspace=try BackupWorkspace(label:"oswind-audio-import")}
        let tree=try BackupFileTree(root:source.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath())
        _ = try tree.pin(source.lastPathComponent,to:workspace.tree,as:"input."+suffix)
        let original=workspace.url.appendingPathComponent("input."+suffix)
        duration=try AudioNormalization.convert(original,to:workspace.tree,as:"speech.wav")
        self.workspace=workspace; file=original; speechFile=workspace.url.appendingPathComponent("speech.wav")
    }
    public static func prepare(_ source: URL,store:MemoryStore?=nil) async throws -> AudioClipSnapshot {
        let task=Task.detached(priority:.utility) { try AudioClipSnapshot(source:source,store:store) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
