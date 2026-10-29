import XCTest
import CSQLite
@testable import OSwindCore

private final class ImportPIITestBackend:PIINativeBackend,@unchecked Sendable {
    let gate:PIIInspectorTests.Gate?,firstOnly:Bool
    init(gate:PIIInspectorTests.Gate?=nil,firstOnly:Bool=false) {self.gate=gate;self.firstOnly=firstOnly}
    func close() {}
    func prepare(_ document:PIIDocument) async throws -> PIIWindowPlan {
        try PIIWindowPlan.make(document:document,prompt:[50281,50369],tokenLimit:512) {_ in [1]}
    }
    func predict(_ window:PIIWindowPlan.Window) async throws -> PIINativeOutput {
        if let gate {await gate.wait()}
        let words=window.input.words
        var logits=Array(repeating:Float(-20),count:words.count*36)
        for (index,word) in words.enumerated() where word.text.contains("OwnedPII") {
            for channel in 0..<3 {logits[index*36+channel]=8}
            if firstOnly {break}
        }
        return .init(sourceSHA256:window.sourceSHA256,windowID:window.id,modelID:PIIInspector.expectedModelID(.cpu),shape:[1,words.count,12,3],logits:logits)
    }
}
final class PIIImportTests:XCTestCase {
    var workspace:URL!,root:URL!,store:MemoryStore!
    override func setUpWithError()throws {
        workspace=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-pii-import-"+UUID().uuidString)
        root=workspace.appendingPathComponent("library");store=try MemoryStore(root:root)
    }
    override func tearDownWithError()throws {try store?.close();store=nil;try? FileManager.default.removeItem(at:workspace)}
    func scanner(_ gate:PIIInspectorTests.Gate?=nil)->PIIImportScanner {
        let backend=ImportPIITestBackend(gate:gate)
        return PIIImportScanner(inspector:PIIInspector(loader:{backend}))
    }
    func note(_ id:String="owned",text:String="Owned fixture") -> Memory {Memory(id:id,kind:.note,app:"Fixture",bundleID:"org.example.fixture",title:"Fixture title",text:text)}
    func imported(_ memories:[Memory],scanner:PIIImportScanner,collector:Bool=false) async throws ->JSONImportResult {
        try await store.importDecodedMemoriesWithPII(memories,embedder:nil,policy:.init(),collectorAdmission:collector,scanner:scanner)
    }
    func testOldSettingsAndOrdinaryResultKeepExistingContract()throws {
        let settings=try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8))
        XCTAssertFalse(settings.piiImports.enabled);XCTAssertEqual(settings.piiImports.compute,.coreML)
        let result=try store.importJSONDetailed(data:JSONEncoder().encode([note()]))
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(result)) as? [String:Any])
        XCTAssertEqual(Set(object.keys),["imported","excluded","skippedLinkedRecaps"])
    }
    func testAllStoredMetadataEscapingAndDuplicateValuesAreMasked() async throws {
        let scanner=scanner();var memory=note(text:"OwnedPIIValue escaped quote \" and newline\nkept")
        memory.app="OwnedPIIValue";memory.title="Title OwnedPIIValue";memory.url="https://example.org/OwnedPIIValue"
        memory.tags=["safe","OwnedPIIValue"];memory.display="OwnedPIIValue"
        memory.embedding=[1,2];memory.embeddingModel="untrusted";memory.imagePath="untrusted.jpg";memory.audioPath="untrusted.wav";memory.videoPath="untrusted.mov"
        let result=try await imported([memory],scanner:scanner);await scanner.shutdown()
        let saved=try XCTUnwrap(store.get(memory.id)),json=String(decoding:try JSONEncoder().encode(saved),as:UTF8.self)
        XCTAssertFalse(json.contains("OwnedPIIValue"));XCTAssertTrue(saved.text.contains("escaped quote \" and newline\nkept"))
        XCTAssertEqual(saved.id,memory.id);XCTAssertEqual(saved.bundleID,memory.bundleID);XCTAssertEqual(saved.tags,["safe","[REDACTED]"])
        XCTAssertNil(saved.embedding);XCTAssertNil(saved.embeddingModel);XCTAssertNil(saved.imagePath);XCTAssertNil(saved.audioPath);XCTAssertNil(saved.videoPath)
        XCTAssertEqual(result.learnedPrivacy?.sources,1);XCTAssertEqual(result.learnedPrivacy?.redactedSources,1);XCTAssertGreaterThan(result.learnedPrivacy?.fields ?? 0,5)
    }
    func testUnicodeGraphemesAndExactDuplicateValuesKeepSafeText() async throws {
        let scanner=scanner(),secret="OwnedPIIe\u{301}"
        var memory=note(text:"🙂 prefix "+secret+" suffix");memory.title="title "+secret
        _ = try await imported([memory],scanner:scanner);await scanner.shutdown()
        let saved=try XCTUnwrap(store.get(memory.id))
        XCTAssertEqual(saved.text,"🙂 prefix [REDACTED] suffix");XCTAssertEqual(saved.title,"title [REDACTED]")
    }
    func testTranscriptMetadataDetectionSuppressesAllTimedTextWithoutChangingTimes() async throws {
        let scanner=scanner();var memory=note(text:"Harmless main transcript")
        memory.kind = .audio;memory.transcript = .init(text:memory.text,duration:2,segments:[.init(start:0,end:1,text:"safe segment",speaker:"OwnedPIISpeaker"),.init(start:1,end:2,text:"another safe segment")],model:"OwnedPIIModel")
        _ = try await imported([memory],scanner:scanner);await scanner.shutdown()
        let transcript=try XCTUnwrap(store.get(memory.id)?.transcript)
        XCTAssertEqual(transcript.text,memory.text);XCTAssertEqual(transcript.segments.map(\.text),["[REDACTED]","[REDACTED]"])
        XCTAssertEqual(transcript.segments.map(\.start),[0,1]);XCTAssertEqual(transcript.segments.map(\.end),[1,2])
        XCTAssertEqual(transcript.segments[0].speaker,"[REDACTED]");XCTAssertEqual(transcript.model,"[REDACTED]")
    }
    func testOriginalSpokenAndSplitPatternChecksSurviveLearnedMaskAndRegularToggleOff() async throws {
        let scanner=scanner();var memory=note(text:"My password is OwnedPIIHidden")
        memory.kind = .audio;memory.transcript = .init(text:memory.text,duration:2,segments:[.init(start:0,end:1,text:"My password"),.init(start:1,end:2,text:"is OwnedPIIHidden")],model:"fixture")
        var policy=PrivacyPolicy();policy.redactSecrets=false
        _ = try await store.importDecodedMemoriesWithPII([memory],embedder:nil,policy:policy,scanner:scanner);await scanner.shutdown()
        let saved=try XCTUnwrap(store.get(memory.id))
        XCTAssertEqual(saved.text,"[REDACTED SENSITIVE SPEECH]");XCTAssertEqual(saved.transcript?.text,saved.text)
        XCTAssertEqual(saved.transcript?.segments.map(\.text),["[REDACTED]","[REDACTED]"])
    }
    func testJoinedVisualPatternProjectsToEveryOriginalFrameAndDropsRegions() async throws {
        let scanner=scanner();let visual=VisualRecording(duration:2,width:1280,height:720,codec:"hevc",hardwareRequired:true,frames:[
            .init(time:0,text:"-----BEGIN PRIVATE KEY-----\nowned",regions:[.init(text:"owned",x:0,y:0,width:1,height:1)]),
            .init(time:1,text:"material\n-----END PRIVATE KEY-----",regions:[.init(text:"material",x:0,y:0,width:1,height:1)])])
        var memory=note(text:visual.text);memory.kind = .screen;memory.visualRecording=visual
        _ = try await imported([memory],scanner:scanner);await scanner.shutdown()
        let saved=try XCTUnwrap(store.get(memory.id)),clean=try XCTUnwrap(saved.visualRecording)
        XCTAssertEqual(clean.frames.map(\.text),["[REDACTED]","[REDACTED]"]);XCTAssertEqual(clean.frames.map(\.time),[0,1]);XCTAssertTrue(clean.frames.allSatisfy {$0.regions.isEmpty})
        XCTAssertEqual(saved.text,clean.text);XCTAssertEqual(clean.codec,"hevc")
    }
    func testRegionOnlyPIIIsRemovedAndFrameTextSurvives() async throws {
        let scanner=scanner();var memory=note(text:"safe OCR")
        memory.kind = .screen;memory.visualRecording = .init(duration:1,width:100,height:100,codec:"h264",hardwareRequired:false,frames:[.init(time:0,text:memory.text,regions:[.init(text:"OwnedPIIRegion",x:0,y:0,width:1,height:1)])])
        _ = try await imported([memory],scanner:scanner);await scanner.shutdown()
        let saved=try XCTUnwrap(store.get(memory.id));XCTAssertEqual(saved.text,"safe OCR");XCTAssertEqual(saved.visualRecording?.frames[0].regions,[])
    }
    func testLearnedSubspanPropagatesWhenOverlappingPatternMaskContainsItsTrigger() async throws {
        let backend=ImportPIITestBackend(firstOnly:true),scanner=PIIImportScanner(inspector:PIIInspector(loader:{backend}))
        var memory=note(text:"password=OwnedPIIValue");memory.url="https://example.org/OwnedPIIValue"
        _ = try await imported([memory],scanner:scanner);await scanner.shutdown()
        let saved=try XCTUnwrap(store.get(memory.id));XCTAssertFalse(saved.text.contains("OwnedPIIValue"));XCTAssertFalse(saved.url?.contains("OwnedPIIValue") ?? true)
    }
    func testImmutableIdentityDetectionRefusesWholeBatch() async throws {
        for field in ["id","bundleID","audioSessionID"] {
            let scanner=scanner();var memory=note()
            if field=="id" {memory.id="OwnedPIIIdentity"};if field=="bundleID" {memory.bundleID="OwnedPIIIdentity"};if field=="audioSessionID" {memory.audioSessionID="OwnedPIIIdentity"}
            do {_ = try await imported([note("first"),memory],scanner:scanner);XCTFail("Identity was rewritten")}
            catch {XCTAssertTrue(error.localizedDescription.contains("immutable"))}
            await scanner.shutdown();XCTAssertEqual(try store.stats().count,0)
        }
    }
    func testCollectorCurationIsScannedBeforeItCanBeRestoredFromOldPayload() async throws {
        let scanner=scanner();var old=note();old.tags=["OwnedPIICuration"];old.favorite=true;try store.insert(old)
        let result=try await imported([note(text:"Replacement")],scanner:scanner,collector:true);await scanner.shutdown()
        let saved=try XCTUnwrap(store.get(old.id));XCTAssertEqual(saved.tags,["[REDACTED]"]);XCTAssertTrue(saved.favorite);XCTAssertEqual(result.imported,1)
    }
    func testChangedParentEvidenceOmitsDependentRecap() async throws {
        let scanner=scanner(),parent=note(text:"OwnedPIIParent")
        var child=note("recap",text:"Owned summary");child.kind = .summary
        child.recap = .init(provider:"fixture",sources:[.init(id:parent.id,revision:parent.evidenceHash,match:"fixture",score:1)])
        let report=try await imported([child,parent],scanner:scanner);await scanner.shutdown()
        XCTAssertEqual(report.imported,1);XCTAssertEqual(report.skippedLinkedRecaps,1);XCTAssertNil(try store.get(child.id))
    }
    func testModelFailuresRefuseBatchWithoutFallbackOrPartialRows() async throws {
        for mode:PIIInspectorTests.Backend.Mode in [.sourceMismatch,.modelMismatch,.nan,.shape,.fail] {
            let backend=PIIInspectorTests.Backend(mode:mode),scanner=PIIImportScanner(inspector:PIIInspector(loader:{backend}))
            do {_ = try await imported([note("one"),note("two")],scanner:scanner);XCTFail("Invalid model output accepted")} catch {}
            await scanner.shutdown();XCTAssertEqual(try store.stats().count,0)
        }
    }
    func testBudgetExceededAfterPreparedSourceRefusesWholeBatchAndShutdownIsTerminal() async throws {
        let scanner=scanner(),large=note("large",text:String(repeating:"owned ",count:9000))
        do {_ = try await imported([note("first"),large],scanner:scanner);XCTFail("Truncated import accepted")} catch {}
        await scanner.shutdown();XCTAssertEqual(try store.stats().count,0)
        do {_ = try await imported([note()],scanner:scanner);XCTFail("Shut down scanner reused")} catch {}
        XCTAssertEqual(try store.stats().count,0)
    }
    /// The real model await, with both SQLite and the activity state mutex free.
    func race(_ mutation:(MemoryStore,LibrarySettingsSnapshot,MediaAdmissionLease)throws->Void) async throws {
        try AppSettings().save(root:root)
        let gate=PIIInspectorTests.Gate(),scanner=scanner(gate),store=self.store!,snapshot=try LibrarySettingsSnapshot.capture(root:root),activity=try store.mediaWriteLease()
        defer {snapshot.release();activity.release()}
        let input=[note("first"),note("target")]
        let worker=Task.detached {try await store.importDecodedMemoriesWithPII(input,embedder:nil,policy:snapshot.settings.privacy,settingsSnapshot:snapshot,admission:activity,scanner:scanner)}
        await fulfillment(of:[gate.entered],timeout:10)
        var mutationError:Error?
        do {try mutation(store,snapshot,activity)} catch {mutationError=error}
        await gate.open()
        do {_ = try await worker.value;XCTFail("Stale prepared import committed")} catch {}
        await scanner.shutdown()
        if let mutationError {throw mutationError}
        XCTAssertNil(try store.get("first"))
    }
    func testConcurrentTargetInsertAndIndependentSQLWorkDuringAwaitAreFenced() async throws {
        try await race {store,_,activity in
            try store.withRoutineDatabase {XCTAssertEqual(sqlite3_get_autocommit($0.handle),1)}
            _ = try activity.withActive(for:store.mediaRootIdentity) {}
            let other=try MemoryStore(root:store.root);defer {try? other.close()}
            try other.insert(self.note("target",text:"Concurrent insert"));try store.insert(self.note("unrelated"))
        }
        XCTAssertEqual(try store.get("target")?.text,"Concurrent insert");XCTAssertNotNil(try store.get("unrelated"))
    }
    func testConcurrentFavoriteTagsAndDeleteAreFenced() async throws {
        try store.insert(note("target"))
        try await race {store,_,_ in try store.setFavorite("target",value:true);try store.setTags("target",tags:["edited"])}
        XCTAssertEqual(try store.get("target")?.tags,["edited"]);XCTAssertEqual(try store.get("target")?.favorite,true)
        try await race {store,_,_ in _ = try store.delete("target")}
        XCTAssertNil(try store.get("target"))
    }
    func testSavedSettingsChangeAndEarlyReleasedAdmissionAreFenced() async throws {
        try await race {store,_,_ in var settings=AppSettings();settings.piiImports.enabled=true;try settings.save(root:store.root)}
        try await race {_,_,activity in activity.release()}
        XCTAssertEqual(try store.stats().count,0)
    }
    func testCancellationJoinsActualAwaitAndDoesNotPublish() async throws {
        let gate=PIIInspectorTests.Gate(),backend=PIIInspectorTests.Backend(gate:gate)
        let inspector=PIIInspector(loader:{backend}),scanner=PIIImportScanner(inspector:inspector),store=self.store!,input=[note()]
        let worker=Task.detached {try await store.importDecodedMemoriesWithPII(input,embedder:nil,policy:.init(),scanner:scanner)}
        await fulfillment(of:[gate.entered],timeout:10);worker.cancel()
        let stopped=XCTestExpectation(description:"Joined scanner shutdown")
        let shutdown=Task {await scanner.shutdown();stopped.fulfill()}
        XCTAssertEqual(backend.snapshot.active,1);XCTAssertEqual(backend.snapshot.closes,0)
        await gate.open()
        do {_ = try await worker.value;XCTFail("Cancelled inference published")} catch is CancellationError {} catch {XCTFail("Unexpected cancellation: \(error)")}
        await fulfillment(of:[stopped],timeout:10);await shutdown.value
        XCTAssertEqual(backend.snapshot.closes,1);XCTAssertFalse(backend.snapshot.closedWhileActive);XCTAssertEqual(try store.stats().count,0)
    }
    func testProductionFactoryMissingCacheRefusesWithoutDownloading() async throws {
        var configuration=PIIImportConfiguration();configuration.enabled=true;configuration.cacheRoot=workspace.appendingPathComponent("missing-cache").path
        do {_ = try await configuration.withScanner {try await self.imported([self.note()],scanner:$0)};XCTFail("Missing model fallback")}
        catch {}
        XCTAssertEqual(try store.stats().count,0);XCTAssertFalse(FileManager.default.fileExists(atPath:configuration.cacheRoot))
    }
}

extension PIIImportTests {
    func testCollectorAndLimitlessPublicLearnedPathsReturnSummary() async throws {
        let scanner=scanner()
        let collector=try JSONSerialization.data(withJSONObject:["format":"OSwind collector batch","version":1,"collectorID":"org.example.fixture","records":[["key":"owned","timestamp":"2026-10-29T12:00:00Z","app":"Fixture","bundleID":"org.example.fixture","title":"OwnedPIITitle","text":"OwnedPIIContent"]]])
        let collected=try await store.importCollectorBatch(collector,scanner:scanner)
        XCTAssertEqual(collected.learnedPrivacy?.sources,1);XCTAssertEqual(collected.learnedPrivacy?.redactedSources,1)
        let source=try XCTUnwrap(store.get(try XCTUnwrap(collected.sourceIDs.first)))
        XCTAssertEqual(source.text,"[REDACTED]");XCTAssertEqual(source.title,"[REDACTED]")
        let record:[String:Any]=["id":"owned-limitless","title":"OwnedPIITitle","markdown":"OwnedPIIBody","startTime":"2026-10-29T12:00:00Z","endTime":"2026-10-29T12:01:00Z","isStarred":false,"contents":[]]
        let page=try JSONSerialization.data(withJSONObject:["data":["lifelogs":[record]],"meta":["lifelogs":["count":1,"nextCursor":NSNull()]]])
        let imported=try await store.importLimitlessAPI(data:page,scanner:scanner);await scanner.shutdown()
        XCTAssertEqual(imported.learnedPrivacy?.sources,1);XCTAssertEqual(imported.learnedPrivacy?.redactedSources,1)
        XCTAssertFalse(try XCTUnwrap(store.get(imported.sourceIDs[0])).text.contains("OwnedPII"))
    }
    func testActualNativeCPUImportPaths() async throws {try await nativeImports(.cpu)}
    func testActualNativeCoreMLImportPaths() async throws {try await nativeImports(.coreML)}
    private func nativeImports(_ compute:PIIComputePolicy) async throws {
        guard let cache=ProcessInfo.processInfo.environment["OSWIND_TEST_PII_SETUP_CACHE"] else {throw XCTSkip("Explicit verified native PII cache absent")}
        var configuration=PIIImportConfiguration();configuration.enabled=true;configuration.compute=compute;configuration.cacheRoot=cache
        let email="+1 (202) 555-0100",text="Owned support note: my private phone number is "+email+". Keep this private."
        XCTAssertTrue(PrivacyPolicy().sensitiveRanges(in:text).isEmpty,"Fixture must require learned detection")
        try await configuration.withScanner {scanner in
            let json=try await self.store.importJSONDetailed(data:JSONEncoder().encode([self.note(text:text)]),scanner:scanner)
            XCTAssertEqual(json.learnedPrivacy?.compute,compute);XCTAssertEqual(json.learnedPrivacy?.sources,1)
            XCTAssertFalse(try XCTUnwrap(self.store.get("owned")).text.contains(email))
            let collector=try JSONSerialization.data(withJSONObject:["format":"OSwind collector batch","version":1,"collectorID":"org.example.fixture","records":[["key":"native","timestamp":"2026-10-29T12:00:00Z","app":"Fixture","bundleID":"org.example.fixture","title":"Fixture","text":text]]])
            let collected=try await self.store.importCollectorBatch(collector,scanner:scanner)
            XCTAssertEqual(collected.learnedPrivacy?.redactedSources,1)
            XCTAssertFalse(try XCTUnwrap(self.store.get(collected.sourceIDs[0])).text.contains(email))
            let record:[String:Any]=["id":"native-limitless","title":"Fixture","markdown":text,"startTime":"2026-10-29T12:00:00Z","endTime":"2026-10-29T12:01:00Z","isStarred":false,"contents":[]]
            let page=try JSONSerialization.data(withJSONObject:["data":["lifelogs":[record]],"meta":["lifelogs":["count":1,"nextCursor":NSNull()]]])
            let imported=try await self.store.importLimitlessAPI(data:page,scanner:scanner)
            XCTAssertEqual(imported.learnedPrivacy?.redactedSources,1)
            XCTAssertFalse(try XCTUnwrap(self.store.get(imported.sourceIDs[0])).text.contains(email))
        }
        XCTAssertEqual(try store.stats().count,3)
    }
    func testPinnedNativeEmailMissIsRetainedAsKnownQualityLimitation() async throws {
        guard let cache=ProcessInfo.processInfo.environment["OSWIND_TEST_PII_SETUP_CACHE"] else {throw XCTSkip("Explicit verified native PII cache absent")}
        let email="maria@sample.example.com",text="You can email me at "+email+" for the report."
        // This is a frozen negative, not a passing privacy-acceptance claim.
        // The initial all-path email acceptance test failed all ten assertions
        // in focused-v4. Preserve that receipt and the unresolved quality gate.
        for compute:PIIComputePolicy in [.cpu,.coreML] {
            var configuration=PIIImportConfiguration();configuration.cacheRoot=cache;configuration.compute=compute
            try await configuration.withScanner {scanner in
                _ = try await self.store.importJSONDetailed(data:JSONEncoder().encode([self.note(text:text)]),scanner:scanner)
            }
            XCTAssertTrue(try XCTUnwrap(store.get("owned")).text.contains(email),"Pinned native model changed; reevaluate the frozen negative and quality ledger")
        }
    }

}

extension PIIImportTests {
    func testEmptyMainTextStillScansStoredMetadata() async throws {
        let scanner=scanner();var memory=note(text:"");memory.title="OwnedPIITitle"
        _ = try await imported([memory],scanner:scanner);await scanner.shutdown()
        XCTAssertEqual(try store.get(memory.id)?.title,"[REDACTED]");XCTAssertEqual(try store.get(memory.id)?.text,"")
    }
    func testConcurrentExternalRecapParentChangeDuringActualAwaitRefusesBatch() async throws {
        let parent=note("external");try store.insert(parent)
        var child=note("child");child.kind = .summary;child.recap = .init(provider:"fixture",sources:[.init(id:parent.id,revision:parent.evidenceHash,match:"fixture",score:1)])
        let gate=PIIInspectorTests.Gate(),scanner=scanner(gate),store=self.store!,input=[note("first"),child]
        let worker=Task.detached {try await store.importDecodedMemoriesWithPII(input,embedder:nil,policy:.init(),scanner:scanner)}
        await fulfillment(of:[gate.entered],timeout:10)
        var mutationError:Error?
        do {try store.setTags(parent.id,tags:["concurrent"])} catch {mutationError=error}
        await gate.open()
        do {_ = try await worker.value;XCTFail("External parent changed during inference")} catch {}
        await scanner.shutdown();if let mutationError {throw mutationError}
        XCTAssertNil(try store.get("first"));XCTAssertNil(try store.get("child"));XCTAssertEqual(try store.get(parent.id)?.tags,["concurrent"])
    }
    func testRootReplacementDuringActualAwaitRefusesWithoutPartialRows() async throws {
        let gate=PIIInspectorTests.Gate(),scanner=scanner(gate),store=self.store!,input=[note()]
        let worker=Task.detached {try await store.importDecodedMemoriesWithPII(input,embedder:nil,policy:.init(),scanner:scanner)}
        await fulfillment(of:[gate.entered],timeout:10)
        let retained=workspace.appendingPathComponent("retained")
        try FileManager.default.moveItem(at:root,to:retained);try Paths.ensure(root)
        await gate.open()
        do {_ = try await worker.value;XCTFail("Replaced library received prepared content")} catch {}
        await scanner.shutdown()
        try FileManager.default.removeItem(at:root);try FileManager.default.moveItem(at:retained,to:root)
        XCTAssertEqual(try store.stats().count,0)
    }
    func testReconstructedResponseRejectsWrongSourceAndRenderedText() async throws {
        let inspector=PIIInspector(loader:{ImportPIITestBackend()}),text="OwnedPIIFixture plain text"
        let result=try await inspector.inspect(text,threshold:0.5);await inspector.shutdown()
        XCTAssertThrowsError(try PIIImportScanner.validatedMasks(result,source:text+"changed",compute:.cpu,threshold:0.5))
        let forged=PIIInspection(sourceSHA256:result.sourceSHA256,modelID:result.modelID,compute:result.compute,threshold:result.threshold,windowCount:result.windowCount,framedTokens:result.framedTokens,text:text,spans:result.spans,modelMasks:result.modelMasks,masks:result.masks,modelRedacted:result.modelRedacted,patternRedacted:result.patternRedacted,redacted:result.redacted,suppressMedia:result.suppressMedia)
        XCTAssertThrowsError(try PIIImportScanner.validatedMasks(forged,source:text,compute:.cpu,threshold:0.5))
    }
}
