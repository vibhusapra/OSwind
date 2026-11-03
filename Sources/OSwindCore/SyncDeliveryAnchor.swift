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
        init(format:String,version:Int,id:String,protection:SyncCredentialProtection,binding:SyncEnrollmentBinding,material:Data,token:Token,retirement:SyncDeliveryRetirement?,membershipHead:String?=nil,membershipPreparation:SyncMembershipPreparation?=nil) {
            self.format=format;self.version=version;self.id=id;self.protection=protection;self.binding=binding;self.material=material;self.token=token;self.retirement=retirement;self.membershipHead=membershipHead;self.membershipPreparation=membershipPreparation
        }
        func replacing(_ next:Token)->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:next,retirement:retirement,membershipHead:membershipHead,membershipPreparation:membershipPreparation)}
        func retiring(_ next:Token,binding:SyncEnrollmentBinding,record:SyncDeliveryRetirement)->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:next,retirement:record,membershipHead:membershipHead,membershipPreparation:membershipPreparation)}
        func activating(_ next:Token,binding:SyncEnrollmentBinding)->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:next,retirement:nil,membershipHead:membershipHead,membershipPreparation:membershipPreparation)}
        func preparing(_ record:SyncMembershipPreparation,token:Token,head:String?=nil)->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:token,retirement:retirement,membershipHead:head ?? membershipHead,membershipPreparation:record)}
        func clearingPreparation()->Self {.init(format:format,version:version,id:id,protection:protection,binding:binding,material:material,token:token,retirement:retirement,membershipHead:membershipHead,membershipPreparation:nil)}
        func encoded()throws->Data {try token.validate();let bytes=try SyncProtocolLimits.encode(self);try SyncCredentialStorageLimits.validate(id:id,bytes:bytes);return bytes}
        static func decode(_ bytes:Data)throws->Self {
            let value=try SyncPairingFormat.decode(Self.self,bytes,limit:SyncCredentialStorageLimits.maximumBytes)
            guard value.format=="OSwind.sync.delivery-anchor",value.version==1,value.id==value.binding.id,value.protection==value.binding.protection,(value.binding.publicationLifetime==nil)==(value.retirement != nil) else {throw OSwindError.invalid("Invalid saved delivery authority")}
            try value.token.validate();try value.binding.validate();let material=try SyncCredentialMaterial.decodeFromKeychain(value.material);try value.retirement?.validate(material:material)
            if let head=value.membershipHead {try SyncProtocolLimits.digest(head);guard head==SyncProtocolLimits.hex(try material.joined.certificate.encoded()) else {throw OSwindError.invalid("Membership floor differs from its private certificate")}}
            if let record=value.membershipPreparation {
                try record.validate()
                guard value.retirement==nil,SyncProtocolLimits.hex(try material.encodedForKeychain())==record.materialBefore,SyncProtocolLimits.hex(try material.joined.certificate.encoded())==record.headBefore else {throw OSwindError.invalid("Prepared membership no longer retains its original private authority")}
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
    private static func readWriterAuthority(library:MemoryStore,db:RoutineDatabase,environment:SyncNativeWriterEnvironment,retiring:Bool,membershipRecovery:Bool=false)throws->(Envelope,SyncCredentialMaterial,any SyncCredentialStorage,Data) {
        let row=try db.statement("SELECT id,protection FROM personal_sync_delivery_anchor WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,let protection=SyncCredentialProtection(rawValue:db.text(row,1)) else {throw OSwindError.unavailable("Native delivery authority is missing; export with backup recover")}
        let id=db.text(row,0),storage=environment.storage(protection)
        guard storage.protection==protection else {throw OSwindError.invalid("Keep the enrolled credential protection tier")}
        let bytes=try storage.read(id:id),envelope=try Envelope.decode(bytes),material=try SyncCredentialMaterial.decodeFromKeychain(envelope.material)
        guard (envelope.retirement != nil)==retiring else {throw OSwindError.unavailable("Use the matching active or retirement recovery owner for this native history")}
        guard envelope.id==id,envelope.protection==protection,(envelope.membershipPreparation != nil)==membershipRecovery else {throw OSwindError.unavailable("Resume the exact saved membership operation before ordinary access")}
        if membershipRecovery {_=try membershipPhase(db,library:library,envelope:envelope)}
        else {
            guard try readToken(db,id:id,protection:protection)==envelope.token else {throw OSwindError.unavailable("Native history differs from its external checkpoint; export with backup recover")}
            try SyncNativeMembershipState.requireActive(db,certificate:material.joined.certificate,floor:envelope.membershipHead)
        }
        try requireSchema(db)
        let identity=try db.statement("SELECT replica,group_id,epoch FROM personal_sync_local WHERE singleton=1");defer {sqlite3_finalize(identity)}
        let joined=material.joined
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
        guard envelope.membershipPreparation==nil else {throw OSwindError.unavailable("Finish the saved membership operation before delivery")}
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
    private enum MembershipPhase {case before,prepared,cancelled}
    private static func membershipPhase(_ db:RoutineDatabase,library:MemoryStore,envelope:Envelope)throws->MembershipPhase {
        guard let record=envelope.membershipPreparation else {throw OSwindError.unavailable("No saved membership preparation")};try record.validate()
        let token=try readToken(db,id:envelope.id,protection:envelope.protection),epoch=try library.nativeWriterAdmission.membershipEpoch(db),version=try db.eraseCount("PRAGMA user_version")
        if version==record.nativeBefore,epoch==record.epochBefore,token==record.tokenBefore,envelope.token==record.tokenPrepared,record.disposition == .preparing {
            if version==36 {guard try SyncNativeMembershipState.read(db)==SyncNativeMembershipState.Value.active(record.headBefore) else {throw OSwindError.unavailable("Original membership changed before its fence")}}
            else {guard try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key IN ('\(SyncNativeMembershipState.phaseKey)','\(SyncNativeMembershipState.stateKey)')")==0 else {throw OSwindError.unavailable("Unexpected membership state before native36 preparation")}}
            return .before
        }
        guard version==36,epoch==record.epochPrepared else {throw OSwindError.unavailable("Native membership belongs to another writer generation")}
        let state=try SyncNativeMembershipState.read(db)
        if state == .prepared(record),token==record.tokenPrepared,
           envelope.token==record.tokenPrepared || (record.disposition == .cancelling && envelope.token==record.tokenCancelled) {return .prepared}
        if state == .active(record.headBefore),record.disposition == .cancelling,token==envelope.token,token==record.tokenCancelled,envelope.membershipHead==record.headBefore {return .cancelled}
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
        try PersonalSyncPairing.verifyMembershipPreparation(library:library,db:db,environment:environment,record:record,proof:proof,deliveryID:saved.id)
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
    func prepareMembership(_ proof:SyncMembershipRefresh,snapshot:PersonalSyncPairing.MembershipSnapshot)throws {
        try validate();let media=try library.mediaWriteLease();defer {media.release()}
        try library.withRoutineDatabase {db in
            lock.lock();defer {lock.unlock()};try requireCheckpoint(in:db)
            guard envelope.retirement==nil,envelope.membershipPreparation==nil,proof.base==material.joined.certificate,
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
                    let record=SyncMembershipPreparation(format:"OSwind.sync.membership-preparation",version:1,operation:UUID().uuidString.lowercased(),plan:plan,pairingID:snapshot.pairingID,pairingBefore:snapshot.pairingBefore,pairingAfter:snapshot.pairingAfter,materialBefore:snapshot.materialBefore,materialAfter:snapshot.materialAfter,headBefore:SyncProtocolLimits.hex(try proof.base.encoded()),headAfter:SyncProtocolLimits.hex(try proof.head.encoded()),nativeBefore:try db.eraseCount("PRAGMA user_version"),epochBefore:try library.nativeWriterAdmission.membershipEpoch(db),epochPrepared:UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:""),tokenBefore:before,tokenPrepared:.init(serial:before.serial+1,nonce:UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:"")),disposition:.preparing)
                    try record.require(proof,material:material)
                    try PersonalSyncPairing.verifyMembershipPreparation(library:library,db:db,environment:membershipEnvironment(),record:record,proof:proof,deliveryID:id)
                    try membershipNativePreparation(record,proof:proof,db:db)
                    let updated=envelope.preparing(record,token:record.tokenPrepared),encoded=try updated.encoded()
                    try Task.checkCancellation();externalAttempted=true;try storage.replace(id:id,expected:bytes,bytes:encoded);envelope=updated;bytes=encoded
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
                        try SyncNativeMembershipState.write(.active(record.headBefore),db);try Self.saveMembershipToken(next,db:db)
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
