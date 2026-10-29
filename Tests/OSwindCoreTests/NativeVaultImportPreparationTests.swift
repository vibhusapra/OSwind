import XCTest
@testable import OSwindCore

final class NativeVaultImportPreparationTests:XCTestCase {
    func testSettingsAndImportReservationsReleaseBeforeVerifiedDetach() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned encrypted import fixture; no normal history or Keychain")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-import-vault-"+UUID().uuidString)
        try Paths.ensure(root);let package=root.appendingPathComponent("Import.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        var active:MemoryStore?
        do {
            _ = try await LibraryVault.create(at:package,name:"Owned import fixture",capacityGiB:1,passphrase:secret)
            _ = try await vault.unlock(passphrase:secret);let store=try MemoryStore(root:vault.libraryURL);active=store
            try AppSettings().save(root:store.root)
            let snapshot=try LibrarySettingsSnapshot.capture(root:store.root);defer {snapshot.release()}
            let original=Memory(id:"owned-import",kind:.note,text:"Owned encrypted import")
            let result=try store.importJSONDetailed(data:JSONEncoder().encode([original]),policy:snapshot.settings.privacy,settingsSnapshot:snapshot)
            XCTAssertEqual(result.imported,1);snapshot.release()
            // Deliberately retain the released snapshot object while detaching.
            let locked=try await vault.lock(store:store);active=nil;XCTAssertEqual(locked.state,.locked);XCTAssertTrue(store.isClosed)
            _ = try await vault.unlock(passphrase:secret);let reopened=try MemoryStore(root:vault.libraryURL);active=reopened
            XCTAssertEqual(try reopened.get(original.id),original)
            _ = try await vault.lock(store:reopened);active=nil;try FileManager.default.removeItem(at:root)
        } catch {try? active?.close();_ = try? await vault.lock();throw error}
    }
}
