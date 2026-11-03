import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

/// Three generated original login-Keychain accounts, one exact owned child,
/// seven durable boundaries. This does not exercise the unfinished app UI.
final class SyncDeliveryOwnerResponseCrashTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    private static let phases=["intent","decision","pairing","delivery","commit","clear","after-response"]
    func testOwnedDeathThroughFinalClearAndResponseReturnKeepsExactCiphertext()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned delivered-response Keychain process-death fixture")}
        let phases:[String]
        if let selected=env["OSWIND_TEST_DELIVERY_APPROVAL_PHASE"] {guard Self.phases.contains(selected) else {throw OSwindError.invalid("Unknown owned approval phase")};phases=[selected]}else {phases=Self.phases}
        for phase in phases {try crash(phase)}
    }
    private func crash(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("owned-delivery-approval-crash-"+nonce),backend=NativeWriterKeychainFixture()
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var stores=[MemoryStore](),pairings=[PersonalSyncPairing]()
        defer {
            pairings.forEach {$0.close()};stores.forEach {try? $0.close()}
            do {try backend.cleanup()}catch {XCTFail("Owned delivered approval accounts were not removed")}
            try? fm.removeItem(at:root)
        }
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        let state=root.appendingPathComponent("state"),mac=MacSyncMachineFingerprint(),env=SyncNativeWriterEnvironment(stateRoot:state,machine:mac,storage:{_ in backend})
        func native(_ name:String)throws->(MemoryStore,PersonalSyncPairing) {
            let library=try MemoryStore(root:root.appendingPathComponent(name),recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(library)
            let owner=try PersonalSyncPairing(store:library,stateRoot:state,machine:mac,storage:backend);pairings.append(owner);return(library,owner)
        }
        let (library,owner)=try native("main"),(peerLibrary,peer)=try native("peer")
        _=try owner.createGroup(deviceName:"Owned delivery crash desk",now:now)
        let request=try XCTUnwrap(peer.requestJoin(deviceName:"Owned delivery crash travel",now:now).request),fingerprint=try XCTUnwrap(owner.status().rootFingerprint)
        let service=try owner.prepareAnchoredService(shared:root.appendingPathComponent("provider"),createShared:true)
        try service.installNativeWriterAdmission();try library.insert(Memory(id:"canary",text:"Owned source surviving approval process death"))
        try service.stop();service.inbox.close();service.transport.close();owner.close();peer.close();try library.close();try peerLibrary.close()
        let accounts=backend.accounts;XCTAssertEqual(accounts.count,3)
        let originals=try Dictionary(uniqueKeysWithValues:accounts.map {($0,try backend.read(id:$0))})
        try Data(request.utf8).write(to:root.appendingPathComponent("request"),options:.withoutOverwriting)
        try SyncProtocolLimits.encode(accounts).write(to:root.appendingPathComponent("accounts"),options:.withoutOverwriting)
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),child=Process(),log=root.appendingPathComponent("child.log")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw OSwindError.invalid("Use the owned XCTest runner")}
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil));let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncDeliveryOwnerResponseCrashTests/testOwnedDeliveredApprovalCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var childEnv=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_DELIVERY_APPROVAL_CRASH_ROOT":root.path,"OSWIND_DELIVERY_APPROVAL_CRASH_NONCE":nonce,"OSWIND_DELIVERY_APPROVAL_CRASH_PHASE":phase]
        for i in 0..<_dyld_image_count() {
            guard let raw=_dyld_get_image_name(i) else {continue};let image=URL(fileURLWithPath:String(cString:raw)).resolvingSymlinksInPath()
            if image.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {childEnv["DYLD_INSERT_LIBRARIES"]=image.path}
        }
        child.environment=childEnv;child.standardInput=FileHandle.nullDevice;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let ready=root.appendingPathComponent("ready"),deadline=ProcessInfo.processInfo.systemUptime+60
        while child.isRunning,!fm.fileExists(atPath:ready.path),ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,fm.fileExists(atPath:ready.path) else {throw OSwindError.unavailable("Owned delivered approval child missed \(phase): "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        let observed=try JSONSerialization.jsonObject(with:Data(contentsOf:ready)) as! [String:Any];XCTAssertEqual(observed["phase"] as? String,phase)
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let delivery=try XCTUnwrap(accounts.compactMap {id->(String,[String:Any])? in
            let value=try JSONSerialization.jsonObject(with:backend.read(id:id)) as! [String:Any];return value["token"]==nil ? nil:(id,value)
        }.first)
        if delivery.1["membershipPreparation"] != nil {
            XCTAssertThrowsError(try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env))
            let operation=try SyncMembershipPreparationOwner.open(root:library.root,environment:env)
            do {try operation.applyMembership();let reply=try XCTUnwrap(operation.completedResponse());XCTAssertEqual(SyncProtocolLimits.hex(Data(reply.response.utf8)),observed["responseSHA256"] as? String);try operation.close()}
            catch {try? operation.close();throw error}
        }
        let (fresh,resumed)=try native("main"),(_,joining)=try native("peer"),reply=try XCTUnwrap(resumed.lastApprovedResponse())
        XCTAssertEqual(SyncProtocolLimits.hex(Data(reply.response.utf8)),observed["responseSHA256"] as? String);XCTAssertEqual(reply.response.utf8.count,observed["responseBytes"] as? Int)
        XCTAssertEqual(reply.approvedAt,now);XCTAssertNotNil(try fresh.get("canary"));XCTAssertTrue(try resumed.status().lastResponseAvailable)
        _=try joining.acceptResponse(reply.response,trustedRootFingerprint:fingerprint,now:now)
        XCTAssertEqual(backend.accounts,accounts)
        for id in accounts {
            let before=try JSONSerialization.jsonObject(with:XCTUnwrap(originals[id])) as! [String:Any],after=try JSONSerialization.jsonObject(with:backend.read(id:id)) as! [String:Any]
            guard let old=before["material"] as? String else {continue}
            let oldKeys=try JSONSerialization.jsonObject(with:XCTUnwrap(Data(base64Encoded:old))) as! [String:Any],newKeys=try JSONSerialization.jsonObject(with:XCTUnwrap(Data(base64Encoded:XCTUnwrap(after["material"] as? String)))) as! [String:Any]
            for key in ["signingPrivate","agreementPrivate","groupSecret","ownerPrivate"] {XCTAssertTrue((oldKeys[key] as? String)==(newKeys[key] as? String),"Original private keys changed")}
        }
        resumed.close();joining.close();try fresh.close();stores.forEach {try? $0.close()};try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
        print("OWNED_DELIVERY_APPROVAL_DEATH phase=\(phase) signal=9 exactResponse=true originalAccounts=3 cleaned=true")
    }
    func testOwnedDeliveredApprovalCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_DELIVERY_APPROVAL_CRASH_ROOT"],let nonce=env["OSWIND_DELIVERY_APPROVAL_CRASH_NONCE"],let phase=env["OSWIND_DELIVERY_APPROVAL_CRASH_PHASE"] else {throw XCTSkip("Only run as owned delivered approval crash child")}
        guard UUID(uuidString:nonce)?.uuidString==nonce,Self.phases.contains(phase) else {throw OSwindError.invalid("Invalid owned delivered approval crash scope")}
        let root=URL(fileURLWithPath:path),expected=fm.temporaryDirectory.appendingPathComponent("owned-delivery-approval-crash-"+nonce)
        guard root.resolvingSymlinksInPath()==expected.resolvingSymlinksInPath(),try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OSwindError.invalid("Owned crash root differs")}
        let ids=try SyncPairingFormat.decode([String].self,Data(contentsOf:root.appendingPathComponent("accounts")),limit:2048)
        guard ids.count==3,Set(ids).count==3 else {throw OSwindError.invalid("Use the three original accounts")};try ids.forEach {try SyncCredentialStorageLimits.validate(id:$0)}
        let backend=DeliveredApprovalCrashStorage(root:root,phase:phase,ids:Set(ids)),state=root.appendingPathComponent("state"),mac=MacSyncMachineFingerprint(),native=SyncNativeWriterEnvironment(stateRoot:state,machine:mac,storage:{_ in backend})
        let library=try MemoryStore(root:root.appendingPathComponent("main"),recoveryReadOnly:false,nativeWriterEnvironment:native)
        let handle=try library.withRoutineDatabase {$0.handle}
        sqlite3_trace_v2(handle,UInt32(SQLITE_TRACE_PROFILE),{mask,context,statement,_ in
            guard mask==UInt32(SQLITE_TRACE_PROFILE),let context,let statement,let sql=sqlite3_sql(OpaquePointer(statement)) else {return 0}
            let storage=Unmanaged<DeliveredApprovalCrashStorage>.fromOpaque(context).takeUnretainedValue()
            if storage.phase=="commit",storage.armed,String(cString:sql).trimmingCharacters(in:.whitespacesAndNewlines).uppercased()=="COMMIT" {try? storage.hold()};return 0
        },Unmanaged.passUnretained(backend).toOpaque())
        let pairing=try PersonalSyncPairing(store:library,stateRoot:state,machine:mac,storage:backend),request=try String(contentsOf:root.appendingPathComponent("request"),encoding:.utf8),review=try pairing.reviewDeliveredRequest(request,now:now)
        pairing.close()
        let operation=try SyncMembershipPreparationOwner.prepareApproval(library:library,review:review,environment:native,clock:{self.now})
        try operation.applyMembership();_=try XCTUnwrap(operation.completedResponse());try operation.close()
        guard phase=="after-response" else {throw OSwindError.invalid("Owned private boundary did not stop")}
        try backend.hold()
    }
}

private final class DeliveredApprovalCrashStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    let root:URL,phase:String,ids:Set<String>
    private let backend=SyncKeychainCredentialStorage(protection:.loginKeychain)
    private var replacements=0
    var armed=false
    init(root:URL,phase:String,ids:Set<String>) {self.root=root;self.phase=phase;self.ids=ids}
    func create(id:String,bytes:Data)throws {throw OSwindError.invalid("Crash child cannot create accounts")}
    func read(id:String)throws->Data {guard ids.contains(id) else {throw OSwindError.invalid("Unowned account refused")};return try backend.read(id:id)}
    func remove(id:String,expected:Data)throws {throw OSwindError.invalid("Crash child cannot remove accounts")}
    func replace(id:String,expected:Data,bytes:Data)throws {
        guard ids.contains(id) else {throw OSwindError.invalid("Unowned account refused")}
        try backend.replace(id:id,expected:expected,bytes:bytes);replacements+=1
        if replacements==4 {armed=true}
        if ["intent":1,"decision":2,"pairing":3,"delivery":4,"clear":5][phase]==replacements {try hold()}
    }
    func hold()throws {
        let envelope=try XCTUnwrap(ids.compactMap {id->[String:Any]? in let object=try JSONSerialization.jsonObject(with:backend.read(id:id)) as! [String:Any];return object["token"]==nil ? nil:object}.first)
        let pointer:Any
        if let pending=envelope["membershipPreparation"] as? [String:Any] {pointer=try XCTUnwrap(pending["approval"])}else {pointer=try XCTUnwrap(envelope["completedApproval"])}
        let reference=try SyncPairingFormat.decode(SyncDeliveryApprovalReference.self,JSONSerialization.data(withJSONObject:pointer,options:[.sortedKeys,.withoutEscapingSlashes]),limit:4096)
        let material=try SyncCredentialMaterial.decodeFromKeychain(XCTUnwrap(Data(base64Encoded:XCTUnwrap(envelope["material"] as? String))))
        let inbox=try material.joined.openPrivateInbox(at:root.appendingPathComponent("main/images/device-sync-"+material.joined.replica));defer {inbox.close()}
        let plan=try SyncOwnerApprovalPlan.decode(XCTUnwrap(inbox.content(reference.approval.content)))
        try plan.require(reference.approval,current:plan.certificate,pairingID:reference.approval.pairingID,lifetime:reference.approval.lifetime)
        let observation:[String:Any]=["phase":phase,"responseSHA256":SyncProtocolLimits.hex(plan.response),"responseBytes":plan.response.count]
        try JSONSerialization.data(withJSONObject:observation,options:[.sortedKeys]).write(to:root.appendingPathComponent("ready"),options:.withoutOverwriting)
        while true {Thread.sleep(forTimeInterval:0.1)}
    }
}
