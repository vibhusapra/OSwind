import XCTest
@testable import OSwindCore

final class AudioSourceBoundsTests:XCTestCase {
    func testCrossingDecoderEndIsClippedWithoutChangingTextOrSpeaker() throws {
        let value=SpeechTranscript(text:"Synthetic recognized speech",duration:7.4,segments:[.init(start:0,end:7.4,text:"Synthetic recognized speech",speaker:"Speaker 1")],model:"fixture")
        let result=try value.bounded(toSourceDuration:5.925)
        XCTAssertEqual(result.duration,5.925);XCTAssertEqual(result.segments[0].end,5.925);XCTAssertEqual(result.text,value.text);XCTAssertEqual(result.segments[0].text,value.segments[0].text);XCTAssertEqual(result.segments[0].speaker,"Speaker 1");XCTAssertEqual(result.model,value.model)
    }
    func testKnownSourceCanIncludeUnrecognizedTrailingSilence() throws {
        let value=SpeechTranscript(text:"Synthetic speech",duration:1,segments:[.init(start:0,end:1,text:"Synthetic speech")],model:"fixture")
        let result=try value.bounded(toSourceDuration:2);XCTAssertEqual(result.duration,2);XCTAssertEqual(result.segments,value.segments)
    }
    func testWhollyOutsideSegmentIsRefusedInsteadOfDroppingText() throws {
        for start in [2.0,3.0] {
            let value=SpeechTranscript(text:"Synthetic speech",duration:4,segments:[.init(start:start,end:4,text:"Synthetic speech")],model:"fixture")
            XCTAssertThrowsError(try value.bounded(toSourceDuration:2))
        }
    }
    func testInvalidSourceAndInvalidDecoderMetadataRemainRefused() throws {
        var value=SpeechTranscript(text:"Synthetic speech",duration:1,segments:[.init(start:0,end:1,text:"Synthetic speech")],model:"fixture")
        for duration in [0,-1,Double.nan,Double.infinity,86401] {XCTAssertThrowsError(try value.bounded(toSourceDuration:duration))}
        value.segments[0].start = -1;XCTAssertThrowsError(try value.bounded(toSourceDuration:1))
        value.segments[0].start=0;value.segments[0].end = .nan;XCTAssertThrowsError(try value.bounded(toSourceDuration:1))
    }
    func testUntimedTextAndExistingExactEndArePreserved() throws {
        let value=SpeechTranscript(text:"Synthetic speech",duration:1,segments:[],model:"fixture")
        XCTAssertEqual(try value.bounded(toSourceDuration:2).text,value.text)
        let exact=SpeechTranscript(text:"Synthetic speech",duration:2,segments:[.init(start:0,end:2,text:"Synthetic speech"),.init(start:2,end:2,text:"")],model:"fixture")
        XCTAssertEqual(try exact.bounded(toSourceDuration:2),exact)
    }
}
