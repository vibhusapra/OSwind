import XCTest
import Foundation
import Darwin
import MachO
@testable import OSwindCore

final class SyncOwnerApprovalCrashTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    func testOwnedProcessDeathBeforeAfterSaveAndBeforeUIReturnRecoversResponse()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned approval response Keychain process-death fixture")}
        for phase in ["before-save","after-save","after-return"] {try crash(phase)}
    }
    private func crash(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("owned-approval-crash-"+nonce),backend=NativeWriterKeychainFixture()
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var stores=[MemoryStore](),owners=[PersonalSyncPairing]()
        defer {
            owners.forEach {$0.close()};stores.forEach {try? $0.close()}
            do {try backend.cleanup()}catch {XCTFail("Owned approval crash accounts could not be removed")}
            try? fm.removeItem(at:root)
        }
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        let state=root.appendingPathComponent("state"),mac=MacSyncMachineFingerprint(),env=SyncNativeWriterEnvironment(stateRoot:state,machine:mac,storage:{_ in backend})
        func native(_ name:String)throws->(MemoryStore,PersonalSyncPairing) {
            let store=try MemoryStore(root:root.appendingPathComponent(name),recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(store)
            let owner=try PersonalSyncPairing(store:store,stateRoot:state,machine:mac,storage:backend);owners.append(owner);return(store,owner)
        }
        let (library,owner)=try native("main"),(peerLibrary,peer)=try native("peer")
        _=try owner.createGroup(deviceName:"Owned crash main",now:now)
        let request=try XCTUnwrap(peer.requestJoin(deviceName:"Owned crash travel",now:now).request),fingerprint=try XCTUnwrap(owner.status().rootFingerprint),accounts=backend.accounts
        XCTAssertEqual(accounts.count,2)
        let originals=try Dictionary(uniqueKeysWithValues:accounts.map {($0,try backend.read(id:$0))})
        try Data(request.utf8).write(to:root.appendingPathComponent("request"),options:.withoutOverwriting)
        try SyncProtocolLimits.encode(accounts).write(to:root.appendingPathComponent("accounts"),options:.withoutOverwriting)
        owner.close();peer.close();try library.close();try peerLibrary.close()
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=root.appendingPathComponent("child.log")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw OSwindError.invalid("Owned XCTest runner required")}
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil));let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncOwnerApprovalCrashTests/testOwnedApprovalCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var childEnv=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_APPROVAL_CRASH_ROOT":root.path,"OSWIND_APPROVAL_CRASH_NONCE":nonce,"OSWIND_APPROVAL_CRASH_PHASE":phase]
        for index in 0..<_dyld_image_count() {
            guard let raw=_dyld_get_image_name(index) else {continue};let image=URL(fileURLWithPath:String(cString:raw)).resolvingSymlinksInPath()
            if image.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {childEnv["DYLD_INSERT_LIBRARIES"]=image.path}
        }
        child.environment=childEnv;child.standardInput=FileHandle.nullDevice;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let ready=root.appendingPathComponent("ready"),deadline=ProcessInfo.processInfo.systemUptime+40
        while child.isRunning,!fm.fileExists(atPath:ready.path),ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,fm.fileExists(atPath:ready.path) else {throw OSwindError.unavailable("Owned approval child missed \(phase): "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing child log"))}
        let observation=try JSONSerialization.jsonObject(with:Data(contentsOf:ready)) as! [String:Any]
        XCTAssertEqual(observation["phase"] as? String,phase)
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let (_,resumed)=try native("main"),(_,joining)=try native("peer")
        let response:String
        if phase=="before-save" {
            XCTAssertEqual(try resumed.status().memberNames.count,1);XCTAssertNil(try resumed.lastApprovedResponse())
            for id in accounts {XCTAssertTrue(try backend.read(id:id)==originals[id],"Pre-intent private state changed")}
            response=try resumed.approve(resumed.reviewRequest(request,now:now),now:now)
        } else {
            XCTAssertEqual(try resumed.status().memberNames.count,2)
            response=try XCTUnwrap(resumed.lastApprovedResponse()).response
            XCTAssertEqual(SyncProtocolLimits.hex(Data(response.utf8)),observation["responseSHA256"] as? String)
            XCTAssertEqual(response.utf8.count,observation["responseBytes"] as? Int)
        }
        let committed=try Dictionary(uniqueKeysWithValues:accounts.map {($0,try backend.read(id:$0))})
        XCTAssertEqual(try resumed.lastApprovedResponse()?.response,response)
        XCTAssertEqual(try resumed.approve(resumed.reviewRequest(request,now:now),now:now),response)
        for id in accounts {XCTAssertTrue(try backend.read(id:id)==committed[id],"Response retrieval changed private state")}
        XCTAssertEqual(try joining.acceptResponse(response,trustedRootFingerprint:fingerprint,now:now).phase,.paired)
        XCTAssertEqual(backend.accounts,accounts)
        resumed.close();joining.close();stores.forEach {try? $0.close()};try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
        print("OWNED_APPROVAL_PROCESS_DEATH phase=\(phase) signal=9 committedResponseExact=\(phase != "before-save") beforeIntentOldStatePreserved=\(phase == "before-save") originalAccounts=2 cleaned=true")
    }
    func testOwnedApprovalCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_APPROVAL_CRASH_ROOT"],let nonce=env["OSWIND_APPROVAL_CRASH_NONCE"],let phase=env["OSWIND_APPROVAL_CRASH_PHASE"] else {throw XCTSkip("Only run as owned approval response crash worker")}
        guard UUID(uuidString:nonce)?.uuidString==nonce,["before-save","after-save","after-return"].contains(phase) else {throw OSwindError.invalid("Invalid owned approval crash scope")}
        let root=URL(fileURLWithPath:path),expected=fm.temporaryDirectory.appendingPathComponent("owned-approval-crash-"+nonce)
        guard root.standardizedFileURL==expected.standardizedFileURL,try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OSwindError.invalid("Owned approval crash root differs")}
        let ids=try SyncPairingFormat.decode([String].self,Data(contentsOf:root.appendingPathComponent("accounts")),limit:1024)
        guard ids.count==2,Set(ids).count==2 else {throw OSwindError.invalid("Use only the two original owned accounts")}
        let storage=ApprovalCrashStorage(root:root,phase:phase,ids:Set(ids)),state=root.appendingPathComponent("state"),mac=MacSyncMachineFingerprint()
        let store=try MemoryStore(root:root.appendingPathComponent("main"),recoveryReadOnly:false,nativeWriterEnvironment:.init(stateRoot:state,machine:mac,storage:{_ in storage}))
        defer {try? store.close()}
        let owner=try PersonalSyncPairing(store:store,stateRoot:state,machine:mac,storage:storage);defer {owner.close()}
        let request=try String(contentsOf:root.appendingPathComponent("request"),encoding:.utf8),response=try owner.approve(owner.reviewRequest(request,now:now),now:now)
        guard phase=="after-return" else {throw OSwindError.invalid("Owned private boundary did not stop")}
        try storage.stop(response:Data(response.utf8))
    }
}

private final class ApprovalCrashStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let backend=SyncKeychainCredentialStorage(protection:.loginKeychain),root:URL,phase:String,ids:Set<String>
    init(root:URL,phase:String,ids:Set<String>) {self.root=root;self.phase=phase;self.ids=ids}
    func create(id:String,bytes:Data)throws {throw OSwindError.invalid("Crash worker cannot create accounts")}
    func read(id:String)throws->Data {guard ids.contains(id) else {throw OSwindError.invalid("Crash worker account differs")};return try backend.read(id:id)}
    func remove(id:String,expected:Data)throws {throw OSwindError.invalid("Crash worker cannot remove accounts")}
    func replace(id:String,expected:Data,bytes:Data)throws {
        guard ids.contains(id) else {throw OSwindError.invalid("Crash worker account differs")}
        if phase=="before-save" {try stop(proposed:bytes)}
        try backend.replace(id:id,expected:expected,bytes:bytes)
        if phase=="after-save" {try stop(proposed:bytes)}
    }
    private func stop(proposed:Data)throws {
        let object=try JSONSerialization.jsonObject(with:proposed) as! [String:Any]
        let pointer=try JSONSerialization.data(withJSONObject:XCTUnwrap(object["initialApproval"]),options:[.sortedKeys,.withoutEscapingSlashes])
        let reference=try SyncPairingFormat.decode(SyncOwnerApprovalReference.self,pointer,limit:2048)
        let material=try SyncCredentialMaterial.decodeFromKeychain(XCTUnwrap(Data(base64Encoded:XCTUnwrap(object["material"] as? String))))
        let folder=try material.joined.openPrivateInbox(at:root.appendingPathComponent("main/images/device-sync-"+material.joined.replica));defer {folder.close()}
        let plan=try SyncOwnerApprovalPlan.decode(XCTUnwrap(folder.content(reference.content)))
        try plan.require(reference,current:material.joined.certificate,pairingID:XCTUnwrap(object["id"] as? String),lifetime:reference.lifetime)
        try stop(response:plan.response)
    }
    func stop(response:Data)throws {
        let observation:[String:Any]=["phase":phase,"responseSHA256":SyncProtocolLimits.hex(response),"responseBytes":response.count]
        try JSONSerialization.data(withJSONObject:observation,options:[.sortedKeys]).write(to:root.appendingPathComponent("ready"),options:.withoutOverwriting)
        while true {Thread.sleep(forTimeInterval:0.1)}
    }
}
