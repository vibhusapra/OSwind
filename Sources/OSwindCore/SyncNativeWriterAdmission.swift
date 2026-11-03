import Foundation
import CSQLite

/// Ordinary native writers share verified admission, not the delivery owner's
/// exclusive credential mutation lease. No proof retains a MemoryStore.
struct SyncNativeWriterEnvironment:Sendable {
    let stateRoot:URL
    let machine:any SyncMachineFingerprint
    let storage:(@Sendable (SyncCredentialProtection)->any SyncCredentialStorage)
    static var native:Self {.init(stateRoot:SyncLocalCredentialState.root,machine:MacSyncMachineFingerprint(),storage:{SyncKeychainCredentialStorage(protection:$0)})}
}

/// A cheap connection-local SQL capability. Old already-open clients have no
/// function; new clients opened before enrollment have a false capability.
/// Either fails at the persistent BEFORE triggers when the schema refreshes.
final class SyncNativeWriterAdmission {
    static let enrolledSchemaVersion=35
    static let membershipSchemaVersion=36
    private let epoch=SyncNativeWriterEpoch()
    private let lock=NSLock()
    private var allowed=false
    private var enrolled=false
    private var retirementGranted=false,membershipGranted=false
    private var floorPending=false
    var membershipFloorQuarantined:Bool {floorPending && !poisoned}
    private var membershipPending=false
    var membershipQuarantined:Bool {membershipPending && !poisoned}
    private var proof:SyncDeliveryAnchor.NativeWriterProof?
    private var environment:SyncNativeWriterEnvironment?
    private var checking=false, trustedDepth=0
    private var schemaCookie:Int?
    private var initialized=false
    private var poisoned=false
    private var retiring=false
    var retirementQuarantined:Bool {retiring && !poisoned}
    var requiresOwnedErasure:Bool {lock.lock();defer {lock.unlock()};return enrolled}
    private func markEnrolled() {lock.lock();enrolled=true;lock.unlock()}
    func register(_ db:RoutineDatabase)throws {
        try epoch.register(db)
        let membership=Unmanaged.passRetained(self).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_native_sync_membership_v1",0,SQLITE_UTF8|SQLITE_INNOCUOUS,membership,{context,_,_ in
            guard let context,let pointer=sqlite3_user_data(context) else {return}
            let owner=Unmanaged<SyncNativeWriterAdmission>.fromOpaque(pointer).takeUnretainedValue()
            owner.lock.lock();let permitted=owner.membershipGranted;owner.lock.unlock();sqlite3_result_int(context,permitted ? 1:0)
        },nil,nil,{if let p=$0 {Unmanaged<SyncNativeWriterAdmission>.fromOpaque(p).release()}})==SQLITE_OK else {throw db.error()}
        let retirement=Unmanaged.passRetained(self).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_native_sync_retirement_v1",0,SQLITE_UTF8|SQLITE_INNOCUOUS,retirement,{context,_,_ in
            guard let context,let pointer=sqlite3_user_data(context) else {return}
            let owner=Unmanaged<SyncNativeWriterAdmission>.fromOpaque(pointer).takeUnretainedValue()
            owner.lock.lock();let permitted=owner.retirementGranted;owner.lock.unlock();sqlite3_result_int(context,permitted ? 1:0)
        },nil,nil,{if let p=$0 {Unmanaged<SyncNativeWriterAdmission>.fromOpaque(p).release()}})==SQLITE_OK else {throw db.error()}
        let pointer=Unmanaged.passRetained(self).toOpaque()
        guard sqlite3_create_function_v2(db.handle,"oswind_native_sync_writer_v1",0,SQLITE_UTF8|SQLITE_INNOCUOUS,pointer,{context,_,_ in
            guard let context,let pointer=sqlite3_user_data(context) else {return}
            let owner=Unmanaged<SyncNativeWriterAdmission>.fromOpaque(pointer).takeUnretainedValue()
            owner.lock.lock();let value=owner.allowed;owner.lock.unlock()
            sqlite3_result_int(context,value ? 1:0)
        },nil,nil,{if let pointer=$0 {Unmanaged<SyncNativeWriterAdmission>.fromOpaque(pointer).release()}})==SQLITE_OK else {throw db.error()}
    }
    private func permit(_ value:Bool) {lock.lock();allowed=value;lock.unlock()}
    func open(_ db:RoutineDatabase,library:MemoryStore,environment:SyncNativeWriterEnvironment)throws {
        checking=true;defer {checking=false}
        initialized=true
        let version=try db.eraseCount("PRAGMA user_version")
        guard version>=34 else {
            if version>=33 {try SyncChangeCapture.transaction(db) {try PersonalSyncPairing.requirePreFenceDeliveryAdmission(library:library,db:db,environment:environment)}}
            return
        }
        self.environment=environment;markEnrolled()
        do {
            proof=try SyncChangeCapture.transaction(db) {
                let verified=try SyncDeliveryAnchor.nativeWriterProof(library:library,db:db,environment:environment)
                if version==34 {try self.installGuards(db,replacingLegacy:true)}
                else {try Self.requireGuards(db);try self.epoch.validate(db);try self.epoch.adopt(db)}
                return verified
            }
            schemaCookie=try db.eraseCount("PRAGMA schema_version")
            permit(true)
        }catch {permit(false);throw error}
    }
    func require(_ db:RoutineDatabase,library:MemoryStore)throws {
        guard initialized,!checking,trustedDepth==0 else {return}
        guard !poisoned else {throw OSwindError.unavailable("Native delivery admission needs recovery after an ambiguous checkpoint commit")}
        guard !floorPending else {throw OSwindError.unavailable("Finish the saved membership floor upgrade before ordinary native access")}
        guard !membershipPending else {throw OSwindError.unavailable("Finish the saved membership operation before ordinary native access")}
        guard !retiring else {throw OSwindError.unavailable("Native history was erased. Finish owned sync cleanup before reopening normal access.")}
        checking=true;defer {checking=false}
        guard let environment,let proof else {
            // Do not upgrade an already-open pre-enrollment connection into an
            // admitted writer. The owner explicitly admits its own connection.
            guard try db.eraseCount("PRAGMA user_version") < 34 else {throw OSwindError.unavailable("Device sync changed this library. Reopen it to verify native writer admission, or export with backup recover.")}
            return
        }
        do {
            try epoch.requireCurrent(db)
            let cookie=try db.eraseCount("PRAGMA schema_version")
            if cookie != schemaCookie {try Self.requireGuards(db);try epoch.validate(db);schemaCookie=cookie}
            if try !proof.matches(db) {
                // Serialize checkpoint refresh with another process's native
                // commit. It saves its external token before SQLite COMMIT.
                self.proof=try SyncChangeCapture.transaction(db) {
                    try SyncDeliveryAnchor.nativeWriterProof(library:library,db:db,environment:environment)
                }
            }
            permit(true)
        }catch {permit(false);throw error}
    }
    func openRetirement(_ db:RoutineDatabase,library:MemoryStore,environment:SyncNativeWriterEnvironment)throws {
        checking=true;defer {checking=false};initialized=true
        guard [Self.enrolledSchemaVersion,Self.membershipSchemaVersion].contains(try db.eraseCount("PRAGMA user_version")) else {throw OSwindError.invalid("Recover retirement from its current enrolled native schema")}
        try SyncChangeCapture.transaction(db) {
            try NativeMediaSchema.validate(db)
            try SyncDeliveryAnchor.verifyRetirement(library:library,db:db,environment:environment)
            try Self.requireGuards(db);try epoch.validate(db);try epoch.adopt(db)
        }
        self.environment=environment;markEnrolled();retiring=true;permit(false)
    }
    func withRetirementCleanup<T>(_ db:RoutineDatabase,_ body:()throws->T)throws->T {
        guard retirementQuarantined,environment != nil else {throw OSwindError.invalid("Use the verified quarantined retirement owner")}
        try Self.requireGuards(db);try epoch.validate(db);try NativeMediaSchema.validate(db)
        try epoch.requireCurrent(db)
        trustedDepth+=1;permit(true)
        defer {trustedDepth-=1;permit(!retiring && !poisoned)}
        return try body()
    }
    func activateAfterRetirement(_ db:RoutineDatabase,verified:SyncDeliveryAnchor.NativeWriterProof)throws {
        guard retirementQuarantined,trustedDepth>0 else {throw OSwindError.invalid("Renew through the owned retirement scope")}
        do {try deliveryCommitted(db,verified:verified);retiring=false}
        catch {invalidate();throw error}
    }
    func install(_ db:RoutineDatabase,library:MemoryStore,environment:SyncNativeWriterEnvironment)throws {
        guard sqlite3_get_autocommit(db.handle) != 0 else {throw OSwindError.invalid("Install native admission outside a transaction")}
        checking=true;defer {checking=false}
        do {
            let verified=try SyncDeliveryAnchor.nativeWriterProof(library:library,db:db,environment:environment)
            permit(true)
            try SyncChangeCapture.transaction(db) {
                guard try verified.matches(db) else {throw OSwindError.unavailable("Delivery checkpoint changed during native enrollment")}
                let version=try db.eraseCount("PRAGMA user_version")
                if [Self.enrolledSchemaVersion,Self.membershipSchemaVersion].contains(version) {try Self.requireGuards(db);try epoch.validate(db);try epoch.adopt(db)}
                else {try installGuards(db,replacingLegacy:version==34)}
            }
            self.environment=environment;markEnrolled();proof=verified;initialized=true
            schemaCookie=try db.eraseCount("PRAGMA schema_version")
        }catch {permit(false);throw error}
    }
    private func installGuards(_ db:RoutineDatabase,replacingLegacy:Bool)throws {
        if replacingLegacy {
            try Self.requireGuards(db,legacy:true)
            for name in try Self.guards(db,legacy:true).keys {try db.execute("DROP TRIGGER \(name)")}
        }else {
            guard try db.eraseCount("PRAGMA user_version")==33 else {throw OSwindError.invalid("Enroll a current native content library")}
        }
        try epoch.install(db)
        for (name,sql) in try Self.guards(db).sorted(by:{$0.key<$1.key}) {
            guard try db.eraseCount("SELECT COUNT(*) FROM sqlite_master WHERE name='\(name)'")==0 else {throw OSwindError.invalid("Native writer guard already exists")}
            try db.execute(sql)
        }
        try db.execute("PRAGMA user_version=\(Self.enrolledSchemaVersion)")
    }
    func membershipEpoch(_ db:RoutineDatabase)throws->String {try epoch.read(db)}
    func openMembershipRecovery(_ db:RoutineDatabase,library:MemoryStore,environment:SyncNativeWriterEnvironment)throws {
        checking=true;defer {checking=false};initialized=true
        try SyncChangeCapture.transaction(db) {
            try NativeMediaSchema.validate(db)
            try SyncDeliveryAnchor.verifyMembershipPreparation(library:library,db:db,environment:environment)
            try Self.requireGuards(db);try epoch.validate(db);try epoch.adopt(db)
        }
        self.environment=environment;markEnrolled();membershipPending=true;permit(false)
    }
    func withMembershipMutation<T>(_ db:RoutineDatabase,_ body:()throws->T)throws->T {
        guard environment != nil,!poisoned,!retiring else {throw OSwindError.invalid("Use the original enrolled membership operation owner")}
        try Self.requireGuards(db);try epoch.validate(db);try epoch.requireCurrent(db)
        trustedDepth+=1;lock.lock();membershipGranted=true;allowed=true;lock.unlock()
        defer {trustedDepth-=1;lock.lock();membershipGranted=false;allowed = !membershipPending && !floorPending && !poisoned;lock.unlock()}
        return try body()
    }
    func prepareMembershipFence(_ db:RoutineDatabase,record:SyncMembershipPreparation)throws {
        lock.lock();let granted=membershipGranted;lock.unlock()
        guard granted,trustedDepth>0,environment != nil,!poisoned,sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Prepare membership in its owned transaction")}
        try record.validate();let version=try db.eraseCount("PRAGMA user_version")
        guard version==record.nativeBefore,try epoch.read(db)==record.epochBefore else {throw OSwindError.unavailable("Membership preparation no longer matches its original writer")}
        try Self.requireGuards(db)
        if version==Self.membershipSchemaVersion {guard try SyncNativeMembershipState.read(db)==record.originalActive else {throw OSwindError.unavailable("Native membership changed before preparation")}}
        else {
            guard try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key IN ('\(SyncNativeMembershipState.phaseKey)','\(SyncNativeMembershipState.stateKey)')")==0 else {throw OSwindError.unavailable("Unexpected membership state in the original native35 library")}
            for name in try Self.guards(db).keys {try db.execute("DROP TRIGGER \(name)")}
        }
        try epoch.rotate(db,next:record.epochPrepared)
        try SyncNativeMembershipState.write(.prepared(record),db)
        if version==Self.enrolledSchemaVersion {for (_,sql) in try Self.guards(db,membership:true).sorted(by:{$0.key<$1.key}) {try db.execute(sql)}}
        try db.execute("PRAGMA user_version=\(Self.membershipSchemaVersion)")
        try Self.requireGuards(db)
    }
    func openMembershipFloorRecovery(_ db:RoutineDatabase,library:MemoryStore,environment:SyncNativeWriterEnvironment)throws {
        checking=true;defer {checking=false};initialized=true
        try SyncChangeCapture.transaction(db) {
            try NativeMediaSchema.validate(db)
            try SyncDeliveryAnchor.verifyMembershipFloorPreparation(library:library,db:db,environment:environment)
            try Self.requireGuards(db);try epoch.validate(db);try epoch.adopt(db)
        }
        self.environment=environment;markEnrolled();floorPending=true;permit(false)
    }
    func prepareMembershipFloorFence(_ db:RoutineDatabase,record:SyncMembershipFloorPreparation)throws {
        lock.lock();let granted=membershipGranted;lock.unlock()
        guard granted,trustedDepth>0,environment != nil,!poisoned,sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Upgrade membership floor in its owned transaction")}
        try record.validate();try Self.requireGuards(db)
        guard try db.eraseCount("PRAGMA user_version")==Self.membershipSchemaVersion,try epoch.read(db)==record.epochBefore,try SyncNativeMembershipState.read(db)==SyncNativeMembershipState.Value.active(record.head,version:1) else {throw OSwindError.unavailable("Membership floor no longer matches its original writer")}
        try epoch.rotate(db,next:record.epochAfter)
        try SyncNativeMembershipState.write(.active(record.head,version:2),db)
    }
    func suspendForMembershipFloor() {floorPending=true;permit(false)}
    func suspendForMembership() {membershipPending=true;permit(false)}
    func rotateForRetirement(_ db:RoutineDatabase)throws {
        guard trustedDepth>0,environment != nil,!poisoned else {throw OSwindError.invalid("Retire native writers through the checkpoint owner")}
        try epoch.rotate(db)
    }
    func deliveryRolledBack(_ db:RoutineDatabase)throws {
        guard environment != nil else {return}
        guard !poisoned,let proof,try proof.matches(db) else {invalidate();throw OSwindError.unavailable("Native rollback lost its admitted checkpoint")}
        try epoch.adopt(db)
    }
    func withDeliveryMutation<T>(_ body:()throws->T)throws->T {
        trustedDepth+=1;defer {trustedDepth-=1};return try body()
    }
    func withRetirementMutation<T>(_ body:()throws->T)throws->T {
        trustedDepth+=1;lock.lock();let previous=retirementGranted;retirementGranted=true;lock.unlock()
        defer {trustedDepth-=1;lock.lock();retirementGranted=previous;lock.unlock()}
        return try body()
    }
    func requireOwnedWholeErasure()throws {
        guard environment != nil else {return}
        lock.lock();let permitted=retirementGranted;lock.unlock()
        guard permitted else {throw OSwindError.unavailable("Erase an enrolled library through its sync lifecycle owner")}
    }
    func deliveryCommitted(_ db:RoutineDatabase,verified:SyncDeliveryAnchor.NativeWriterProof)throws {
        guard environment != nil else {return}
        checking=true;defer {checking=false}
        // The delivery owner already verified its lease, binding, external
        // bytes and native boundary, then saved this exact token before COMMIT.
        // Adopt that proof without another Keychain read/decode on every phase.
        do {
            try epoch.requireCurrent(db)
            guard !poisoned,try verified.matches(db) else {throw OSwindError.unavailable("Committed native admission changed; use recovery")}
            proof=verified;permit(true)
        }
        catch {permit(false);throw error}
    }
    func invalidate() {
        // Legacy internal33 fixtures have no installed native admission. Their
        // delivery owner still stops, while ordinary local recovery stays open.
        guard environment != nil else {return};poisoned=true;permit(false)
    }
    func suspendForRetirement() {retiring=true;permit(false)}
    private static func guards(_ db:RoutineDatabase,legacy:Bool=false,membership:Bool=false)throws->[String:String] {
        let row=try db.statement("SELECT name FROM pragma_table_list WHERE schema='main' AND type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        defer {sqlite3_finalize(row)}
        var result=[String:String](),code=sqlite3_step(row)
        while code==SQLITE_ROW {
            let table=db.text(row,0)
            guard !table.isEmpty,table.utf8.allSatisfy({(97...122).contains($0)||(48...57).contains($0)||$0==95}) else {throw OSwindError.invalid("Unsupported native table name")}
            for op in ["insert","update","delete"] {
                let name="sync_native_writer_\(table)_\(op)"
                let generation=legacy ? "":" OR \(SyncNativeWriterEpoch.guardCondition)"
                let phase=membership ? " OR \(SyncNativeMembershipState.guardCondition)":""
                result[name]="CREATE TRIGGER \(name) BEFORE \(op.uppercased()) ON \(table) BEGIN SELECT CASE WHEN oswind_native_sync_writer_v1()<>1\(generation)\(phase) THEN RAISE(ABORT,'Reopen OSwind to verify device sync writer admission') END; END"
            }
            code=sqlite3_step(row)
        }
        guard code==SQLITE_DONE,!result.isEmpty else {throw db.error()}
        if !legacy {for op in ["insert","update"] {
            let name="sync_native_retirement_metadata_"+op
            result[name]="CREATE TRIGGER \(name) BEFORE \(op.uppercased()) ON store_metadata WHEN new.key IN ('library_wipe_dirty','library_group_wipe_dirty_v1') AND new.value='1' AND oswind_native_sync_retirement_v1()<>1 BEGIN SELECT RAISE(ABORT,'Erase an enrolled library through its sync lifecycle owner'); END"
        }}
        if membership {for op in ["insert","update","delete"] {
            let name="sync_native_membership_metadata_"+op
            let predicate=op=="insert" ? "new.key IN ('\(SyncNativeMembershipState.phaseKey)','\(SyncNativeMembershipState.stateKey)')":op=="delete" ? "old.key IN ('\(SyncNativeMembershipState.phaseKey)','\(SyncNativeMembershipState.stateKey)')":"(new.key IN ('\(SyncNativeMembershipState.phaseKey)','\(SyncNativeMembershipState.stateKey)') OR old.key IN ('\(SyncNativeMembershipState.phaseKey)','\(SyncNativeMembershipState.stateKey)'))"
            result[name]="CREATE TRIGGER \(name) BEFORE \(op.uppercased()) ON store_metadata WHEN \(predicate) AND oswind_native_sync_membership_v1()<>1 BEGIN SELECT RAISE(ABORT,'Membership metadata requires its saved operation owner'); END"
        }}
        return result
    }
    private static func requireGuards(_ db:RoutineDatabase,legacy:Bool=false)throws {
        let version=try db.eraseCount("PRAGMA user_version")
        guard legacy ? version==34:[enrolledSchemaVersion,membershipSchemaVersion].contains(version) else {throw OSwindError.unavailable("Native writer admission was rolled back; use recovery")}
        for (name,sql) in try guards(db,legacy:legacy,membership:version==membershipSchemaVersion) {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.unavailable("Native writer admission is missing or changed; use recovery")}
        }
    }
}
