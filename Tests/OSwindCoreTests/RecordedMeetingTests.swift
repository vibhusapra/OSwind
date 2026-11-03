import XCTest
import CSQLite
@testable import OSwindCore

final class RecordedMeetingTests:XCTestCase {
    private var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recorded-meetings-"+UUID().uuidString);store=try MemoryStore(root:root)
    }
    override func tearDownWithError()throws {try store.close();try FileManager.default.removeItem(at:root)}
    @discardableResult private func audio(_ id:String,_ time:Double,session:String?="session",duration:Double=30,live:Bool=true,title:String="Team review",bundle:String="owned.meeting")throws->Memory {
        var memory=Memory(id:id,timestamp:Date(timeIntervalSince1970:time),endTimestamp:live ? Date(timeIntervalSince1970:time+duration):nil,kind:.audio,app:"Owned audio",bundleID:bundle,title:title,text:"Literal source words for "+id)
        memory.transcript = .init(text:memory.text,duration:duration,segments:[.init(start:0,end:duration,text:memory.text,speaker:"Speaker 1")],model:"Authored fixture")
        memory.audioSessionID=session;try store.insert(memory);return memory
    }
    func testExplicitRecordingGroupsPreserveSourcesAndUnionChannelsWithoutFillingGaps()throws {
        try audio("mic-1",100);try audio("system-1",100);try audio("mic-2",145);try audio("other",101,session:"different");try audio("legacy",102,session:nil)
        let page=try store.recordedMeetingPage(),groups=RecordedMeetingPlanner.group(page.sources)
        XCTAssertNil(page.next);XCTAssertEqual(page.examined,5);XCTAssertEqual(groups.count,3)
        let meeting=try XCTUnwrap(groups.first {$0.sources.count==3})
        XCTAssertEqual(meeting.observedSeconds,60,accuracy:0.001);XCTAssertEqual(meeting.latest.timeIntervalSince(meeting.first),75,accuracy:0.001)
        XCTAssertEqual(meeting.clipSeconds,90);XCTAssertFalse(meeting.hasUnobservedTimes)
        for source in meeting.sources {XCTAssertEqual(try store.recordedMeetingEvidence(source).id,source.memoryID)}
    }
    func testImportDateDoesNotBecomeAnObservedMeetingSpanOrMergeNearbyFiles()throws {
        try audio("file-a",100,session:"import-a",duration:3600,live:false);try audio("file-b",101,session:"import-b",duration:600,live:false)
        let groups=RecordedMeetingPlanner.group(try store.recordedMeetingPage().sources)
        XCTAssertEqual(groups.count,2);XCTAssertTrue(groups.allSatisfy {$0.observedSeconds==0 && $0.first==$0.latest && $0.hasUnobservedTimes})
        XCTAssertEqual(groups.reduce(0) {$0+$1.clipSeconds},4200)
    }
    func testLegacyClipWithoutAnIntervalKeepsItsRecordingTimeUnknown()throws {
        try audio("legacy",100,session:nil,duration:90,live:false,title:"Old microphone recording")
        let source=try XCTUnwrap(store.recordedMeetingPage().sources.first),session=try XCTUnwrap(RecordedMeetingPlanner.group([source]).first)
        XCTAssertFalse(source.hasObservedInterval);XCTAssertTrue(session.hasUnobservedTimes);XCTAssertEqual(session.observedSeconds,0);XCTAssertEqual(session.clipSeconds,90)
        XCTAssertEqual(session.first,session.latest,"A retained date is not an inferred ninety-second meeting interval")
    }
    func testEqualTimestampPaginationAndUnicodeIdentifiersKeepEverySource()throws {
        for id in ["a","z","é","e\u{301}"] {try audio(id,100,session:id)}
        var cursor:RecordedMeetingCursor?,all=[RecordedMeetingSource]()
        repeat {let page=try store.recordedMeetingPage(before:cursor,limit:1);all+=page.sources;cursor=page.next}while cursor != nil
        XCTAssertEqual(all.count,4);XCTAssertEqual(Set(all.map {Data($0.memoryID.utf8)}).count,4)
        XCTAssertEqual(RecordedMeetingPlanner.group(all).count,4);XCTAssertEqual(Set(all.map(\.id)).count,4)
    }
    func testPrivacyExclusionsStillAdvanceCursorAndCurrentPolicyRefusesRetainedReference()throws {
        try audio("visible",1);try audio("excluded",2,bundle:"owned.blocked")
        let prior=try XCTUnwrap(store.recordedMeetingPage().sources.first {$0.memoryID=="excluded"})
        var settings=AppSettings();settings.privacy.excludedApps.append("owned.blocked");try settings.save(root:root)
        let first=try store.recordedMeetingPage(limit:1);XCTAssertTrue(first.sources.isEmpty);XCTAssertEqual(first.excluded,1);XCTAssertNotNil(first.next)
        let second=try store.recordedMeetingPage(before:first.next,limit:1);XCTAssertEqual(second.sources.map(\.memoryID),["visible"]);XCTAssertNil(second.next)
        XCTAssertThrowsError(try store.recordedMeetingEvidence(prior))
        settings.privacy.excludedApps.removeAll {$0=="owned.blocked"};try settings.save(root:root)
        XCTAssertEqual(try store.recordedMeetingEvidence(prior).id,"excluded")
    }
    func testSourceUpdateDeletionRecreationRegroupingAndForeignStoreRefuseStaleReferences()throws {
        var memory=try audio("source",100),reference=try XCTUnwrap(store.recordedMeetingPage().sources.first)
        memory.title="Updated source";try store.insert(memory);XCTAssertThrowsError(try store.recordedMeetingEvidence(reference))
        reference=try XCTUnwrap(store.recordedMeetingPage().sources.first)
        let other=try MemoryStore(root:root);defer {try? other.close()}
        XCTAssertThrowsError(try other.recordedMeetingEvidence(reference))
        try audio("newer",101);let cursor=try XCTUnwrap(store.recordedMeetingPage(limit:1).next);XCTAssertThrowsError(try other.recordedMeetingPage(before:cursor))
        try store.delete("source");try store.insert(memory);XCTAssertThrowsError(try store.recordedMeetingEvidence(reference))
        let new=try XCTUnwrap(store.recordedMeetingPage().sources.first {$0.memoryID=="source"});memory.audioSessionID="new group";try store.insert(memory)
        XCTAssertThrowsError(try store.recordedMeetingEvidence(new))
    }
    func testLegacySQLPayloadMutationMaintainsThinIndexAndReopenRepairsDroppedTrigger()throws {
        var memory=try audio("source",100),reference=try XCTUnwrap(store.recordedMeetingPage().sources.first)
        memory.audioSessionID="new session";memory.title="Edited through source SQL"
        let payload=try JSONEncoder().encode(memory)
        try store.withRoutineDatabase {db in
            let row=try db.statement("UPDATE memories SET payload=?,title=? WHERE id=?");defer {sqlite3_finalize(row)}
            _=payload.withUnsafeBytes {sqlite3_bind_blob(row,1,$0.baseAddress,Int32(payload.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))};db.bind(row,2,memory.title);db.bind(row,3,memory.id);try db.done(row)
        }
        XCTAssertThrowsError(try store.recordedMeetingEvidence(reference));let changed=try XCTUnwrap(store.recordedMeetingPage().sources.first)
        XCTAssertEqual(changed.title,memory.title);XCTAssertNotEqual(changed.sessionKey,reference.sessionKey)
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER recorded_meeting_update; DELETE FROM recorded_meeting_sources")}
        try store.close();store=try MemoryStore(root:root)
        reference=try XCTUnwrap(store.recordedMeetingPage().sources.first);XCTAssertEqual(reference.title,memory.title);XCTAssertEqual(try store.recordedMeetingEvidence(reference).audioSessionID,"new session")
    }
    func testChangingAudioToNoteRemovesItsProjectionAndRestoringItGetsANewReference()throws {
        var memory=try audio("source",100);let transcript=memory.transcript,reference=try XCTUnwrap(store.recordedMeetingPage().sources.first)
        memory.kind = .note;memory.transcript=nil;memory.endTimestamp=nil;try store.insert(memory)
        XCTAssertTrue(try store.recordedMeetingPage().sources.isEmpty);XCTAssertThrowsError(try store.recordedMeetingEvidence(reference))
        memory.kind = .audio;memory.transcript=transcript;try store.insert(memory)
        let restored=try XCTUnwrap(store.recordedMeetingPage().sources.first);XCTAssertNotEqual(restored.revision,reference.revision)
    }
    func testSettingsChangeBeforePublicationRefusesWithoutPublishingOldMetadata()throws {
        try audio("source",100);let page=try store.recordedMeetingPage();var published=false
        var settings=AppSettings();settings.privacy.excludedApps.append("owned.meeting");try settings.save(root:root)
        XCTAssertThrowsError(try store.withCurrentRecordedMeetingPage(page) {published=true});XCTAssertFalse(published)
        let current=try store.recordedMeetingPage();try store.withCurrentRecordedMeetingPage(current) {published=true};XCTAssertTrue(published);XCTAssertTrue(current.sources.isEmpty)
    }
    func testPageReadsNoTranscriptPayloadAndProducesBoundedMetadata()throws {
        try audio("source",100,title:"Review api_key=secretvalue1234567890")
        try store.withRoutineDatabase {db in
            // An isolated ordinary fixture connection only. Refuse reads of the
            // canonical payload; this test closes it before any further write.
            sqlite3_set_authorizer(db.handle,{_,action,table,column,_,_ in
                if action==SQLITE_READ,let table,let column,String(cString:table)=="memories",String(cString:column)=="payload" {return SQLITE_DENY};return SQLITE_OK
            },nil)
        }
        let page=try store.recordedMeetingPage();XCTAssertEqual(page.sources.count,1);XCTAssertFalse(page.sources[0].title.contains("secretvalue1234567890"))
        try store.close()
    }
}
