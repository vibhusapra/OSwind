import XCTest
import Foundation
import CSQLite
import Darwin
@testable import OSwindCore

/// Actual predecessor engine, including a positively admitted cached statement.
/// Unknown completed authority must refuse without dropping the response.
final class SyncCompletedResponseCompatibilityTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    func testOwnedPredecessorFormat2RefusesCachedAndFreshCompletedResponseWrites()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard env["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1",let manifestPath=env["OSWIND_TEST_PREDECESSOR_FORMAT2_MANIFEST"] else {throw XCTSkip("Explicit frozen predecessor engine and generated login-Keychain accounts")}
        let manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:manifestPath))) as? [String:Any])
        XCTAssertEqual(manifest["originalRuntime"] as? String,"ad32c6cd938b77edf2017bb206c07d24cdd3a855")
        let bundle=URL(fileURLWithPath:try XCTUnwrap(manifest["bundle"] as? String)),files=try XCTUnwrap(manifest["files"] as? [String:String])
        guard !files.isEmpty,files["Contents/MacOS/OSwindPackageTests"] != nil else {throw OSwindError.invalid("Missing predecessor executable manifest")}
        for (path,hash) in files {guard !path.hasPrefix("/"),!path.split(separator:"/").contains(".."),try SyncProtocolLimits.hex(Data(contentsOf:bundle.appendingPathComponent(path)))==hash else {throw OSwindError.invalid("Changed frozen predecessor bundle")}}
        let nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("owned-completed-format2-"+nonce),backend=NativeWriterKeychainFixture()
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var stores=[MemoryStore](),pairings=[PersonalSyncPairing](),operations=[SyncMembershipPreparationOwner](),children=[Process](),outputs=[FileHandle]()
        defer {
            for child in children {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
            outputs.forEach {try? $0.close()};operations.forEach {try? $0.close()};pairings.forEach {$0.close()};stores.forEach {try? $0.close()}
            do {try backend.cleanup()}catch {XCTFail("Owned predecessor accounts could not be removed")}
            try? fm.removeItem(at:root)
        }
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        let native=SyncNativeWriterEnvironment(stateRoot:root.appendingPathComponent("state"),machine:MacSyncMachineFingerprint(),storage:{_ in backend})
        func store(_ name:String)throws->MemoryStore {let value=try MemoryStore(root:root.appendingPathComponent(name),recoveryReadOnly:false,nativeWriterEnvironment:native);stores.append(value);return value}
        func pair(_ store:MemoryStore)throws->PersonalSyncPairing {let value=try PersonalSyncPairing(store:store,stateRoot:native.stateRoot,machine:native.machine,storage:backend);pairings.append(value);return value}
        let library=try store("main"),owner=try pair(library),first=try pair(store("first")),third=try pair(store("third")),joining=try pair(store("joining"))
        _=try owner.createGroup(deviceName:"Owned predecessor desk",now:now)
        let rootFingerprint=try XCTUnwrap(owner.status().rootFingerprint),initial=try XCTUnwrap(first.requestJoin(deviceName:"Owned initial peer",now:now).request)
        _=try first.acceptResponse(owner.approve(owner.reviewRequest(initial,now:now),now:now),trustedRootFingerprint:rootFingerprint,now:now);first.close()
        let service=try owner.prepareAnchoredService(shared:root.appendingPathComponent("provider"),createShared:true)
        try service.installNativeWriterAdmission();try library.insert(Memory(id:"canary",text:"Owned completed-response compatibility source"))
        try service.stop();service.inbox.close();service.transport.close();owner.close()
        // Reach genuine format2 through the previously supported pure-proof
        // handover, before generating any completed joining-response field.
        let thirdRequest=try XCTUnwrap(third.requestJoin(deviceName:"Owned pure-proof peer",now:now).request)
        let pairingID=try library.withRoutineDatabase {db->String in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-pairing-handle-v1'");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Missing original pairing handle")}
            let handle=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(db.text(row,0).utf8)) as? [String:Any]);return try XCTUnwrap(handle["id"] as? String)
        }
        let saved=try XCTUnwrap(JSONSerialization.jsonObject(with:backend.read(id:pairingID)) as? [String:Any]),material=try SyncCredentialMaterial.decodeFromKeychain(XCTUnwrap(Data(base64Encoded:XCTUnwrap(saved["material"] as? String)))),authority=try XCTUnwrap(material.owner)
        let next=try authority.admitting(SyncJoinRequest.decode(Data(thirdRequest.utf8),now:now),now:now),proof=try SyncMembershipRefresh(base:authority.certificate,updates:[next.certificate])
        let pure=try SyncMembershipPreparationOwner.prepare(library:library,proof:proof,environment:native);operations.append(pure);try pure.applyMembership();try pure.close()
        let current=try store("main");XCTAssertEqual(try current.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2)
        let text=try XCTUnwrap(joining.requestJoin(deviceName:"Owned final joining Mac",now:now).request)
        let accounts=backend.accounts;XCTAssertEqual(accounts.count,5)
        try SyncProtocolLimits.encode(accounts).write(to:root.appendingPathComponent("accounts"),options:.withoutOverwriting)
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath();guard runner.lastPathComponent=="xctest" else {throw OSwindError.invalid("Owned XCTest runner required")}
        func launch(_ mode:String)throws->Process {
            let child=Process(),log=root.appendingPathComponent(mode+".log");XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil));let output=try FileHandle(forWritingTo:log);outputs.append(output)
            child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.FrozenFormat2WorkerTests/testOwnedFormat2Worker",bundle.path]
            child.environment=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_OLD_FORMAT2_ROOT":root.path,"OSWIND_OLD_FORMAT2_NONCE":nonce,"OSWIND_OLD_FORMAT2_MODE":mode]
            child.standardInput=FileHandle.nullDevice;child.standardOutput=output;child.standardError=output;try child.run();children.append(child);return child
        }
        func wait(_ child:Process,ready:Bool,mode:String)throws {
            let deadline=ProcessInfo.processInfo.systemUptime+40
            while child.isRunning,ProcessInfo.processInfo.systemUptime<deadline {
                if ready,fm.fileExists(atPath:root.appendingPathComponent("ready-cached").path) {return}
                Thread.sleep(forTimeInterval:0.01)
            }
            guard !ready,!child.isRunning else {throw OSwindError.unavailable("Owned predecessor missed its exact completion boundary")}
            child.waitUntilExit();guard child.terminationReason == .exit,child.terminationStatus==0 else {throw OSwindError.unavailable("Owned predecessor failed: "+((try? String(contentsOf:root.appendingPathComponent(mode+".log"),encoding:.utf8)) ?? "missing log"))}
        }
        print("OWNED_PREDECESSOR_STAGE before-positive-cached")
        let cached=try launch("cached");try wait(cached,ready:true,mode:"cached")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("ready-cached"),encoding:.utf8),"format2-admitted-written-prepared")
        print("OWNED_PREDECESSOR_STAGE before-approval")
        let approving=try pair(current),review=try approving.reviewDeliveredRequest(text,now:now);approving.close()
        let operation=try SyncMembershipPreparationOwner.prepareApproval(library:current,review:review,environment:native,clock:{self.now});operations.append(operation)
        try operation.applyMembership();let response=try XCTUnwrap(operation.completedResponse())
        print("OWNED_PREDECESSOR_STAGE approved-before-release")
        try Data("release".utf8).write(to:root.appendingPathComponent("release-cached"),options:.withoutOverwriting)
        try wait(cached,ready:false,mode:"cached");XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("result-cached"),encoding:.utf8),"cached-and-normal-refused")
        try operation.close();let beforeFresh=try Dictionary(uniqueKeysWithValues:accounts.map {($0,try backend.read(id:$0))})
        let freshOld=try launch("refuse");try wait(freshOld,ready:false,mode:"refuse")
        print("OWNED_PREDECESSOR_STAGE fresh-refused")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("result-refuse"),encoding:.utf8),"unknown-authority-refused")
        for id in accounts {XCTAssertTrue(try backend.read(id:id)==beforeFresh[id],"Fresh predecessor changed original private authority")}
        let fresh=try store("main"),resumed=try pair(fresh)
        // The old prepared statement intentionally updates the SQL column,
        // while get() reads the separate serialized payload.
        let title=try fresh.withRoutineDatabase {db->String in
            let row=try db.statement("SELECT title FROM memories WHERE id='canary'");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Original compatibility canary is missing")};return db.text(row,0)
        }
        XCTAssertEqual(title,"predecessor-positive");XCTAssertEqual(try fresh.get("canary")?.text,"Owned completed-response compatibility source");XCTAssertNil(try fresh.get("predecessor-must-refuse"))
        XCTAssertEqual(try resumed.lastApprovedResponse(),response)
        try fresh.insert(Memory(id:"current-positive",text:"Current writer preserves exact completed response"));XCTAssertNotNil(try fresh.get("current-positive"))
        XCTAssertEqual(try resumed.lastApprovedResponse(),response)
        _=try joining.acceptResponse(response.response,trustedRootFingerprint:rootFingerprint,now:now)
        pairings.forEach {$0.close()};try stores.forEach {try $0.close()};try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
        guard testRun?.totalFailureCount==0 else {return}
        print("OWNED_PREDECESSOR_FORMAT2 admittedWrittenPrepared=true cachedAndFreshRefused=true exactCompletedResponse=true currentWriter=true recipientAccepted=true originalAccountsCleaned=5")
    }
}
