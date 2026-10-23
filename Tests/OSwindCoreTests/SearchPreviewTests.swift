import XCTest
import CSQLite
@testable import OSwindCore

final class SearchPreviewTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root.appendingPathComponent("library"))}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    func source(_ id:String="audio",words:Int=100) -> Memory {
        let segments:[TranscriptSegment]=(0..<words).map { index in
            let start=Double(index)*0.2,end=Double(index+1)*0.2
            return TranscriptSegment(start:start,end:end,text:"word\(index)",speaker:index%2==0 ? "Maya":"Theo")
        }
        let text=segments.map(\.text).joined(separator:" ")
        var memory=Memory(id:id,kind:.audio,app:"Imported audio",title:"Authored",text:text);memory.transcript=SpeechTranscript(text:text,duration:Double(words)*0.2,segments:segments,model:"fixture");return memory
    }
    func preview(_ query:String="word") throws -> SearchHit {try XCTUnwrap(store.search(SearchFilter(query:query),mode:.keyword,detail:.preview).first)}
    func testPreviewOmitsSegmentsKeepsOriginalTextAndHydratesCompleteSource() throws {
        let original=source(words:10000);try store.insert(original)
        let hit=try preview();XCTAssertNil(hit.memory.transcript);XCTAssertEqual(hit.memory.text,original.text)
        let metadata=try XCTUnwrap(hit.memory.searchPreview);XCTAssertEqual(metadata.sourceRevision,original.evidenceHash)
        XCTAssertEqual(metadata.transcript.segmentCount,10000);XCTAssertEqual(metadata.transcript.assignedSegments,10000)
        XCTAssertEqual(metadata.transcript.speakerLabels,["Maya","Theo"]);XCTAssertTrue(metadata.transcript.labelsComplete)
        let restored=try store.hydrate([hit]);XCTAssertEqual(restored[0].memory,original)
        XCTAssertEqual(try store.search(SearchFilter(query:"word"),mode:.keyword)[0].memory.transcript,original.transcript)
        XCTAssertLessThan(try JSONEncoder().encode(hit.memory).count,try JSONEncoder().encode(original).count/3)
    }
    func testAllRetrievalModesPreserveRankingAndPassageAnchors() throws {
        let original=source(words:600);try store.insert(original)
        _ = try store.saveVectors([VectorRecord(memory:original,vector:[1,0])],modelID:"fixture")
        let plan=SemanticPassagePlan.make(original)
        XCTAssertTrue(try store.savePassages(memory:original,modelID:"fixture",records:plan.enumerated().map {PassageVector(range:$0.element.range,vector:$0.offset==1 ? [0,1]:[1,0])}))
        for mode in SearchMode.allCases {
            let filter=SearchFilter(query:"word",speaker:"Maya")
            let full=try store.search(filter,mode:mode,vector:[0,1],modelID:"fixture")
            let light=try store.search(filter,mode:mode,vector:[0,1],modelID:"fixture",detail:.preview)
            XCTAssertEqual(full.map(\.id),light.map(\.id));XCTAssertEqual(full.map(\.score),light.map(\.score));XCTAssertEqual(full.map(\.passage),light.map(\.passage))
            XCTAssertEqual(try store.hydrate(light)[0].memory.transcript,original.transcript)
        }
        XCTAssertNotNil(try preview("Maya").memory.searchPreview)
    }
    func testPreviewCannotOverwriteSourceOrEnterSavedAnswer() throws {
        let original=source();try store.insert(original);let hit=try preview()
        XCTAssertThrowsError(try store.insert(hit.memory))
        let chat=try store.createChat(),answer=Answer(text:"Maya [1].",sources:[hit],provider:"fixture",duration:0)
        XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Who?",answer:answer))
        XCTAssertTrue(try store.chatTurns(chat.id).isEmpty);XCTAssertEqual(try store.get(original.id),original)
    }
    func testHydrationRejectsDeletedOrRevisedEvidenceButAcceptsMetadataEdits() throws {
        let original=source();try store.insert(original);let hit=try preview()
        try store.setFavorite(original.id,value:true);try store.setTags(original.id,tags:["work"])
        let full=try store.hydrate([hit])[0].memory;XCTAssertTrue(full.favorite);XCTAssertEqual(full.tags,["work"])
        XCTAssertTrue(try preview().memory.favorite);XCTAssertEqual(try preview().memory.tags,["work"])
        _ = try store.renameAudioSpeaker(original.id,from:"Maya",to:"Robin")
        XCTAssertThrowsError(try store.hydrate([hit]));XCTAssertThrowsError(try store.hydrate(original))
        let fresh=try preview("Robin");XCTAssertTrue(fresh.memory.searchPreview?.transcript.speakerLabels.contains("Robin")==true)
        try store.delete(original.id);XCTAssertThrowsError(try store.hydrate([fresh]));XCTAssertTrue(try store.search(SearchFilter(),mode:.keyword,detail:.preview).isEmpty)
    }
    func testHydrationRejectsStaleTimingAndInvalidPassage() throws {
        var memory=source();try store.insert(memory);let hit=try preview()
        memory.transcript?.segments[0].end=0.19;try store.insert(memory)
        XCTAssertThrowsError(try store.hydrate([hit]))
        var invalid=try preview();invalid.passage=PassageRange(start:memory.text.utf16.count,length:10)
        XCTAssertThrowsError(try store.hydrate([invalid]))
    }
    func testMixedKindsAndLegacyUntimedAudioRemainComplete() throws {
        try store.insert(source());try store.insert(Memory(id:"note",kind:.note,text:"word note"));try store.insert(Memory(id:"legacy",kind:.audio,text:"word legacy"))
        let hits=try store.search(SearchFilter(query:"word"),mode:.keyword,detail:.preview)
        XCTAssertEqual(hits.count,3);XCTAssertNotNil(hits.first {$0.id=="audio"}?.memory.searchPreview)
        XCTAssertNil(hits.first {$0.id=="legacy"}?.memory.searchPreview);XCTAssertNil(hits.first {$0.id=="note"}?.memory.searchPreview)
    }
    func testTimelineSampleMatchesFullSelectionWithoutTimedPayloads() throws {
        for i in 0..<60 {var memory=source(String(i));memory.timestamp=Date(timeIntervalSince1970:Double(i));try store.insert(memory)}
        let full=try store.timelineSample(SearchFilter(),limit:12),light=try store.timelineSample(SearchFilter(),limit:12,detail:.preview)
        XCTAssertEqual(full.map(\.id),light.map(\.id));XCTAssertEqual(full.count,12)
        XCTAssertTrue(light.allSatisfy {$0.transcript==nil && $0.searchPreview != nil});XCTAssertEqual(full.first?.id,"0");XCTAssertEqual(full.last?.id,"59")
    }
    func testDerivedCacheFailureRollsBackSourceAndMetadata() throws {
        let original=source();try store.insert(original)
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(store.root.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK);defer {sqlite3_close(db)}
        XCTAssertEqual(sqlite3_exec(db,"CREATE TRIGGER fail_preview BEFORE INSERT ON audio_search_previews BEGIN SELECT RAISE(ABORT,'fixture failure'); END;",nil,nil,nil),SQLITE_OK)
        XCTAssertThrowsError(try store.setFavorite(original.id,value:true));XCTAssertEqual(try store.get(original.id),original)
        var revised=original;revised.title="Changed";XCTAssertThrowsError(try store.insert(revised));XCTAssertEqual(try store.get(original.id),original)
        XCTAssertNoThrow(try store.hydrate([preview()]))
    }
    func testMigrationRestoreAndInterchangeRebuildCacheFromFullSources() throws {
        let original=source();try store.insert(original)
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(store.root.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"DELETE FROM audio_search_previews; PRAGMA user_version=10;",nil,nil,nil),SQLITE_OK);sqlite3_close(db)
        store=nil;store=try MemoryStore(root:root.appendingPathComponent("library"));XCTAssertNotNil(try preview().memory.searchPreview)
        let backup=root.appendingPathComponent("audio.oswindbackup");_ = try LibraryBackup.create(store:store,destination:backup)
        let restored=root.appendingPathComponent("restored");_ = try LibraryBackup.restore(backup,to:restored)
        let reopened=try MemoryStore(root:restored);let hits=try reopened.search(SearchFilter(query:"word"),mode:.keyword,detail:.preview)
        XCTAssertNotNil(hits.first?.memory.searchPreview);XCTAssertEqual(try reopened.hydrate(hits)[0].memory.transcript,original.transcript)
        let json=root.appendingPathComponent("source.json");try store.exportJSON(to:json);XCTAssertFalse(try String(contentsOf:json,encoding:.utf8).contains("searchPreview"))
        let copied=try MemoryStore(root:root.appendingPathComponent("copied"));_ = try copied.importJSON(from:json)
        XCTAssertNotNil(try copied.search(SearchFilter(query:"word"),mode:.keyword,detail:.preview).first?.memory.searchPreview)
    }
    func testSummaryNamesAreBoundedWithoutInventingTruncatedLabels() throws {
        var original=source(words:100)
        for i in 0..<100 {original.transcript?.segments[i].speaker="Name \(i)"}
        try store.insert(original);let metadata=try XCTUnwrap(preview().memory.searchPreview?.transcript)
        XCTAssertEqual(metadata.speakerCount,100);XCTAssertEqual(metadata.speakerLabels.count,32);XCTAssertFalse(metadata.labelsComplete)
    }
    func testCancelledHydrationCannotProduceEvidence() async throws {
        try store.insert(source());let hit=try preview(),store=self.store!
        let task=Task {withUnsafeCurrentTask {$0?.cancel()};return try store.hydrate([hit])}
        do {_ = try await task.value;XCTFail("Cancelled hydration returned a source")} catch is CancellationError {} catch {XCTFail("Unexpected error: \(error)")}
    }
    func testMetadataWriteWaitsBeforeReadingConcurrentAttributionRevision() async throws {
        let original=source();try store.insert(original);let other=try MemoryStore(root:store.root)
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(store.root.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK);defer {sqlite3_close(db)}
        XCTAssertEqual(sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil),SQLITE_OK)
        var revised=original
        for index in revised.transcript!.segments.indices where revised.transcript!.segments[index].speaker=="Maya" {revised.transcript!.segments[index].speaker="Robin"}
        let payload=try JSONEncoder().encode(revised);var statement:OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db,"UPDATE memories SET payload=? WHERE id='audio'",-1,&statement,nil),SQLITE_OK)
        _ = payload.withUnsafeBytes {sqlite3_bind_blob(statement,1,$0.baseAddress,Int32($0.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
        XCTAssertEqual(sqlite3_step(statement),SQLITE_DONE);sqlite3_finalize(statement)
        let started=expectation(description:"metadata writer entered"),finished=expectation(description:"metadata writer completed")
        DispatchQueue.global().async {started.fulfill();do {try other.setFavorite(original.id,value:true)} catch {XCTFail("Concurrent metadata write failed: \(error)")};finished.fulfill()}
        await fulfillment(of:[started],timeout:5);try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(sqlite3_exec(db,"COMMIT",nil,nil,nil),SQLITE_OK);await fulfillment(of:[finished],timeout:5)
        let current=try XCTUnwrap(store.get(original.id));XCTAssertTrue(current.favorite);XCTAssertEqual(current.transcript?.segments[0].speaker,"Robin")
        XCTAssertTrue(try preview().memory.searchPreview?.transcript.speakerLabels.contains("Robin")==true)
        XCTAssertNoThrow(try store.hydrate([preview()]))
    }
    func testSyntheticBenchmarkRefusesExistingUnmarkedDataAndPreservesIDs() throws {
        let archive=root.appendingPathComponent("bench")
        XCTAssertThrowsError(try AudioSearchEvaluation.run(archive:archive,detail:.preview));XCTAssertFalse(FileManager.default.fileExists(atPath:archive.path))
        _ = try AudioSearchEvaluation.prepare(archive:archive,clips:2,words:10)
        XCTAssertThrowsError(try AudioSearchEvaluation.prepare(archive:archive,clips:2,words:10))
        let full=try AudioSearchEvaluation.run(archive:archive,detail:.full,repetitions:2),light=try AudioSearchEvaluation.run(archive:archive,detail:.preview,repetitions:2)
        XCTAssertEqual(full["ordered_id_sha256"] as? String,light["ordered_id_sha256"] as? String)
        XCTAssertLessThan(try XCTUnwrap(light["response_bytes"] as? Int),try XCTUnwrap(full["response_bytes"] as? Int))
    }
    func testTransportDefaultsAndValidationStayExplicit() throws {
        XCTAssertNoThrow(try Integration.filter(["detail":"preview"]));XCTAssertNoThrow(try Integration.filter(["detail":"full"]))
        XCTAssertThrowsError(try Integration.filter(["detail":"other"]));XCTAssertThrowsError(try Integration.filter(["detail":true]))
    }
    func testAnswerAndRecapHydrateOnlyCompleteCitableSources() async throws {
        let original=source();try store.insert(original);var config=AIConfiguration();config.provider = .evidence
        for recap in [false,true] {
            let answer=try await AnswerEngine(store:store,embedder:LocalEmbedder()).answer("word speaker:Maya",configuration:config,summarize:recap)
            XCTAssertEqual(answer.sources.count,1);XCTAssertNil(answer.sources[0].memory.searchPreview);XCTAssertEqual(answer.sources[0].memory.transcript,original.transcript)
        }
    }
}
