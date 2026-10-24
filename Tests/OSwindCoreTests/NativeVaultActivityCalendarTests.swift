import XCTest
@testable import OSwindCore

final class NativeVaultActivityCalendarTests:XCTestCase {
    func testRetainedCalendarValueCannotPinEncryptedDeviceOrQueryClosedStore() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned encrypted calendar fixture; no normal history or Keychain")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-calendar-vault-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Calendar.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package)
        do {
            _ = try await LibraryVault.create(at:package,name:"Owned calendar fixture",capacityGiB:1,passphrase:secret)
            _ = try await vault.unlock(passphrase:secret);let store=try MemoryStore(root:vault.libraryURL)
            try store.insert(Memory(id:"owned",timestamp:try QueryScopeResolver.instant("2024-11-03T01:30:00-04:00"),text:"Owned synthetic source"))
            let request=ActivityCalendarRequest(month:"2024-11",timeZone:TimeZone(identifier:"America/New_York")!,selectedDay:"2024-11-03")
            let snapshot=try await Integration.activity(request,store:store);XCTAssertEqual(snapshot.totalSources,1);XCTAssertEqual(snapshot.hours.count,25)
            let locked=try await vault.lock(store:store);XCTAssertEqual(locked.state,.locked);XCTAssertTrue(store.isClosed)
            let attached=try await NativeVaultDriver().attachment(paths:VaultPaths(package));XCTAssertNil(attached)
            XCTAssertEqual(snapshot.totalSources,1) // Plain value remains retained; no descriptor or database handle.
            XCTAssertThrowsError(try store.activityCalendar(request));XCTAssertThrowsError(try store.activityCalendarRevision())
            _ = try await vault.unlock(passphrase:secret);let reopened=try MemoryStore(root:vault.libraryURL)
            XCTAssertEqual(try reopened.activityCalendar(request),snapshot)
            _ = try await vault.lock(store:reopened);try FileManager.default.removeItem(at:root)
        } catch {_ = try? await vault.lock();throw error}
    }
}
