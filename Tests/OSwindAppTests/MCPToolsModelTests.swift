import XCTest
import Foundation
import Security
@testable import OSwind
@testable import OSwindCore

final class MCPUIProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var d=0,c=0,values=[[String:String]](),args=[Data]()
    func discovery(_ credentials:[String:String]) {lock.lock();defer {lock.unlock()};d+=1;values.append(credentials)}
    func call(_ credentials:[String:String],_ data:Data) {lock.lock();defer {lock.unlock()};c+=1;values.append(credentials);args.append(data)}
    var discoveries:Int {lock.lock();defer {lock.unlock()};return d}
    var calls:Int {lock.lock();defer {lock.unlock()};return c}
    var credentials:[[String:String]] {lock.lock();defer {lock.unlock()};return values}
    var arguments:[Data] {lock.lock();defer {lock.unlock()};return args}
}
actor MCPUIGate {
    var open=false
    var waiters=[CheckedContinuation<Void,Never>]()
    func wait()async {if open {return};await withCheckedContinuation {waiters.append($0)}}
    func release() {open=true;let pending=waiters;waiters=[];for p in pending {p.resume()}}
}

@MainActor final class MCPToolsModelTests:XCTestCase {
    var root:URL!,store:MemoryStore!,model:MCPToolsModel!,settings:AppSettings!,profile:MCPConnectionProfile!,probe:MCPUIProbe!
    var locked=false,reads=[String](),writes=[(String,String)]()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("oswind-owned-mcp-ui-"+UUID().uuidString);store=try MemoryStore(root:root)
        profile = .init(name:"Owned tools",command:.init(executable:"/usr/bin/false"));settings=AppSettings();settings.mcpConnections=[profile];probe=MCPUIProbe();try install()
    }
    override func tearDownWithError()throws {model?.suspend();try store?.close();try? FileManager.default.removeItem(at:root);model=nil;store=nil}
    func review()throws->MCPToolReview {
        let value=try MCPValue.decode(Data(#"{"name":"owned_echo","description":"Owned untrusted fixture","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}},"annotations":{"readOnlyHint":true}}"#.utf8))
        return try MCPToolReview(commandFingerprint:String(repeating:"a",count:64),protocolVersion:"2026-07-28",tools:[MCPReviewedTool(value)])
    }
    func output()->MCPToolOutput {.init(tool:"owned_echo",protocolVersion:"2026-07-28",commandFingerprint:String(repeating:"a",count:64),toolFingerprint:String(repeating:"b",count:64),argumentsFingerprint:String(repeating:"c",count:64),resultJSON:Data("{}".utf8),text:"Marigold release belongs to Mira.",isError:false,completedAt:"2026-11-01T06:00:00Z")}
    func install(discoveryGate:MCPUIGate?=nil,callGate:MCPUIGate?=nil)throws {
        let probe=self.probe!,r=try review(),out=output()
        let runner=MCPClientRunner(discover:{_,credentials in probe.discovery(credentials);if let discoveryGate {await discoveryGate.wait()};return r},call:{_,credentials,_,_,args in probe.call(credentials,args);if let callGate {await callGate.wait()};return out})
        model=MCPToolsModel(store:store,settings:settings,runner:runner,locked:{[unowned self] in self.locked},readCredential:{[unowned self] name in self.reads.append(name);return "owned-token"},writeCredential:{[unowned self] name,value in self.writes.append((name,value))})
    }
    func wait(_ body:@escaping @MainActor ()->Bool)async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(6))
        while !body() {guard ContinuousClock.now<end else {XCTFail("Owned UI fixture did not settle");return};try await Task.sleep(for:.milliseconds(10))}
    }
    func discover()async throws {model.requestDiscovery();let action=try XCTUnwrap(model.pendingReview);model.confirm(action.id);try await wait {[self] in !model.busy};XCTAssertNotNil(model.catalog)}
    func call()async throws {try await discover();model.chooseTool("owned_echo");model.argumentsText=#"{"text":"owned-only"}"#;model.requestCall();let action=try XCTUnwrap(model.pendingReview);model.confirm(action.id);try await wait {[self] in !model.busy};XCTAssertNotNil(model.result)}
    func testLoadingAndReviewingNeverLaunchesOrReadsCredentials()throws {
        XCTAssertEqual(probe.discoveries,0);XCTAssertTrue(reads.isEmpty);model.requestDiscovery();XCTAssertNotNil(model.pendingReview);XCTAssertEqual(probe.discoveries,0);XCTAssertTrue(reads.isEmpty);model.cancelReview();XCTAssertNil(model.pendingReview)
    }
    func testOnlyExplicitCurrentReviewLaunches()async throws {
        model.requestDiscovery();let old=try XCTUnwrap(model.pendingReview).id;model.requestDiscovery();model.confirm(old);XCTAssertEqual(probe.discoveries,0)
        try await discover();XCTAssertEqual(probe.discoveries,1)
    }
    func testCallUsesOnlyReviewedArgumentsAndDoesNotAutomaticallySave()async throws {
        try await call();XCTAssertEqual(probe.calls,1);XCTAssertEqual(probe.arguments,[Data(#"{"text":"owned-only"}"#.utf8)]);XCTAssertEqual(model.result?.output.text,"Marigold release belongs to Mira.");XCTAssertEqual(try store.stats().count,0)
    }
    func testMalformedArgumentsRefuseBeforeRunnerOrCredentialRead()async throws {
        try await discover();model.chooseTool("owned_echo");model.argumentsText=#"{"x":1,"x":2}"#;model.requestCall();XCTAssertNil(model.pendingReview);XCTAssertNotNil(model.error);XCTAssertEqual(probe.calls,0);XCTAssertTrue(reads.isEmpty)
    }
    func testEditingArgumentsInvalidatesCallConsent()async throws {
        try await discover();model.chooseTool("owned_echo");model.requestCall();let id=try XCTUnwrap(model.pendingReview).id;model.argumentsText=#"{"changed":true}"#;model.confirm(id);XCTAssertNil(model.pendingReview);XCTAssertEqual(probe.calls,0)
    }
    func testCanonicalEquivalentCommandEditInvalidatesReview()throws {
        settings.mcpConnections[0].command.arguments=["café"];model.apply(settings);model.requestDiscovery();let id=try XCTUnwrap(model.pendingReview).id
        settings.mcpConnections[0].command.arguments=["cafe\u{301}"];model.apply(settings);model.confirm(id);XCTAssertNil(model.pendingReview);XCTAssertEqual(probe.discoveries,0)
    }
    func testUnavailableAndLockedScopesNeverReadCredentials()throws {
        profile.command.credentialNames=["API_TOKEN"];settings.mcpConnections=[profile];model.apply(settings)
        model.allowed={false};model.requestDiscovery();XCTAssertNil(model.pendingReview)
        model.allowed={true};model.requestDiscovery();let id=try XCTUnwrap(model.pendingReview).id;locked=true;model.confirm(id);XCTAssertNil(model.pendingReview);XCTAssertEqual(probe.discoveries,0);XCTAssertTrue(reads.isEmpty)
    }
    func testCredentialsResolveOnlyThisProfileNamespaceAfterConfirmation()async throws {
        profile.command.credentialNames=["API_TOKEN"];settings.mcpConnections=[profile];model.apply(settings);model.requestDiscovery();XCTAssertTrue(reads.isEmpty)
        let id=try XCTUnwrap(model.pendingReview).id;model.confirm(id);try await wait {[self] in !model.busy};XCTAssertEqual(reads,[profile.credentialPrefix+"API_TOKEN"]);XCTAssertEqual(probe.credentials,[["API_TOKEN":"owned-token"]])
    }
    func testSavingCredentialRevokesReviewAndClearsDraft()async throws {
        profile.command.credentialNames=["API_TOKEN"];settings.mcpConnections=[profile];model.apply(settings);try await discover();model.chooseTool("owned_echo");model.requestCall();model.credentialDrafts["API_TOKEN"]="owned-new-token"
        try await model.saveCredential("API_TOKEN");XCTAssertNil(model.catalog);XCTAssertNil(model.pendingReview);XCTAssertTrue(model.credentialDrafts.isEmpty);XCTAssertEqual(writes.count,1);XCTAssertEqual(writes[0].0,profile.credentialPrefix+"API_TOKEN");XCTAssertEqual(writes[0].1,"owned-new-token")
    }
    func testSuspensionClearsPrivateStateWithoutRestart()async throws {
        try await call();model.credentialDrafts["API_TOKEN"]="owned-draft";model.showingConfiguration=true;model.suspend();XCTAssertNil(model.result);XCTAssertNil(model.catalog);XCTAssertNil(model.pendingReview);XCTAssertTrue(model.credentialDrafts.isEmpty);XCTAssertEqual(model.argumentsText,"{}");XCTAssertFalse(model.showingConfiguration);XCTAssertEqual(probe.calls,1)
    }
    func testCancelledIgnoringDiscoveryMustDrainBeforeNewWork()async throws {
        let gate=MCPUIGate();defer {Task {await gate.release()}};try install(discoveryGate:gate);model.requestDiscovery();let id=try XCTUnwrap(model.pendingReview).id;model.confirm(id);try await wait {[self] in probe.discoveries==1}
        model.suspend();XCTAssertTrue(model.busy);XCTAssertTrue(model.stopping);model.requestDiscovery();XCTAssertNil(model.pendingReview)
        await gate.release();try await wait {[self] in !model.busy};XCTAssertNil(model.catalog);XCTAssertNil(model.result);XCTAssertEqual(probe.discoveries,1)
    }
    func testPrivacyChangeDropsLateCallResult()async throws {
        let gate=MCPUIGate();defer {Task {await gate.release()}};try install(callGate:gate);try await discover();model.chooseTool("owned_echo");model.requestCall();model.confirm(try XCTUnwrap(model.pendingReview).id);try await wait {[self] in probe.calls==1}
        settings.privacy.excludedApps.append("org.oswind.mcp");model.apply(settings);await gate.release();try await wait {[self] in !model.busy};XCTAssertNil(model.result);XCTAssertNil(model.catalog)
    }
    func testCancelAndWaitJoinsActualOutstandingWork()async throws {
        let gate=MCPUIGate();defer {Task {await gate.release()}};try install(callGate:gate);try await discover();model.chooseTool("owned_echo");model.requestCall();model.confirm(try XCTUnwrap(model.pendingReview).id);try await wait {[self] in probe.calls==1}
        var finished=false;let waiter=Task {await model.cancelAndWait();finished=true};try await Task.sleep(for:.milliseconds(20));XCTAssertFalse(finished);XCTAssertTrue(model.stopping)
        await gate.release();await waiter.value;XCTAssertTrue(finished);XCTAssertFalse(model.busy);XCTAssertNil(model.result)
    }
    func testExplicitSaveUsesStableSourceAndCannotDoubleSubmit()async throws {
        try await call();var drafts=[MCPResultSourceDraft]();model.saveSource={draft in drafts.append(draft);return .init(collectorID:draft.collectorID,requested:1,imported:1,excluded:0,sourceIDs:[draft.sourceID])}
        XCTAssertTrue(drafts.isEmpty);model.saveResultText();try await wait {[self] in !model.busy};let first=try XCTUnwrap(drafts.first);XCTAssertEqual(model.savedSourceID,first.sourceID);model.saveResultText();XCTAssertEqual(drafts.count,1)
    }
    func testConfigurationAndRemovalNeverLaunchAndTouchOnlyOwnCredentialEntries()async throws {
        var saved=[[MCPConnectionProfile]]();model.saveProfiles={saved.append($0)};var p=profile!;p.command.credentialNames=["API_TOKEN"];try await model.saveProfile(p);XCTAssertEqual(saved.count,1);XCTAssertEqual(probe.discoveries,0)
        try await model.removeProfile(p.id);XCTAssertTrue(model.profiles.isEmpty);XCTAssertEqual(writes.count,1);XCTAssertEqual(writes[0].0,p.credentialPrefix+"API_TOKEN");XCTAssertEqual(writes[0].1,"")
    }
    func testUnknownCredentialNameCannotAccessAnotherAccount()async throws {
        do {try await model.removeCredential("compatible");XCTFail("Removed an unrelated account")}catch {}
        XCTAssertTrue(writes.isEmpty);XCTAssertTrue(reads.isEmpty)
    }
    func testRootReplacementRefusesBeforeCredentialsOrProcess()async throws {
        let old=root.appendingPathExtension("retired");try FileManager.default.moveItem(at:root,to:old);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.moveItem(at:old,to:root)}
        model.requestDiscovery();model.confirm(try XCTUnwrap(model.pendingReview).id);try await wait {[self] in !model.busy};XCTAssertEqual(probe.discoveries,0);XCTAssertTrue(reads.isEmpty);XCTAssertNil(model.catalog)
    }
    func testKeychainDeletionChecksStatusAndRefusesOtherCredentialNamespaces()throws {
        XCTAssertNoThrow(try MCPKeychainCredentials.validateAccount(profile.credentialPrefix+"API_TOKEN"))
        for account in ["compatible","anthropic","mcp.bad.API_TOKEN",profile.credentialPrefix+"DYLD_INSERT_LIBRARIES"] {XCTAssertThrowsError(try MCPKeychainCredentials.validateAccount(account))}
        XCTAssertNoThrow(try MCPKeychainCredentials.verifyDeletion(errSecSuccess));XCTAssertNoThrow(try MCPKeychainCredentials.verifyDeletion(errSecItemNotFound));XCTAssertThrowsError(try MCPKeychainCredentials.verifyDeletion(errSecInteractionNotAllowed))
    }
    func testFailedCredentialRemovalKeepsConnectionForRetry()async throws {
        var p=profile!;p.command.credentialNames=["API_TOKEN"];settings.mcpConnections=[p]
        let runner=MCPClientRunner(discover:{_,_ in throw OSwindError.unavailable("Should not run")},call:{_,_,_,_,_ in throw OSwindError.unavailable("Should not run")})
        model=MCPToolsModel(store:store,settings:settings,runner:runner,locked:{false},readCredential:{_ in nil},writeCredential:{_,_ in throw OSwindError.unavailable("Owned Keychain failure")})
        var saves=0;model.saveProfiles={_ in saves+=1}
        do {try await model.removeProfile(p.id);XCTFail("Forgot a connection with unremoved credentials")}catch {}
        XCTAssertEqual(model.profiles,[p]);XCTAssertEqual(saves,0)
    }

}
