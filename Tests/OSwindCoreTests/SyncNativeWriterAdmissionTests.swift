import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

final class SyncNativeWriterAdmissionTests:XCTestCase {
    var root:URL!,library:MemoryStore!,pairing:PersonalSyncPairing?,service:SyncLibraryService?
    let storage=DeliveryTestStorage()
    let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"a",count:64))
    var environment:SyncNativeWriterEnvironment {.init(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{[storage] _ in storage})}
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-native-writer-"+UUID().uuidString)
        library=try MemoryStore(root:root.appendingPathComponent("library"))
        try library.insert(Memory(id:"owned",kind:.note,text:"Owned source retained through recovery"))
    }
    override func tearDownWithError()throws {
        try stop();try library?.close();try FileManager.default.removeItem(at:root)
    }
    func prepare()throws {
        let owner=try PersonalSyncPairing(store:library,stateRoot:environment.stateRoot,machine:machine,storage:storage)
        pairing=owner;_=try owner.createGroup(deviceName:"Owned admission Mac")
        service=try owner.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:true)
    }
    func stop()throws {
        defer {service?.inbox.close();service?.transport.close();service=nil;pairing?.close();pairing=nil}
        try service?.stop()
    }
    func ready()throws {
        for _ in 0..<80 {
            let step=try service!.tick(limit:64)
            if case .preparing=step {continue};if case .reviewingPolicy=step {continue};return
        };throw OSwindError.unavailable("Owned admission service did not become ready")
    }
    func reopen()throws->MemoryStore {try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:environment)}
    func deliveryID()throws->String {
        try XCTUnwrap(storage.values.first {_,data in (try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["format"] as? String == "OSwind.sync.delivery-anchor"}?.key)
    }
    func testCurrentConcurrentWritersRefreshCheckpointsAndPreserveVersion34()throws {
        try prepare();try service!.installNativeWriterAdmission()
        let second=try reopen();defer {try? second.close()}
        try second.insert(Memory(id:"second",kind:.note,text:"Second admitted native client"))
        try ready()
        try second.insert(Memory(id:"after-checkpoint",kind:.note,text:"Refresh after another owner's commit"))
        try ready()
        XCTAssertNotNil(try library.get("after-checkpoint"))
        XCTAssertEqual(try second.withRoutineDatabase {try $0.eraseCount("PRAGMA user_version")},34)
        XCTAssertEqual(try service!.cache.journal.outbox().count,3)
    }
    func testAlreadyOpenCurrentClientRequiresReopenAfterEnrollment()throws {
        let stale=try MemoryStore(root:library.root);defer {try? stale.close()}
        let prepared=try stale.withRoutineDatabase {try $0.statement("UPDATE memories SET title='Unadmitted prepared statement' WHERE id='owned'")}
        defer {sqlite3_finalize(prepared)}
        try prepare();try service!.installNativeWriterAdmission()
        XCTAssertNotEqual(sqlite3_step(prepared),SQLITE_DONE,"SQL compiled before enrollment must recompile against the false connection capability")
        XCTAssertThrowsError(try stale.insert(Memory(id:"stale",kind:.note,text:"Must be refused")))
        XCTAssertNil(try library.get("stale"))
        try library.insert(Memory(id:"current",kind:.note,text:"Owning admitted writer still works"))
        XCTAssertNotNil(try library.get("current"))
    }
    func testAmbiguousExternalFailureCannotRegrantTheSameNativeConnection()throws {
        try prepare();try service!.installNativeWriterAdmission()
        storage.failReplacement=true
        XCTAssertThrowsError(try service!.tick());storage.failReplacement=false
        for _ in 0..<3 {XCTAssertThrowsError(try library.insert(Memory(id:"must-refuse",text:"No cached proof regrant")))}
        XCTAssertThrowsError(try stop());try library.close()
        library=try reopen()
        XCTAssertNil(try library.get("must-refuse"))
        try library.insert(Memory(id:"reopened",text:"Verified reopen after the owned backend refused replacement"))
        XCTAssertNotNil(try library.get("reopened"))
    }
    func testOwnedKeychainNativeWriterAdmissionReopensOriginalAccounts()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned Keychain writer admission fixture")}
        let backend=NativeWriterKeychainFixture(),state=root.appendingPathComponent("native-state"),mac=MacSyncMachineFingerprint()
        defer {do {try backend.cleanup()}catch {XCTFail("Owned native admission Keychain cleanup failed")}}
        let owner=try PersonalSyncPairing(store:library,stateRoot:state,machine:mac,storage:backend)
        pairing=owner;_=try owner.createGroup(deviceName:"Owned native writer")
        service=try owner.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:true)
        try service!.installNativeWriterAdmission();try ready();try stop();try library.close()
        library=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:.init(stateRoot:state,machine:mac,storage:{_ in backend}))
        try library.insert(Memory(id:"native-reopen",text:"Current native writer with original Keychain proof"))
        XCTAssertNotNil(try library.get("native-reopen"));XCTAssertEqual(backend.accounts.count,2)
        try library.close();try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
    }
    func testSecondPreparationCannotInvalidateTheRunningService()throws {
        try prepare();try service!.installNativeWriterAdmission();try ready()
        let keys=storage.values
        XCTAssertThrowsError(try pairing!.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:false))
        XCTAssertEqual(storage.values,keys)
        try library.insert(Memory(id:"after-refused-owner",kind:.note,text:"Current service remains usable"))
        try ready();XCTAssertEqual(try service!.cache.journal.outbox().count,2)
    }
    func testRestoredPreInstallationDatabaseRefusesBeforeConstructorMigrations()throws {
        let owner=try PersonalSyncPairing(store:library,stateRoot:environment.stateRoot,machine:machine,storage:storage)
        pairing=owner;_=try owner.createGroup(deviceName:"Owned pre-install Mac")
        let snapshot=root.appendingPathComponent("pre-install.sqlite")
        try library.withRoutineDatabase {db in
            var destination:OpaquePointer?;XCTAssertEqual(sqlite3_open(snapshot.path,&destination),SQLITE_OK);defer {sqlite3_close(destination)}
            let backup=try XCTUnwrap(sqlite3_backup_init(destination,"main",db.handle,"main"));XCTAssertEqual(sqlite3_backup_step(backup,-1),SQLITE_DONE);XCTAssertEqual(sqlite3_backup_finish(backup),SQLITE_OK)
        }
        service=try owner.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:true)
        try service!.installNativeWriterAdmission();try ready();try stop();try library.close()
        let path=library.root.appendingPathComponent("memory.sqlite")
        try FileManager.default.removeItem(at:path);try FileManager.default.copyItem(at:snapshot,to:path)
        let before=try Data(contentsOf:path),accounts=storage.values
        XCTAssertThrowsError(try reopen());XCTAssertEqual(try Data(contentsOf:path),before);XCTAssertEqual(storage.values,accounts)
        _=try LibraryRecovery.createBackup(from:library.root,destination:root.appendingPathComponent("pre-install-recovery.oswindbackup"))
    }
    func testMissingCredentialRefusesBeforeMigrationsAndRecoveryRestoresFreshIdentity()throws {
        try prepare();try service!.installNativeWriterAdmission();try ready()
        let id=try deliveryID();try stop();try library.close();storage.forget(id)
        XCTAssertThrowsError(try reopen())
        let output=root.appendingPathComponent("recovered.oswindbackup"),fresh=root.appendingPathComponent("fresh")
        _=try LibraryRecovery.createBackup(from:library.root,destination:output)
        _=try LibraryBackup.restore(output,to:fresh)
        let restored=try MemoryStore(root:fresh);defer {try? restored.close()}
        XCTAssertEqual(try restored.get("owned")?.text,"Owned source retained through recovery")
        XCTAssertEqual(try restored.withRoutineDatabase {try $0.eraseCount("PRAGMA user_version")},33)
        XCTAssertEqual(try restored.withRoutineDatabase {try $0.eraseCount("SELECT enabled FROM personal_sync_capture")},0)
        XCTAssertEqual(try restored.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM sqlite_master WHERE name='personal_sync_delivery_anchor'")},0)
        XCTAssertEqual(try restored.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key LIKE 'sync-pairing-%' OR key='sync-publication-library-lifetime-v1'")},0)
    }
    func testChangedNativeGuardRefusesExistingAndReopenedConnections()throws {
        try prepare();try service!.installNativeWriterAdmission()
        try library.withRoutineDatabase {try $0.execute("DROP TRIGGER sync_native_writer_memories_delete")}
        XCTAssertThrowsError(try library.insert(Memory(id:"changed",kind:.note,text:"Refuse changed guard")))
        XCTAssertThrowsError(try stop());try library.close();XCTAssertThrowsError(try reopen())
    }
    func testCheckpointRollbackCannotBeAdmittedWithAValidNewerCredential()throws {
        try prepare();try service!.installNativeWriterAdmission()
        let snapshot=root.appendingPathComponent("before.sqlite")
        try library.withRoutineDatabase {db in
            var destination:OpaquePointer?;XCTAssertEqual(sqlite3_open(snapshot.path,&destination),SQLITE_OK);defer {sqlite3_close(destination)}
            let backup=try XCTUnwrap(sqlite3_backup_init(destination,"main",db.handle,"main"));XCTAssertEqual(sqlite3_backup_step(backup,-1),SQLITE_DONE);XCTAssertEqual(sqlite3_backup_finish(backup),SQLITE_OK)
        }
        try ready();try stop();try library.close()
        let path=library.root.appendingPathComponent("memory.sqlite")
        try FileManager.default.removeItem(at:path);try FileManager.default.copyItem(at:snapshot,to:path)
        XCTAssertThrowsError(try reopen())
        _=try LibraryRecovery.createBackup(from:library.root,destination:root.appendingPathComponent("rollback-recovery.oswindbackup"))
    }
    func testAdmissionProofDoesNotRetainClosedLibrary()throws {
        try prepare();try service!.installNativeWriterAdmission();try stop();try library.close()
        weak var weakLibrary=library
        library=nil
        XCTAssertNil(weakLibrary)
    }
    func testFrozenPrior33AlreadyOpenCollectorAndFreshClientRefuse()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_COLLECTION_PRIOR33_CLI"] else {throw XCTSkip("Requires the exact frozen prior33 executable")}
        let binary=URL(fileURLWithPath:path),expected="6580f0db8534063df2fbf04115eb4142af9eb33ef2e2df098d177f6988013c92"
        func hash()throws->String {SHA256.hash(data:try Data(contentsOf:binary)).map {String(format:"%02x",$0)}.joined()}
        XCTAssertEqual(try hash(),expected)
        let child=Process(),input=Pipe(),output=Pipe(),errors=Pipe()
        child.executableURL=binary;child.arguments=["--data",library.root.path,"collect","--stdin"]
        var env=ProcessInfo.processInfo.environment;env["OSWIND_DATA_DIR"]=library.root.path;env.removeValue(forKey:"DYLD_INSERT_LIBRARIES");child.environment=env
        child.standardInput=input;child.standardOutput=output;child.standardError=errors
        try child.run();defer {if child.isRunning {child.terminate()};try? input.fileHandleForWriting.close()}
        var observed=false
        let deadline=ProcessInfo.processInfo.systemUptime+15
        while !observed,child.isRunning,ProcessInfo.processInfo.systemUptime<deadline {
            do {let lease=try MediaAdmissionLease.acquire(root:library.root,exclusive:true,timeout:0,onBusy:{observed=true});lease.release()}
            catch {if !observed {throw error}}
            if !observed {Thread.sleep(forTimeInterval:0.02)}
        }
        XCTAssertTrue(observed,"Observe the real old collector's retained-media admission before enrolling")
        guard observed else {return}
        try prepare();try service!.installNativeWriterAdmission()
        let batch="""
        {"format":"OSwind collector batch","version":1,"collectorID":"dev.example.tickets","records":[{"key":"ticket-123","timestamp":"2026-10-25T05:23:45.123456-07:00","app":"Tickets","bundleID":"dev.example.tickets","title":"Launch","text":"Owned old collector source","url":"https://example.com/ticket/123"}]}
        """
        try input.fileHandleForWriting.write(contentsOf:Data(batch.utf8));try input.fileHandleForWriting.close()
        let end=ProcessInfo.processInfo.systemUptime+20
        while child.isRunning,ProcessInfo.processInfo.systemUptime<end {Thread.sleep(forTimeInterval:0.02)}
        guard !child.isRunning else {child.terminate();return XCTFail("Old collector did not terminate after admission refusal")}
        child.waitUntilExit();XCTAssertNotEqual(child.terminationStatus,0)
        let stderr=String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        XCTAssertTrue(stderr.contains("oswind_native_sync_writer_v1") || stderr.contains("writer admission"),stderr)
        XCTAssertEqual(try library.stats(includeDiskUsage:false).count,1)
        let fresh=Process(),freshError=Pipe();fresh.executableURL=binary;fresh.arguments=["--data",library.root.path,"stats"];fresh.environment=env;fresh.standardInput=FileHandle.nullDevice;fresh.standardOutput=FileHandle.nullDevice;fresh.standardError=freshError
        try fresh.run();fresh.waitUntilExit();XCTAssertNotEqual(fresh.terminationStatus,0)
        XCTAssertTrue(String(decoding:freshError.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).contains("newer OSwind version"))
        try library.insert(Memory(id:"current",kind:.note,text:"Current native writer survives old client refusal"))
        XCTAssertNotNil(try library.get("current"));XCTAssertEqual(try hash(),expected)
        print("NATIVE_SYNC_WRITER_FENCE frozen33AlreadyOpenRefused=true fresh33Refused=true currentWriter=true originalExecutableUnchanged=true")
    }
}

private final class NativeWriterKeychainFixture:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let backend=SyncKeychainCredentialStorage(protection:.loginKeychain)
    private(set) var accounts=[String]()
    func create(id:String,bytes:Data)throws {try backend.create(id:id,bytes:bytes);accounts.append(id)}
    func read(id:String)throws->Data {try backend.read(id:id)}
    func replace(id:String,expected:Data,bytes:Data)throws {try backend.replace(id:id,expected:expected,bytes:bytes)}
    func remove(id:String,expected:Data)throws {try backend.remove(id:id,expected:expected)}
    func cleanup()throws {
        for id in accounts {
            try backend.remove(id:id,expected:backend.read(id:id))
            do {_=try backend.read(id:id);throw OSwindError.invalid("Owned writer credential survived cleanup")}
            catch SyncCredentialStorageError.missing {}
        }
        accounts.removeAll()
    }
}
