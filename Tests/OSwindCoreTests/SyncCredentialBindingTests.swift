import XCTest
import Darwin
@testable import OSwindCore

final class SyncCredentialBindingTests:XCTestCase {
    struct Machine:SyncMachineFingerprint {let value:String;func fingerprint()throws->String {value}}
    var root:URL!,store:MemoryStore!
    let machine=Machine(value:String(repeating:"a",count:64))
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-sync-binding-"+UUID().uuidString);try Paths.ensure(root)
        store=try MemoryStore(root:root.appendingPathComponent("library"))
    }
    override func tearDownWithError()throws {try store?.close();store=nil;try FileManager.default.removeItem(at:root)}
    func material()throws->SyncCredentialMaterial {
        let pending=try SyncPendingJoin(name:"Owned bound device"),owner=try SyncGroupAuthority(owner:pending.request)
        return try .init(joined:pending.accept(owner.response(to:pending.request),expectedRootFingerprint:owner.fingerprint),owner:owner)
    }
    func testInstallationCreationIsStableAndMissingExistingIdentityNeverRegenerates()throws {
        let state=root.appendingPathComponent("state")
        XCTAssertThrowsError(try SyncLocalCredentialState.installationID(at:state,create:false))
        XCTAssertFalse(FileManager.default.fileExists(atPath:state.path))
        let first=try SyncLocalCredentialState.installationID(at:state,create:true)
        XCTAssertEqual(try SyncLocalCredentialState.installationID(at:state,create:true),first)
        XCTAssertEqual(try SyncLocalCredentialState.installationID(at:state,create:false),first)
        try FileManager.default.removeItem(at:state.appendingPathComponent("installation-v1"))
        XCTAssertThrowsError(try SyncLocalCredentialState.installationID(at:state,create:false))
        XCTAssertFalse(FileManager.default.fileExists(atPath:state.appendingPathComponent("installation-v1").path))
    }
    func testMalformedAndSymlinkedInstallationStateCannotBeAdopted()throws {
        let state=root.appendingPathComponent("state");_=try SyncLocalCredentialState.installationID(at:state,create:true)
        let member=state.appendingPathComponent("installation-v1")
        try Data("Not a saved installation".utf8).write(to:member)
        XCTAssertThrowsError(try SyncLocalCredentialState.installationID(at:state,create:true))
        let foreign=root.appendingPathComponent("foreign");try Data("foreign bytes".utf8).write(to:foreign)
        try FileManager.default.removeItem(at:member);try FileManager.default.createSymbolicLink(at:member,withDestinationURL:foreign)
        XCTAssertThrowsError(try SyncLocalCredentialState.installationID(at:state,create:false))
        XCTAssertEqual(try Data(contentsOf:foreign),Data("foreign bytes".utf8))
    }
    func testConcurrentFirstEnrollmentKeepsOneCompleteInstallationIdentity()throws {
        let state=root.appendingPathComponent("state"),results=InstallationResults()
        DispatchQueue.concurrentPerform(iterations:8) {_ in
            do {results.record(try SyncLocalCredentialState.installationID(at:state,create:true))}catch {results.failed(error)}
        }
        XCTAssertEqual(results.failures,0,results.messages.joined(separator:" | "));XCTAssertEqual(results.values.count,8);XCTAssertEqual(Set(results.values).count,1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:state.path),["installation-v1"])
    }
    func testBindingAcceptsCurrentLibraryAndRejectsMachineInstallationAndProtectionChanges()throws {
        let keys=try material(),installation=UUID().uuidString.lowercased()
        let binding=try SyncEnrollmentBinding.capture(store:store,material:keys,id:UUID().uuidString.lowercased(),protection:.loginKeychain,machine:machine,installation:installation)
        try binding.verify(store:store,material:keys,protection:.loginKeychain,machine:machine,installation:installation)
        XCTAssertThrowsError(try binding.verify(store:store,material:keys,protection:.loginKeychain,machine:Machine(value:String(repeating:"b",count:64)),installation:installation))
        XCTAssertThrowsError(try binding.verify(store:store,material:keys,protection:.loginKeychain,machine:machine,installation:UUID().uuidString.lowercased()))
        XCTAssertThrowsError(try binding.verify(store:store,material:keys,protection:.dataProtectionKeychain,machine:machine,installation:installation))
        XCTAssertThrowsError(try binding.verify(store:store,material:material(),protection:.loginKeychain,machine:machine,installation:installation))
        XCTAssertTrue(String(reflecting:binding).contains("redacted"))
    }
    func testCopiedDatabaseCannotReuseOriginalPhysicalBinding()throws {
        let keys=try material(),installation=UUID().uuidString.lowercased()
        let binding=try SyncEnrollmentBinding.capture(store:store,material:keys,id:UUID().uuidString.lowercased(),protection:.loginKeychain,machine:machine,installation:installation)
        try store.insert(Memory(id:"owned",kind:.note,text:"Owned copy fixture"));try store.close()
        let clone=root.appendingPathComponent("clone");try FileManager.default.copyItem(at:store.root,to:clone)
        let copied=try MemoryStore(root:clone);defer {try? copied.close()}
        XCTAssertThrowsError(try binding.verify(store:copied,material:keys,protection:.loginKeychain,machine:machine,installation:installation))
        XCTAssertNotNil(try copied.get("owned"))
    }
    func testSameVolumeRenameRetainsPhysicalLibraryBinding()throws {
        let keys=try material(),installation=UUID().uuidString.lowercased()
        let binding=try SyncEnrollmentBinding.capture(store:store,material:keys,id:UUID().uuidString.lowercased(),protection:.loginKeychain,machine:machine,installation:installation)
        try store.close();let moved=root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at:store.root,to:moved)
        let reopened=try MemoryStore(root:moved);defer {try? reopened.close()}
        try binding.verify(store:reopened,material:keys,protection:.loginKeychain,machine:machine,installation:installation)
    }
    func testNativeWipeCannotSilentlyReuseEnrolledPublicationBinding()throws {
        let keys=try material(),installation=UUID().uuidString.lowercased()
        let transport=try keys.joined.createTransport(at:root.appendingPathComponent("shared"))
        let inbox=try keys.joined.createPrivateInbox(at:store.root.appendingPathComponent("images/bound-inbox"))
        defer {transport.close();inbox.close()}
        let service=try SyncLibraryService.install(library:store,replica:keys.joined.replica,group:keys.joined.certificate.body.group,epoch:keys.joined.certificate.body.epoch,peers:[],transport:transport,inbox:inbox)
        defer {try? service.stop()}
        let binding=try SyncEnrollmentBinding.capture(store:store,material:keys,id:UUID().uuidString.lowercased(),protection:.loginKeychain,machine:machine,installation:installation)
        XCTAssertNotNil(binding.publicationLifetime)
        try store.insert(Memory(id:"owned",kind:.note,text:"Owned generation fixture"));try service.stop();_=try store.deleteAll()
        XCTAssertThrowsError(try binding.verify(store:store,material:keys,protection:.loginKeychain,machine:machine,installation:installation))
    }
    func testIndividualSourceErasureDoesNotRetireWholeLibraryCredentialBinding()throws {
        let keys=try material(),installation=UUID().uuidString.lowercased()
        let transport=try keys.joined.createTransport(at:root.appendingPathComponent("shared")),inbox=try keys.joined.createPrivateInbox(at:store.root.appendingPathComponent("images/bound-inbox"))
        defer {transport.close();inbox.close()}
        let service=try SyncLibraryService.install(library:store,replica:keys.joined.replica,group:keys.joined.certificate.body.group,epoch:keys.joined.certificate.body.epoch,peers:[],transport:transport,inbox:inbox)
        defer {try? service.stop()}
        let binding=try SyncEnrollmentBinding.capture(store:store,material:keys,id:UUID().uuidString.lowercased(),protection:.loginKeychain,machine:machine,installation:installation)
        XCTAssertNotNil(binding.publicationLifetime)
        try store.insert(Memory(id:"one",kind:.note,text:"Owned removable source"));try store.insert(Memory(id:"two",kind:.note,text:"Owned retained source"))
        _=try store.delete("one")
        try binding.verify(store:store,material:keys,protection:.loginKeychain,machine:machine,installation:installation)
        XCTAssertNotNil(try store.get("two"))
    }
    func testReplacedOpenRootCannotBeUsedToCreateNewBinding()throws {
        let keys=try material(),moved=root.appendingPathComponent("retained")
        try FileManager.default.moveItem(at:store.root,to:moved);try Paths.ensure(store.root)
        XCTAssertThrowsError(try SyncEnrollmentBinding.capture(store:store,material:keys,id:UUID().uuidString.lowercased(),protection:.loginKeychain,machine:machine,installation:UUID().uuidString.lowercased()))
    }
    func testExclusiveCredentialLeaseClosesAndRejectsReplacedLockIdentity()throws {
        let state=root.appendingPathComponent("state"),id=UUID().uuidString.lowercased(),first=try SyncCredentialExclusiveLease(id:id,stateRoot:state)
        defer {first.close()};try first.requireCurrentIdentity()
        XCTAssertThrowsError(try SyncCredentialExclusiveLease(id:id,stateRoot:state))
        let member=state.appendingPathComponent("locks/credential-"+id)
        try FileManager.default.moveItem(at:member,to:member.appendingPathExtension("retained"));try Data().write(to:member)
        XCTAssertThrowsError(try first.requireCurrentIdentity())
        first.close();XCTAssertThrowsError(try first.requireCurrentIdentity())
    }
    func testCredentialLeaseExcludesAnActualOtherProcessUntilRelease()async throws {
        let state=root.appendingPathComponent("state"),id=UUID().uuidString.lowercased(),lease=try SyncCredentialExclusiveLease(id:id,stateRoot:state)
        defer {lease.close()}
        let path=state.appendingPathComponent("locks/credential-"+id).path
        func child()async throws->Int32 {
            let process=Process(),done=XCTestExpectation(description:"Owned nonblocking lock child exited")
            process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            process.arguments=["-c","import os,sys,fcntl\nf=os.open(sys.argv[1],os.O_RDONLY|os.O_NOFOLLOW)\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError:\n sys.exit(73)\nsys.exit(0)",path]
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            process.terminationHandler={_ in done.fulfill()}
            try process.run();defer {if process.isRunning {kill(process.processIdentifier,SIGKILL);process.waitUntilExit()}}
            await fulfillment(of:[done],timeout:10)
            guard !process.isRunning else {throw OSwindError.unavailable("Owned lock child did not finish")}
            return process.terminationStatus
        }
        let blocked=try await child();XCTAssertEqual(blocked,73)
        lease.close();let available=try await child();XCTAssertEqual(available,0)
        let next=try SyncCredentialExclusiveLease(id:id,stateRoot:state);defer {next.close()};try next.requireCurrentIdentity()
    }
    func testNativeMachineFingerprintIsBoundedWithoutLoggingHardwareIdentity()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit read-only Mac binding probe; hardware identifier is never logged or retained")}
        let digest=try MacSyncMachineFingerprint().fingerprint();try SyncProtocolLimits.digest(digest)
    }
}

private final class InstallationResults:@unchecked Sendable {
    private let lock=NSLock();private var ids=[String](),errors=0,reasons=[String]()
    var values:[String] {lock.lock();defer {lock.unlock()};return ids}
    var failures:Int {lock.lock();defer {lock.unlock()};return errors}
    var messages:[String] {lock.lock();defer {lock.unlock()};return reasons}
    func record(_ id:String) {lock.lock();ids.append(id);lock.unlock()}
    func failed(_ error:Error) {lock.lock();errors+=1;reasons.append(error.localizedDescription);lock.unlock()}
}
