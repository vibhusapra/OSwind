import XCTest
@testable import OSwind
@testable import OSwindCore

@MainActor final class TextObservationModelTests:XCTestCase {
    func testAdmittedObservationUpdatesOnlyMatchingInspectorWithoutStartingCapture()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-observation-model-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let app=try AppModel(root:root,startServices:false);defer {app.prepareForLibrarySwitch();try? app.store.close()}
        app.settings.visualCaptureMode = .accessibility
        let first=Date(timeIntervalSince1970:1730611800)
        var memory=Memory(id:"owned-model-observation",timestamp:first,app:"Owned",text:"Owned words",display:"accessibility-window");memory.textObservation=TextObservationSpan();try app.store.insert(memory)
        app.selected=memory
        let reservation=try AccessibilityCaptureReservation(store:app.store,configuration:app.settings);defer {reservation.release()}
        let cursor=TextObservationCursor(id:memory.id,digest:try AccessibilityCaptureRecord.digest(memory),binding:Data(),first:first,last:first,uptime:1,span:try XCTUnwrap(memory.textObservation))
        let updated=try app.store.extendAccessibilityObservation(cursor,at:first.addingTimeInterval(5),reservation:reservation)
        app.capture.onObservation?(updated);XCTAssertEqual(app.selected?.textObservation?.samples,2);XCTAssertFalse(app.capture.running);XCTAssertFalse(app.audio.running)
        app.selected=nil;app.capture.onObservation?(updated);XCTAssertNil(app.selected)
        app.selected=Memory(id:"unrelated",text:"Different selected source");app.capture.onObservation?(updated);XCTAssertEqual(app.selected?.id,"unrelated")
    }
}
