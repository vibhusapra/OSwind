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
    private let lock=NSLock()
    private var allowed=false
    private var proof:SyncDeliveryAnchor.NativeWriterProof?
    private var environment:SyncNativeWriterEnvironment?
    private var checking=false, trustedDepth=0
    private var schemaCookie:Int?
    private var initialized=false
    private var poisoned=false
    func register(_ db:RoutineDatabase)throws {
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
        guard version==34 else {
            if version>=33 {try SyncChangeCapture.transaction(db) {try PersonalSyncPairing.requirePreFenceDeliveryAdmission(library:library,db:db,environment:environment)}}
            return
        }
        self.environment=environment
        do {
            proof=try SyncChangeCapture.transaction(db) {
                let verified=try SyncDeliveryAnchor.nativeWriterProof(library:library,db:db,environment:environment)
                try Self.requireGuards(db);return verified
            }
            schemaCookie=try db.eraseCount("PRAGMA schema_version")
            permit(true)
        }catch {permit(false);throw error}
    }
    func require(_ db:RoutineDatabase,library:MemoryStore)throws {
        guard initialized,!checking,trustedDepth==0 else {return}
        guard !poisoned else {throw OSwindError.unavailable("Native delivery admission needs recovery after an ambiguous checkpoint commit")}
        checking=true;defer {checking=false}
        guard let environment,let proof else {
            // Do not upgrade an already-open pre-enrollment connection into an
            // admitted writer. The owner explicitly admits its own connection.
            guard try db.eraseCount("PRAGMA user_version") != 34 else {throw OSwindError.unavailable("Device sync changed this library. Reopen it to verify native writer admission, or export with backup recover.")}
            return
        }
        do {
            let cookie=try db.eraseCount("PRAGMA schema_version")
            if cookie != schemaCookie {try Self.requireGuards(db);schemaCookie=cookie}
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
    func install(_ db:RoutineDatabase,library:MemoryStore,environment:SyncNativeWriterEnvironment)throws {
        guard sqlite3_get_autocommit(db.handle) != 0 else {throw OSwindError.invalid("Install native admission outside a transaction")}
        checking=true;defer {checking=false}
        do {
            let verified=try SyncDeliveryAnchor.nativeWriterProof(library:library,db:db,environment:environment)
            permit(true)
            try SyncChangeCapture.transaction(db) {
                guard try verified.matches(db) else {throw OSwindError.unavailable("Delivery checkpoint changed during native enrollment")}
                if try db.eraseCount("PRAGMA user_version")==34 {try Self.requireGuards(db)}
                else {
                    for (name,sql) in try Self.guards(db).sorted(by:{$0.key<$1.key}) {
                        guard try db.eraseCount("SELECT COUNT(*) FROM sqlite_master WHERE name='\(name)'")==0 else {throw OSwindError.invalid("Native writer guard already exists")}
                        try db.execute(sql)
                    }
                    try db.execute("PRAGMA user_version=34")
                }
            }
            self.environment=environment;proof=verified;initialized=true
            schemaCookie=try db.eraseCount("PRAGMA schema_version")
        }catch {permit(false);throw error}
    }
    func withDeliveryMutation<T>(_ body:()throws->T)throws->T {
        trustedDepth+=1;defer {trustedDepth-=1};return try body()
    }
    func deliveryCommitted(_ db:RoutineDatabase,verified:SyncDeliveryAnchor.NativeWriterProof)throws {
        guard environment != nil else {return}
        checking=true;defer {checking=false}
        // The delivery owner already verified its lease, binding, external
        // bytes and native boundary, then saved this exact token before COMMIT.
        // Adopt that proof without another Keychain read/decode on every phase.
        do {
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
    private static func guards(_ db:RoutineDatabase)throws->[String:String] {
        let row=try db.statement("SELECT name FROM pragma_table_list WHERE schema='main' AND type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        defer {sqlite3_finalize(row)}
        var result=[String:String](),code=sqlite3_step(row)
        while code==SQLITE_ROW {
            let table=db.text(row,0)
            guard !table.isEmpty,table.utf8.allSatisfy({(97...122).contains($0)||(48...57).contains($0)||$0==95}) else {throw OSwindError.invalid("Unsupported native table name")}
            for op in ["insert","update","delete"] {
                let name="sync_native_writer_\(table)_\(op)"
                result[name]="CREATE TRIGGER \(name) BEFORE \(op.uppercased()) ON \(table) BEGIN SELECT CASE WHEN oswind_native_sync_writer_v1()<>1 THEN RAISE(ABORT,'Reopen OSwind to verify device sync writer admission') END; END"
            }
            code=sqlite3_step(row)
        }
        guard code==SQLITE_DONE,!result.isEmpty else {throw db.error()};return result
    }
    private static func requireGuards(_ db:RoutineDatabase)throws {
        guard try db.eraseCount("PRAGMA user_version")==34 else {throw OSwindError.unavailable("Native writer admission was rolled back; use recovery")}
        for (name,sql) in try guards(db) {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
            guard sqlite3_step(row)==SQLITE_ROW,db.text(row,0)==sql else {throw OSwindError.unavailable("Native writer admission is missing or changed; use recovery")}
        }
    }
}
