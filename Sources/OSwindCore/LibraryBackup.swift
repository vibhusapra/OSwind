import Foundation
import CSQLite

public struct LibraryBackupProgress: Sendable {
    public var phase: String
    public var completedItems: Int64
    public var totalItems: Int64
    public var unit: String
    public var copiedBytes: Int64
    public var attempt: Int
    public init(phase: String, completedItems: Int64 = 0, totalItems: Int64 = 0, copiedBytes: Int64 = 0, attempt: Int = 1, unit: String = "files") {
        self.phase = phase; self.completedItems = completedItems; self.totalItems = totalItems; self.copiedBytes = copiedBytes; self.attempt = attempt; self.unit = unit
    }
}
public struct LibraryBackupInfo: Codable, Sendable {
    public var formatVersion: Int
    public var createdAt: String
    public var sourceSchema: Int
    public var memories: Int64
    public var conversations: Int64
    public var turns: Int64
    public var mediaFiles: Int64
    public var payloadBytes: Int64
    public var encryption: String
    public var archiveFingerprint: String? = nil
}
struct LibraryBackupHeader: Codable {
    var format = "OSwind library backup"
    var info: LibraryBackupInfo
    var database: BackupFileDigest
    var settings: BackupFileDigest
    var manifest: BackupFileDigest
    func validate() throws {
        guard format == "OSwind library backup", info.formatVersion == 1, (6...MemoryStore.schemaVersion).contains(info.sourceSchema), info.encryption == "none", info.archiveFingerprint == nil,
              [info.memories,info.conversations,info.turns,info.mediaFiles,info.payloadBytes,database.bytes,settings.bytes,manifest.bytes].allSatisfy({$0>=0}), database.bytes >= 100, settings.bytes <= 1_048_576,
              [database,settings,manifest].allSatisfy({$0.sha256.count==64 && $0.sha256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)})}) else { throw BackupFileError.invalid("Unsupported or invalid library backup header") }
        _ = try QueryScopeResolver.instant(info.createdAt)
    }
}
enum BackupMath {
    static func add(_ a: Int64,_ b: Int64) throws -> Int64 {
        let (sum,overflow) = a.addingReportingOverflow(b); guard a>=0,b>=0,!overflow else { throw BackupFileError.invalid("Backup byte or file count overflow") }; return sum
    }
}
final class BackupDataReader {
    let db: BackupDatabase
    let schema: Int
    init(_ url: URL) throws {
        db = try BackupDatabase(url)
        schema = Int(try db.integer("PRAGMA user_version"))
        guard (6...MemoryStore.schemaVersion).contains(schema) else { throw BackupFileError.invalid("Unsupported backup database schema") }
        for name in ["memories","chat_sessions","chat_turns","chat_sources","semantic_vectors","semantic_passages","passage_manifests"] { try db.requireTable(name) }
        guard try db.integer("SELECT COUNT(*) FROM memories NOT INDEXED WHERE length(payload)>\(MemoryStore.maximumRecordBytes)")==0 else { throw BackupFileError.invalid("A source payload exceeds the backup format's 128 MiB record bound") }
    }
    func close() { db.close() }
    func counts() throws -> (Int64,Int64,Int64) { (try db.integer("SELECT COUNT(*) FROM memories NOT INDEXED"),try db.integer("SELECT COUNT(*) FROM chat_sessions NOT INDEXED"),try db.integer("SELECT COUNT(*) FROM chat_turns NOT INDEXED")) }
    func forEachAsset(_ body: (String) throws -> Void) throws {
        var cursor = Int64.min, first = true
        while true {
            try Task.checkCancellation()
            let statement = try db.prepare("SELECT rowid,json_extract(CAST(payload AS TEXT),'$.imagePath'),json_extract(CAST(payload AS TEXT),'$.audioPath') FROM memories NOT INDEXED WHERE rowid\(first ? ">=" : ">")? ORDER BY rowid LIMIT 128")
            sqlite3_bind_int64(statement,1,cursor); var paths = [String](), last: Int64?, status = sqlite3_step(statement)
            do {
                while status == SQLITE_ROW {
                    last = sqlite3_column_int64(statement,0)
                    for column: Int32 in [1,2] where sqlite3_column_type(statement,column) != SQLITE_NULL { let path = try db.text(statement,column); try BackupMediaEntry.validateSourcePath(path); paths.append(path) }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else { throw db.error("Cannot read source media references") }; sqlite3_finalize(statement)
            } catch { sqlite3_finalize(statement); throw error }
            guard let last else { return }; cursor = last; first = false
            for path in paths { try Task.checkCancellation(); try body(path) }
        }
    }
}

public enum LibraryBackup {
    static func quietSettings(_ settings: AppSettings) -> AppSettings {
        var result = settings
        result.captureOnLaunch = false; result.audioEnabled = false; result.systemAudioEnabled = false; result.apiEnabled = false
        result.automaticMaintenance = false; result.ai.allowRemote = false; result.ai.provider = .evidence
        result.ai.endpoint = AIConfiguration().endpoint; result.search.provider = .apple; result.search.endpoint = SearchConfiguration().endpoint
        result.whisperBinary = AppSettings().whisperBinary; result.whisperModel = AppSettings().whisperModel
        return result
    }
    private static func sourceSettings(_ tree: BackupFileTree) throws -> AppSettings {
        do { return try JSONDecoder().decode(AppSettings.self,from:tree.read("settings.json",limit:1_048_576)) }
        catch BackupFileError.missing { return AppSettings() }
    }
    @discardableResult public static func create(store: MemoryStore, destination: URL, maxAttempts: Int = 3,
                                                 progress: (LibraryBackupProgress) throws -> Void = { _ in }) throws -> LibraryBackupInfo {
        guard (1...10).contains(maxAttempts), destination.isFileURL else { throw BackupFileError.invalid("Invalid backup destination or retry bound") }
        try BackupWorkspace.requireNewDestination(destination)
        _ = try BackupWorkspace.cleanupAbandoned()
        _ = try BackupWorkspace.cleanupAbandoned(in:destination.deletingLastPathComponent())
        let source = try BackupFileTree(root:store.root.standardizedFileURL.resolvingSymlinksInPath()), outputParent = try BackupFileTree(root:destination.deletingLastPathComponent())
        guard try !source.isAncestor(of:outputParent) else { throw BackupFileError.invalid("Save the backup outside its source library") }
        let scratch = try BackupWorkspace(label:"oswind-backup-pins"), output = try BackupWorkspace(in:destination.deletingLastPathComponent(),label:"oswind-backup-partial")
        defer { withExtendedLifetime(scratch) {} }
        let index = try BackupManifestIndex(scratch.url.appendingPathComponent("manifest-index.sqlite"))
        defer { index.close(); withExtendedLifetime(scratch) {} }
        try progress(LibraryBackupProgress(phase:"Preparing media"))
        let live = try BackupDataReader(store.root.appendingPathComponent("memory.sqlite")); defer { live.close() }
        var pinned: Int64 = 0
        try live.forEachAsset { path in
            let pending = try index.register(path)
            if !pending.pinned {
                do { _ = try source.pin(path,to:scratch.tree,as:pending.member); try index.markPinned(path); pinned = try BackupMath.add(pinned,1) }
                catch BackupFileError.missing { return }
                try progress(LibraryBackupProgress(phase:"Protecting media",completedItems:pinned))
            }
        }
        var completedAttempt = 0
        for attempt in 1...maxAttempts {
            try Task.checkCancellation(); try index.beginAttempt()
            let snapshot = scratch.url.appendingPathComponent("memory.sqlite")
            if attempt > 1 { try scratch.tree.remove("memory.sqlite") }
            try progress(LibraryBackupProgress(phase:"Snapshotting database",attempt:attempt))
            try SQLiteSnapshot.copy(source:store.root.appendingPathComponent("memory.sqlite"),to:snapshot) { state in
                try progress(LibraryBackupProgress(phase:"Snapshotting database",completedItems:Int64(state.copiedPages),totalItems:Int64(state.totalPages),attempt:attempt,unit:"pages"))
            }
            let reader = try BackupDataReader(snapshot)
            var missing = false
            do {
                try reader.forEachAsset { path in
                    let pending = try index.register(path); try index.markActive(path)
                    if !pending.pinned {
                        do { _ = try source.pin(path,to:scratch.tree,as:pending.member); try index.markPinned(path) }
                        catch BackupFileError.missing { missing = true }
                    }
                }
                reader.close()
            } catch { reader.close(); throw error }
            if !missing { completedAttempt = attempt; break }
            try progress(LibraryBackupProgress(phase:"Retrying changed media",attempt:attempt))
        }
        guard completedAttempt > 0 else { throw BackupFileError.changed("Referenced media kept disappearing; no partial backup was published") }
        let snapshot = try BackupDataReader(scratch.url.appendingPathComponent("memory.sqlite")); defer { snapshot.close() }
        let counts = try snapshot.counts(), total = try index.activeCount
        var files: Int64 = 0, copied: Int64 = 0
        try index.forEachActive { pending in
            try progress(LibraryBackupProgress(phase:"Copying media",completedItems:files,totalItems:total,copiedBytes:copied,attempt:completedAttempt))
            _ = try scratch.tree.pin(pending.member,to:output.tree,as:pending.member) { bytes in
                try progress(LibraryBackupProgress(phase:"Copying media",completedItems:files,totalItems:total,copiedBytes:try BackupMath.add(copied,bytes),attempt:completedAttempt))
            }
            let digest = try output.tree.digest(pending.member) { bytes in try progress(LibraryBackupProgress(phase:"Verifying media",completedItems:files,totalItems:total,copiedBytes:try BackupMath.add(copied,bytes),attempt:completedAttempt)) }
            try index.record(BackupMediaEntry(sourcePath:pending.sourcePath,member:pending.member,bytes:digest.bytes,sha256:digest.sha256))
            copied = try BackupMath.add(copied,digest.bytes); files = try BackupMath.add(files,1)
        }
        _ = try scratch.tree.pin("memory.sqlite",to:output.tree,as:"memory.sqlite") { bytes in try progress(LibraryBackupProgress(phase:"Copying database",copiedBytes:bytes,attempt:completedAttempt)) }
        let database = try output.tree.digest("memory.sqlite") { bytes in try progress(LibraryBackupProgress(phase:"Verifying database",copiedBytes:bytes,attempt:completedAttempt)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try output.tree.write(encoder.encode(try sourceSettings(source)),as:"settings.json")
        let settings = try output.tree.digest("settings.json"), manifest = try index.write(to:output.tree)
        let info = LibraryBackupInfo(formatVersion:1,createdAt:try ISOTime.string(Date()),sourceSchema:snapshot.schema,memories:counts.0,conversations:counts.1,turns:counts.2,mediaFiles:total,payloadBytes:try BackupMath.add(BackupMath.add(database.bytes,settings.bytes),copied),encryption:"none")
        let header = LibraryBackupHeader(info:info,database:database,settings:settings,manifest:manifest); try header.validate()
        let headerData = try encoder.encode(header)
        try output.tree.write(headerData,as:"header.json")
        try progress(LibraryBackupProgress(phase:"Verifying package",completedItems:files,totalItems:total,copiedBytes:copied,attempt:completedAttempt))
        _ = try inspect(output.url)
        try progress(LibraryBackupProgress(phase:"Publishing backup",completedItems:files,totalItems:total,copiedBytes:copied,attempt:completedAttempt))
        try output.publish(as:destination)
        var result = info; result.archiveFingerprint = BackupSHA256.hex(headerData)
        return result
    }
    public static func inspect(_ archive: URL, progress: (LibraryBackupProgress) throws -> Void = { _ in }) throws -> LibraryBackupInfo {
        _ = try BackupWorkspace.cleanupAbandoned()
        let tree = try BackupFileTree(root:archive), headerData = try tree.read("header.json",limit:65536)
        let header = try JSONDecoder().decode(LibraryBackupHeader.self,from:headerData); try header.validate()
        let scratch = try BackupWorkspace(label:"oswind-backup-inspect"), index = try BackupManifestIndex(scratch.url.appendingPathComponent("manifest-index.sqlite"))
        defer { index.close(); withExtendedLifetime(scratch) {} }
        try index.load(from:tree,expectedCount:header.info.mediaFiles,expectedDigest:header.manifest)
        guard try tree.digest("settings.json") == header.settings else { throw BackupFileError.invalid("Backup settings checksum differs") }
        _ = try JSONDecoder().decode(AppSettings.self,from:tree.read("settings.json",limit:1_048_576))
        _ = try tree.pin("memory.sqlite",to:scratch.tree,as:"memory.sqlite")
        guard try scratch.tree.digest("memory.sqlite") == header.database else { throw BackupFileError.invalid("Backup database checksum differs") }
        let reader = try BackupDataReader(scratch.url.appendingPathComponent("memory.sqlite")); defer { reader.close() }
        let counts = try reader.counts()
        guard reader.schema == header.info.sourceSchema, counts.0 == header.info.memories, counts.1 == header.info.conversations, counts.2 == header.info.turns else { throw BackupFileError.invalid("Backup database counts or schema differ") }
        try index.beginAttempt()
        try reader.forEachAsset { path in
            guard try index.entry(for:path,requireActive:false) != nil else { throw BackupFileError.invalid("Backup is missing referenced media") }
            try index.markActive(path)
        }
        guard try index.activeCount == header.info.mediaFiles else { throw BackupFileError.invalid("Backup contains unreferenced media") }
        var files: Int64 = 0
        try index.forEachActive { pending in
            guard let entry = try index.entry(for:pending.sourcePath), try tree.digest(entry.member) == BackupFileDigest(bytes:entry.bytes,sha256:entry.sha256) else { throw BackupFileError.invalid("Backup media checksum differs") }
            files = try BackupMath.add(files,1); try progress(LibraryBackupProgress(phase:"Verifying media",completedItems:files,totalItems:header.info.mediaFiles))
        }
        let expectedBytes = try BackupMath.add(BackupMath.add(header.database.bytes,header.settings.bytes),index.activeBytes)
        guard expectedBytes == header.info.payloadBytes else { throw BackupFileError.invalid("Backup total bytes differ") }
        let allowed = Set(["header.json","media.ndjson","memory.sqlite","settings.json","media"])
        var hasMedia = false
        try tree.forEachEntry { name in guard allowed.contains(name) else { throw BackupFileError.invalid("Backup has an unexpected root member") }; if name == "media" { hasMedia = true } }
        if hasMedia {
            var found: Int64 = 0
            try tree.forEachEntry(in:"media") { name in guard try index.contains(member:"media/"+name) else { throw BackupFileError.invalid("Backup has unlisted media") }; found = try BackupMath.add(found,1) }
            guard found == header.info.mediaFiles else { throw BackupFileError.invalid("Backup media membership differs") }
        } else { guard header.info.mediaFiles == 0 else { throw BackupFileError.invalid("Backup media directory is absent") } }
        var result = header.info; result.archiveFingerprint = BackupSHA256.hex(headerData)
        return result
    }
}

public enum BackupWorkspaceCleanup {
    @discardableResult public static func run(in directory: URL = FileManager.default.temporaryDirectory) throws -> Int {
        try BackupWorkspace.cleanupAbandoned(in:directory)
    }
}
