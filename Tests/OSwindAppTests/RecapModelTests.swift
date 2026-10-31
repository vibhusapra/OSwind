import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class RecapModelTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);app=try AppModel(root:root,startServices:false)}
    override func tearDownWithError() throws {app.prepareForLibrarySwitch();app=nil;try? FileManager.default.removeItem(at:root)}
    func source() throws -> Memory {let m=Memory(id:"parent",bundleID:"com.oswind.fixture.original",title:"Original",text:"Maya owns release.");try app.store.insert(m);return m}
    func answer(_ m:Memory)->Answer {.init(text:"Maya owns release [1].",sources:[.init(memory:m,score:1,match:"fixture",passage:PassageRange(start:0,length:4))],provider:"fixture",duration:0)}
    func testNativeJSONImportReportsPrivacyOmissionsAndGuardsBusyState() async throws {
        let parent=try source(),recap=try app.store.saveRecap(answer(parent)),file=root.appendingPathComponent("import.json")
        try app.store.delete(parent.id)
        try JSONEncoder().encode([parent,recap]).write(to:file)
        app.settings.privacy.excludedApps=[parent.bundleID]
        app.importJSONFile(file);XCTAssertTrue(app.importingJSON);app.importJSONFile(file)
        for _ in 0..<1000 where app.importingJSON {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertFalse(app.importingJSON);XCTAssertNil(app.errorMessage)
        XCTAssertTrue(app.importStatus.contains("1 excluded"));XCTAssertTrue(app.importStatus.contains("1 linked recaps omitted"))
        XCTAssertEqual(try app.store.stats().count,0)
    }
    func testLibrarySwitchPreventsLateRecapAndImportPublicationInOldModel() async throws {
        let parent=try source(),file=root.appendingPathComponent("switch.json");try JSONEncoder().encode([parent]).write(to:file)
        app.answer=answer(parent);app.saveAnswer();app.importJSONFile(file);app.prepareForLibrarySwitch()
        for _ in 0..<1000 where app.savingRecap || app.importingJSON {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertFalse(app.savingRecap);XCTAssertFalse(app.importingJSON)
        XCTAssertEqual(app.recapSaveStatus,"Saving a source-linked recap…");XCTAssertFalse(app.importStatus.hasPrefix("Imported"));XCTAssertNil(app.selected)
    }
    func testNativeSaveUsesLinkedStorePathAndDoesNotDuplicateWhileBusy() async throws {
        let m=try source();app.answer=answer(m);app.saveAnswer();XCTAssertTrue(app.savingRecap);app.saveAnswer()
        for _ in 0..<500 where app.savingRecap {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertFalse(app.savingRecap);XCTAssertNil(app.errorMessage)
        let summaries=try app.store.search(.init(kind:.summary),mode:.keyword);XCTAssertEqual(summaries.count,1);XCTAssertEqual(summaries[0].memory.recap?.sources[0].id,m.id)
    }
    func testDetailWatcherClosesAfterAnotherConnectionErasesOriginal() async throws {
        let parent=try source(),recap=try app.store.saveRecap(answer(parent)),detail=RecapDetailModel();var closed=false
        detail.watch(recap,store:app.store,interval:1_000_000) {closed=true}
        for _ in 0..<500 where detail.sources.isEmpty {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertEqual(detail.sources.first?.id,parent.id)
        let other=try MemoryStore(root:root);try other.delete(parent.id)
        for _ in 0..<500 where !closed {try await Task.sleep(nanoseconds:1_000_000)}
        detail.stop();XCTAssertTrue(closed);XCTAssertTrue(detail.sources.isEmpty)
    }
    func testOriginalCardOpensCurrentSourceAndRejectsStaleRevision() async throws {
        let parent=try source(),recap=try app.store.saveRecap(answer(parent)),card=try XCTUnwrap(app.store.recapSourceCards(recap.id).first)
        app.openRecapSource(card)
        for _ in 0..<500 where app.openingMemoryID != nil {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertEqual(app.selected?.id,parent.id);XCTAssertEqual(app.selectedPassage,card.passage)
        app.selected=nil;var changed=parent;changed.text="Changed";try app.store.insert(changed);app.openRecapSource(card)
        for _ in 0..<500 where app.openingMemoryID != nil {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertNil(app.selected);XCTAssertNotNil(app.errorMessage)
    }
    func historicalRecap() throws -> (Memory,Memory) {
        let origin="00000000-0000-0000-0000-000000004101"
        let original=Memory(id:"parent",kind:.note,app:"Owned",title:"Original",text:"Maya owns original release.")
        try app.store.insert(Memory(id:"parent",kind:.note,app:"Owned",title:"Current",text:"New current source"))
        let body=try SyncSourceBody(memory:original,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No parent")}
        let record=try SyncPortableRecord(identity:.init(table:.source,origin:origin,lifetime:UUID().uuidString.lowercased()),body:.source(body))
        return try app.store.withRoutineDatabase {db in
            let history=HistoricalEvidenceStore(database:db),parentHandle=UUID().uuidString.lowercased()
            try history.insert(handle:parentHandle,source:"parent",record:record,paths:[:],parents:[])
            let parent=try history.read(parentHandle,verifyMedia:{_,_,_ in})
            var recap=Memory(id:"recap",kind:.summary,app:"Owned",title:"Original recap",text:"Maya owns release [1].")
            recap.recap = .init(provider:"owned",sources:[.init(id:parent.sourceID,revision:parent.memory.evidenceHash,match:"owned",score:1,passage:.init(start:0,length:4))])
            let recapBody=try SyncSourceBody(memory:recap,origin:origin,media:[]) {_,_ in try parent.reference}
            let recapRecord=try SyncPortableRecord(identity:.init(table:.source,origin:origin,lifetime:UUID().uuidString.lowercased()),body:.source(recapBody))
            try app.store.insert(Memory(id:"recap",kind:.summary,text:"Changed current recap"))
            let handle=UUID().uuidString.lowercased();try history.insert(handle:handle,source:"recap",record:recapRecord,paths:[:],parents:[parent])
            return(try history.read(handle,verifyMedia:{_,_,_ in}).memory,parent.memory)
        }
    }
    func testHistoricalRecapWatcherUsesExactCardsAndClosesWhenAncestorIsErased() async throws {
        let (recap,parent)=try historicalRecap(),detail=RecapDetailModel();var closed=false
        detail.watch(recap,store:app.store,interval:1_000_000) {closed=true}
        for _ in 0..<500 where detail.sources.isEmpty {try await Task.sleep(nanoseconds:1_000_000)}
        let card=try XCTUnwrap(detail.sources.first);XCTAssertEqual(card.id,parent.id);XCTAssertEqual(card.historicalHandle,parent.originalEvidence?.handle)
        app.openRecapSource(card)
        for _ in 0..<500 where app.openingMemoryID != nil {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertEqual(app.selected,parent);XCTAssertNil(app.errorMessage)
        let other=try MemoryStore(root:root);defer {try? other.close()};_=try other.delete("parent")
        for _ in 0..<500 where !closed {try await Task.sleep(nanoseconds:1_000_000)}
        detail.stop();XCTAssertTrue(closed);XCTAssertTrue(detail.sources.isEmpty)
        app.selected=nil;app.openRecapSource(card)
        for _ in 0..<500 where app.openingMemoryID != nil {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertNil(app.selected);XCTAssertNotNil(app.errorMessage)
    }
    func testHistoricalNativeActionsRefuseToModifyOrDeleteCanonicalOwner() throws {
        let (_,original)=try historicalRecap(),before=try XCTUnwrap(app.store.get("parent"))
        app.favorite(original);XCTAssertEqual(try app.store.get("parent"),before);XCTAssertNotNil(app.errorMessage)
        app.errorMessage=nil;app.delete(original);XCTAssertNil(app.deletingID);XCTAssertEqual(try app.store.get("parent"),before)
        XCTAssertEqual(try app.store.historicalMemory(XCTUnwrap(original.originalEvidence).handle),original);XCTAssertNotNil(app.errorMessage)
    }

    func testHistoricalTextSelectionClosesOnExternalErasureAndLibrarySwitchCancelsWatcher() async throws {
        let (_,original)=try historicalRecap();app.selected=original;app.watchSelectedOriginal(interval:1_000_000)
        let other=try MemoryStore(root:root);defer {try? other.close()};_=try other.delete("parent")
        for _ in 0..<500 where app.selected != nil {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertNil(app.selected);XCTAssertTrue(app.deletionStatus?.contains("original")==true)
        app.prepareForLibrarySwitch();XCTAssertNil(app.selected)
    }

}
