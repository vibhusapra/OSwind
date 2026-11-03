import XCTest
import CSQLite
import CryptoKit
import Darwin
@testable import OSwindCore

final class SyncMembershipPreparationTests:XCTestCase {
    private var root:URL!,stores=[MemoryStore](),pairings=[PersonalSyncPairing](),services=[SyncLibraryService](),operations=[SyncMembershipPreparationOwner]()
    private var storage=MembershipPreparationStorage(),serial=0
    private let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"a",count:64))
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    private var environment:SyncNativeWriterEnvironment {.init(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{[storage] protection in storage.requested(protection);return storage})}
    private struct Fixture {
        let store:MemoryStore,proof:SyncMembershipRefresh,shared:URL,pairingID:String,deliveryID:String,oldPairing:Data,oldMaterial:String,peerCount:Int
        let third:MemoryStore,thirdPairing:PersonalSyncPairing
    }
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-membership-preparation-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
    override func tearDownWithError()throws {
        storage.didReplace=nil
        try operations.forEach {try $0.close()};services.forEach {try? $0.stop();$0.inbox.close();$0.transport.close()};pairings.forEach {$0.close()};try stores.forEach {try $0.close()};try FileManager.default.removeItem(at:root)
    }
    private func store(_ url:URL)throws->MemoryStore {
        let value=try MemoryStore(root:url,recoveryReadOnly:false,nativeWriterEnvironment:environment);stores.append(value);return value
    }
    private func pair(_ store:MemoryStore)throws->PersonalSyncPairing {
        let value=try PersonalSyncPairing(store:store,stateRoot:environment.stateRoot,machine:machine,storage:storage);pairings.append(value);return value
    }
    private func join(_ peer:PersonalSyncPairing,to owner:PersonalSyncPairing,name:String)throws {
        let request=try XCTUnwrap(peer.requestJoin(deviceName:name,now:now).request),response=try owner.approve(owner.reviewRequest(request,now:now),now:now)
        _=try peer.acceptResponse(response,trustedRootFingerprint:XCTUnwrap(owner.status().rootFingerprint),now:now)
    }
    private func object(_ data:Data)throws->[String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])}
    private func read(_ library:URL,_ sql:String)throws->String {
        var db:OpaquePointer?;guard sqlite3_open_v2(library.appendingPathComponent("memory.sqlite").path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {sqlite3_close(db);throw OSwindError.invalid("Owned immutable membership read failed")};defer {sqlite3_close(db)}
        var row:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&row,nil)==SQLITE_OK else {throw OSwindError.invalid("Owned membership query failed")};defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_bytes(row,0)<=262144,let text=sqlite3_column_text(row,0) else {throw OSwindError.invalid("Owned membership query has no bounded result")}
        return String(decoding:UnsafeBufferPointer(start:text,count:Int(sqlite3_column_bytes(row,0))),as:UTF8.self)
    }
    private func fixture(beforePairing:(MemoryStore)throws->Void={_ in})throws->Fixture {
        serial+=1;let base=root.appendingPathComponent("case-\(serial)"),a=try store(base.appendingPathComponent("owner")),b=try store(base.appendingPathComponent("peer")),c=try store(base.appendingPathComponent("third"))
        try beforePairing(b)
        let owner=try pair(a),peer=try pair(b),third=try pair(c);_=try owner.createGroup(deviceName:"Owned desk",now:now)
        try join(peer,to:owner,name:"Owned travel");let prior=try peer.membershipCertificateForRefresh();try join(third,to:owner,name:"Owned third")
        let proof=try XCTUnwrap(owner.membershipRefresh(after:prior)),shared=base.appendingPathComponent("shared")
        let service=try peer.prepareAnchoredService(shared:shared,createShared:true);services.append(service);try service.installNativeWriterAdmission()
        try b.insert(Memory(id:"canary",kind:.note,text:"Owned local intent before membership fence"))
        try service.stop();service.inbox.close();service.transport.close();peer.close()
        let handle=try object(Data(read(b.root,"SELECT value FROM store_metadata WHERE key='sync-pairing-handle-v1'").utf8)),pairingID=try XCTUnwrap(handle["id"] as? String),deliveryID=try read(b.root,"SELECT id FROM personal_sync_delivery_anchor")
        let saved=try XCTUnwrap(storage.values[pairingID]),material=try XCTUnwrap(object(saved)["material"] as? String)
        XCTAssertEqual(try read(b.root,"PRAGMA user_version"),"35")
        return .init(store:b,proof:proof,shared:shared,pairingID:pairingID,deliveryID:deliveryID,oldPairing:saved,oldMaterial:material,peerCount:2,third:c,thirdPairing:third)
    }
    private func prepare(_ f:Fixture)throws->SyncMembershipPreparationOwner {
        let op=try SyncMembershipPreparationOwner.prepare(library:f.store,proof:f.proof,environment:environment);operations.append(op);return op
    }
    private func recover(_ f:Fixture)throws->SyncMembershipPreparationOwner {
        let op=try SyncMembershipPreparationOwner.open(root:f.store.root,environment:environment);operations.append(op);return op
    }
    private func files(_ root:URL)throws->[String:String] {
        let enumerator=try XCTUnwrap(FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey]));var result=[String:String]()
        for case let path as URL in enumerator where try path.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true {result[String(path.path.dropFirst(root.path.count+1))]=SyncProtocolLimits.hex(try Data(contentsOf:path))};return result
    }
    private func assertOriginal(_ f:Fixture,file:StaticString=#filePath,line:UInt=#line)throws {
        XCTAssertTrue(storage.values[f.pairingID]==f.oldPairing,"Preparation changed pairing authority",file:file,line:line)
        let envelope=try object(XCTUnwrap(storage.values[f.deliveryID]));XCTAssertTrue((envelope["material"] as? String)==f.oldMaterial,"Preparation changed private delivery material",file:file,line:line)
        XCTAssertEqual(try read(f.store.root,"SELECT COUNT(*) FROM personal_sync_peers"),String(f.peerCount),file:file,line:line)
    }
    private func finish(_ f:Fixture,_ operation:SyncMembershipPreparationOwner)throws->MemoryStore {
        try operation.cancelBeforeHandover();try operation.close();let fresh=try store(f.store.root)
        XCTAssertEqual(try read(f.store.root,"PRAGMA user_version"),"36");XCTAssertEqual(try read(f.store.root,"SELECT value FROM store_metadata WHERE key='sync-native-membership-phase-v1'"),"active")
        try assertOriginal(f);XCTAssertNotNil(try fresh.get("canary"));return fresh
    }
    func testCommittedFenceRejectsCachedPreparedWritersAndCancellationKeepsOriginalMembership()throws {
        let f=try fixture(),provider=try files(f.shared),accounts=storage.values.count,stale=try store(f.store.root)
        let row=try stale.withRoutineDatabase {try $0.statement("UPDATE memories SET title='Stale prepared writer' WHERE id='canary'")};defer {sqlite3_finalize(row)}
        let op=try prepare(f)
        XCTAssertEqual(try read(f.store.root,"PRAGMA user_version"),"36");XCTAssertEqual(try read(f.store.root,"SELECT value FROM store_metadata WHERE key='sync-native-membership-phase-v1'"),"prepared")
        XCTAssertEqual(try read(f.store.root,"SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_native_writer_%' AND instr(sql,'oswind_native_sync_membership_v1')=0"),"0")
        XCTAssertEqual(try read(f.store.root,"SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'sync_native_membership_metadata_%'"),"3")
        XCTAssertThrowsError(try f.store.get("canary"));XCTAssertThrowsError(try store(f.store.root));XCTAssertNotEqual(sqlite3_step(row),SQLITE_DONE)
        try assertOriginal(f);let fresh=try finish(f,op)
        XCTAssertNotEqual(sqlite3_step(row),SQLITE_DONE);XCTAssertThrowsError(try stale.get("canary"))
        try fresh.insert(Memory(id:"fresh",text:"Fresh verified native36 writer"));XCTAssertNotNil(try fresh.get("fresh"))
        XCTAssertEqual(try files(f.shared),provider);XCTAssertEqual(storage.values.count,accounts)
        XCTAssertGreaterThan(Int(try read(f.store.root,"SELECT COUNT(*) FROM personal_sync_changes")) ?? 0,0)
    }
    func testRejectedPreparationCommitRecoversExactFenceAndPreservesLegitimatePreFenceWrite()throws {
        let f=try fixture(),stale=try store(f.store.root),provider=try files(f.shared),gate=MembershipCommitGate()
        let handle=try f.store.withRoutineDatabase {$0.handle}
        storage.didReplace={_ in sqlite3_commit_hook(handle,MembershipCommitGate.callback,Unmanaged.passUnretained(gate).toOpaque())}
        XCTAssertThrowsError(try prepare(f));storage.didReplace=nil;sqlite3_commit_hook(handle,nil,nil)
        XCTAssertEqual(gate.rejections,1);try assertOriginal(f)
        XCTAssertEqual(try read(f.store.root,"PRAGMA user_version"),"35")
        try stale.insert(Memory(id:"pre-fence",text:"Legitimate raw capture before the fence committed"))
        try f.store.close();XCTAssertThrowsError(try store(f.store.root))
        let resumed=try recover(f);try resumed.resumeFence();XCTAssertThrowsError(try stale.insert(Memory(id:"post-fence",text:"Must refuse")))
        let fresh=try finish(f,resumed);XCTAssertNotNil(try fresh.get("pre-fence"));XCTAssertNil(try fresh.get("post-fence"));XCTAssertEqual(try files(f.shared),provider)
    }
    func testAmbiguousPreparationSaveCannotAdvancePrivateMembershipAndResumesWithoutReplacementAccounts()throws {
        for after in [false,true] {
            let f=try fixture(),count=storage.values.count;storage.failAt=storage.attempts+1;storage.failAfter=after
            XCTAssertThrowsError(try prepare(f));try f.store.close();try assertOriginal(f)
            if after {XCTAssertThrowsError(try store(f.store.root));let resumed=try recover(f);try resumed.resumeFence();_=try finish(f,resumed)}
            else {let fresh=try store(f.store.root);XCTAssertNotNil(try fresh.get("canary"));XCTAssertEqual(try read(f.store.root,"PRAGMA user_version"),"35");XCTAssertThrowsError(try recover(f))}
            XCTAssertEqual(storage.values.count,count)
        }
    }
    func testCancellationRecoversBeforeAndAfterEveryExternalBoundary()throws {
        for boundary in 1...3 {for after in [false,true] {
            let f=try fixture(),op=try prepare(f),provider=try files(f.shared),count=storage.values.count
            storage.failAt=storage.attempts+boundary;storage.failAfter=after
            XCTAssertThrowsError(try op.cancelBeforeHandover(),"Owned boundary \(boundary), after=\(after)");try op.close();try assertOriginal(f)
            let envelope=try object(XCTUnwrap(storage.values[f.deliveryID]))
            if envelope["membershipPreparation"]==nil {
                // The final clear committed before its injected error.
                let fresh=try store(f.store.root);XCTAssertNotNil(try fresh.get("canary"));XCTAssertThrowsError(try recover(f))
            }else {let resumed=try recover(f);_=try finish(f,resumed)}
            XCTAssertEqual(storage.values.count,count);XCTAssertEqual(try files(f.shared),provider)
        }}
    }
    func testRejectedCancellationCommitReplaysExactSavedCheckpoint()throws {
        let f=try fixture(),op=try prepare(f),handle=try f.store.withMembershipDatabase {$0.handle},gate=MembershipCommitGate(),target=storage.attempts+2
        storage.didReplace={ordinal in if ordinal==target {sqlite3_commit_hook(handle,MembershipCommitGate.callback,Unmanaged.passUnretained(gate).toOpaque())}}
        XCTAssertThrowsError(try op.cancelBeforeHandover());storage.didReplace=nil;sqlite3_commit_hook(handle,nil,nil);try op.close();XCTAssertEqual(gate.rejections,1)
        let envelope=try object(XCTUnwrap(storage.values[f.deliveryID])),token=try XCTUnwrap(envelope["token"] as? [String:Any]),floor=try XCTUnwrap(token["serial"] as? Int64)
        let resumed=try recover(f);_=try finish(f,resumed)
        XCTAssertEqual(Int64(try read(f.store.root,"SELECT serial FROM personal_sync_delivery_anchor")),floor)
    }
    func testRecoveryRefusesCloneMissingEncryptedPlanAndChangedPairingWithoutRegeneration()throws {
        let f=try fixture(),op=try prepare(f),provider=try files(f.shared);try op.close();let accounts=storage.values
        let absent=root.appendingPathComponent("never-created");XCTAssertThrowsError(try SyncMembershipPreparationOwner.prepare(root:absent,proof:f.proof,environment:environment));XCTAssertFalse(FileManager.default.fileExists(atPath:absent.path))
        let clone=root.appendingPathComponent("clone");try FileManager.default.copyItem(at:f.store.root,to:clone)
        XCTAssertThrowsError(try SyncMembershipPreparationOwner.open(root:clone,environment:environment));XCTAssertTrue(storage.values==accounts)
        let inbox=f.store.root.appendingPathComponent("images/device-sync-"+f.proof.base.body.members.first(where:{$0.name=="Owned travel"})!.replica),parked=f.store.root.appendingPathComponent("images/parked-inbox")
        try FileManager.default.moveItem(at:inbox,to:parked);XCTAssertThrowsError(try recover(f));XCTAssertFalse(FileManager.default.fileExists(atPath:inbox.path));XCTAssertTrue(storage.values==accounts)
        try FileManager.default.moveItem(at:parked,to:inbox)
        var changed=try object(f.oldPairing);changed["consumedRequest"]=String(repeating:"0",count:64)
        storage.overwrite(f.pairingID,bytes:try JSONSerialization.data(withJSONObject:changed,options:[.sortedKeys,.withoutEscapingSlashes]))
        XCTAssertThrowsError(try recover(f));storage.overwrite(f.pairingID,bytes:f.oldPairing)
        let resumed=try recover(f);_=try finish(f,resumed);XCTAssertEqual(try files(f.shared),provider)
    }
    func testNativePhaseAndReservedMetadataCannotBeChangedByOrdinaryWriters()throws {
        let f=try fixture(),op=try prepare(f),fresh=try finish(f,op)
        for sql in ["UPDATE store_metadata SET value='prepared' WHERE key='sync-native-membership-phase-v1'","DELETE FROM store_metadata WHERE key='sync-native-membership-state-v1'","INSERT OR REPLACE INTO store_metadata VALUES('sync-native-membership-phase-v1','active')","UPDATE store_metadata SET key='renamed-state' WHERE key='sync-native-membership-state-v1'"] {XCTAssertThrowsError(try fresh.withRoutineDatabase {try $0.execute(sql)})}
        try fresh.insert(Memory(id:"after-refused-change",text:"Ordinary content remains writable"));XCTAssertNotNil(try fresh.get("after-refused-change"))
        try fresh.close()
        let g=try fixture(),prepared=try prepare(g)
        try g.store.withMembershipDatabase {db in try g.store.nativeWriterAdmission.withMembershipMutation(db) {try db.execute("UPDATE store_metadata SET value='active' WHERE key='sync-native-membership-phase-v1'")}}
        try prepared.close();let values=storage.values
        XCTAssertThrowsError(try recover(g));XCTAssertTrue(storage.values==values)
    }
    func testPreparationReservesCancellationCapacityAndReplaysOneExactTarget()throws {
        let f=try fixture(),op=try prepare(f),envelope=try object(XCTUnwrap(storage.values[f.deliveryID]))
        var raw=try XCTUnwrap(envelope["membershipPreparation"] as? [String:Any])
        for before in [Int64.max-3,Int64.max-2,Int64.max-1] {
            var a=try XCTUnwrap(raw["tokenBefore"] as? [String:Any]),b=try XCTUnwrap(raw["tokenPrepared"] as? [String:Any]);a["serial"]=before;b["serial"]=before+1;raw["tokenBefore"]=a;raw["tokenPrepared"]=b
            let bytes=try JSONSerialization.data(withJSONObject:raw,options:[.sortedKeys,.withoutEscapingSlashes]),record=try SyncPairingFormat.decode(SyncMembershipPreparation.self,bytes,limit:4096)
            if before==Int64.max-3 {try record.validate();XCTAssertEqual(record.tokenCancelled.serial,Int64.max-1);XCTAssertEqual(record.tokenCancelled,record.tokenCancelled)}
            else {XCTAssertThrowsError(try record.validate())}
        }
        _=try finish(f,op)
    }
    func testRefreshedOwnerMaterialRetainsEveryOriginalPrivateKeyAndCanApproveAgain()throws {
        let (owner,peer)=try SyncCredentialMaterialTests().fixture(),authority=try XCTUnwrap(owner.owner),third=try SyncPendingJoin(name:"Owned third"),next=try authority.admitting(third.request),proof=try SyncMembershipRefresh(base:authority.certificate,updates:[next.certificate])
        for material in [owner,peer] {
            let updated=try material.withMembershipRefresh(proof),before=try object(material.encodedForKeychain()),after=try object(updated.encodedForKeychain())
            for key in ["signingPrivate","agreementPrivate","groupSecret","ownerPrivate"] {XCTAssertTrue((before[key] as? String)==(after[key] as? String),"Membership derivation changed private material")}
            XCTAssertEqual(updated.joined.certificate,next.certificate)
            if let root=updated.owner {let fourth=try SyncPendingJoin(name:"Owned fourth"),approved=try root.admitting(fourth.request);XCTAssertEqual(try fourth.accept(approved.response(to:fourth.request),expectedRootFingerprint:root.fingerprint).certificate.body.members.count,4)}
            else {XCTAssertNil(material.owner)}
        }
    }
    func testPreparationUsesSavedDataProtectionTierWithoutFallback()throws {
        storage=MembershipPreparationStorage(protection:.dataProtectionKeychain)
        let f=try fixture(),op=try prepare(f);_=try finish(f,op)
        XCTAssertFalse(storage.requests.isEmpty);XCTAssertTrue(storage.requests.allSatisfy {$0 == .dataProtectionKeychain},"A saved tier was replaced with the default login tier")
    }
    func testOwnedNativeKeychainPreparationReopensAndCancelsOriginalAccounts()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned native Keychain membership preparation fixture")}
        let backend=NativeWriterKeychainFixture(),state=root.appendingPathComponent("native-state"),mac=MacSyncMachineFingerprint(),env=SyncNativeWriterEnvironment(stateRoot:state,machine:mac,storage:{_ in backend})
        defer {do {try backend.cleanup()}catch {XCTFail("Owned preparation Keychain cleanup failed")}}
        func native(_ path:String)throws->(MemoryStore,PersonalSyncPairing) {
            let library=try MemoryStore(root:root.appendingPathComponent(path),recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(library)
            let pairing=try PersonalSyncPairing(store:library,stateRoot:state,machine:mac,storage:backend);pairings.append(pairing);return (library,pairing)
        }
        let (_,owner)=try native("native-owner"),(library,peer)=try native("native-peer"),(_,third)=try native("native-third")
        _=try owner.createGroup(deviceName:"Owned native desk",now:now);try join(peer,to:owner,name:"Owned native travel");let prior=try peer.membershipCertificateForRefresh();try join(third,to:owner,name:"Owned native third")
        let proof=try XCTUnwrap(owner.membershipRefresh(after:prior)),service=try peer.prepareAnchoredService(shared:root.appendingPathComponent("native-shared"),createShared:true);services.append(service);try service.installNativeWriterAdmission()
        try service.stop();service.inbox.close();service.transport.close();peer.close()
        let accounts=backend.accounts,op=try SyncMembershipPreparationOwner.prepare(library:library,proof:proof,environment:env);operations.append(op);try op.close()
        XCTAssertThrowsError(try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env))
        let resumed=try SyncMembershipPreparationOwner.open(root:library.root,environment:env);operations.append(resumed);try resumed.resumeFence();try resumed.cancelBeforeHandover();try resumed.close()
        let fresh=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(fresh);try fresh.insert(Memory(id:"native-reopened",text:"Original native accounts after cancelled membership fence"));XCTAssertNotNil(try fresh.get("native-reopened"));XCTAssertEqual(backend.accounts,accounts);XCTAssertEqual(accounts.count,4)
        try fresh.close();owner.close();third.close();try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
    }
    func testOwnedNativeKeychainHandoverReopensNewMembershipWithOriginalAccounts()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned native Keychain membership preparation fixture")}
        let backend=NativeWriterKeychainFixture(),state=root.appendingPathComponent("native-state"),mac=MacSyncMachineFingerprint(),env=SyncNativeWriterEnvironment(stateRoot:state,machine:mac,storage:{_ in backend})
        defer {do {try backend.cleanup()}catch {XCTFail("Owned preparation Keychain cleanup failed")}}
        func native(_ path:String)throws->(MemoryStore,PersonalSyncPairing) {
            let library=try MemoryStore(root:root.appendingPathComponent(path),recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(library)
            let pairing=try PersonalSyncPairing(store:library,stateRoot:state,machine:mac,storage:backend);pairings.append(pairing);return (library,pairing)
        }
        let (_,owner)=try native("native-owner"),(library,peer)=try native("native-peer"),(_,third)=try native("native-third")
        _=try owner.createGroup(deviceName:"Owned native desk",now:now);try join(peer,to:owner,name:"Owned native travel");let prior=try peer.membershipCertificateForRefresh();try join(third,to:owner,name:"Owned native third")
        let proof=try XCTUnwrap(owner.membershipRefresh(after:prior)),service=try peer.prepareAnchoredService(shared:root.appendingPathComponent("native-shared"),createShared:true);services.append(service);try service.installNativeWriterAdmission()
        try service.stop();service.inbox.close();service.transport.close();peer.close()
        let accounts=backend.accounts,op=try SyncMembershipPreparationOwner.prepare(library:library,proof:proof,environment:env);operations.append(op);try op.close()
        XCTAssertThrowsError(try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env))
        let resumed=try SyncMembershipPreparationOwner.open(root:library.root,environment:env);operations.append(resumed);try resumed.resumeFence();try resumed.applyMembership();try resumed.close()
        let fresh=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:env);stores.append(fresh);try fresh.insert(Memory(id:"native-reopened",text:"Original native accounts after committed membership handover"));XCTAssertNotNil(try fresh.get("native-reopened"));XCTAssertEqual(backend.accounts,accounts);XCTAssertEqual(accounts.count,4)
        let checked=try PersonalSyncPairing(store:fresh,stateRoot:state,machine:mac,storage:backend);pairings.append(checked)
        XCTAssertEqual(try checked.status().memberNames.count,3);checked.close()
        try fresh.close();owner.close();third.close();try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
    }
    func testActualFrozen35ClientWaitingBeforeEnrollmentAndFreshOpenRefuseNative36()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE35_CLI"] else {throw XCTSkip("Requires the exact frozen native35 CLI; never replace that binary")}
        let binary=URL(fileURLWithPath:path),expected="c958f555cf55c962b721f2835c5e9675d922a096bb4a4c0948f59016ec50887d"
        func hash()throws->String {SyncProtocolLimits.hex(try Data(contentsOf:binary))};guard try hash()==expected else {throw OSwindError.invalid("Use the unchanged frozen native35 client")}
        let child=Process(),input=Pipe(),errors=Pipe();var childEnvironment=ProcessInfo.processInfo.environment;childEnvironment.removeValue(forKey:"DYLD_INSERT_LIBRARIES")
        defer {try? input.fileHandleForWriting.close();if child.isRunning {child.terminate();for _ in 0..<100 where child.isRunning {Thread.sleep(forTimeInterval:0.01)};if child.isRunning {kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}}
        let f=try fixture {library in
            childEnvironment["OSWIND_DATA_DIR"]=library.root.path
            let positive=Process();positive.executableURL=binary;positive.arguments=["--data",library.root.path,"stats"];positive.environment=childEnvironment;positive.standardInput=FileHandle.nullDevice;positive.standardOutput=FileHandle.nullDevice;positive.standardError=FileHandle.nullDevice;try positive.run();positive.waitUntilExit();XCTAssertEqual(positive.terminationStatus,0)
            child.executableURL=binary;child.arguments=["--data",library.root.path,"collect","--stdin"];child.environment=childEnvironment;child.standardInput=input;child.standardOutput=FileHandle.nullDevice;child.standardError=errors;try child.run()
            var observed=false;let end=ProcessInfo.processInfo.systemUptime+15
            while child.isRunning,!observed,ProcessInfo.processInfo.systemUptime<end {do {let lease=try MediaAdmissionLease.acquire(root:library.root,exclusive:true,timeout:0,onBusy:{observed=true});lease.release()}catch {if !observed {throw error}};if !observed {Thread.sleep(forTimeInterval:0.02)}}
            guard observed else {throw OSwindError.invalid("Frozen native35 collector did not reserve the owned fixture")}
        }
        let op=try prepare(f)
        let batch="""
        {"format":"OSwind collector batch","version":1,"collectorID":"dev.example.old35","records":[{"key":"owned-35","timestamp":"2026-10-25T05:23:45.123456-07:00","app":"Owned","bundleID":"dev.example.old35","title":"Owned old35","text":"Must not enter native36"}]}
        """
        try input.fileHandleForWriting.write(contentsOf:Data(batch.utf8));try input.fileHandleForWriting.close();let end=ProcessInfo.processInfo.systemUptime+20
        while child.isRunning,ProcessInfo.processInfo.systemUptime<end {Thread.sleep(forTimeInterval:0.02)};guard !child.isRunning else {return XCTFail("Owned frozen35 child did not finish")};child.waitUntilExit();XCTAssertNotEqual(child.terminationStatus,0)
        let message=String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);XCTAssertTrue(message.contains("Reopen") || message.contains("writer admission") || message.contains("oswind_native_sync_membership_v1"),message)
        let fresh=Process(),freshError=Pipe();fresh.executableURL=binary;fresh.arguments=["--data",f.store.root.path,"stats"];fresh.environment=childEnvironment;fresh.standardInput=FileHandle.nullDevice;fresh.standardOutput=FileHandle.nullDevice;fresh.standardError=freshError;try fresh.run();let freshMessage=String(decoding:freshError.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);fresh.waitUntilExit();XCTAssertNotEqual(fresh.terminationStatus,0);XCTAssertTrue(freshMessage.contains("newer OSwind version"))
        _=try finish(f,op);XCTAssertEqual(try hash(),expected)
        print("NATIVE36_FROZEN35_FENCE positive33=true waitingBeforeEnrollmentRefused=true fresh36Refused=true originalBinaryUnchanged=true")
    }
    private func activated(_ f:Fixture,_ op:SyncMembershipPreparationOwner)throws->MemoryStore {
        try op.applyMembership();try op.close();let fresh=try store(f.store.root)
        XCTAssertEqual(try read(f.store.root,"PRAGMA user_version"),"36")
        XCTAssertEqual(try read(f.store.root,"SELECT COUNT(*) FROM personal_sync_peers"),String(f.proof.head.body.members.count))
        let envelope=try object(XCTUnwrap(storage.values[f.deliveryID])),raw=try XCTUnwrap(envelope["material"] as? String)
        let saved=try object(XCTUnwrap(storage.values[f.pairingID]));XCTAssertTrue((saved["material"] as? String)==raw)
        XCTAssertNil(envelope["membershipPreparation"]);XCTAssertEqual(envelope["membershipHead"] as? String,SyncProtocolLimits.hex(try f.proof.head.encoded()))
        let old=try object(XCTUnwrap(Data(base64Encoded:f.oldMaterial))),new=try object(XCTUnwrap(Data(base64Encoded:raw)))
        for key in ["signingPrivate","agreementPrivate","groupSecret","ownerPrivate"] {XCTAssertTrue((old[key] as? String)==(new[key] as? String),"Handover changed original private keys")}
        return fresh
    }
    func testMembershipHandoverPreservesKeysPendingCaptureAndExistingAccountIDs()throws {
        let f=try fixture(),provider=try files(f.shared),count=storage.values.count,op=try prepare(f),fresh=try activated(f,op)
        XCTAssertNotNil(try fresh.get("canary"));XCTAssertEqual(storage.values.count,count);XCTAssertEqual(try files(f.shared),provider)
        let peer=try pair(fresh);XCTAssertEqual(try peer.status().memberNames.count,3)
        let service=try peer.prepareAnchoredService(shared:f.shared,createShared:false);services.append(service)
        XCTAssertEqual(service.peers.count,2)
        _=try SyncOutgoingTests().serviceReady(service,limit:1)
        XCTAssertEqual(try service.cache.journal.outbox().count,1)
    }
    func testHandoverRecoversBeforeAndAfterEveryPrivateAccountSaveBoundary()throws {
        for boundary in 1...4 {for after in [false,true] {
            let f=try fixture(),op=try prepare(f),provider=try files(f.shared),count=storage.values.count
            storage.failAt=storage.attempts+boundary;storage.failAfter=after
            XCTAssertThrowsError(try op.applyMembership(),"Owned application boundary \(boundary), after=\(after)");try op.close()
            let envelope=try object(XCTUnwrap(storage.values[f.deliveryID]))
            if envelope["membershipPreparation"]==nil {
                let fresh=try store(f.store.root);XCTAssertNotNil(try fresh.get("canary"));XCTAssertEqual(try pair(fresh).status().memberNames.count,3);XCTAssertThrowsError(try recover(f))
            }else {
                let resumed=try recover(f)
                if let record=envelope["membershipPreparation"] as? [String:Any],record["disposition"] as? String=="applying" {XCTAssertThrowsError(try resumed.cancelBeforeHandover())}
                _=try activated(f,resumed)
            }
            XCTAssertEqual(storage.values.count,count);XCTAssertEqual(try files(f.shared),provider)
        }}
    }
    func testRejectedHandoverCommitReplaysSavedNewMaterialWithoutRepeatingPairingCAS()throws {
        let f=try fixture(),op=try prepare(f),handle=try f.store.withMembershipDatabase {$0.handle},gate=MembershipCommitGate(),target=storage.attempts+3
        storage.didReplace={ordinal in if ordinal==target {sqlite3_commit_hook(handle,MembershipCommitGate.callback,Unmanaged.passUnretained(gate).toOpaque())}}
        XCTAssertThrowsError(try op.applyMembership());storage.didReplace=nil;sqlite3_commit_hook(handle,nil,nil);try op.close();XCTAssertEqual(gate.rejections,1)
        let paired=storage.values[f.pairingID],envelope=try object(XCTUnwrap(storage.values[f.deliveryID])),token=try XCTUnwrap(envelope["token"] as? [String:Any]),floor=try XCTUnwrap(token["serial"] as? Int64)
        XCTAssertEqual(try read(f.store.root,"SELECT value FROM store_metadata WHERE key='sync-native-membership-phase-v1'"),"prepared")
        let resumed=try recover(f);_=try activated(f,resumed)
        XCTAssertTrue(storage.values[f.pairingID]==paired,"Recovery rewrote an already committed pairing candidate")
        XCTAssertEqual(Int64(try read(f.store.root,"SELECT serial FROM personal_sync_delivery_anchor")),floor)
    }
    func testAppliedNativeMembershipRefusesARolledBackPairingAccount()throws {
        let f=try fixture(),op=try prepare(f),fresh=try activated(f,op),updated=try XCTUnwrap(storage.values[f.pairingID]);try fresh.close();let count=storage.values.count
        storage.overwrite(f.pairingID,bytes:f.oldPairing);XCTAssertThrowsError(try store(f.store.root));XCTAssertEqual(storage.values.count,count)
        storage.overwrite(f.pairingID,bytes:updated);let original=try store(f.store.root);XCTAssertEqual(try pair(original).status().memberNames.count,3)
    }
    func testHandoverAfterSavedCancellationIsAnExplicitDifferentOperation()throws {
        let f=try fixture(),op=try prepare(f),handle=try f.store.withMembershipDatabase {$0.handle},gate=MembershipCommitGate(),target=storage.attempts+2
        storage.didReplace={ordinal in if ordinal==target {sqlite3_commit_hook(handle,MembershipCommitGate.callback,Unmanaged.passUnretained(gate).toOpaque())}}
        XCTAssertThrowsError(try op.cancelBeforeHandover());storage.didReplace=nil;sqlite3_commit_hook(handle,nil,nil);try op.close()
        let resumed=try recover(f);XCTAssertThrowsError(try resumed.applyMembership());let fresh=try finish(f,resumed);try fresh.close()
        let newStore=try store(f.store.root),new=try SyncMembershipPreparationOwner.prepare(library:newStore,proof:f.proof,environment:environment);operations.append(new);_=try activated(f,new)
    }
    func testLaterPeerReceivesCompleteThirteenKindGraphAfterMembershipHandover()throws {
        let f=try fixture(),graph=SyncOutgoingTests();graph.store=f.store;graph.root=f.store.root;try graph.seedGraph()
        let expected=try Dictionary(uniqueKeysWithValues:SyncCanonicalTable.allCases.map {($0.rawValue,try graph.serviceCount(f.store,$0.rawValue))})
        XCTAssertTrue(expected.values.allSatisfy {$0>0})
        let op=try prepare(f),fresh=try activated(f,op),peer=try pair(fresh),sender=try peer.prepareAnchoredService(shared:f.shared,createShared:false);services.append(sender)
        let third=f.third,receiver=try f.thirdPairing.prepareAnchoredService(shared:f.shared,createShared:false);services.append(receiver)
        for _ in 0..<40 {_=try graph.serviceReady(sender,limit:2);_=try graph.serviceReady(receiver,limit:2)}
        for table in SyncCanonicalTable.allCases {XCTAssertEqual(try graph.serviceCount(third,table.rawValue),expected[table.rawValue],table.rawValue)}
        XCTAssertTrue(try receiver.cache.journal.outbox().isEmpty);XCTAssertEqual(try graph.serviceCount(third,"personal_sync_publication_bindings"),1)
    }
    func testLaterPeerReplayRepublishesPrunedHistoryWithoutRollingBackAdvertisedHead()throws {
        let f=try fixture(),graph=SyncOutgoingTests(),first=try pair(f.store),initial=try first.prepareAnchoredService(shared:f.shared,createShared:false);services.append(initial)
        for index in 0..<10 {try f.store.insert(Memory(id:"replay-\(index)",kind:.note,app:"Owned",text:"Owned replay source \(index)"))}
        for _ in 0..<8 {_=try graph.serviceReady(initial,limit:2)}
        let producer=initial.cache.journal.replica,old=try XCTUnwrap(initial.transport.serviceHead(replica:producer)?.through)
        XCTAssertGreaterThan(old,2)
        try f.store.insert(Memory(id:"canary",kind:.note,text:"Owned current replacement after old cached body was pruned"))
        try initial.stop();initial.inbox.close();initial.transport.close();first.close()
        try FileManager.default.removeItem(at:f.shared.appendingPathComponent("objects"))
        let heads=try files(f.shared.appendingPathComponent("heads")),op=try prepare(f),fresh=try activated(f,op)
        XCTAssertEqual(try files(f.shared.appendingPathComponent("heads")),heads)
        let peer=try pair(fresh),sender=try peer.prepareAnchoredService(shared:f.shared,createShared:false);services.append(sender)
        let third=f.third,receiver=try f.thirdPairing.prepareAnchoredService(shared:f.shared,createShared:false);services.append(receiver)
        for _ in 0..<24 {
            _=try graph.serviceReady(sender,limit:2)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(sender.transport.serviceHead(replica:producer)?.through),old)
            XCTAssertGreaterThanOrEqual(Int64(try read(fresh.root,"SELECT sent FROM personal_sync_service_state")) ?? 0,old)
            _=try graph.serviceReady(receiver,limit:2)
        }
        let identity=try fresh.withRoutineDatabase {_ in try XCTUnwrap(sender.cache.catalog.preparedIdentity(.source,primary:[.text(Data("canary".utf8))]))}
        let local=try third.withRoutineDatabase {_ ->String in
            let mapping=try XCTUnwrap(receiver.cache.catalog.object(identity)),primary=try XCTUnwrap(mapping.primary)
            guard primary.count==1,case .text(let key)=primary[0],let value=String(data:key,encoding:.utf8) else {throw OSwindError.invalid("Owned incoming source mapping differs")};return value
        }
        XCTAssertEqual(try third.get(local)?.text,"Owned current replacement after old cached body was pruned")
        XCTAssertEqual(try receiver.cache.journal.state(for:identity.key).preferred?.content,try sender.cache.journal.state(for:identity.key).preferred?.content)
        XCTAssertEqual(try receiver.cache.journal.cursor(for:producer),try sender.transport.serviceHead(replica:producer)?.through)
        XCTAssertEqual(try third.stats(includeDiskUsage:false).count,11)
        XCTAssertEqual(try read(fresh.root,"SELECT COUNT(*) FROM store_metadata WHERE key='sync-membership-replay-v1'"),"0")
        XCTAssertTrue(try receiver.cache.journal.outbox().isEmpty)
    }
    func testMembershipReplayKeepsCurrentPrivacyHoldAndResumesOnlyWhenAllowed()throws {
        let f=try fixture(),graph=SyncOutgoingTests(),first=try pair(f.store),initial=try first.prepareAnchoredService(shared:f.shared,createShared:false);services.append(initial)
        try f.store.insert(Memory(id:"canary",kind:.note,app:"Owned",bundleID:"owned.blocked",text:"Owned source withheld during replay"))
        _=try graph.serviceReady(initial,limit:2);try initial.stop();initial.inbox.close();initial.transport.close();first.close()
        try FileManager.default.removeItem(at:f.shared.appendingPathComponent("objects"))
        let op=try prepare(f),fresh=try activated(f,op),peer=try pair(fresh),sender=try peer.prepareAnchoredService(shared:f.shared,createShared:false);services.append(sender)
        var settings=AppSettings.load(root:fresh.root);settings.privacy.excludedApps.append("owned.blocked");try settings.save(root:fresh.root)
        let provider=try files(f.shared)
        XCTAssertThrowsError(try graph.serviceReady(sender,limit:2));XCTAssertEqual(try files(f.shared),provider)
        let savedSent=try XCTUnwrap(Int64(try read(fresh.root,"SELECT sent FROM personal_sync_service_state")))
        let cursor=try SyncMembershipReplay.current(sender.cache.database,sent:savedSent)
        XCTAssertEqual(cursor?.after,0)
        settings.privacy.excludedApps.removeAll {$0=="owned.blocked"};try settings.save(root:fresh.root)
        _=try graph.serviceReady(sender,limit:2)
        XCTAssertEqual(try read(fresh.root,"SELECT COUNT(*) FROM store_metadata WHERE key='sync-membership-replay-v1'"),"0")
    }
    func testTaskCancellationAtPrivateBoundariesJoinsUncancelledCloseAndResumesExactChoice()async throws {
        for boundary in 2...5 {
            let f=try fixture(),gate=MembershipCancellationGate(),target=storage.attempts+boundary,count=storage.values.count,backend=storage,env=environment
            storage.didReplace={ordinal in if ordinal==target {gate.block()}}
            let worker=Task.detached { [library=f.store,proof=f.proof,env] in
                let owner=try SyncMembershipPreparationOwner.prepare(library:library,proof:proof,environment:env)
                let outcome:Result<Void,Error>
                do {try owner.applyMembership();outcome = .success(())}catch {outcome = .failure(error)}
                // Closing a cancelled worker must still wait for its media/SQL
                // reservation and release the original credential ownership.
                try await Task.detached(priority:.utility) {try owner.close()}.value
                return try outcome.get()
            }
            await fulfillment(of:[gate.reached],timeout:10)
            worker.cancel();gate.release()
            let outcome=await worker.result;backend.didReplace=nil
            if case .failure(let error)=outcome {XCTAssertTrue(error is CancellationError,"Cancellation failed with another error")}
            XCTAssertTrue(f.store.isClosed,"The cancelled worker did not join its native close")
            let saved=try object(XCTUnwrap(storage.values[f.deliveryID]))
            if saved["membershipPreparation"]==nil {
                let fresh=try store(f.store.root);XCTAssertEqual(try pair(fresh).status().memberNames.count,3)
            }else {let resumed=try recover(f);_=try activated(f,resumed)}
            XCTAssertEqual(storage.values.count,count)
        }
    }
    func testNative36RetirementAndPortableRecoveryKeepOriginalSafetyBoundaries()throws {
        let f=try fixture(),op=try prepare(f),fresh=try finish(f,op);try fresh.close()
        let backup=root.appendingPathComponent("portable.oswindbackup"),restored=root.appendingPathComponent("restored")
        _=try LibraryRecovery.createBackup(from:f.store.root,destination:backup);_=try LibraryBackup.restore(backup,to:restored)
        let quiet=try store(restored);XCTAssertEqual(try pair(quiet).status().phase,.unconfigured);XCTAssertEqual(try read(restored,"SELECT COUNT(*) FROM store_metadata WHERE key LIKE 'sync-native-membership-%'"),"0")
        let active=try store(f.store.root),peer=try pair(active),service=try peer.prepareAnchoredService(shared:f.shared,createShared:false);services.append(service)
        _=try service.stageLocalRetirement();try service.stop();service.inbox.close();service.transport.close();peer.close();try active.close()
        let recovery=try SyncRetirementCleanupOwner.open(root:active.root,environment:environment);defer {try? recovery.close()}
        XCTAssertTrue(try recovery.cleanup().cleanupComplete);_=try recovery.completeLocalRetirement();try recovery.close()
        let renewed=try store(active.root);try renewed.insert(Memory(id:"renewed",text:"Native36 whole erase renewal"));XCTAssertNotNil(try renewed.get("renewed"));XCTAssertEqual(try read(active.root,"PRAGMA user_version"),"36")
    }

    func testCancellationAfterEarlierHandoverPreservesFormatFloor()throws {
        let f=try fixture(),first=try prepare(f),fresh=try activated(f,first)
        XCTAssertEqual(try fresh.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2)
        let owner=try XCTUnwrap(pairings.first),fourthStore=try store(root.appendingPathComponent("floor-fourth")),fourth=try pair(fourthStore)
        try join(fourth,to:owner,name:"Owned floor fourth")
        let proof=try XCTUnwrap(owner.membershipRefresh(after:f.proof.head)),count=storage.values.count,op=try SyncMembershipPreparationOwner.prepare(library:fresh,proof:proof,environment:environment);operations.append(op)
        let envelope=try object(XCTUnwrap(storage.values[f.deliveryID])),pending=try XCTUnwrap(envelope["membershipPreparation"] as? [String:Any])
        XCTAssertEqual(pending["stateVersionBefore"] as? Int,2)
        try op.cancelBeforeHandover();try op.close();let reopened=try store(fresh.root)
        XCTAssertEqual(try reopened.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2)
        XCTAssertEqual(try pair(reopened).status().memberNames.count,3);XCTAssertEqual(storage.values.count,count);XCTAssertNotNil(try reopened.get("canary"))
        XCTAssertThrowsError(try reopened.withRoutineDatabase {db in try reopened.nativeWriterAdmission.withMembershipMutation(db) {try SyncChangeCapture.transaction(db) {try SyncNativeMembershipState.write(.active(SyncProtocolLimits.hex(try f.proof.head.encoded()),version:1),db)}}})
        XCTAssertEqual(try reopened.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2)
    }
    func testLegacyPreparingAndCancellingRecordsWithoutFloorFieldRemainRecoverable()throws {
        for cancelling in [false,true] {
            let f=try fixture(),op=try prepare(f)
            if cancelling {storage.failAt=storage.attempts+2;storage.failAfter=false;XCTAssertThrowsError(try op.cancelBeforeHandover())}
            let envelope=try object(XCTUnwrap(storage.values[f.deliveryID])),pending=try XCTUnwrap(envelope["membershipPreparation"] as? [String:Any])
            XCTAssertNil(pending["stateVersionBefore"]);XCTAssertNil(pending["additions"])
            for invalid in [0,2,3] {
                var changed=pending;changed["stateVersionBefore"]=invalid
                let decoded=try SyncPairingFormat.decode(SyncMembershipPreparation.self,JSONSerialization.data(withJSONObject:changed,options:[.sortedKeys,.withoutEscapingSlashes]),limit:4096)
                XCTAssertThrowsError(try decoded.validate(),"A native35 predecessor cannot claim a saved native36 format")
            }
            XCTAssertEqual(pending["disposition"] as? String,cancelling ? "cancelling":"preparing")
            try op.close();let resumed=try recover(f),fresh=try finish(f,resumed)
            XCTAssertEqual(try fresh.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},1)
        }
    }
    func testCommittedLegacyApplyRecoversRejectedFormatUpgradeWithoutNewTokenOrAccounts()throws {
        let f=try fixture(),op=try prepare(f),handle=try f.store.withMembershipDatabase {$0.handle},gate=MembershipFloorCommitGate(),target=storage.attempts+3,count=storage.values.count
        // Project the exact old652 committed active1 representation after the
        // new private delivery save, then reject the separate floor COMMIT.
        storage.didReplace={ordinal in if ordinal==target {
            do {try f.store.withMembershipDatabase {db in
                let row=try db.statement("UPDATE store_metadata SET value=? WHERE key=?");defer {sqlite3_finalize(row)}
                db.bind(row,1,String(decoding:try SyncProtocolLimits.encode(SyncNativeMembershipState.Value.active(SyncProtocolLimits.hex(try f.proof.head.encoded()),version:1)),as:UTF8.self));db.bind(row,2,SyncNativeMembershipState.stateKey);try db.done(row)
                sqlite3_commit_hook(db.handle,MembershipFloorCommitGate.callback,Unmanaged.passUnretained(gate).toOpaque())
            }}catch {XCTFail("Owned legacy committed-state projection failed")}
        }}
        XCTAssertThrowsError(try op.applyMembership());storage.didReplace=nil;sqlite3_commit_hook(handle,nil,nil)
        XCTAssertEqual(gate.rejections,1);XCTAssertEqual(gate.commits,2)
        let before=try object(XCTUnwrap(storage.values[f.deliveryID])),pending=try XCTUnwrap(before["membershipPreparation"] as? [String:Any]);XCTAssertNil(pending["stateVersionBefore"])
        let token=try SyncPairingFormat.decode(SyncDeliveryAnchor.Token.self,JSONSerialization.data(withJSONObject:XCTUnwrap(before["token"]),options:[.sortedKeys]),limit:1024)
        try op.close();let resumed=try recover(f),attempts=storage.attempts,fresh=try activated(f,resumed)
        XCTAssertEqual(storage.attempts,attempts+1,"Only the pending clear may save externally after the legacy floor COMMIT")
        let after=try object(XCTUnwrap(storage.values[f.deliveryID])),saved=try SyncPairingFormat.decode(SyncDeliveryAnchor.Token.self,JSONSerialization.data(withJSONObject:XCTUnwrap(after["token"]),options:[.sortedKeys]),limit:1024)
        XCTAssertEqual(saved,token);XCTAssertEqual(storage.values.count,count);XCTAssertEqual(try fresh.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},2)
        XCTAssertEqual(try read(fresh.root,"SELECT COUNT(*) FROM personal_sync_peers"),"3")
    }
    func testCurrentRuntimeCanFinishAlreadyClearedLegacyReplayWithoutDiscardingIt()throws {
        let f=try fixture(),graph=SyncOutgoingTests(),initialPair=try pair(f.store),initial=try initialPair.prepareAnchoredService(shared:f.shared,createShared:false);services.append(initial)
        _=try graph.serviceReady(initial,limit:2);try initial.stop();initial.inbox.close();initial.transport.close();initialPair.close()
        let op=try prepare(f),fresh=try activated(f,op)
        // An authored earlier652 cleared active1 snapshot, not a permitted
        // current API downgrade. Such snapshots predate the new floor.
        try fresh.withRoutineDatabase {db in try fresh.nativeWriterAdmission.withMembershipMutation(db) {try SyncChangeCapture.transaction(db) {
            let row=try db.statement("UPDATE store_metadata SET value=? WHERE key=?");defer {sqlite3_finalize(row)}
            db.bind(row,1,String(decoding:try SyncProtocolLimits.encode(SyncNativeMembershipState.Value.active(SyncProtocolLimits.hex(try f.proof.head.encoded()),version:1)),as:UTF8.self));db.bind(row,2,SyncNativeMembershipState.stateKey);try db.done(row)
        }}}
        try fresh.close();let legacy=try store(fresh.root),peer=try pair(legacy),sender=try peer.prepareAnchoredService(shared:f.shared,createShared:false);services.append(sender)
        let sent=try XCTUnwrap(Int64(try read(legacy.root,"SELECT sent FROM personal_sync_service_state")))
        XCTAssertGreaterThan(try XCTUnwrap(SyncMembershipReplay.current(sender.cache.database,sent:sent)).through,0)
        _=try graph.serviceReady(sender,limit:2)
        XCTAssertEqual(try read(legacy.root,"SELECT COUNT(*) FROM store_metadata WHERE key='sync-membership-replay-v1'"),"0");XCTAssertNotNil(try legacy.get("canary"))
        XCTAssertEqual(try legacy.withRoutineDatabase {try SyncNativeMembershipState.read($0).version},1,"Backfilling a cleared legacy cached-writer fence is a separate owned transition")
    }

}

private final class MembershipPreparationStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection
    init(protection:SyncCredentialProtection = .loginKeychain) {self.protection=protection}
    private let lock=NSLock();private var saved=[String:Data](),count=0,tiers=[SyncCredentialProtection]()
    func requested(_ value:SyncCredentialProtection) {lock.lock();tiers.append(value);lock.unlock()}
    var requests:[SyncCredentialProtection] {lock.lock();defer {lock.unlock()};return tiers}
    var failAt:Int?,failAfter=false,didReplace:((Int)->Void)?
    var values:[String:Data] {lock.lock();defer {lock.unlock()};return saved}
    var attempts:Int {lock.lock();defer {lock.unlock()};return count}
    func create(id:String,bytes:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==nil else {throw SyncCredentialStorageError.alreadyExists};saved[id]=bytes}
    func read(id:String)throws->Data {lock.lock();defer {lock.unlock()};guard let bytes=saved[id] else {throw SyncCredentialStorageError.missing};return bytes}
    func replace(id:String,expected:Data,bytes:Data)throws {
        lock.lock();count+=1;let ordinal=count,fail=ordinal==failAt,after=failAfter
        if fail && !after {lock.unlock();throw SyncCredentialStorageError.unavailable(-1)}
        guard saved[id]==expected else {lock.unlock();throw SyncCredentialStorageError.changed};saved[id]=bytes;lock.unlock();didReplace?(ordinal)
        if fail && after {throw SyncCredentialStorageError.unavailable(-1)}
    }
    func remove(id:String,expected:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved.removeValue(forKey:id)}
    func overwrite(_ id:String,bytes:Data) {lock.lock();saved[id]=bytes;lock.unlock()}
}
private final class MembershipCommitGate {
    private(set) var rejections=0
    static let callback:@convention(c) (UnsafeMutableRawPointer?)->Int32 = {pointer in
        let gate=Unmanaged<MembershipCommitGate>.fromOpaque(pointer!).takeUnretainedValue()
        if gate.rejections==0 {gate.rejections+=1;return 1};return 0
    }
}

private final class MembershipCancellationGate:@unchecked Sendable {
    let reached=XCTestExpectation(description:"Owned private membership save reached")
    private let permit=DispatchSemaphore(value:0)
    func block() {reached.fulfill();permit.wait()}
    func release() {permit.signal()}
}

private final class MembershipFloorCommitGate {
    private(set) var commits=0,rejections=0
    static let callback:@convention(c) (UnsafeMutableRawPointer?)->Int32 = {pointer in
        let gate=Unmanaged<MembershipFloorCommitGate>.fromOpaque(pointer!).takeUnretainedValue();gate.commits+=1
        if gate.commits==2 {gate.rejections+=1;return 1};return 0
    }
}
