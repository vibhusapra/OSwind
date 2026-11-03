import Foundation
import CSQLite

/// Saved before any private membership handover. Contains hashes, public
/// identities and an encrypted-inbox address, never replacement credentials.
struct SyncMembershipPreparation:Codable,Equatable,Sendable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    enum Disposition:String,Codable {case preparing,cancelling}
    let format:String,version:Int,operation:String,plan:SyncContentReference,pairingID:String
    let pairingBefore:String,pairingAfter:String,materialBefore:String,materialAfter:String,headBefore:String,headAfter:String
    let nativeBefore:Int,epochBefore:String,epochPrepared:String
    let tokenBefore:SyncDeliveryAnchor.Token,tokenPrepared:SyncDeliveryAnchor.Token
    let disposition:Disposition
    var tokenCancelled:SyncDeliveryAnchor.Token {.init(serial:tokenPrepared.serial==Int64.max ? Int64.max:tokenPrepared.serial+1,nonce:String(SyncProtocolLimits.hex(Data(("OSwind.sync.membership-cancellation.v1\0"+operation+"\0"+tokenPrepared.nonce).utf8)).prefix(32)))}
    func validate()throws {
        guard format=="OSwind.sync.membership-preparation",version==1,[35,36].contains(nativeBefore),plan.bytes>0,plan.bytes<=Int64(SyncMembershipRefresh.maximumBytes),headBefore != headAfter,materialBefore != materialAfter,pairingBefore != pairingAfter,epochBefore != epochPrepared else {throw OSwindError.invalid("Invalid saved membership preparation")}
        try SyncProtocolLimits.uuid(operation);try SyncCredentialStorageLimits.validate(id:pairingID)
        for digest in [plan.sha256,pairingBefore,pairingAfter,materialBefore,materialAfter,headBefore,headAfter] {try SyncProtocolLimits.digest(digest)}
        for epoch in [epochBefore,epochPrepared] {guard epoch.utf8.count==32,epoch.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw OSwindError.invalid("Invalid membership writer generation")}}
        try tokenBefore.validate();try tokenPrepared.validate()
        guard tokenBefore.serial<Int64.max-2,tokenPrepared.serial==tokenBefore.serial+1,tokenBefore.nonce != tokenPrepared.nonce else {throw OSwindError.invalid("Membership preparation must advance its original checkpoint exactly once")}
        try tokenCancelled.validate();guard tokenCancelled.nonce != tokenBefore.nonce,tokenCancelled.nonce != tokenPrepared.nonce else {throw OSwindError.invalid("Membership cancellation nonce collides with its original checkpoints")}
    }
    func cancelling()->Self {.init(format:format,version:version,operation:operation,plan:plan,pairingID:pairingID,pairingBefore:pairingBefore,pairingAfter:pairingAfter,materialBefore:materialBefore,materialAfter:materialAfter,headBefore:headBefore,headAfter:headAfter,nativeBefore:nativeBefore,epochBefore:epochBefore,epochPrepared:epochPrepared,tokenBefore:tokenBefore,tokenPrepared:tokenPrepared,disposition:.cancelling)}
    func require(_ proof:SyncMembershipRefresh,material:SyncCredentialMaterial)throws {
        try validate()
        guard try SyncProtocolLimits.hex(material.encodedForKeychain())==materialBefore,
              try SyncProtocolLimits.hex(proof.base.encoded())==headBefore,try SyncProtocolLimits.hex(proof.head.encoded())==headAfter,
              proof.base==material.joined.certificate,
              try SyncProtocolLimits.hex(material.withMembershipRefresh(proof).encodedForKeychain())==materialAfter else {throw OSwindError.unavailable("Saved membership proof differs from its original private authority")}
    }
    var description:String {"<redacted membership preparation>"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:["operation":"redacted"])}
}

/// Native36 is opt-in at the first membership preparation. Ordinary content
/// stays33 and existing enrollment stays35 until that owned operation.
enum SyncNativeMembershipState {
    static let phaseKey="sync-native-membership-phase-v1",stateKey="sync-native-membership-state-v1"
    static let guardCondition="(oswind_native_sync_membership_v1()<>1 AND (SELECT value FROM store_metadata WHERE key='\(phaseKey)') IS NOT 'active')"
    struct Value:Codable,Equatable {
        let format:String,version:Int,head:String,operation:String?,plan:String?,target:String?
        static func active(_ head:String)->Self {.init(format:"OSwind.sync.native-membership",version:1,head:head,operation:nil,plan:nil,target:nil)}
        static func prepared(_ record:SyncMembershipPreparation)->Self {.init(format:"OSwind.sync.native-membership",version:1,head:record.headBefore,operation:record.operation,plan:record.plan.sha256,target:record.headAfter)}
        var phase:String {operation==nil ? "active":"prepared"}
        func validate()throws {
            guard format=="OSwind.sync.native-membership",version==1,(operation==nil)==(plan==nil),(operation==nil)==(target==nil) else {throw OSwindError.invalid("Invalid native membership phase")}
            try SyncProtocolLimits.digest(head)
            if let operation,let plan,let target {try SyncProtocolLimits.uuid(operation);try SyncProtocolLimits.digest(plan);try SyncProtocolLimits.digest(target);guard head != target else {throw OSwindError.invalid("Membership preparation has no successor")}}
        }
    }
    static func read(_ db:RoutineDatabase)throws->Value {
        let row=try db.statement("SELECT value,(SELECT value FROM store_metadata WHERE key=?) FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,phaseKey);db.bind(row,2,stateKey)
        guard sqlite3_step(row)==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_TEXT,sqlite3_column_bytes(row,0)>0,sqlite3_column_bytes(row,0)<=2048,sqlite3_column_type(row,1)==SQLITE_TEXT,sqlite3_column_bytes(row,1)<=8 else {throw OSwindError.unavailable("Native membership state is missing or exceeds its bound")}
        let value=try SyncPairingFormat.decode(Value.self,Data(db.text(row,0).utf8),limit:2048);try value.validate()
        guard db.text(row,1)==value.phase else {throw OSwindError.unavailable("Native membership phase differs from its saved operation")};return value
    }
    static func write(_ value:Value,_ db:RoutineDatabase)throws {
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Save membership state in its owning transaction")};try value.validate()
        let row=try db.statement("INSERT INTO store_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");defer {sqlite3_finalize(row)}
        for (key,text) in [(phaseKey,value.phase),(stateKey,String(decoding:try SyncProtocolLimits.encode(value),as:UTF8.self))] {sqlite3_reset(row);sqlite3_clear_bindings(row);db.bind(row,1,key);db.bind(row,2,text);try db.done(row)}
    }
    static func requireActive(_ db:RoutineDatabase,certificate:SyncMembershipCertificate,floor:String?)throws {
        let version=try db.eraseCount("PRAGMA user_version"),head=SyncProtocolLimits.hex(try certificate.encoded())
        if let floor {guard floor==head,version==36 else {throw OSwindError.unavailable("Native membership was rolled back; use saved operation recovery")}}
        if version==36 {guard try read(db)==Value.active(head) else {throw OSwindError.unavailable("Finish the saved membership operation before ordinary access")}}
    }
}
