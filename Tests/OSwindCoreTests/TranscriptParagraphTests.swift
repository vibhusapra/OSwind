import XCTest
@testable import OSwindCore

final class TranscriptParagraphTests:XCTestCase {
    func transcript(_ segments:[TranscriptSegment]) -> SpeechTranscript { SpeechTranscript(text:"Synthetic",duration:100,segments:segments,model:"fixture") }
    func testGroupingPreservesAllIndicesAndSpeakerUnknownBoundaries() throws {
        let value=transcript([TranscriptSegment(start:0,end:1,text:"Hello",speaker:"A"),TranscriptSegment(start:1,end:2,text:"there.",speaker:"A"),TranscriptSegment(start:2,end:3,text:"Unknown"),TranscriptSegment(start:3,end:4,text:"Second",speaker:"B"),TranscriptSegment(start:4,end:5,text:"voice.",speaker:"B")])
        let groups=try TranscriptParagraph.make(value)
        XCTAssertEqual(groups.map(\.range),[0..<2,2..<3,3..<5]);XCTAssertEqual(groups.map(\.speaker),["A",nil,"B"])
        XCTAssertEqual(groups.flatMap{Array($0.range)},Array(value.segments.indices));XCTAssertEqual(groups.map(\.start),[0,2,3])
    }
    func testGapsLongTextAndOverlappingCoarseSegmentsBreakGroups() throws {
        let value=transcript([TranscriptSegment(start:0,end:1,text:"A"),TranscriptSegment(start:3,end:4,text:"B"),TranscriptSegment(start:4,end:5,text:String(repeating:"x",count:360)),TranscriptSegment(start:5,end:10,text:"Long"),TranscriptSegment(start:6,end:7,text:"Overlap")])
        let groups=try TranscriptParagraph.make(value)
        XCTAssertEqual(groups.map(\.range),[0..<1,1..<2,2..<3,3..<4,4..<5])
    }
    func testEmptyTranscriptAndSentenceBoundary() throws {
        XCTAssertEqual(try TranscriptParagraph.make(transcript([])),[])
        let value=transcript([TranscriptSegment(start:0,end:1,text:String(repeating:"x",count:81)+"."),TranscriptSegment(start:1,end:2,text:"Next.")])
        XCTAssertEqual(try TranscriptParagraph.make(value).map(\.range),[0..<1,1..<2])
    }
}
