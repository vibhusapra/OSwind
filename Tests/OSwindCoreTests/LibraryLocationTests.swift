import XCTest
@testable import OSwindCore

final class LibraryLocationTests: XCTestCase {
    var root: URL!, defaults: UserDefaults!, suite: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Paths.ensure(root)
        suite = "com.oswind.tests."+UUID().uuidString; defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defaults.removePersistentDomain(forName:suite)
    }
    override func tearDownWithError() throws { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
    func testMissingSelectedLibraryRequiresRecoveryAndNeverCreatesEmptyRoot() throws {
        let missing = root.appendingPathComponent("disconnected/library"); defaults.set(missing.path,forKey:LibraryLocationPreferences.key)
        let selected = LibraryLocationPreferences.selection(environment:[:],defaults:defaults)
        XCTAssertEqual(selected.origin,"selected"); XCTAssertTrue(selected.requiresExisting); XCTAssertThrowsError(try selected.validate())
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path)); XCTAssertThrowsError(try LibraryLocationPreferences.save(missing,defaults:defaults))
        XCTAssertEqual(defaults.string(forKey:LibraryLocationPreferences.key),missing.path)
    }
    func testExplicitEnvironmentDemoAndSelectedLibraryPrecedence() throws {
        let existing = root.appendingPathComponent("existing"); _ = try MemoryStore(root:existing)
        try LibraryLocationPreferences.save(existing,defaults:defaults)
        let selected = LibraryLocationPreferences.selection(environment:[:],defaults:defaults); try selected.validate(); XCTAssertEqual(selected.url.standardizedFileURL.resolvingSymlinksInPath(),existing.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(LibraryLocationPreferences.selection(environment:[:],demo:true,defaults:defaults).origin,"demo")
        let explicit = LibraryLocationPreferences.selection(environment:["OSWIND_DATA_DIR":root.appendingPathComponent("new-explicit").path],demo:true,defaults:defaults)
        XCTAssertEqual(explicit.origin,"environment"); XCTAssertFalse(explicit.requiresExisting); try explicit.validate()
        defaults.removeObject(forKey:LibraryLocationPreferences.key)
        XCTAssertEqual(LibraryLocationPreferences.selection(environment:[:],defaults:defaults).origin,"default")
    }
    func testBackupPackagesCannotBeSelectedAsLiveLibraries() throws {
        let package = root.appendingPathComponent("backup.oswindbackup"); _ = try MemoryStore(root:package)
        try Data("header".utf8).write(to:package.appendingPathComponent("header.json"))
        XCTAssertThrowsError(try LibraryLocationSelection(url:package,requiresExisting:true,origin:"selected").validate())
        XCTAssertThrowsError(try LibraryLocationPreferences.save(package,defaults:defaults)); XCTAssertNil(defaults.string(forKey:LibraryLocationPreferences.key))
        XCTAssertThrowsError(try LibraryLocationSelection(url:URL(string:"https://example.invalid/library")!,requiresExisting:false,origin:"invalid").validate())
    }
}
