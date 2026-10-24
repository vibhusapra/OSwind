import Foundation

public struct VisualFrame:Codable,Equatable,Sendable {
    public var time:Double
    public var text:String
    public var regions:[TextRegion]
    public init(time:Double,text:String,regions:[TextRegion]=[]) {self.time=time;self.text=text;self.regions=regions}
}
/// One immutable, independently erasable short clip. Text offsets always address
/// the original joined OCR/AX source; a frame time never replaces a text anchor.
public struct VisualRecording:Codable,Equatable,Sendable {
    public var duration:Double
    public var width:Int
    public var height:Int
    public var codec:String
    public var hardwareRequired:Bool
    public var frames:[VisualFrame]
    public init(duration:Double,width:Int,height:Int,codec:String,hardwareRequired:Bool,frames:[VisualFrame]) {
        self.duration=duration;self.width=width;self.height=height;self.codec=codec;self.hardwareRequired=hardwareRequired;self.frames=frames
    }
    public var text:String {frames.map(\.text).joined(separator:"\n\n")}
    public func validated() throws -> Self {
        guard duration.isFinite,duration>0,duration<=120,(2...4096).contains(width),(2...4096).contains(height),["hevc","h264"].contains(codec),!frames.isEmpty,frames.count<=240,text.count<=1_000_000 else {throw OSwindError.invalid("Invalid or oversized visual recording")}
        var previous = -Double.infinity
        for frame in frames {
            guard frame.time.isFinite,frame.time>=0,frame.time<duration,frame.time>previous,frame.text.count<=100000,frame.regions.count<=2000,
                  frame.regions.allSatisfy({r in [r.x,r.y,r.width,r.height].allSatisfy(\.isFinite) && r.x>=0 && r.y>=0 && r.width>=0 && r.height>=0 && r.x+r.width<=1.000001 && r.y+r.height<=1.000001 && r.text.count<=100000}) else {throw OSwindError.invalid("Invalid visual frame timing, text or geometry")}
            previous=frame.time
        }
        return self
    }
    public func sanitized(policy:PrivacyPolicy) throws -> Self {
        _ = try validated();var copy=self
        for index in copy.frames.indices {
            let clean=policy.sanitize(copy.frames[index].text);copy.frames[index].text=clean.text
            if clean.redacted || copy.frames[index].regions.contains(where:{policy.sanitize($0.text).redacted}) {copy.frames[index].regions=[]}
        }
        return try copy.validated()
    }
    public func ranges() -> [(frame:VisualFrame,range:PassageRange)] {
        var offset=0,result=[(VisualFrame,PassageRange)]()
        for frame in frames {result.append((frame,PassageRange(start:offset,length:frame.text.utf16.count)));offset += frame.text.utf16.count+2}
        return result
    }
    public func frameTime(passage:PassageRange?=nil,query:String="") -> Double {
        let entries=ranges()
        func words(_ text:String)->[String] {text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).split(whereSeparator:{!$0.isLetter && !$0.isNumber}).map(String.init)}
        let phrases=((try? SearchExpressionPlan.make(query))?.positivePhrases ?? []).map(words)
        let passageEntry=passage.flatMap { passage in entries.first(where:{NSIntersectionRange(NSRange(location:$0.range.start,length:$0.range.length),NSRange(location:passage.start,length:passage.length)).length>0}) }
        if phrases.isEmpty,let passageEntry {return passageEntry.frame.time}
        let terms=MemoryStore.queryTerms(query)
        let ranked=entries.map { entry -> (time:Double,phrases:Int,terms:Int) in
            let tokens=phrases.isEmpty ? []:words(entry.frame.text)
            let matches=phrases.filter { phrase in
                guard !phrase.isEmpty,phrase.count<=tokens.count else {return false}
                return (0...(tokens.count-phrase.count)).contains { start in tokens[start..<(start+phrase.count)].elementsEqual(phrase) }
            }.count
            return (entry.frame.time,matches,terms.filter {entry.frame.text.localizedCaseInsensitiveContains($0)}.count)
        }
        let bestPhraseCount=ranked.map(\.phrases).max() ?? 0
        // A semantic passage must not override a stronger required-phrase frame.
        if let passageEntry,ranked.first(where:{$0.time==passageEntry.frame.time})?.phrases==bestPhraseCount {return passageEntry.frame.time}
        return ranked.max {a,b in a.phrases != b.phrases ? a.phrases<b.phrases:a.terms != b.terms ? a.terms<b.terms:a.time>b.time}?.time ?? 0
    }
}
public enum VisualCaptureMode:String,Codable,CaseIterable,Sendable {case snapshots,replay}
public extension CaptureProfile {
    func replayInterval(lowPower:Bool,thermalLimited:Bool) -> Double {
        let base:Double = self == .light ? 5:self == .balanced ? 1:0.5
        return base*(lowPower ? 3:1)*(thermalLimited ? 3:1)
    }
}
