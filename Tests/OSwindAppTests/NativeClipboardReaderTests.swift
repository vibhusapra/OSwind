import XCTest
import AppKit
@testable import OSwind
@testable import OSwindCore

final class ClipboardOwnedLazyProvider:NSObject,NSPasteboardItemDataProvider,@unchecked Sendable {
    private let lock=NSLock();private var calls=0
    var reads:Int {lock.lock();defer {lock.unlock()};return calls}
    func pasteboard(_ pasteboard:NSPasteboard?,item:NSPasteboardItem,provideDataForType type:NSPasteboard.PasteboardType) {
        lock.lock();calls+=1;lock.unlock();item.setString("Owned lazy text that must not be requested",forType:type)
    }
}

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
        let snapshot=try await reader.read(try XCTUnwrap(probe.changeCount),"org.oswind.foreground")
        XCTAssertEqual(snapshot.text,Data(text.utf8));XCTAssertEqual(snapshot.changeCount,snapshot.finalChangeCount);XCTAssertEqual(snapshot.itemCount,1)
    }
    func testActualNamedBoardConfidentialMarkerAndChangedCounterRefuse()async throws {
        let pasteboard=try board();defer {pasteboard.releaseGlobally()};pasteboard.clearContents()
        let item=NSPasteboardItem();item.setString("Owned protected fixture",forType:.string);item.setData(Data(),forType:.init("org.nspasteboard.ConcealedType"));XCTAssertTrue(pasteboard.writeObjects([item]))
        let reader=try NativeClipboardBackend(ownedName:pasteboard.name.rawValue).reader,count=pasteboard.changeCount
        do {_ = try await reader.read(count,"org.oswind.foreground");XCTFail("Confidential board was admitted")}catch is ClipboardObservationSkip {}catch {XCTFail("Unexpected error: \(error)")}
        pasteboard.clearContents();XCTAssertTrue(pasteboard.setString("Owned replacement",forType:.string))
        do {_ = try await reader.read(count,"org.oswind.foreground");XCTFail("Changed board was admitted")}catch is ClipboardObservationSkip {}catch {XCTFail("Unexpected error: \(error)")}
    }
    func testMismatchedSourceIsRefusedBeforeLazyTextProviderRuns()async throws {
        let pasteboard=try board();defer {pasteboard.releaseGlobally()};pasteboard.clearContents()
        let provider=ClipboardOwnedLazyProvider(),item=NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider,forTypes:[.string]));XCTAssertTrue(item.setString("org.oswind.different-source",forType:.init("org.nspasteboard.source")));XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertEqual(provider.reads,0,"The owned lazy fixture must be cold before the reader")
        let reader=try NativeClipboardBackend(ownedName:pasteboard.name.rawValue).reader,context=WindowContext(app:"Owned app",bundle:"org.oswind.foreground",pid:123,title:"Owned window",url:nil,accessibilityText:"",secure:false)
        do {
            let snapshot=try await reader.read(pasteboard.changeCount,context.bundle)
            _ = try ClipboardTextDraft(snapshot:snapshot,before:context,after:context,sessionID:UUID().uuidString.lowercased(),at:Date(),elapsedSeconds:0.01,policy:PrivacyPolicy())
            XCTFail("Mismatched source claim was admitted")
        }catch is ClipboardObservationSkip {}catch {XCTFail("Unexpected error: \(error)")}
        XCTAssertEqual(provider.reads,0,"A mismatched source must refuse before fetching plain text")
    }
}
