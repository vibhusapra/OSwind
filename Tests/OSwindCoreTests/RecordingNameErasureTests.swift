import XCTest
@testable import OSwindCore

extension SyncOutgoingTests {
    private func eraseNamedClipAndCheckClosure(_ audio:Memory,_ caption:Memory)throws {
        try seed("unrelated-note","Independent authored note")
        let scope=HistoryErasureScope(start:audio.timestamp.addingTimeInterval(-1),end:audio.timestamp.addingTimeInterval(1),kind:.audio)
        let review=try store.previewErasure(scope)
        XCTAssertEqual(review.matchedSources,1)
        XCTAssertEqual(review.sources,2,"Reviewed source erasure must include its independently stored recording name")
        guard review.sources==2 else {return}
        let result=try store.eraseHistory(scope,expectedToken:review.token)
        XCTAssertEqual(result.sources,2);XCTAssertNil(try store.get(audio.id));XCTAssertNil(try store.get(caption.id))
        XCTAssertNotNil(try store.get("unrelated-note"))
        try store.withRoutineDatabase {db in
            XCTAssertNil(try RecordingAffiliationStore.read(db,id:caption.id));try RecordingAffiliationStore.checkAccounting(db)
            XCTAssertEqual(try db.eraseCount("SELECT used_bytes FROM recording_affiliation_state WHERE singleton=1"),0)
        }
    }
    func testRecordingNameErasureBeforeEnrollmentIncludesTheAuthoredNameInPreview()throws {
        let (audio,caption)=try namedClip()
        try eraseNamedClipAndCheckClosure(audio,caption)
    }
    func testRecordingNameErasureAfterEnrollmentIncludesItsStoredAffiliation()throws {
        let (audio,caption)=try namedClip();try install();_=try finish()
        try eraseNamedClipAndCheckClosure(audio,caption)
    }
    func testRecordingNameErasureAfterUnavailableAndRenameDoesNotDependOnOldWireBodies()throws {
        var (audio,caption)=try namedClip();try install();_=try finish()
        let firstCaption=try recordingPacket(caption.id)
        audio.text="Authored replacement transcript";try store.insert(audio);_=try finish()
        caption.title="Renamed unavailable recording";try store.insert(caption);_=try finish()
        XCTAssertNil(try cache.record(firstCaption.reference,admit:{_ in}))
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("Missing unavailable metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable);XCTAssertTrue(body.sourceReferences.isEmpty)
        try eraseNamedClipAndCheckClosure(audio,caption)
    }
    func testRecordingNameErasureKeepsSessionNameUntilItsLastClipIsSelected()throws {
        var first=Memory(id:"session-first",timestamp:now,kind:.audio,app:"Owned",title:"First clip",text:"First authored speech")
        first.audioSessionID="explicit-owned-session"
        var second=first;second.id="session-second";second.timestamp=now.addingTimeInterval(30);second.text="Second authored speech"
        try store.insert(first);try store.insert(second)
        let source=try XCTUnwrap(store.recordedMeetingPage().sources.first),name=try store.saveRecordedMeetingName("Shared session name",for:source)
        let firstScope=HistoryErasureScope(start:now.addingTimeInterval(-1),end:now.addingTimeInterval(1),kind:.audio),firstReview=try store.previewErasure(firstScope)
        XCTAssertEqual(firstReview.sources,1);_=try store.eraseHistory(firstScope,expectedToken:firstReview.token)
        XCTAssertNotNil(try store.get(name.id));XCTAssertNotNil(try store.get(second.id))
        let remaining=try XCTUnwrap(store.recordedMeetingPage().sources.first)
        XCTAssertEqual(try store.recordedMeetingDetails(for:remaining).map(\.name),["Shared session name"])
        let lastScope=HistoryErasureScope(start:now.addingTimeInterval(29),end:now.addingTimeInterval(31),kind:.audio),lastReview=try store.previewErasure(lastScope)
        XCTAssertEqual(lastReview.sources,2,"Erasing the last clip must include the recording's authored name")
        guard lastReview.sources==2 else {return}
        XCTAssertEqual(try store.eraseHistory(lastScope,expectedToken:lastReview.token).sources,2)
        XCTAssertNil(try store.get(name.id));XCTAssertNil(try store.get(second.id))
    }
}
