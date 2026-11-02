import XCTest
import AppKit
@testable import OSwindCore
@testable import OSwind

@MainActor final class MeetingsModelTests:XCTestCase {
    actor Gate {
        let entered=XCTestExpectation(description:"owned calendar operation entered")
        private var continuation:CheckedContinuation<Void,Never>?
        private(set) var returned=false
        func wait()async {await withCheckedContinuation {continuation=$0;entered.fulfill()};returned=true}
        func open() {continuation?.resume();continuation=nil}
    }
    final class Source:@unchecked Sendable {
        let lock=NSLock()
        var permission:MeetingCalendarAccess = .full
        var values=[MeetingOccurrence](),choices=[MeetingCalendar]()
        var clock:UInt64=0,reads=0,requests=0,calendarReads=0,completed=0
        var nextGate:Gate?
        func read<T>(_ body:(Source)->T)->T {lock.lock();defer {lock.unlock()};return body(self)}
        func change(_ values:[MeetingOccurrence]) {read {$0.values=values;$0.clock += 1}}
        func provider()->MeetingCalendarProvider {
            .init(access:{self.read {$0.permission}},request:{self.read {$0.requests += 1;return $0.permission}},calendars:{self.read {$0.calendarReads += 1;return $0.choices}},events:{ids,_,_,_ in
                let (feed,gate)=self.read {s in s.reads += 1;let gate=s.nextGate;s.nextGate=nil;return (MeetingFeed(events:s.values.filter {ids.contains($0.calendarID)},revision:s.clock),gate)}
                if let gate {await gate.wait()};self.read {$0.completed += 1};return feed
            },revision:{self.read {$0.clock}})
        }
    }
    actor Notifications {
        var permitted=true,requests=0,posts=[String](),removed=[String](),clears=[String](),visible=Set<String>()
        var postGate:Gate?,requestGate:Gate?
        func setPostGate(_ value:Gate) {postGate=value}
        func setRequestGate(_ value:Gate) {requestGate=value}
        func permission()->Bool {permitted}
        func request()async->Bool {requests += 1;if let gate=requestGate {requestGate=nil;await gate.wait()};return permitted}
        func post(_ id:String)async {if let gate=postGate {postGate=nil;await gate.wait()};posts.append(id);visible.insert(id)}
        func remove(_ ids:[String]) {removed += ids;visible.subtract(ids)}
        func clear(_ prefix:String) {clears.append(prefix);visible=visible.filter {!$0.hasPrefix(prefix)}}
        nonisolated func delivery()->MeetingNotificationDelivery {.init(allowed:{await self.permission()},request:{await self.request()},post:{await self.post($0)},remove:{await self.remove($0)},clear:{await self.clear($0)})}
    }
    var root:URL!,store:MemoryStore!,source:Source!,notifications:Notifications!,models=[MeetingsModel]()
    let now=Date(timeIntervalSince1970:1_793_490_000)
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meetings-model-"+UUID().uuidString);store=try MemoryStore(root:root);source=Source();notifications=Notifications()
        source.choices=[try MeetingCalendar(id:"owned-calendar",title:"Owned work",account:"Authored account")];source.values=[try event()]
    }
    override func tearDownWithError()throws {models.forEach {$0.stop(clear:true)};models=[];try store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func event(start:Date?=nil,title:String="Orion review")throws->MeetingOccurrence {
        let start=start ?? now.addingTimeInterval(60)
        return try .init(calendarID:"owned-calendar",seriesID:"owned-series",start:start,end:start.addingTimeInterval(1800),title:title,joinURL:URL(string:"https://meeting.example/owned?token=DoNotSend"))
    }
    func settings(reminders:Bool=false)throws->AppSettings {
        var value=AppSettings();value.meetings.enabled=true;value.meetings.calendarIDs=["owned-calendar"];value.meetings.boundLibrary=try store.authorizeMeetingLibrary();value.meetings.reminders=reminders;return value
    }
    func model(_ value:AppSettings?=nil,locked:@escaping ()->Bool={false},lowPower:@escaping ()->Bool={false})throws->MeetingsModel {
        let model=MeetingsModel(store:store,settings:try value ?? settings(),provider:source.provider(),delivery:notifications.delivery(),now:{self.now},locked:locked,lowPower:lowPower,automaticPolling:false);models.append(model);return model
    }
    func eventually(_ predicate:@escaping () async ->Bool)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !(await predicate()),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(2))}
        let passed=await predicate();XCTAssertTrue(passed)
    }
    func loaded(_ model:MeetingsModel)async throws {try await eventually {!model.busy && !model.events.isEmpty}}
    func testDisabledStartupQuietWakeAndRefreshNeverReadOrPrompt()async throws {
        let model=try model(AppSettings());model.start();model.wake();model.refresh(force:true);try await Task.sleep(for:.milliseconds(20))
        XCTAssertFalse(model.active);XCTAssertTrue(model.events.isEmpty);XCTAssertEqual(source.read {$0.reads},0);XCTAssertEqual(source.read {$0.requests},0);XCTAssertEqual(source.read {$0.calendarReads},0)
    }
    func testSelectedFeedUsesCacheUntilRevisionChangesAndNeverRequestsPermission()async throws {
        let model=try model();model.start();try await loaded(model);XCTAssertEqual(source.read {$0.reads},1)
        model.refresh();try await eventually {!model.busy};XCTAssertEqual(source.read {$0.reads},1)
        source.change([try event(title:"Changed review")]);model.invalidate();try await loaded(model)
        XCTAssertEqual(model.events.first?.title,"Changed review");XCTAssertEqual(source.read {$0.reads},2);XCTAssertEqual(source.read {$0.requests},0)
    }
    func testRevokedAccessStopsWithoutReadingEventsOrRequestingAgain()async throws {
        source.read {$0.permission = .writeOnly};let model=try model();model.start();try await eventually {!model.busy}
        XCTAssertFalse(model.active);XCTAssertTrue(model.events.isEmpty);XCTAssertEqual(model.access,.writeOnly);XCTAssertEqual(source.read {$0.reads},0);XCTAssertEqual(source.read {$0.requests},0)
    }
    func testWrongLibraryBindingStopsBeforeCalendarRead()async throws {
        var value=try settings();value.meetings.boundLibrary=String(repeating:"a",count:32)
        let model=try model(value);model.start();try await eventually {!model.busy}
        XCTAssertFalse(model.active);XCTAssertEqual(source.read {$0.reads},0);XCTAssertTrue(model.events.isEmpty)
    }
    func testPauseClearsDetailsAndWakeCannotResumeManualPause()async throws {
        let model=try model();model.start();try await loaded(model);model.pause();let reads=source.read {$0.reads}
        model.wake();model.refresh(force:true);try await Task.sleep(for:.milliseconds(20));XCTAssertTrue(model.events.isEmpty);XCTAssertFalse(model.active);XCTAssertEqual(source.read {$0.reads},reads)
        model.resume();try await loaded(model);XCTAssertEqual(source.read {$0.reads},reads+1)
    }
    func testSleepClearsDetailsAndRequestedWakeRefreshes()async throws {
        let model=try model();model.start();try await loaded(model);model.sleep();XCTAssertTrue(model.events.isEmpty);XCTAssertFalse(model.active)
        source.change([try event(title:"After wake")]);model.wake();try await loaded(model);XCTAssertEqual(model.events.first?.title,"After wake")
    }
    func testLateCalendarResponseCannotPublishAfterPause()async throws {
        let gate=Gate();source.read {$0.nextGate=gate};let model=try model();model.start();await fulfillment(of:[gate.entered],timeout:5)
        model.pause();await gate.open();try await eventually {self.source.read {$0.completed}==1};XCTAssertTrue(model.events.isEmpty);XCTAssertTrue(model.due.isEmpty);XCTAssertFalse(model.active)
    }
    func testCancelledDrainJoinsAlreadyStoppedCalendarResponseAndRejectsReactivation()async throws {
        let gate=Gate();source.read {$0.nextGate=gate};let model=try model();model.start();await fulfillment(of:[gate.entered],timeout:5)
        model.stop(clear:true);var done=false
        let drain=Task {await model.cancelAndWait();done=true};drain.cancel()
        try await Task.sleep(for:.milliseconds(30));XCTAssertFalse(done)
        model.start();model.connect();XCTAssertFalse(model.active);XCTAssertEqual(source.read {$0.requests},0)
        await gate.open();await drain.value;XCTAssertTrue(done);XCTAssertTrue(model.events.isEmpty)
        model.start();try await loaded(model);await model.cancelAndWait()
    }
    func testPrivacyEditRevokesInflightReadAndLeavesNoCalendarNames()async throws {
        let gate=Gate();source.read {$0.nextGate=gate};let model=try model();model.start();await fulfillment(of:[gate.entered],timeout:5)
        var blocked=try settings();blocked.privacy.excludedApps.append("com.apple.iCal");model.apply(blocked);await gate.open();try await eventually {self.source.read {$0.completed}==1}
        XCTAssertTrue(model.events.isEmpty);XCTAssertTrue(model.calendars.isEmpty);XCTAssertFalse(model.active)
    }
    func testLockGateRejectsReadAndExplicitConnectionWithoutPrompt()async throws {
        let model=try model(locked:{true});model.start();model.connect();model.wake();try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(source.read {$0.reads},0);XCTAssertEqual(source.read {$0.requests},0);XCTAssertFalse(model.active)
    }
    func testChangedOccurrenceRefusesBriefAndJoinUntilRefreshed()async throws {
        let model=try model();var briefs=0,joins=0;model.prepareBrief={_ in briefs += 1};model.openJoinURL={_ in joins += 1}
        model.start();try await loaded(model);let old=try XCTUnwrap(model.events.first)
        source.change([try event(title:"Updated review")]);model.join(old);try await eventually {!model.busy}
        XCTAssertEqual(joins,0);XCTAssertEqual(briefs,0);try await loaded(model)
        let fresh=try XCTUnwrap(model.events.first);model.reviewBrief(fresh);try await eventually {!model.busy};XCTAssertEqual(briefs,1)
    }
    func testOnlyExplicitVerifiedJoinOpensLink()async throws {
        let model=try model();var opened=[URL]();model.openJoinURL={opened.append($0)};model.start();try await loaded(model)
        XCTAssertTrue(opened.isEmpty);model.join(try XCTUnwrap(model.events.first));try await eventually {!model.busy}
        XCTAssertEqual(opened.map(\.host),["meeting.example"])
    }
    func testReminderAttemptIsDeduplicatedAcrossControllerRestart()async throws {
        let value=try settings(reminders:true),first=try model(value);first.start();try await loaded(first);try await eventually {await self.notifications.posts.count==1};first.stop(clear:true)
        let second=try model(value);second.start();try await loaded(second);try await Task.sleep(for:.milliseconds(30));let posts=await notifications.posts;XCTAssertEqual(posts.count,1)
        XCTAssertFalse(posts[0].contains("Orion"));XCTAssertFalse(posts[0].contains("DoNotSend"));XCTAssertLessThan(posts[0].utf8.count,180)
    }
    func testLateNotificationCompletionRemovesOnlyRetiredGeneration()async throws {
        let gate=Gate();await notifications.setPostGate(gate);let value=try settings(reminders:true),model=try model(value);model.start();await fulfillment(of:[gate.entered],timeout:5)
        model.pause();source.change([try event(start:now.addingTimeInterval(90))]);model.resume();try await loaded(model);try await eventually {await self.notifications.posts.count==1}
        await gate.open();try await eventually {await self.notifications.removed.count==1}
        let visible=await notifications.visible,posts=await notifications.posts,removed=await notifications.removed,clears=await notifications.clears
        XCTAssertEqual(visible.count,1);XCTAssertEqual(posts.count,2);XCTAssertFalse(visible.contains(removed[0]));XCTAssertTrue(clears.contains {removed[0].hasPrefix($0)});XCTAssertTrue(visible.allSatisfy {id in !clears.contains {id.hasPrefix($0)}})
    }
    func testExplicitSelectionBindsLibraryAndPersistsOnlySelectedIdentifiers()async throws {
        let model=try model(AppSettings());var saved=[MeetingContextConfiguration]();model.savePreferences={saved.append($0)}
        model.connect();try await eventually {!model.busy && !model.calendars.isEmpty};XCTAssertEqual(source.read {$0.requests},1);XCTAssertEqual(source.read {$0.reads},0)
        model.select(try XCTUnwrap(model.calendars.first),enabled:true);try await loaded(model)
        XCTAssertEqual(saved.count,1);XCTAssertEqual(saved[0].calendarIDs,["owned-calendar"]);XCTAssertEqual(saved[0].boundLibrary,try store.authorizeMeetingLibrary());XCTAssertFalse(saved[0].reminders)
    }
    func testStaleNotificationPermissionReplyCannotRestoreDisconnectedPreferences()async throws {
        let gate=Gate();await notifications.setRequestGate(gate);let model=try model();model.start();try await loaded(model);var saved=[MeetingContextConfiguration]();model.savePreferences={saved.append($0)}
        model.setReminderPreferences(enabled:true,lead:5);await fulfillment(of:[gate.entered],timeout:5);model.disconnect();await gate.open();try await eventually {await gate.returned};try await Task.sleep(for:.milliseconds(10))
        XCTAssertFalse(model.configuration.enabled);XCTAssertEqual(saved.count,1);XCTAssertFalse(saved[0].enabled)
    }
    func testExternalLibraryWipeDuringFeedReadRequiresNewSelection()async throws {
        let gate=Gate();source.read {$0.nextGate=gate};let model=try model();model.start();await fulfillment(of:[gate.entered],timeout:5)
        _=try store.wipeLibrary();await gate.open();try await eventually {self.source.read {$0.completed}==1 && !model.busy}
        XCTAssertTrue(model.events.isEmpty);XCTAssertFalse(model.active);XCTAssertTrue(model.status.contains("library changed"))
    }
    func testPowerModeChangesPollingIntervalWithoutAnEnergyClaim()throws {
        XCTAssertEqual(try model(lowPower:{false}).pollingSeconds,30);XCTAssertEqual(try model(lowPower:{true}).pollingSeconds,90)
    }
    func testEventRevisionChangeRemovesLateNotificationCompletion()async throws {
        let gate=Gate();await notifications.setPostGate(gate);let model=try model(settings(reminders:true));model.start();await fulfillment(of:[gate.entered],timeout:5)
        source.change([try event(title:"Changed meeting")]);model.invalidate();try await loaded(model);await gate.open()
        try await eventually {await self.notifications.removed.count==1};let visible=await notifications.visible;XCTAssertTrue(visible.isEmpty);XCTAssertEqual(model.events.first?.title,"Changed meeting")
    }

    func testChangedLibraryRootCannotRequestPermissionOrListCalendars()async throws {
        let fm=FileManager.default,moved=root.deletingLastPathComponent().appendingPathComponent("owned-meeting-moved-"+UUID().uuidString)
        let model=try model(AppSettings());try fm.moveItem(at:root,to:moved);try fm.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? fm.removeItem(at:root);try? fm.moveItem(at:moved,to:root)}
        model.connect();try await eventually {!model.busy};XCTAssertEqual(source.read {$0.requests},0);XCTAssertEqual(source.read {$0.calendarReads},0);XCTAssertTrue(model.calendars.isEmpty);XCTAssertNotNil(model.error)
    }

    func testActualTimerRefreshesChangedFeedWithoutAnInvalidationCallback()async throws {
        let refreshed=expectation(description:"owned periodic calendar refresh"),base=source.provider(),date=now
        var provider=base
        provider.events={ids,people,policy,now in let feed=try await base.events(ids,people,policy,now);if feed.revision>0 {refreshed.fulfill()};return feed}
        let model=MeetingsModel(store:store,settings:try settings(),provider:provider,delivery:notifications.delivery(),now:{date},locked:{false},lowPower:{false},automaticPolling:true);models.append(model)
        model.start();try await loaded(model);source.change([try event(title:"Periodic refresh")])
        await fulfillment(of:[refreshed],timeout:40);try await loaded(model);XCTAssertEqual(model.events.first?.title,"Periodic refresh");model.stop(clear:true)
        XCTAssertEqual(model.pollingSeconds,30);XCTAssertEqual(source.read {$0.reads},2)
    }

}
