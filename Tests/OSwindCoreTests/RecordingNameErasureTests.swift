import XCTest
import CSQLite
@testable import OSwindCore

extension SyncOutgoingTests {
    func testRecordingNameErasureNeverUsesForgedNameCacheToSelectAnotherCapturedSource()throws {
        let (audio,caption)=try namedClip()
        var other=audio;other.id="unrelated-captured-audio";other.timestamp=now.addingTimeInterval(100);other.title="Unrelated capture";try store.insert(other)
        try store.withRoutineDatabase {db in
            let row=try db.statement("UPDATE recorded_meeting_details SET memory_id=? WHERE memory_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,other.id);db.bind(row,2,caption.id);try db.done(row)
        }
        let scope=HistoryErasureScope(start:now.addingTimeInterval(-1),end:now.addingTimeInterval(1),kind:.audio),review=try store.previewErasure(scope)
        let selected=Set(review.samples.map(\.id)),expected:Set<String>=[audio.id,caption.id]
        XCTAssertEqual(selected,expected,"A rebuildable name cache must never authorize erasing another captured source")
        guard selected==expected else {return}
        _=try store.eraseHistory(scope,expectedToken:review.token)
        XCTAssertNil(try store.get(audio.id));XCTAssertNil(try store.get(caption.id));XCTAssertNotNil(try store.get(other.id))
        XCTAssertEqual(try n("SELECT count(*) FROM recorded_meeting_details"),0,"Erasure must not leave private name text in a corrupted derived row")
    }
    func testRecordingNameErasureDoesNotTrustMissingSessionCacheMember()throws {
        var first=Memory(id:"cached-session-first",timestamp:now,kind:.audio,app:"Owned",title:"First",text:"First");first.audioSessionID="owned-real-session"
        var second=first;second.id="cached-session-second";second.timestamp=now.addingTimeInterval(30);second.title="Remaining";try store.insert(first);try store.insert(second)
        let source=try XCTUnwrap(store.recordedMeetingPage().sources.first),name=try store.saveRecordedMeetingName("Keep while a real member remains",for:source)
        try store.withRoutineDatabase {db in
            let row=try db.statement("DELETE FROM recorded_meeting_sources WHERE memory_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,second.id);try db.done(row)
        }
        let scope=HistoryErasureScope(start:now.addingTimeInterval(-1),end:now.addingTimeInterval(1),kind:.audio),review=try store.previewErasure(scope)
        XCTAssertEqual(review.sources,1,"Canonical remaining session members protect the name even when their rebuildable cache row is missing")
        guard review.sources==1 else {return}
        _=try store.eraseHistory(scope,expectedToken:review.token)
        XCTAssertNotNil(try store.get(second.id));XCTAssertNotNil(try store.get(name.id))
    }
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
