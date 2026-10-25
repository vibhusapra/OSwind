import XCTest
@testable import OSwind
@testable import OSwindCore

@MainActor final class SearchNavigationTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-search-navigation-"+UUID().uuidString)
        app=try AppModel(root:root,startServices:false);app.mode = .keyword
        try app.store.insert(Memory(id:"linked-note",kind:.note,app:"Fixture",text:"release evidence"))
        try app.store.insert(Memory(id:"other-note",kind:.note,app:"Other",text:"release plan"))
        try app.store.insert(Memory(id:"audio",kind:.audio,app:"Fixture",text:"release conversation"))
    }
    override func tearDownWithError() throws {
        app.prepareForLibrarySwitch();try app.store.close();app=nil
        try? FileManager.default.removeItem(at:root)
    }
    func settle() async throws {
        // The host cannot complete a UI refresh while suspended; retain the same awake budget.
        let deadline=SuspendingClock.now.advanced(by:.seconds(3))
        while app.refreshing,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(app.refreshing);XCTAssertNil(app.errorMessage);XCTAssertNil(app.searchInputError)
    }
    func project()throws->MemoryEntity {
        let entity=try app.store.createEntity(kind:.project,name:"Release")
        try app.store.linkEntity(entity.id,to:"linked-note")
        return entity
    }
    func testShortcutFromPeopleReloadsGlobalResultsAfterProjectScopeClears() async throws {
        app.browseEntity(try project(),ask:false);try await settle()
        XCTAssertEqual(app.hits.map(\.id),["linked-note"])
        app.section="People & projects";app.refresh();try await settle();XCTAssertNil(app.entityScope)
        app.focusSearch();try await settle()
        XCTAssertEqual(app.section,"Memories");XCTAssertNotNil(app.searchFocusRequest)
        XCTAssertNil(app.entityScope);XCTAssertEqual(Set(app.hits.map(\.id)),["linked-note","other-note","audio"])
    }
    func testShortcutDropsConversationOnlyFilterWithoutChangingQuery() async throws {
        app.section="Conversations";app.query="release";app.refresh();try await settle()
        XCTAssertEqual(app.hits.map(\.id),["audio"])
        app.focusSearch();try await settle()
        XCTAssertEqual(app.query,"release");XCTAssertNil(app.filter.kind)
        XCTAssertEqual(Set(app.hits.map(\.id)),["linked-note","other-note","audio"])
    }
    func testShortcutAlreadyInMemoriesFindsNewSourcesWithoutQueryChange() async throws {
        app.query="release";app.refresh();try await settle()
        try app.store.insert(Memory(id:"new",kind:.note,text:"release update"))
        app.focusSearch();try await settle()
        XCTAssertEqual(app.query,"release");XCTAssertTrue(app.hits.contains {$0.id=="new"})
    }
    func testShortcutFromAskPreservesExplicitProjectAndAppFilters() async throws {
        let entity=try project();app.browseEntity(entity,ask:true);app.appFilter="Fixture";app.query="release"
        app.focusSearch();try await settle()
        XCTAssertEqual(app.section,"Memories");XCTAssertEqual(app.filter.entityID,entity.id)
        XCTAssertEqual(app.appFilter,"Fixture");XCTAssertEqual(app.query,"release");XCTAssertEqual(app.mode,.keyword)
        XCTAssertEqual(app.hits.map(\.id),["linked-note"])
    }
}
