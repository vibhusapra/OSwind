import XCTest
import CSQLite
@testable import OSwindCore
@testable import OSwind

@MainActor final class RecordingCalendarModelTests:XCTestCase {
    final class Provider:@unchecked Sendable {
        let lock=NSLock();var permission:MeetingCalendarAccess = .full,clock:UInt64=0,reads=0,requests=0
        var calendars=[MeetingCalendar]()
        var events=[MeetingOccurrence](),nextGate:MeetingsModelTests.Gate?
        func state<T>(_ f:(Provider)->T)->T {lock.lock();defer {lock.unlock()};return f(self)}
        func source()->MeetingCalendarProvider {
            .init(access:{self.state {$0.permission}},request:{self.state {$0.requests+=1;return $0.permission}},calendars:{[]},events:{_,_,_,_ in throw OSwindError.invalid("Recording review must use explicit historical range")},revision:{self.state {$0.clock}},eventsInRange:{ids,_,range in
                let (feed,gate)=self.state {s in s.reads+=1;let g=s.nextGate;s.nextGate=nil;return (MeetingFeed(events:s.events.filter {ids.contains($0.calendarID) && $0.start<range.end && $0.end>=range.start},revision:s.clock,calendars:s.calendars),g)}
                if let gate {await gate.wait()};return feed
            },accessNow:{self.state {$0.permission}})
        }
    }
    var root:URL!,store:MemoryStore!,work:LibraryWorkRegistry!,provider:Provider!,model:RecordingCalendarModel!,source:RecordedMeetingSource!,saved:RecordedMeetingDetailsSnapshot!
    let start=Date(timeIntervalSince1970:1_793_700_000)
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recording-calendar-ui-"+UUID().uuidString);store=try MemoryStore(root:root);work=LibraryWorkRegistry();provider=Provider()
        var audio=Memory(id:"owned-audio",timestamp:start,kind:.audio,app:"Owned",title:"Original capture",text:"Authored speech; no audio hardware");audio.audioSessionID="owned-session";try store.insert(audio)
        source=try XCTUnwrap(store.recordedMeetingPage().sources.first);saved=try store.saveRecordedMeetingName("Owned label",for:source)
        var settings=AppSettings();settings.meetings.enabled=true;settings.meetings.calendarIDs=["owned-calendar"];settings.meetings.boundLibrary=try store.authorizeMeetingLibrary();try settings.save(root:root)
        provider.events=[try event()];model=RecordingCalendarModel(store:store,work:work,provider:provider.source());model.allowed={true};model.select(source,expected:saved)
    }
    override func tearDown()async throws {model.clear();await work.cancelAndWait();try store.close();model=nil;store=nil;try FileManager.default.removeItem(at:root)}
    func event(title:String="Owned occurrence",series:String="owned-series")throws->MeetingOccurrence {try .init(calendarID:"owned-calendar",seriesID:series,start:start,end:start.addingTimeInterval(1800),title:title,joinURL:URL(string:"https://meet.example/DoNotCopy"))}
    func settle()async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(10));while work.busy,ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(5))};XCTAssertFalse(work.busy)
    }
    func choose()async throws {model.open();try await settle();XCTAssertTrue(model.loaded);model.selectedID=try XCTUnwrap(model.events.first?.id);XCTAssertTrue(model.canSave)}
    func testCalendarSaveFinishesWhileParentQuietRefreshIsStillReading()async throws {
        final class NextRead:@unchecked Sendable {
            private let lock=NSLock();private var value:ImportWorkerGate?
            func arm(_ gate:ImportWorkerGate) {lock.lock();value=gate;lock.unlock()}
            func take()->ImportWorkerGate? {lock.lock();defer {lock.unlock()};let result=value;value=nil;return result}
        }
        let read=NextRead(),heldRead=ImportWorkerGate(),heldCalendar=MeetingsModelTests.Gate()
        let names=RecordingNamesModel(store:store,work:work,calendarProvider:provider.source(),read:{store,source in
            let rows=try store.recordedMeetingDetails(for:source);if let gate=read.take() {try gate.pause()};return rows
        });names.allowed={true}
        defer {heldRead.release();names.clear()}
        names.select(source,revision:try store.recordedMeetingRevision());try await settle()
        let calendar=names.calendar;calendar.open();try await settle();calendar.selectedID=try XCTUnwrap(calendar.events.first?.id)
        provider.state {$0.nextGate=heldCalendar};calendar.save();await fulfillment(of:[heldCalendar.entered],timeout:5)
        var next=try XCTUnwrap(store.get(source.memoryID));next.id="clip-during-calendar-save";next.timestamp=start.addingTimeInterval(30);try store.insert(next)
        let latest=try XCTUnwrap(store.recordedMeetingPage().sources.first {$0.memoryID==next.id})
        read.arm(heldRead);names.suspend();names.select(latest,revision:try store.recordedMeetingRevision());await fulfillment(of:[heldRead.entered],timeout:5)
        await heldCalendar.open()
        let end=ContinuousClock.now.advanced(by:.seconds(5));while calendar.saving,ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(calendar.saving);XCTAssertNotNil(try store.get(saved.id)?.recordingDetails?.calendar)
        XCTAssertFalse(calendar.presented,"A completed save must close even while its parent is quietly refreshing")
        XCTAssertNotNil(calendar.notice,"The committed result must not disappear because a parent read is still in flight")
        heldRead.release();try await settle();names.clear()
    }

    func testLiveSessionAppendPreservesChosenCalendarOccurrence()async throws {
        try await choose();let chosen=model.selectedID
        var next=try XCTUnwrap(store.get(source.memoryID));next.id="next-live-clip";next.timestamp=start.addingTimeInterval(60);next.title="Next captured clip";try store.insert(next)
        let nextSource=try XCTUnwrap(store.recordedMeetingPage().sources.first {$0.memoryID==next.id})
        model.select(nextSource,expected:saved);try await settle()
        XCTAssertEqual(model.selectedID,chosen,"A new clip in the same explicit session must not discard the user's event choice")
        XCTAssertTrue(model.canSave);model.save();try await settle()
        XCTAssertNotNil(try store.get(saved.id)?.recordingDetails?.calendar)
    }
    func testArchiveQuietRefreshKeepsCalendarChoiceForLiveSessionArrival()async throws {
        let names=RecordingNamesModel(store:store,work:work,calendarProvider:provider.source());names.allowed={true};names.select(source,revision:try store.recordedMeetingRevision());try await settle()
        let calendar=names.calendar;calendar.open();try await settle();calendar.selectedID=calendar.events.first?.id;let selected=calendar.selectedID
        var next=try XCTUnwrap(store.get(source.memoryID));next.id="live-arrival";next.timestamp=start.addingTimeInterval(30);try store.insert(next)
        let newest=try XCTUnwrap(store.recordedMeetingPage().sources.first {$0.memoryID==next.id})
        names.suspend();names.select(newest,revision:try store.recordedMeetingRevision());try await settle()
        XCTAssertEqual(calendar.selectedID,selected);XCTAssertTrue(calendar.canSave);calendar.save();try await settle();XCTAssertNotNil(try store.get(saved.id)?.recordingDetails?.calendar);names.clear()
    }
    func testUnnamedRecordingLinksInOneFlowAndUsesEventTitleOnlyOnExplicitChoice()async throws {
        _=try store.removeRecordedMeetingName(saved,for:source)
        let names=RecordingNamesModel(store:store,work:work,calendarProvider:provider.source());names.allowed={true};names.select(source,revision:try store.recordedMeetingRevision());try await settle()
        let calendar=names.calendar;calendar.open();try await settle();XCTAssertTrue(calendar.loaded);XCTAssertTrue(calendar.requiresName);XCTAssertEqual(calendar.recordingName,"Original capture")
        calendar.selectedID=try XCTUnwrap(calendar.events.first?.id);calendar.useEventTitle();XCTAssertEqual(calendar.recordingName,"Owned occurrence");calendar.save();try await settle()
        let created=try XCTUnwrap(store.recordedMeetingDetails(for:source).first);XCTAssertEqual(created.name,"Owned occurrence");XCTAssertNotNil(created.details.calendar);XCTAssertEqual(names.rows,[created]);names.clear()
    }
    func testRevocationInsideActualMetadataStatementRollsBackLink()async throws {
        try await choose();let provider=provider!
        try store.withRoutineDatabase {db in sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,sql in
            if let context,let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("INSERT INTO memories(") {Unmanaged<Provider>.fromOpaque(context).takeUnretainedValue().state {$0.permission = .denied}};return 0
        },Unmanaged.passUnretained(provider).toOpaque())}
        defer {_ = try? store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)};withExtendedLifetime(provider) {}}
        model.save();try await settle();XCTAssertNil(try store.get(saved.id)?.recordingDetails?.calendar);XCTAssertNotNil(model.error)
    }
    func testExplicitHistoryReadFreshSaveAndUnlinkWithoutPermission()async throws {
        XCTAssertEqual(provider.state {$0.reads},0);try await choose();let original=try store.get(source.memoryID);model.save();try await settle()
        XCTAssertEqual(provider.state {$0.reads},2);XCTAssertEqual(provider.state {$0.requests},0);XCTAssertFalse(model.presented)
        let current=try XCTUnwrap(store.recordedMeetingDetails(for:source).first);XCTAssertEqual(current.details.calendar?.occurrenceID,provider.events.first?.id);XCTAssertEqual(try store.get(source.memoryID),original)
        model.select(source,expected:current);provider.state {$0.permission = .denied};model.unlink();try await settle();XCTAssertNil(try store.recordedMeetingDetails(for:source).first?.details.calendar)
    }
    func testNonfiniteDateRefusesBeforeNativeProviderRead()async throws {
        try await choose();let before=provider.state {$0.reads};model.date=Date(timeIntervalSinceReferenceDate:.nan);model.load();try await settle()
        XCTAssertEqual(provider.state {$0.reads},before);XCTAssertTrue(model.events.isEmpty);XCTAssertNotNil(model.error)
    }
    func testRevokedAccessClearsChoicesAndCannotSaveOrPrompt()async throws {
        try await choose();provider.state {$0.permission = .denied};model.checkForChanges();XCTAssertTrue(model.events.isEmpty);XCTAssertFalse(model.canSave);model.save();try await settle()
        XCTAssertNil(try store.get(saved.id)?.recordingDetails?.calendar);XCTAssertEqual(provider.state {$0.requests},0)
    }
    func testChangedOccurrenceWithoutClockAdvanceStillRefusesFreshSave()async throws {
        try await choose();provider.state {$0.events=[try! self.event(title:"Rescheduled title")]};model.save();try await settle()
        XCTAssertNotNil(model.error);XCTAssertNil(try store.get(saved.id)?.recordingDetails?.calendar);XCTAssertFalse(model.canSave)
    }
    func testClockChangeAfterHeldReadCannotPublish()async throws {
        let gate=MeetingsModelTests.Gate();provider.state {$0.nextGate=gate};model.open();await fulfillment(of:[gate.entered],timeout:5);provider.state {$0.clock+=1};await gate.open();try await settle()
        XCTAssertTrue(model.events.isEmpty);XCTAssertFalse(model.loaded);XCTAssertNotNil(model.error)
    }
    func testSettingsAtomicABAWhileHeldReadCannotPublish()async throws {
        let gate=MeetingsModelTests.Gate();provider.state {$0.nextGate=gate};model.open();await fulfillment(of:[gate.entered],timeout:5)
        let settings=AppSettings.load(root:root);try settings.save(root:root);await gate.open();try await settle()
        XCTAssertTrue(model.events.isEmpty);XCTAssertFalse(model.loaded);XCTAssertNotNil(model.error)
    }
    func testClearCancelsAndJoinsActualProviderWorkAndLateResultCannotReturn()async throws {
        let gate=MeetingsModelTests.Gate();provider.state {$0.nextGate=gate};model.open();await fulfillment(of:[gate.entered],timeout:5);model.clear()
        XCTAssertTrue(work.busy);XCTAssertTrue(model.events.isEmpty);XCTAssertFalse(model.presented)
        await gate.open();try await settle();XCTAssertTrue(model.events.isEmpty);XCTAssertFalse(model.presented)
    }
    func testUnselectedForeignAndDuplicateOccurrencesDoNotBecomeChoices()async throws {
        let foreign=try MeetingOccurrence(calendarID:"unselected",seriesID:"foreign",start:start,end:start.addingTimeInterval(30),title:"Never display")
        provider.state {$0.events=[foreign]};model.open();try await settle();XCTAssertTrue(model.loaded);XCTAssertTrue(model.events.isEmpty)
        provider.state {$0.events=[try! self.event(),try! self.event()]};model.load();try await settle();XCTAssertFalse(model.loaded);XCTAssertTrue(model.events.isEmpty);XCTAssertNotNil(model.error)
    }
    func testForeignSavedReferenceDoesNotAutomaticallyChooseMatchingLocalOccurrence()async throws {
        var memory=try XCTUnwrap(store.get(saved.id));memory.recordingDetails = .init(scope:saved.details.scope,calendar:try .init(event:provider.events[0],libraryIdentity:String(repeating:"f",count:32)));try store.insert(memory)
        let current=try XCTUnwrap(store.recordedMeetingDetails(for:source).first);model.select(source,expected:current);model.open();try await settle()
        XCTAssertTrue(model.loaded);XCTAssertNil(model.selectedID);XCTAssertFalse(model.canSave)
        model.selectedID=try XCTUnwrap(model.events.first?.id);model.save();try await settle()
        XCTAssertEqual(try store.get(saved.id)?.recordingDetails?.calendar?.libraryIdentity,try store.meetingLibraryIdentity())
    }
    func testChangedNameDuringHeldReadCannotPublishAndRetainsNewName()async throws {
        let gate=MeetingsModelTests.Gate();provider.state {$0.nextGate=gate};model.open();await fulfillment(of:[gate.entered],timeout:5)
        _=try store.saveRecordedMeetingName("Newer label",for:source,replacing:saved);await gate.open();try await settle()
        XCTAssertTrue(model.events.isEmpty);XCTAssertEqual(try store.get(saved.id)?.title,"Newer label");XCTAssertFalse(model.canSave)
    }
}
