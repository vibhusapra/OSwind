import XCTest
import Foundation
import CSQLite
import Darwin
@testable import OSwindCore

final class SyncMembershipBackfillNativeTests:XCTestCase {
    // Filled only from the independently built, frozen d665a30 engine bundle.
    private let frozen36SHA="80a09cbd70547dc61b1834bd6ef2f20a5867852a9b73ab38030391d0ac7959de"
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    func testOwnedFrozen36CachedWriterFencedAfterRejectedBackfillCommitAndExactRecovery()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1",let bundlePath=ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE36_BUNDLE"] else {throw XCTSkip("Explicit frozen36 engine and owned native Keychain fixture")}
        let bundle=URL(fileURLWithPath:bundlePath),binary=bundle.appendingPathComponent("Contents/MacOS/OSwindPackageTests")
        guard try SyncProtocolLimits.hex(Data(contentsOf:binary))==frozen36SHA else {throw OSwindError.invalid("Use the unchanged frozen36 engine bundle")}
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("owned-membership-floor-"+nonce),backend=BackfillNativeStorage()
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var stores=[MemoryStore](),pairings=[PersonalSyncPairing](),operations=[SyncMembershipFloorOwner](),children=[Process](),outputs=[FileHandle](),services=[SyncLibraryService]()
        defer {
            for child in children {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
            if let path=ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE36_DIAGNOSTICS"] {
                let destination=URL(fileURLWithPath:path)
                for name in ["cached.log","fresh-after.log","fresh-after-retire.log"] {let item=root.appendingPathComponent(name);if fm.fileExists(atPath:item.path) {try? fm.copyItem(at:item,to:destination.appendingPathComponent(name))}}
            }
            outputs.forEach {try? $0.close()};services.forEach {try? $0.stop();$0.inbox.close();$0.transport.close()};operations.forEach {try? $0.close()};pairings.forEach {$0.close()};stores.forEach {try? $0.close()}
            do {try backend.cleanup()}catch {XCTFail("Owned frozen36 accounts could not be removed")};try? fm.removeItem(at:root)
        }
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        let state=root.appendingPathComponent("state"),mac=MacSyncMachineFingerprint(),env=SyncNativeWriterEnvironment(stateRoot:state,machine:mac,storage:{_ in backend})
        func native(_ path:String)throws->(MemoryStore,PersonalSyncPairing) {
            let library=try MemoryStore(root:root.appendingPathComponent(path),recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(library)
            let pairing=try PersonalSyncPairing(store:library,stateRoot:state,machine:mac,storage:backend);pairings.append(pairing);return(library,pairing)
        }
        func join(_ peer:PersonalSyncPairing,_ owner:PersonalSyncPairing,_ name:String)throws {
            let request=try XCTUnwrap(peer.requestJoin(deviceName:name,now:now).request),response=try owner.approve(owner.reviewRequest(request,now:now),now:now)
            _=try peer.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(owner.status().rootFingerprint),now:now)
        }
        let (_,owner)=try native("owner-library"),(library,peer)=try native("peer"),(_,third)=try native("third-library")
        _=try owner.createGroup(deviceName:"Owned floor desk",now:now);try join(peer,owner,"Owned floor travel")
        let prior=try peer.membershipCertificateForRefresh();try join(third,owner,"Owned floor third")
        let proof=try XCTUnwrap(owner.membershipRefresh(after:prior)),service=try peer.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:true)
        services.append(service);try service.installNativeWriterAdmission();try library.insert(Memory(id:"canary",text:"Owned native36 compatibility capture"))
        _=try SyncOutgoingTests().serviceReady(service,limit:2)
        try service.stop();service.inbox.close();service.transport.close();peer.close()
        let initial=try SyncMembershipPreparationOwner.prepare(library:library,proof:proof,environment:env);defer {try? initial.close()};try initial.applyMembership();try initial.close()
        let authored=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(authored)
        // Authored old652 cleared format1 snapshot with existing replay; all
        // original credentials and graph history retain their current bytes.
        try authored.withRoutineDatabase {db in try authored.nativeWriterAdmission.withMembershipMutation(db) {try SyncChangeCapture.transaction(db) {
            let current=try SyncNativeMembershipState.read(db),row=try db.statement("UPDATE store_metadata SET value=? WHERE key=?");defer {sqlite3_finalize(row)}
            db.bind(row,1,String(decoding:try SyncProtocolLimits.encode(SyncNativeMembershipState.Value.active(current.head,version:1)),as:UTF8.self));db.bind(row,2,SyncNativeMembershipState.stateKey);try db.done(row)
        }}}
        try authored.close();let active=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(active)
        XCTAssertEqual(try active.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},1)
        let accounts=backend.accounts;XCTAssertEqual(accounts.count,4)
        try SyncProtocolLimits.encode(accounts).write(to:root.appendingPathComponent("accounts"),options:.withoutOverwriting)
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath();guard runner.lastPathComponent=="xctest" else {throw OSwindError.invalid("Owned XCTest runner required")}
        func launch(_ mode:String,_ label:String)throws->Process {
            let child=Process(),log=root.appendingPathComponent(label+".log");XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil));let output=try FileHandle(forWritingTo:log);outputs.append(output)
            child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncNative36FrozenWorkerTests/testOwnedNative36Worker",bundle.path]
            child.environment=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_OLD36_ROOT":root.path,"OSWIND_OLD36_NONCE":nonce,"OSWIND_OLD36_MODE":mode]
            child.standardInput=FileHandle.nullDevice;child.standardOutput=output;child.standardError=output;try child.run();children.append(child);return child
        }
        func wait(_ child:Process,marker:String?,label:String)throws {
            let deadline=ProcessInfo.processInfo.systemUptime+40
            while child.isRunning,ProcessInfo.processInfo.systemUptime<deadline {
                if let marker,fm.fileExists(atPath:root.appendingPathComponent(marker).path) {return}
                Thread.sleep(forTimeInterval:0.01)
            }
            if marker != nil || child.isRunning {throw OSwindError.unavailable("Owned old36 gate failed: "+((try? String(contentsOf:root.appendingPathComponent(label+".log"),encoding:.utf8)) ?? "missing child log"))}
            child.waitUntilExit();guard child.terminationReason == .exit,child.terminationStatus==0 else {throw OSwindError.unavailable("Owned frozen36 child failed: "+((try? String(contentsOf:root.appendingPathComponent(label+".log"),encoding:.utf8)) ?? "missing child log"))}
        }
        print("OLD36_PARENT_STAGE before-old-child");let cached=try launch("cached","cached");try wait(cached,marker:"ready-cached",label:"cached")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("ready-cached"),encoding:.utf8),"admitted-written-prepared")
        print("BACKFILL_NATIVE_STAGE cached-ready");let stale=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(stale)
        print("BACKFILL_NATIVE_STAGE stale-opened");let handle=try active.withRoutineDatabase {$0.handle},gate=BackfillNativeCommitGate()
        backend.didReplace={sqlite3_commit_hook(handle,BackfillNativeCommitGate.callback,Unmanaged.passUnretained(gate).toOpaque())}
        XCTAssertThrowsError(try SyncMembershipFloorOwner.prepare(library:active,environment:env));backend.didReplace=nil;sqlite3_commit_hook(handle,nil,nil);XCTAssertEqual(gate.rejections,1)
        print("BACKFILL_NATIVE_STAGE commit-rejected");let deliveryID=try stale.withRoutineDatabase {db->String in let row=try db.statement("SELECT id FROM personal_sync_delivery_anchor");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Owned delivery missing")};return db.text(row,0)}
        print("BACKFILL_NATIVE_STAGE delivery-id-read");let pending=try XCTUnwrap(JSONSerialization.jsonObject(with:backend.read(id:deliveryID)) as? [String:Any]),target=try SyncPairingFormat.decode(SyncDeliveryAnchor.Token.self,JSONSerialization.data(withJSONObject:XCTUnwrap(pending["token"]),options:[.sortedKeys]),limit:1024)
        print("BACKFILL_NATIVE_STAGE saved-pending-read");try stale.insert(Memory(id:"pre-fence-backfill",text:"Capture after rejected backfill COMMIT before recovered fence"))
        print("BACKFILL_NATIVE_STAGE pre-fence-capture-written");let operation=try SyncMembershipFloorOwner.open(root:library.root,environment:env);operations.append(operation);try operation.complete()
        print("BACKFILL_NATIVE_STAGE recovery-completed");XCTAssertThrowsError(try stale.insert(Memory(id:"post-fence-backfill",text:"Must refuse")))
        let completed=try XCTUnwrap(JSONSerialization.jsonObject(with:backend.read(id:deliveryID)) as? [String:Any]),final=try SyncPairingFormat.decode(SyncDeliveryAnchor.Token.self,JSONSerialization.data(withJSONObject:XCTUnwrap(completed["token"]),options:[.sortedKeys]),limit:1024);XCTAssertEqual(final,target)
        print("OLD36_BACKFILL_STAGE exact-recovery-completed");try Data("release".utf8).write(to:root.appendingPathComponent("release-cached"),options:.withoutOverwriting)
        try wait(cached,marker:nil,label:"cached");XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("result-cached"),encoding:.utf8),"cached-and-normal-refused")
        print("OLD36_PARENT_STAGE old-child-joined");try operation.close();try active.close()
        print("OLD36_PARENT_STAGE before-fresh-old");let freshOld=try launch("refuse","fresh-after");try wait(freshOld,marker:nil,label:"fresh-after")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("result-refuse"),encoding:.utf8),"state-format-refused")
        print("OLD36_PARENT_STAGE fresh-old-refused");let fresh=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(fresh)
        let title=try fresh.withRoutineDatabase {db ->String in let row=try db.statement("SELECT title FROM memories WHERE id='canary'");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Owned positive canary missing")};return db.text(row,0)}
        XCTAssertEqual(title,"old36-positive");XCTAssertEqual(try fresh.get("canary")?.text,"Owned native36 compatibility capture");XCTAssertNil(try fresh.get("old36-must-refuse"));XCTAssertEqual(backend.accounts,accounts)
        XCTAssertEqual(try fresh.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2)
        let replay=try fresh.withRoutineDatabase {db ->SyncMembershipReplay.Cursor? in let sent=try db.eraseCount("SELECT sent FROM personal_sync_service_state WHERE singleton=1");return try SyncMembershipReplay.current(db,sent:Int64(sent))}
        XCTAssertGreaterThan(try XCTUnwrap(replay).through,0);XCTAssertNotNil(try fresh.get("pre-fence-backfill"));XCTAssertNil(try fresh.get("post-fence-backfill"))
        let paired=try PersonalSyncPairing(store:fresh,stateRoot:state,machine:mac,storage:backend);pairings.append(paired);XCTAssertEqual(try paired.status().memberNames.count,3)
        let retiring=try paired.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:false)
        services.append(retiring);_=try retiring.stageLocalRetirement();try retiring.stop();retiring.inbox.close();retiring.transport.close();paired.close();try fresh.close()
        let cleanup=try SyncRetirementCleanupOwner.open(root:library.root,environment:env);defer {try? cleanup.close()}
        XCTAssertTrue(try cleanup.cleanup().cleanupComplete);_=try cleanup.completeLocalRetirement();try cleanup.close()
        let renewed=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(renewed)
        XCTAssertEqual(try renewed.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2)
        XCTAssertEqual(try renewed.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-membership-replay-v1'")},0)
        XCTAssertNil(try renewed.get("canary"));try renewed.insert(Memory(id:"after-retirement",text:"Current writer after format2 retirement"));XCTAssertNotNil(try renewed.get("after-retirement"))
        try fm.removeItem(at:root.appendingPathComponent("result-refuse"))
        let afterRetirement=try launch("refuse","fresh-after-retire");try wait(afterRetirement,marker:nil,label:"fresh-after-retire")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("result-refuse"),encoding:.utf8),"state-format-refused");XCTAssertEqual(backend.accounts,accounts)
        print("OLD36_PARENT_STAGE before-final-cleanup");try renewed.close();owner.close();third.close();try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
        XCTAssertEqual(try SyncProtocolLimits.hex(Data(contentsOf:binary)),frozen36SHA)
        print("FROZEN36_BACKFILL_FLOOR legacyAdmittedAndWritten=true rejectedCommitRecoveredExactToken=true preFenceCapturePreserved=true cachedWriterFenced=true completedFormat2FreshRefused=true pendingReplayPreserved=true retirementPreservedFloorAndClearedReplay=true originalAccountsCleaned=4")
    }
}

private final class BackfillNativeStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection=SyncCredentialProtection.loginKeychain
    private let native=NativeWriterKeychainFixture()
    var accounts:[String] {native.accounts}
    var didReplace:(()->Void)?
    func create(id:String,bytes:Data)throws {try native.create(id:id,bytes:bytes)}
    func read(id:String)throws->Data {try native.read(id:id)}
    func replace(id:String,expected:Data,bytes:Data)throws {try native.replace(id:id,expected:expected,bytes:bytes);didReplace?()}
    func remove(id:String,expected:Data)throws {try native.remove(id:id,expected:expected)}
    func cleanup()throws {try native.cleanup()}
}
private final class BackfillNativeCommitGate {
    private(set) var rejections=0
    static let callback:@convention(c) (UnsafeMutableRawPointer?)->Int32 = {pointer in
        let gate=Unmanaged<BackfillNativeCommitGate>.fromOpaque(pointer!).takeUnretainedValue();if gate.rejections==0 {gate.rejections+=1;return 1};return 0
    }
}
