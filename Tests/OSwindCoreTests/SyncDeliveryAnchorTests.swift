import XCTest
import CSQLite
@testable import OSwindCore

final class SyncDeliveryAnchorTests:XCTestCase {
    private var root:URL!,a:MemoryStore!,b:MemoryStore!,storage:DeliveryTestStorage!
    var pairings=[PersonalSyncPairing](),services=[SyncLibraryService]()
    let machine=SyncCredentialBindingTests.Machine(value:String(repeating:"a",count:64))
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-delivery-anchor-"+UUID().uuidString)
        a=try MemoryStore(root:root.appendingPathComponent("a"));b=try MemoryStore(root:root.appendingPathComponent("b"));storage=DeliveryTestStorage()
    }
    override func tearDownWithError()throws {
        for service in services {try? service.stop();service.inbox.close();service.transport.close()}
        pairings.forEach {$0.close()};try a?.close();try b?.close();try FileManager.default.removeItem(at:root)
    }
    func reopen(_ url:URL)throws->MemoryStore {let backend=storage!;return try MemoryStore(root:url,recoveryReadOnly:false,nativeWriterEnvironment:.init(stateRoot:root.appendingPathComponent("state"),machine:machine,storage:{_ in backend}))}
    func pairing(_ library:MemoryStore)throws->PersonalSyncPairing {
        let value=try PersonalSyncPairing(store:library,stateRoot:root.appendingPathComponent("state"),machine:machine,storage:storage);pairings.append(value);return value
    }
    func owner()throws->PersonalSyncPairing {let value=try pairing(a);_=try value.createGroup(deviceName:"Owned desk Mac");return value}
    func prepare(_ pairing:PersonalSyncPairing,create:Bool=true)throws->SyncLibraryService {
        let service=try pairing.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:create);services.append(service);return service
    }
    func ready(_ service:SyncLibraryService,limit:Int=64)throws->SyncLibraryServiceStep {
        for _ in 0..<100 {
            let step=try service.tick(limit:limit)
            if case .preparing=step {continue};if case .reviewingPolicy=step {continue};return step
        };throw OSwindError.unavailable("Owned anchored service did not finish local preparation")
    }
    func stop(_ service:SyncLibraryService)throws {try service.stop();service.inbox.close();service.transport.close()}
    func copyDB(_ store:MemoryStore,to path:URL)throws {
        try store.close();try FileManager.default.copyItem(at:store.root.appendingPathComponent("memory.sqlite"),to:path)
    }
    func restoreDB(_ store:MemoryStore,from path:URL)throws->MemoryStore {
        let url=store.root;try store.close();try FileManager.default.removeItem(at:url.appendingPathComponent("memory.sqlite"));try FileManager.default.copyItem(at:path,to:url.appendingPathComponent("memory.sqlite"));return try reopen(url)
    }
    func testInternalPairingFactoryPublishesThroughDurableAnchorAndReopensOriginalKeys()throws {
        let owner=try owner(),service=try prepare(owner)
        try a.insert(Memory(id:"source",kind:.note,text:"Owned anchored source"))
        _=try ready(service)
        XCTAssertEqual(try service.cache.journal.outbox().count,1)
        let accounts=storage.values,source=try a.get("source");XCTAssertNotNil(source)
        try stop(service);owner.close();try a.close();a=try reopen(root.appendingPathComponent("a"))
        let reopened=try pairing(a),resumed=try prepare(reopened,create:false)
        _=try ready(resumed);XCTAssertEqual(storage.values.count,accounts.count)
        XCTAssertEqual(try resumed.cache.journal.outbox().count,1)
        XCTAssertEqual(try resumed.transport.serviceHead(replica:resumed.cache.journal.replica)?.through,1)
    }
    func testAdvertisedHeadAheadOfAppliedCursorAllowsPartialDeliveryAndResume()throws {
        let owner=try owner(),joiner=try pairing(b),request=try XCTUnwrap(joiner.requestJoin(deviceName:"Owned travel Mac").request)
        let response=try owner.approve(owner.reviewRequest(request));_=try joiner.acceptResponse(response,trustedRootFingerprint:owner.status().rootFingerprint!)
        let sender=try prepare(owner),receiver=try prepare(joiner,create:false)
        for i in 0..<6 {try a.insert(Memory(id:"source-\(i)",kind:.note,text:"Owned transfer \(i)"))}
        _=try ready(sender)
        _=try ready(receiver,limit:1)
        XCTAssertEqual(try receiver.cache.journal.cursor(for:sender.cache.journal.replica),1)
        XCTAssertEqual(try receiver.transport.serviceHead(replica:sender.cache.journal.replica)?.through,6)
        try stop(receiver);joiner.close();try b.close();b=try reopen(root.appendingPathComponent("b"))
        let reopened=try pairing(b),resumed=try prepare(reopened,create:false)
        for _ in 0..<8 {_=try ready(resumed,limit:1)}
        XCTAssertEqual(try resumed.cache.journal.cursor(for:sender.cache.journal.replica),6)
        XCTAssertEqual(try b.stats(includeDiskUsage:false).count,6)
        XCTAssertTrue(try resumed.cache.journal.outbox().isEmpty)
    }
    func testReadOnlyIdleTicksDoNotRewriteKeychain()throws {
        let service=try prepare(owner());_=try ready(service)
        let before=storage.replacements,files=try transportFiles(service.transport.root)
        for _ in 0..<5 {_=try ready(service)}
        XCTAssertEqual(storage.replacements,before,"Quiet polling must not persist new credentials")
        XCTAssertEqual(try transportFiles(service.transport.root),files,"Quiet polling must not rewrite provider objects")
    }
    func testRestoredWriterDatabaseRefusesBeforeAnyNewProviderWrites()throws {
        var owner=try owner();var service=try prepare(owner)
        try stop(service);owner.close()
        let prior=root.appendingPathComponent("before.sqlite");try copyDB(a,to:prior)
        a=try reopen(root.appendingPathComponent("a"));owner=try pairing(a);service=try prepare(owner,create:false)
        try a.insert(Memory(id:"source",kind:.note,text:"Already assigned writer history"));_=try ready(service)
        let before=try transportFiles(service.transport.root)
        try stop(service);owner.close();XCTAssertThrowsError(try restoreDB(a,from:prior),"Constructor must refuse rollback before migrations")
        XCTAssertEqual(try transportFiles(root.appendingPathComponent("shared")),before)
    }
    func testRestoringDatabaseBeforeDeliveryReservationCannotCreateAFreshZeroFloor()throws {
        let owner=try owner(),snapshot=root.appendingPathComponent("before-delivery.sqlite")
        try snapshotDB(a,to:snapshot)
        let service=try prepare(owner)
        try a.insert(Memory(id:"source",kind:.note,text:"Already published before native restore"));_=try ready(service)
        let files=try transportFiles(service.transport.root),accounts=storage.values
        try stop(service);owner.close();XCTAssertThrowsError(try restoreDB(a,from:snapshot),"Constructor must detect the surviving external reservation before migrations")
        XCTAssertEqual(storage.values,accounts,"The externally reserved account must survive a pre-install database restore")
        XCTAssertEqual(try transportFiles(root.appendingPathComponent("shared")),files)
    }
    func testPendingDeliveryAccountIsNeverRegeneratedAfterCredentialLoss()throws {
        let owner=try owner(),service=try prepare(owner);try stop(service);owner.close()
        let keys=storage.values.keys
        let delivery=try XCTUnwrap(keys.first {id in guard let value=storage.values[id],let object=try? JSONSerialization.jsonObject(with:value) as? [String:Any] else {return false};return object["format"] as? String=="OSwind.sync.delivery-anchor"})
        storage.forget(delivery);let count=storage.values.count
        XCTAssertThrowsError(try prepare(pairing(a),create:false));XCTAssertEqual(storage.values.count,count)
    }
    func testFailedInitialDeliveryCredentialCreateKeepsReservedIdentityForRecovery()throws {
        let owner=try owner();storage.failCreate=true
        XCTAssertThrowsError(try prepare(owner));XCTAssertEqual(storage.values.count,1)
        let saved=storage.values;storage.failCreate=false
        XCTAssertThrowsError(try prepare(owner,create:false))
        XCTAssertEqual(storage.values,saved,"A missing reserved credential is not a fresh zero-floor enrollment")
    }
    func testChangedCheckpointSchemaIsRejectedAfterCachedValidation()throws {
        let service=try prepare(owner());_=try ready(service)
        let files=try transportFiles(service.transport.root)
        try a.withRoutineDatabase {try $0.execute("DROP TRIGGER sync_delivery_checkpoint_personal_sync_receipts_insert")}
        XCTAssertThrowsError(try service.tick())
        XCTAssertEqual(try transportFiles(service.transport.root),files)
    }
    func testUnownedWireMutationInvalidatesCheckpointInsteadOfBeingAdopted()throws {
        let owner=try owner(),service=try prepare(owner)
        try a.withRoutineDatabase {db in try db.execute("UPDATE personal_sync_local SET sequence=sequence+1 WHERE singleton=1")}
        let files=try transportFiles(service.transport.root)
        XCTAssertThrowsError(try service.tick());XCTAssertEqual(try transportFiles(service.transport.root),files)
    }
    func testSameSequenceDifferentAssignedBodyIsRejectedByExternalCheckpoint()throws {
        let service=try prepare(owner())
        try a.insert(Memory(id:"source",kind:.note,text:"Owned original immutable content"));_=try ready(service)
        let original=try XCTUnwrap(service.cache.journal.outbox().first),files=try transportFiles(service.transport.root)
        let fork=try SyncRevision(key:original.key,dot:original.dot,context:original.context,mutation:.put,content:.init(data:Data("Owned different content at the same counter".utf8)),publication:original.publication,creationEra:original.creationEra)
        try a.withRoutineDatabase {db in
            let row=try db.statement("UPDATE personal_sync_outbox SET revision=? WHERE sequence=?");defer {sqlite3_finalize(row)}
            let bytes=try fork.encoded();bytes.withUnsafeBytes {_=sqlite3_bind_blob(row,1,$0.baseAddress,Int32(bytes.count),db.transient)}
            sqlite3_bind_int64(row,2,fork.dot.counter);try db.done(row)
        }
        XCTAssertThrowsError(try service.tick()) {error in XCTAssertTrue(error.localizedDescription.contains("checkpoint"))}
        XCTAssertEqual(try transportFiles(service.transport.root),files)
    }
    func testCredentialSaveFailureRollsBackNativePreparationAndRequiresReopen()throws {
        let owner=try owner(),service=try prepare(owner)
        try a.insert(Memory(id:"source",kind:.note,text:"Must not publish without checkpoint"))
        let files=try transportFiles(service.transport.root);storage.failReplacement=true
        XCTAssertThrowsError(try service.tick())
        XCTAssertEqual(try transportFiles(service.transport.root),files)
        XCTAssertTrue(try service.cache.journal.outbox().isEmpty)
        storage.failReplacement=false
        XCTAssertThrowsError(try service.tick(),"Ambiguous external write failure must not resume the same owner")
        try stop(service);owner.close()
        let resumed=try prepare(pairing(a),create:false);_=try ready(resumed)
        XCTAssertEqual(try resumed.cache.journal.outbox().count,1)
    }
    func testExternalAdvanceBeforeFailedSQLiteCommitRequiresRecoveryWithoutProviderWrites()throws {
        let owner=try owner(),service=try prepare(owner),gate=DeliveryCommitFault()
        try a.insert(Memory(id:"source",kind:.note,text:"Commit must be durable before publication"))
        let files=try transportFiles(service.transport.root)
        let handle=try a.withRoutineDatabase {$0.handle}
        storage.afterReplacement={
            _=sqlite3_set_authorizer(handle,{context,action,first,_,_,_ in
                guard action==SQLITE_TRANSACTION,let first,String(cString:first)=="COMMIT",let context else {return SQLITE_OK}
                return Unmanaged<DeliveryCommitFault>.fromOpaque(context).takeUnretainedValue().denyOnce() ? SQLITE_DENY:SQLITE_OK
            },Unmanaged.passUnretained(gate).toOpaque())
        }
        defer {try? a.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)}}
        XCTAssertThrowsError(try service.tick())
        storage.afterReplacement=nil
        try a.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)}
        XCTAssertTrue(gate.denied);XCTAssertEqual(try transportFiles(service.transport.root),files)
        XCTAssertThrowsError(try service.tick())
        try stop(service);owner.close()
        XCTAssertThrowsError(try prepare(pairing(a),create:false),"An advanced external floor cannot be reset to the rolled-back native database")
    }
    func testOutOfOrderDeletionIsCheckpointedBeforeNativeVisibilityAndCannotRollbackAtUnchangedCursor()throws {
        try a.insert(Memory(id:"victim",kind:.note,text:"Owned early deletion source"))
        let local=try SyncPendingJoin(name:"Owned receiver"),remote=try SyncPendingJoin(name:"Owned sender")
        let authority=try SyncGroupAuthority(owner:local.request).admitting(remote.request)
        let joined=try local.accept(authority.response(to:local.request),expectedRootFingerprint:authority.fingerprint)
        let material=try SyncCredentialMaterial(joined:joined,owner:authority),id=UUID().uuidString.lowercased()
        let shared=root.appendingPathComponent("shared"),inboxPath=a.root.appendingPathComponent("images/manual-anchor")
        var transport=try joined.createTransport(at:shared),inbox=try joined.createPrivateInbox(at:inboxPath)
        var service=try SyncLibraryService.install(library:a,replica:joined.replica,group:authority.certificate.body.group,epoch:authority.certificate.body.epoch,peers:[remote.request.body.replica],transport:transport,inbox:inbox)
        services.append(service)
        let state=root.appendingPathComponent("state");_=try SyncLocalCredentialState.installationID(at:state,create:true)
        let anchor=try SyncDeliveryAnchor.create(library:a,cache:service.cache,material:material,id:id,stateRoot:state,machine:machine,storage:storage)
        try service.attachExternalAnchor(anchor)
        let snapshot=root.appendingPathComponent("before-early-delete.sqlite");try snapshotDB(a,to:snapshot)
        var observedUncommittedBoundary=false
        storage.afterReplacement={
            // A separate WAL reader still sees the source while the external
            // checkpoint already contains this mutation's final token.
            do {observedUncommittedBoundary=try self.readOnlyCount(self.a.root,"SELECT COUNT(*) FROM memories WHERE id='victim'")==1}
            catch {XCTFail("Owned separate WAL reader failed")}
        }
        let key=try SyncObjectKey.make(kind:.source,identity:Data("Owned early source identity".utf8)),peer=remote.request.body.replica
        let deletion=try SyncRevision(key:key,dot:.init(replica:peer,counter:2),context:SyncClock([peer:1]),mutation:.delete,content:nil)
        try a.withRoutineDatabase {db in try anchor.mutate(in:db) {
            let receipt=try service.cache.journal.receive(deletion,contentAvailable:{_ in false},apply:{_ in try db.execute("DELETE FROM memories WHERE id='victim'")})
            XCTAssertEqual(receipt.applied,0);XCTAssertTrue(receipt.inserted)
        }}
        storage.afterReplacement=nil
        XCTAssertTrue(observedUncommittedBoundary);XCTAssertNil(try a.get("victim"))
        XCTAssertEqual(try service.cache.journal.cursor(for:peer),0)
        try anchor.validate();try stop(service)
        a=try restoreDB(a,from:snapshot)
        XCTAssertNotNil(try a.get("victim"))
        transport=try joined.openTransport(at:shared);inbox=try joined.openPrivateInbox(at:inboxPath)
        service=try SyncLibraryService.install(library:a,replica:joined.replica,group:authority.certificate.body.group,epoch:authority.certificate.body.epoch,peers:[peer],transport:transport,inbox:inbox);services.append(service)
        XCTAssertEqual(try service.cache.journal.cursor(for:peer),0)
        XCTAssertThrowsError(try SyncDeliveryAnchor.open(library:a,cache:service.cache,material:material,id:id,stateRoot:state,machine:machine,storage:storage),"An unchanged contiguous cursor cannot conceal rollback of early deletion effects")
    }
    func testOwnedNativeKeychainAnchoredDeliveryReopensWithoutReplacingIdentity()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned Keychain delivery fixture; no existing credential is enumerated")}
        let backend=OwnedDeliveryNativeStorage(),state=root.appendingPathComponent("native-state")
        defer {do {try backend.cleanup()}catch {XCTFail("Owned delivery Keychain cleanup failed")}}
        let owner=try PersonalSyncPairing(store:a,stateRoot:state,machine:MacSyncMachineFingerprint(),storage:backend);pairings.append(owner)
        _=try owner.createGroup(deviceName:"Owned persistent delivery")
        let service=try prepare(owner)
        try a.insert(Memory(id:"native",kind:.note,text:"Owned actual Keychain publication"));_=try ready(service)
        try stop(service);owner.close();try a.close();a=try MemoryStore(root:root.appendingPathComponent("a"),recoveryReadOnly:false,nativeWriterEnvironment:.init(stateRoot:state,machine:MacSyncMachineFingerprint(),storage:{_ in backend}))
        let reopened=try PersonalSyncPairing(store:a,stateRoot:state,machine:MacSyncMachineFingerprint(),storage:backend);pairings.append(reopened)
        let resumed=try prepare(reopened,create:false);_=try ready(resumed)
        XCTAssertEqual(try resumed.cache.journal.outbox().count,1);XCTAssertEqual(backend.accounts.count,2)
        try stop(resumed);reopened.close();try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
    }
    func snapshotDB(_ store:MemoryStore,to path:URL)throws {
        try store.withRoutineDatabase {source in
            var destination:OpaquePointer?
            guard sqlite3_open_v2(path.path,&destination,SQLITE_OPEN_CREATE|SQLITE_OPEN_READWRITE,nil)==SQLITE_OK,let destination else {throw OSwindError.database("Owned checkpoint snapshot unavailable")}
            defer {sqlite3_close(destination)}
            guard let backup=sqlite3_backup_init(destination,"main",source.handle,"main") else {throw OSwindError.database("Owned checkpoint snapshot could not start")}
            let step=sqlite3_backup_step(backup,-1),finished=sqlite3_backup_finish(backup)
            guard step==SQLITE_DONE,finished==SQLITE_OK else {throw OSwindError.database("Owned checkpoint snapshot failed")}
        }
    }
    func readOnlyCount(_ root:URL,_ sql:String)throws->Int64 {
        var handle:OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&handle,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,let handle else {throw OSwindError.database("Owned checkpoint reader unavailable")}
        defer {sqlite3_close(handle)}
        var row:OpaquePointer?;guard sqlite3_prepare_v2(handle,sql,-1,&row,nil)==SQLITE_OK,let row else {throw OSwindError.database("Owned checkpoint reader query failed")}
        defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.database("Owned checkpoint reader returned no row")};return sqlite3_column_int64(row,0)
    }
    func testPreparedPairingCannotBeRetiredOrMembershipChangedBehindDelivery()throws {
        let owner=try owner(),pending=try SyncPendingJoin(name:"Another Mac")
        let text=String(decoding:try pending.request.encoded(),as:UTF8.self),review=try owner.reviewRequest(text)
        _=try prepare(owner)
        XCTAssertThrowsError(try owner.retire())
        XCTAssertThrowsError(try owner.reviewRequest(text))
        XCTAssertThrowsError(try owner.approve(review))
    }
    func testPublicPreviewStillDoesNotActivateCaptureOrExposeDelivery()throws {
        let owner=try owner();XCTAssertEqual(try owner.status().phase,.owner)
        XCTAssertEqual(try a.withRoutineDatabase {try $0.eraseCount("SELECT enabled FROM personal_sync_capture")},0)
        XCTAssertEqual(MemoryStore.schemaVersion,33)
    }
    func transportFiles(_ root:URL)throws->[String:Data] {
        var result=[String:Data]()
        let files=try XCTUnwrap(FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]))
        for case let file as URL in files {
            let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {throw OSwindError.invalid("Owned transport fixture contains a symlink")}
            if values.isRegularFile==true {result[String(file.path.dropFirst(root.path.count+1))]=try Data(contentsOf:file)}
        };return result
    }

}

final class DeliveryTestStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let lock=NSLock();private var saved=[String:Data](),writes=0
    var failReplacement=false,failCreate=false
    var afterReplacement:(()->Void)?
    var values:[String:Data] {lock.lock();defer {lock.unlock()};return saved}
    var replacements:Int {lock.lock();defer {lock.unlock()};return writes}
    func forget(_ id:String) {lock.lock();saved.removeValue(forKey:id);lock.unlock()}
    func create(id:String,bytes:Data)throws {lock.lock();defer {lock.unlock()};if failCreate {throw SyncCredentialStorageError.unavailable(-1)};guard saved[id]==nil else {throw SyncCredentialStorageError.alreadyExists};saved[id]=bytes}
    func read(id:String)throws->Data {lock.lock();defer {lock.unlock()};guard let value=saved[id] else {throw SyncCredentialStorageError.missing};return value}
    func replace(id:String,expected:Data,bytes:Data)throws {lock.lock();defer {lock.unlock()};if failReplacement {throw SyncCredentialStorageError.unavailable(-1)};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved[id]=bytes;writes+=1;afterReplacement?()}
    func remove(id:String,expected:Data)throws {lock.lock();defer {lock.unlock()};guard saved[id]==expected else {throw SyncCredentialStorageError.changed};saved.removeValue(forKey:id)}
}

private final class DeliveryCommitFault:@unchecked Sendable {
    private let lock=NSLock();private var used=false
    var denied:Bool {lock.lock();defer {lock.unlock()};return used}
    func denyOnce()->Bool {lock.lock();defer {lock.unlock()};guard !used else {return false};used=true;return true}
}

private final class OwnedDeliveryNativeStorage:SyncCredentialStorage,@unchecked Sendable {
    let protection:SyncCredentialProtection = .loginKeychain
    private let backend=SyncKeychainCredentialStorage(protection:.loginKeychain)
    private(set) var accounts=[String]()
    func create(id:String,bytes:Data)throws {try backend.create(id:id,bytes:bytes);accounts.append(id)}
    func read(id:String)throws->Data {try backend.read(id:id)}
    func replace(id:String,expected:Data,bytes:Data)throws {try backend.replace(id:id,expected:expected,bytes:bytes)}
    func remove(id:String,expected:Data)throws {try backend.remove(id:id,expected:expected)}
    func cleanup()throws {
        for id in accounts {try backend.remove(id:id,expected:backend.read(id:id))
            do {_=try backend.read(id:id);throw OSwindError.invalid("Owned delivery credential survived cleanup")}
            catch SyncCredentialStorageError.missing {}}
        accounts.removeAll()
    }
}
