import Foundation
import CSQLite

/// Disposable public certificates, never a trusted head or private material.
/// The caller supplies its verified Keychain head on every read/retention.
enum SyncMembershipHistory {
    static let prefix="sync-membership-certificate-v1:"
    static let maximumRecords=256
    private static let maximumEncodedBytes=((SyncPairingFormat.certificateLimit+2)/3)*4
    private static func namespace(_ head:SyncMembershipCertificate)throws->String {
        try head.verify(root:head.body.rootPublicKey)
        return prefix+head.body.group+":"+head.body.epoch+":"
    }
    private static func digest(_ value:SyncMembershipCertificate)throws->String {SyncProtocolLimits.hex(try value.encoded())}
    private static func requireSpace(_ value:SyncMembershipCertificate,head:SyncMembershipCertificate)throws {
        try value.verify(root:head.body.rootPublicKey)
        guard value.body.group==head.body.group,value.body.epoch==head.body.epoch else {throw OSwindError.invalid("Membership history belongs to another group or epoch")}
    }
    private static func read(_ hash:String,head:SyncMembershipCertificate,namespace:String,db:RoutineDatabase)throws->SyncMembershipCertificate? {
        try SyncProtocolLimits.digest(hash)
        let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,namespace+hash)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw db.error()}
        guard sqlite3_column_type(row,0)==SQLITE_TEXT,sqlite3_column_bytes(row,0)>0,sqlite3_column_bytes(row,0)<=maximumEncodedBytes else {throw OSwindError.invalid("Saved membership certificate exceeds its bound")}
        let text=db.text(row,0)
        guard let bytes=Data(base64Encoded:text),bytes.base64EncodedString()==text else {throw OSwindError.invalid("Invalid saved membership certificate encoding")}
        let value=try SyncMembershipCertificate.decode(bytes,root:head.body.rootPublicKey)
        try requireSpace(value,head:head)
        guard try digest(value)==hash else {throw OSwindError.invalid("Membership certificate differs from its saved address")}
        return value
    }
    /// Save evidence before advancing private authority. Failed private CAS may
    /// leave a signed fork here; it is harmless unless the private head names it.
    /// Evict only bounded orphan cache entries, preserving every known ancestor.
    static func retain(_ certificates:[SyncMembershipCertificate],anchoredHead:SyncMembershipCertificate,db:RoutineDatabase)throws {
        guard sqlite3_get_autocommit(db.handle)==0,!certificates.isEmpty,certificates.count<=SyncProtocolLimits.peers else {throw OSwindError.invalid("Retain bounded membership history in its native transaction")}
        let space=try namespace(anchoredHead)
        var supplied=[String:SyncMembershipCertificate]()
        for certificate in certificates {try requireSpace(certificate,head:anchoredHead);supplied[try digest(certificate)]=certificate}
        supplied[try digest(anchoredHead)]=anchoredHead
        var protected=Set(supplied.keys),cursor=anchoredHead,visited=Set<String>()
        while true {
            let hash=try digest(cursor);guard visited.insert(hash).inserted,visited.count<=SyncProtocolLimits.peers else {throw OSwindError.invalid("Invalid membership ancestry")}
            protected.insert(hash)
            guard let previous=cursor.body.previous else {break}
            // Legacy libraries may not have recorded their earlier history.
            // Preserve that explicit gap; never manufacture a predecessor.
            guard let prior=try supplied[previous] ?? read(previous,head:anchoredHead,namespace:space,db:db) else {break}
            try cursor.requireSuccessor(of:prior);cursor=prior
        }
        let keys=try db.statement("SELECT key FROM store_metadata WHERE key>=? AND key<? ORDER BY key LIMIT ?");defer {sqlite3_finalize(keys)}
        db.bind(keys,1,space);db.bind(keys,2,space+"~");sqlite3_bind_int(keys,3,Int32(maximumRecords+1))
        var existing=[String](),code=sqlite3_step(keys)
        while code==SQLITE_ROW {
            guard sqlite3_column_bytes(keys,0)==space.utf8.count+64 else {throw OSwindError.invalid("Invalid membership cache address")}
            let key=db.text(keys,0),hash=String(key.dropFirst(space.count));try SyncProtocolLimits.digest(hash);existing.append(hash);code=sqlite3_step(keys)
        }
        guard code==SQLITE_DONE,existing.count<=maximumRecords else {throw OSwindError.invalid("Membership cache exceeds its record bound")}
        let added=Set(supplied.keys).subtracting(existing)
        if existing.count+added.count>maximumRecords {
            let remove=try db.statement("DELETE FROM store_metadata WHERE key=?");defer {sqlite3_finalize(remove)}
            for hash in existing where !protected.contains(hash) {sqlite3_reset(remove);sqlite3_clear_bindings(remove);db.bind(remove,1,space+hash);try db.done(remove)}
            existing.removeAll {!protected.contains($0)}
        }
        guard Set(existing).union(supplied.keys).count<=maximumRecords else {throw OSwindError.invalid("Retain active membership ancestry within its bound")}
        let put=try db.statement("INSERT INTO store_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE store_metadata.value IS NOT excluded.value");defer {sqlite3_finalize(put)}
        for (hash,certificate) in supplied.sorted(by:{$0.key<$1.key}) {
            sqlite3_reset(put);sqlite3_clear_bindings(put);db.bind(put,1,space+hash);db.bind(put,2,try certificate.encoded().base64EncodedString());try db.done(put)
        }
    }
    /// Read only the exact root-signed path ending at the verified private
    /// head. Orphan branches and plausible newer revisions are not authority.
    static func page(after trusted:SyncMembershipCertificate,anchoredHead:SyncMembershipCertificate,db:RoutineDatabase)throws->SyncMembershipRefresh? {
        let space=try namespace(anchoredHead);try requireSpace(trusted,head:anchoredHead)
        if trusted==anchoredHead {return nil}
        let target=try digest(trusted);var cursor=anchoredHead,backwards=[SyncMembershipCertificate](),seen=Set<String>()
        while cursor != trusted {
            let hash=try digest(cursor);guard seen.insert(hash).inserted,seen.count<SyncProtocolLimits.peers else {throw OSwindError.invalid("Membership history cannot reach the exact trusted certificate")}
            backwards.append(cursor)
            guard let previous=cursor.body.previous else {throw OSwindError.invalid("Membership update does not extend this trusted history")}
            let prior:SyncMembershipCertificate
            if previous==target {prior=trusted}
            else {guard let saved=try read(previous,head:anchoredHead,namespace:space,db:db) else {throw OSwindError.unavailable("An intermediate signed membership certificate is missing; use a retained certificate or explicit device recovery")};prior=saved}
            try cursor.requireSuccessor(of:prior);cursor=prior
        }
        return try .boundedPrefix(base:trusted,updates:Array(backwards.reversed()))
    }
}
