import Foundation
import CSQLite

extension MemoryStore {
    func verifyHistoricalMedia(_ reference:SyncVersionReference,_ manifests:[SyncMediaManifest],_ paths:[SyncMediaRole:String])throws {
        try reference.validate(.source);guard Set(paths.keys)==Set(manifests.map(\.role)) else {throw OSwindError.invalid("Historical media roles differ")}
        guard !manifests.isEmpty else {return};try requireMediaRootIdentity()
        let tree=try BackupFileTree(root:root.standardizedFileURL.resolvingSymlinksInPath())
        for manifest in manifests {
            try manifest.validate();guard let path=paths[manifest.role] else {throw OSwindError.unavailable("Historical media is unavailable")}
            let digest=try tree.digest(path,limit:manifest.bytes)
            guard digest.bytes==manifest.bytes,digest.sha256==manifest.sha256 else {throw OSwindError.unavailable("Historical media changed; current bytes were not substituted")}
        }
        try tree.requireRootIdentity(at:root)
    }
    func historicalCatalog(_ db:RoutineDatabase)->HistoricalEvidenceStore {
        if let value=historicalEvidenceCatalog,value.database.handle==db.handle {return value}
        let value=HistoricalEvidenceStore(database:db);historicalEvidenceCatalog=value;return value
    }
    func historicalEvidence(_ db:RoutineDatabase,_ handle:String,sourceID:String?=nil)throws->HistoricalEvidence {
        try historicalCatalog(db).read(handle,sourceID:sourceID,verifyMedia:verifyHistoricalMedia)
    }
    public func historicalMemory(_ handle:String,sourceID:String?=nil)throws->Memory {
        let activity=try mediaWriteLease();defer {activity.release()}
        return try withRoutineDatabase {try historicalEvidence($0,handle,sourceID:sourceID).memory}
    }
}
