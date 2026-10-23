import Foundation

public struct DiarizationInfo: Codable, Equatable, Sendable {
    public var model: String
    public var detectedSpeakers: Int
    public var unassignedSegments: Int
    /// Labels are anonymous and local to this recording, never a global identity.
    public var scope = "recording"
    public init(model:String,detectedSpeakers:Int,unassignedSegments:Int) { self.model=model; self.detectedSpeakers=detectedSpeakers; self.unassignedSegments=unassignedSegments }
}
public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var start:Double
    public var end:Double
    public var speaker:String
    public init(start:Double,end:Double,speaker:String) { self.start=start; self.end=end; self.speaker=speaker }
}
public enum SpeakerAttribution {
    /// A non-overlapping interval series plus prefix duration permits each
    /// coverage query in O(log n), even for long/nested ASR segments.
    private struct Coverage {
        var starts=[Double](), ends=[Double](), prefix=[0.0]
        mutating func append(_ start:Double,_ end:Double) { starts.append(start); ends.append(end); prefix.append(prefix.last!+end-start) }
        func area(to time:Double) -> Double {
            var low=0,high=ends.count
            while low<high { let mid=(low+high)/2; if ends[mid]<=time { low=mid+1 } else { high=mid } }
            return prefix[low]+(low<starts.count ? max(0,time-starts[low]):0)
        }
        func overlap(_ start:Double,_ end:Double) -> Double { max(0,area(to:end)-area(to:start)) }
    }
    public static func attach(_ turns:[SpeakerTurn],to transcript:SpeechTranscript,model:String) throws -> SpeechTranscript {
        _ = try transcript.validated(); try Task.checkCancellation()
        guard turns.count<=200000,!model.isEmpty,model.utf8.count<=1024 else { throw OSwindError.invalid("Diarization output is oversized") }
        struct Event { var time:Double; var speaker:String; var delta:Int }
        var events=[Event](), labels=[String:String]()
        for (index,turn) in turns.sorted(by:{ ($0.start,$0.end,$0.speaker)<($1.start,$1.end,$1.speaker) }).enumerated() {
            if index%1024==0 { try Task.checkCancellation() }
            guard turn.start.isFinite,turn.end.isFinite,turn.start>=0,turn.end>turn.start,turn.end<=transcript.duration+0.5,!turn.speaker.isEmpty,turn.speaker.utf8.count<=128 else { throw OSwindError.invalid("Invalid speaker turn") }
            if labels[turn.speaker]==nil { guard labels.count<256 else { throw OSwindError.invalid("More than 256 speakers in one recording") }; labels[turn.speaker]="Speaker \(labels.count+1)" }
            let start=min(transcript.duration,turn.start),end=min(transcript.duration,turn.end)
            if end>start { events.append(Event(time:start,speaker:turn.speaker,delta:1)); events.append(Event(time:end,speaker:turn.speaker,delta:-1)) }
        }
        events.sort { $0.time<$1.time }
        var active=[String:Int](), coverage=[String:Coverage](), mixed=Coverage(), index=0,previous=0.0
        while index<events.count {
            if index%2048==0 { try Task.checkCancellation() }
            let time=events[index].time
            if time>previous {
                if active.count==1,let speaker=active.keys.first { coverage[speaker,default:Coverage()].append(previous,time) }
                else if active.count>1 { mixed.append(previous,time) }
            }
            while index<events.count && events[index].time==time {
                let event=events[index], count=(active[event.speaker] ?? 0)+event.delta
                if count==0 { active.removeValue(forKey:event.speaker) } else { active[event.speaker]=count }
                index += 1
            }
            previous=time
        }
        let series=coverage.map { (labels[$0.key]!, $0.value) }.sorted { $0.0<$1.0 }
        var result=transcript
        for i in result.segments.indices {
            if i%256==0 { try Task.checkCancellation() }
            let segment=result.segments[i], duration=segment.end-segment.start
            result.segments[i].speaker=nil
            guard duration>0,mixed.overlap(segment.start,segment.end)<=duration*0.15 else { continue }
            var best=(label:"",area:0.0), runner=0.0
            for (label,intervals) in series {
                let area=intervals.overlap(segment.start,segment.end)
                if area>best.area { runner=best.area; best=(label,area) } else { runner=max(runner,area) }
            }
            // Temporal coverage is not a calibrated recognition confidence.
            // Mixed/weak/boundary spans remain unknown rather than inventing IDs.
            if best.area>=duration*0.6 && runner<=duration*0.2 { result.segments[i].speaker=best.label }
        }
        result.diarization=DiarizationInfo(model:model,detectedSpeakers:labels.count,unassignedSegments:result.segments.filter{$0.speaker==nil}.count)
        return try result.validated()
    }
}
