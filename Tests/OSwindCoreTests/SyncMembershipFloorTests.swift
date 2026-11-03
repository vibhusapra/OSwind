import XCTest
import Foundation
import CSQLite
import Darwin
@testable import OSwindCore

final class SyncMembershipFloorTests:XCTestCase {
    // Filled only from the independently built, frozen d665a30 engine bundle.
    private let frozen36SHA="80a09cbd70547dc61b1834bd6ef2f20a5867852a9b73ab38030391d0ac7959de"
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    func testOwnedFrozen36AdmitsLegacyButRefusesCompletedReplayFormat()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1",let bundlePath=ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE36_BUNDLE"] else {throw XCTSkip("Explicit frozen36 engine and owned native Keychain fixture")}
        let bundle=URL(fileURLWithPath:bundlePath),binary=bundle.appendingPathComponent("Contents/MacOS/OSwindPackageTests")
        guard try SyncProtocolLimits.hex(Data(contentsOf:binary))==frozen36SHA else {throw OSwindError.invalid("Use the unchanged frozen36 engine bundle")}
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("owned-membership-floor-"+nonce),backend=NativeWriterKeychainFixture()
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var stores=[MemoryStore](),pairings=[PersonalSyncPairing](),operations=[SyncMembershipPreparationOwner](),children=[Process](),outputs=[FileHandle](),services=[SyncLibraryService]()
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
        print("OLD36_PARENT_STAGE native35-ready");let initial=try SyncMembershipPreparationOwner.prepare(library:library,proof:proof,environment:env);operations.append(initial);try initial.cancelBeforeHandover();try initial.close()
        print("OLD36_PARENT_STAGE initial-cancelled");let active=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(active)
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
        print("OLD36_PARENT_STAGE old-child-admitted");let operation=try SyncMembershipPreparationOwner.prepare(library:active,proof:proof,environment:env);operations.append(operation);try operation.applyMembership()
        print("OLD36_PARENT_STAGE handover-applied");try Data("release".utf8).write(to:root.appendingPathComponent("release-cached"),options:.withoutOverwriting)
        try wait(cached,marker:nil,label:"cached");XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("result-cached"),encoding:.utf8),"cached-and-normal-refused")
        print("OLD36_PARENT_STAGE old-child-joined");try operation.close()
        print("OLD36_PARENT_STAGE before-fresh-old");let freshOld=try launch("refuse","fresh-after");try wait(freshOld,marker:nil,label:"fresh-after")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("result-refuse"),encoding:.utf8),"state-format-refused")
        print("OLD36_PARENT_STAGE fresh-old-refused");let fresh=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(fresh)
        let title=try fresh.withRoutineDatabase {db ->String in let row=try db.statement("SELECT title FROM memories WHERE id='canary'");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Owned positive canary missing")};return db.text(row,0)}
        XCTAssertEqual(title,"old36-positive");XCTAssertEqual(try fresh.get("canary")?.text,"Owned native36 compatibility capture");XCTAssertNil(try fresh.get("old36-must-refuse"));XCTAssertEqual(backend.accounts,accounts)
        XCTAssertEqual(try fresh.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2)
        let replay=try fresh.withRoutineDatabase {db ->SyncMembershipReplay.Cursor? in let sent=try db.eraseCount("SELECT sent FROM personal_sync_service_state WHERE singleton=1");return try SyncMembershipReplay.current(db,sent:Int64(sent))}
        XCTAssertGreaterThan(try XCTUnwrap(replay).through,0)
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
        print("FROZEN36_FORMAT_FLOOR legacyAdmittedAndWritten=true cachedWriterFenced=true completedFormat2FreshRefused=true pendingReplayPresent=true retirementPreservedFloorAndClearedReplay=true originalAccountsCleaned=4")
    }
}
