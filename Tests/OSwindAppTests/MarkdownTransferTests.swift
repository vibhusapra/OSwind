import XCTest
import OSwindCore
@testable import OSwind

final class MarkdownTransferTests: XCTestCase {
    @MainActor func testDetachedExportCompletesAndErrorsPreservePublishedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Paths.ensure(root); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root.appendingPathComponent("library")), output = root.appendingPathComponent("Markdown"), transfer = LibraryTransferModel()
        try store.insert(Memory(text:"Synthetic transfer"))
        transfer.exportMarkdown(store:store,destination:output,policy:PrivacyPolicy(),includeMedia:false)
        XCTAssertTrue(transfer.busy); XCTAssertTrue(transfer.markdownOperation)
        for _ in 0..<200 where transfer.busy { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(transfer.busy); XCTAssertNil(transfer.error); XCTAssertEqual(transfer.markdownFolder,output)
        let index = try Data(contentsOf:output.appendingPathComponent("index.md"))
        transfer.exportMarkdown(store:store,destination:output,policy:PrivacyPolicy(),includeMedia:false)
        for _ in 0..<200 where transfer.busy { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(transfer.busy); XCTAssertNotNil(transfer.error); XCTAssertNil(transfer.markdownFolder)
        XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("index.md")),index)
    }
    @MainActor func testImmediateCancelAndSecondOperationGuard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Paths.ensure(root); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root.appendingPathComponent("library")), output = root.appendingPathComponent("Cancelled"), other = root.appendingPathComponent("Must not start"), transfer = LibraryTransferModel()
        for i in 0..<100 { try store.insert(Memory(id:"\(i)",text:String(repeating:"Synthetic ",count:1000))) }
        transfer.exportMarkdown(store:store,destination:output,policy:PrivacyPolicy(),includeMedia:false)
        transfer.exportMarkdown(store:store,destination:other,policy:PrivacyPolicy(),includeMedia:false)
        transfer.cancel()
        for _ in 0..<200 where transfer.busy { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(transfer.busy); XCTAssertNil(transfer.markdownFolder); XCTAssertNil(transfer.error)
        XCTAssertTrue(transfer.status.hasPrefix("Cancelled")); XCTAssertFalse(FileManager.default.fileExists(atPath:output.path)); XCTAssertFalse(FileManager.default.fileExists(atPath:other.path))
    }
}
