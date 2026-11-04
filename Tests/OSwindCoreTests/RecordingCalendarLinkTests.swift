import XCTest
@testable import OSwindCore

final class RecordingCalendarLinkTests:XCTestCase {
    private var root:URL!,store:MemoryStore!,source:RecordedMeetingSource!,savedName:RecordedMeetingDetailsSnapshot!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recording-calendar-"+UUID().uuidString)
        store=try MemoryStore(root:root)
        var audio=Memory(id:"owned-audio",kind:.audio,app:"Owned",title:"Original capture",text:"Authored speech; no ASR");audio.audioSessionID="owned-session";try store.insert(audio)
        source=try XCTUnwrap(store.recordedMeetingPage().sources.first);savedName=try store.saveRecordedMeetingName("Authored name",for:source)
        var settings=AppSettings();settings.meetings.enabled=true;settings.meetings.boundLibrary=try store.authorizeMeetingLibrary();settings.meetings.calendarIDs=["owned-calendar"];try settings.save(root:root)
    }
    override func tearDownWithError()throws {try store.close();store=nil;try FileManager.default.removeItem(at:root)}
    private func link(calendar:String="owned-calendar",library:String?=nil)throws->RecordingCalendarLink {
        let start=Date(timeIntervalSince1970:1000)
        return try .init(event:.init(calendarID:calendar,seriesID:"owned-series",start:start,end:start.addingTimeInterval(1800),title:"Never copy calendar title",participants:["Never copy participant"],joinURL:URL(string:"https://meeting.example/DoNotCopy")),libraryIdentity:try library ?? XCTUnwrap(store.meetingLibraryIdentity()))
    }
    func testUnnamedRecordingCreatesReviewedLabelAndCalendarAtomically()throws {
        _=try store.removeRecordedMeetingName(savedName,for:source)
        let original=try store.get(source.memoryID),selection=try store.recordedMeetingCalendarSelection(for:source),value=try link()
        let created=try store.setRecordedMeetingCalendar(value,for:source,recordingName:"Chosen label",selection:selection,admit:{})
        XCTAssertEqual(created.name,"Chosen label");XCTAssertEqual(created.details.calendar,value);XCTAssertEqual(try store.get(source.memoryID),original)
        XCTAssertThrowsError(try store.setRecordedMeetingCalendar(value,for:source,recordingName:"Must not create a conflict",admit:{}))
        XCTAssertEqual(try store.recordedMeetingDetails(for:source),[created])
    }
    func testBorrowedReviewSnapshotRejectsIdenticalSettingsFileReplacement()throws {
        let selection=try store.recordedMeetingCalendarSelection(for:source,replacing:savedName),snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        let settings=AppSettings.load(root:root);try settings.save(root:root)
        XCTAssertThrowsError(try store.withCurrentRecordedMeetingCalendarSelection(selection,settingsSnapshot:snapshot) {})
        XCTAssertThrowsError(try store.setRecordedMeetingCalendar(link(),for:source,replacing:savedName,selection:selection,settingsSnapshot:snapshot,admit:{}))
        XCTAssertNil(try store.get(savedName.id)?.recordingDetails?.calendar)
    }
    func testReviewedLinkAndUnlinkPreserveNameAudioAndOpaqueOnlyReference()throws {
        let original=try store.get(source.memoryID),value=try link(),before=try store.recordedMeetingRevision()
        let saved=try store.setRecordedMeetingCalendar(value,for:source,replacing:savedName,admit:{})
        XCTAssertEqual(saved.name,savedName.name);XCTAssertEqual(saved.details.scope,savedName.details.scope);XCTAssertEqual(saved.details.calendar,value)
        XCTAssertNotEqual(try store.recordedMeetingRevision(),before);XCTAssertEqual(try store.get(source.memoryID),original)
        let data=try JSONEncoder().encode(XCTUnwrap(store.get(saved.id))),text=String(decoding:data,as:UTF8.self)
        for forbidden in ["Never copy calendar title","Never copy participant","DoNotCopy"] {XCTAssertFalse(text.contains(forbidden))}
        // Removing a dormant link does not require current Calendar permission.
        var settings=AppSettings.load(root:root);settings.meetings = .init();try settings.save(root:root)
        let removed=try store.setRecordedMeetingCalendar(nil,for:source,replacing:saved,admit:{})
        XCTAssertNil(removed.details.calendar);XCTAssertEqual(removed.name,savedName.name);XCTAssertEqual(try store.get(source.memoryID),original)
    }
    func testChangedProviderAfterMutationRollsBackNameRevisionAndBinding()throws {
        final class Admission:@unchecked Sendable {var calls=0;func check()throws {calls+=1;if calls==2 {throw OSwindError.unavailable("Owned provider changed")}}}
        let gate=Admission(),before=try store.recordedMeetingRevision(),original=try store.get(savedName.id),value=try link()
        XCTAssertThrowsError(try store.setRecordedMeetingCalendar(value,for:source,replacing:savedName,admit:{try gate.check()}))
        XCTAssertEqual(gate.calls,2);XCTAssertEqual(try store.get(savedName.id),original);XCTAssertEqual(try store.recordedMeetingRevision(),before)
    }
    func testUnselectedForeignLibraryDisabledAndCalendarPrivacyRefuse()throws {
        for value in [try link(calendar:"other-calendar"),try link(library:String(repeating:"a",count:32))] {XCTAssertThrowsError(try store.setRecordedMeetingCalendar(value,for:source,replacing:savedName,admit:{}))}
        let value=try link();var settings=AppSettings.load(root:root);settings.meetings.enabled=false;try settings.save(root:root)
        XCTAssertThrowsError(try store.setRecordedMeetingCalendar(value,for:source,replacing:savedName,admit:{}))
        settings.meetings.enabled=true;settings.privacy.excludedApps.append("com.apple.iCal");try settings.save(root:root)
        XCTAssertThrowsError(try store.setRecordedMeetingCalendar(value,for:source,replacing:savedName,admit:{}));XCTAssertNil(try store.get(savedName.id)?.recordingDetails?.calendar)
    }
    func testStaleNameAndSourceConflictAndForeignOwnerRefuse()throws {
        let value=try link(),other=try MemoryStore(root:root);defer {try? other.close()}
        XCTAssertThrowsError(try other.setRecordedMeetingCalendar(value,for:source,replacing:savedName,admit:{}))
        let renamed=try store.saveRecordedMeetingName("Renamed",for:source,replacing:savedName)
        XCTAssertThrowsError(try store.setRecordedMeetingCalendar(value,for:source,replacing:savedName,admit:{}))
        var duplicate=try XCTUnwrap(store.get(savedName.id));duplicate.id="conflicting-definition";try store.insert(duplicate)
        XCTAssertThrowsError(try store.setRecordedMeetingCalendar(value,for:source,replacing:renamed,admit:{}));try store.delete(duplicate.id)
        try store.setFavorite(source.memoryID,value:true)
        XCTAssertThrowsError(try store.setRecordedMeetingCalendar(value,for:source,replacing:renamed,admit:{}))
    }
    func testReentrantAdmissionCannotChangeSourceOrConflictSetAndCommit()throws {
        final class Change:@unchecked Sendable {var count=0;let run:()throws->Void;init(_ run:@escaping ()throws->Void){self.run=run};func check()throws {count+=1;if count==2 {try run()}}}
        let original=try store.get(source.memoryID),before=try store.recordedMeetingRevision(),value=try link(),ownedStore=store!,ownedSource=source!
        let change=Change {var updated=try XCTUnwrap(ownedStore.get(ownedSource.memoryID));updated.favorite=true;try ownedStore.insert(updated)}
        XCTAssertThrowsError(try store.setRecordedMeetingCalendar(value,for:source,replacing:savedName,admit:{try change.check()}))
        XCTAssertEqual(try store.get(source.memoryID),original);XCTAssertEqual(try store.recordedMeetingRevision(),before);XCTAssertNil(try store.get(savedName.id)?.recordingDetails?.calendar)
        let ownedName=savedName!,conflict=Change {
            var duplicate=try XCTUnwrap(ownedStore.get(ownedName.id));duplicate.id="reentrant-conflicting-definition";try ownedStore.insert(duplicate)
        }
        XCTAssertThrowsError(try store.setRecordedMeetingCalendar(value,for:source,replacing:savedName,admit:{try conflict.check()}))
        XCTAssertEqual(conflict.count,2);XCTAssertNil(try store.get("reentrant-conflicting-definition"))
        XCTAssertEqual(try store.recordedMeetingDetails(for:source),[savedName!]);XCTAssertEqual(try store.recordedMeetingRevision(),before)
    }
}
