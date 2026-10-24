import XCTest
import Darwin
import CSQLite
@testable import OSwindCore

final class VaultTests:XCTestCase {
    var root:URL!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-vault-contract-"+UUID().uuidString);try Paths.ensure(root)}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    func manifest(_ name:String="fixture") throws -> VaultPaths {
        let path=root.appendingPathComponent(name);try Paths.ensure(path);let paths=try VaultPaths(path)
        try paths.write(LibraryVaultInfo(name:"Synthetic vault",capacityGiB:1,volumeUUID:UUID().uuidString),as:VaultPaths.manifestName);try paths.closeAlias();return paths
    }
    func testMissingManifestInReservedPackageRefusesPlaintextFallback() throws {
        let package=root.appendingPathComponent("Broken.oswindvault");try Paths.ensure(package)
        XCTAssertThrowsError(try MemoryStore(root:package));XCTAssertThrowsError(try MemoryStore(root:package.appendingPathComponent("Library")));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:package.path).isEmpty)
    }
    func testLockedManagedHandleRefusesStoreBeforeCreatingAnything() throws {
        let paths=try manifest();let before=try FileManager.default.contentsOfDirectory(atPath:paths.package.path).sorted()
        XCTAssertThrowsError(try MemoryStore(root:paths.library));XCTAssertThrowsError(try MemoryStore(root:paths.package))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:paths.package.path).sorted(),before);XCTAssertFalse(FileManager.default.fileExists(atPath:paths.package.appendingPathComponent("memory.sqlite").path));XCTAssertTrue(paths.library.isFileURL)
    }
    func testAliasCloseNeverTouchesItsTargetAndIsIdempotent() throws {
        let paths=try manifest(),outside=root.appendingPathComponent("outside");try Paths.ensure(outside);try Data([9]).write(to:outside.appendingPathComponent("keep"))
        try FileManager.default.removeItem(at:paths.library);try FileManager.default.createSymbolicLink(at:paths.library,withDestinationURL:outside);try paths.closeAlias();try paths.closeAlias()
        XCTAssertEqual(try Data(contentsOf:outside.appendingPathComponent("keep")),Data([9]));var s=stat();XCTAssertEqual(lstat(paths.library.path,&s),0);XCTAssertEqual(s.st_mode&S_IFMT,S_IFREG)
    }
    func testAliasCloseRefusesRealDirectoryAndPreservesData() throws {
        let paths=try manifest();try FileManager.default.removeItem(at:paths.library);try Paths.ensure(paths.library);try Data([7]).write(to:paths.library.appendingPathComponent("keep"))
        XCTAssertThrowsError(try paths.closeAlias());XCTAssertEqual(try Data(contentsOf:paths.library.appendingPathComponent("keep")),Data([7]))
    }
    func testRedirectedPublicHandleRemainsBoundToItsOwnPackage() throws {
        let first=try manifest("first"),second=try manifest("second"),target=root.appendingPathComponent("foreign-library");try Paths.ensure(target)
        let marker=VaultLibraryMarker(vaultID:try second.info().id,packagePath:second.package.path);try JSONEncoder().encode(marker).write(to:target.appendingPathComponent(VaultPaths.markerName))
        try FileManager.default.removeItem(at:first.library);try FileManager.default.createSymbolicLink(at:first.library,withDestinationURL:target)
        XCTAssertEqual(try VaultAccess.package(containing:first.library)?.package,first.package);XCTAssertThrowsError(try MemoryStore(root:first.library))
    }
    func testCorruptManifestAndMissingSessionNeverBecomePlainLibraries() throws {
        let paths=try manifest();try paths.tree().remove(VaultPaths.manifestName);try paths.tree().write(Data("{}".utf8),as:VaultPaths.manifestName)
        XCTAssertThrowsError(try MemoryStore(root:paths.library));XCTAssertFalse(FileManager.default.fileExists(atPath:paths.package.appendingPathComponent("memory.sqlite").path))
    }
    func testCopiedManagedMarkerOutsideVaultRefusesPlainFallback() throws {
        let paths=try manifest(),copied=root.appendingPathComponent("copied");try Paths.ensure(copied)
        let marker=VaultLibraryMarker(vaultID:try paths.info().id,packagePath:paths.package.path);try JSONEncoder().encode(marker).write(to:copied.appendingPathComponent(VaultPaths.markerName))
        XCTAssertThrowsError(try MemoryStore(root:copied));XCTAssertFalse(FileManager.default.fileExists(atPath:copied.appendingPathComponent("memory.sqlite").path))
    }
    func testForgedSessionCannotTreatOrdinaryFolderAsMountedEncryptedVolume() throws {
        let paths=try manifest(),info=try paths.info(),nonce=UUID().uuidString.lowercased();let mount=paths.mounts.appendingPathComponent(nonce);try Paths.ensure(mount);try Paths.ensure(paths.image)
        let stamp=try BackupFileTree(root:mount).identity(),image=try BackupFileTree(root:paths.image).identity()
        let session=VaultSession(vaultID:info.id,nonce:nonce,phase:.unlocked,mountLeaf:nonce,device:"/dev/disk123s1",volumeUUID:info.volumeUUID,rootDevice:stamp.device,rootInode:stamp.inode,imageDevice:image.device,imageInode:image.inode)
        try paths.write(session,as:"session.json");try paths.openAlias(session:session)
        XCTAssertThrowsError(try MemoryStore(root:paths.library));XCTAssertFalse(FileManager.default.fileExists(atPath:mount.appendingPathComponent("Library/memory.sqlite").path))
    }
    func testPackageReplacementIsRejectedBeforeMetadataWrite() throws {
        let paths=try manifest();try FileManager.default.moveItem(at:paths.package,to:root.appendingPathComponent("moved"));try Paths.ensure(paths.package)
        XCTAssertThrowsError(try paths.closeAlias());XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:paths.package.path).isEmpty)
    }
    func testOperationReservationRejectsOtherActorsAndReleases() throws {
        let paths=try manifest();var lease:VaultOperationLease?=try VaultOperationLease(paths:paths);XCTAssertNotNil(lease);XCTAssertThrowsError(try VaultOperationLease(paths:paths));lease=nil
        let next=try VaultOperationLease(paths:paths);withExtendedLifetime(next){}
    }
    func testPlainConnectionRetainsDiskTemporaryPolicy() throws {
        let location=root.appendingPathComponent("ordinary");let store=try MemoryStore(root:location)
        XCTAssertEqual(try VaultAccess.temporaryPolicy(at:location),.file)
        try store.withRoutineDatabase {db in let row=try db.statement("PRAGMA temp_store");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),1)}
    }
    func testInvalidPassphraseCannotCreatePackageOrSpawnHelper() async throws {
        let path=root.appendingPathComponent("must-not-exist")
        for secret in [Data(),Data("short".utf8),Data(repeating:0,count:32),Data(repeating:65,count:4097)] {
            do {_=try await LibraryVault.create(at:path,name:"Fixture",capacityGiB:1,passphrase:secret);XCTFail("Invalid passphrase accepted")} catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
        }
    }
    func testHelperCapturesBothPipesWithoutDeadlockAndBoundsOutput() async throws {
        let value=try await VaultProcess.run("/usr/bin/python3",["-c","import sys;sys.stdout.write('a'*100000);sys.stderr.write('b'*100000)"])
        XCTAssertEqual(value.status,0);XCTAssertEqual(value.stdout.count,100000);XCTAssertEqual(value.stderr.count,100000)
        do {_=try await VaultProcess.run("/usr/bin/python3",["-c","import sys;sys.stdout.write('a'*5000000)"]);XCTFail("Oversized output accepted")} catch {}
    }
    func testCancelledHelperActuallyExitsBeforeReturning() async throws {
        let pid=root.appendingPathComponent("owned.pid"),program="import os,time,pathlib;pathlib.Path("+String(reflecting:pid.path)+").write_text(str(os.getpid()));time.sleep(30)"
        let worker=Task {try await VaultProcess.run("/usr/bin/python3",["-c",program])};let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !FileManager.default.fileExists(atPath:pid.path),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(FileManager.default.fileExists(atPath:pid.path));worker.cancel();do {_=try await worker.value;XCTFail("Cancelled helper succeeded")} catch is CancellationError {} catch {XCTFail("Unexpected error \(error)")}
        let process=try XCTUnwrap(Int32(String(contentsOf:pid,encoding:.utf8)));errno=0;XCTAssertEqual(kill(process,0),-1);XCTAssertEqual(errno,ESRCH)
    }
}

final class NativeVaultTests:XCTestCase {
    func testOptionalCredentialLifecycleUsesVerifiedPassphraseAndPreservesFallback() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned encrypted fixture with fake credential provider; no real Keychain access")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-vault-credential-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Fixture.oswindvault"),secret=Data(UUID().uuidString.utf8),provider=FixtureVaultSecrets()
        _=try await LibraryVault.create(at:package,name:"Owned credentials",capacityGiB:1,passphrase:secret)
        let vault=try LibraryVault(package:package)
        do {
            do {_=try await vault.unlockUsingKeychain(using:provider);XCTFail("Unsaved credential was loaded")} catch {}
            XCTAssertEqual(provider.loads,0)
            _=try await vault.unlock(passphrase:secret)
            do {try await vault.rememberPassphrase(Data(UUID().uuidString.utf8),using:provider);XCTFail("Unverified credential was saved")} catch {}
            XCTAssertEqual(provider.saves,0)
            provider.failSave=true
            do {try await vault.rememberPassphrase(secret,using:provider);XCTFail("Failed credential save succeeded")} catch {}
            let failed=try await vault.status();XCTAssertFalse(failed.info.keychainEnabled)
            provider.failSave=false;try await vault.rememberPassphrase(secret,using:provider)
            let saved=try await vault.status();XCTAssertTrue(saved.info.keychainEnabled)
            _=try await vault.lock();_=try await vault.unlockUsingKeychain(using:provider);XCTAssertEqual(provider.loads,1)
            try await vault.forgetPassphrase(using:provider);let forgotten=try await vault.status();XCTAssertFalse(forgotten.info.keychainEnabled);XCTAssertNil(provider.secret)
            _=try await vault.lock();_=try await vault.unlock(passphrase:secret);_=try await vault.lock();try FileManager.default.removeItem(at:root)
        } catch {_=try? await vault.lock();throw error}
    }
    func testOwnedEncryptedVolumeAndSQLiteTemporaryPolicies() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Opt in to create an owned local encrypted APFS fixture; no Keychain or normal-library access")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-native-vault-"+UUID().uuidString);try Paths.ensure(root)
        let package=root.appendingPathComponent("Fixture.oswindvault"),secret=Data(UUID().uuidString.utf8)
        let vault=try LibraryVault(package:package)
        do {
            print("Owned native vault: create and detach")
            let created=try await LibraryVault.create(at:package,name:"Owned fixture",capacityGiB:1,passphrase:secret)
            XCTAssertEqual(created.state,.locked);XCTAssertThrowsError(try MemoryStore(root:vault.libraryURL))
            print("Owned native vault: unlock and inspect SQLite")
            _=try await vault.unlock(passphrase:secret)
            let store=try MemoryStore(root:vault.libraryURL);try store.insert(Memory(id:"owned",text:"Owned encrypted fixture"))
            try store.withRoutineDatabase {db in let row=try db.statement("PRAGMA temp_store");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),2)}
            var workspace:BackupWorkspace?=try store.libraryWorkspace("oswind-backup-pins")
            let database=try BackupDatabase(workspace!.url.appendingPathComponent("scratch.sqlite"),createPrivate:true);XCTAssertEqual(try database.integer("PRAGMA temp_store"),2);database.close()
            workspace=nil
            print("Owned native vault: close store and detach")
            let other=try MemoryStore(root:vault.libraryURL)
            do {_=try await vault.lock(store:store);XCTFail("A competing store must prevent detach")} catch {}
            XCTAssertTrue(store.isClosed);XCTAssertThrowsError(try MemoryStore(root:vault.libraryURL))
            // A closed public alias must not prevent an existing cooperative
            // reader from releasing its own SQLite connection and media lease.
            try other.close();XCTAssertTrue(other.isClosed)
            let locked=try await vault.lock();XCTAssertEqual(locked.state,.locked)
            _=try await vault.unlock(passphrase:secret);let reopened=try MemoryStore(root:vault.libraryURL);XCTAssertEqual(try reopened.get("owned")?.text,"Owned encrypted fixture");_=try await vault.lock(store:reopened)
            try FileManager.default.removeItem(at:root)
        } catch {
            _=try? await vault.lock()
            // Keep a failed native fixture for diagnosis. Never force unmount or
            // delete a package whose detached state was not verified.
            throw error
        }
    }
}

private final class FixtureVaultSecrets:VaultSecretProvider,@unchecked Sendable {
    var secret:Data?,loads=0,saves=0,failSave=false
    func save(_ passphrase:Data,vaultID:String) throws {saves+=1;if failSave {throw OSwindError.unavailable("Synthetic credential-save failure")};secret=passphrase}
    func load(vaultID:String) throws -> Data {loads+=1;guard let secret else {throw OSwindError.unavailable("No synthetic credential")};return secret}
    func remove(vaultID:String) throws {secret=nil}
}
