import Foundation
import CSQLite

/// Pairing is durable device admission, not delivery activation. Public values
/// contain only reviewed public messages. No private material reaches the app.
public struct PersonalSyncPairingStatus:Equatable,Sendable {
    public enum Phase:String,Sendable {case unconfigured,waitingForOwner,owner,paired,retired}
    public let phase:Phase
    public let deviceName:String
    public let memberNames:[String]
    public let rootFingerprint:String?
    public let requestFingerprint:String?
    public let request:String?
    public let expires:Date?
    /// A delivery reservation survives stopped sessions and forbids membership edits.
    public let deliveryPrepared:Bool
    public var lastResponseAvailable:Bool=false
}
public struct PersonalSyncPairingReview:Equatable,Sendable {
    public let deviceName:String
    public let requestFingerprint:String
    public let expires:Date
    public let alreadyAdmitted:Bool
    // Exact canonical signed request. Approval must return this reviewed value,
    // rather than reparsing a mutable UI text field after the user clicks.
    fileprivate let bytes:Data
    fileprivate let ownerState:String
}

public struct PersonalSyncApprovedResponse:Equatable,Sendable {
    public let response:String,deviceName:String,requestFingerprint:String
    public let approvedAt:Date,expires:Date
}

/// Serialized owner of a Keychain anchor and its current native library. The
/// caller must join every operation and close this owner before leaving storage.
/// A prepared session takes lifetime ownership of this pairing owner. The app
/// must join setup and session shutdown before leaving its native library.
public final class PersonalSyncPairing:@unchecked Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    private struct Handle:Codable,Equatable {let format:String,version:Int,id:String,protection:SyncCredentialProtection}
    private struct Location:Codable,Equatable {
        let installation:String,machine:String,origin:String,generation:String,volume:String,inode:UInt64,lifetime:String
        let vault:SyncVaultPhysicalBinding?
        func replacingLifetime(_ value:String)->Self {.init(installation:installation,machine:machine,origin:origin,generation:generation,volume:volume,inode:inode,lifetime:value,vault:vault)}
        static func capture(_ store:MemoryStore,stateRoot:URL,machine:any SyncMachineFingerprint)throws->Self {
            let installation=try SyncLocalCredentialState.installationID(at:stateRoot,create:false),fingerprint=try machine.fingerprint()
            try SyncProtocolLimits.digest(fingerprint)
            try store.validateDirectoryIdentity()
            let resolved=store.root.standardizedFileURL.resolvingSymlinksInPath()
            guard let raw=try resolved.resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString,let volume=UUID(uuidString:raw) else {throw OSwindError.unavailable("Stable library identity unavailable")}
            let vault=try VaultAccess.context(at:store.root).map {try SyncVaultPhysicalBinding.capture($0)}
            return try store.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {
                guard !(try LibraryWipeState.isPending(db)) else {throw OSwindError.unavailable("Finish library cleanup before pairing")}
                try PersonalSyncPairing.requireHooks(db)
                let scope=try SyncChangeCapture.scope(db),lifetime=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(lifetime)}
                db.bind(lifetime,1,PersonalSyncPairing.lifetimeKey)
                guard sqlite3_step(lifetime)==SQLITE_ROW else {throw OSwindError.unavailable("Pairing library lifetime retired; recovery is required")}
                let id=db.text(lifetime,0);try SyncProtocolLimits.uuid(id)
                return Self(installation:installation,machine:fingerprint,origin:scope.origin,generation:scope.generation,volume:volume.uuidString.lowercased(),inode:store.mediaRootIdentity.inode,lifetime:id,vault:vault)
            }}
        }
    }
    /// Only encoded into the dedicated private Keychain account. The nonsecret
    /// native handle is immutable and contains neither keys nor these payloads.
    private struct DeliveryReservation:Codable {let id:String,protection:SyncCredentialProtection}
    private struct Envelope:Codable {
        let format:String,version:Int,id:String,protection:SyncCredentialProtection,location:Location
        let pending:Data?,material:Data?,consumedRequest:String?,retired:Bool
        let delivery:DeliveryReservation?
        var initialApproval:SyncOwnerApprovalReference?=nil
        func replacing(pending:Data?=nil,material:Data?=nil,consumed:String?=nil,retired:Bool=false,approval:SyncOwnerApprovalReference?=nil)->Self {
            .init(format:format,version:version,id:id,protection:protection,location:location,pending:pending,material:material,consumedRequest:consumed,retired:retired,delivery:delivery,initialApproval:retired ? nil:(approval ?? initialApproval))
        }
        func reserving(_ next:DeliveryReservation)->Self {
            .init(format:format,version:version,id:id,protection:protection,location:location,pending:pending,material:material,consumedRequest:consumedRequest,retired:retired,delivery:next,initialApproval:initialApproval)
        }
        func rebinding(_ next:Location)->Self {.init(format:format,version:version,id:id,protection:protection,location:next,pending:pending,material:material,consumedRequest:consumedRequest,retired:retired,delivery:delivery,initialApproval:next.lifetime==location.lifetime ? initialApproval:nil)}
        func validate()throws {
            if let initialApproval {
                try initialApproval.validate()
                guard !retired,pending==nil,let material,try SyncCredentialMaterial.decodeFromKeychain(material).owner != nil,
                      initialApproval.pairingID==id,initialApproval.lifetime==location.lifetime else {throw OSwindError.invalid("Saved approval belongs to another owner lifetime")}
            }
            if let delivery {
                try SyncCredentialStorageLimits.validate(id:delivery.id)
                guard delivery.protection==protection,!retired,material != nil,pending==nil else {throw OSwindError.invalid("Invalid reserved delivery authority")}
            }
            guard format=="OSwind.sync.pairing-anchor",version==1 else {throw OSwindError.invalid("Invalid pairing credential")}
            try SyncCredentialStorageLimits.validate(id:id)
            if let consumedRequest {try SyncProtocolLimits.digest(consumedRequest)}
            if retired {guard pending==nil,material==nil else {throw OSwindError.invalid("Retired pairing retained keys")}}
            else if let pending {guard material==nil,consumedRequest==nil else {throw OSwindError.invalid("Ambiguous pairing state")};_=try SyncPendingJoin.decodeFromKeychain(pending)}
            else if let material {guard consumedRequest != nil else {throw OSwindError.invalid("Pairing request consumption missing")};_=try SyncCredentialMaterial.decodeFromKeychain(material)}
            else {throw OSwindError.invalid("Missing pairing state")}
        }
        func encoded()throws->Data {try validate();let bytes=try SyncProtocolLimits.encode(self);try SyncCredentialStorageLimits.validate(id:id,bytes:bytes);return bytes}
        static func decode(_ bytes:Data)throws->Self {let value=try SyncPairingFormat.decode(Self.self,bytes,limit:SyncCredentialStorageLimits.maximumBytes);try value.validate();return value}
    }
    private static let handleKey="sync-pairing-handle-v1",lifetimeKey="sync-pairing-library-lifetime-v1"
    private static let hooks:[String:String]=Dictionary(uniqueKeysWithValues:["insert","update"].map {op in
        let name="sync_pairing_native_wipe_"+op
        return (name,"CREATE TRIGGER \(name) AFTER \(op.uppercased()) ON store_metadata WHEN new.key IN ('library_wipe_dirty','library_group_wipe_dirty_v1') AND new.value='1' BEGIN DELETE FROM store_metadata WHERE key='\(lifetimeKey)'; END")
    })
    private let mutex=NSRecursiveLock(),store:MemoryStore,stateRoot:URL,machine:any SyncMachineFingerprint
    private let injectedStorage:(any SyncCredentialStorage)?
    private var handle:Handle?,storage:(any SyncCredentialStorage)?,lease:SyncCredentialExclusiveLease?,closed=false
    private var retirementOnly=false
    public convenience init(store:MemoryStore)throws {try self.init(store:store,stateRoot:SyncLocalCredentialState.root,machine:MacSyncMachineFingerprint(),storage:nil)}
    init(store:MemoryStore,stateRoot:URL,machine:any SyncMachineFingerprint,storage:(any SyncCredentialStorage)?,retirementRecovery:Bool=false)throws {
        self.store=store;self.stateRoot=stateRoot;self.machine=machine;injectedStorage=storage
        if retirementRecovery {
            guard let saved=try store.withRetirementDatabase({_ in try readHandle()}) else {throw OSwindError.unavailable("Retirement pairing handle is missing")}
            try adopt(saved);retirementOnly=true;return
        }
        let media=try MediaAdmissionLease.acquire(root:store.root,exclusive:false,expectedRoot:store.mediaRootIdentity);defer {media.release()}
        if let saved=try readHandle() {try adopt(saved);_=try current()}
    }
    public var description:String {"<redacted personal sync pairing owner>"}
    public var debugDescription:String {description}
    public var customMirror:Mirror {Mirror(self,children:["pairing":"redacted"])}
    deinit {lease?.close()}
    public func belongs(to candidate:MemoryStore)->Bool {candidate===store}
    public func close() {mutex.lock();defer {mutex.unlock()};closed=true;lease?.close();lease=nil;storage=nil}
    private func withAccess<T>(_ body:()throws->T)throws->T {
        mutex.lock();defer {mutex.unlock()}
        guard !closed,!retirementOnly,!store.isClosed else {throw OSwindError.unavailable("Pairing owner is closed or owned by retirement recovery")}
        let media=try MediaAdmissionLease.acquire(root:store.root,exclusive:false,expectedRoot:store.mediaRootIdentity);defer {media.release()}
        try Task.checkCancellation();return try body()
    }
    private func readHandle()throws->Handle? {
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,Self.handleKey)
            let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw db.error()}
            let bytes=Data(db.text(row,0).utf8),value=try SyncPairingFormat.decode(Handle.self,bytes,limit:1024)
            guard value.format=="OSwind.sync.pairing-handle",value.version==1 else {throw OSwindError.invalid("Invalid pairing handle")}
            try SyncCredentialStorageLimits.validate(id:value.id);return value
        }
    }
    private func adopt(_ value:Handle)throws {
        let backend=injectedStorage ?? SyncKeychainCredentialStorage(protection:value.protection)
        guard backend.protection==value.protection else {throw OSwindError.unavailable("The saved pairing requires its original Keychain protection")}
        let owned=try SyncCredentialExclusiveLease(id:value.id,stateRoot:stateRoot)
        handle=value;storage=backend;lease=owned
    }
    private static func requireHooks(_ db:RoutineDatabase)throws {
        for (name,sql) in hooks {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.unavailable("Pairing lifetime protection is missing or changed")}
        }
    }
    static func retirementLifetime(_ db:RoutineDatabase)throws->String {
        let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,lifetimeKey)
        guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("Retain the original pairing lifetime before retirement")}
        let value=db.text(row,0);try SyncProtocolLimits.uuid(value);return value
    }
    static func openRetirement(store:MemoryStore,environment:SyncNativeWriterEnvironment)throws->PersonalSyncPairing {
        let protection=try store.withRetirementDatabase {db -> SyncCredentialProtection in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,handleKey)
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("Retirement pairing handle is missing")}
            return try SyncPairingFormat.decode(Handle.self,Data(db.text(row,0).utf8),limit:1024).protection
        }
        return try PersonalSyncPairing(store:store,stateRoot:environment.stateRoot,machine:environment.machine,storage:environment.storage(protection),retirementRecovery:true)
    }
    typealias RetirementPreparation=(RoutineDatabase,SyncDeliveryRetirement,Data,String)throws->(()throws->Void)
    /// Close public command admission BEFORE the erase owner takes an exclusive
    /// media lease. This avoids a pairing-mutex/media lock inversion. The
    /// returned preparation can only renew the exact saved original lifetime.
    func retirementRenewalPreparation()throws->RetirementPreparation {
        mutex.lock();defer {mutex.unlock()}
        guard !closed,!store.isClosed,handle != nil,storage != nil,let lease else {throw OSwindError.unavailable("Resume the original pairing owner before renewal")}
        try lease.requireCurrentIdentity();retirementOnly=true
        return {[self] db,record,material,anchorID in
            mutex.lock();defer {mutex.unlock()}
            guard !closed,let handle,let storage,let lease=self.lease,sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.unavailable("Pairing renewal owner closed or left its transaction")}
            try lease.requireCurrentIdentity()
            let bytes=try storage.read(id:handle.id),saved=try Envelope.decode(bytes)
            guard saved.id==handle.id,saved.protection==handle.protection,!saved.retired,saved.pending==nil,saved.material==material,
                  saved.delivery?.id==anchorID,saved.delivery?.protection==handle.protection,saved.location.lifetime==record.pairingLifetime else {throw OSwindError.unavailable("Original pairing authority changed during retirement; use recovery")}
            let current=try readHandle()
            guard current==handle,try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-pairing-library-lifetime-v1'")==0 else {throw OSwindError.invalid("Renew only the retired native pairing lifetime")}
            let lifetime=UUID().uuidString.lowercased(),put=try db.statement("INSERT INTO store_metadata(key,value) VALUES(?,?)");defer {sqlite3_finalize(put)}
            db.bind(put,1,Self.lifetimeKey);db.bind(put,2,lifetime);try db.done(put)
            let location=try Location.capture(store,stateRoot:stateRoot,machine:machine)
            guard location.replacingLifetime(saved.location.lifetime)==saved.location else {throw OSwindError.unavailable("Retirement moved to another physical library or installation")}
            let encoded=try saved.rebinding(location).encoded()
            return {[self] in
                mutex.lock();defer {mutex.unlock()}
                guard !closed else {throw OSwindError.unavailable("Pairing renewal owner closed before its external save")}
                try lease.requireCurrentIdentity();try storage.replace(id:handle.id,expected:bytes,bytes:encoded)
            }
        }
    }
    /// The external pairing reservation survives restoring a database from
    /// before writer-fence installation. Check it before constructor migrations
    /// can write, without acquiring the pairing owner's exclusive lease.
    static func requirePreFenceDeliveryAdmission(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment)throws {
        let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,handleKey)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return};guard code==SQLITE_ROW else {throw db.error()}
        let handle=try SyncPairingFormat.decode(Handle.self,Data(db.text(row,0).utf8),limit:1024)
        guard handle.format=="OSwind.sync.pairing-handle",handle.version==1 else {throw OSwindError.invalid("Invalid pairing handle; use backup recover")}
        try SyncCredentialStorageLimits.validate(id:handle.id)
        let storage=environment.storage(handle.protection)
        guard storage.protection==handle.protection else {throw OSwindError.unavailable("Resume the original pairing protection tier")}
        let saved=try Envelope.decode(storage.read(id:handle.id))
        guard saved.id==handle.id,saved.protection==handle.protection else {throw OSwindError.unavailable("Pairing authority differs from its native handle; use recovery")}
        guard let delivery=saved.delivery else {return}
        guard try db.eraseCount("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='personal_sync_delivery_anchor'")==1 else {throw OSwindError.unavailable("Reserved device sync setup is missing from this native history; export with backup recover")}
        let anchor=try db.statement("SELECT id,protection FROM personal_sync_delivery_anchor WHERE singleton=1");defer {sqlite3_finalize(anchor)}
        guard sqlite3_step(anchor)==SQLITE_ROW,db.text(anchor,0)==delivery.id,db.text(anchor,1)==delivery.protection.rawValue else {throw OSwindError.unavailable("Resume the originally reserved delivery authority; use recovery")}
        _=try SyncDeliveryAnchor.nativeWriterProof(library:library,db:db,environment:environment)
    }
    private func current()throws->(Envelope,Data) {
        guard let handle,let storage,let lease else {throw OSwindError.unavailable("Create or request pairing first")}
        try lease.requireCurrentIdentity()
        guard try readHandle()==handle else {throw OSwindError.unavailable("Pairing native handle changed; use recovery")}
        let bytes=try storage.read(id:handle.id),value=try Envelope.decode(bytes)
        guard value.id==handle.id,value.protection==handle.protection,
              value.location == (try Location.capture(store,stateRoot:stateRoot,machine:machine)) else {throw OSwindError.unavailable("Pairing belongs to a different Mac, installation or library lifetime; use recovery")}
        return (value,bytes)
    }
    private func save(_ value:Envelope,expected:Data,beforeReplacement:()throws->Void={})throws {
        guard let storage,let lease else {throw OSwindError.unavailable("Pairing owner is closed")}
        try lease.requireCurrentIdentity()
        let (_,currentBytes)=try current();guard currentBytes==expected else {throw SyncCredentialStorageError.changed}
        // Cancellation before this boundary leaves the old durable state. After
        // replacement a caller must reload it; cancellation is not rollback.
        try Task.checkCancellation();let encoded=try value.encoded();try beforeReplacement();try storage.replace(id:value.id,expected:expected,bytes:encoded)
    }
    private func create(pending:SyncPendingJoin,material:SyncCredentialMaterial?)throws->PersonalSyncPairingStatus {
        guard handle==nil,try readHandle()==nil else {throw OSwindError.unavailable("An existing pairing must be resumed or recovered")}
        _=try SyncLocalCredentialState.installationID(at:stateRoot,create:true)
        let backend=injectedStorage ?? SyncKeychainCredentialStorage(protection:.loginKeychain)
        let saved=Handle(format:"OSwind.sync.pairing-handle",version:1,id:UUID().uuidString.lowercased(),protection:backend.protection)
        // Reserve before touching the Keychain. A crash/denial leaves this exact
        // handle for recovery and can never silently regenerate an old identity.
        try adopt(saved)
        try store.withRoutineDatabase {db in
            guard sqlite3_get_autocommit(db.handle) != 0 else {throw OSwindError.invalid("Pair outside native transactions")}
            try db.execute("PRAGMA synchronous=FULL")
            try SyncChangeCapture.transaction(db) {
                guard try readHandle()==nil,!(try LibraryWipeState.isPending(db)) else {throw OSwindError.unavailable("Library pairing admission changed")}
                for (_,sql) in Self.hooks {try db.execute(sql)}
                let put=try db.statement("INSERT INTO store_metadata(key,value) VALUES(?,?)");defer {sqlite3_finalize(put)}
                db.bind(put,1,Self.lifetimeKey);db.bind(put,2,UUID().uuidString.lowercased());try db.done(put)
                sqlite3_reset(put);sqlite3_clear_bindings(put);db.bind(put,1,Self.handleKey);db.bind(put,2,String(decoding:try SyncProtocolLimits.encode(saved),as:UTF8.self));try db.done(put)
                if let material {try SyncMembershipHistory.retain([material.joined.certificate],anchoredHead:material.joined.certificate,db:db)}
            }
        }
        let value=Envelope(format:"OSwind.sync.pairing-anchor",version:1,id:saved.id,protection:saved.protection,location:try Location.capture(store,stateRoot:stateRoot,machine:machine),pending:material==nil ? try pending.encodedForKeychain():nil,material:try material?.encodedForKeychain(),consumedRequest:material==nil ? nil:try pending.request.digest,retired:false,delivery:nil)
        try Task.checkCancellation();try backend.create(id:saved.id,bytes:value.encoded())
        return try status(value)
    }
    public func status()throws->PersonalSyncPairingStatus {try withAccess {
        guard handle != nil else {
            guard try readHandle()==nil else {throw OSwindError.unavailable("Pairing changed; reopen setup")}
            return .init(phase:.unconfigured,deviceName:"",memberNames:[],rootFingerprint:nil,requestFingerprint:nil,request:nil,expires:nil,deliveryPrepared:false)
        }
        return try status(current().0)
    }}
    private func status(_ value:Envelope)throws->PersonalSyncPairingStatus {
        if value.retired {return .init(phase:.retired,deviceName:"",memberNames:[],rootFingerprint:nil,requestFingerprint:nil,request:nil,expires:nil,deliveryPrepared:false)}
        if let bytes=value.pending {
            let pending=try SyncPendingJoin.decodeFromKeychain(bytes)
            return .init(phase:.waitingForOwner,deviceName:pending.request.body.name,memberNames:[],rootFingerprint:nil,requestFingerprint:try pending.request.digest,request:String(decoding:try pending.request.encoded(),as:UTF8.self),expires:Date(timeIntervalSince1970:TimeInterval(pending.request.body.expires)),deliveryPrepared:false)
        }
        let material=try SyncCredentialMaterial.decodeFromKeychain(value.material!)
        let certificate=material.joined.certificate
        return .init(phase:material.owner==nil ? .paired:.owner,deviceName:certificate.body.members.first {$0.replica==material.joined.replica}!.name,memberNames:certificate.body.members.map(\.name),rootFingerprint:try SyncPairingFormat.fingerprint(certificate.body.rootPublicKey),requestFingerprint:nil,request:nil,expires:nil,deliveryPrepared:value.delivery != nil,lastResponseAvailable:value.initialApproval != nil)
    }
    public func createGroup(deviceName:String,now:Date=Date())throws->PersonalSyncPairingStatus {try withAccess {
        let pending=try SyncPendingJoin(name:deviceName,now:now),owner=try SyncGroupAuthority(owner:pending.request,now:now)
        let joined=try pending.accept(owner.response(to:pending.request,now:now),expectedRootFingerprint:owner.fingerprint,now:now)
        return try create(pending:pending,material:.init(joined:joined,owner:owner))
    }}
    public func requestJoin(deviceName:String,now:Date=Date())throws->PersonalSyncPairingStatus {try withAccess {try create(pending:.init(name:deviceName,now:now),material:nil)}}
    public func renewRequest(now:Date=Date())throws->PersonalSyncPairingStatus {try withAccess {
        let (value,bytes)=try current();guard let saved=value.pending,!value.retired else {throw OSwindError.invalid("Only a pending request can renew")}
        let pending=try SyncPendingJoin.decodeFromKeychain(saved).renewed(now:now),next=value.replacing(pending:try pending.encodedForKeychain())
        try save(next,expected:bytes);return try status(next)
    }}
    public func reviewRequest(_ text:String,now:Date=Date())throws->PersonalSyncPairingReview {try withAccess {
        let (value,saved)=try current();guard value.delivery==nil,let raw=value.material,let owner=try SyncCredentialMaterial.decodeFromKeychain(raw).owner else {throw OSwindError.invalid("Review requests on the group owner's Mac")}
        guard text.utf8.count<=SyncPairingFormat.requestLimit else {throw OSwindError.invalid("Pairing request exceeds its bound")}
        let request=try SyncJoinRequest.decode(Data(text.utf8),now:now)
        return .init(deviceName:request.body.name,requestFingerprint:try request.digest,expires:Date(timeIntervalSince1970:TimeInterval(request.body.expires)),alreadyAdmitted:owner.certificate.body.members.contains(try SyncMember(request)),bytes:try request.encoded(),ownerState:SyncProtocolLimits.hex(saved))
    }}
    /// Persist the new membership before returning its encrypted response. A
    /// retry returns the exact saved ciphertext while its request remains valid.
    public func approve(_ review:PersonalSyncPairingReview)throws->String {try approve(review,clock:{Date()})}
    // Clock injection is internal for deterministic fixtures, never a public
    // way to authorize a new approval using a caller-supplied past timestamp.
    func approve(_ review:PersonalSyncPairingReview,now:Date)throws->String {try approve(review,clock:{now})}
    func approve(_ review:PersonalSyncPairingReview,clock:()->Date)throws->String {try withAccess {
        let (value,bytes)=try current();guard value.delivery==nil,let raw=value.material,let owner=try SyncCredentialMaterial.decodeFromKeychain(raw).owner else {throw OSwindError.invalid("Only the group owner can approve devices")}
        let now=clock()
        let material=try SyncCredentialMaterial.decodeFromKeychain(raw),request=try SyncJoinRequest.decode(review.bytes,now:now)
        if value.initialApproval?.requestDigest == (try request.digest) {return try loadInitialApproval(value,material:material).response}
        guard review.ownerState==SyncProtocolLimits.hex(bytes),review.alreadyAdmitted==owner.certificate.body.members.contains(try SyncMember(request)) else {throw OSwindError.invalid("The owner changed after review; review this request again")}
        let nextOwner=try owner.admitting(request,now:now)
        let joined=try material.joined.withCertificate(nextOwner.certificate),next=try SyncCredentialMaterial(joined:joined,owner:nextOwner)
        let plan=try nextOwner.approvalPlan(to:request,prior:owner.certificate,pairingID:value.id,lifetime:value.location.lifetime,now:now),planBytes=try plan.encoded(),reference=try plan.reference()
        try retainMembershipHistory([material.joined.certificate,nextOwner.certificate],head:material.joined.certificate)
        let path=store.root.appendingPathComponent("images/device-sync-"+material.joined.replica,isDirectory:true)
        let inbox=try FileManager.default.fileExists(atPath:path.path) ? material.joined.openPrivateInbox(at:path):material.joined.createPrivateInbox(at:path)
        defer {inbox.close()};try inbox.publishContent(planBytes,reference:reference.content)
        try save(value.replacing(material:next.encodedForKeychain(),consumed:value.consumedRequest,approval:reference),expected:bytes,beforeReplacement:{try request.validate(now:clock())})
        return String(decoding:plan.response,as:UTF8.self)
    }}
    /// Explicit recovery only. Normal status never returns encrypted response
    /// text. Expired messages remain exact; the joiner still rejects at real now.
    public func lastApprovedResponse()throws->PersonalSyncApprovedResponse? {try withAccess {
        let (value,_)=try current();guard let raw=value.material,!value.retired else {return nil}
        let material=try SyncCredentialMaterial.decodeFromKeychain(raw)
        guard material.owner != nil,value.initialApproval != nil else {return nil}
        return try loadInitialApproval(value,material:material)
    }}
    private func loadInitialApproval(_ value:Envelope,material:SyncCredentialMaterial)throws->PersonalSyncApprovedResponse {
        guard let reference=value.initialApproval else {throw OSwindError.unavailable("No saved joining response")}
        try reference.validate()
        let inbox=try material.joined.openPrivateInbox(at:store.root.appendingPathComponent("images/device-sync-"+material.joined.replica));defer {inbox.close()}
        guard let bytes=try inbox.content(reference.content),reference.content.matches(bytes) else {throw OSwindError.unavailable("The saved encrypted response is missing; recovery is required")}
        let plan=try SyncOwnerApprovalPlan.decode(bytes)
        try plan.require(reference,current:material.joined.certificate,pairingID:value.id,lifetime:value.location.lifetime)
        _=try store.withRoutineDatabase {try SyncMembershipHistory.page(after:plan.certificate,anchoredHead:material.joined.certificate,db:$0)}
        return .init(response:String(decoding:plan.response,as:UTF8.self),deviceName:plan.request.body.name,requestFingerprint:plan.binding.requestDigest,approvedAt:Date(timeIntervalSince1970:TimeInterval(plan.binding.approvedAt)),expires:Date(timeIntervalSince1970:TimeInterval(plan.request.body.expires)))
    }
    public func acceptResponse(_ text:String,trustedRootFingerprint:String,now:Date=Date())throws->PersonalSyncPairingStatus {try withAccess {
        let (value,bytes)=try current();guard let raw=value.pending,!value.retired else {throw OSwindError.invalid("The pending request has already been consumed or retired")}
        guard text.utf8.count<=SyncPairingFormat.responseLimit else {throw OSwindError.invalid("Pairing response exceeds its bound")}
        let pending=try SyncPendingJoin.decodeFromKeychain(raw),joined=try pending.accept(Data(text.utf8),expectedRootFingerprint:trustedRootFingerprint,now:now)
        let next=value.replacing(material:try SyncCredentialMaterial(joined:joined).encodedForKeychain(),consumed:try pending.request.digest)
        try retainMembershipHistory([joined.certificate],head:joined.certificate)
        try save(next,expected:bytes);return try status(next)
    }}
    private func retainMembershipHistory(_ certificates:[SyncMembershipCertificate],head:SyncMembershipCertificate)throws {
        try store.withRoutineDatabase {db in
            guard sqlite3_get_autocommit(db.handle) != 0 else {throw OSwindError.invalid("Save membership history before its external credential boundary")}
            try db.execute("PRAGMA synchronous=FULL")
            try SyncChangeCapture.transaction(db) {try SyncMembershipHistory.retain(certificates,anchoredHead:head,db:db)}
        }
    }
    /// Public certificate only, used to request a root-signed catch-up path.
    /// No native membership mutation or private credential is returned.
    func membershipCertificateForRefresh()throws->SyncMembershipCertificate {try withAccess {
        let value=try current().0
        guard !value.retired,let material=value.material else {throw OSwindError.invalid("Finish pairing before requesting a membership update")}
        return try SyncCredentialMaterial.decodeFromKeychain(material).joined.certificate
    }}
    func membershipRefresh(after trusted:SyncMembershipCertificate)throws->SyncMembershipRefresh? {try withAccess {
        let head=try membershipCertificateForRefresh()
        return try store.withRoutineDatabase {try SyncMembershipHistory.page(after:trusted,anchoredHead:head,db:$0)}
    }}
    struct MembershipSnapshot {
        let pairingID:String,pairingBefore:String,pairingAfter:String,materialBefore:String,materialAfter:String
    }
    private static func membershipEnvelopes(_ value:Envelope,proof:SyncMembershipRefresh)throws->(before:Data,after:Data,materialBefore:Data,materialAfter:Data) {
        guard !value.retired,value.pending==nil,value.delivery != nil,let raw=value.material else {throw OSwindError.invalid("Use the originally enrolled pairing")}
        let material=try SyncCredentialMaterial.decodeFromKeychain(raw),candidates=try material.membershipCandidates(proof)
        let before=try candidates.before.encodedForKeychain(),after=try candidates.after.encodedForKeychain()
        return (try value.replacing(material:before,consumed:value.consumedRequest).encoded(),try value.replacing(material:after,consumed:value.consumedRequest).encoded(),before,after)
    }
    private static func membershipSnapshot(_ value:Envelope,bytes:Data,proof:SyncMembershipRefresh)throws->MembershipSnapshot {
        let candidates=try membershipEnvelopes(value,proof:proof)
        guard candidates.before==bytes else {throw OSwindError.invalid("Start preparation at the exact original private membership")}
        return .init(pairingID:value.id,pairingBefore:SyncProtocolLimits.hex(candidates.before),pairingAfter:SyncProtocolLimits.hex(candidates.after),materialBefore:SyncProtocolLimits.hex(candidates.materialBefore),materialAfter:SyncProtocolLimits.hex(candidates.materialAfter))
    }
    static func openMembershipPairing(library:MemoryStore,environment:SyncNativeWriterEnvironment)throws->PersonalSyncPairing {
        let protection=try library.withRoutineDatabase {db->SyncCredentialProtection in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,handleKey)
            guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_bytes(row,0)<=1024 else {throw OSwindError.unavailable("Resume an existing enrolled pairing")}
            let handle=try SyncPairingFormat.decode(Handle.self,Data(db.text(row,0).utf8),limit:1024)
            guard handle.format=="OSwind.sync.pairing-handle",handle.version==1 else {throw OSwindError.invalid("Invalid original membership pairing handle")};return handle.protection
        }
        return try Self(store:library,stateRoot:environment.stateRoot,machine:environment.machine,storage:environment.storage(protection))
    }
    struct MembershipFloorSnapshot {let pairingID:String,pairingDigest:String,materialDigest:String,head:String}
    func openMembershipFloorAnchor()throws->(SyncDeliveryAnchor,MembershipFloorSnapshot) {try withAccess {
        let (value,bytes)=try current()
        guard !value.retired,value.pending==nil,let delivery=value.delivery,let raw=value.material else {throw OSwindError.unavailable("Resume the original enrolled pairing before upgrading its floor")}
        let material=try SyncCredentialMaterial.decodeFromKeychain(raw),snapshot=MembershipFloorSnapshot(pairingID:value.id,pairingDigest:SyncProtocolLimits.hex(bytes),materialDigest:SyncProtocolLimits.hex(raw),head:SyncProtocolLimits.hex(try material.joined.certificate.encoded()))
        let anchor=try SyncDeliveryAnchor.openExisting(library:store,material:material,id:delivery.id,stateRoot:stateRoot,machine:machine,storage:injectedStorage ?? SyncKeychainCredentialStorage(protection:delivery.protection))
        return (anchor,snapshot)
    }}
    static func verifyMembershipFloor(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment,record:SyncMembershipFloorPreparation,deliveryID:String,material:Data)throws {
        try record.validate();let saved=try membershipEnvelope(library:library,db:db,environment:environment,deliveryID:deliveryID)
        guard saved.value.id==record.pairingID,SyncProtocolLimits.hex(saved.bytes)==record.pairingDigest,saved.value.material==material,SyncProtocolLimits.hex(material)==record.materialDigest else {throw OSwindError.unavailable("Membership floor differs from the original pairing account")}
    }
    func openMembershipPreparationAnchor(_ proof:SyncMembershipRefresh)throws->(SyncDeliveryAnchor,MembershipSnapshot) {try withAccess {
        let (value,bytes)=try current(),snapshot=try Self.membershipSnapshot(value,bytes:bytes,proof:proof)
        guard let delivery=value.delivery,let saved=value.material else {throw OSwindError.invalid("Resume the original enrolled pairing")}
        let backend=injectedStorage ?? SyncKeychainCredentialStorage(protection:delivery.protection)
        let anchor=try SyncDeliveryAnchor.openExisting(library:store,material:SyncCredentialMaterial.decodeFromKeychain(saved),id:delivery.id,stateRoot:stateRoot,machine:machine,storage:backend)
        return (anchor,snapshot)
    }}
    /// Both normal admission and saved recovery read only the originally
    /// enrolled account. This never creates a handle, backend or private key.
    private static func membershipEnvelope(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment,deliveryID:String)throws->(value:Envelope,bytes:Data,storage:any SyncCredentialStorage) {
        let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,handleKey)
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_TEXT,sqlite3_column_bytes(row,0)>0,sqlite3_column_bytes(row,0)<=1024 else {throw OSwindError.unavailable("Original membership pairing handle is missing")}
        let handle=try SyncPairingFormat.decode(Handle.self,Data(db.text(row,0).utf8),limit:1024)
        guard handle.format=="OSwind.sync.pairing-handle",handle.version==1 else {throw OSwindError.unavailable("Invalid original membership pairing handle")};try SyncCredentialStorageLimits.validate(id:handle.id)
        let backend=environment.storage(handle.protection);guard backend.protection==handle.protection else {throw OSwindError.unavailable("Keep the original membership protection tier")}
        let bytes=try backend.read(id:handle.id),value=try Envelope.decode(bytes)
        guard value.id==handle.id,value.protection==handle.protection,!value.retired,value.pending==nil,value.material != nil,value.delivery?.id==deliveryID,
              value.location == (try Location.capture(library,stateRoot:environment.stateRoot,machine:environment.machine)) else {throw OSwindError.unavailable("Membership pairing moved or changed its original lifetime")}
        return (value,bytes,backend)
    }
    static func verifyActiveMembership(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment,deliveryID:String,material:Data)throws {
        let saved=try membershipEnvelope(library:library,db:db,environment:environment,deliveryID:deliveryID)
        guard saved.value.material==material else {throw OSwindError.unavailable("Pairing and delivery membership differ; use the exact saved operation")}
    }
    /// Returns true only for the exact saved new pairing envelope. The two
    /// candidates preserve all original location/reservation/consumption fields.
    @discardableResult static func verifyMembershipPreparation(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment,record:SyncMembershipPreparation,proof:SyncMembershipRefresh,deliveryID:String)throws->Bool {
        let saved=try membershipEnvelope(library:library,db:db,environment:environment,deliveryID:deliveryID)
        guard saved.value.id==record.pairingID else {throw OSwindError.unavailable("Saved membership belongs to another pairing account")}
        let candidates=try membershipEnvelopes(saved.value,proof:proof),current=SyncProtocolLimits.hex(saved.bytes)
        guard SyncProtocolLimits.hex(candidates.before)==record.pairingBefore,SyncProtocolLimits.hex(candidates.after)==record.pairingAfter,
              SyncProtocolLimits.hex(candidates.materialBefore)==record.materialBefore,SyncProtocolLimits.hex(candidates.materialAfter)==record.materialAfter,
              current==record.pairingBefore || (record.disposition == .applying && current==record.pairingAfter) else {throw OSwindError.unavailable("Pairing differs from both exact saved operation candidates")}
        return current==record.pairingAfter
    }
    func requireMembershipLease(id:String)throws {
        mutex.lock();defer {mutex.unlock()}
        guard !closed,handle?.id==id,let lease else {throw OSwindError.unavailable("The original membership pairing owner is closed")};try lease.requireCurrentIdentity()
    }
    /// Caller holds both original credential leases and a native36 fence that
    /// is already proven committed. A failed/ambiguous CAS is never rollback.
    static func completeMembershipPreparation(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment,record:SyncMembershipPreparation,proof:SyncMembershipRefresh,deliveryID:String)throws {
        guard record.disposition == .applying,try db.eraseCount("PRAGMA user_version")==36,
              try SyncNativeMembershipState.read(db)==SyncNativeMembershipState.Value.prepared(record),
              try library.nativeWriterAdmission.membershipEpoch(db)==record.epochPrepared else {throw OSwindError.unavailable("Commit the exact saved native fence before private handover")}
        if try verifyMembershipPreparation(library:library,db:db,environment:environment,record:record,proof:proof,deliveryID:deliveryID) {return}
        let saved=try membershipEnvelope(library:library,db:db,environment:environment,deliveryID:deliveryID),candidates=try membershipEnvelopes(saved.value,proof:proof)
        guard saved.value.id==record.pairingID,SyncProtocolLimits.hex(saved.bytes)==record.pairingBefore,SyncProtocolLimits.hex(candidates.after)==record.pairingAfter else {throw SyncCredentialStorageError.changed}
        let checkpoint=try db.statement("SELECT id,serial,nonce FROM personal_sync_delivery_anchor WHERE singleton=1");defer {sqlite3_finalize(checkpoint)}
        guard sqlite3_step(checkpoint)==SQLITE_ROW,db.text(checkpoint,0)==deliveryID,sqlite3_column_type(checkpoint,1)==SQLITE_INTEGER,
              SyncDeliveryAnchor.Token(serial:sqlite3_column_int64(checkpoint,1),nonce:db.text(checkpoint,2))==record.tokenPrepared else {throw OSwindError.unavailable("The committed native fence changed before private handover")}
        try Task.checkCancellation();try saved.storage.replace(id:record.pairingID,expected:saved.bytes,bytes:candidates.after)
    }
    /// Internal service preparation. The public paused-session factory below
    /// also installs native admission before transferring pairing ownership.
    func prepareAnchoredService(shared:URL,createShared:Bool)throws->SyncLibraryService {try withAccess {
        let (value,_)=try current()
        guard !value.retired,let saved=value.material else {throw OSwindError.invalid("Finish pairing before preparing delivery")}
        let material=try SyncCredentialMaterial.decodeFromKeychain(saved),joined=material.joined
        let native=store.root.standardizedFileURL.resolvingSymlinksInPath().path,sharedPath=shared.standardizedFileURL.resolvingSymlinksInPath().path
        guard shared.isFileURL,sharedPath != native,!sharedPath.hasPrefix(native+"/"),!native.hasPrefix(sharedPath+"/") else {throw OSwindError.invalid("Keep the shared sync folder outside the native library")}
        let resumed:SyncDeliveryAnchor?
        if let reservation=value.delivery {
            resumed=try .openExisting(library:store,material:material,id:reservation.id,stateRoot:stateRoot,machine:machine,storage:injectedStorage ?? SyncKeychainCredentialStorage(protection:reservation.protection))
        }else {resumed=nil}
        var handedOff=false;defer {if !handedOff {resumed?.close()}}
        let transport=try createShared ? joined.createTransport(at:shared):joined.openTransport(at:shared)
        var inbox:SyncObjectFolder?,service:SyncLibraryService?
        do {
            let path=store.root.appendingPathComponent("images/device-sync-"+joined.replica,isDirectory:true)
            inbox=try FileManager.default.fileExists(atPath:path.path) ? joined.openPrivateInbox(at:path):joined.createPrivateInbox(at:path)
            let peers=joined.certificate.body.members.map(\.replica).filter {$0 != joined.replica}
            let prepared=try SyncLibraryService.install(library:store,replica:joined.replica,group:joined.certificate.body.group,epoch:joined.certificate.body.epoch,peers:peers,transport:transport,inbox:inbox!)
            service=prepared
            if let resumed {try prepared.attachExternalAnchor(resumed)}else {try installDeliveryAnchor(on:prepared)}
            handedOff=true;return prepared
        }catch {try? service?.stop();inbox?.close();transport.close();throw error}
    }}
    /// Explicit folder activation. Finish admitting the intended devices first;
    /// membership changes after delivery reservation require a later lifecycle.
    /// Success transfers this owner to the returned, initially paused session.
    public func prepareSession(sharedFolder:URL,createSharedFolder:Bool=false)throws->PersonalSyncSession {
        let service=try prepareAnchoredService(shared:sharedFolder,createShared:createSharedFolder)
        do {
            try saveSessionFolder(sharedFolder)
            try service.installNativeWriterAdmission()
            return try PersonalSyncSession(service:service,pairing:self)
        }catch {try? service.stop();service.inbox.close();service.transport.close();throw error}
    }
    /// A local nonsecret bookmark is separate from group credentials. Resolving
    /// never mounts a volume or prompts for access. Backups restore only their
    /// content allowlist, so this local metadata cannot activate a copied library.
    public func savedSessionFolder()throws->URL? {try withAccess {
        _=try current()
        return try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-session-folder-bookmark-v1'");defer {sqlite3_finalize(row)}
            let status=sqlite3_step(row);if status==SQLITE_DONE {return nil}
            guard status==SQLITE_ROW,let bytes=Data(base64Encoded:db.text(row,0)),!bytes.isEmpty,bytes.count<=65536 else {throw OSwindError.invalid("Choose the sync folder again; its saved bookmark is invalid")}
            var stale=false
            let folder=try URL(resolvingBookmarkData:bytes,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale)
            guard !stale,folder.isFileURL else {throw OSwindError.unavailable("Choose the existing sync folder again; its location changed")}
            return folder
        }
    }}
    public func prepareSavedSession()throws->PersonalSyncSession {
        guard let folder=try savedSessionFolder() else {throw OSwindError.unavailable("Choose a shared sync folder first")}
        return try prepareSession(sharedFolder:folder)
    }
    /// Acquire the original native delivery authority without a provider folder.
    /// Success transfers this pairing owner to a one-shot local eraser. A live
    /// session's credential lease refuses this before any native mutation.
    public func prepareLocalErasure()throws->PersonalSyncLocalErasure {try withAccess {
        let (value,_)=try current()
        guard !value.retired,let saved=value.material,let delivery=value.delivery else {throw OSwindError.unavailable("This library has no prepared delivery authority to retire")}
        let material=try SyncCredentialMaterial.decodeFromKeychain(saved),joined=material.joined
        let anchor=try SyncDeliveryAnchor.openExisting(library:store,material:material,id:delivery.id,stateRoot:stateRoot,machine:machine,storage:injectedStorage ?? SyncKeychainCredentialStorage(protection:delivery.protection))
        do {
            let cache=try store.withRoutineDatabase {db in
                let catalog=try SyncIdentityCatalog.openExisting(db)
                let journal=try SyncJournal(database:db,replica:joined.replica,group:joined.certificate.body.group,epoch:joined.certificate.body.epoch)
                return try SyncVersionStore.openExisting(catalog:catalog,journal:journal)
            }
            try anchor.installNativeWriterAdmission()
            return PersonalSyncLocalErasure(library:store,cache:cache,anchor:anchor,pairing:self)
        }catch {anchor.close();throw error}
    }}
    private func saveSessionFolder(_ folder:URL)throws {try withAccess {
        _=try current()
        let bookmark=try folder.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
        guard !bookmark.isEmpty,bookmark.count<=65536 else {throw OSwindError.invalid("The selected sync folder bookmark exceeds its bound")}
        try store.withRoutineDatabase {db in
            let row=try db.statement("INSERT INTO store_metadata(key,value) VALUES('sync-session-folder-bookmark-v1',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");defer {sqlite3_finalize(row)}
            db.bind(row,1,bookmark.base64EncodedString());try db.done(row)
        }
    }}
    /// Reserve the external account in the already durable pairing anchor
    /// BEFORE creating any native delivery marker. Restoring a pre-install
    /// database can therefore never allocate a fresh zero-floor account.
    /// Internal primitive used by the public owned-session factory.
    @discardableResult func installDeliveryAnchor(on service:SyncLibraryService)throws->SyncDeliveryAnchor {try withAccess {
        guard service.library===store else {throw OSwindError.invalid("Prepare delivery for the pairing owner's current library")}
        let (value,bytes)=try current()
        guard !value.retired,let saved=value.material else {throw OSwindError.invalid("Finish pairing before preparing delivery")}
        let material=try SyncCredentialMaterial.decodeFromKeychain(saved)
        guard material.joined.replica==service.cache.journal.replica,material.joined.certificate.body.group==service.cache.journal.group,material.joined.certificate.body.epoch==service.cache.journal.epoch else {throw OSwindError.invalid("Delivery service differs from this pairing identity")}
        try service.transport.requireSignedAuthority(material.joined.packetAuthority())
        let reservation:DeliveryReservation,fresh:Bool
        if let existing=value.delivery {reservation=existing;fresh=false}
        else {
            reservation = .init(id:UUID().uuidString.lowercased(),protection:value.protection);fresh=true
            try save(value.reserving(reservation),expected:bytes)
        }
        let backend=injectedStorage ?? SyncKeychainCredentialStorage(protection:reservation.protection)
        let anchor:SyncDeliveryAnchor
        if fresh {anchor=try .create(library:store,cache:service.cache,material:material,id:reservation.id,stateRoot:stateRoot,machine:machine,storage:backend)}
        else {anchor=try .open(library:store,cache:service.cache,material:material,id:reservation.id,stateRoot:stateRoot,machine:machine,storage:backend)}
        do {try service.attachExternalAnchor(anchor);return anchor}
        catch {anchor.close();throw error}
    }}
    /// Local retirement erases private material but retains a keyless external
    /// tombstone. This is not group revocation or permission to reuse identity.
    public func retire()throws->PersonalSyncPairingStatus {try withAccess {
        let (value,bytes)=try current()
        guard value.delivery==nil else {throw OSwindError.unavailable("Retire delivery through its lifecycle owner before retiring pairing")}
        let next=value.replacing(consumed:value.consumedRequest,retired:true)
        try save(next,expected:bytes);return try status(next)
    }}
}
