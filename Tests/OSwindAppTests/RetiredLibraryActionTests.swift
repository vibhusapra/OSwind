import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class RetiredLibraryActionTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-retired-action-"+UUID().uuidString);app=try AppModel(root:root,startServices:false)
        app.settings.captureOnLaunch=false;app.settings.apiEnabled=false;app.settings.routinesEnabled=false;app.settings.automaticMaintenance=false
        app.settings.entityAutomaticIndex=false;app.settings.search.visual.enabled=false;app.showOnboarding=false
        try app.store.insert(Memory(id:"owned",text:"An authored source for retired action checks"))
    }
    override func tearDown()async throws {
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();app=nil;try? FileManager.default.removeItem(at:root)
    }
    func ready()async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while app.hasPendingStatistics || app.refreshing,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.hasPendingStatistics);XCTAssertFalse(app.refreshing)
    }
    func testRetiredFavoriteActionCannotWriteOldLibrary()async throws {
        try await ready();let source=try XCTUnwrap(app.store.get("owned"));app.prepareForLibrarySwitch();app.favorite(source)
        XCTAssertFalse(try XCTUnwrap(app.store.get("owned")).favorite)
    }
    func testRetiredChatActionCannotDeleteOldConversation()async throws {
        try await ready();let chat=try app.store.createChat();app.currentChatID=chat.id;app.prepareForLibrarySwitch();app.deleteCurrentChat()
        XCTAssertNotNil(try app.store.chat(chat.id))
    }
    func testRetiredAPIActionCannotStartOrRelabelListener()async throws {
        try await ready();app.prepareForLibrarySwitch();app.startAPI();try await Task.sleep(for:.milliseconds(100))
        XCTAssertTrue(app.apiStatus=="API off","A retired action must neither start nor attempt to relabel its listener")
    }
    func testRetiredRefreshCannotStartNewQuery()async throws {
        try await ready();app.prepareForLibrarySwitch();app.refresh(forceStatistics:true)
        XCTAssertFalse(app.refreshing)
    }
    func testRetiredSourceOpenCannotLoadAndPublishOldSelection()async throws {
        try await ready();let source=try XCTUnwrap(app.store.get("owned"));app.prepareForLibrarySwitch();app.openMemory(source,query:"owned")
        XCTAssertNil(app.openingMemoryID)
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while app.openingMemoryID != nil,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertNil(app.selected)
    }
}
