import XCTest
import CSQLite
@testable import OSwindCore

final class TextObservationStoreTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    let date=Date(timeIntervalSince1970:1730611800)
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-observation-"+UUID().uuidString);store=try MemoryStore(root:root);var s=AppSettings();s.visualCaptureMode = .accessibility;try s.save(root:root)}
    override func tearDownWithError()throws {try? store.close();try? FileManager.default.removeItem(at:root)}
    func memory(_ id:String="observed",span:Bool=true)->Memory {
        var m=Memory(id:id,timestamp:date,app:"Owned",bundleID:"org.oswind.owned",title:"Release",text:"Maya owns the Friday release.",display:AccessibilityCaptureRecord.display)
        if span {m.textObservation=TextObservationSpan()};return m
    }
    func cursor(_ m:Memory)throws->TextObservationCursor {.init(id:m.id,digest:try AccessibilityCaptureRecord.digest(m),binding:Data(),first:m.timestamp,last:m.endTimestamp ?? m.timestamp,uptime:100,span:try XCTUnwrap(m.textObservation))}
    func extend(_ m:Memory,seconds:Double=5)throws->Memory {
        let r=try AccessibilityCaptureReservation(store:store,configuration:AppSettings.load(root:root));defer {r.release()}
        return try store.extendAccessibilityObservation(cursor(m),at:(m.endTimestamp ?? m.timestamp).addingTimeInterval(seconds),reservation:r)
    }
    func sql(_ query:String)throws->String {try store.withRoutineDatabase {db in let row=try db.statement(query);defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return db.text(row,0)}}
    func testExtensionPreservesSourceVectorFTSKeysAndCurrentCuration()throws {
        var m=memory();m.embedding=[1,0,0,0];m.embeddingModel="owned";try store.insert(m)
        let vector=try sql("SELECT hex(embedding) FROM memories WHERE id='observed'"),key=try sql("SELECT key FROM memory_fts_keys WHERE memory_id='observed'"),journal=try sql("SELECT MAX(seq) FROM vector_changes")
        try store.setFavorite(m.id,value:true);try store.setTags(m.id,tags:["release"])
        let updated=try extend(m)
        XCTAssertTrue(updated.favorite);XCTAssertEqual(updated.tags,["release"]);XCTAssertEqual(updated.text,m.text);XCTAssertEqual(updated.timestamp,date);XCTAssertEqual(updated.endTimestamp,date.addingTimeInterval(5));XCTAssertEqual(updated.textObservation?.samples,2)
        XCTAssertEqual(try sql("SELECT hex(embedding) FROM memories WHERE id='observed'"),vector);XCTAssertEqual(try sql("SELECT key FROM memory_fts_keys WHERE memory_id='observed'"),key);XCTAssertEqual(try sql("SELECT MAX(seq) FROM vector_changes"),journal)
        XCTAssertEqual(try store.search(SearchFilter(query:"Friday",favoritesOnly:true,tag:"release"),mode:.keyword).map(\.id),[m.id])
    }
    func testTimeSearchIncludesLastObservedPointAndKeepsExclusiveQueryEnd()throws {
        let m=memory();try store.insert(m);let updated=try extend(m,seconds:30)
        for offset in [0.0,10,30] {XCTAssertEqual(try store.search(SearchFilter(query:"Friday",start:date.addingTimeInterval(offset),end:date.addingTimeInterval(offset+1)),mode:.keyword).map(\.id),[m.id])}
        XCTAssertTrue(try store.search(SearchFilter(start:date.addingTimeInterval(30.001)),mode:.keyword).isEmpty)
        XCTAssertTrue(try store.search(SearchFilter(end:date),mode:.keyword).isEmpty)
        XCTAssertEqual(try store.timelineSample(SearchFilter(start:date.addingTimeInterval(15)),limit:10).first?.textObservation,updated.textObservation)
        var point=memory("point",span:false);point.endTimestamp=date.addingTimeInterval(40);try store.insert(point)
        XCTAssertEqual(try store.search(SearchFilter(start:date.addingTimeInterval(15)),mode:.keyword).map(\.id),[m.id],"Legacy duration/source-start semantics stay unchanged")
    }
    func testScopeRevisionChangesWithoutVectorIdentityChange()throws {
        var m=memory();m.embedding=[1,0,0,0];m.embeddingModel="owned";try store.insert(m)
        let before=try sql("SELECT hex(revision) FROM search_scope_revision"),identity=try sql("SELECT value FROM store_metadata WHERE key='identity'")
        _=try extend(m);XCTAssertNotEqual(try sql("SELECT hex(revision) FROM search_scope_revision"),before);XCTAssertEqual(try sql("SELECT value FROM store_metadata WHERE key='identity'"),identity)
    }
    func testCalendarStillCountsStartsAndErasureIncludesLastObservedPoint()throws {
        let m=memory();try store.insert(m);_=try extend(m,seconds:30)
        let zone=try XCTUnwrap(TimeZone(identifier:"America/New_York")),request=ActivityCalendarRequest(month:"2024-11",timeZone:zone,selectedDay:"2024-11-03",filter:SearchFilter(start:date.addingTimeInterval(10)))
        XCTAssertEqual(try store.activityCalendar(request).totalSources,0)
        let scope=HistoryErasureScope(start:date.addingTimeInterval(30),end:date.addingTimeInterval(31)),preview=try store.previewErasure(scope)
        XCTAssertEqual(preview.sources,1);_=try store.eraseHistory(scope,expectedToken:preview.token);XCTAssertEqual(try sql("SELECT COUNT(*) FROM text_observation_ranges"),"0")
    }
    func testSavedEvidencePinsExtentAndExplicitEditsStillInvalidateReferences()throws {
        let m=memory();try store.insert(m);let answer=Answer(text:"Maya [1]",sources:[.init(memory:m,score:1,match:"owned")],provider:"owned",duration:0),chat=try store.createChat()
        _=try store.appendChatTurn(sessionID:chat.id,question:"What was observed?",answer:answer);let recap=try store.saveRecap(answer)
        XCTAssertThrowsError(try extend(m));XCTAssertNotNil(try store.get(recap.id));XCTAssertEqual(try store.chatTurns(chat.id).count,1)
        var edited=m;edited.text="Changed release facts";try store.insert(edited)
        XCTAssertNil(try store.get(recap.id));XCTAssertTrue(try store.chatTurns(chat.id).isEmpty)
        XCTAssertThrowsError(try store.saveRecap(answer));XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Late?",answer:answer))
    }
    func testCurationDoesNotInvalidateObservationEvidenceOrRecaps()throws {
        let m=memory();try store.insert(m);let answer=Answer(text:"Maya [1]",sources:[.init(memory:m,score:1,match:"owned")],provider:"owned",duration:0),recap=try store.saveRecap(answer)
        try store.setFavorite(m.id,value:true);try store.setTags(m.id,tags:["owned"])
        XCTAssertNotNil(try store.get(recap.id));XCTAssertEqual(try store.get(m.id)?.evidenceHash,m.evidenceHash)
    }
    func testStaleDeletedAndEditedSourcesCannotBeExtended()throws {
        let m=memory();try store.insert(m);let newer=try extend(m)
        XCTAssertThrowsError(try extend(m));XCTAssertEqual(try store.get(m.id)?.endTimestamp,newer.endTimestamp)
        var edited=newer;edited.text="Edited context";try store.insert(edited);XCTAssertThrowsError(try extend(newer))
        try store.delete(m.id);XCTAssertThrowsError(try extend(newer));XCTAssertEqual(try store.stats().count,0)
    }
    func testSavedPolicyReplacementRefusesExtensionAndLeavesExtentUnchanged()throws {
        let m=memory();try store.insert(m);let reservation=try AccessibilityCaptureReservation(store:store,configuration:AppSettings.load(root:root));defer {reservation.release()}
        let settings=root.appendingPathComponent("settings.json");try Data(contentsOf:settings).write(to:settings,options:.atomic)
        XCTAssertThrowsError(try store.extendAccessibilityObservation(cursor(m),at:date.addingTimeInterval(5),reservation:reservation));XCTAssertNil(try store.get(m.id)?.endTimestamp);XCTAssertEqual(try sql("SELECT COUNT(*) FROM text_observation_ranges"),"0")
    }
    func testRangeProjectionRepairsAndLegacySourceBytesRemainUnchanged()throws {
        let m=memory();try store.insert(m);_=try extend(m);let payload=try sql("SELECT hex(payload) FROM memories WHERE id='observed'")
        try store.withRoutineDatabase {try $0.execute("DROP TABLE text_observation_ranges")};try store.close();store=try MemoryStore(root:root)
        XCTAssertEqual(try sql("SELECT hex(payload) FROM memories WHERE id='observed'"),payload);XCTAssertEqual(try sql("SELECT COUNT(*) FROM text_observation_ranges"),"1")
        var legacy=memory("legacy",span:false);legacy.endTimestamp=nil;try store.insert(legacy);let hash=legacy.evidenceHash;try store.close();store=try MemoryStore(root:root);XCTAssertEqual(try store.get(legacy.id)?.evidenceHash,hash)
    }
    func testSpanValidationRefusesImpossibleImportedClaims()throws {
        for n in 0..<5 {
            var m=memory("invalid\(n)");m.endTimestamp=date.addingTimeInterval(n==0 ? 901:n==1 ? -1:5)
            if n==2 {m.textObservation=TextObservationSpan(samples:2,largestGapSeconds:121)}
            if n==3 {m.textObservation=TextObservationSpan(samples:2,largestGapSeconds:5);m.kind = .note}
            if n==4 {m.textObservation=TextObservationSpan(samples:2,largestGapSeconds:1)}
            XCTAssertThrowsError(try store.insert(m))
        }
        XCTAssertEqual(try store.stats().count,0)
    }
    func testSourceStartOptionAndLegacyFilterDecodePreserveCalendarSemantics()throws {
        let m=memory();try store.insert(m);_=try extend(m,seconds:30)
        let from=date.addingTimeInterval(10),all=SearchFilter(start:from),starts=SearchFilter(start:from,sourceStartsOnly:true)
        XCTAssertEqual(try store.matchingCount(all),1);XCTAssertEqual(try store.matchingCount(starts),0)
        let legacy=try JSONDecoder().decode(SearchFilter.self,from:Data(#"{"query":"Friday","favoritesOnly":false,"limit":20}"#.utf8));XCTAssertNil(legacy.sourceStartsOnly)
        for invalid:Any in ["true",1,0,NSNull()] {XCTAssertThrowsError(try Integration.filter(["sourceStartsOnly":invalid]))}
        XCTAssertEqual(try Integration.filter(["sourceStartsOnly":true]).sourceStartsOnly,true)
    }
    func testActualHTTPAndMCPExecutionShareObservedRangeAndStrictBooleanValidation()async throws {
        let m=memory();try store.insert(m);_=try extend(m,seconds:30)
        let from=date.addingTimeInterval(10).formatted(.iso8601),arguments:[String:Any]=["query":"Friday","mode":"keyword","start":from]
        let result=try await Integration.execute("search_memory",args:arguments,store:store,embedder:LocalEmbedder()) as? [String:Any]
        XCTAssertEqual((result?["hits"] as? [[String:Any]])?.count,1)
        let server=try LocalAPIServer(store:store,embedder:LocalEmbedder())
        func request(_ suffix:String)->String {"GET /v1/search?query=Friday&mode=keyword&start=\(from)&\(suffix) HTTP/1.1\r\nHost: 127.0.0.1:47831\r\nAuthorization: Bearer \(server.token)\r\n\r\n"}
        let included=await server.handle(request("sourceStartsOnly=false")),excluded=await server.handle(request("sourceStartsOnly=true"))
        XCTAssertEqual(included.0,200);XCTAssertEqual(excluded.0,200)
        XCTAssertEqual(((included.1 as? [String:Any])?["hits"] as? [[String:Any]])?.count,1);XCTAssertEqual(((excluded.1 as? [String:Any])?["hits"] as? [[String:Any]])?.count,0)
        let invalid=await server.handle(request("sourceStartsOnly=1")),duplicate=await server.handle(request("sourceStartsOnly=true&sourceStartsOnly=false"));XCTAssertEqual(invalid.0,400);XCTAssertEqual(duplicate.0,400)
    }
    func testEvidenceAnswerKeepsDistinctSpansAndDescribesUnobservedGaps()async throws {
        let first=memory();var second=memory("second");second.timestamp=date.addingTimeInterval(600)
        try store.insert(first);try store.insert(second);_=try extend(first);_=try extend(second)
        var configuration=AIConfiguration();configuration.provider = .evidence
        let answer=try await AnswerEngine(store:store,embedder:LocalEmbedder()).answer("Friday",configuration:configuration)
        XCTAssertEqual(answer.sources.count,2);XCTAssertTrue(answer.text.contains("Sampled text: 2 observations"));XCTAssertTrue(answer.text.contains("Gaps are unobserved"));XCTAssertTrue(answer.warnings.contains {$0.contains("sampled")})
    }
    func testFullBackupAndJSONPreserveObservationRangeWithQuietSettings()throws {
        let m=memory();try store.insert(m);let updated=try extend(m)
        let archive=root.deletingLastPathComponent().appendingPathComponent("owned-span-"+UUID().uuidString+".oswindbackup"),restored=root.deletingLastPathComponent().appendingPathComponent("owned-span-restored-"+UUID().uuidString),copy=root.deletingLastPathComponent().appendingPathComponent("owned-span-json-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:archive);try? FileManager.default.removeItem(at:restored);try? FileManager.default.removeItem(at:copy)}
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:restored)
        let restoredStore=try MemoryStore(root:restored);defer {try? restoredStore.close()};XCTAssertEqual(try restoredStore.get(m.id)?.textObservation,updated.textObservation);XCTAssertEqual(try restoredStore.matchingCount(SearchFilter(start:date.addingTimeInterval(3))),1);XCTAssertFalse(AppSettings.load(root:restored).captureOnLaunch)
        let exported=root.appendingPathComponent("owned-export.json");try store.exportJSON(to:exported);let copied=try MemoryStore(root:copy);defer {try? copied.close()};_=try copied.importJSONDetailed(from:exported);XCTAssertEqual(try copied.get(m.id)?.textObservation,updated.textObservation);XCTAssertEqual(try copied.matchingCount(SearchFilter(start:date.addingTimeInterval(3))),1)
    }
    func testCursorSampleCapRejectsFurtherCoalescing()throws {
        var m=memory();m.endTimestamp=date.addingTimeInterval(499.5);m.textObservation=TextObservationSpan(samples:1000,largestGapSeconds:0.5);try m.textObservation?.validated(for:m)
        let c=try cursor(m);XCTAssertFalse(c.canContinue(digest:c.digest,binding:c.binding,at:date.addingTimeInterval(500),uptime:100.5,gapLimit:50))
    }
    func testInvalidRawStoreRangeCannotSelectASpanCrossingBothBounds()throws {
        let m=memory();try store.insert(m);_=try extend(m,seconds:30)
        for f in [SearchFilter(start:date.addingTimeInterval(20),end:date.addingTimeInterval(10)),SearchFilter(start:date,end:date),SearchFilter(start:Date(timeIntervalSince1970:.infinity))] {
            XCTAssertTrue(try store.search(f,mode:.keyword).isEmpty);XCTAssertEqual(try store.matchingCount(f),0);XCTAssertTrue(try store.timelineSample(f).isEmpty)
        }
    }
    func testOversizedCurationCannotRemoveTheSampledTimeProjection()throws {
        let m=memory();try store.insert(m);_=try extend(m)
        XCTAssertThrowsError(try store.setTags(m.id,tags:[String(repeating:"x",count:300000)]))
        XCTAssertTrue(try store.get(m.id)?.tags.isEmpty == true)
        XCTAssertEqual(try store.matchingCount(SearchFilter(start:date.addingTimeInterval(3))),1)
    }
    func testEvidenceConsumptionPinsSpanBeforeModelResponse()async throws {
        let m=memory();try store.insert(m);var configuration=AIConfiguration();configuration.provider = .evidence
        let answer=try await AnswerEngine(store:store,embedder:LocalEmbedder()).answer("Friday",configuration:configuration)
        XCTAssertThrowsError(try extend(m))
        XCTAssertEqual(try store.get(m.id)?.textObservation?.samples,1)
        XCTAssertNoThrow(try store.saveRecap(answer))
    }
    func testPinnedStaleResultCanAdvanceOnlyThroughUneditedAppend()throws {
        let m=memory();try store.insert(m);let newer=try extend(m)
        let hit=SearchHit(memory:m,score:1,match:"owned")
        XCTAssertThrowsError(try store.hydrate([hit]))
        let pinned=try store.hydrate([hit],pinTextObservations:true);XCTAssertEqual(pinned[0].memory.textObservation,newer.textObservation)
        XCTAssertThrowsError(try extend(newer))
        var edited=newer;edited.text="Changed source";try store.insert(edited)
        XCTAssertThrowsError(try store.hydrate([hit],pinTextObservations:true))
    }
    func testPinGuardProtectsSQLWritersAndSourceEraseCascadesPins()throws {
        let m=memory();try store.insert(m);let recap=try store.saveRecap(Answer(text:"Maya [1]",sources:[.init(memory:m,score:1,match:"owned")],provider:"owned",duration:0))
        XCTAssertEqual(try sql("SELECT COUNT(*) FROM text_observation_pins"),"1")
        XCTAssertThrowsError(try store.withRoutineDatabase {try $0.execute("UPDATE memories SET payload=CAST(json_set(CAST(payload AS TEXT),'$.endTimestamp',timestamp-978307200+5,'$.textObservation.samples',2,'$.textObservation.largestGapSeconds',5) AS BLOB) WHERE id='observed'")})
        XCTAssertNil(try store.get(m.id)?.endTimestamp);XCTAssertNotNil(try store.get(recap.id));try store.delete(m.id);XCTAssertEqual(try sql("SELECT COUNT(*) FROM text_observation_pins"),"0")
    }
    func testColdPinRepairPreservesReferencedExtent()throws {
        let m=memory();try store.insert(m);_=try store.saveRecap(Answer(text:"Maya [1]",sources:[.init(memory:m,score:1,match:"owned")],provider:"owned",duration:0))
        try store.withRoutineDatabase {try $0.execute("DROP TABLE text_observation_pins")};try store.close();store=try MemoryStore(root:root)
        XCTAssertEqual(try sql("SELECT COUNT(*) FROM text_observation_pins"),"1");XCTAssertThrowsError(try extend(m))
    }
    func testQuietBackupRestoresPinsForSavedEvidence()throws {
        let m=memory();try store.insert(m);let recap=try store.saveRecap(Answer(text:"Maya [1]",sources:[.init(memory:m,score:1,match:"owned")],provider:"owned",duration:0))
        let archive=root.deletingLastPathComponent().appendingPathComponent("owned-pinned-"+UUID().uuidString+".oswindbackup"),restored=root.deletingLastPathComponent().appendingPathComponent("owned-pinned-restored-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:archive);try? FileManager.default.removeItem(at:restored)}
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:restored)
        let copy=try MemoryStore(root:restored);defer {try? copy.close()};XCTAssertNotNil(try copy.get(recap.id))
        let count=try copy.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM text_observation_pins")};XCTAssertEqual(count,1)
    }
}
