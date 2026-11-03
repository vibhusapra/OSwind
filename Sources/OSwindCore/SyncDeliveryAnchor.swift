import Foundation
import CSQLite

/// A consistent native database rollback boundary. This is not global freshness
/// against a withholding provider, malicious selective SQL edits or OS/Keychain
/// rollback. Public activation still requires native writer/lifecycle admission.
final class SyncDeliveryAnchor:@unchecked Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    struct Token:Codable,Equatable,Sendable {
        let serial:Int64,nonce:String
        func validate()throws {
            guard serial>=0,serial<Int64.max,nonce.utf8.count==32,nonce.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw OSwindError.invalid("Invalid delivery checkpoint")}
        }
    }
    private struct Envelope:Codable {
        let format:String,version:Int,id:String,protection:SyncCredentialProtection,binding:SyncEnrollmentBinding,material:Data,token:Token
        let retirement:SyncDeliveryRetirement?
        let membershipHead:String?,membershipPreparation:SyncMembershipPreparation?
        let membershipFloor:SyncMembershipFloorPreparation?
        let completedApproval:SyncDeliveryApprovalReference?
        init(format:String,version:Int,id:String,protection:SyncCredentialProtection,binding:SyncEnrollmentBinding,material:Data,token:Token,retirement:SyncDeliveryRetirement?,membershipHead:String?=nil,membershipPreparation:SyncMembershipPreparation?=nil,membershipFloor:SyncMembershipFloorPreparation?=nil,completedApproval:SyncDeliveryApprovalReference?=nil) {
            self.format=format;self.version=version;self.id=id;self.protection=protection;self.binding=binding;self.material=material;self.token=token;self.retirement=retirement;self.membershipHead=membershipHead;self.membershipPreparation=membershipPreparation;self.membershipFloor=membershipFloor;self.completedApproval=completedApproval
        }
        func replacing(_ next:Token)->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:next,retirement:retirement,membershipHead:membershipHead,membershipPreparation:membershipPreparation,membershipFloor:membershipFloor,completedApproval:completedApproval)}
        func retiring(_ next:Token,binding:SyncEnrollmentBinding,record:SyncDeliveryRetirement)->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:next,retirement:record,membershipHead:membershipHead,membershipPreparation:membershipPreparation,membershipFloor:membershipFloor)}
        func activating(_ next:Token,binding:SyncEnrollmentBinding)->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:next,retirement:nil,membershipHead:membershipHead,membershipPreparation:membershipPreparation,membershipFloor:membershipFloor)}
        func preparing(_ record:SyncMembershipPreparation,token:Token,head:String?=nil)->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:token,retirement:retirement,membershipHead:head ?? membershipHead,membershipPreparation:record,membershipFloor:membershipFloor,completedApproval:completedApproval)}
        func applying(_ record:SyncMembershipPreparation,material:Data,token:Token)->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:token,retirement:retirement,membershipHead:record.headAfter,membershipPreparation:record,membershipFloor:membershipFloor,completedApproval:completedApproval)}
        func clearingPreparation()->Self {
            let completed=membershipPreparation?.disposition == .applying ? (membershipPreparation?.approval ?? completedApproval):completedApproval
            return .init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:token,retirement:retirement,membershipHead:membershipHead,membershipPreparation:nil,membershipFloor:membershipFloor,completedApproval:completed)
        }
        func upgradingFloor(_ record:SyncMembershipFloorPreparation?)->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:record?.tokenAfter ?? token,retirement:retirement,membershipHead:membershipHead,membershipPreparation:membershipPreparation,membershipFloor:record,completedApproval:completedApproval)}
        func encoded()throws->Data {try token.validate();let bytes=try SyncProtocolLimits.encode(self);try SyncCredentialStorageLimits.validate(id:id,bytes:bytes);return bytes}
        static func decode(_ bytes:Data)throws->Self {
            let value=try SyncPairingFormat.decode(Self.self,bytes,limit:SyncCredentialStorageLimits.maximumBytes)
            guard value.format=="OSwind.sync.delivery-anchor",value.version==1,value.id==value.binding.id,value.protection==value.binding.protection,(value.binding.publicationLifetime==nil)==(value.retirement != nil) else {throw OSwindError.invalid("Invalid saved delivery authority")}
            try value.token.validate();try value.binding.validate();let material=try SyncCredentialMaterial.decodeFromKeychain(value.material);try value.retirement?.validate(material:material)
            if let head=value.membershipHead {try SyncProtocolLimits.digest(head);guard head==SyncProtocolLimits.hex(try material.joined.certificate.encoded()) else {throw OSwindError.invalid("Membership floor differs from its private certificate")}}
            guard value.membershipFloor==nil || (value.retirement==nil && value.membershipPreparation==nil) else {throw OSwindError.invalid("Select one saved delivery operation") }
            if let floor=value.membershipFloor {
                try floor.validate()
                guard value.token==floor.tokenAfter,value.membershipHead==floor.head,SyncProtocolLimits.hex(value.material)==floor.materialDigest,SyncProtocolLimits.hex(try material.joined.certificate.encoded())==floor.head else {throw OSwindError.invalid("Saved membership floor differs from its exact private authority")}
            }
            if let approval=value.completedApproval {
                try approval.validate()
                guard value.retirement==nil,approval.publicationLifetime==value.binding.publicationLifetime else {throw OSwindError.invalid("Completed approval belongs to another publication lifetime")}
            }
            if let record=value.membershipPreparation {
                try record.validate()
                if let approval=record.approval {try approval.require(pairingID:record.pairingID,head:record.headAfter,publicationLifetime:value.binding.publicationLifetime)}
                let hash=SyncProtocolLimits.hex(try material.encodedForKeychain()),head=SyncProtocolLimits.hex(try material.joined.certificate.encoded())
                guard value.retirement==nil,
                      (hash==record.materialBefore && head==record.headBefore) || (record.disposition == .applying && hash==record.materialAfter && head==record.headAfter) else {throw OSwindError.invalid("Prepared membership differs from both saved private candidates")}
            }
            return value
        }
    }
    private static let table="personal_sync_delivery_anchor"
    private static let schema="CREATE TABLE personal_sync_delivery_anchor(singleton INTEGER PRIMARY KEY CHECK(singleton=1),id TEXT NOT NULL,protection TEXT NOT NULL,serial INTEGER NOT NULL CHECK(typeof(serial)='integer' AND serial>=0 AND serial<9223372036854775807),nonce TEXT NOT NULL CHECK(length(nonce)=32))"
    // These mutate authenticated wire history, including out-of-order deletes
    // and receipts. Raw native capture/work queues are not assigned wire state.
    static let wireTables=["personal_sync_local","personal_sync_peers","personal_sync_registers","personal_sync_receipts","personal_sync_expected_operations","personal_sync_outbox","personal_sync_pending","personal_sync_observed","personal_sync_collection_approvals","personal_sync_collection_received_controls","personal_sync_service_heads"]
    private static let advance="UPDATE personal_sync_delivery_anchor SET serial=serial+1,nonce=lower(hex(randomblob(16))) WHERE singleton=1;"
    private static let hooks:[String:String] = {
        var values=[String:String]()
        for table in wireTables {for op in ["insert","update","delete"] {
            let name="sync_delivery_checkpoint_"+table+"_"+op
            values[name]="CREATE TRIGGER \(name) AFTER \(op.uppercased()) ON \(table) BEGIN \(advance) END"
        }}
        values["sync_delivery_checkpoint_sent"]="CREATE TRIGGER sync_delivery_checkpoint_sent AFTER UPDATE OF sent ON personal_sync_service_state WHEN old.sent IS NOT new.sent BEGIN \(advance) END"
        for op in ["insert","delete"] {
            let name="sync_delivery_checkpoint_service_"+op
            values[name]="CREATE TRIGGER \(name) AFTER \(op.uppercased()) ON personal_sync_service_state BEGIN \(advance) END"
        }
        values["sync_delivery_checkpoint_identity"]="CREATE TRIGGER sync_delivery_checkpoint_identity BEFORE UPDATE OF singleton,id,protection ON personal_sync_delivery_anchor BEGIN SELECT RAISE(ABORT,'Delivery checkpoint identity is immutable'); END"
        values["sync_delivery_checkpoint_monotonic"]="CREATE TRIGGER sync_delivery_checkpoint_monotonic BEFORE UPDATE OF serial,nonce ON personal_sync_delivery_anchor WHEN new.serial<=old.serial OR new.nonce=old.nonce BEGIN SELECT RAISE(ABORT,'Delivery checkpoint must advance'); END"
        values["sync_delivery_checkpoint_retained"]="CREATE TRIGGER sync_delivery_checkpoint_retained BEFORE DELETE ON personal_sync_delivery_anchor BEGIN SELECT RAISE(ABORT,'Retain delivery recovery authority'); END"
        return values
    }()
    private let lock=NSRecursiveLock(),library:MemoryStore,storage:any SyncCredentialStorage,machine:any SyncMachineFingerprint,stateRoot:URL
    private let lease:SyncCredentialExclusiveLease,id:String
    private let database:OpaquePointer,material:SyncCredentialMaterial
    private var schemaCookie:Int?
    private var envelope:Envelope,bytes:Data,closed=false,poisoned=false
    var description:String {"<redacted delivery checkpoint owner>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["delivery":"redacted"])}

    /// `id` comes from the pairing owner's durably saved reservation, never a
    /// UUID regenerated after an old native handle/checkpoint goes missing.
    static func create(library:MemoryStore,cache:SyncVersionStore,material:SyncCredentialMaterial,id:String,stateRoot:URL,machine:any SyncMachineFingerprint,storage:any SyncCredentialStorage)throws->Self {
        try SyncCredentialStorageLimits.validate(id:id)
        let lease=try SyncCredentialExclusiveLease(id:id,stateRoot:stateRoot)
        var retained=false;defer {if !retained {lease.close()}}
        let media=try library.mediaWriteLease();defer {media.release()}
        let token=try library.withRoutineDatabase {db in
            guard db.handle==cache.database.handle,sqlite3_get_autocommit(db.handle) != 0 else {throw OSwindError.invalid("Create delivery authority outside native transactions")}
            try db.execute("PRAGMA synchronous=FULL")
            return try SyncChangeCapture.transaction(db) {
                try requireMaterial(material,cache:cache)
                guard try db.eraseCount("SELECT COUNT(*) FROM sqlite_master WHERE name='personal_sync_delivery_anchor'")==0,
                      try db.eraseCount("SELECT sequence FROM personal_sync_local WHERE singleton=1")==0,
                      try db.eraseCount("SELECT COUNT(*) FROM personal_sync_receipts")==0,
                      try db.eraseCount("SELECT COUNT(*) FROM personal_sync_registers")==0,
                      try db.eraseCount("SELECT counter FROM personal_sync_collection_local WHERE singleton=1")==0,
                      try db.eraseCount("SELECT COUNT(*) FROM personal_sync_collection_frontier")==0,
                      try db.eraseCount("SELECT COUNT(*) FROM personal_sync_service_heads")==0,
                      try db.eraseCount("SELECT COUNT(*) FROM personal_sync_outbox")==0,
                      try db.eraseCount("SELECT COUNT(*) FROM personal_sync_pending")==0,
                      try db.eraseCount("SELECT COUNT(*) FROM personal_sync_collection_approvals")==0,
                      try db.eraseCount("SELECT COUNT(*) FROM personal_sync_collection_received_controls")==0 else {throw OSwindError.unavailable("Existing delivery history requires its original external authority")}
                try db.execute(schema)
                let row=try db.statement("INSERT INTO personal_sync_delivery_anchor VALUES(1,?,?,0,lower(hex(randomblob(16))))");defer {sqlite3_finalize(row)}
                db.bind(row,1,id);db.bind(row,2,storage.protection.rawValue);try db.done(row)
                for sql in hooks.values {try db.execute(sql)}
                return try readToken(db,id:id,protection:storage.protection)
            }
        }
        // The native reservation commits first. A failed create leaves this
        // exact account for recovery; it is never silently recreated on reopen.
        let installation=try SyncLocalCredentialState.installationID(at:stateRoot,create:false)
        let binding=try SyncEnrollmentBinding.capture(store:library,material:material,id:id,protection:storage.protection,machine:machine,installation:installation)
        guard binding.publicationLifetime != nil else {throw OSwindError.invalid("Install the native delivery lifetime first")}
        let envelope=Envelope(format:"OSwind.sync.delivery-anchor",version:1,id:id,protection:storage.protection,binding:binding,material:try material.encodedForKeychain(),token:token,retirement:nil),bytes=try envelope.encoded()
        try Task.checkCancellation();try storage.create(id:id,bytes:bytes)
        let value=Self(library:library,database:cache.database.handle,storage:storage,machine:machine,stateRoot:stateRoot,lease:lease,envelope:envelope,bytes:bytes,material:material)
        retained=true;try value.validate();return value
    }
    static func open(library:MemoryStore,cache:SyncVersionStore,material:SyncCredentialMaterial,id:String,stateRoot:URL,machine:any SyncMachineFingerprint,storage:any SyncCredentialStorage)throws->Self {
        let lease=try SyncCredentialExclusiveLease(id:id,stateRoot:stateRoot)
        var retained=false;defer {if !retained {lease.close()}}
        let bytes=try storage.read(id:id),envelope=try Envelope.decode(bytes)
        guard envelope.id==id,envelope.protection==storage.protection,envelope.material == (try material.encodedForKeychain()) else {throw OSwindError.unavailable("Resume the original delivery credential and membership")}
        try library.withRoutineDatabase {db in
            guard db.handle==cache.database.handle else {throw OSwindError.invalid("Resume delivery on its owning native connection")}
            try requireMaterial(material,cache:cache)
        }
        let value=Self(library:library,database:cache.database.handle,storage:storage,machine:machine,stateRoot:stateRoot,lease:lease,envelope:envelope,bytes:bytes,material:material)
        retained=true;try value.validate();return value
    }
    /// Resume the external owner before service installation may replace its
    /// native command token. A second preparation cannot invalidate a running
    /// service and only then discover that its credential lease is already held.
    static func openExisting(library:MemoryStore,material:SyncCredentialMaterial,id:String,stateRoot:URL,machine:any SyncMachineFingerprint,storage:any SyncCredentialStorage)throws->Self {
        let lease=try SyncCredentialExclusiveLease(id:id,stateRoot:stateRoot)
        var retained=false;defer {if !retained {lease.close()}}
        let bytes=try storage.read(id:id),envelope=try Envelope.decode(bytes)
        guard envelope.id==id,envelope.protection==storage.protection,envelope.material == (try material.encodedForKeychain()) else {throw OSwindError.unavailable("Resume the original delivery credential and membership")}
        let handle=try library.withRoutineDatabase {db in
            _=try nativeWriterProof(library:library,db:db,environment:.init(stateRoot:stateRoot,machine:machine,storage:{_ in storage}))
            return db.handle
        }
        let value=Self(library:library,database:handle,storage:storage,machine:machine,stateRoot:stateRoot,lease:lease,envelope:envelope,bytes:bytes,material:material)
        try value.validate();retained=true;return value
    }
    private init(library:MemoryStore,database:OpaquePointer,storage:any SyncCredentialStorage,machine:any SyncMachineFingerprint,stateRoot:URL,lease:SyncCredentialExclusiveLease,envelope:Envelope,bytes:Data,material:SyncCredentialMaterial) {
        self.library=library;self.database=database;self.storage=storage;self.machine=machine;self.stateRoot=stateRoot;self.lease=lease;self.envelope=envelope;self.bytes=bytes;self.material=material;id=envelope.id
    }
    deinit {lease.close()}
    func close() {lock.lock();defer {lock.unlock()};closed=true;lease.close()}
    func belongs(to store:MemoryStore)->Bool {library===store}
    private static func requireMaterial(_ material:SyncCredentialMaterial,cache:SyncVersionStore)throws {
        let joined=material.joined
        guard joined.replica==cache.journal.replica,joined.certificate.body.group==cache.journal.group,joined.certificate.body.epoch==cache.journal.epoch else {throw OSwindError.invalid("Delivery credential belongs to another journal")}
        _=try joined.packetAuthority()
        let db=cache.database,row=try db.statement("SELECT replica FROM personal_sync_peers ORDER BY replica LIMIT 65");defer {sqlite3_finalize(row)}
        var peers=[String](),code=sqlite3_step(row)
        while code==SQLITE_ROW {peers.append(db.text(row,0));code=sqlite3_step(row)}
        guard code==SQLITE_DONE,peers==joined.certificate.body.members.map(\.replica).sorted() else {throw OSwindError.invalid("Delivery peers differ from the trusted membership")}
    }
    func requireTransport(_ transport:SyncObjectFolder)throws {
        lock.lock();defer {lock.unlock()}
        guard !closed,!poisoned else {throw OSwindError.unavailable("Delivery authority is closed")}
        try transport.requireSignedAuthority(material.joined.packetAuthority())
    }
    private static func readToken(_ db:RoutineDatabase,id:String,protection:SyncCredentialProtection)throws->Token {
        let row=try db.statement("SELECT id,protection,serial,nonce,(SELECT COUNT(*) FROM personal_sync_delivery_anchor) FROM personal_sync_delivery_anchor WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==id,db.text(row,1)==protection.rawValue,sqlite3_column_type(row,2)==SQLITE_INTEGER,sqlite3_column_int64(row,4)==1 else {throw OSwindError.unavailable("Delivery checkpoint identity is missing or changed")}
        let token=Token(serial:sqlite3_column_int64(row,2),nonce:db.text(row,3));try token.validate();return token
    }
    private static func requireSchema(_ db:RoutineDatabase)throws {
        for (name,sql) in hooks.merging([table:schema],uniquingKeysWith:{$1}) {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.unavailable("Delivery checkpoint protection is missing or changed")}
        }
    }
    struct NativeWriterProof {
        private let id:String,protection:SyncCredentialProtection,token:Token,lifetime:String
        fileprivate init(id:String,protection:SyncCredentialProtection,token:Token,lifetime:String) {self.id=id;self.protection=protection;self.token=token;self.lifetime=lifetime}
        func matches(_ db:RoutineDatabase)throws->Bool {
            guard try SyncDeliveryAnchor.readToken(db,id:id,protection:protection)==token else {return false}
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='sync-publication-library-lifetime-v1'");defer {sqlite3_finalize(row)}
            return sqlite3_step(row)==SQLITE_ROW && db.text(row,0)==lifetime
        }
    }
    /// Immutable verification for an ordinary native connection. It neither
    /// owns a credential lease nor retains the store or delivery service.
    private static func readWriterAuthority(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment,retiring:Bool,membershipRecovery:Bool=false,floorRecovery:Bool=false)throws->(Envelope,SyncCredentialMaterial,any SyncCredentialStorage,Data) {
        let row=try db.statement("SELECT id,protection FROM personal_sync_delivery_anchor WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,let protection=SyncCredentialProtection(rawValue:db.text(row,1)) else {throw OSwindError.unavailable("Native delivery authority is missing; export with backup recover")}
        let id=db.text(row,0),storage=environment.storage(protection)
        guard storage.protection==protection else {throw OSwindError.invalid("Keep the enrolled credential protection tier")}
        let bytes=try storage.read(id:id),envelope=try Envelope.decode(bytes),material=try SyncCredentialMaterial.decodeFromKeychain(envelope.material)
        guard (envelope.retirement != nil)==retiring else {throw OSwindError.unavailable("Use the matching active or retirement recovery owner for this native history")}
        guard envelope.id==id,envelope.protection==protection else {throw OSwindError.unavailable("Resume the original delivery authority")}
        if !membershipRecovery,!floorRecovery,envelope.membershipPreparation != nil {throw PersonalSyncMembershipRecoveryRequired()}
        guard (envelope.membershipPreparation != nil)==membershipRecovery,(envelope.membershipFloor != nil)==floorRecovery else {throw OSwindError.unavailable("Resume the exact saved membership operation before ordinary access")}
        var nativeMaterial=material
        if membershipRecovery {
            let phase=try membershipPhase(db,library:library,envelope:envelope),record=envelope.membershipPreparation!
            let proof=try membershipProof(library:library,material:material,record:record),candidates=try material.membershipCandidates(proof)
            nativeMaterial = phase.isApplied ? candidates.after:candidates.before
        } else if floorRecovery {
            _=try membershipFloorPhase(db,library:library,envelope:envelope)
            try PersonalSyncPairing.verifyMembershipFloor(library:library,db:db,environment:environment,record:envelope.membershipFloor!,deliveryID:id,material:envelope.material)
        } else {
            guard try readToken(db,id:id,protection:protection)==envelope.token else {throw OSwindError.unavailable("Native history differs from its external checkpoint; export with backup recover")}
            try SyncNativeMembershipState.requireActive(db,certificate:material.joined.certificate,floor:envelope.membershipHead)
            if !retiring,envelope.membershipHead != nil {try PersonalSyncPairing.verifyActiveMembership(library:library,db:db,environment:environment,deliveryID:id,material:envelope.material)}
        }
        try requireSchema(db)
        let identity=try db.statement("SELECT replica,group_id,epoch FROM personal_sync_local WHERE singleton=1");defer {sqlite3_finalize(identity)}
        let joined=nativeMaterial.joined
        guard sqlite3_step(identity)==SQLITE_ROW,db.text(identity,0)==joined.replica,db.text(identity,1)==joined.certificate.body.group,db.text(identity,2)==joined.certificate.body.epoch else {throw OSwindError.unavailable("Native sync identity changed; use recovery")}
        let peers=try db.statement("SELECT replica FROM personal_sync_peers ORDER BY replica LIMIT 65");defer {sqlite3_finalize(peers)}
        var members=[String](),code=sqlite3_step(peers)
        while code==SQLITE_ROW {members.append(db.text(peers,0));code=sqlite3_step(peers)}
        guard code==SQLITE_DONE,members==joined.certificate.body.members.map(\.replica).sorted() else {throw OSwindError.unavailable("Native sync membership changed; use recovery")}
        try envelope.binding.verify(store:library,material:material,protection:protection,machine:environment.machine,installation:SyncLocalCredentialState.installationID(at:environment.stateRoot,create:false))
        return (envelope,material,storage,bytes)
    }
    static func nativeWriterProof(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment)throws->NativeWriterProof {
        let (value,_,_,_)=try readWriterAuthority(library:library,db:db,environment:environment,retiring:false)
        return NativeWriterProof(id:value.id,protection:value.protection,token:value.token,lifetime:value.binding.publicationLifetime!)
    }
    static func verifyRetirement(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment)throws {
        let (value,_,_,_)=try readWriterAuthority(library:library,db:db,environment:environment,retiring:true)
        try value.retirement!.requireLogicalCompletion(db,allowCleaned:true)
    }
    static func openRetirement(library:MemoryStore,environment:SyncNativeWriterEnvironment)throws->Self {
        let id=try library.withRetirementDatabase {db -> String in
            let row=try db.statement("SELECT id FROM personal_sync_delivery_anchor WHERE singleton=1");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("Retirement authority is missing")};return db.text(row,0)
        }
        try SyncCredentialStorageLimits.validate(id:id)
        let lease=try SyncCredentialExclusiveLease(id:id,stateRoot:environment.stateRoot)
        var retained=false;defer {if !retained {lease.close()}}
        let value=try library.withRetirementDatabase {db -> Self in
            let (saved,material,storage,bytes)=try readWriterAuthority(library:library,db:db,environment:environment,retiring:true)
            guard saved.id==id else {throw OSwindError.unavailable("Retirement account changed while opening")}
            try saved.retirement!.requireLogicalCompletion(db,allowCleaned:true)
            return Self(library:library,database:db.handle,storage:storage,machine:environment.machine,stateRoot:environment.stateRoot,lease:lease,envelope:saved,bytes:bytes,material:material)
        }
        retained=true;return value
    }
    func cleanupRetirement(progress:@escaping @Sendable (LibraryBackupProgress)->Void)throws->LibraryWipeResult {
        let media=try MediaAdmissionLease.acquire(root:library.root,exclusive:true,expectedRoot:library.mediaRootIdentity);defer {media.release()}
        return try library.withRetirementDatabase {db in
            lock.lock();defer {lock.unlock()}
            try requireCheckpoint(in:db)
            guard let retirement=envelope.retirement,try storage.read(id:id)==bytes else {throw OSwindError.unavailable("Resume the saved retirement authority")}
            try envelope.binding.verify(store:library,material:material,protection:storage.protection,machine:machine,installation:SyncLocalCredentialState.installationID(at:stateRoot,create:false))
            try retirement.requireLogicalCompletion(db,allowCleaned:true)
            let result=try library.nativeWriterAdmission.withRetirementCleanup(db) {
                try library.retryLibraryWipeCleanup(reservation:media,progress:progress)
            }
            try requireCheckpoint(in:db);try NativeMediaSchema.validate(db);try retirement.requireLogicalCompletion(db,allowCleaned:true)
            return result
        }
    }
    func completeRetirement(pairing:PersonalSyncPairing.RetirementPreparation,expectedKind:SyncDeliveryRetirement.Kind?=nil)throws->SyncCollectionControl {
        let media=try MediaAdmissionLease.acquire(root:library.root,exclusive:true,expectedRoot:library.mediaRootIdentity);defer {media.release()}
        return try library.withRetirementDatabase {db in
            lock.lock();defer {lock.unlock()}
            try requireCheckpoint(in:db)
            guard let record=envelope.retirement,expectedKind==nil || expectedKind==record.kind,
                  try storage.read(id:id)==bytes else {throw OSwindError.unavailable("Resume the exact saved retirement")}
            try record.requireLogicalCompletion(db,allowCleaned:true)
            guard !(try LibraryWipeState.isPending(db)),try db.eraseCount("SELECT COUNT(*) FROM erasure_assets")==0 else {throw OSwindError.unavailable("Complete physical cleanup before renewing device sync authority")}
            return try library.nativeWriterAdmission.withRetirementCleanup(db) {
                try Task.checkCancellation();try db.execute("BEGIN IMMEDIATE")
                var externalAttempted=false
                do {
                    try requireCheckpoint(in:db)
                    let catalog=try SyncIdentityCatalog.openExisting(db),joined=material.joined
                    let journal=try SyncJournal(database:db,replica:joined.replica,group:joined.certificate.body.group,epoch:joined.certificate.body.epoch)
                    let cache=try SyncVersionStore.openExisting(catalog:catalog,journal:journal)
                    try SyncPublicationQueue.renewAfterRetirement(cache:cache,library:library,record:record)
                    let savePairing=try pairing(db,record,envelope.material,id)
                    let binding=try SyncEnrollmentBinding.capture(store:library,material:material,id:id,protection:storage.protection,machine:machine,installation:SyncLocalCredentialState.installationID(at:stateRoot,create:false))
                    guard binding.publicationLifetime != nil else {throw OSwindError.invalid("Prepare the new native publication identity")}
                    try db.execute(Self.advance)
                    let next=try Self.readToken(db,id:id,protection:storage.protection),updated=envelope.activating(next,binding:binding),encoded=try updated.encoded()
                    try Task.checkCancellation()
                    // Two Keychain accounts cannot commit atomically with SQL.
                    // Any attempted external save denies this owner on failure.
                    // Saved original lifetimes prevent retrying a partially
                    // advanced pairing envelope as if it were the old one.
                    externalAttempted=true;try savePairing()
                    try storage.replace(id:id,expected:bytes,bytes:encoded)
                    envelope=updated;bytes=encoded
                    try db.execute("COMMIT")
                    try library.nativeWriterAdmission.activateAfterRetirement(db,verified:NativeWriterProof(id:id,protection:storage.protection,token:next,lifetime:binding.publicationLifetime!))
                    return record.control
                }catch {
                    if externalAttempted {poisoned=true;library.nativeWriterAdmission.invalidate()}
                    do {try db.execute("ROLLBACK");if !externalAttempted {try requireCheckpoint(in:db)}}catch {poisoned=true;library.nativeWriterAdmission.invalidate()}
                    throw error
                }
            }
        }
    }
    func installNativeWriterAdmission()throws {
        try validate()
        let media=try library.mediaWriteLease();defer {media.release()}
        try library.withRoutineDatabase {db in
            try requireCheckpoint(in:db)
            try library.nativeWriterAdmission.install(db,library:library,environment:.init(stateRoot:stateRoot,machine:machine,storage:{[storage] protection in
                // This anchor already owns the exact protection-tier backend.
                // The admission verifier rejects any different requested tier.
                return storage
            }))
        }
    }
    private func available(_ db:RoutineDatabase)throws {
        guard !closed,!poisoned,!library.isClosed,db.handle==database else {throw OSwindError.unavailable("Delivery authority needs to be reopened or recovered")}
        try lease.requireCurrentIdentity()
    }
    /// Call with the native SQL mutex already held. Never acquire the anchor
    /// mutex then wait for SQLite: the service uses media -> SQL -> anchor order.
    func requireCheckpoint(in db:RoutineDatabase)throws {
        lock.lock();defer {lock.unlock()}
        try available(db)
        guard envelope.membershipPreparation==nil,envelope.membershipFloor==nil else {throw OSwindError.unavailable("Finish the saved membership operation before delivery")}
        let cookie=try db.eraseCount("PRAGMA schema_version")
        if schemaCookie != cookie {try Self.requireSchema(db);schemaCookie=cookie}
        guard try Self.readToken(db,id:id,protection:storage.protection)==envelope.token else {throw OSwindError.unavailable("Native delivery history differs from its external checkpoint; use recovery")}
    }
    func validate()throws {
        let media=try library.mediaWriteLease();defer {media.release()}
        try library.withRoutineDatabase {db in
            lock.lock();defer {lock.unlock()}
            try requireCheckpoint(in:db)
            guard try storage.read(id:id)==bytes else {throw OSwindError.unavailable("External delivery authority changed or is unavailable")}
            try envelope.binding.verify(store:library,material:material,protection:storage.protection,machine:machine,installation:SyncLocalCredentialState.installationID(at:stateRoot,create:false))
        }
    }
    /// No provider writes are allowed inside this native mutation transaction.
    /// Save external state before COMMIT, so native incoming effects cannot be
    /// visible before their checkpoint exists. A failed/ambiguous final commit
    /// poisons admission and leaves the external floor intact for recovery.
    func mutate<T>(in db:RoutineDatabase,_ body:()throws->T)throws->T {
        try library.nativeWriterAdmission.withDeliveryMutation {try mutateOwned(in:db,body)}
    }
    func retireLocal(in db:RoutineDatabase,_ body:()throws->SyncNativeRetirementResult)throws->SyncNativeRetirementResult {
        try retireNative(in:db,kind:.local,body)
    }
    func retireReceived(in db:RoutineDatabase,_ body:()throws->SyncNativeRetirementResult)throws->SyncNativeRetirementResult {
        try retireNative(in:db,kind:.received,body)
    }
    private func retireNative(in db:RoutineDatabase,kind:SyncDeliveryRetirement.Kind,_ body:()throws->SyncNativeRetirementResult)throws->SyncNativeRetirementResult {
        try library.nativeWriterAdmission.withRetirementMutation {
            try mutateOwned(in:db,retiring:{SyncDeliveryRetirement(kind:kind,control:$0.control,pairingLifetime:$0.pairingLifetime,publicationLifetime:self.envelope.binding.publicationLifetime!)},body)
        }
    }
    private func mutateOwned<T>(in db:RoutineDatabase,retiring:((T)throws->SyncDeliveryRetirement)?=nil,_ body:()throws->T)throws->T {
        lock.lock();defer {lock.unlock()}
        try requireCheckpoint(in:db)
        guard sqlite3_get_autocommit(db.handle) != 0,try db.eraseCount("PRAGMA synchronous")>=2 else {throw OSwindError.invalid("Anchor a prepared outer native transaction")}
        try Task.checkCancellation();try db.execute("BEGIN IMMEDIATE")
        var externalAttempted=false
        do {
            // Close the gap between the optimistic check and BEGIN IMMEDIATE.
            try requireCheckpoint(in:db)
            let before=sqlite3_total_changes64(db.handle)
            let value=try body();try Task.checkCancellation()
            let retirement=try retiring?(value)
            let retiredBinding:SyncEnrollmentBinding?
            if let retirement {
                guard envelope.retirement==nil else {throw OSwindError.invalid("Finish the existing retirement before another erase")}
                try retirement.validate(material:material);try retirement.requireLogicalCompletion(db)
                let binding=try SyncEnrollmentBinding.capture(store:library,material:material,id:id,protection:storage.protection,machine:machine,installation:SyncLocalCredentialState.installationID(at:stateRoot,create:false))
                guard binding.publicationLifetime==nil else {throw OSwindError.invalid("Retire the old publication lifetime in the native erasure transaction")}
                retiredBinding=binding
            }else {retiredBinding=nil}
            // Non-wire preparation/projection work must also carry a commit
            // stamp. Wire triggers already changed the token when applicable.
            var next=try Self.readToken(db,id:id,protection:storage.protection)
            if next==envelope.token,sqlite3_total_changes64(db.handle)>before {try db.execute(Self.advance);next=try Self.readToken(db,id:id,protection:storage.protection)}
            guard retirement==nil || next != envelope.token else {throw OSwindError.invalid("Native retirement must advance its external checkpoint")}
            if next != envelope.token {
                guard next.serial>envelope.token.serial else {throw OSwindError.invalid("Delivery checkpoint cannot move backwards")}
                let updated:Envelope
                if let retirement,let retiredBinding {updated=envelope.retiring(next,binding:retiredBinding,record:retirement)}else{updated=envelope.replacing(next)}
                let encoded=try updated.encoded()
                externalAttempted=true
                try storage.replace(id:id,expected:bytes,bytes:encoded)
                envelope=updated;bytes=encoded
            }
            // After the external boundary, cancellation is not rollback. Finish
            // the owned critical commit, then let the caller observe cancellation.
            try db.execute("COMMIT")
            if retirement != nil {library.nativeWriterAdmission.suspendForRetirement()}
            else {try library.nativeWriterAdmission.deliveryCommitted(db,verified:NativeWriterProof(id:id,protection:storage.protection,token:envelope.token,lifetime:envelope.binding.publicationLifetime!))}
            return value
        }catch {
            if externalAttempted {poisoned=true;library.nativeWriterAdmission.invalidate()}
            do {
                try db.execute("ROLLBACK")
                if !externalAttempted {try library.nativeWriterAdmission.deliveryRolledBack(db)}
            }catch {poisoned=true;library.nativeWriterAdmission.invalidate()}
            throw error
        }
    }
}

// Native preparation deliberately retains old private membership. Full
// handover/peer bootstrap is a later operation; safe cancellation is complete.
extension SyncDeliveryAnchor {
    private enum MembershipPhase {
        case before,prepared,cancelled,applied,legacyApplied
        var isApplied:Bool {self == .applied || self == .legacyApplied}
    }
    private static func membershipPhase(_ db:RoutineDatabase,library:MemoryStore,envelope:Envelope)throws->MembershipPhase {
        guard let record=envelope.membershipPreparation else {throw OSwindError.unavailable("No saved membership preparation")};try record.validate()
        let token=try readToken(db,id:envelope.id,protection:envelope.protection),epoch=try library.nativeWriterAdmission.membershipEpoch(db),version=try db.eraseCount("PRAGMA user_version")
        if version==record.nativeBefore,epoch==record.epochBefore,token==record.tokenBefore,envelope.token==record.tokenPrepared,record.disposition == .preparing {
            if version==36 {guard try SyncNativeMembershipState.read(db)==record.originalActive else {throw OSwindError.unavailable("Original membership changed before its fence")}}
            else {guard try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key IN ('\(SyncNativeMembershipState.phaseKey)','\(SyncNativeMembershipState.stateKey)')")==0 else {throw OSwindError.unavailable("Unexpected membership state before native36 preparation")}}
            return .before
        }
        guard version==36,epoch==record.epochPrepared else {throw OSwindError.unavailable("Native membership belongs to another writer generation")}
        let state=try SyncNativeMembershipState.read(db)
        if state == .prepared(record),token==record.tokenPrepared {
            let allowed:Bool
            switch record.disposition {
            case .preparing:allowed=envelope.token==record.tokenPrepared
            case .cancelling:allowed=envelope.token==record.tokenPrepared || envelope.token==record.tokenCancelled
            case .applying:let applied=try record.appliedToken();allowed=envelope.token==record.tokenPrepared || envelope.token==applied
            }
            if allowed {return .prepared}
        }
        if state == .active(record.headAfter,version:state.version),record.disposition == .applying,token==envelope.token,
           token == (try record.appliedToken()),envelope.membershipHead==record.headAfter,
           SyncProtocolLimits.hex(envelope.material)==record.materialAfter {
            if state.version==2 {return .applied}
            // An interrupted older handover may have committed format1 before
            // clearing its intent. Its saved fence still excludes old writers.
            if state.version==1,record.stateVersionBefore==nil {return .legacyApplied}
        }
        if state == record.originalActive,record.disposition == .cancelling,token==envelope.token,token==record.tokenCancelled,envelope.membershipHead==record.headBefore {return .cancelled}
        throw OSwindError.unavailable("Native state differs from the exact saved membership preparation")
    }
    private static func membershipProof(library:MemoryStore,material:SyncCredentialMaterial,record:SyncMembershipPreparation)throws->SyncMembershipRefresh {
        let joined=material.joined,inbox=try joined.openPrivateInbox(at:library.root.appendingPathComponent("images/device-sync-"+joined.replica));defer {inbox.close()}
        guard let bytes=try inbox.content(record.plan),record.plan.matches(bytes) else {throw OSwindError.unavailable("The saved encrypted membership proof is missing")}
        let proof=try SyncMembershipRefresh.decode(bytes);try record.require(proof,material:material);return proof
    }
    static func verifyMembershipPreparation(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment)throws {
        let (saved,material,_,_)=try readWriterAuthority(library:library,db:db,environment:environment,retiring:false,membershipRecovery:true)
        let record=saved.membershipPreparation!,proof=try membershipProof(library:library,material:material,record:record)
        let updated=try PersonalSyncPairing.verifyMembershipPreparation(library:library,db:db,environment:environment,record:record,proof:proof,deliveryID:saved.id)
        if try membershipPhase(db,library:library,envelope:saved).isApplied {guard updated else {throw OSwindError.unavailable("Applied native membership is missing its exact new pairing authority")}}
    }
    static func openMembershipPreparation(library:MemoryStore,environment:SyncNativeWriterEnvironment)throws->Self {
        let id=try library.withMembershipDatabase {db->String in
            let row=try db.statement("SELECT id FROM personal_sync_delivery_anchor WHERE singleton=1");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("Original membership delivery account is missing")};return db.text(row,0)
        }
        let lease=try SyncCredentialExclusiveLease(id:id,stateRoot:environment.stateRoot);var retained=false;defer {if !retained {lease.close()}}
        let result=try library.withMembershipDatabase {db->Self in
            try verifyMembershipPreparation(library:library,db:db,environment:environment)
            let (saved,material,storage,bytes)=try readWriterAuthority(library:library,db:db,environment:environment,retiring:false,membershipRecovery:true)
            guard saved.id==id else {throw OSwindError.unavailable("Membership account changed while opening")}
            return Self(library:library,database:db.handle,storage:storage,machine:environment.machine,stateRoot:environment.stateRoot,lease:lease,envelope:saved,bytes:bytes,material:material)
        }
        retained=true;return result
    }
    /// Explicit response recovery; normal status never exposes ciphertext.
    /// A pending, corrupt or missing latest receipt cannot become an older one.
    func completedOwnerResponse(inMembershipRecovery:Bool=false)throws->PersonalSyncApprovedResponse? {
        let read:(RoutineDatabase)throws->PersonalSyncApprovedResponse? = {db in
            self.lock.lock();defer {self.lock.unlock()};try self.available(db)
            guard try self.storage.read(id:self.id)==self.bytes,self.envelope.retirement==nil,self.envelope.membershipPreparation==nil,self.envelope.membershipFloor==nil else {throw OSwindError.unavailable("Finish the saved delivery operation before response recovery")}
            guard let reference=self.envelope.completedApproval else {return nil}
            try reference.validate()
            guard reference.publicationLifetime==self.envelope.binding.publicationLifetime else {throw OSwindError.invalid("Saved response belongs to another publication lifetime")}
            let current=try SyncCredentialMaterial.decodeFromKeychain(self.envelope.material)
            return try PersonalSyncPairing.deliveredApprovalResponse(library:self.library,db:db,environment:self.membershipEnvironment(),reference:reference,deliveryID:self.id,material:current)
        }
        return try inMembershipRecovery ? library.withMembershipDatabase(read):library.withRoutineDatabase(read)
    }
    static func hasCompletedApproval(library:MemoryStore,deliveryID:String,material:SyncCredentialMaterial,environment:SyncNativeWriterEnvironment)throws->Bool {
        try library.withRoutineDatabase {db in
            let (saved,current,_,_)=try readWriterAuthority(library:library,db:db,environment:environment,retiring:false)
            guard saved.id==deliveryID,try current.encodedForKeychain()==material.encodedForKeychain() else {throw OSwindError.unavailable("Response availability belongs to another owner")}
            return saved.completedApproval != nil
        }
    }
    var membershipPairingID:String? {lock.lock();defer {lock.unlock()};return envelope.membershipPreparation?.pairingID}
    private func membershipEnvironment()->SyncNativeWriterEnvironment {.init(stateRoot:stateRoot,machine:machine,storage:{[storage] _ in storage})}
    private func requireMembershipPreparation(_ db:RoutineDatabase)throws->(SyncMembershipPreparation,SyncMembershipRefresh,MembershipPhase) {
        try available(db);guard let record=envelope.membershipPreparation,try storage.read(id:id)==bytes else {throw OSwindError.unavailable("Saved membership authority changed or is unavailable")}
        let environment=membershipEnvironment();try Self.verifyMembershipPreparation(library:library,db:db,environment:environment)
        return (record,try Self.membershipProof(library:library,material:material,record:record),try Self.membershipPhase(db,library:library,envelope:envelope))
    }
    private static func saveMembershipToken(_ token:Token,db:RoutineDatabase)throws {
        try token.validate();let row=try db.statement("UPDATE personal_sync_delivery_anchor SET serial=?,nonce=? WHERE singleton=1");defer {sqlite3_finalize(row)}
        sqlite3_bind_int64(row,1,token.serial);db.bind(row,2,token.nonce);try db.done(row);guard sqlite3_changes(db.handle)==1 else {throw OSwindError.unavailable("Membership checkpoint disappeared")}
    }
    private func membershipNativePreparation(_ record:SyncMembershipPreparation,proof:SyncMembershipRefresh,db:RoutineDatabase)throws {
        try library.nativeWriterAdmission.prepareMembershipFence(db,record:record)
        try SyncMembershipHistory.retain(proof.certificates,anchoredHead:proof.base,db:db)
        try Self.saveMembershipToken(record.tokenPrepared,db:db)
    }
    func prepareMembership(_ proof:SyncMembershipRefresh,snapshot:PersonalSyncPairing.MembershipSnapshot,approvalPlan:SyncOwnerApprovalPlan?=nil,checkBeforeIntent:()throws->Void={})throws {
        try validate();let media=try library.mediaWriteLease();defer {media.release()}
        try library.withRoutineDatabase {db in
            lock.lock();defer {lock.unlock()};try requireCheckpoint(in:db)
            guard envelope.retirement==nil,envelope.membershipPreparation==nil,envelope.membershipFloor==nil,proof.base==material.joined.certificate,
                  snapshot.materialBefore==SyncProtocolLimits.hex(try material.encodedForKeychain()),
                  snapshot.materialAfter==SyncProtocolLimits.hex(try material.withMembershipRefresh(proof).encodedForKeychain()),
                  sqlite3_get_autocommit(db.handle) != 0,try db.eraseCount("PRAGMA synchronous")>=2,
                  try db.eraseCount("SELECT COUNT(*) FROM personal_sync_service_state WHERE token != ''")==0 else {throw OSwindError.invalid("Prepare the original enrolled membership outside other transactions")}
            try library.nativeWriterAdmission.withMembershipMutation(db) {
                try Task.checkCancellation();try db.execute("BEGIN IMMEDIATE");var externalAttempted=false
                do {
                    try requireCheckpoint(in:db)
                    let before=try Self.readToken(db,id:id,protection:storage.protection)
                    guard before.serial<Int64.max-2 else {throw OSwindError.unavailable("Membership checkpoint capacity exhausted")}
                    let planBytes=try proof.encoded(),plan=try SyncContentReference(data:planBytes),joined=material.joined
                    let inbox=try joined.openPrivateInbox(at:library.root.appendingPathComponent("images/device-sync-"+joined.replica));defer {inbox.close()};try inbox.publishContent(planBytes,reference:plan)
                    let approval:SyncDeliveryApprovalReference?
                    if let approvalPlan {
                        guard let lifetime=envelope.binding.publicationLifetime else {throw OSwindError.invalid("Approve only the original active publication lifetime")}
                        let saved=SyncDeliveryApprovalReference(approval:try approvalPlan.reference(),publicationLifetime:lifetime)
                        try saved.require(pairingID:snapshot.pairingID,head:SyncProtocolLimits.hex(try proof.head.encoded()),publicationLifetime:lifetime)
                        guard approvalPlan.binding.purpose == .addition,approvalPlan.prior==proof.base,approvalPlan.certificate==proof.head else {throw OSwindError.invalid("Approval differs from the exact signed membership proof")}
                        try inbox.publishContent(approvalPlan.encoded(),reference:saved.approval.content)
                        approval=saved
                    }else {approval=nil}
                    let nativeBefore=try db.eraseCount("PRAGMA user_version")
                    let originalFormat:Int?
                    if nativeBefore==36 {originalFormat=try SyncNativeMembershipState.read(db).version}else {originalFormat=nil}
                    let record=SyncMembershipPreparation(format:"OSwind.sync.membership-preparation",version:1,operation:UUID().uuidString.lowercased(),plan:plan,pairingID:snapshot.pairingID,pairingBefore:snapshot.pairingBefore,pairingAfter:snapshot.pairingAfter,materialBefore:snapshot.materialBefore,materialAfter:snapshot.materialAfter,headBefore:SyncProtocolLimits.hex(try proof.base.encoded()),headAfter:SyncProtocolLimits.hex(try proof.head.encoded()),nativeBefore:nativeBefore,epochBefore:try library.nativeWriterAdmission.membershipEpoch(db),epochPrepared:UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:""),tokenBefore:before,tokenPrepared:.init(serial:before.serial+1,nonce:UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:"")),disposition:.preparing,stateVersionBefore:originalFormat,approval:approval)
                    try record.require(proof,material:material)
                    try PersonalSyncPairing.verifyMembershipPreparation(library:library,db:db,environment:membershipEnvironment(),record:record,proof:proof,deliveryID:id)
                    try membershipNativePreparation(record,proof:proof,db:db)
                    let updated=envelope.preparing(record,token:record.tokenPrepared),encoded=try updated.encoded()
                    try Task.checkCancellation();try checkBeforeIntent();externalAttempted=true;try storage.replace(id:id,expected:bytes,bytes:encoded);envelope=updated;bytes=encoded
                    // Private membership remains old through this critical COMMIT.
                    try db.execute("COMMIT");library.nativeWriterAdmission.suspendForMembership()
                }catch {
                    if externalAttempted {poisoned=true;library.nativeWriterAdmission.invalidate()}
                    do {try db.execute("ROLLBACK");if !externalAttempted {try library.nativeWriterAdmission.deliveryRolledBack(db)}}catch {poisoned=true;library.nativeWriterAdmission.invalidate()}
                    throw error
                }
            }
        }
    }
    func validateMembershipPreparation()throws {
        let media=try MediaAdmissionLease.acquire(root:library.root,exclusive:false,expectedRoot:library.mediaRootIdentity);defer {media.release()}
        try library.withMembershipDatabase {db in lock.lock();defer {lock.unlock()};_=try requireMembershipPreparation(db)}
    }
    func continueMembershipFence()throws {
        let media=try MediaAdmissionLease.acquire(root:library.root,exclusive:false,expectedRoot:library.mediaRootIdentity);defer {media.release()}
        try library.withMembershipDatabase {db in
            lock.lock();defer {lock.unlock()};let (record,proof,phase)=try requireMembershipPreparation(db)
            guard phase == .before else {return}
            try library.nativeWriterAdmission.withMembershipMutation(db) {
                try Task.checkCancellation();try db.execute("BEGIN IMMEDIATE")
                do {
                    guard try requireMembershipPreparation(db).2 == .before else {throw OSwindError.unavailable("Membership fence changed before recovery")}
                    try membershipNativePreparation(record,proof:proof,db:db)
                    // The exact external token was saved by the interrupted
                    // preparation. No replacement credential is allocated.
                    try db.execute("COMMIT")
                }catch {try? db.execute("ROLLBACK");poisoned=true;library.nativeWriterAdmission.invalidate();throw error}
            }
        }
    }
    /// Safe only while both private accounts still hold the exact old material.
    /// Keep native36 and its new writer generation; never re-enable old clients.
    func cancelMembershipBeforeHandover()throws {
        try continueMembershipFence()
        let media=try MediaAdmissionLease.acquire(root:library.root,exclusive:false,expectedRoot:library.mediaRootIdentity);defer {media.release()}
        try library.withMembershipDatabase {db in
            lock.lock();defer {lock.unlock()};var (record,_,phase)=try requireMembershipPreparation(db)
            guard record.disposition != .applying else {throw OSwindError.unavailable("Finish the saved private membership handover; it cannot be cancelled")}
            if record.disposition == .preparing {
                try Task.checkCancellation();record=record.cancelling();let updated=envelope.preparing(record,token:envelope.token),encoded=try updated.encoded()
                do {try storage.replace(id:id,expected:bytes,bytes:encoded);envelope=updated;bytes=encoded}
                catch {poisoned=true;library.nativeWriterAdmission.invalidate();throw error}
            }
            if phase != .cancelled {
                try library.nativeWriterAdmission.withMembershipMutation(db) {
                    try db.execute("BEGIN IMMEDIATE")
                    do {
                        (record,_,phase)=try requireMembershipPreparation(db)
                        guard phase == .prepared,record.disposition == .cancelling else {throw OSwindError.unavailable("Cancel only the exact committed membership fence")}
                        // This cancellation changes only fixed metadata, not
                        // wire history. Replay its exact already-saved target
                        // rather than consume another serial after COMMIT loss.
                        let next=record.tokenCancelled
                        try SyncNativeMembershipState.write(record.originalActive,db);try Self.saveMembershipToken(next,db:db)
                        let updated=envelope.preparing(record,token:next,head:record.headBefore),encoded=try updated.encoded()
                        if encoded != bytes {try storage.replace(id:id,expected:bytes,bytes:encoded)};envelope=updated;bytes=encoded
                        try db.execute("COMMIT")
                    }catch {try? db.execute("ROLLBACK");poisoned=true;library.nativeWriterAdmission.invalidate();throw error}
                }
            }
            let updated=envelope.clearingPreparation(),encoded=try updated.encoded()
            do {try storage.replace(id:id,expected:bytes,bytes:encoded);envelope=updated;bytes=encoded}
            catch {poisoned=true;library.nativeWriterAdmission.invalidate();throw error}
            // This restricted connection stays quarantined until it closes.
        }
    }
}

extension SyncDeliveryAnchor {
    /// Apply only the existing saved proof, never replacement UI text. The
    /// caller joins this entire operation and owns both original account leases.
    func applyMembershipAfterFence(requirePairingLease:()throws->Void)throws {
        try continueMembershipFence()
        let media=try MediaAdmissionLease.acquire(root:library.root,exclusive:false,expectedRoot:library.mediaRootIdentity);defer {media.release()}
        try library.withMembershipDatabase {db in
            lock.lock();defer {lock.unlock()};try requirePairingLease()
            var (record,proof,phase)=try requireMembershipPreparation(db)
            guard record.disposition != .cancelling else {throw OSwindError.unavailable("Finish the saved membership cancellation first")}
            if record.disposition == .preparing {
                try Task.checkCancellation();record=try record.applying(proof.head.body.members.count-proof.base.body.members.count)
                let updated=envelope.preparing(record,token:envelope.token),encoded=try updated.encoded()
                do {try storage.replace(id:id,expected:bytes,bytes:encoded);envelope=updated;bytes=encoded}
                catch {poisoned=true;library.nativeWriterAdmission.invalidate();throw error}
            }
            if !phase.isApplied {
                do {
                    try requirePairingLease()
                    try PersonalSyncPairing.completeMembershipPreparation(library:library,db:db,environment:membershipEnvironment(),record:record,proof:proof,deliveryID:id)
                    try library.nativeWriterAdmission.withMembershipMutation(db) {
                        try db.execute("BEGIN IMMEDIATE")
                        do {
                            (record,proof,phase)=try requireMembershipPreparation(db);try requirePairingLease()
                            guard phase == .prepared,record.disposition == .applying,
                                  try PersonalSyncPairing.verifyMembershipPreparation(library:library,db:db,environment:membershipEnvironment(),record:record,proof:proof,deliveryID:id) else {throw OSwindError.unavailable("Apply only the exact saved forward private membership")}
                            let candidates=try material.membershipCandidates(proof),before=candidates.before.joined,after=candidates.after.joined
                            let known=Set(before.certificate.body.members.map(\.replica)),added=after.certificate.body.members.map(\.replica).filter {!known.contains($0)}
                            guard added.count==record.additions else {throw OSwindError.invalid("Native peer additions differ from the saved proof")}
                            let journal=try SyncJournal(database:db,replica:before.replica,group:before.certificate.body.group,epoch:before.certificate.body.epoch)
                            for peer in added.sorted() {try journal.allowPeer(peer)}
                            let current=try Self.readToken(db,id:id,protection:storage.protection),target=try record.appliedToken()
                            guard current.serial==record.tokenPrepared.serial+Int64(added.count),target.serial==current.serial+1 else {throw OSwindError.unavailable("Unexpected native wire changes during membership application")}
                            let sent=Int64(try db.eraseCount("SELECT sent FROM personal_sync_service_state WHERE singleton=1"))
                            try SyncNativeMembershipState.write(.active(record.headAfter,version:2),db)
                            try SyncMembershipReplay.seed(head:record.headAfter,through:sent,db:db)
                            try Self.saveMembershipToken(target,db:db)
                            let updated=envelope.applying(record,material:try candidates.after.encodedForKeychain(),token:target),encoded=try updated.encoded()
                            if encoded != bytes {try storage.replace(id:id,expected:bytes,bytes:encoded)};envelope=updated;bytes=encoded
                            try db.execute("COMMIT")
                        }catch {try? db.execute("ROLLBACK");throw error}
                    }
                }catch {poisoned=true;library.nativeWriterAdmission.invalidate();throw error}
            }
            try requirePairingLease();(record,proof,phase)=try requireMembershipPreparation(db)
            if phase == .legacyApplied {
                // The old still-pending operation already owns the rotated
                // writer generation and exact final token. Upgrade only its
                // local format, without reauthoring peers or consuming tokens.
                do {try library.nativeWriterAdmission.withMembershipMutation(db) {
                    try db.execute("BEGIN IMMEDIATE")
                    do {
                        (record,proof,phase)=try requireMembershipPreparation(db);try requirePairingLease()
                        guard phase == .legacyApplied else {throw OSwindError.unavailable("The exact legacy application changed before its format upgrade")}
                        try SyncNativeMembershipState.write(.active(record.headAfter,version:2),db)
                        try db.execute("COMMIT")
                    }catch {try? db.execute("ROLLBACK");throw error}
                }}catch {poisoned=true;library.nativeWriterAdmission.invalidate();throw error}
            }
            guard try requireMembershipPreparation(db).2 == .applied else {throw OSwindError.unavailable("Commit the replay-capable membership floor before clearing its operation")}
            let updated=envelope.clearingPreparation(),encoded=try updated.encoded()
            do {try storage.replace(id:id,expected:bytes,bytes:encoded);envelope=updated;bytes=encoded}
            catch {poisoned=true;library.nativeWriterAdmission.invalidate();throw error}
            // A fresh normal store/session verifies the new floor after close.
        }
    }
}

// A local format migration is not a signed membership change. Its own pending
// record and restricted connection preserve already-cleared preview history.
extension SyncDeliveryAnchor {
    private enum MembershipFloorPhase {case before,completed}
    private static func membershipFloorPhase(_ db:RoutineDatabase,library:MemoryStore,envelope:Envelope)throws->MembershipFloorPhase {
        guard let record=envelope.membershipFloor,try db.eraseCount("PRAGMA user_version")==36 else {throw OSwindError.unavailable("Resume the saved native36 membership floor upgrade")}
        try record.validate()
        let token=try readToken(db,id:envelope.id,protection:envelope.protection),epoch=try library.nativeWriterAdmission.membershipEpoch(db),state=try SyncNativeMembershipState.read(db)
        guard envelope.token==record.tokenAfter,envelope.membershipHead==record.head else {throw OSwindError.unavailable("The floor operation changed its exact target")}
        if token==record.tokenBefore,epoch==record.epochBefore,state == .active(record.head,version:1) {return .before}
        if token==record.tokenAfter,epoch==record.epochAfter,state == .active(record.head,version:2) {return .completed}
        throw OSwindError.unavailable("Native history differs from both exact floor checkpoints")
    }
    static func verifyMembershipFloorPreparation(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment)throws {
        _=try readWriterAuthority(library:library,db:db,environment:environment,retiring:false,floorRecovery:true)
    }
    static func openMembershipFloorPreparation(library:MemoryStore,environment:SyncNativeWriterEnvironment)throws->Self {
        let id=try library.withMembershipFloorDatabase {db->String in
            let row=try db.statement("SELECT id FROM personal_sync_delivery_anchor WHERE singleton=1");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("Original floor delivery account is missing")};return db.text(row,0)
        }
        let lease=try SyncCredentialExclusiveLease(id:id,stateRoot:environment.stateRoot);var retained=false;defer {if !retained {lease.close()}}
        let result=try library.withMembershipFloorDatabase {db->Self in
            let (saved,material,storage,bytes)=try readWriterAuthority(library:library,db:db,environment:environment,retiring:false,floorRecovery:true)
            guard saved.id==id else {throw OSwindError.unavailable("Floor account changed while opening")}
            return Self(library:library,database:db.handle,storage:storage,machine:environment.machine,stateRoot:environment.stateRoot,lease:lease,envelope:saved,bytes:bytes,material:material)
        }
        retained=true;return result
    }
    var membershipFloorPairingID:String? {lock.lock();defer {lock.unlock()};return envelope.membershipFloor?.pairingID}
    private func requireMembershipFloor(_ db:RoutineDatabase)throws->MembershipFloorPhase {
        try available(db)
        guard envelope.membershipFloor != nil,try storage.read(id:id)==bytes else {throw OSwindError.unavailable("Saved membership floor authority changed")}
        try Self.verifyMembershipFloorPreparation(library:library,db:db,environment:membershipEnvironment())
        return try Self.membershipFloorPhase(db,library:library,envelope:envelope)
    }
    func validateMembershipFloorPreparation()throws {
        try library.withMembershipFloorDatabase {db in lock.lock();defer {lock.unlock()};_=try requireMembershipFloor(db)}
    }
    /// On true the transferred store is quarantined even after a successful
    /// native COMMIT. A fresh admitted store is required after pending clear.
    func prepareMembershipFloor(snapshot:PersonalSyncPairing.MembershipFloorSnapshot,checkBeforeIntent:()throws->Void)throws->Bool {
        try validate();let media=try library.mediaWriteLease();defer {media.release()}
        return try library.withRoutineDatabase {db in
            lock.lock();defer {lock.unlock()};try requireCheckpoint(in:db)
            guard envelope.retirement==nil,envelope.membershipPreparation==nil,envelope.membershipFloor==nil,
                  envelope.membershipHead==snapshot.head,SyncProtocolLimits.hex(envelope.material)==snapshot.materialDigest,
                  sqlite3_get_autocommit(db.handle) != 0,try db.eraseCount("PRAGMA user_version")==36,
                  try db.eraseCount("SELECT COUNT(*) FROM personal_sync_service_state WHERE token != ''")==0 else {throw OSwindError.unavailable("Upgrade the original stopped native36 library")}
            let state=try SyncNativeMembershipState.read(db)
            guard state == .active(snapshot.head,version:state.version) else {throw OSwindError.unavailable("Complete the saved membership operation before its format upgrade")}
            if state.version==2 {return false}
            try db.execute("PRAGMA synchronous=FULL")
            return try library.nativeWriterAdmission.withMembershipMutation(db) {
                try checkBeforeIntent();try db.execute("BEGIN IMMEDIATE");var externalAttempted=false
                do {
                    try requireCheckpoint(in:db)
                    guard try storage.read(id:id)==bytes else {throw SyncCredentialStorageError.changed}
                    let before=try Self.readToken(db,id:id,protection:storage.protection)
                    guard before.serial<Int64.max-1 else {throw OSwindError.unavailable("Membership floor checkpoint capacity exhausted")}
                    let record=SyncMembershipFloorPreparation(format:"OSwind.sync.membership-floor",version:1,operation:UUID().uuidString.lowercased(),pairingID:snapshot.pairingID,pairingDigest:snapshot.pairingDigest,materialDigest:snapshot.materialDigest,head:snapshot.head,epochBefore:try library.nativeWriterAdmission.membershipEpoch(db),epochAfter:UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:""),tokenBefore:before,tokenAfter:.init(serial:before.serial+1,nonce:UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:"")))
                    try PersonalSyncPairing.verifyMembershipFloor(library:library,db:db,environment:membershipEnvironment(),record:record,deliveryID:id,material:envelope.material)
                    try library.nativeWriterAdmission.prepareMembershipFloorFence(db,record:record)
                    try Self.saveMembershipToken(record.tokenAfter,db:db)
                    let updated=envelope.upgradingFloor(record),encoded=try updated.encoded()
                    try checkBeforeIntent();externalAttempted=true;try storage.replace(id:id,expected:bytes,bytes:encoded);envelope=updated;bytes=encoded
                    try db.execute("COMMIT");library.nativeWriterAdmission.suspendForMembershipFloor();return true
                }catch {
                    if externalAttempted {poisoned=true;library.nativeWriterAdmission.invalidate()}
                    do {try db.execute("ROLLBACK");if !externalAttempted {try library.nativeWriterAdmission.deliveryRolledBack(db)}}catch {poisoned=true;library.nativeWriterAdmission.invalidate()}
                    throw error
                }
            }
        }
    }
    /// After durable intent the only decision is forward to the exact saved
    /// token/generation. Cancellation cannot abandon that native/private gap.
    func completeMembershipFloor(requirePairingLease:()throws->Void)throws {
        let media=try MediaAdmissionLease.acquire(root:library.root,exclusive:false,expectedRoot:library.mediaRootIdentity);defer {media.release()}
        try library.withMembershipFloorDatabase {db in
            lock.lock();defer {lock.unlock()};try requirePairingLease()
            let phase=try requireMembershipFloor(db),record=envelope.membershipFloor!
            if phase == .before {
                do {try library.nativeWriterAdmission.withMembershipMutation(db) {
                    try db.execute("BEGIN IMMEDIATE")
                    do {
                        try requirePairingLease()
                        guard try requireMembershipFloor(db) == .before else {throw OSwindError.unavailable("The saved floor checkpoint changed before recovery")}
                        try library.nativeWriterAdmission.prepareMembershipFloorFence(db,record:record)
                        try Self.saveMembershipToken(record.tokenAfter,db:db)
                        try db.execute("COMMIT")
                    }catch {try? db.execute("ROLLBACK");throw error}
                }}catch {poisoned=true;library.nativeWriterAdmission.invalidate();throw error}
            }
            try requirePairingLease()
            guard try requireMembershipFloor(db) == .completed else {throw OSwindError.unavailable("Commit the exact native floor before clearing recovery")}
            let updated=envelope.upgradingFloor(nil),encoded=try updated.encoded()
            do {try storage.replace(id:id,expected:bytes,bytes:encoded);envelope=updated;bytes=encoded}
            catch {poisoned=true;library.nativeWriterAdmission.invalidate();throw error}
        }
    }
}
