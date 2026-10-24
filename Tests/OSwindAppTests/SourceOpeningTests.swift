import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class SourceOpeningTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);app=try AppModel(root:root,startServices:false)}
    override func tearDownWithError() throws {app.prepareForLibrarySwitch();app=nil;try? FileManager.default.removeItem(at:root)}
    func preview(_ id:String="audio") throws -> Memory {
        let segments=(0..<1000).map {TranscriptSegment(start:Double($0),end:Double($0)+0.8,text:"word\($0)",speaker:"Maya")}
        let text=segments.map(\.text).joined(separator:" ");var memory=Memory(id:id,kind:.audio,text:text)
        memory.transcript=SpeechTranscript(text:text,duration:1000,segments:segments,model:"fixture");try app.store.insert(memory)
        return try XCTUnwrap(app.store.search(SearchFilter(),mode:.keyword,detail:.preview).first {$0.id==id}?.memory)
    }
    func finish() async throws {
        let until=ContinuousClock.now.advanced(by:.seconds(5))
        while app.openingMemoryID != nil && ContinuousClock.now<until {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertNil(app.openingMemoryID)
    }
    func testOpeningHydratesFullTimedSourceAndPreservesPassage() async throws {
        let memory=try preview(),passage=PassageRange(start:0,length:5)
        app.openMemory(memory,query:"word",passage:passage);try await finish()
        XCTAssertNil(app.selected?.searchPreview);XCTAssertEqual(app.selected?.transcript?.segments.count,1000)
        XCTAssertEqual(app.selectedPassage,passage);XCTAssertEqual(app.selectedEvidenceQuery,"word")
    }
    func testCancelledOpeningCannotPublishAfterSearchFocusChanges() async throws {
        app.openMemory(try preview(),query:"word");app.focusSearch()
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertNil(app.selected);XCTAssertNil(app.openingMemoryID)
    }
    func testNewOpeningAndLibrarySwitchDiscardOlderWork() async throws {
        let first=try preview("one"),second=try preview("two")
        app.openMemory(first,query:"first");app.openMemory(second,query:"second");try await finish()
        XCTAssertEqual(app.selected?.id,"two");XCTAssertEqual(app.selectedEvidenceQuery,"second")
        app.openMemory(first,query:"late");app.prepareForLibrarySwitch();try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertNil(app.selected);XCTAssertNil(app.openingMemoryID)
    }
    func testDeletingPendingSourceCancelsItsOpening() async throws {
        let memory=try preview();app.openMemory(memory,query:"word");app.delete(memory)
        try await Task.sleep(nanoseconds:100_000_000);XCTAssertNil(app.selected);XCTAssertNil(app.openingMemoryID)
    }
    func testVisualOpeningPreservesProofAndClearsItWhenLeavingSource() async throws {
        let memory=Memory(id:"image",app:"Fixture",text:"",imagePath:"images/one.dat")
        try Data("owned sample pixels".utf8).write(to:root.appendingPathComponent(memory.imagePath!));try app.store.insert(memory)
        let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:app.store,id:memory.id))
        _ = try app.store.saveVisualVectors([.init(point:snapshot.plan.points[0],decodedTime:nil,vector:[1,0])],snapshot:snapshot,modelID:"fixture");snapshot.release()
        let hit=try XCTUnwrap(app.store.searchVisual(SearchFilter(),vector:[1,0],modelID:"fixture").hits.first),match=try XCTUnwrap(hit.visual)
        app.openMemory(hit.memory,query:"appearance",visual:match);try await finish()
        XCTAssertEqual(app.selected?.id,memory.id);XCTAssertEqual(app.selectedVisual,match)
        app.focusSearch();XCTAssertNil(app.selectedVisual)
        try Data("replacement".utf8).write(to:root.appendingPathComponent(memory.imagePath!))
        app.errorMessage=nil;app.openMemory(hit.memory,query:"stale",visual:match);try await finish()
        XCTAssertNil(app.selected);XCTAssertNil(app.selectedVisual);XCTAssertNotNil(app.errorMessage)
        app.openMemory(hit.memory,query:"cancelled",visual:match);app.prepareForLibrarySwitch()
        try await Task.sleep(nanoseconds:50_000_000);XCTAssertNil(app.selectedVisual);XCTAssertNil(app.selected)
    }
    func testChangedOrErasedSourceFailsWithoutOpeningStaleText() async throws {
        let memory=try preview();_ = try app.store.renameAudioSpeaker(memory.id,from:"Maya",to:"Theo")
        app.openMemory(memory,query:"old");try await finish()
        XCTAssertNil(app.selected);XCTAssertNotNil(app.errorMessage)
        let fresh=try XCTUnwrap(app.store.search(SearchFilter(),mode:.keyword,detail:.preview).first?.memory)
        try app.store.delete(fresh.id);app.errorMessage=nil;app.openMemory(fresh,query:"erased");try await finish()
        XCTAssertNil(app.selected);XCTAssertNotNil(app.errorMessage)
    }
}
