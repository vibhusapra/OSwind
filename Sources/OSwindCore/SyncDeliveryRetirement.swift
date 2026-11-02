import Foundation
import CSQLite

/// Saved in the external delivery authority before logical erasure commits.
/// Physical cleanup and active binding renewal remain separate owned phases.
struct SyncDeliveryRetirement:Codable,Equatable,Sendable {
    enum Kind:String,Codable,Sendable {case local,received}
    let kind:Kind,control:SyncCollectionControl
    let pairingLifetime:String,publicationLifetime:String
    func validate(material:SyncCredentialMaterial)throws {
        let joined=material.joined
        guard control.group==joined.certificate.body.group,control.epoch==joined.certificate.body.epoch,
              joined.certificate.body.members.contains(where:{$0.replica==control.creator}),
              (control.creator==joined.replica)==(kind == .local) else {throw OSwindError.invalid("Retirement belongs to another delivery authority")}
        _=try SyncCollectionControl.decode(control.encoded())
        try SyncProtocolLimits.uuid(pairingLifetime)
        let uuid=UUID(uuidString:publicationLifetime)?.uuidString.lowercased()==publicationLifetime
        let hex=publicationLifetime.utf8.count==32 && publicationLifetime.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)})
        guard uuid || hex else {throw OSwindError.invalid("Invalid retired publication lifetime")}
    }
    func requireLogicalCompletion(_ db:RoutineDatabase,allowCleaned:Bool=false)throws {
        if !allowCleaned {guard try LibraryWipeState.isPending(db) else {throw OSwindError.invalid("Retirement has no pending native cleanup")}}
        try SyncCollectionHistory.requireNativeCompletionHooks(db)
        for table in SyncCanonicalTable.allCases {
            guard try db.eraseCount("SELECT COUNT(*) FROM "+table.rawValue)==0 else {throw OSwindError.invalid("Retirement left live canonical content")}
        }
        for table in ["historical_evidence","personal_sync_versions","personal_sync_version_recipes","personal_sync_version_sessions","personal_sync_version_runs","personal_sync_identity_current","personal_sync_publication_jobs","personal_sync_publication_bindings"] {
            guard try db.eraseCount("SELECT COUNT(*) FROM "+table)==0 else {throw OSwindError.invalid("Retirement left reusable source or identity bytes")}
        }
        let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,SyncCollectionHistory.nativeCompletionKey)
        guard sqlite3_step(row)==SQLITE_ROW,try db.text(row,0)==control.digest else {throw OSwindError.invalid("Complete the exact native retirement before saving its external state")}
    }
}

struct SyncNativeRetirementResult:Sendable {
    let counts:LibraryWipeCounts,control:SyncCollectionControl,pairingLifetime:String
}
