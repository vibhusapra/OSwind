import XCTest
@testable import OSwindCore

final class SpeakerTimelineTests:XCTestCase {
    func testNativePolicyKeepsOverlapForMixedWordSafeguard() throws {
        let config=SpeakerNativePolicy.configuration()
        XCTAssertFalse(config.postProcessing.exclusiveSegments)
        XCTAssertFalse(config.exposeChunkEmbeddings);XCTAssertNil(config.embeddingExportPath)
        let transcript=SpeechTranscript(text:"mixed",duration:1,segments:[TranscriptSegment(start:0,end:1,text:"mixed")],model:"fixture")
        let result=try SpeakerAttribution.attach([SpeakerTurn(start:0,end:1,speaker:"A"),SpeakerTurn(start:0.2,end:0.8,speaker:"B")],to:transcript,model:"fixture")
        XCTAssertNil(result.segments[0].speaker);XCTAssertEqual(result.diarization?.detectedSpeakers,2)
    }
    func testOverlappingTurnsRemainIndependentOfTranscriptCoverage() throws {
        let timeline=SpeakerTimeline(duration:3,model:"fixture",turns:[SpeakerTurn(start:1,end:2,speaker:"B"),SpeakerTurn(start:0,end:2,speaker:"A"),SpeakerTurn(start:2.9,end:3.1,speaker:"B")])
        let valid=try timeline.validated()
        XCTAssertEqual(valid.turns.map(\.speaker),["A","B","B"]);XCTAssertEqual(valid.turns.last?.end,3)
        let decoded=try JSONDecoder().decode(SpeakerTimeline.self,from:JSONEncoder().encode(valid));XCTAssertEqual(decoded,valid)
    }
    func testInvalidOutputDoesNotBecomeAQualityScore() throws {
        let base=SpeakerTimeline(duration:3,model:"fixture",turns:[])
        XCTAssertNoThrow(try base.validated())
        for turn in [SpeakerTurn(start:-1,end:1,speaker:"A"),SpeakerTurn(start:1,end:0,speaker:"A"),SpeakerTurn(start:0,end:.infinity,speaker:"A"),SpeakerTurn(start:0,end:3.6,speaker:"A"),SpeakerTurn(start:0,end:1,speaker:"")] {
            var bad=base;bad.turns=[turn];XCTAssertThrowsError(try bad.validated())
        }
        var bad=base;bad.duration = .nan;XCTAssertThrowsError(try bad.validated());bad=base;bad.scope="global";XCTAssertThrowsError(try bad.validated())
    }
}
