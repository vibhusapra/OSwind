import Foundation

public enum SearchDetail:String,Codable,Sendable { case full, preview }
public struct TranscriptPreview:Codable,Equatable,Sendable {
    public var duration:Double
    public var model:String
    public var segmentCount:Int
    public var assignedSegments:Int
    public var speakerCount:Int
    public var speakerLabels:[String]
    public var labelsComplete:Bool
    public var diarization:DiarizationInfo?
    init(_ transcript:SpeechTranscript) {
        duration=transcript.duration;model=transcript.model;segmentCount=transcript.segments.count
        assignedSegments=transcript.segments.reduce(0) {$0+($1.speaker == nil ? 0:1)}
        let names=Set(transcript.segments.compactMap(\.speaker))
        speakerCount=names.count
        // Preview metadata stays bounded even for unusually long Unicode labels.
        // Omitted labels are explicit; never return a shortened identity label.
        speakerLabels=Array(names.filter {$0.utf8.count<=512}.sorted().prefix(32))
        labelsComplete=speakerLabels.count==speakerCount;diarization=transcript.diarization
    }
}
public struct MemorySearchPreview:Codable,Equatable,Sendable {
    public var sourceRevision:String
    public var transcript:TranscriptPreview
    init(memory:Memory,transcript:SpeechTranscript) { sourceRevision=memory.evidenceHash;self.transcript=TranscriptPreview(transcript) }
}
enum SearchPreviewSchema {
    static let sql="""
    CREATE TABLE IF NOT EXISTS audio_search_previews (
        memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
        payload BLOB NOT NULL
    );
    """
}
