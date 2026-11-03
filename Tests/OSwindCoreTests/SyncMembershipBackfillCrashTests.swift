import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

/// Authored libraries, four explicitly owned login-Keychain accounts and a
/// same-XCTest child killed only after a durable private/SQLite boundary.
final class SyncMembershipBackfillCrashTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    private func object(_ bytes:Data)throws->[String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])}
    func testOwnedProcessDeathAtSixFloorBoundariesPreservesExactForwardChoice()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned native Keychain process-death fixture")}
        for phase in ["before-intent","intent","before-commit","commit","before-clear","clear"] {try crash(phase)}
    }
    private func crash(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("owned-membership-backfill-crash-"+nonce),backend=NativeWriterKeychainFixture()
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var stores=[MemoryStore](),pairings=[PersonalSyncPairing]()
        defer {
            pairings.forEach {$0.close()};stores.forEach {try? $0.close()}
            do {try backend.cleanup()}catch {XCTFail("Owned membership crash accounts could not be removed")}
            try? fm.removeItem(at:root)
        }
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        let state=root.appendingPathComponent("state"),mac=MacSyncMachineFingerprint(),env=SyncNativeWriterEnvironment(stateRoot:state,machine:mac,storage:{_ in backend})
        func native(_ path:String)throws->(MemoryStore,PersonalSyncPairing) {
            let store=try MemoryStore(root:root.appendingPathComponent(path),recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(store)
            let pairing=try PersonalSyncPairing(store:store,stateRoot:state,machine:mac,storage:backend);pairings.append(pairing);return(store,pairing)
        }
        func join(_ peer:PersonalSyncPairing,_ owner:PersonalSyncPairing,_ name:String)throws {
            let request=try XCTUnwrap(peer.requestJoin(deviceName:name,now:now).request),response=try owner.approve(owner.reviewRequest(request,now:now),now:now)
            _=try peer.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(owner.status().rootFingerprint),now:now)
        }
        let (_,owner)=try native("owner-library"),(library,peer)=try native("peer-library"),(_,third)=try native("third-library")
        _=try owner.createGroup(deviceName:"Owned crash desk",now:now);try join(peer,owner,"Owned crash travel")
        let prior=try peer.membershipCertificateForRefresh();try join(third,owner,"Owned crash third")
        let proof=try XCTUnwrap(owner.membershipRefresh(after:prior)),shared=root.appendingPathComponent("shared"),service=try peer.prepareAnchoredService(shared:shared,createShared:true)
        try service.installNativeWriterAdmission();try library.insert(Memory(id:"canary",text:"Owned capture surviving real floor process death"));_=try SyncOutgoingTests().serviceReady(service,limit:2)
        try service.stop();service.inbox.close();service.transport.close();peer.close();try library.close()
        let initial=try SyncMembershipPreparationOwner.prepare(root:library.root,proof:proof,environment:env);defer {try? initial.close()};try initial.applyMembership();try initial.close()
        let authored=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(authored)
        let replayBefore=try authored.withRoutineDatabase {db->String in
            try authored.nativeWriterAdmission.withMembershipMutation(db) {try SyncChangeCapture.transaction(db) {
                let current=try SyncNativeMembershipState.read(db),row=try db.statement("UPDATE store_metadata SET value=? WHERE key=?");defer {sqlite3_finalize(row)}
                db.bind(row,1,String(decoding:try SyncProtocolLimits.encode(SyncNativeMembershipState.Value.active(current.head,version:1)),as:UTF8.self));db.bind(row,2,SyncNativeMembershipState.stateKey);try db.done(row)
            }}
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-membership-replay-v1'");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Owned replay missing")};return db.text(row,0)
        }
        try authored.close()
        let accounts=backend.accounts;XCTAssertEqual(accounts.count,4)
        let originals=try Dictionary(uniqueKeysWithValues:accounts.map {($0,try backend.read(id:$0))})
        try SyncProtocolLimits.encode(accounts).write(to:root.appendingPathComponent("accounts"),options:.withoutOverwriting)
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=root.appendingPathComponent("child.log")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw OSwindError.invalid("Owned XCTest runner required")}
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil));let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncMembershipBackfillCrashTests/testOwnedMembershipBackfillCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var childEnv=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_FLOOR_CRASH_ROOT":root.path,"OSWIND_FLOOR_CRASH_NONCE":nonce,"OSWIND_FLOOR_CRASH_PHASE":phase]
        for i in 0..<_dyld_image_count() {
            guard let raw=_dyld_get_image_name(i) else {continue};let image=URL(fileURLWithPath:String(cString:raw)).resolvingSymlinksInPath()
            if image.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {childEnv["DYLD_INSERT_LIBRARIES"]=image.path}
        }
        child.environment=childEnv;child.standardInput=FileHandle.nullDevice;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let ready=root.appendingPathComponent("ready"),deadline=ProcessInfo.processInfo.systemUptime+40
        while child.isRunning,!fm.fileExists(atPath:ready.path),ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:ready,encoding:.utf8))==phase else {XCTFail("Owned membership child missed \(phase): "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing child log"));return}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let savedDelivery=try accounts.compactMap {id -> (String,[String:Any])? in
            let value=try object(backend.read(id:id));return value["token"] == nil ? nil:(id,value)
        }.first
        let delivery=try XCTUnwrap(savedDelivery),expectedToken:SyncDeliveryAnchor.Token?
        if let pending=delivery.1["membershipFloor"] as? [String:Any] {
            let record=try SyncPairingFormat.decode(SyncMembershipFloorPreparation.self,JSONSerialization.data(withJSONObject:pending,options:[.sortedKeys]),limit:4096);try record.validate();expectedToken=record.tokenAfter
            XCTAssertFalse(["before-intent","clear"].contains(phase))
        }else {
            XCTAssertTrue(["before-intent","clear"].contains(phase))
            expectedToken=phase=="clear" ? try SyncPairingFormat.decode(SyncDeliveryAnchor.Token.self,JSONSerialization.data(withJSONObject:XCTUnwrap(delivery.1["token"]),options:[.sortedKeys]),limit:1024):nil
        }
        if phase=="before-intent" {
            let resumed=try SyncMembershipFloorOwner.prepare(root:library.root,environment:env);defer {try? resumed.close()};try resumed.complete();try resumed.close()
        }else if phase != "clear" {
            XCTAssertThrowsError(try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env))
            let resumed=try SyncMembershipFloorOwner.open(root:library.root,environment:env);defer {try? resumed.close()};try resumed.complete();try resumed.close()
        }
        let fresh=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(fresh)
        let finalDelivery=try object(backend.read(id:delivery.0)),finalToken=try SyncPairingFormat.decode(SyncDeliveryAnchor.Token.self,JSONSerialization.data(withJSONObject:XCTUnwrap(finalDelivery["token"]),options:[.sortedKeys]),limit:1024)
        if let expectedToken {XCTAssertEqual(finalToken,expectedToken)}
        let originalDelivery=try object(XCTUnwrap(originals[delivery.0])),originalToken=try SyncPairingFormat.decode(SyncDeliveryAnchor.Token.self,JSONSerialization.data(withJSONObject:XCTUnwrap(originalDelivery["token"]),options:[.sortedKeys]),limit:1024);XCTAssertEqual(finalToken.serial,originalToken.serial+1)
        XCTAssertEqual(try fresh.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2)
        let replayAfter=try fresh.withRoutineDatabase {db->String in let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-membership-replay-v1'");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Recovered replay missing")};return db.text(row,0)};XCTAssertEqual(replayAfter,replayBefore);XCTAssertEqual(finalDelivery["membershipHead"] as? String,SyncProtocolLimits.hex(try proof.head.encoded()))
        XCTAssertNotNil(try fresh.get("canary"));try fresh.insert(Memory(id:"fresh",text:"Verified writer after actual child death"))
        let checked=try PersonalSyncPairing(store:fresh,stateRoot:state,machine:mac,storage:backend);pairings.append(checked)
        XCTAssertEqual(try checked.status().memberNames.count,3);XCTAssertEqual(backend.accounts,accounts)
        for id in accounts {
            let before=try object(XCTUnwrap(originals[id])),after=try object(backend.read(id:id))
            XCTAssertTrue((before["material"] as? String)==(after["material"] as? String),"Original private material changed")
            if id != delivery.0 {XCTAssertTrue(originals[id]==(try backend.read(id:id)),"Original pairing account changed")}
            XCTAssertNil(after["membershipFloor"])
        }
        checked.close();try fresh.close();owner.close();third.close();try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
        print("OWNED_BACKFILL_PROCESS_DEATH phase=\(phase) signal=9 exactForwardRecovered=true replayPreserved=true originalAccounts=4 cleaned=true")
    }
    func testOwnedMembershipBackfillCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_FLOOR_CRASH_ROOT"],let nonce=env["OSWIND_FLOOR_CRASH_NONCE"],let phase=env["OSWIND_FLOOR_CRASH_PHASE"] else {throw XCTSkip("Only run as owned membership crash worker")}
        guard UUID(uuidString:nonce)?.uuidString==nonce,["before-intent","intent","before-commit","commit","before-clear","clear"].contains(phase) else {throw OSwindError.invalid("Invalid owned membership crash scope")}
        let root=URL(fileURLWithPath:path),expected=fm.temporaryDirectory.appendingPathComponent("owned-membership-backfill-crash-"+nonce)
        guard root.resolvingSymlinksInPath()==expected.resolvingSymlinksInPath(),try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OSwindError.invalid("Invalid owned membership crash root")}
        let ids=try SyncPairingFormat.decode([String].self,Data(contentsOf:root.appendingPathComponent("accounts")),limit:1024)
        guard ids.count==4,Set(ids).count==4 else {throw OSwindError.invalid("Invalid owned membership account list")};try ids.forEach {try SyncProtocolLimits.uuid($0)}
        let backend=BackfillCrashStorage(root:root,phase:phase,ids:Set(ids)),state=root.appendingPathComponent("state"),native=SyncNativeWriterEnvironment(stateRoot:state,machine:MacSyncMachineFingerprint(),storage:{_ in backend})
        let library=try MemoryStore(root:root.appendingPathComponent("peer-library"),recoveryReadOnly:false,nativeWriterEnvironment:native)
        let handle=try library.withRoutineDatabase {$0.handle}
        sqlite3_trace_v2(handle,UInt32(SQLITE_TRACE_PROFILE),{mask,context,statement,_ in
            guard mask==UInt32(SQLITE_TRACE_PROFILE),let context,let statement,let sql=sqlite3_sql(OpaquePointer(statement)) else {return 0}
            let storage=Unmanaged<BackfillCrashStorage>.fromOpaque(context).takeUnretainedValue()
            if storage.phase=="commit",storage.armed,String(cString:sql).trimmingCharacters(in:.whitespacesAndNewlines).uppercased()=="COMMIT" {storage.hold()};return 0
        },Unmanaged.passUnretained(backend).toOpaque())
        sqlite3_commit_hook(handle,{pointer in
            guard let pointer else {return 0};let storage=Unmanaged<BackfillCrashStorage>.fromOpaque(pointer).takeUnretainedValue()
            if storage.phase=="before-commit",storage.armed {storage.hold()};return 0
        },Unmanaged.passUnretained(backend).toOpaque())
        let operation=try SyncMembershipFloorOwner.prepare(library:library,environment:native)
        try operation.complete();try operation.close();XCTFail("Owned floor child passed its requested kill gate")
    }
}
private final class BackfillCrashStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    let root:URL,phase:String,ids:Set<String>
    private let backend=SyncKeychainCredentialStorage(protection:.loginKeychain)
    private var replacements=0
    var armed=false
    init(root:URL,phase:String,ids:Set<String>) {self.root=root;self.phase=phase;self.ids=ids}
    func create(id:String,bytes:Data)throws {throw OSwindError.invalid("Crash worker cannot create credentials")}
    func read(id:String)throws->Data {guard ids.contains(id) else {throw OSwindError.invalid("Unowned crash account")};return try backend.read(id:id)}
    func replace(id:String,expected:Data,bytes:Data)throws {
        guard ids.contains(id) else {throw OSwindError.invalid("Unowned crash account")}
        if (phase=="before-intent" && replacements==0) || (phase=="before-clear" && replacements==1) {hold()}
        try backend.replace(id:id,expected:expected,bytes:bytes);replacements+=1
        if replacements==1 {armed=true}
        if ["intent":1,"clear":2][phase]==replacements {hold()}
    }
    func remove(id:String,expected:Data)throws {throw OSwindError.invalid("Crash worker cannot remove credentials")}
    func hold() {
        do {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic)}catch {return}
        Thread.sleep(forTimeInterval:45)
    }
}
