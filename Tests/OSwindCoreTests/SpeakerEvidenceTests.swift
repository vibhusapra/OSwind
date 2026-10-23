import XCTest
import CSQLite
@testable import OSwindCore

final class SpeakerEvidenceTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store=try MemoryStore(root:root.appendingPathComponent("library"))
    }
    override func tearDownWithError() throws { store=nil; try? FileManager.default.removeItem(at:root) }
    func memory(_ id:String="meeting",names:[String?]=["Maya","Theo"],texts:[String]=["I own the capture tests.","I will package the archive."],time:Date=Date()) -> Memory {
        let text=texts.joined(separator:" ")
        var result=Memory(id:id,timestamp:time,kind:.audio,app:"Imported audio",title:"Fixture",text:text)
        result.transcript=SpeechTranscript(text:text,duration:Double(texts.count*3),segments:texts.enumerated().map { TranscriptSegment(start:Double($0.offset*3),end:Double($0.offset*3+2),text:$0.element,speaker:names[$0.offset]) },model:"fixture")
        return result
    }
    func sql(_ commands:String) throws {
        var db:OpaquePointer?; XCTAssertEqual(sqlite3_open(store.root.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK); defer { sqlite3_close(db) }
        guard sqlite3_exec(db,commands,nil,nil,nil)==SQLITE_OK else { throw OSwindError.database(String(cString:sqlite3_errmsg(db))) }
    }
    func testNameLookupAndExactLabelFilterPreserveRawTextAndVectors() throws {
        let source=memory(names:["Máya Chen","Theo"]); try store.insert(source)
        _ = try store.saveVectors([VectorRecord(memory:source,vector:[1,0])],modelID:"fixture")
        let result=try store.search(SearchFilter(query:"Maya",limit:10),mode:.keyword)
        XCTAssertEqual(result.map(\.id),[source.id]); XCTAssertEqual(result.first?.match,"speaker name")
        XCTAssertEqual(result.first?.memory.text,source.text)
        XCTAssertEqual(try store.search(SearchFilter(speaker:"MAYA CHEN"),mode:.keyword).map(\.id),[source.id])
        XCTAssertTrue(try store.search(SearchFilter(speaker:"Maya"),mode:.keyword).isEmpty)
        _ = try store.renameAudioSpeaker(source.id,from:"Máya Chen",to:"Avery")
        XCTAssertTrue(try store.search(SearchFilter(query:"Maya"),mode:.keyword).isEmpty)
        XCTAssertEqual(try store.search(SearchFilter(query:"Avery"),mode:.keyword).map(\.id),[source.id])
        XCTAssertEqual(try store.vectorCount(modelID:"fixture"),1)
        XCTAssertEqual(try store.get(source.id)?.contentHash,source.contentHash)
    }
    func testSpeakerScopeIntersectsAllSearchModesAndNeverMergesRecordings() throws {
        let first=memory("one"),second=memory("two",names:["Robin","Theo"])
        try store.insert(first);try store.insert(second)
        _ = try store.saveVectors([first,second].map {VectorRecord(memory:$0,vector:[1,0])},modelID:"fixture")
        for mode in SearchMode.allCases {
            let hits=try store.search(SearchFilter(query:"archive",speaker:"Maya"),mode:mode,vector:[1,0],modelID:"fixture")
            XCTAssertEqual(hits.map(\.id),["one"])
        }
        XCTAssertEqual(try store.matchingCount(SearchFilter(speaker:"Maya")),1)
        XCTAssertEqual(try store.indexCoverage(modelID:"fixture",filter:SearchFilter(speaker:"Maya")).total,1)
        XCTAssertTrue(try store.search(SearchFilter(app:"Safari",speaker:"Maya"),mode:.keyword).isEmpty)
    }
    func testDuplicateWordAndNameResultsDeduplicateAndRespectLimits() throws {
        try store.insert(memory("both",texts:["Maya owns capture.","Archive on Friday."]))
        try store.insert(memory("name"))
        let hits=try store.search(SearchFilter(query:"Maya",limit:1),mode:.keyword)
        XCTAssertEqual(hits.count,1); XCTAssertEqual(hits[0].id,"both")
        XCTAssertEqual(try store.search(SearchFilter(query:"Maya",limit:10),mode:.keyword).count,2)
    }
    func testRenameInvalidatesStoredAndInflightAnswersButFavoriteDoesNot() throws {
        let source=memory(); try store.insert(source); let chat=try store.createChat()
        let answer=Answer(text:"Maya owns capture [1].",sources:[SearchHit(memory:source,score:1,match:"keyword")],provider:"fixture",duration:0)
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Owner?",answer:answer)
        try store.setFavorite(source.id,value:true); XCTAssertEqual(try store.chatTurns(chat.id).count,1)
        let renamed=try store.renameAudioSpeaker(source.id,from:"Maya",to:"Avery")
        XCTAssertNotEqual(renamed.evidenceHash,source.evidenceHash)
        XCTAssertTrue(try store.chatTurns(chat.id).isEmpty)
        XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Stale?",answer:answer))
        XCTAssertEqual(try store.chat(chat.id)?.title,"Conversation")
        XCTAssertThrowsError(try store.renameAudioSpeaker(source.id,from:"Avery",to:"THÉO"))
        XCTAssertEqual(try store.get(source.id)?.transcript,renamed.transcript)
    }
    func testTranscriptRevisionInvalidatesAttributionEvenWithUnchangedWords() throws {
        let source=memory();try store.insert(source);let chat=try store.createChat()
        let answer=Answer(text:"Maya [1].",sources:[SearchHit(memory:source,score:1,match:"keyword")],provider:"fixture",duration:0)
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Who?",answer:answer)
        var changed=source;changed.transcript?.segments[0].speaker="Robin";try store.insert(changed)
        XCTAssertTrue(try store.chatTurns(chat.id).isEmpty)
        XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Who?",answer:answer))
        XCTAssertTrue(try store.search(SearchFilter(query:"Maya"),mode:.keyword).isEmpty)
    }
    func testProjectionFailureRollsBackSourceAndRename() throws {
        let source=memory();try store.insert(source)
        try sql("CREATE TRIGGER fail_speaker BEFORE INSERT ON audio_speakers WHEN new.label='Forbidden' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;")
        XCTAssertThrowsError(try store.renameAudioSpeaker(source.id,from:"Maya",to:"Forbidden"))
        XCTAssertEqual(try store.get(source.id)?.transcript,source.transcript)
        XCTAssertEqual(try store.search(SearchFilter(query:"Maya"),mode:.keyword).count,1)
        var bad=source; bad.transcript?.segments[0].speaker="Forbidden"
        XCTAssertThrowsError(try store.insert(bad))
        XCTAssertEqual(try store.get(source.id)?.transcript,source.transcript)
        try store.insert(memory("after"));XCTAssertEqual(try store.matchingCount(),2)
    }
    func testMigrationRestoreInterchangeAndErasureRebuildDerivedIndex() throws {
        let source=memory();try store.insert(source)
        try sql("DELETE FROM audio_speakers; PRAGMA user_version=9;")
        store=nil;store=try MemoryStore(root:root.appendingPathComponent("library"))
        XCTAssertEqual(try store.search(SearchFilter(query:"Maya"),mode:.keyword).count,1)
        let backup=root.appendingPathComponent("meeting.oswindbackup");_ = try LibraryBackup.create(store:store,destination:backup)
        let restored=root.appendingPathComponent("restored");_ = try LibraryBackup.restore(backup,to:restored)
        let restoredStore=try MemoryStore(root:restored)
        XCTAssertEqual(try restoredStore.search(SearchFilter(speaker:"Maya"),mode:.keyword).count,1)
        let interchange=root.appendingPathComponent("memory.json");try store.exportJSON(to:interchange)
        let copied=try MemoryStore(root:root.appendingPathComponent("copied"));_ = try copied.importJSON(from:interchange)
        XCTAssertEqual(try copied.search(SearchFilter(query:"Maya"),mode:.keyword).count,1)
        try store.delete(source.id);XCTAssertTrue(try store.search(SearchFilter(query:"Maya"),mode:.keyword).isEmpty)
    }
    func testLiteralSourceAlignmentUnknownAndUnicodeRanges() throws {
        let source=memory(names:["Maya",nil],texts:["Café 👩🏽‍💻 ships.","Archive is ready."])
        let spans=try XCTUnwrap(AudioEvidence.spans(source.transcript!))
        XCTAssertEqual(spans.count,2)
        XCTAssertEqual(spans[0].range.text(in:source.text),"Café 👩🏽‍💻 ships.")
        let hit=SearchHit(memory:source,score:1,match:"fixture",passage:spans[0].range)
        let evidence=hit.answerEvidence(query:"ships")
        XCTAssertTrue(evidence.contains("speaker \"Maya\""));XCTAssertTrue(evidence.contains("Café 👩🏽‍💻 ships."))
        XCTAssertFalse(evidence.contains("Archive is ready."))
        XCTAssertEqual(hit.passage,spans[0].range)
        let all=SearchHit(memory:source,score:1,match:"").answerEvidence(query:"")
        XCTAssertTrue(all.contains("speaker unknown"));XCTAssertTrue(all.contains("00:03.0–00:05.0"))
    }
    func testMismatchNeverAssignsSpeakerToDifferentSourceWords() throws {
        var source=memory(); source.transcript?.segments[0].text="I own" // leftover letters cannot be bridged to the next timed segment
        XCTAssertNil(AudioEvidence.spans(source.transcript!))
        let evidence=SearchHit(memory:source,score:1,match:"").answerEvidence(query:"capture")
        XCTAssertEqual(evidence,source.text);XCTAssertFalse(evidence.contains("speaker \"Maya\""))
    }
    func testLateSpeakerAnchorsAvoidHeadTailOnlyEvidence() throws {
        let texts=(0..<120).map {"Line \($0): "+String(repeating:"ordinary context ",count:15)}
        var names=Array<String?>(repeating:"Theo",count:texts.count);names[60]="Maya"
        let source=memory(names:names,texts:texts),hit=SearchHit(memory:source,score:1,match:"speaker name")
        let evidence=hit.answerEvidence(query:"What did Maya say?",budget:500)
        XCTAssertTrue(evidence.contains("speaker \"Maya\""));XCTAssertTrue(evidence.contains("Line 60:"))
        XCTAssertLessThan(evidence.count,2400)
    }
    func testScopeSyntaxTransportAndLegacyFilterDecode() throws {
        let resolved=try QueryScopeResolver.resolve(SearchFilter(query:#"archive speaker:"Máya Chen" kind:audio"#))
        XCTAssertEqual(resolved.filter.speaker,"Máya Chen");XCTAssertEqual(resolved.filter.query,"archive")
        XCTAssertThrowsError(try QueryScopeResolver.resolve(SearchFilter(query:"speaker:Maya",speaker:"Theo")))
        XCTAssertThrowsError(try QueryScopeResolver.resolve(SearchFilter(query:"speaker:")))
        XCTAssertNil(try QueryScopeResolver.resolve(SearchFilter(query:"speaker:Maya"),interpret:false).filter.speaker)
        XCTAssertEqual(try Integration.filter(["speaker":"Maya"]).speaker,"Maya")
        XCTAssertThrowsError(try Integration.filter(["speaker":123]))
        var legacy=try XCTUnwrap(try JSONSerialization.jsonObject(with:JSONEncoder().encode(SearchFilter())) as? [String:Any]);legacy.removeValue(forKey:"speaker")
        XCTAssertNil(try JSONDecoder().decode(SearchFilter.self,from:JSONSerialization.data(withJSONObject:legacy)).speaker)
    }
    func testSpeakerNamesAreNotDiscardedAsQuestionStopwords() throws {
        try store.insert(memory(names:["Will","Theo"]))
        XCTAssertEqual(try store.search(SearchFilter(query:"What did Will say?"),mode:.keyword).count,1)
    }
    func testChatSpeakerScopeDoesNotPersistDetectedSecrets() throws {
        let source=memory();try store.insert(source);let chat=try store.createChat()
        let answer=Answer(text:"Evidence [1].",sources:[SearchHit(memory:source,score:1,match:"")],provider:"fixture",duration:0)
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Owner?",answer:answer,filter:SearchFilter(speaker:"password=synthetic123"))
        XCTAssertFalse(try store.chatTurns(chat.id)[0].filter.speaker?.contains("synthetic123") ?? true)
    }
    func testEvidenceOnlyAnswerCarriesSpeakerAndSourceAnchors() async throws {
        try store.insert(memory())
        var config=AIConfiguration();config.provider = .evidence
        let answer=try await AnswerEngine(store:store,embedder:LocalEmbedder()).answer("Who owns capture? speaker:Maya",configuration:config)
        XCTAssertEqual(answer.sources.count,1);XCTAssertTrue(answer.text.contains("speaker \"Maya\""))
        XCTAssertTrue(answer.text.contains("I own the capture tests."));XCTAssertTrue(answer.text.contains("[1]"))
        XCTAssertEqual(answer.resolution?.filter.speaker,"Maya")
    }
}
