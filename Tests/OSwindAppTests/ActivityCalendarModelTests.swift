import XCTest
@testable import OSwind
@testable import OSwindCore

private actor CalendarModelFixture {
    var loads=0,version:Int64=1
    var waiting:CheckedContinuation<Void,Never>?
    var gateMonth:String?
    let entered=XCTestExpectation(description:"owned calendar model loader entered")
    init(gateMonth:String?=nil){self.gateMonth=gateMonth}
    func load(_ request:ActivityCalendarRequest) async throws -> ActivityCalendarSnapshot {
        loads+=1;let value=try request.layout()
        if request.month==gateMonth {await withCheckedContinuation {waiting=$0;entered.fulfill()}}
        return value
    }
    func release(){waiting?.resume();waiting=nil}
    func revision()->ActivityCalendarRevision {.init(ownChanges:version,externalVersion:1)}
    func change(){version+=1}
}
@MainActor final class ActivityCalendarModelTests:XCTestCase {
    let zone=TimeZone(identifier:"America/New_York")!
    func settled(_ model:ActivityCalendarModel,month:String) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while (model.busy || model.snapshot?.month != month),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(model.busy);XCTAssertEqual(model.snapshot?.month,month);XCTAssertNil(model.error)
    }
    func testMonthChangeDiscardsLatePreviousResponseAndClearsOldScope() async throws {
        let fixture=CalendarModelFixture(gateMonth:"2024-03"),model=ActivityCalendarModel(month:"2024-03",timeZone:zone,load:{try await fixture.load($0)},revision:{await fixture.revision()})
        defer {model.deactivate(clear:true)}
        model.reload();await fulfillment(of:[fixture.entered],timeout:5)
        model.month="2024-04";try await settled(model,month:"2024-04");await fixture.release()
        for _ in 0..<10 {await Task.yield()};XCTAssertEqual(model.snapshot?.month,"2024-04")
    }
    func testLibraryDeactivationClearsCountsAndRejectsLateCompletion() async throws {
        let fixture=CalendarModelFixture(gateMonth:"2024-03"),model=ActivityCalendarModel(month:"2024-03",timeZone:zone,load:{try await fixture.load($0)},revision:{await fixture.revision()})
        model.reload();await fulfillment(of:[fixture.entered],timeout:5);model.deactivate(clear:true);await fixture.release()
        for _ in 0..<10 {await Task.yield()};XCTAssertNil(model.snapshot);XCTAssertNil(model.error);XCTAssertFalse(model.busy)
    }
    func testUnchangedRevisionDoesNotReloadAndMutationDoes() async throws {
        let fixture=CalendarModelFixture(),model=ActivityCalendarModel(month:"2024-03",timeZone:zone,load:{try await fixture.load($0)},revision:{await fixture.revision()});defer {model.deactivate()}
        model.reload();try await settled(model,month:"2024-03");await model.checkForChanges();let first=await fixture.loads;XCTAssertEqual(first,1)
        await fixture.change();await model.checkForChanges();try await settled(model,month:"2024-03");let second=await fixture.loads;XCTAssertEqual(second,2)
    }
    func testRapidControlsCoalesceAndTimezonePreservesCivilMonth() async throws {
        let fixture=CalendarModelFixture(),model=ActivityCalendarModel(month:"2024-03",timeZone:zone,load:{try await fixture.load($0)},revision:{await fixture.revision()});defer {model.deactivate()}
        model.reload();model.month="2024-04";model.app="Notes";model.kind = .note;model.favoritesOnly=true;model.updateTimeZone(TimeZone(identifier:"Asia/Kathmandu")!)
        try await settled(model,month:"2024-04");XCTAssertEqual(model.snapshot?.timeZone,"Asia/Kathmandu");XCTAssertEqual(model.snapshot?.scope.app,"Notes");XCTAssertEqual(model.snapshot?.scope.kind,.note);XCTAssertEqual(model.snapshot?.scope.favoritesOnly,true);let loads=await fixture.loads;XCTAssertEqual(loads,1)
    }
    func testFrequentCaptureInvalidationsWaitForRevisionCadenceInsteadOfReloading() async throws {
        let fixture=CalendarModelFixture(),model=ActivityCalendarModel(month:"2024-03",timeZone:zone,load:{try await fixture.load($0)},revision:{await fixture.revision()});defer {model.deactivate()}
        model.activate();try await settled(model,month:"2024-03")
        for _ in 0..<20 {model.invalidate()}
        XCTAssertFalse(model.busy);let before=await fixture.loads;XCTAssertEqual(before,1)
        await model.checkForChanges();try await settled(model,month:"2024-03");let after=await fixture.loads;XCTAssertEqual(after,2)
    }
    func testDaySelectionKeepsMonthCountsButRequiresMatchingHourResponse() async throws {
        let fixture=CalendarModelFixture(),model=ActivityCalendarModel(month:"2024-11",timeZone:zone,load:{try await fixture.load($0)},revision:{await fixture.revision()});defer {model.deactivate()}
        model.reload();try await settled(model,month:"2024-11");model.selectedDay="2024-11-03";XCTAssertNotNil(model.snapshot);XCTAssertNil(model.snapshot?.selectedDay)
        try await settled(model,month:"2024-11");XCTAssertEqual(model.snapshot?.hours.count,25);XCTAssertEqual(model.snapshot?.selectedDay,"2024-11-03")
        model.month="2024-12";XCTAssertNil(model.selectedDay);XCTAssertNil(model.snapshot)
    }
    func testActualStoreRevisionRefreshAndClosedLibraryFailure() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-calendar-model-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),model=ActivityCalendarModel(store:store,timeZone:zone,now:try QueryScopeResolver.instant("2024-03-10T12:00:00-04:00"));defer {model.deactivate(clear:true);try? store.close()}
        model.reload();try await settled(model,month:"2024-03");XCTAssertEqual(model.snapshot?.totalSources,0)
        try store.insert(Memory(timestamp:try QueryScopeResolver.instant("2024-03-10T01:30:00-05:00"),text:"Owned source"));await model.checkForChanges();try await settled(model,month:"2024-03");XCTAssertEqual(model.snapshot?.totalSources,1)
        try store.close();model.reload();let deadline=ContinuousClock.now.advanced(by:.seconds(10));while model.busy,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))};XCTAssertFalse(model.busy);XCTAssertNotNil(model.error);XCTAssertNil(model.snapshot)
    }
    func testBrowseRepeatedHourUsesExactUTCIntervalAndMetadataScope() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-calendar-browse-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let app=try AppModel(root:root,startServices:false);defer {app.prepareForLibrarySwitch();try? app.store.close()}
        for (index,stamp) in ["2024-11-03T01:30:00-04:00","2024-11-03T01:30:00-05:00"].enumerated() {
            var memory=Memory(id:"owned-hour-\(index)",timestamp:try QueryScopeResolver.instant(stamp),kind:.audio,app:"Notes",text:"Owned words",favorite:true,tags:["release notes"])
            memory.transcript=SpeechTranscript(text:memory.text,duration:1,segments:[TranscriptSegment(start:0,end:1,text:memory.text,speaker:"Maya Chen")],model:"fixture");try app.store.insert(memory)
        }
        let request=ActivityCalendarRequest(month:"2024-11",timeZone:zone,selectedDay:"2024-11-03",filter:SearchFilter(app:"Notes",kind:.audio,favoritesOnly:true,tag:"release notes",speaker:"Maya Chen")),snapshot=try app.store.activityCalendar(request),repeated=try XCTUnwrap(snapshot.hours.filter {$0.hour==1}.last)
        app.browseActivity(start:repeated.start,end:repeated.end,snapshot:snapshot)
        XCTAssertEqual(app.section,"Memories");XCTAssertEqual(app.mode,.keyword);XCTAssertEqual(app.range,"Calendar slice");XCTAssertEqual(app.calendarSliceZone,zone.identifier)
        let filter=try QueryScopeResolver.resolve(app.filter,interpret:true).filter
        XCTAssertEqual(filter.start,repeated.start);XCTAssertEqual(filter.end,repeated.end);XCTAssertEqual(filter.app,"Notes");XCTAssertEqual(filter.kind,.audio);XCTAssertTrue(filter.favoritesOnly);XCTAssertEqual(filter.tag,"release notes");XCTAssertEqual(filter.speaker,"Maya Chen")
        let deadline=ContinuousClock.now.advanced(by:.seconds(10));while app.refreshing,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(app.refreshing);XCTAssertNil(app.searchInputError);XCTAssertEqual(app.hits.map(\.id),["owned-hour-1"])
    }
    func testMissingCalendarSliceFailsInsteadOfWideningAndLockClearsIt() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-calendar-clear-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let app=try AppModel(root:root,startServices:false);defer {app.prepareForLibrarySwitch();try? app.store.close()}
        app.range="Calendar slice";XCTAssertThrowsError(try QueryScopeResolver.resolve(app.filter))
        app.calendarSlice=DateInterval(start:Date(timeIntervalSince1970:100),duration:3600);app.calendarSliceZone=zone.identifier;app.pauseForHistoryErasure();XCTAssertNil(app.activity.snapshot);app.clearForVaultLock();XCTAssertNil(app.calendarSlice);XCTAssertNil(app.activity.snapshot)
    }
}
