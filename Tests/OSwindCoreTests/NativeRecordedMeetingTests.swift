import XCTest
@testable import OSwindCore

final class NativeRecordedMeetingTests:XCTestCase {
    func testRetainedMetadataPageDoesNotPinOwnedEncryptedImageAfterStoreClose()async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Explicit owned encrypted recording metadata fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recorded-meeting-vault-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Owned.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        var active:MemoryStore?
        do {
            _=try await LibraryVault.create(at:package,name:"Owned recorded meeting",capacityGiB:1,passphrase:secret)
            _=try await vault.unlock(passphrase:secret);let store=try MemoryStore(root:vault.libraryURL);active=store
            var memory=Memory(id:"owned-audio",timestamp:Date(timeIntervalSince1970:1_793_738_000),kind:.audio,app:"Owned fixture",title:"Retained metadata",text:"Authored encrypted audio source")
            memory.audioSessionID="owned-session";memory.transcript = .init(text:memory.text,duration:30,segments:[.init(start:0,end:30,text:memory.text)],model:"Authored fixture");try store.insert(memory)
            let page=try store.recordedMeetingPage();XCTAssertEqual(page.sources.count,1)
            try store.close();active=nil
            let closed=try await vault.lock();XCTAssertEqual(closed.state,.locked);XCTAssertFalse(closed.imageAttached)
            XCTAssertEqual(page.sources.first?.memoryID,"owned-audio","Retaining the value page must not pin a vault descriptor")
            XCTAssertThrowsError(try store.withCurrentRecordedMeetingPage(page) {})
            let verified=try await vault.status();XCTAssertEqual(verified.state,.locked);XCTAssertFalse(verified.imageAttached)
            try FileManager.default.removeItem(at:root)
        }catch {try? active?.close();_=try? await vault.lock();throw error}
    }
}
