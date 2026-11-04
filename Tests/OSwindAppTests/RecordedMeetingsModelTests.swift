import XCTest
import AppKit
import SwiftUI
@testable import OSwindCore
@testable import OSwind

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
