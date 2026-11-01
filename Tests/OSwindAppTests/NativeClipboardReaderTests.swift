import XCTest
import AppKit
@testable import OSwind
@testable import OSwindCore

@MainActor final class NativeClipboardReaderTests:XCTestCase {
    func board()throws->NSPasteboard {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_CLIPBOARD"]=="1" else {throw XCTSkip("Opt-in owned named-pasteboard check; no general clipboard access")}
        return NSPasteboard(name:.init("org.oswind.owned.clipboard."+UUID().uuidString.lowercased()))
    }
    func testActualNamedBoardReturnsExactUTF8WithoutOpeningGeneralClipboard()async throws {
        let pasteboard=try board();defer {pasteboard.releaseGlobally()};pasteboard.clearContents()
        let text="Owned café 日本語 e\u{301} 🧠 clipboard fixture";XCTAssertTrue(pasteboard.setString(text,forType:.string))
        let reader=try NativeClipboardBackend(ownedName:pasteboard.name.rawValue).reader,probe=try await reader.probe()
        XCTAssertEqual(probe.access,.allowed);XCTAssertEqual(probe.changeCount,pasteboard.changeCount)
        let snapshot=try await reader.read(try XCTUnwrap(probe.changeCount))
        XCTAssertEqual(snapshot.text,Data(text.utf8));XCTAssertEqual(snapshot.changeCount,snapshot.finalChangeCount);XCTAssertEqual(snapshot.itemCount,1)
    }
    func testActualNamedBoardConfidentialMarkerAndChangedCounterRefuse()async throws {
        let pasteboard=try board();defer {pasteboard.releaseGlobally()};pasteboard.clearContents()
        let item=NSPasteboardItem();item.setString("Owned protected fixture",forType:.string);item.setData(Data(),forType:.init("org.nspasteboard.ConcealedType"));XCTAssertTrue(pasteboard.writeObjects([item]))
        let reader=try NativeClipboardBackend(ownedName:pasteboard.name.rawValue).reader,count=pasteboard.changeCount
        do {_ = try await reader.read(count);XCTFail("Confidential board was admitted")}catch is ClipboardObservationSkip {}catch {XCTFail("Unexpected error: \(error)")}
        pasteboard.clearContents();XCTAssertTrue(pasteboard.setString("Owned replacement",forType:.string))
        do {_ = try await reader.read(count);XCTFail("Changed board was admitted")}catch is ClipboardObservationSkip {}catch {XCTFail("Unexpected error: \(error)")}
    }
}
