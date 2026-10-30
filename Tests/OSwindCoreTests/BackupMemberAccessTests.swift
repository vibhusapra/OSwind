import XCTest
import Darwin
@testable import OSwindCore

final class BackupMemberAccessTests:XCTestCase {
    private var root:URL!,source:URL!,tree:BackupFileTree!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-member-"+UUID().uuidString)
        source=root.appendingPathComponent("source");try Paths.ensure(source);tree=try BackupFileTree(root:source)
    }
    override func tearDownWithError() throws {tree=nil;try FileManager.default.removeItem(at:root)}
    private func missing(_ name:String)throws->BackupMemberAccess {
        do {_ = try tree.read(name,limit:64);throw OSwindError.invalid("Missing member was read")}
        catch BackupFileError.missing(let message,let access) {
            XCTAssertEqual(message,"Cannot read backup member: missing file")
            return try XCTUnwrap(access)
        }
    }
    func testKnownRootMetadataProvidesSafeFailureIdentity() throws {
        for (name,kind) in [("oswind-vault.json",BackupMemberAccess.Member.vaultManifest),("session.json",.vaultSession),(".oswind-vault-library.json",.vaultLibraryMarker),("memory.sqlite",.memoryDatabase),("settings.json",.settings)] {
            let access=try missing(name)
            XCTAssertEqual(access.member,kind);XCTAssertEqual(access.code,ENOENT)
            XCTAssertTrue(access.rootDescriptorMatchesInitial);XCTAssertTrue(access.parentDescriptorIsDirectory)
            XCTAssertEqual(access.parentMatchesInitialRoot,true);XCTAssertTrue(access.namedRootMatchesInitial)
        }
    }
    func testUnknownNamesAndPathsNeverAppearInErrorOrDiagnostic() throws {
        let privateName="PRIVATE-HISTORY-CREDENTIAL-example",access=try missing(privateName)
        XCTAssertEqual(access.member,.other)
        let json=String(decoding:try JSONEncoder().encode(access),as:UTF8.self)
        do {_ = try tree.read(privateName,limit:64);XCTFail("Missing member was read")}
        catch {
            for text in [error.localizedDescription,String(describing:error),String(reflecting:error),json] {
                XCTAssertFalse(text.contains(privateName));XCTAssertFalse(text.contains(root.path));XCTAssertFalse(text.contains("oswind-owned-member-"))
            }
        }
    }
    func testRetainedRootLookupReportsReplacementWithoutReadingIt() throws {
        let moved=root.appendingPathComponent("retained");try FileManager.default.moveItem(at:source,to:moved);try Paths.ensure(source)
        try Data("Replacement must not be read".utf8).write(to:source.appendingPathComponent("settings.json"))
        let access=try missing("settings.json")
        XCTAssertTrue(access.rootDescriptorMatchesInitial);XCTAssertEqual(access.parentMatchesInitialRoot,true)
        XCTAssertFalse(access.namedRootMatchesInitial)
    }
    func testNestedLookupDoesNotMislabelUnknownPathsAndOptionalSessionsStayMissing() throws {
        try Paths.ensure(source.appendingPathComponent("nested"))
        let access=try missing("nested/session.json")
        XCTAssertEqual(access.member,.other);XCTAssertNil(access.parentMatchesInitialRoot)
        let paths=try VaultPaths(source),info=LibraryVaultInfo(name:"Owned fixture",capacityGiB:1,volumeUUID:"00000000-0000-0000-0000-000000000000")
        XCTAssertNil(try paths.session(info:info),"Enriched errors retain the optional-session missing classification")
    }
}
