import XCTest
@testable import OSwindCore

final class NativeVaultMigrationTests:XCTestCase {
    func runFixture(_ body:(URL,MemoryStore,URL,Data) async throws -> Void) async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Opt in to owned encrypted APFS migration; original library and credentials are synthetic")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-vault-migration-"+UUID().uuidString);try Paths.ensure(root)
        let source=try MemoryStore(root:root.appendingPathComponent("Original")),package=root.appendingPathComponent("Encrypted.oswindvault"),secret=Data(UUID().uuidString.utf8)
        try source.insert(Memory(id:"original",text:"Original synthetic history"))
        do {try await body(root,source,package,secret);try source.close();if FileManager.default.fileExists(atPath:package.path) {let attachment=try await NativeVaultDriver().attachment(paths:VaultPaths(package));XCTAssertNil(attachment);guard attachment==nil else {throw OSwindError.invalid("Owned fixture remained attached")}};try FileManager.default.removeItem(at:root)}
        catch {try? source.close();if let vault=try? LibraryVault(package:package) {_=try? await vault.lock()};throw error}
    }
    func testHistoryMediaVectorsChatsSettingsAndOriginalSurviveCopy() async throws {
        try await runFixture {root,source,package,secret in
            let media=Data("Owned synthetic retained bytes".utf8);try Paths.ensure(source.root.appendingPathComponent("audio"));try media.write(to:source.root.appendingPathComponent("audio/fixture.wav"))
            let note=Memory(id:"media",text:"Synthetic media evidence",audioPath:"audio/fixture.wav");try source.insert(note);_=try source.saveVectors([VectorRecord(memory:note,vector:[1,0])],modelID:"fixture")
            let chat=try source.createChat();_=try source.appendChatTurn(sessionID:chat.id,question:"What was saved?",answer:Answer(text:"Synthetic media [1]",sources:[SearchHit(memory:note,score:1,match:"semantic")],provider:"evidence",duration:0))
            var settings=AppSettings();settings.profile = .light;settings.apiEnabled=true;try settings.save(root:source.root)
            let proof=MigrationObservations(package:package)
            let result=try await LibraryVault.migrate(from:source,to:package,name:"Synthetic copy",capacityGiB:1,passphrase:secret,progress:{proof.observe($0)})
            XCTAssertTrue(result.sourceStable);XCTAssertTrue(result.originalRetained);XCTAssertEqual(result.snapshot.memories,2);XCTAssertEqual(result.snapshot.turns,1);XCTAssertEqual(result.snapshot.mediaFiles,1);XCTAssertEqual(result.status.state,.locked)
            XCTAssertTrue(proof.sawEncryptedScratch);XCTAssertTrue(proof.aliasStayedClosed)
            XCTAssertEqual(try source.get("original")?.text,"Original synthetic history");XCTAssertEqual(try Data(contentsOf:source.root.appendingPathComponent("audio/fixture.wav")),media)
            let vault=try LibraryVault(package:package);_=try await vault.unlock(passphrase:secret);let copied=try MemoryStore(root:vault.libraryURL)
            XCTAssertNotNil(try copied.get("original"));XCTAssertEqual(try copied.chatTurns(chat.id).count,1);XCTAssertEqual(try copied.vectorCount(modelID:"fixture"),1)
            let copiedNote=try XCTUnwrap(copied.get("media"));XCTAssertEqual(try Data(contentsOf:vault.libraryURL.appendingPathComponent(try XCTUnwrap(copiedNote.audioPath))),media)
            XCTAssertEqual(AppSettings.load(root:vault.libraryURL).profile,.light);XCTAssertFalse(AppSettings.load(root:vault.libraryURL).apiEnabled)
            let mount=vault.libraryURL.resolvingSymlinksInPath().deletingLastPathComponent();XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:mount.path).contains {$0.hasPrefix(".oswind-")})
            _=try await vault.lock(store:copied)
        }
    }
    func testChangedSourceIsReportedAndOriginalIsRetained() async throws {
        try await runFixture {_,source,package,secret in
            let mutation=MigrationMutation(source:source)
            let result=try await LibraryVault.migrate(from:source,to:package,name:"Changed source",capacityGiB:1,passphrase:secret,progress:{mutation.observe($0)})
            XCTAssertTrue(mutation.changed);XCTAssertNil(mutation.failure);XCTAssertFalse(result.sourceStable);XCTAssertTrue(result.originalRetained);XCTAssertNotNil(try source.get("during-copy"));XCTAssertEqual(result.status.state,.locked)
        }
    }
    func testCancellationDuringCopyClosesHandleAndDetachesWithoutRemovingOriginal() async throws {
        try await runFixture {_,source,package,secret in
            let worker=Task {
                try await LibraryVault.migrate(from:source,to:package,name:"Cancelled copy",capacityGiB:1,passphrase:secret,progress:{event in
                    if event.phase=="Copying history into encrypted storage" {withUnsafeCurrentTask {$0?.cancel()}}
                })
            }
            do {_=try await worker.value;XCTFail("Cancelled migration succeeded")} catch is CancellationError {}
            XCTAssertNotNil(try source.get("original"));let vault=try LibraryVault(package:package);XCTAssertThrowsError(try MemoryStore(root:vault.libraryURL))
            // An incomplete setup is unavailable, but independently verified lock
            // must still report detached and never require forced unmount.
            let closed=try await vault.lock();XCTAssertEqual(closed.state,.locked)
        }
    }
}
private final class MigrationObservations:@unchecked Sendable {
    let package:URL;var sawEncryptedScratch=false;var aliasStayedClosed=true
    init(package:URL) {self.package=package}
    func observe(_ progress:LibraryBackupProgress) {
        if let session=try? JSONDecoder().decode(VaultSession.self,from:Data(contentsOf:package.appendingPathComponent("session.json"))) {
            let mount=package.appendingPathComponent(".mounts/"+session.mountLeaf)
            if let names=try? FileManager.default.contentsOfDirectory(atPath:mount.path),names.contains(where:{$0.hasPrefix(".oswind-vault-migration-")}) {sawEncryptedScratch=true}
        }
        var info=stat();if lstat(package.appendingPathComponent("Library").path,&info) != 0 || info.st_mode&S_IFMT != S_IFREG {aliasStayedClosed=false}
    }
}
private final class MigrationMutation:@unchecked Sendable {
    let source:MemoryStore;var changed=false;var failure:String?
    init(source:MemoryStore) {self.source=source}
    func observe(_ event:LibraryBackupProgress) {
        guard !changed,event.phase=="Publishing restored library" else {return};changed=true
        do {try source.insert(Memory(id:"during-copy",text:"Added after the backup snapshot"))} catch {failure=error.localizedDescription}
    }
}
