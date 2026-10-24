import XCTest
import OSwindCore
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
}
