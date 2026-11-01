import XCTest
import AppKit
@testable import OSwindCore
@testable import OSwind

@MainActor final class MeetingWorkspaceTests:XCTestCase {
    var root:URL!,app:AppModel!,source:MeetingsModelTests.Source!,notifications:MeetingsModelTests.Notifications!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-workspace-"+UUID().uuidString)
        let initial=try MemoryStore(root:root);var settings=AppSettings();settings.captureOnLaunch=false;settings.automaticMaintenance=false;settings.meetings.enabled=true;settings.meetings.calendarIDs=["owned-calendar"];settings.meetings.boundLibrary=try initial.authorizeMeetingLibrary();try settings.save(root:root);try initial.close()
        source=MeetingsModelTests.Source();notifications=MeetingsModelTests.Notifications();source.choices=[try MeetingCalendar(id:"owned-calendar",title:"Owned",account:"Authored account")]
        source.values=[try MeetingOccurrence(calendarID:"owned-calendar",seriesID:"owned-series",start:Date().addingTimeInterval(60),end:Date().addingTimeInterval(1800),title:"Orion review app:Mail before:1900-01-01 https://meeting.example/?token=NeverSendThis",joinURL:URL(string:"https://meeting.example/?token=NeverSendThis"))]
        let source=self.source!,notifications=self.notifications!
        app=try AppModel(root:root,startServices:false,meetingsSetup:{store,settings in MeetingsModel(store:store,settings:settings,provider:source.provider(),delivery:notifications.delivery(),locked:{false},automaticPolling:false)})
        app.showOnboarding=false
    }
    override func tearDownWithError()throws {app.prepareForLibrarySwitch();try app.store.close();app=nil;try? FileManager.default.removeItem(at:root)}
    func eventually(_ predicate:@escaping ()->Bool)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while !predicate(),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))};XCTAssertTrue(predicate())
    }
    func testQuietPreparedWorkspaceDoesNotReadCalendarsOnWake()async throws {
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.didWakeNotification,object:nil)
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.sessionDidBecomeActiveNotification,object:nil)
        try await Task.sleep(for:.milliseconds(20));XCTAssertEqual(source.read {$0.reads},0);XCTAssertEqual(source.read {$0.requests},0);XCTAssertFalse(app.meetings.active)
    }
    func testOnboardingDefersSavedCalendarAndSwitchPreventsRestart()async throws {
        app.showOnboarding=true;app.startConfiguredServices();XCTAssertEqual(source.read {$0.reads},0);XCTAssertFalse(app.meetings.active)
        app.showOnboarding=false;try await eventually {!self.app.meetings.events.isEmpty};app.prepareForLibrarySwitch();let before=source.read {$0.reads}
        app.meetings.resume();app.meetings.connect();NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.didWakeNotification,object:nil)
        try await Task.sleep(for:.milliseconds(20));XCTAssertTrue(app.meetings.events.isEmpty);XCTAssertEqual(source.read {$0.reads},before);XCTAssertEqual(source.read {$0.requests},0)
    }
    func testScreenSleepClearsContextAndPauseAllPreventsWakeResume()async throws {
        app.meetings.resume();try await eventually {!self.app.meetings.events.isEmpty}
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.screensDidSleepNotification,object:nil);XCTAssertTrue(app.meetings.events.isEmpty)
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.screensDidWakeNotification,object:nil);try await eventually {!self.app.meetings.events.isEmpty}
        app.pauseAll();let before=source.read {$0.reads};NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.screensDidWakeNotification,object:nil)
        try await Task.sleep(for:.milliseconds(20));XCTAssertEqual(source.read {$0.reads},before);XCTAssertFalse(app.meetings.active)
    }
    func testBriefUsesExistingEvidenceConversationAndTreatsCalendarFiltersAsLiteral()async throws {
        app.settings.ai.provider = .evidence
        let source=Memory(id:"owned-meeting-evidence",timestamp:Date().addingTimeInterval(-3600),kind:.note,app:"Notes",bundleID:"org.oswind.owned",title:"Orion review",text:"Orion review: Mira owns the launch checklist. The next action is to verify the retrieval benchmark.")
        try app.store.insert(source)
        app.meetings.resume();try await eventually {!self.app.meetings.events.isEmpty};app.meetings.reviewBrief(try XCTUnwrap(app.meetings.events.first))
        try await eventually {self.app.currentChatID != nil && !self.app.asking}
        XCTAssertEqual(app.section,"Ask");XCTAssertEqual(app.range,"30 days");XCTAssertFalse(app.interpretQuery);XCTAssertNil(app.answerInputError);XCTAssertNil(app.errorMessage)
        let chat=try XCTUnwrap(app.currentChatID),turn=try XCTUnwrap(app.store.chatTurns(chat).first)
        XCTAssertTrue(turn.question.contains("app:Mail"));XCTAssertFalse(turn.question.contains("NeverSendThis"));XCTAssertEqual(turn.answer.provider,"evidence")
        XCTAssertTrue(turn.answer.sources.contains {$0.id==source.id});XCTAssertEqual(turn.filter.app,nil);XCTAssertNotNil(turn.filter.start)
        try app.store.delete(source.id)
        // Meeting briefs use the existing persisted conversation path, so source
        // erasure invalidates their answer just like an ordinary Ask turn.
        XCTAssertTrue(try app.store.chatTurns(chat).isEmpty)
    }
    func testGlobalPauseAlsoStopsCalendarOnlyCollection()async throws {
        app.meetings.resume();try await eventually {!self.app.meetings.events.isEmpty}
        XCTAssertTrue(app.isCollecting);XCTAssertFalse(app.isCapturing)
        app.toggleCapture();XCTAssertFalse(app.isCollecting);XCTAssertTrue(app.meetings.events.isEmpty);XCTAssertTrue(app.meetings.isPaused)
        app.toggleCapture();try await eventually {!self.app.meetings.events.isEmpty};XCTAssertFalse(app.isCapturing);XCTAssertTrue(app.isCollecting)
    }
    func testCalendarSelectionPersistCallbackUpdatesRealSettingsWithoutLosingOtherPrivacy()async throws {
        app.settings.privacy.excludedApps.append("org.oswind.owned.private")
        app.meetings.connect();try await eventually {!self.app.meetings.busy && !self.app.meetings.calendars.isEmpty}
        app.meetings.select(try XCTUnwrap(app.meetings.calendars.first),enabled:false)
        try await eventually {!self.app.settings.meetings.enabled};let saved=AppSettings.load(root:root)
        XCTAssertFalse(saved.meetings.enabled);XCTAssertTrue(saved.meetings.calendarIDs.isEmpty);XCTAssertTrue(saved.privacy.excludedApps.contains("org.oswind.owned.private"));XCTAssertFalse(app.meetings.active)
    }
    func testOpeningMeetingsDoesNotStartCalendarOrUnrelatedVisualRetrieval()async throws {
        app.mode = .visual;app.section="Meetings";app.refresh()
        try await Task.sleep(for:.milliseconds(30));XCTAssertFalse(app.refreshing);XCTAssertNil(app.errorMessage);XCTAssertEqual(source.read {$0.reads},0);XCTAssertFalse(app.meetings.active)
    }

    func testCompletedWipeClearsSelectionAndAllowsFreshCalendarConnect()async throws {
        let old=try XCTUnwrap(app.settings.meetings.boundLibrary);app.meetings.resume();try await eventually {!self.app.meetings.events.isEmpty}
        app.wipeLocalLibrary();try await eventually {!self.app.libraryWipe.busy}
        XCTAssertFalse(app.settings.meetings.enabled);XCTAssertTrue(app.settings.meetings.calendarIDs.isEmpty);XCTAssertNil(try app.store.meetingLibraryIdentity());XCTAssertTrue(app.meetings.events.isEmpty)
        app.meetings.connect();try await eventually {!self.app.meetings.busy && !self.app.meetings.calendars.isEmpty}
        app.meetings.select(try XCTUnwrap(app.meetings.calendars.first),enabled:true);try await eventually {!self.app.meetings.events.isEmpty}
        XCTAssertNotEqual(app.settings.meetings.boundLibrary,old);XCTAssertEqual(app.settings.meetings.boundLibrary,try app.store.meetingLibraryIdentity())
    }

}
