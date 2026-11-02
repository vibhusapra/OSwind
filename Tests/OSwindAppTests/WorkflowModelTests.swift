import XCTest
import AppKit
@testable import OSwindCore
@testable import OSwind

@MainActor final class WorkflowModelTests:XCTestCase {
    var root:URL!,app:AppModel!,model:WorkflowModel!
    var locked=false,previews=0,exports=0,holdPreview=false,holdExport=false,commitBeforeGate=false
    var previewGate:CheckedContinuation<Void,Never>?,exportGate:CheckedContinuation<Void,Never>?
    var exportedDraft:WorkflowDraft?,lastPermit:WorkflowExportPermit?
    var queryGate:AudioImportGate?
    override func setUp()async throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-workflow-model-"+UUID().uuidString)
        app=try AppModel(root:root,startServices:false,workflowSetup:{[unowned self] store,settings in
            var env=WorkflowEnvironment(preview:{[unowned self] id,ordinal in
                self.previews+=1;if self.holdPreview {await withCheckedContinuation {self.previewGate=$0}}
                return self.frame(id:id,ordinal:ordinal)
            },export:{[unowned self] draft,_,_,permit,progress in
                self.exports+=1;self.exportedDraft=draft;self.lastPermit=permit
                try await progress(.init(phase:.narrating,step:1,totalSteps:draft.steps.count))
                if self.commitBeforeGate {try permit.beginCommit()}
                if self.holdExport {await withCheckedContinuation {self.exportGate=$0}}
                if !self.commitBeforeGate {try permit.check()}
                return .init(formatVersion:1,createdAt:"owned",sourceSchema:MemoryStore.schemaVersion,draftRevision:try draft.revision,steps:draft.steps.count,duration:1,movieSHA256:String(repeating:"a",count:64),plaintextIndependentCopy:true)
            })
            env.locked={[unowned self] in self.locked}
            return WorkflowModel(store:store,settings:settings,environment:env)
        })
        app.showOnboarding=false;model=app.workflow;model.helperPath="/usr/bin/true"
        try await SourceWorkTestJob.settle(app)
    }
    override func tearDown()async throws {
        await queryGate?.open();queryGate=nil
        previewGate?.resume();previewGate=nil;exportGate?.resume();exportGate=nil
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();try? FileManager.default.removeItem(at:root)
        app=nil;model=nil
    }
    func frame(id:String,ordinal:Int=0)->WorkflowEditorFrame {
        let hash=String(repeating:"a",count:64)
        return .init(source:.init(library:hash,memoryID:id,revision:hash,mediaSHA256:hash,kind:.video,frameOrdinal:ordinal,frameTime:Double(ordinal)),title:"Owned screen "+id,app:"Owned editor",timestamp:Date(timeIntervalSince1970:100),png:Data(),choices:[.init(ordinal:0,time:0),.init(ordinal:1,time:1)])
    }
    func wait(_ condition:@escaping ()->Bool)async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(5));while !condition(),ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(2))};XCTAssertTrue(condition())
    }
    func add(_ id:String="owned-screen")async throws {model.add(memoryID:id);try await wait {[self] in !model.busy}}
    func ready()async throws {try await add();model.edit(try XCTUnwrap(model.steps.first?.id),narration:"Review the owned screen.");XCTAssertTrue(model.canExport)}
    func testExplicitSourceEditingFrameSelectionAndOrderNeverStartNarrationOrWriteHistory()async throws {
        XCTAssertEqual(previews,0);XCTAssertEqual(exports,0);try await ready();let first=try XCTUnwrap(model.steps.first?.id)
        model.edit(first,title:"Edited title",narration:"Edited exact words.");model.selectFrame(stepID:first,ordinal:1);try await wait {[self] in !model.busy}
        XCTAssertEqual(model.steps.first?.step.source.frameOrdinal,1);XCTAssertEqual(model.steps.first?.step.title,"Edited title");XCTAssertEqual(model.steps.first?.step.narration,"Edited exact words.")
        try await add("second");let second=try XCTUnwrap(model.steps.last?.id);model.move(second,by:-1);XCTAssertEqual(model.steps.first?.id,second);model.remove(first)
        XCTAssertEqual(model.steps.count,1);XCTAssertEqual(exports,0);XCTAssertEqual(try app.store.stats().count,0);XCTAssertFalse(app.capture.running)
    }
    func testOpenSourceLoadsCurrentCompleteHistoryWithoutNarration()async throws {
        let text=String(repeating:"Owned complete source. ",count:300)
        try app.store.insert(Memory(id:"owned-source-open",title:"Owned source",text:text));try await add("owned-source-open")
        app.openWorkflowSource(try XCTUnwrap(model.steps.first?.step.source));try await wait {[self] in app.selected != nil && app.openingMemoryID==nil}
        XCTAssertEqual(app.selected?.id,"owned-source-open");XCTAssertEqual(app.selected?.text,text);XCTAssertEqual(exports,0)
        app.selected=nil;app.prepareForLibrarySwitch();app.openWorkflowSource(frame(id:"owned-source-open").source);XCTAssertNil(app.openingMemoryID)
    }
    func testEightStepBoundAndInvalidScriptsDisableExport()async throws {
        for index in 0..<9 {try await add("owned-\(index)")};XCTAssertEqual(previews,8);XCTAssertEqual(model.steps.count,8);XCTAssertFalse(model.canExport)
        for item in model.steps {model.edit(item.id,narration:"Owned narration.")};XCTAssertTrue(model.canExport)
        model.title="";XCTAssertFalse(model.canExport);model.title="Owned";model.edit(model.steps[0].id,narration:String(repeating:"a",count:4001));XCTAssertFalse(model.canExport)
    }
    func testMissingHelperLockedAndRetiredLibraryCannotStartWork()async throws {
        try await ready();model.helperPath="/owned-missing-kokoro";XCTAssertFalse(model.canExport);model.export(to:root.appendingPathComponent("Never"));XCTAssertEqual(exports,0)
        model.helperPath="/usr/bin/true";locked=true;model.add(memoryID:"blocked");XCTAssertFalse(model.busy);XCTAssertFalse(model.canExport)
        locked=false;app.prepareForLibrarySwitch();model.add(memoryID:"retired");XCTAssertFalse(model.busy);XCTAssertTrue(model.steps.isEmpty)
    }
    func testCancelledNoncooperativePreviewStaysBusyAndDropsLatePixels()async throws {
        holdPreview=true;model.add(memoryID:"held");try await wait {[self] in previewGate != nil};model.cancel(clear:true)
        XCTAssertTrue(model.busy);XCTAssertTrue(app.hasPendingExitWork);model.add(memoryID:"overlap");XCTAssertEqual(previews,1)
        var joined=false;let drain=Task {await self.model.cancelAndWait();joined=true};await Task.yield();XCTAssertFalse(joined)
        previewGate?.resume();previewGate=nil;await drain.value;XCTAssertFalse(model.busy);XCTAssertTrue(model.steps.isEmpty);XCTAssertFalse(app.hasPendingExitWork)
    }
    func testPrivacyChangeClearsDraftAndRejectsLatePreview()async throws {
        try await ready();holdPreview=true;model.add(memoryID:"held");try await wait {[self] in previewGate != nil}
        var changed=app.settings;changed.privacy.retainImages=false;app.settings=changed
        XCTAssertTrue(model.steps.isEmpty);XCTAssertTrue(model.busy);previewGate?.resume();previewGate=nil;try await wait {[self] in !model.busy};XCTAssertTrue(model.steps.isEmpty);XCTAssertEqual(exports,0)
    }
    func testExportSnapshotIsImmutableAndCancellationRevokesBeforeCommit()async throws {
        try await ready();let original=model.draft;holdExport=true;model.export(to:root.appendingPathComponent("OwnedOutput"));try await wait {[self] in exportGate != nil}
        XCTAssertTrue(model.status.contains("step 1 of 1"));model.edit(model.steps[0].id,narration:"Cannot edit while rendering");model.move(model.steps[0].id,by:1)
        XCTAssertEqual(exportedDraft,original);XCTAssertEqual(model.draft,original);XCTAssertTrue(app.hasPendingExitWork)
        model.cancel();XCTAssertFalse(try XCTUnwrap(lastPermit).canCancel);XCTAssertTrue(model.busy);exportGate?.resume();exportGate=nil;try await wait {[self] in !model.busy};XCTAssertNil(model.completedURL);XCTAssertTrue(model.status.contains("cancelled"))
    }
    func testAlreadyPublishedExportIsReportedAfterLateCancellation()async throws {
        try await ready();holdExport=true;commitBeforeGate=true;let destination=root.appendingPathComponent("OwnedOutput")
        model.export(to:destination);try await wait {[self] in exportGate != nil};model.cancel();exportGate?.resume();exportGate=nil;try await wait {[self] in !model.busy}
        XCTAssertEqual(model.completedURL,destination);XCTAssertEqual(model.completedDuration,1);XCTAssertTrue(model.status.contains("Exported 1 steps"))
    }
    func testPauseCancelsActiveWorkAndLaterExplicitPreviewDoesNotResumeCapture()async throws {
        holdPreview=true;model.add(memoryID:"held");try await wait {[self] in previewGate != nil};app.pauseAll();XCTAssertTrue(model.busy);previewGate?.resume();previewGate=nil;try await wait {[self] in !model.busy}
        holdPreview=false;try await add("after-pause");XCTAssertEqual(model.steps.count,1);XCTAssertFalse(app.capture.running);XCTAssertFalse(app.audio.running)
    }
    func testDeletionDrainsPreviewBeforeErasingSource()async throws {
        let memory=Memory(id:"owned-deletion",text:"Owned deletion sentinel");try app.store.insert(memory)
        holdPreview=true;model.add(memoryID:memory.id);try await wait {[self] in previewGate != nil};app.delete(memory);await Task.yield()
        XCTAssertNotNil(try app.store.get(memory.id));XCTAssertTrue(model.busy)
        previewGate?.resume();previewGate=nil;try await wait {[self] in app.deletingID==nil};XCTAssertNil(try app.store.get(memory.id));XCTAssertTrue(model.steps.isEmpty)
    }
    func testLibraryErasureJoinsActualPreviewBeforeDeletingHistory()async throws {
        try app.store.insert(Memory(id:"owned-wipe",text:"Owned erasure sentinel"))
        holdPreview=true;model.add(memoryID:"held");try await wait {[self] in previewGate != nil};app.wipeLocalLibrary();await Task.yield()
        XCTAssertTrue(app.libraryWipe.busy);XCTAssertNotNil(try app.store.get("owned-wipe"));XCTAssertTrue(model.busy)
        previewGate?.resume();previewGate=nil;try await wait {[self] in !app.libraryWipe.busy};XCTAssertNil(app.libraryWipe.error);XCTAssertNil(try app.store.get("owned-wipe"));XCTAssertTrue(model.steps.isEmpty)
    }
    func testRootReplacementDuringPreviewRejectsLateResult()async throws {
        holdPreview=true;model.add(memoryID:"held");try await wait {[self] in previewGate != nil}
        let moved=root.appendingPathExtension("moved");try FileManager.default.moveItem(at:root,to:moved);defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.moveItem(at:moved,to:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);previewGate?.resume();previewGate=nil;try await wait {[self] in !model.busy}
        XCTAssertTrue(model.steps.isEmpty);XCTAssertTrue(model.status.contains("changed"))
    }
    func plainSession()async throws->AppSession {
        let session=AppSession(selection:.init(url:root.appendingPathComponent("bootstrap"),requiresExisting:false,origin:"owned workflow session"),defaults:UserDefaults(suiteName:"oswind-owned-workflow-session-"+UUID().uuidString)!,locked:{false})
        try await wait {session.model != nil && !session.busy}
        if let initial=session.model {initial.prepareForLibrarySwitch();await initial.cancelExternalWorkAndWait();try initial.store.close()}
        session.model=app;return session
    }
    func testPlainQuitJoinsActualExportBeforeTermination()async throws {
        let previous=AppSession.current;defer {AppSession.current=previous};let session=try await plainSession()
        try await ready();holdExport=true;model.export(to:root.appendingPathComponent("OwnedOutput"));try await wait {[self] in exportGate != nil}
        let delegate=AppDelegate();var exits=0;delegate.finishTermination={_ in exits+=1}
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
        try await wait {[self] in model.status.contains("Cancelling")};XCTAssertEqual(exits,0);XCTAssertFalse(app.store.isClosed);XCTAssertTrue(model.busy)
        exportGate?.resume();exportGate=nil;try await wait {exits==1};XCTAssertFalse(app.hasPendingExitWork);XCTAssertNil(model.completedURL)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateNow);session.model=nil
    }
    func testLibrarySwitchJoinsPreviewBeforeClosingSQLite()async throws {
        let previous=AppSession.current;defer {AppSession.current=previous};let session=try await plainSession()
        holdPreview=true;model.add(memoryID:"held");try await wait {[self] in previewGate != nil}
        let destination=root.appendingPathExtension("next"),other=try MemoryStore(root:destination);try other.close();defer {try? FileManager.default.removeItem(at:destination)}
        session.open(destination,persist:false);try await wait {session.busy && session.model==nil};XCTAssertFalse(app.store.isClosed);XCTAssertTrue(model.busy)
        previewGate?.resume();previewGate=nil;try await wait {!session.busy};XCTAssertNil(session.failure);XCTAssertTrue(app.store.isClosed);XCTAssertTrue(model.steps.isEmpty)
        let next=try XCTUnwrap(session.model);next.prepareForLibrarySwitch();await next.cancelExternalWorkAndWait();try next.store.close();session.model=nil
    }
    func testCompletedWorkflowPreviewStillOwnsExitForActualHeldQuery()async throws {
        let gate=AudioImportGate();queryGate=gate
        let returned=expectation(description:"Independent actual query returned")
        app.searchWorkObserver={if $0 == .query {await gate.wait()}}
        app.searchWorkCompleted={if $0 == .query {returned.fulfill()}}
        app.query="Owned";app.refresh();await fulfillment(of:[gate.entered],timeout:5)
        try await ready();XCTAssertFalse(model.busy);XCTAssertTrue(app.hasPendingExitWork)
        model.cancel(clear:true);await model.cancelAndWait()
        XCTAssertTrue(app.hasPendingExitWork,"Finishing a preview must not acknowledge an independent actual query")
        var finished=false;let drain=Task {await self.app.cancelExternalWorkAndWait();finished=true}
        await fulfillment(of:[gate.cancelled],timeout:5);try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(finished)
        await gate.open();await fulfillment(of:[returned],timeout:5);await drain.value
        XCTAssertFalse(app.hasPendingExitWork);XCTAssertTrue(model.steps.isEmpty);XCTAssertEqual(exports,0)
    }
}
