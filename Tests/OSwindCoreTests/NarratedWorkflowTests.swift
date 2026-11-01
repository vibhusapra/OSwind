import XCTest
@testable import OSwindCore

final class NarratedWorkflowTests:XCTestCase {
    func binding()->WorkflowSourceBinding {.init(library:String(repeating:"a",count:64),memoryID:"owned-screen",revision:String(repeating:"b",count:64),mediaSHA256:String(repeating:"c",count:64),kind:.image)}
    func draft()->WorkflowDraft {.init(title:"Owned workflow",steps:[.init(source:binding(),title:"Review the source",narration:"This retained screen shows the authored workspace.")])}
    func testUnicodeDraftRoundTripPreservesExactReviewedScript()throws {
        var d=draft();d.steps[0].narration="Review café 👩🏽‍💻.\nThen inspect the retained source."
        let decoded=try JSONDecoder().decode(WorkflowDraft.self,from:JSONEncoder().encode(d))
        XCTAssertEqual(try decoded.validated(),d);XCTAssertEqual(try decoded.revision,try d.revision)
    }
    func testScriptTitleOrderAndSourceChangesRevokeDraftRevision()throws {
        var d=draft();d.steps.append(.init(source:binding(),title:"Second",narration:"Review the second selected frame."))
        let original=try d.revision
        var script=d;script.steps[0].narration+=" Edited.";XCTAssertNotEqual(try script.revision,original)
        var title=d;title.title="Edited title";XCTAssertNotEqual(try title.revision,original)
        var order=d;order.steps.reverse();XCTAssertNotEqual(try order.revision,original)
        var source=d;source.steps[0].source.mediaSHA256=String(repeating:"d",count:64);XCTAssertNotEqual(try source.revision,original)
    }
    func testEmptyDuplicateOversizedAndMixedLibraryDraftsRefuse()throws {
        var d=draft();d.steps=[];XCTAssertThrowsError(try d.validated())
        d=draft();d.steps.append(d.steps[0]);XCTAssertThrowsError(try d.validated())
        d=draft();d.steps=Array(repeating:d.steps[0],count:9).map {var s=$0;s.id=UUID();return s};XCTAssertThrowsError(try d.validated())
        d=draft();var foreign=d.steps[0];foreign.id=UUID();foreign.source.library=String(repeating:"d",count:64);d.steps.append(foreign);XCTAssertThrowsError(try d.validated())
        d=draft();d.steps[0].narration=String(repeating:"👩🏽‍💻",count:1000);XCTAssertThrowsError(try d.validated())
        d=draft();d.steps=Array(repeating:d.steps[0],count:4).map {var s=$0;s.id=UUID();s.narration=String(repeating:"a",count:4000);return s};XCTAssertThrowsError(try d.validated())
    }
    func testMalformedSourceAndInventedReplayCoordinatesRefuse()throws {
        var b=binding();b.mediaSHA256="not-a-digest";XCTAssertThrowsError(try b.validate())
        b=binding();b.frameTime=0;XCTAssertThrowsError(try b.validate())
        b=binding();b.frameOrdinal=1;XCTAssertThrowsError(try b.validate())
        b=binding();b.kind = .video;XCTAssertThrowsError(try b.validate())
        for time in [Double.nan,Double.infinity,-1,120.01] {b.frameTime=time;XCTAssertThrowsError(try b.validate())}
        b.frameTime=1.25;b.frameOrdinal=3;XCTAssertNoThrow(try b.validate())
        // This validates syntax only. Actual export must also match the exact
        // current retained frame plan and pixel hash, not just these ranges.
    }
    func testCanonicallyEquivalentScriptsStillHaveDifferentByteRevisions()throws {
        var a=draft();var b=a;a.steps[0].narration="caf\u{00e9}";b.steps[0].narration="cafe\u{0301}"
        XCTAssertEqual(a.steps[0].narration,b.steps[0].narration)
        XCTAssertNotEqual(Data(a.steps[0].narration.utf8),Data(b.steps[0].narration.utf8))
        XCTAssertNotEqual(try a.revision,try b.revision)
    }
    func testNULScriptsAndMultilineTitlesCannotReachNarrationOrCaptions()throws {
        var d=draft();d.steps[0].narration="Owned\0script";XCTAssertThrowsError(try d.validated())
        d=draft();d.title="Title\n00:00:00 --> 00:00:01";XCTAssertThrowsError(try d.validated())
        d=draft();d.steps[0].title="Owned\rtitle";XCTAssertThrowsError(try d.validated())
    }
}
