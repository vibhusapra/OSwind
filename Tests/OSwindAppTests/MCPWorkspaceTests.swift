import XCTest
import Foundation
import AppKit
@testable import OSwind
@testable import OSwindCore

final class MCPAdmissionBarrier:@unchecked Sendable {
    private let condition=NSCondition();private var entered=false,released=false
    var waiting:Bool {condition.lock();defer {condition.unlock()};return entered}
    func hold()throws {
        condition.lock();defer {condition.unlock()};entered=true;condition.broadcast()
        let until=Date().addingTimeInterval(20)
        while !released {guard condition.wait(until:until) else {throw OSwindError.unavailable("Owned result barrier expired")}}
    }
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
}
@MainActor final class MCPWorkspaceTests:XCTestCase {
    var root:URL!,app:AppModel!,profile:MCPConnectionProfile!,probe:MCPUIProbe!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("oswind-owned-mcp-workspace-"+UUID().uuidString);profile = .init(name:"Owned research",command:.init(executable:"/usr/bin/false"));probe=MCPUIProbe();try install()
    }
    override func tearDown()async throws {
        if let app {app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close()}
        try? FileManager.default.removeItem(at:root);app=nil
    }
    func install(callGate:MCPUIGate?=nil)throws {
        let tool=try MCPReviewedTool(MCPValue.decode(Data(#"{"name":"owned_echo","inputSchema":{"type":"object"}}"#.utf8))),review=MCPToolReview(commandFingerprint:String(repeating:"a",count:64),protocolVersion:"2026-07-28",tools:[tool]),probe=self.probe!
        let output=MCPToolOutput(tool:tool.name,protocolVersion:review.protocolVersion,commandFingerprint:review.commandFingerprint,toolFingerprint:tool.fingerprint,argumentsFingerprint:String(repeating:"c",count:64),resultJSON:Data("{}".utf8),text:"Marigold release belongs to Mira. password=owned-only-secret",isError:false,completedAt:"2026-11-01T06:00:00Z")
        let runner=MCPClientRunner(discover:{_,credentials in probe.discovery(credentials);return review},call:{_,credentials,_,_,args in probe.call(credentials,args);if let callGate {await callGate.wait()};return output})
        app=try AppModel(root:root,startServices:false,toolsSetup:{store,settings in MCPToolsModel(store:store,settings:settings,runner:runner,locked:{false},readCredential:{_ in XCTFail("No credentials configured for this fixture");return nil},writeCredential:{_,_ in XCTFail("No real credential writes in workspace checks")})});app.showOnboarding=false;app.settings.mcpConnections=[profile]
    }
    func wait(_ body:@escaping @MainActor ()->Bool)async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(8));while !body() {guard ContinuousClock.now<end else {XCTFail("Owned workspace operation did not settle");return};try await Task.sleep(for:.milliseconds(10))}
    }
    func prepareCall()async throws {
        let model=app.tools;model.requestDiscovery();model.confirm(try XCTUnwrap(model.pendingReview).id);try await wait {[self] in !app.tools.busy};XCTAssertNotNil(model.catalog);model.chooseTool("owned_echo");model.requestCall();model.confirm(try XCTUnwrap(model.pendingReview).id)
    }
    func completedCall()async throws {try await prepareCall();try await wait {[self] in !app.tools.busy};XCTAssertNotNil(app.tools.result)}
    func testSavingVisibleTextUsesActualPrivacyAdmissionAndBecomesSearchable()async throws {
        try await completedCall();XCTAssertEqual(try app.store.stats().count,0);app.tools.saveResultText();try await wait {[self] in !app.tools.busy}
        let id=try XCTUnwrap(app.tools.savedSourceID),saved=try XCTUnwrap(app.store.get(id));XCTAssertEqual(saved.bundleID,"org.oswind.mcp");XCTAssertTrue(saved.text.contains("Marigold release"));XCTAssertFalse(saved.text.contains("owned-only-secret"));XCTAssertTrue(saved.text.contains("[REDACTED]"));XCTAssertTrue(saved.text.contains("Unverified external MCP"))
        let hits=try app.store.search(SearchFilter(query:"Marigold"));XCTAssertTrue(hits.contains {$0.memory.id==id})
        app.openMCPSource(id);try await wait {[self] in app.openingMemoryID==nil};XCTAssertEqual(app.selected?.id,id)
    }
    func testPrivacyChangeDuringPreparationCancelsBeforeSourcePublication()async throws {
        try await completedCall();let visible=try XCTUnwrap(app.tools.result),draft=try MCPResultSourceDraft(profile:visible.profile,callID:visible.callID,output:visible.output),barrier=MCPAdmissionBarrier();defer {barrier.release()}
        app.tools.saveSource={[unowned self] draft in try await self.app.saveMCPResult(draft,observeWorker:{phase in if case .settingsCaptured=phase {try barrier.hold()}})}
        app.tools.saveResultText();try await wait {barrier.waiting};app.settings.privacy.excludedApps.append("org.oswind.mcp");barrier.release();try await wait {[self] in !app.tools.busy}
        XCTAssertNil(try app.store.get(draft.sourceID));XCTAssertNil(app.tools.result);XCTAssertNil(app.tools.savedSourceID)
    }
    func testGlobalPauseStopsToolOnlyWorkWithoutStartingScreenCapture()async throws {
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();let gate=MCPUIGate();defer {Task {await gate.release()}};try install(callGate:gate);try await prepareCall();try await wait {[self] in probe.calls==1}
        XCTAssertFalse(app.isCapturing);XCTAssertFalse(app.isCollecting);XCTAssertTrue(app.hasPausableWork);app.toggleCapture();XCTAssertTrue(app.tools.stopping);XCTAssertFalse(app.capture.running)
        await gate.release();try await wait {[self] in !app.tools.busy};XCTAssertNil(app.tools.result);XCTAssertEqual(probe.calls,1);XCTAssertFalse(app.capture.running)
    }
    func testLibraryDepartureJoinsToolWorkerBeforeReturning()async throws {
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();let gate=MCPUIGate();defer {Task {await gate.release()}};try install(callGate:gate);try await prepareCall();try await wait {[self] in probe.calls==1}
        app.prepareForLibrarySwitch();var drained=false;let waiter=Task {await app.cancelExternalWorkAndWait();drained=true};try await Task.sleep(for:.milliseconds(25));XCTAssertFalse(drained);XCTAssertFalse(app.store.isClosed)
        await gate.release();await waiter.value;XCTAssertTrue(drained);try app.store.close();XCTAssertTrue(app.store.isClosed);XCTAssertNil(app.tools.result)
    }
    func testOnboardingAndRetiredLibraryCannotLaunchOrSaveTools()async throws {
        app.showOnboarding=true;app.tools.requestDiscovery();XCTAssertNil(app.tools.pendingReview);XCTAssertEqual(probe.discoveries,0)
        app.showOnboarding=false;try await completedCall();app.prepareForLibrarySwitch();app.tools.saveResultText();XCTAssertEqual(try app.store.stats().count,0);XCTAssertNil(app.tools.result)
    }
    func testToolsWorkspaceRefreshDoesNotRunUnrelatedMemorySearch()async throws {
        app.section="Tools";app.query="\"unfinished";app.refresh();try await Task.sleep(for:.milliseconds(30));XCTAssertFalse(app.refreshing);XCTAssertNil(app.searchInputError);XCTAssertEqual(probe.discoveries,0)
    }
    func testActualAppSessionSwitchWaitsForToolDrainBeforeClosingStore()async throws {
        let gate=MCPUIGate();defer {Task {await gate.release()}}
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();try install(callGate:gate)
        let session=AppSession(selection:.init(url:root,requiresExisting:true,origin:"owned MCP session test"),defaults:UserDefaults(suiteName:"oswind-owned-mcp-session-"+UUID().uuidString)!,locked:{false})
        try await wait {session.model != nil && !session.busy}
        if let initial=session.model {initial.prepareForLibrarySwitch();await initial.cancelExternalWorkAndWait();try initial.store.close()}
        session.model=app;try await prepareCall();try await wait {[self] in probe.calls==1}
        let destination=root.appendingPathExtension("destination"),other=try MemoryStore(root:destination);try other.close();defer {try? FileManager.default.removeItem(at:destination)}
        session.open(destination,persist:false);try await wait {session.busy && session.model==nil}
        XCTAssertFalse(app.store.isClosed);XCTAssertTrue(app.tools.stopping)
        await gate.release();try await wait {!session.busy};XCTAssertNil(session.failure);XCTAssertTrue(app.store.isClosed)
        let next=try XCTUnwrap(session.model);XCTAssertEqual(next.store.root.standardizedFileURL,destination.standardizedFileURL);next.prepareForLibrarySwitch();await next.cancelExternalWorkAndWait();try next.store.close();session.model=nil
    }

    func testPlainQuitDelegateWaitsForCancellationIgnoringToolBeforeFinishing()async throws {
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close()
        let gate=MCPUIGate();defer {Task {await gate.release()}};try install(callGate:gate)
        let previous=AppSession.current;defer {AppSession.current=previous}
        let session=AppSession(selection:.init(url:root,requiresExisting:true,origin:"owned MCP quit test"),defaults:UserDefaults(suiteName:"oswind-owned-mcp-quit-"+UUID().uuidString)!,locked:{false})
        try await wait {session.model != nil && !session.busy}
        if let initial=session.model {initial.prepareForLibrarySwitch();await initial.cancelExternalWorkAndWait();try initial.store.close()}
        session.model=app;try await prepareCall();try await wait {[self] in probe.calls==1}
        XCTAssertFalse(app.hasPendingJSONImport);XCTAssertTrue(app.tools.busy);XCTAssertTrue(app.hasPendingExitWork)
        let delegate=AppDelegate();var exits=0;delegate.finishTermination={_ in exits+=1}
        let reply=delegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(reply,.terminateCancel,"Plain-library quit must join the actual MCP worker")
        guard reply == .terminateCancel else {await gate.release();await app.tools.cancelAndWait();session.model=nil;return}
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
        try await wait {[self] in app.tools.stopping};XCTAssertEqual(exits,0);XCTAssertFalse(app.store.isClosed)
        await gate.release();try await wait {exits==1}
        XCTAssertFalse(app.tools.busy);XCTAssertFalse(app.hasPendingExitWork);XCTAssertNil(app.tools.result);XCTAssertEqual(probe.calls,1)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateNow);XCTAssertEqual(exits,1)
        session.model=nil
    }

}
