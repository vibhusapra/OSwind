import XCTest
import CSQLite
@testable import OSwindCore

final class RecapTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    @discardableResult func source(_ id:String="source") throws -> Memory {let m=Memory(id:id,timestamp:Date(timeIntervalSince1970:100),app:"Safari",title:"Owner",text:"Maya owns release. Friday deadline.");try store.insert(m);return m}
    func answer(_ source:Memory) -> Answer {.init(text:"Maya owns release [1].",sources:[.init(memory:source,score:1,match:"fixture")],provider:"fixture",duration:0)}
    func testSpecificConversationTurnCanBeSavedBeyondRecentThousand() throws {
        let parent=try source(),chat=try store.createChat(),first=try store.appendChatTurn(sessionID:chat.id,question:"Old release?",answer:answer(parent))
        for i in 0..<1001 {_ = try store.appendChatTurn(sessionID:chat.id,question:"Later \(i)?",answer:answer(parent))}
        XCTAssertFalse(try store.chatTurns(chat.id,limit:1000).contains {$0.id==first.id})
        let recap=try store.saveChatRecap(sessionID:chat.id,turnID:first.id)
        XCTAssertEqual(recap.recap?.sources.first?.id,parent.id)
        XCTAssertThrowsError(try store.saveChatRecap(sessionID:chat.id,turnID:"missing"))
    }
    func testSavedRecapPersistsOrderedAnchorsWithoutCopyingSourceBodies() throws {
        let parent=try source();var a=answer(parent);a.sources[0].passage=PassageRange(start:0,length:4)
        let recap=try store.saveRecap(a);XCTAssertEqual(recap.kind,.summary);XCTAssertEqual(recap.recap?.sources[0].revision,parent.evidenceHash)
        store=nil;store=try MemoryStore(root:root);let refs=try store.recapEvidence(recap.id);XCTAssertEqual(refs.map(\.id),[parent.id]);XCTAssertEqual(refs[0].passage,a.sources[0].passage)
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(recap.recap),as:UTF8.self).contains(parent.text))
    }
    func testSourceDeletionRemovesTransitiveRecapsAndCitedTurnsAndCountsThem() throws {
        let parent=try source(),first=try store.saveRecap(answer(parent)),second=try store.saveRecap(answer(first)),other=try source("unrelated"),chat=try store.createChat()
        _=try store.appendChatTurn(sessionID:chat.id,question:"Recap?",answer:answer(second))
        let result=try store.delete(parent.id);XCTAssertEqual(result.sources,3);XCTAssertEqual(result.conversationTurns,1)
        XCTAssertNil(try store.get(first.id));XCTAssertNil(try store.get(second.id));XCTAssertNotNil(try store.get(other.id));XCTAssertTrue(try store.chatTurns(chat.id).isEmpty)
    }
    func testDeletingRecapKeepsOriginalAndOtherBranches() throws {
        let parent=try source(),first=try store.saveRecap(answer(parent)),other=try store.saveRecap(answer(parent)),child=try store.saveRecap(answer(first))
        XCTAssertEqual(try store.delete(first.id).sources,2);XCTAssertNotNil(try store.get(parent.id));XCTAssertNotNil(try store.get(other.id));XCTAssertNil(try store.get(child.id))
    }
    func testSourceRevisionInvalidatesRecapsButFavoriteAndTagsDoNot() throws {
        var parent=try source();let recap=try store.saveRecap(answer(parent));try store.setFavorite(parent.id,value:true);try store.setTags(parent.id,tags:["tag"]);XCTAssertNotNil(try store.get(recap.id))
        let index=root.appendingPathComponent("indexes");try Paths.ensure(index);try Data([1]).write(to:index.appendingPathComponent("private-cache"))
        parent.title="Changed owner";try store.insert(parent);XCTAssertNil(try store.get(recap.id));XCTAssertFalse(FileManager.default.fileExists(atPath:index.path))
    }
    func testTypedSpeakerChangeInvalidatesLinkedRecaps() throws {
        let transcript=SpeechTranscript(text:"Owner",duration:1,segments:[TranscriptSegment(start:0,end:1,text:"Owner",speaker:"Speaker 1")],model:"fixture")
        var parent=Memory(id:"audio",kind:.audio,text:transcript.text);parent.transcript=transcript;try store.insert(parent);let recap=try store.saveRecap(answer(parent))
        _=try store.renameAudioSpeaker(parent.id,from:"Speaker 1",to:"Maya");XCTAssertNil(try store.get(recap.id))
    }
    func testStaleMissingPreviewAndSourcelessAnswersCannotSave() throws {
        var parent=try source();let old=answer(parent);parent.text="Changed";try store.insert(parent);XCTAssertThrowsError(try store.saveRecap(old))
        try store.delete(parent.id);XCTAssertThrowsError(try store.saveRecap(answer(parent)))
        XCTAssertThrowsError(try store.saveRecap(.init(text:"No evidence",sources:[],provider:"fixture",duration:0)))
    }
    func testSavingRechecksCurrentPrivacyExclusion() throws {
        var parent=try source();parent.bundleID="com.oswind.fixture.private";try store.insert(parent)
        var policy=PrivacyPolicy();policy.excludedApps=[parent.bundleID]
        XCTAssertThrowsError(try store.saveRecap(answer(parent),policy:policy))
        XCTAssertEqual(try store.stats().count,1)
    }
    func testLinkedMetadataCannotBeDetachedOrMutated() throws {
        let parent=try source();var recap=try store.saveRecap(answer(parent));recap.recap=nil;XCTAssertThrowsError(try store.insert(recap));XCTAssertNotNil(try store.get(recap.id)?.recap)
        recap=try XCTUnwrap(store.get(recap.id));recap.recap!.provider="other";XCTAssertThrowsError(try store.insert(recap))
    }
    func testCycleIsRejectedAndSourceTableUnchanged() throws {
        var parent=try source(),first=try store.saveRecap(answer(parent));parent.kind = .summary;parent.recap = .init(provider:"fixture",sources:[.init(id:first.id,revision:first.evidenceHash,match:"fixture",score:1)])
        XCTAssertThrowsError(try store.insert(parent));XCTAssertEqual(try store.get(parent.id)?.kind,.screen);XCTAssertNotNil(try store.get(first.id))
        first.recap!.sources[0].score = .infinity;XCTAssertThrowsError(try store.insert(first))
    }
    func testScopedPreviewIncludesRecapsOutsideAppAndDeletesWholeClosure() throws {
        let parent=try source(),first=try store.saveRecap(answer(parent)),second=try store.saveRecap(answer(first));let preview=try store.previewErasure(.init(app:"Safari"))
        XCTAssertEqual(preview.matchedSources,1);XCTAssertEqual(preview.linkedRecaps,2);XCTAssertEqual(preview.sources,3)
        XCTAssertEqual(try store.eraseHistory(preview.scope,expectedToken:preview.token).sources,3);XCTAssertNil(try store.get(second.id))
    }
    func testRetentionCountsFutureDatedDependentRecaps() throws {
        let parent=try source(),recap=try store.saveRecap(answer(parent));XCTAssertEqual(try store.prune(before:Date(timeIntervalSince1970:200)),2);XCTAssertNil(try store.get(recap.id))
    }
    func testJSONReversedOrderPreservesLinksAndDeletion() throws {
        let parent=try source(),first=try store.saveRecap(answer(parent)),second=try store.saveRecap(answer(first)),file=root.appendingPathComponent("input.json")
        try JSONEncoder().encode([second,first,parent]).write(to:file)
        let other=try MemoryStore(root:root.appendingPathComponent("other"));XCTAssertEqual(try other.importJSONDetailed(from:file).imported,3)
        XCTAssertEqual(try other.recapEvidence(second.id).first?.id,first.id);XCTAssertEqual(try other.delete(parent.id).sources,3)
    }
    func testJSONPrivacyExclusionAndRedactionOmitDependentRecaps() throws {
        var parent=try source();parent.bundleID="com.private";parent.text="password=privateValue";try store.insert(parent)
        let first=try store.saveRecap(answer(parent)),second=try store.saveRecap(answer(first)),file=root.appendingPathComponent("input.json");try JSONEncoder().encode([second,first,parent]).write(to:file)
        let hidden=try MemoryStore(root:root.appendingPathComponent("hidden"));var policy=PrivacyPolicy();policy.excludedApps=["com.private"]
        let a=try hidden.importJSONDetailed(from:file,policy:policy);XCTAssertEqual(a.imported,0);XCTAssertEqual(a.excluded,1);XCTAssertEqual(a.skippedLinkedRecaps,2)
        let redacted=try MemoryStore(root:root.appendingPathComponent("redacted"));let b=try redacted.importJSONDetailed(from:file);XCTAssertEqual(b.imported,1);XCTAssertEqual(b.skippedLinkedRecaps,2);XCTAssertEqual(try redacted.get(parent.id)?.text,"[REDACTED]")
    }
    func testIncompleteLinkedJSONFailsAtomicallyWithoutCreatingAnIndependentCopy() throws {
        let recap=try store.saveRecap(answer(source())),file=root.appendingPathComponent("input.json");try JSONEncoder().encode([Memory(id:"plain",text:"keep only on success"),recap]).write(to:file)
        let other=try MemoryStore(root:root.appendingPathComponent("other"));XCTAssertThrowsError(try other.importJSONDetailed(from:file));XCTAssertEqual(try other.stats().count,0)
    }
    func testFullBackupRestoresLinksRegardlessOfRecordOrder() throws {
        let parent=try source(),first=try store.saveRecap(answer(parent)),second=try store.saveRecap(answer(first)),work=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Paths.ensure(work);defer {try? FileManager.default.removeItem(at:work)}
        let archive=work.appendingPathComponent("copy.oswindbackup"),destination=work.appendingPathComponent("restored")
        _ = try LibraryBackup.create(store:store,destination:archive);_ = try LibraryBackup.restore(archive,to:destination)
        let restored=try MemoryStore(root:destination);XCTAssertEqual(try restored.recapEvidence(second.id).first?.id,first.id);XCTAssertEqual(try restored.delete(parent.id).sources,3)
    }

    func testMarkdownLinksAndHiddenParentPropagationIgnorePhysicalRecordOrder() throws {
        let parent=try source(),first=try store.saveRecap(answer(parent)),second=try store.saveRecap(answer(first)),work=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Paths.ensure(work);defer {try? FileManager.default.removeItem(at:work)}
        try store.withRoutineDatabase {try $0.execute("UPDATE memories SET rowid=rowid+10000 WHERE id='source'")}
        let output=work.appendingPathComponent("allowed"),info=try MarkdownExport.create(store:store,destination:output,policy:PrivacyPolicy());XCTAssertEqual(info.memories,3)
        let files=try FileManager.default.contentsOfDirectory(at:output.appendingPathComponent("sources"),includingPropertiesForKeys:nil)
        var linkCount=0
        for file in files {
            let text=try String(contentsOf:file,encoding:.utf8),regex=try NSRegularExpression(pattern:"\\]\\((\\.\\./sources/[^)]+)\\)")
            for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) {let relative=(text as NSString).substring(with:match.range(at:1));XCTAssertTrue(FileManager.default.fileExists(atPath:URL(fileURLWithPath:relative,relativeTo:file.deletingLastPathComponent()).standardizedFileURL.path));linkCount+=1}
        }
        XCTAssertEqual(linkCount,2)
        var hidden=PrivacyPolicy();hidden.excludedTitles=["Owner"]
        let blocked=try MarkdownExport.create(store:store,destination:work.appendingPathComponent("hidden"),policy:hidden);XCTAssertEqual(blocked.memories,0);XCTAssertEqual(blocked.excludedMemories,3)
        XCTAssertNotNil(try store.get(first.id));XCTAssertNotNil(try store.get(second.id))
    }
    func testMarkdownRedactionOmitsDerivedTextAndCitedTurns() throws {
        var parent=try source();parent.text="password=privateValue";try store.insert(parent)
        let first=try store.saveRecap(answer(parent)),chat=try store.createChat();_=try store.appendChatTurn(sessionID:chat.id,question:"Sensitive recap?",answer:answer(first))
        let work=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString);try Paths.ensure(work);defer {try? FileManager.default.removeItem(at:work)}
        let info=try MarkdownExport.create(store:store,destination:work.appendingPathComponent("copy"),policy:PrivacyPolicy());XCTAssertEqual(info.memories,1);XCTAssertEqual(info.excludedMemories,1);XCTAssertEqual(info.excludedTurns,1)
    }

    func testLongChainErasureDoesNotDependOnRecursiveTriggerDepth() throws {
        let parent=try source();var previous=parent
        for _ in 0..<110 {previous=try store.saveRecap(answer(previous))}
        XCTAssertEqual(try store.delete(parent.id).sources,111);XCTAssertEqual(try store.stats().count,0)
    }
    func testLegacyIndependentSummaryRemainsIndependent() throws {
        let parent=try source(),copy=Memory(id:"legacy",kind:.summary,app:"OSwind",text:"Maya owns release [1].")
        try store.insert(copy);try store.delete(parent.id);XCTAssertNil(try store.get(copy.id)?.recap);XCTAssertNotNil(try store.get(copy.id))
    }
    func testVisualMetadataRevisionInvalidatesRecapWithUnchangedText() throws {
        var visual=VisualRecording(duration:1,width:320,height:180,codec:"h264",hardwareRequired:false,frames:[VisualFrame(time:0,text:"owned")])
        var parent=Memory(id:"visual",text:visual.text);parent.visualRecording=visual;try store.insert(parent);let recap=try store.saveRecap(answer(parent))
        visual.duration=2;parent.visualRecording=visual;try store.insert(parent);XCTAssertNil(try store.get(recap.id))
    }
    func testCancelledSaveRollsBackBeforePublication() async throws {
        let parent=try source(),local=store!,result=answer(parent)
        let worker=Task.detached {withUnsafeCurrentTask {$0?.cancel()};return try local.saveRecap(result)}
        do {_=try await worker.value;XCTFail("Cancelled save succeeded")} catch is CancellationError {} catch {XCTFail("Wrong error \(error)")}
        XCTAssertEqual(try store.stats().count,1)
    }

}
