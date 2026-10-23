import Foundation

/// Anonymous, recording-local speech intervals, before ASR word attribution.
/// This contains no voice embeddings, profiles or cross-recording identities.
public struct SpeakerTimeline:Codable,Equatable,Sendable {
    public var duration:Double
    public var model:String
    public var turns:[SpeakerTurn]
    public var scope="recording"
    public init(duration:Double,model:String,turns:[SpeakerTurn]) {self.duration=duration;self.model=model;self.turns=turns}
    public func validated() throws -> Self {
        guard duration.isFinite,duration>0,duration<=86400,!model.isEmpty,model.utf8.count<=1024,scope=="recording",turns.count<=200000 else {throw OSwindError.invalid("Invalid speaker timeline")}
        var copy=self,labels=Set<String>()
        for turn in turns {
            guard turn.start.isFinite,turn.end.isFinite,turn.start>=0,turn.end>turn.start,turn.end<=duration+0.5,!turn.speaker.isEmpty,turn.speaker.utf8.count<=128 else {throw OSwindError.invalid("Invalid speaker turn")}
            labels.insert(turn.speaker);guard labels.count<=256 else {throw OSwindError.invalid("More than 256 speakers in one recording")}
        }
        copy.turns=turns.compactMap {turn in
            let start=min(duration,turn.start),end=min(duration,turn.end)
            return end>start ? SpeakerTurn(start:start,end:end,speaker:turn.speaker):nil
        }.sorted {($0.start,$0.end,$0.speaker)<($1.start,$1.end,$1.speaker)}
        return copy
    }
}
