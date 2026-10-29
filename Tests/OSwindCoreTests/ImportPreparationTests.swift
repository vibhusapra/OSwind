import XCTest
import CSQLite
@testable import OSwindCore

private final class ImportPreparationGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"Preparation paused outside SQL")
    private let condition=NSCondition()
    private var released=false
    func pause() throws {
        condition.lock();defer {condition.unlock()};entered.fulfill()
        let deadline=Date().addingTimeInterval(20)
        while !released {guard condition.wait(until:deadline) else {throw OSwindError.unavailable("Test preparation gate timed out")}}
    }
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
}

final class ImportPreparationTests:XCTestCase {
    var workspace:URL!,root:URL!,store:MemoryStore!
    override func setUpWithError() throws {
        workspace=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-import-preparation-"+UUID().uuidString)
        root=workspace.appendingPathComponent("library");store=try MemoryStore(root:root)
    }
    override func tearDownWithError() throws {try store?.close();store=nil;try? FileManager.default.removeItem(at:workspace)}
    func note(_ id:String,text:String="Owned imported text") -> Memory {Memory(id:id,kind:.note,app:"Fixture",title:"Owned fixture",text:text)}
    func recap(_ parent:Memory) -> Memory {
        var value=Memory(id:"recap",kind:.summary,app:"OSwind",text:"Owned summary")
        value.recap = .init(provider:"fixture",sources:[.init(id:parent.id,revision:parent.evidenceHash,match:"fixture",score:1)])
        return value
    }
    func testSameConnectionAndOtherConnectionCanReadAndWriteDuringPreparation() async throws {
        let store=self.store!,other=try MemoryStore(root:root),gate=ImportPreparationGate(),input=[note("one"),note("two")]
        defer {gate.release();try? other.close()}
        let worker=Task.detached {try store.importDecodedMemoriesDetailed(input,embedder:nil,policy:.init(),preparationProgress:{if $0==1 {try gate.pause()}})}
        await fulfillment(of:[gate.entered],timeout:10)
        let progressed=XCTestExpectation(description:"Both connections progress during preparation")
        let concurrent=Task.detached {
            defer {progressed.fulfill()}
            try store.withRoutineDatabase {XCTAssertEqual(sqlite3_get_autocommit($0.handle),1)}
            XCTAssertEqual(try store.stats().count,0);try store.insert(Memory(id:"same-connection",kind:.note,text:"Unrelated edit"))
            try other.insert(Memory(id:"other-connection",kind:.note,text:"Unrelated external edit"))
        }
        await fulfillment(of:[progressed],timeout:5);gate.release()
        try await concurrent.value;let result=try await worker.value
        XCTAssertEqual(result.imported,2);XCTAssertEqual(try store.stats().count,4)
    }
    func testConcurrentTargetTextChangeRefusesWholeBatch() throws {
        let original=note("target",text:"Original");try store.insert(original)
        let other=try MemoryStore(root:root);defer {try? other.close()}
        XCTAssertThrowsError(try store.importDecodedMemoriesDetailed([note("fresh"),note("target")],embedder:nil,policy:.init(),preparationProgress:{if $0==1 {try other.insert(self.note("target",text:"Concurrent edit"))}})) {XCTAssertTrue($0.localizedDescription.contains("changed during preparation"))}
        XCTAssertNil(try store.get("fresh"));XCTAssertEqual(try store.get("target")?.text,"Concurrent edit")
    }
    func testConcurrentFavoriteAndTagChangeIsFencedForCollectorCuration() throws {
        try store.insert(note("target"));let other=try MemoryStore(root:root);defer {try? other.close()}
        XCTAssertThrowsError(try store.importDecodedMemoriesDetailed([note("fresh"),note("target")],embedder:nil,policy:.init(),collectorAdmission:true,preparationProgress:{if $0==1 {try other.setFavorite("target",value:true);try other.setTags("target",tags:["new curation"])}}))
        XCTAssertNil(try store.get("fresh"));XCTAssertEqual(try store.get("target")?.tags,["new curation"]);XCTAssertEqual(try store.get("target")?.favorite,true)
    }
    func testConcurrentInsertCannotBeOverwrittenAndDeleteCannotBeResurrected() throws {
        XCTAssertThrowsError(try store.importDecodedMemoriesDetailed([note("fresh"),note("target")],embedder:nil,policy:.init(),preparationProgress:{if $0==1 {try self.store.insert(self.note("target",text:"Concurrent insert"))}}))
        XCTAssertNil(try store.get("fresh"));XCTAssertEqual(try store.get("target")?.text,"Concurrent insert")
        XCTAssertThrowsError(try store.importDecodedMemoriesDetailed([note("fresh"),note("target")],embedder:nil,policy:.init(),preparationProgress:{if $0==1 {_ = try self.store.delete("target")}}))
        XCTAssertEqual(try store.stats().count,0)
    }
    func testConcurrentExternalRecapParentChangeRefusesWholeBatch() throws {
        let parent=note("external");try store.insert(parent);let child=recap(parent)
        XCTAssertThrowsError(try store.importDecodedMemoriesDetailed([note("fresh"),child],embedder:nil,policy:.init(),preparationProgress:{if $0==1 {try self.store.setTags(parent.id,tags:["Concurrent parent curation"])}}))
        XCTAssertNil(try store.get("fresh"));XCTAssertNil(try store.get(child.id));XCTAssertEqual(try store.get(parent.id)?.tags,["Concurrent parent curation"])
    }
    func testCancellationDuringPreparationPublishesNothingAndCanRetry() async throws {
        let store=self.store!,input=[note("one"),note("two")]
        let worker=Task.detached {try store.importDecodedMemoriesDetailed(input,embedder:nil,policy:.init(),preparationProgress:{_ in withUnsafeCurrentTask {$0?.cancel()}})}
        do {_ = try await worker.value;XCTFail("Cancelled preparation committed")} catch is CancellationError {} catch {throw error}
        XCTAssertEqual(try store.stats().count,0);XCTAssertEqual(try store.importDecodedMemoriesDetailed(input,embedder:nil,policy:.init()).imported,2)
    }
    func testSavedPrivacyChangeRollsBackSourcesAndRecapInvalidation() throws {
        let parent=note("parent",text:"Original"),child=recap(parent);try store.insert(parent);try store.insert(child)
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        XCTAssertThrowsError(try store.importDecodedMemoriesDetailed([note(parent.id,text:"Updated"),note("fresh")],embedder:nil,policy:snapshot.settings.privacy,settingsSnapshot:snapshot,preparationProgress:{if $0==1 {var settings=snapshot.settings;settings.privacy.excludedApps.append("Fixture");try settings.save(root:self.root)}})) {XCTAssertTrue($0.localizedDescription.contains("Saved settings changed"))}
        XCTAssertEqual(try store.get(parent.id)?.text,parent.text);XCTAssertNotNil(try store.get(child.id));XCTAssertNil(try store.get("fresh"))
    }
    func testIdenticalSettingsSaveAndPolicyABARefusePreparedImport() throws {
        try AppSettings().save(root:root)
        for aba in [false,true] {
            let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
            XCTAssertThrowsError(try store.importDecodedMemoriesDetailed([note("fresh")],embedder:nil,policy:snapshot.settings.privacy,settingsSnapshot:snapshot,preparationProgress:{_ in
                if aba {var changed=snapshot.settings;changed.privacy.redactSecrets.toggle();try changed.save(root:self.root)}
                try snapshot.settings.save(root:self.root)
            }))
            XCTAssertEqual(try store.stats().count,0)
        }
    }
    func testPreparationLeaseBlocksCloseAndWipeReservationsUntilPublication() throws {
        var observed=false
        XCTAssertEqual(try store.importDecodedMemoriesDetailed([note("fresh")],embedder:nil,policy:.init(),preparationProgress:{_ in
            observed=true
            XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:self.root,exclusive:true,timeout:0))
            XCTAssertFalse(self.store.isClosed)
        }).imported,1)
        XCTAssertTrue(observed);let exclusive=try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:0);exclusive.release()
        try store.close();XCTAssertThrowsError(try store.importDecodedMemoriesDetailed([note("later")],embedder:nil,policy:.init()))
    }
    func testRootReplacementDuringPreparationRefusesOriginalAndReplacement() throws {
        let moved=workspace.appendingPathComponent("retained-original")
        XCTAssertThrowsError(try store.importDecodedMemoriesDetailed([note("fresh")],embedder:nil,policy:.init(),preparationProgress:{_ in
            try FileManager.default.moveItem(at:self.root,to:moved);try Paths.ensure(self.root)
        }))
        XCTAssertEqual(try store.stats().count,0);let replacement=try MemoryStore(root:root);defer {try? replacement.close()};XCTAssertEqual(try replacement.stats().count,0)
    }
    func testAppleSourceAndPassageVectorsArePreparedBeforeWriterTransaction() throws {
        let embedder=LocalEmbedder();guard embedder.available else {throw XCTSkip("Apple English embedding asset is unavailable")}
        let source=note("long",text:String(repeating:"Owned desktop fixture remembers the Aurora launch. ",count:85))
        let result=try store.importDecodedMemoriesDetailed([source],embedder:embedder,policy:.init(),preparationProgress:{_ in
            try self.store.withRoutineDatabase {XCTAssertEqual(sqlite3_get_autocommit($0.handle),1)}
            XCTAssertNil(try self.store.get(source.id))
        })
        let saved=try XCTUnwrap(store.get(source.id));XCTAssertEqual(result.imported,1);XCTAssertEqual(saved.embeddingModel,embedder.modelID)
        XCTAssertTrue(try store.passagesCurrent(saved,modelID:embedder.modelID));XCTAssertNotNil(try store.embeddingDimensions(modelID:embedder.modelID))
    }
    func testExplicitPerRequestPolicyStillWorksWithoutSavedSettings() throws {
        var policy=PrivacyPolicy();policy.redactSecrets=false
        let source=note("explicit",text:"password=owned-fixture")
        XCTAssertEqual(try store.importJSONDetailed(data:JSONEncoder().encode([source]),policy:policy).imported,1)
        XCTAssertEqual(try store.get(source.id)?.text,source.text)
    }
}
