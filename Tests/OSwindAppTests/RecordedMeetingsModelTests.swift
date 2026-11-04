import XCTest
import AppKit
import SwiftUI
import Combine
@testable import OSwindCore
@testable import OSwind

private final class RecordingChangeReadCounter:@unchecked Sendable {
    private let lock=NSLock()
    private var value=0
    func increment() {lock.lock();value+=1;lock.unlock()}
    var count:Int {lock.lock();defer {lock.unlock()};return value}
}
@MainActor final class RecordedMeetingsModelTests:XCTestCase {
    private var root:URL!,store:MemoryStore!,work:LibraryWorkRegistry!,models=[RecordedMeetingsModel](),appModels=[AppModel](),sessions=[AppSession](),suites=[String]()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recorded-meeting-model-"+UUID().uuidString);store=try MemoryStore(root:root);work=LibraryWorkRegistry()
    }
    override func tearDown()async throws {
        models.forEach {$0.deactivate()};await work.cancelAndWait()
        for app in sessions {let joined=await app.lockForTermination();XCTAssertTrue(joined);try app.model?.store.close();app.model=nil}
        for model in appModels {model.prepareForLibrarySwitch();await model.cancelExternalWorkAndWait();try model.store.close()}
        try store.close();for suite in suites {UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)};try FileManager.default.removeItem(at:root)
    }
    @discardableResult private func audio(_ id:String,session:String="recording",at seconds:Double=1_793_738_000,live:Bool=true,title:String="Planning session",in library:MemoryStore?=nil)throws->Memory {
        var memory=Memory(id:id,timestamp:Date(timeIntervalSince1970:seconds),endTimestamp:live ? Date(timeIntervalSince1970:seconds+30):nil,kind:.audio,app:"Owned microphone",bundleID:"owned.meeting",title:title,text:"Authored source text "+id)
        memory.audioSessionID=session;memory.transcript = .init(text:memory.text,duration:30,segments:[.init(start:0,end:30,text:memory.text,speaker:"Speaker 1")],model:"Owned fixture")
        try (library ?? store).insert(memory);return memory
    }
    private func model(read:@escaping @Sendable (MemoryStore,RecordedMeetingCursor?)throws->RecordedMeetingPage = {try $0.recordedMeetingPage(before:$1)})->RecordedMeetingsModel {
        let value=RecordedMeetingsModel(store:store,work:work,readPage:read);value.allowed={true};models.append(value);return value
    }
    private func settle(_ value:RecordedMeetingsModel)async throws {
        let end=SuspendingClock.now.advanced(by:.seconds(15));while value.busy,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))};XCTAssertFalse(value.busy)
    }
    func testLoadGroupsAndOpensExactCurrentSourceReference()async throws {
        try audio("a");try audio("b",at:1_793_738_040);try audio("c",session:"import",live:false,title:"Imported discussion")
        let value=model();value.activate();try await settle(value)
        XCTAssertNil(value.error);XCTAssertEqual(value.sessions.count,2);XCTAssertFalse(value.hasOlder)
        let selected=try XCTUnwrap(value.sessions.first {$0.sources.count==2}),source=try XCTUnwrap(selected.sources.first);var opened:RecordedMeetingSource?
        value.openSource={opened=$0};value.open(source);XCTAssertEqual(opened,source);XCTAssertEqual(try store.recordedMeetingEvidence(source).id,source.memoryID)
        value.deactivate();opened=nil;value.open(source);XCTAssertNil(opened)
    }
    func testArchiveDisplaysSessionNamesBeforeSelectionWithoutChangingSourceTitles()async throws {
        try audio("a",session:"first");try audio("b",session:"second")
        let page=try store.recordedMeetingPage()
        for ref in page.sources {_=try store.saveRecordedMeetingName(ref.memoryID=="a" ? "First saved name":"Second saved name",for:ref)}
        let value=model();value.activate();try await settle(value)
        XCTAssertEqual(value.nameSummaries.count,2)
        for session in value.sessions {
            XCTAssertEqual(value.title(for:session),session.sources.first?.memoryID=="a" ? "First saved name":"Second saved name")
            XCTAssertEqual(session.sources.first?.title,"Planning session")
        }
        value.deactivate();XCTAssertTrue(value.nameSummaries.isEmpty)
    }
    func testArchiveNamesIncludePinnedSelectionOutsideTheContiguousHeadWindow()async throws {
        for index in 0..<600 {try audio("named-\(index)",session:"session-\(index)",at:Double(index))}
        let value=RecordedMeetingsModel(store:store,work:work,foreground:{true},pollSeconds:{10_000});value.allowed={true};models.append(value)
        value.activate();try await settle(value);value.loadOlder();try await settle(value)
        let selected=try XCTUnwrap(value.sessions.first {$0.sources.first?.memoryID=="named-0"}),ref=try XCTUnwrap(selected.sources.first)
        _=try store.saveRecordedMeetingName("Pinned older session",for:ref);value.selectedID=selected.id
        for index in 600..<1300 {try audio("named-\(index)",session:"session-\(index)",at:Double(index))}
        await value.checkForChanges();try await settle(value)
        XCTAssertEqual(value.selectedID,selected.id);XCTAssertEqual(try value.title(for:XCTUnwrap(value.selected)),"Pinned older session")
        XCTAssertTrue(value.hasOlder);XCTAssertEqual(value.sessions.flatMap(\.sources).count,1025)
        value.loadOlder();try await settle(value);XCTAssertFalse(value.hasOlder)
        XCTAssertEqual(Set(value.sessions.flatMap(\.sources).map(\.memoryID)),Set((0..<1300).map {"named-\($0)"}))
    }
    func testNameMutationAfterSummaryPreparationCannotPublishAnObsoleteAlias()async throws {
        try audio("a");let ref=try XCTUnwrap(store.recordedMeetingPage().sources.first),first=try store.saveRecordedMeetingName("Old alias",for:ref)
        let gate=ImportWorkerGate(),reads=RecordingChangeReadCounter();defer {gate.release()}
        let value=RecordedMeetingsModel(store:store,work:work,foreground:{true},pollSeconds:{10_000},readSessionNames:{store,refs,revision in
            let result=try store.recordedMeetingSessionNames(for:refs,at:revision);reads.increment();if reads.count==1 {try gate.pause()};return result
        });value.allowed={true};models.append(value);value.activate();await fulfillment(of:[gate.entered],timeout:5)
        _=try store.saveRecordedMeetingName("Current alias",for:ref,replacing:first);gate.release();try await settle(value)
        XCTAssertEqual(value.sessions.count,1);XCTAssertEqual(try value.title(for:XCTUnwrap(value.sessions.first)),"Current alias")
        XCTAssertFalse(value.nameSummaries.values.contains {$0.name=="Old alias"})
    }
    func testDepartedArchiveSummaryWorkerStaysJoinedAndCannotRestoreLabels()async throws {
        try audio("a");_=try store.saveRecordedMeetingName("Private alias",for:XCTUnwrap(store.recordedMeetingPage().sources.first))
        let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordedMeetingsModel(store:store,work:work,readSessionNames:{store,refs,revision in let result=try store.recordedMeetingSessionNames(for:refs,at:revision);try gate.pause();return result})
        value.allowed={true};models.append(value);value.activate();await fulfillment(of:[gate.entered],timeout:5);value.deactivate()
        var joined=false;let draining=Task {await work.cancelAndWait();joined=true}
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(joined)
        gate.release();await draining.value;XCTAssertTrue(value.sessions.isEmpty);XCTAssertTrue(value.nameSummaries.isEmpty)
    }
    func testOlderViewDepartureCannotClearANewerAppearance()async throws {
        try audio("a");let value=model(),old=value.activate();try await settle(value)
        let fresh=value.activate();try await settle(value);value.deactivate(old)
        XCTAssertEqual(value.sessions.count,1);XCTAssertNotNil(value.selected)
        value.deactivate(fresh);XCTAssertTrue(value.sessions.isEmpty);XCTAssertFalse(value.status.contains("1 recording"))
    }
    func testPrivacyChangeAfterReadBeforePublicationHidesOldRows()async throws {
        try audio("a");let gate=ImportWorkerGate();defer {gate.release()}
        let value=model {store,cursor in let page=try store.recordedMeetingPage(before:cursor);try gate.pause();return page}
        value.activate();await fulfillment(of:[gate.entered],timeout:5)
        var settings=AppSettings();settings.privacy.excludedApps.append("owned.meeting");try settings.save(root:root)
        gate.release();try await settle(value);XCTAssertTrue(value.sessions.isEmpty);XCTAssertNotNil(value.error)
    }
    func testForeignPageCannotPublishInAnotherLibrary()async throws {
        let other=try MemoryStore(root:root.appendingPathComponent("other"));defer {try? other.close()};try audio("other",in:other)
        let value=model {_,_ in try other.recordedMeetingPage()};value.activate();try await settle(value)
        XCTAssertNotNil(value.error);XCTAssertTrue(value.sessions.isEmpty)
    }
    func testGroupingRunsOffMainThreadAndRechecksPrivacyBeforePublication()async throws {
        try audio("a");let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordedMeetingsModel(store:store,work:work,groupSources:{sources in
            XCTAssertFalse(Thread.isMainThread,"Grouping must not run in the actor publication callback")
            try gate.pause();return RecordedMeetingPlanner.group(sources)
        });value.allowed={true};models.append(value)
        value.activate();await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertTrue(value.busy);XCTAssertTrue(value.sessions.isEmpty)
        var settings=AppSettings();settings.privacy.excludedApps.append("owned.meeting");try settings.save(root:root)
        gate.release();try await settle(value);XCTAssertTrue(value.sessions.isEmpty);XCTAssertNotNil(value.error)
    }
    func testDeletedRecordingDuringGroupingCannotReappearFromPreparedPage()async throws {
        try audio("deleted");let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordedMeetingsModel(store:store,work:work,groupSources:{sources in try gate.pause();return RecordedMeetingPlanner.group(sources)})
        value.allowed={true};models.append(value)
        var publishedIDs=[String]();let observer=value.$sessions.sink {publishedIDs += $0.flatMap(\.sources).map(\.memoryID)};defer {observer.cancel()}
        value.activate();await fulfillment(of:[gate.entered],timeout:5)
        let other=try MemoryStore(root:root);try other.delete("deleted");try other.close()
        XCTAssertNil(try store.get("deleted"));XCTAssertTrue(try store.recordedMeetingPage().sources.isEmpty)
        gate.release();try await settle(value)
        XCTAssertTrue(value.sessions.isEmpty);XCTAssertFalse(publishedIDs.contains("deleted"),"A page already obsolete before publication must not flash its removed source")
    }
    func testRevisionPollingIgnoresHiddenLockedAndUnrelatedWrites()async throws {
        try audio("a");var active=false,admitted=true
        let reads=RecordingChangeReadCounter(),windows=RecordingChangeReadCounter()
        let value=RecordedMeetingsModel(store:store,work:work,foreground:{active},pollSeconds:{10_000},readRevision:{store in reads.increment();return try store.recordedMeetingRevision()},readWindow:{store,count,refs in windows.increment();return try store.recordedMeetingWindow(pages:count,retaining:refs)})
        value.allowed={admitted};models.append(value);value.activate();try await settle(value)
        await value.checkForChanges();XCTAssertEqual(reads.count,0)
        active=true;admitted=false;await value.checkForChanges();XCTAssertEqual(reads.count,0)
        admitted=true;let before=value.sessions
        let other=try MemoryStore(root:root);try other.insert(Memory(id:"note",kind:.note,app:"Owned notes",text:"Authored unrelated note"));try other.close()
        await value.checkForChanges();XCTAssertEqual(reads.count,1);XCTAssertEqual(windows.count,0);XCTAssertEqual(value.sessions,before)
        value.deactivate();await value.checkForChanges();XCTAssertEqual(reads.count,1)
    }
    func testChangedWindowPreservesSelectionAndPagesThroughMoreThan512Arrivals()async throws {
        for index in 0..<600 {try audio("clip-\(index)",session:"session-\(index)",at:Double(index))}
        let value=RecordedMeetingsModel(store:store,work:work,foreground:{true},pollSeconds:{10_000});value.allowed={true};models.append(value)
        value.activate();try await settle(value);value.loadOlder();try await settle(value)
        let selected=try XCTUnwrap(value.sessions.first {$0.sources.first?.memoryID=="clip-0"});value.selectedID=selected.id
        let other=try MemoryStore(root:root);defer {try? other.close()}
        for index in 600..<1300 {try audio("clip-\(index)",session:"session-\(index)",at:Double(index),in:other)}
        await value.checkForChanges();try await settle(value)
        XCTAssertNil(value.error);XCTAssertEqual(value.selectedID,selected.id);XCTAssertEqual(value.selected?.sources.map(\.memoryID),["clip-0"])
        XCTAssertEqual(value.sessions.flatMap(\.sources).count,1025);XCTAssertTrue(value.hasOlder)
        value.loadOlder();try await settle(value);XCTAssertNil(value.error);XCTAssertFalse(value.hasOlder)
        XCTAssertEqual(Set(value.sessions.flatMap(\.sources).map(\.memoryID)),Set((0..<1300).map {"clip-\($0)"}))
        var moved=try XCTUnwrap(other.get("clip-0"));moved.audioSessionID="moved-session";moved.title="New owned title";try other.insert(moved)
        await value.checkForChanges();try await settle(value)
        XCTAssertFalse(value.sessions.contains {$0.id==selected.id});XCTAssertTrue(value.sessions.flatMap(\.sources).contains {$0.memoryID=="clip-0" && $0.title=="New owned title"})
        try other.delete("clip-1299");await value.checkForChanges();try await settle(value)
        XCTAssertFalse(value.sessions.flatMap(\.sources).contains {$0.memoryID=="clip-1299"});XCTAssertNil(value.error)
    }
    func testOlderPageCannotMergeAnAlreadyDeletedLoadedMember()async throws {
        for index in 0..<600 {try audio("clip-\(index)",session:"session-\(index)",at:Double(index))}
        let gate=ImportWorkerGate(),groups=RecordingChangeReadCounter();defer {gate.release()}
        let value=RecordedMeetingsModel(store:store,work:work,foreground:{true},pollSeconds:{10_000},groupSources:{sources in groups.increment();if groups.count==2 {try gate.pause()};return RecordedMeetingPlanner.group(sources)})
        value.allowed={true};models.append(value);value.activate();try await settle(value);value.loadOlder();await fulfillment(of:[gate.entered],timeout:5)
        let other=try MemoryStore(root:root);try other.delete("clip-599");try other.close()
        var emitted=[String]();let observer=value.$sessions.sink {emitted += $0.flatMap(\.sources).map(\.memoryID)}
        emitted=[];gate.release();try await settle(value);observer.cancel()
        XCTAssertFalse(value.sessions.flatMap(\.sources).contains {$0.memoryID=="clip-599"});XCTAssertFalse(emitted.contains("clip-599"));XCTAssertNil(value.error)
        XCTAssertEqual(value.sessions.flatMap(\.sources).count,599)
    }
    func testArchiveChangeDuringLoadOlderPreservesTheRequestedExtraPageBudget()async throws {
        for index in 0..<600 {try audio("clip-\(index)",session:"session-\(index)",at:Double(index))}
        let value=RecordedMeetingsModel(store:store,work:work,foreground:{true},pollSeconds:{10_000});value.allowed={true};models.append(value)
        value.activate();try await settle(value);XCTAssertEqual(value.sessions.count,512)
        let other=try MemoryStore(root:root);try audio("arrived",session:"arrived",at:600,in:other);try other.close()
        value.loadOlder();try await settle(value)
        XCTAssertNil(value.error);XCTAssertFalse(value.hasOlder);XCTAssertEqual(value.sessions.flatMap(\.sources).count,601)
        XCTAssertEqual(Set(value.sessions.flatMap(\.sources).map(\.memoryID)),Set((0..<600).map {"clip-\($0)"}).union(["arrived"]))
    }
    func testActualAppDepartureJoinsBlockedRevisionReaderBeforeStoreClose()async throws {
        let location=root.appendingPathComponent("app-revision");try Paths.ensure(location);var settings=AppSettings();settings.captureOnLaunch=false;settings.apiEnabled=false;settings.routinesEnabled=false;settings.entityAutomaticIndex=false;settings.automaticMaintenance=false;try settings.save(root:location)
        let suite="org.oswind.tests.recorded-revision."+UUID().uuidString;suites.append(suite)
        let app=AppSession(selection:.init(url:location,requiresExisting:false,origin:"owned-revision"),defaults:UserDefaults(suiteName:suite)!,locked:{false});sessions.append(app)
        let end=SuspendingClock.now.advanced(by:.seconds(20));while app.busy,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertNil(app.failure);let old=try XCTUnwrap(app.model);old.showOnboarding=false;try audio("a",in:old.store)
        let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordedMeetingsModel(store:old.store,work:old.libraryWork,foreground:{true},pollSeconds:{10_000},readRevision:{store in let revision=try store.recordedMeetingRevision();try gate.pause();return revision});value.allowed={[weak old] in old?.libraryWorkAvailable==true};models.append(value)
        value.activate();try await settle(value);let check=Task {await value.checkForChanges()};await fulfillment(of:[gate.entered],timeout:5);value.deactivate()
        let joined=Task {await app.lockForTermination()};for _ in 0..<10 {await Task.yield()}
        XCTAssertTrue(old.libraryWork.busy);XCTAssertFalse(old.store.isClosed);gate.release();await check.value
        let clean=await joined.value;XCTAssertTrue(clean);XCTAssertFalse(old.libraryWork.busy);try old.store.close();app.model=nil;XCTAssertTrue(value.sessions.isEmpty)
    }
    func testWindowRefreshWorkerRemainsOwnedUntilActualAppDepartureCompletes()async throws {
        let location=root.appendingPathComponent("app-window");try Paths.ensure(location);var settings=AppSettings();settings.captureOnLaunch=false;settings.apiEnabled=false;settings.routinesEnabled=false;settings.entityAutomaticIndex=false;settings.automaticMaintenance=false;try settings.save(root:location)
        let suite="org.oswind.tests.recorded-window."+UUID().uuidString;suites.append(suite)
        let app=AppSession(selection:.init(url:location,requiresExisting:false,origin:"owned-window"),defaults:UserDefaults(suiteName:suite)!,locked:{false});sessions.append(app)
        let end=SuspendingClock.now.advanced(by:.seconds(20));while app.busy,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertNil(app.failure);let old=try XCTUnwrap(app.model);old.showOnboarding=false;try audio("a",in:old.store)
        let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordedMeetingsModel(store:old.store,work:old.libraryWork,foreground:{true},pollSeconds:{10_000},readWindow:{store,count,refs in let window=try store.recordedMeetingWindow(pages:count,retaining:refs);try gate.pause();return window});value.allowed={[weak old] in old?.libraryWorkAvailable==true};models.append(value)
        value.activate();try await settle(value);try audio("b",in:old.store);await value.checkForChanges();await fulfillment(of:[gate.entered],timeout:5);value.deactivate()
        let joined=Task {await app.lockForTermination()};for _ in 0..<10 {await Task.yield()}
        XCTAssertTrue(old.libraryWork.busy);XCTAssertFalse(old.store.isClosed);gate.release();let clean=await joined.value
        XCTAssertTrue(clean);XCTAssertFalse(old.libraryWork.busy);try old.store.close();app.model=nil;XCTAssertTrue(value.sessions.isEmpty)
    }
    func testQuietRefreshRetainsTheSelectedDisplayUntilCurrentReplacementIsReady()async throws {
        try audio("a",session:"first");let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordedMeetingsModel(store:store,work:work,foreground:{true},pollSeconds:{10_000},readWindow:{store,count,refs in let window=try store.recordedMeetingWindow(pages:count,retaining:refs);try gate.pause();return window})
        value.allowed={true};models.append(value);value.activate();try await settle(value);let selected=try XCTUnwrap(value.selectedID)
        let other=try MemoryStore(root:root);try audio("b",session:"second",in:other);try other.close()
        await value.checkForChanges();await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertTrue(value.busy);XCTAssertEqual(value.selectedID,selected);XCTAssertEqual(value.sessions.flatMap(\.sources).map(\.memoryID),["a"]);XCTAssertNil(value.error)
        gate.release();try await settle(value);XCTAssertEqual(value.selectedID,selected);XCTAssertEqual(Set(value.sessions.flatMap(\.sources).map(\.memoryID)),["a","b"])
    }
    func testExternalPrivacySettingsClearTheOldDisplayBeforeReplacementPreparation()async throws {
        try audio("a");let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordedMeetingsModel(store:store,work:work,foreground:{true},pollSeconds:{10_000},readWindow:{store,count,refs in let window=try store.recordedMeetingWindow(pages:count,retaining:refs);try gate.pause();return window})
        value.allowed={true};models.append(value);value.activate();try await settle(value);XCTAssertFalse(value.sessions.isEmpty)
        var settings=AppSettings();settings.privacy.excludedApps.append("owned.meeting");try settings.save(root:root)
        await value.checkForChanges();await fulfillment(of:[gate.entered],timeout:5);XCTAssertTrue(value.busy);XCTAssertTrue(value.sessions.isEmpty)
        gate.release();try await settle(value);XCTAssertTrue(value.sessions.isEmpty);XCTAssertNil(value.error)
    }
    func testPrivacyHiddenHeadStillOffersOlderAllowedRecordings()async throws {
        let location=root.appendingPathComponent("hidden-head");var settings=AppSettings();settings.captureOnLaunch=false;settings.apiEnabled=false;settings.routinesEnabled=false;settings.entityAutomaticIndex=false;settings.automaticMaintenance=false;settings.privacy.excludedApps.append("owned.meeting");try settings.save(root:location)
        let app=try AppModel(root:location,startServices:false,recordingsLocked:{false});app.showOnboarding=false;appModels.append(app)
        var kept=try audio("older-allowed",session:"allowed",at:0,in:app.store);kept.bundleID="owned.allowed";kept.app="Allowed fixture";kept.title="Older allowed recording";try app.store.insert(kept)
        for index in 0..<512 {try audio("hidden-\(index)",at:Double(index+100),title:"Hidden authored clip",in:app.store)}
        let value=app.recordedMeetings;value.activate();try await settle(value);XCTAssertTrue(value.sessions.isEmpty);XCTAssertTrue(value.hasOlder)
        if let path=ProcessInfo.processInfo.environment["OSWIND_RECORDED_MEETING_UI_QA_DIR"] {
            let output=URL(fileURLWithPath:path);try Paths.ensure(output)
            for dark in [false,true] {try await render(RecordedMeetingsView(model:value).environmentObject(app),size:.init(width:900,height:650),dark:dark,model:value,expected:0,to:output.appendingPathComponent("hidden-head-\(dark ? "dark":"light").png"))}
        }
        // The render helper closes its hosting window and retires that
        // appearance. Reactivate before exercising the next user action.
        value.activate();try await settle(value);XCTAssertTrue(value.hasOlder);XCTAssertTrue(value.sessions.isEmpty)
        value.loadOlder();try await settle(value);XCTAssertNil(value.error);XCTAssertFalse(value.hasOlder)
        XCTAssertEqual(value.sessions.flatMap(\.sources).map(\.memoryID),["older-allowed"])
    }
    func testRenderQuietRefreshKeepsSelectedRecordingInBothAppearances()async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_RECORDED_MEETING_UI_QA_DIR"] else {throw XCTSkip("Explicit generated recording refresh components only")}
        let output=URL(fileURLWithPath:path);try Paths.ensure(output)
        for dark in [false,true] {
            let app=try AppModel(root:root.appendingPathComponent(dark ? "refresh-dark":"refresh-light"),startServices:false,recordingsLocked:{false});app.showOnboarding=false;appModels.append(app);try audio("a",session:"first",in:app.store)
            let blocker=RecordingWindowRenderBlocker();defer {blocker.gate.release()}
            let value=RecordedMeetingsModel(store:app.store,work:app.libraryWork,foreground:{true},pollSeconds:{10_000},readWindow:{store,count,refs in let window=try store.recordedMeetingWindow(pages:count,retaining:refs);try blocker.pauseIfEnabled();return window});value.allowed={true};models.append(value)
            let size=NSSize(width:900,height:650),content=RecordedMeetingsView(model:value).environmentObject(app).frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(dark ? .dark:.light)
            let view=NSHostingView(rootView:content),window=NSWindow(contentRect:.init(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;defer {window.close()}
            value.activate();view.layoutSubtreeIfNeeded();window.displayIfNeeded();try await Task.sleep(for:.milliseconds(350));try await settle(value)
            XCTAssertEqual(value.sessions.count,1);let selection=value.selectedID;blocker.enable();try audio("b",session:"second",in:app.store);await value.checkForChanges();await fulfillment(of:[blocker.gate.entered],timeout:5)
            XCTAssertTrue(value.busy);XCTAssertEqual(value.sessions.count,1);XCTAssertEqual(value.selectedID,selection)
            view.layoutSubtreeIfNeeded();window.displayIfNeeded();let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
            let bytes=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]));try bytes.write(to:output.appendingPathComponent("updating-\(dark ? "dark":"light").png"));XCTAssertGreaterThan(bytes.count,4000)
            blocker.gate.release();try await settle(value);XCTAssertEqual(value.sessions.count,2);XCTAssertEqual(value.selectedID,selection)
        }
    }
    func testPublicPeerIncomingRecordingAndDeletionUpdateTheActiveAppWorkspace()async throws {
        let app=try AppModel(root:root.appendingPathComponent("receiving-app"),startServices:false,recordingsLocked:{false});app.showOnboarding=false;appModels.append(app)
        let credentials=RecordingPeerCredentialFixture(),machine=RecordingPeerMachine(),state=root.appendingPathComponent("peer-state")
        let env=SyncNativeWriterEnvironment(stateRoot:state,machine:machine,storage:{_ in credentials}),peer=try MemoryStore(root:root.appendingPathComponent("sending-peer"),recoveryReadOnly:false,nativeWriterEnvironment:env)
        let owner=try PersonalSyncPairing(store:app.store,stateRoot:state,machine:machine,storage:credentials),joining=try PersonalSyncPairing(store:peer,stateRoot:state,machine:machine,storage:credentials)
        var peers=[PersonalSyncSession]()
        do {
            let now=Date();_=try owner.createGroup(deviceName:"Owned receiving app",now:now)
            let fingerprint=try XCTUnwrap(owner.status().rootFingerprint),request=try XCTUnwrap(joining.requestJoin(deviceName:"Owned sending fixture",now:now).request)
            _=try joining.acceptResponse(owner.approve(owner.reviewRequest(request,now:now),now:now),trustedRootFingerprint:fingerprint,now:now)
            let folder=root.appendingPathComponent("peer-provider"),receiving=try owner.prepareSession(sharedFolder:folder,createSharedFolder:true),sending=try joining.prepareSession(sharedFolder:folder);peers=[sending,receiving]
            let value=RecordedMeetingsModel(store:app.store,work:app.libraryWork,foreground:{true},pollSeconds:{0.05});value.allowed={[weak app] in app?.libraryWorkAvailable==true};models.append(value)
            value.activate();try await settle(value);XCTAssertTrue(value.sessions.isEmpty)
            try audio("peer-original",session:"peer-recording",in:peer)
            func cycle()async throws {
                for session in peers {
                    try await session.setProcessingEnabled(true);let deadline=SuspendingClock.now.advanced(by:.seconds(20))
                    while true {
                        let state=await session.status();if state.phase == .upToDate {break}
                        guard state.phase != .failed,state.phase != .waitingForPolicy,SuspendingClock.now<deadline else {throw OSwindError.unavailable("Owned public recording peer cycle refused or timed out")}
                        try await Task.sleep(for:.milliseconds(5))
                    }
                    try await session.setProcessingEnabled(false)
                }
            }
            for _ in 0..<8 {try await cycle();if !value.sessions.isEmpty {break};try await Task.sleep(for:.milliseconds(60))}
            let deadline=SuspendingClock.now.advanced(by:.seconds(5));while value.sessions.isEmpty,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
            let source=try XCTUnwrap(value.sessions.first?.sources.first);XCTAssertNotEqual(source.memoryID,"peer-original");XCTAssertEqual(try app.store.recordedMeetingEvidence(source).text,"Authored source text peer-original")
            try peer.delete("peer-original")
            for _ in 0..<8 {try await cycle();if try app.store.recordedMeetingPage().sources.isEmpty {break}}
            let erased=SuspendingClock.now.advanced(by:.seconds(5));while !value.sessions.isEmpty,SuspendingClock.now<erased {try await Task.sleep(for:.milliseconds(10))}
            XCTAssertTrue(value.sessions.isEmpty);XCTAssertNil(value.error);XCTAssertNil(try app.store.get(source.memoryID))
            value.deactivate();for session in peers {try await session.stop()};owner.close();joining.close();try peer.close()
        }catch {for session in peers {try? await session.stop()};owner.close();joining.close();try? peer.close();throw error}
    }
    func testVisibleTimerRefreshesNewOwnedRecordingAndStopsOnDeparture()async throws {
        let value=RecordedMeetingsModel(store:store,work:work,foreground:{true},pollSeconds:{0.05});value.allowed={true};models.append(value)
        value.activate();try await settle(value);try audio("arrived")
        let end=SuspendingClock.now.advanced(by:.seconds(5));while value.sessions.isEmpty,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(value.sessions.flatMap(\.sources).map(\.memoryID),["arrived"]);XCTAssertNil(value.error)
        value.deactivate();await work.cancelAndWait();try await Task.sleep(for:.milliseconds(100));XCTAssertFalse(work.busy);XCTAssertTrue(value.sessions.isEmpty)
    }
    func testActualAppDepartureJoinsBlockedGroupingBeforeStoreClose()async throws {
        let location=root.appendingPathComponent("app-group");try Paths.ensure(location);var settings=AppSettings();settings.captureOnLaunch=false;settings.apiEnabled=false;settings.routinesEnabled=false;settings.entityAutomaticIndex=false;settings.automaticMaintenance=false;try settings.save(root:location)
        let suite="org.oswind.tests.recorded-group."+UUID().uuidString;suites.append(suite)
        let app=AppSession(selection:.init(url:location,requiresExisting:false,origin:"owned-group"),defaults:UserDefaults(suiteName:suite)!,locked:{false});sessions.append(app)
        let end=SuspendingClock.now.advanced(by:.seconds(20));while app.busy,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.busy);XCTAssertNil(app.failure);let old=try XCTUnwrap(app.model);old.showOnboarding=false;try audio("a",in:old.store)
        let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordedMeetingsModel(store:old.store,work:old.libraryWork,groupSources:{sources in try gate.pause();return RecordedMeetingPlanner.group(sources)});value.allowed={[weak old] in old?.libraryWorkAvailable==true};models.append(value)
        value.activate();await fulfillment(of:[gate.entered],timeout:5);value.deactivate()
        let joined=Task {await app.lockForTermination()};for _ in 0..<10 {await Task.yield()}
        XCTAssertTrue(old.libraryWork.busy);XCTAssertFalse(old.store.isClosed);XCTAssertTrue(value.sessions.isEmpty)
        gate.release();let clean=await joined.value;XCTAssertTrue(clean);XCTAssertFalse(old.libraryWork.busy);try old.store.close();app.model=nil
        XCTAssertTrue(value.sessions.isEmpty)
    }
    func testActualAppDepartureJoinsBlockedRecordingPageBeforeStoreClose()async throws {
        let location=root.appendingPathComponent("app");try Paths.ensure(location);var settings=AppSettings();settings.captureOnLaunch=false;settings.apiEnabled=false;settings.routinesEnabled=false;settings.entityAutomaticIndex=false;settings.automaticMaintenance=false;try settings.save(root:location)
        let suite="org.oswind.tests.recorded-meeting."+UUID().uuidString;suites.append(suite)
        let app=AppSession(selection:.init(url:location,requiresExisting:false,origin:"owned-meeting"),defaults:UserDefaults(suiteName:suite)!,locked:{false});sessions.append(app)
        let end=SuspendingClock.now.advanced(by:.seconds(20));while app.busy,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.busy);XCTAssertNil(app.failure);let old=try XCTUnwrap(app.model);old.showOnboarding=false;try audio("a",in:old.store)
        let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordedMeetingsModel(store:old.store,work:old.libraryWork,readPage:{store,cursor in try gate.pause();return try store.recordedMeetingPage(before:cursor)});value.allowed={[weak old] in old?.libraryWorkAvailable==true};models.append(value)
        value.activate();await fulfillment(of:[gate.entered],timeout:5);value.deactivate()
        let joined=Task {await app.lockForTermination()};for _ in 0..<10 {await Task.yield()}
        XCTAssertTrue(old.libraryWork.busy);XCTAssertFalse(old.store.isClosed);XCTAssertTrue(value.sessions.isEmpty)
        gate.release();let clean=await joined.value;XCTAssertTrue(clean);XCTAssertFalse(old.libraryWork.busy);try old.store.close();app.model=nil
        XCTAssertTrue(value.sessions.isEmpty)
    }
    func testActualAppDeletionRefreshesRecordingsAndErasurePauseClearsVisibleTitles()async throws {
        let app=try AppModel(root:root,startServices:false,recordingsLocked:{false});appModels.append(app);app.showOnboarding=false
        let removed=try audio("removed",session:"remove",in:app.store);try audio("kept",session:"keep",in:app.store)
        let value=app.recordedMeetings
        XCTAssertTrue(value.allowed(),"Owned unlocked fixture must enter the actual recording workspace")
        value.activate();try await settle(value);XCTAssertEqual(value.sessions.count,2)
        app.delete(removed)
        let end=SuspendingClock.now.advanced(by:.seconds(15));while app.deletingID != nil,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertNil(app.deletingID);try await settle(value)
        XCTAssertEqual(value.sessions.flatMap(\.sources).map(\.memoryID),["kept"]);XCTAssertNil(try app.store.get("removed"))
        app.pauseForHistoryErasure();XCTAssertTrue(value.sessions.isEmpty);XCTAssertNil(value.selectedID);XCTAssertFalse(value.busy)
        XCTAssertNotNil(try app.store.get("kept"),"Pausing removes previews, not canonical surviving sources")
    }
    func testActualAppRecordingsRefuseLockedAdmissionAndCanReloadAfterUnlock()async throws {
        var locked=true
        let app=try AppModel(root:root,startServices:false,recordingsLocked:{locked});appModels.append(app);app.showOnboarding=false
        try audio("owned",in:app.store);let value=app.recordedMeetings
        value.activate();XCTAssertFalse(value.allowed());XCTAssertFalse(value.busy);XCTAssertTrue(value.sessions.isEmpty)
        locked=false;XCTAssertTrue(value.allowed());value.refresh();try await settle(value)
        XCTAssertEqual(value.sessions.flatMap(\.sources).map(\.memoryID),["owned"])
        locked=true;value.invalidate();XCTAssertFalse(value.allowed());XCTAssertFalse(value.busy);XCTAssertTrue(value.sessions.isEmpty)
        XCTAssertNotNil(try app.store.get("owned"),"Locking a view does not erase its canonical source")
    }
    func testRecordingAskRouteAndSavedChatFollowupRetainExactScope()async throws {
        let app=try AppModel(root:root,startServices:false,recordingsLocked:{false});appModels.append(app);app.showOnboarding=false;app.settings.ai.provider = .evidence
        try audio("allowed",session:"selected",in:app.store);try audio("neighbor",session:"other",in:app.store)
        let value=app.recordedMeetings;value.activate();try await settle(value)
        value.selectedID=try XCTUnwrap(value.sessions.first {$0.sources.first?.memoryID=="allowed"}).id;value.askSelected()
        let deadline=SuspendingClock.now.advanced(by:.seconds(20))
        while app.section != "Ask",SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertEqual(app.section,"Ask");XCTAssertEqual(app.recordingScope?.id,"selected");XCTAssertEqual(app.range,"All time")
        app.ask("source",interpretation:false)
        while app.asking,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.asking);XCTAssertEqual(app.answer?.sources.map(\.id),["allowed"])
        let chat=try XCTUnwrap(app.currentChatID);app.newChat();XCTAssertNil(app.recordingScope);app.selectChat(chat)
        XCTAssertEqual(app.recordingScope?.id,"selected");app.ask("source",interpretation:false)
        while app.asking,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.asking);XCTAssertEqual(app.answer?.sources.map(\.id),["allowed"])
        XCTAssertTrue(try app.store.chatTurns(chat).allSatisfy {$0.filter.recordingScope?.id=="selected"})
    }
    func testPendingRecordingRequestCannotReplaceNewChatHistoryOrDepartedSection()async throws {
        let app=try AppModel(root:root,startServices:false,recordingsLocked:{false});appModels.append(app);app.showOnboarding=false
        try audio("a",session:"selected",in:app.store)
        let history=try app.store.saveChatTurn(question:"Owned general history",answer:.init(text:"No evidence",sources:[],provider:"evidence",duration:0))
        let value=app.recordedMeetings;value.activate();try await settle(value);let reference=try XCTUnwrap(value.selected?.sources.first)
        for action in ["new","history","section"] {
            app.newChat();app.section="Meetings"
            let gate=ImportWorkerGate();defer {gate.release()}
            app.beginRecordingChat(reference,readScope:{store,source in try gate.pause();return try store.recordingScope(for:source)})
            await fulfillment(of:[gate.entered],timeout:5)
            switch action {case "new":app.newChat();case "history":app.selectChat(history.sessionID);default:app.section="Notes"}
            gate.release()
            let deadline=SuspendingClock.now.advanced(by:.seconds(20))
            while app.libraryWork.count(kinds:[.query])>0,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
            XCTAssertEqual(app.libraryWork.count(kinds:[.query]),0);XCTAssertNil(app.recordingScope,action)
            XCTAssertEqual(app.section,action=="section" ? "Notes":"Meetings",action)
            XCTAssertEqual(app.currentChatID,action=="history" ? history.sessionID:nil,action)
        }
    }
    func testNewerRecordingRequestWinsWhenEarlierScopeReadFinishesLast()async throws {
        let app=try AppModel(root:root,startServices:false,recordingsLocked:{false});appModels.append(app);app.showOnboarding=false;app.section="Meetings"
        try audio("a",session:"first",in:app.store);try audio("b",session:"second",in:app.store)
        let value=app.recordedMeetings;value.activate();try await settle(value)
        let first=try XCTUnwrap(value.sessions.first {$0.sources.first?.memoryID=="a"}),second=try XCTUnwrap(value.sessions.first {$0.sources.first?.memoryID=="b"})
        value.selectedID=first.id;let gate=ImportWorkerGate();defer {gate.release()}
        app.beginRecordingChat(try XCTUnwrap(first.sources.first),readScope:{store,source in try gate.pause();return try store.recordingScope(for:source)})
        await fulfillment(of:[gate.entered],timeout:5);value.selectedID=second.id;value.askSelected()
        let deadline=SuspendingClock.now.advanced(by:.seconds(20))
        while app.recordingScope?.id != "second",SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertEqual(app.recordingScope?.id,"second");gate.release()
        while app.libraryWork.count(kinds:[.query])>0,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertEqual(app.libraryWork.count(kinds:[.query]),0);XCTAssertEqual(app.recordingScope?.id,"second");XCTAssertEqual(app.section,"Ask")
    }
    func testRecordingRecapShortcutIncludesOlderRecordingAndPreservesScopedFollowup()async throws {
        let app=try AppModel(root:root,startServices:false,recordingsLocked:{false});appModels.append(app);app.showOnboarding=false;app.settings.ai.provider = .evidence
        try audio("old",session:"selected",at:946_684_800,in:app.store);try audio("neighbor",session:"other",at:946_684_800,in:app.store)
        app.section="Ask";app.recordingScope=try .init(sessionID:"selected");app.range="Today";app.interpretQuery=true
        app.recapSelection()
        func settled()async throws {
            let deadline=SuspendingClock.now.advanced(by:.seconds(20))
            while app.asking,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
            XCTAssertFalse(app.asking)
        }
        try await settled();XCTAssertEqual(app.range,"All time");XCTAssertEqual(app.answer?.sources.map(\.id),["old"])
        XCTAssertTrue(app.answer?.warnings.contains(where:{$0.contains("distributed sample")})==true)
        app.draftStandup();try await settled();XCTAssertEqual(app.range,"All time");XCTAssertEqual(app.answer?.sources.map(\.id),["old"])
        let chat=try XCTUnwrap(app.currentChatID),turns=try app.store.chatTurns(chat)
        XCTAssertEqual(turns.count,2);XCTAssertTrue(turns.allSatisfy {$0.filter.start==nil && $0.filter.recordingScope?.id=="selected"})
    }
    func testRenderScopedRecordingActionsAndAskBadge()async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_RECORDING_SCOPE_UI_DIR"] else {throw XCTSkip("Explicit generated scoped recording components only")}
        let output=URL(fileURLWithPath:path);try Paths.ensure(output)
        let app=try AppModel(root:root,startServices:false,recordingsLocked:{false});appModels.append(app);app.showOnboarding=false
        try audio("a",in:app.store);try audio("b",in:app.store)
        let value=app.recordedMeetings;value.activate();try await settle(value)
        for dark in [false,true] {
            try await render(RecordedMeetingsView(model:value).environmentObject(app),size:.init(width:770,height:570),dark:dark,model:value,expected:1,to:output.appendingPathComponent("recording-actions-\(dark ? "dark":"light").png"))
            app.recordingScope=try .init(sessionID:"recording");app.interpretQuery=false;app.range="All time";app.section="Ask"
            try await render(AskView().environmentObject(app),size:.init(width:1000,height:720),dark:dark,model:value,expected:1,to:output.appendingPathComponent("scoped-ask-\(dark ? "dark":"light").png"))
        }
    }
    func testRenderRecordingsCompactEmptyAndSetupFailureInBothAppearances()async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_RECORDED_MEETING_UI_QA_DIR"] else {throw XCTSkip("Explicit generated recording workspace components only")}
        let output=URL(fileURLWithPath:path);try Paths.ensure(output)
        let app=try AppModel(root:root,startServices:false,audioSetup:{store,embedder,settings in
            var startup=AudioStartupEnvironment();startup.locked={false}
            startup.authorizeMicrophone={XCTFail("Missing-model refusal must precede microphone authorization");return false}
            startup.makeEngine={throw OSwindError.unavailable("Owned render never opens audio hardware")}
            return AudioController(store:store,embedder:embedder,settings:settings,startup:startup)
        },recordingsLocked:{false});appModels.append(app);app.showOnboarding=false
        try audio("mic-a",in:app.store);try audio("system-a",in:app.store);try audio("mic-b",at:1_793_738_045,in:app.store);try audio("file-a",session:"import",live:false,title:"Research interview",in:app.store)
        try audio("legacy",session:"legacy-untimed",at:1_793_730_000,live:false,title:"Legacy voice note",in:app.store)
        let value=app.recordedMeetings;value.activate();try await settle(value);XCTAssertEqual(value.sessions.count,3)
        for dark in [false,true] {
            try await render(RecordedMeetingsView(model:value).environmentObject(app),size:.init(width:1100,height:720),dark:dark,model:value,expected:3,to:output.appendingPathComponent("recordings-\(dark ? "dark":"light").png"))
            try await render(RecordedMeetingsView(model:value).environmentObject(app),size:.init(width:770,height:570),dark:dark,model:value,expected:3,to:output.appendingPathComponent("compact-\(dark ? "dark":"light").png"))
        }
        value.deactivate();for id in ["mic-a","system-a","mic-b","file-a","legacy"] {try app.store.delete(id)}
        value.activate();try await settle(value);XCTAssertTrue(value.sessions.isEmpty)
        for dark in [false,true] {try await render(RecordedMeetingsView(model:value).environmentObject(app),size:.init(width:900,height:650),dark:dark,model:value,expected:0,to:output.appendingPathComponent("empty-\(dark ? "dark":"light").png"))}
        // An owned missing executable fails before microphone/system startup.
        // Keep this refusal visible even though no audio work became active.
        app.settings.speech.engine = .whisper;app.settings.audioEnabled=true;app.settings.whisperBinary=root.appendingPathComponent("owned-missing-whisper").path
        await app.toggleAudio();XCTAssertFalse(app.audio.running);XCTAssertFalse(app.audio.hasActiveWork);XCTAssertNotEqual(app.audio.status,"Audio off");XCTAssertTrue(app.audio.status.contains("Whisper"))
        for dark in [false,true] {try await render(RecordedMeetingsView(model:value).environmentObject(app),size:.init(width:900,height:650),dark:dark,model:value,expected:0,to:output.appendingPathComponent("setup-failure-\(dark ? "dark":"light").png"))}
    }
    private func render<Content:View>(_ content:Content,size:NSSize,dark:Bool,model:RecordedMeetingsModel,expected:Int,to path:URL)async throws {
        model.activate();try await settle(model)
        let view=NSHostingView(rootView:content.frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(dark ? .dark:.light))
        let window=NSWindow(contentRect:.init(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;defer {window.close()}
        view.layoutSubtreeIfNeeded();window.displayIfNeeded();try await Task.sleep(for:.milliseconds(350));view.layoutSubtreeIfNeeded();window.displayIfNeeded()
        try await settle(model);XCTAssertEqual(model.sessions.count,expected,"Wrong recording scene before raster capture")
        view.layoutSubtreeIfNeeded();window.displayIfNeeded()
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap);let bytes=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]));try bytes.write(to:path);XCTAssertGreaterThan(bytes.count,4000)
    }
}

private struct RecordingPeerMachine:SyncMachineFingerprint {func fingerprint()throws->String {String(repeating:"7",count:64)}}
private final class RecordingPeerCredentialFixture:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let lock=NSLock()
    private var values=[String:Data]()
    func create(id:String,bytes:Data)throws {lock.lock();defer {lock.unlock()};guard values[id]==nil else {throw SyncCredentialStorageError.alreadyExists};values[id]=bytes}
    func read(id:String)throws->Data {lock.lock();defer {lock.unlock()};guard let value=values[id] else {throw SyncCredentialStorageError.missing};return value}
    func replace(id:String,expected:Data,bytes:Data)throws {lock.lock();defer {lock.unlock()};guard values[id]==expected else {throw SyncCredentialStorageError.changed};values[id]=bytes}
    func remove(id:String,expected:Data)throws {lock.lock();defer {lock.unlock()};guard values[id]==expected else {throw SyncCredentialStorageError.changed};values.removeValue(forKey:id)}
}

private final class RecordingWindowRenderBlocker:@unchecked Sendable {
    let gate=ImportWorkerGate()
    private let lock=NSLock()
    private var enabled=false
    func enable() {lock.lock();enabled=true;lock.unlock()}
    func pauseIfEnabled()throws {lock.lock();let active=enabled;lock.unlock();if active {try gate.pause()}}
}
