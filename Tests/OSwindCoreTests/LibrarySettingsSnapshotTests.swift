import XCTest
import Darwin
@testable import OSwindCore

final class LibrarySettingsSnapshotTests:XCTestCase {
    var root:URL!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-settings-snapshot-"+UUID().uuidString);try Paths.ensure(root)}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    func testAbsentSettingsUsesDefaultsAndFirstSaveInvalidatesIt() throws {
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        XCTAssertEqual(snapshot.settings,AppSettings());XCTAssertEqual(try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {42},42)
        try AppSettings().save(root:root);XCTAssertThrowsError(try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {})
    }
    func testRoundTripPrivateFileAndNoPreparationLock() throws {
        var settings=AppSettings();settings.privacy.excludedApps.append("dev.example.fixture");try settings.save(root:root)
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()};XCTAssertEqual(snapshot.settings,settings)
        try snapshot.withCurrent(root:root,policy:settings.privacy) {}
        // A retained snapshot does not block ordinary saves during preparation.
        try settings.save(root:root);XCTAssertThrowsError(try snapshot.withCurrent(root:root,policy:settings.privacy) {})
        let attributes=try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("settings.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testMalformedExistingSettingsNeverFallsBackToDefaults() throws {
        let file=root.appendingPathComponent("settings.json");try Data("{broken".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        XCTAssertThrowsError(try LibrarySettingsSnapshot.capture(root:root)) {XCTAssertTrue($0.localizedDescription.contains("malformed"))}
    }
    func testSymlinkHardlinkDirectoryFIFOAndOversizeSettingsRefuse() throws {
        let file=root.appendingPathComponent("settings.json"),other=root.appendingPathComponent("other.json")
        try JSONEncoder().encode(AppSettings()).write(to:other);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:other.path)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:other);XCTAssertThrowsError(try LibrarySettingsSnapshot.capture(root:root));XCTAssertThrowsError(try AppSettings().save(root:root));try FileManager.default.removeItem(at:file)
        XCTAssertEqual(link(other.path,file.path),0);XCTAssertThrowsError(try LibrarySettingsSnapshot.capture(root:root));XCTAssertThrowsError(try AppSettings().save(root:root));try FileManager.default.removeItem(at:file)
        try Paths.ensure(file);XCTAssertThrowsError(try LibrarySettingsSnapshot.capture(root:root));try FileManager.default.removeItem(at:file)
        XCTAssertEqual(mkfifo(file.path,0o600),0);XCTAssertThrowsError(try LibrarySettingsSnapshot.capture(root:root));try FileManager.default.removeItem(at:file)
        try Data(repeating:32,count:SettingsFileAccess.maximumBytes+1).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        XCTAssertThrowsError(try LibrarySettingsSnapshot.capture(root:root))
    }
    func testReleaseWrongPolicyAndWrongRootRefuse() throws {
        let snapshot=try LibrarySettingsSnapshot.capture(root:root)
        var policy=snapshot.settings.privacy;policy.redactSecrets.toggle()
        XCTAssertThrowsError(try snapshot.withCurrent(root:root,policy:policy) {})
        let other=root.appendingPathComponent("other");try Paths.ensure(other)
        XCTAssertThrowsError(try snapshot.withCurrent(root:other,policy:snapshot.settings.privacy) {})
        snapshot.release();snapshot.release();XCTAssertThrowsError(try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {})
    }
    func testRemovalAndInPlaceEditInvalidateSnapshot() throws {
        try AppSettings().save(root:root);let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        let file=root.appendingPathComponent("settings.json"),original=try Data(contentsOf:file)
        var changed=snapshot.settings;changed.privacy.redactSecrets.toggle();try JSONEncoder().encode(changed).write(to:file)
        XCTAssertThrowsError(try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {})
        try original.write(to:file);try FileManager.default.removeItem(at:file)
        XCTAssertThrowsError(try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {})
    }
    func testFinalCheckHoldsSharedLockThroughPublicationAndWriterCanRetry() throws {
        let snapshot=try LibrarySettingsSnapshot.capture(root:root);defer {snapshot.release()}
        try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {
            XCTAssertThrowsError(try AppSettings().save(root:root)) {XCTAssertTrue($0.localizedDescription.contains("Settings are busy"))}
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("settings.json").path))
        }
        try AppSettings().save(root:root)
        XCTAssertThrowsError(try snapshot.withCurrent(root:root,policy:snapshot.settings.privacy) {})
    }
    func testLockSymlinkAndPublicLockRefuse() throws {
        let file=root.appendingPathComponent(".settings-admission.lock"),other=root.appendingPathComponent("other")
        try Data().write(to:other);try FileManager.default.createSymbolicLink(at:file,withDestinationURL:other)
        XCTAssertThrowsError(try LibrarySettingsSnapshot.capture(root:root));XCTAssertThrowsError(try AppSettings().save(root:root));try FileManager.default.removeItem(at:file)
        try Data().write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:file.path)
        XCTAssertThrowsError(try LibrarySettingsSnapshot.capture(root:root));XCTAssertThrowsError(try AppSettings().save(root:root))
    }
}
