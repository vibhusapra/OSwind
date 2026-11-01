import XCTest
@testable import OSwindCore

final class MeetingEvidencePolicyTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-meeting-evidence-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func testMeetingContextExcludesCurrentPrivateSourcesAndDerivedSummariesBeforePromptAssembly()async throws {
        let secret="sk-"+String(repeating:"A",count:32)
        let allowed=Memory(id:"allowed",kind:.note,app:"Owned",bundleID:"org.oswind.owned",title:"Orion "+secret,text:"Orion release owner is Mira. "+secret)
        let blocked=Memory(id:"blocked",kind:.note,bundleID:"org.oswind.private",title:"Orion confidential",text:"Orion hidden project detail")
        let domain=Memory(id:"domain",kind:.screen,bundleID:"org.oswind.browser",title:"Orion web",url:"https://private.example/owned",text:"Orion hidden website detail")
        let title=Memory(id:"title",kind:.note,title:"Orion DoNotUse",text:"Orion hidden title detail")
        let legacy=Memory(id:"legacy",kind:.summary,title:"Orion legacy recap",text:"Orion hidden unlinked summary")
        for value in [allowed,blocked,domain,title,legacy] {try store.insert(value)}
        _=try store.saveRecap(.init(text:"Orion hidden derived detail [1]",sources:[.init(memory:blocked,score:1,match:"owned")],provider:"evidence",duration:0))
        var policy=PrivacyPolicy();policy.excludedApps.append(blocked.bundleID);policy.excludedDomains.append("private.example");policy.excludedTitles.append("DoNotUse")
        var config=AIConfiguration();config.provider = .evidence
        let result=try await AnswerEngine(store:store,embedder:LocalEmbedder()).answer("Orion meeting",configuration:config,summarize:true,interpretQuery:false,evidencePolicy:policy)
        XCTAssertEqual(result.sources.map(\.id),[allowed.id]);XCTAssertFalse(result.text.contains(secret));XCTAssertTrue(result.text.contains("[REDACTED]"));XCTAssertFalse(result.text.contains("hidden"));XCTAssertTrue(result.text.contains("Mira"))
        XCTAssertTrue(result.warnings.contains {$0.contains("omits excluded sources")})
        XCTAssertEqual(try store.get(allowed.id)?.text,allowed.text);XCTAssertEqual(result.sources.first?.memory.evidenceHash,allowed.evidenceHash)
    }
    func testNoEligibleMeetingEvidenceReturnsWithoutCredentialOrRemoteRequest()async throws {
        try store.insert(Memory(kind:.note,bundleID:"org.oswind.private",title:"Orion",text:"Owned private detail"))
        var policy=PrivacyPolicy();policy.excludedApps.append("org.oswind.private")
        var config=AIConfiguration();config.provider = .anthropic;config.model="owned-unused";config.allowRemote=false;config.endpoint="https://unused.invalid"
        let result=try await AnswerEngine(store:store,embedder:LocalEmbedder()).answer("Orion",configuration:config,summarize:true,evidencePolicy:policy)
        XCTAssertTrue(result.sources.isEmpty);XCTAssertEqual(result.provider,"evidence");XCTAssertTrue(result.text.contains("couldn’t find recorded evidence"))
    }
}
