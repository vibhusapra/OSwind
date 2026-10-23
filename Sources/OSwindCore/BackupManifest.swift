import Foundation
import CryptoKit
import CSQLite
import Darwin

enum BackupSHA256 { static func hex(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() } }

struct BackupMediaEntry: Codable, Equatable, Sendable {
    var sourcePath: String
    var member: String
    var bytes: Int64
    var sha256: String
    static func member(for sourcePath: String) -> String { "media/"+SHA256.hash(data:Data(sourcePath.utf8)).map { String(format:"%02x",$0) }.joined() }
    static func validateSourcePath(_ path: String) throws {
        let parts = try BackupFileTree.components(path)
        guard parts.count >= 2, ["images","audio","video"].contains(parts[0]) else { throw BackupFileError.invalid("Backup media must belong to images, audio or video") }
    }
    func validate() throws {
        try Self.validateSourcePath(sourcePath)
        guard member == Self.member(for:sourcePath), bytes >= 0, sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw BackupFileError.invalid("Invalid backup media manifest entry") }
    }
}
struct BackupPendingMedia { var sourcePath: String; var member: String; var pinned: Bool }

/// Disk-backed keys avoid an archive-sized Set/dictionary while pinning,
/// validating duplicates or looking up source references during restore.
final class BackupManifestIndex {
    private let db: BackupDatabase
    init(_ url: URL) throws {
        db = try BackupDatabase(url,createPrivate:true)
        try db.execute("CREATE TABLE media(source_path TEXT PRIMARY KEY,member TEXT NOT NULL UNIQUE,pinned INTEGER NOT NULL DEFAULT 0,active INTEGER NOT NULL DEFAULT 0,bytes INTEGER,sha256 TEXT); BEGIN IMMEDIATE;")
    }
    func close() { db.close() }
    func register(_ path: String, rejectDuplicate: Bool = false) throws -> BackupPendingMedia {
        try BackupMediaEntry.validateSourcePath(path)
        let member = BackupMediaEntry.member(for:path)
        let statement = try db.prepare("INSERT INTO media(source_path,member) VALUES(?,?)"+(rejectDuplicate ? "" : " ON CONFLICT(source_path) DO NOTHING"))
        defer { sqlite3_finalize(statement) }; db.bind(statement,1,path); db.bind(statement,2,member)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw BackupFileError.invalid("Duplicate or conflicting backup media mapping") }
        let lookup = try db.prepare("SELECT pinned FROM media WHERE source_path=?"); defer { sqlite3_finalize(lookup) }; db.bind(lookup,1,path)
        guard sqlite3_step(lookup) == SQLITE_ROW else { throw db.error("Missing backup media mapping") }
        return BackupPendingMedia(sourcePath:path,member:member,pinned:sqlite3_column_int(lookup,0) != 0)
    }
    func beginAttempt() throws { try db.execute("UPDATE media SET active=0;") }
    func markActive(_ path: String) throws { try update("UPDATE media SET active=1 WHERE source_path=?",path) }
    func markPinned(_ path: String) throws { try update("UPDATE media SET pinned=1 WHERE source_path=?",path) }
    private func update(_ sql: String, _ path: String) throws {
        let statement = try db.prepare(sql); defer { sqlite3_finalize(statement) }; db.bind(statement,1,path)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db.handle) == 1 else { throw db.error("Cannot update backup media state") }
    }
    func record(_ entry: BackupMediaEntry, rejectDuplicate: Bool = false) throws {
        try entry.validate(); _ = try register(entry.sourcePath,rejectDuplicate:rejectDuplicate)
        let statement = try db.prepare("UPDATE media SET bytes=?,sha256=?,active=1,pinned=1 WHERE source_path=?")
        defer { sqlite3_finalize(statement) }; sqlite3_bind_int64(statement,1,entry.bytes); db.bind(statement,2,entry.sha256); db.bind(statement,3,entry.sourcePath)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw db.error("Cannot record backup media digest") }
    }
    var activeCount: Int64 { get throws { try db.integer("SELECT COUNT(*) FROM media WHERE active=1") } }
    var activeBytes: Int64 { get throws { try db.integer("SELECT COALESCE(SUM(bytes),0) FROM media WHERE active=1") } }
    func forEachActive(_ body: (BackupPendingMedia) throws -> Void) throws {
        var cursor = ""
        while true {
            try Task.checkCancellation()
            let statement = try db.prepare("SELECT source_path,member,pinned FROM media WHERE active=1 AND source_path>? ORDER BY source_path LIMIT 128")
            db.bind(statement,1,cursor); var page = [BackupPendingMedia](), status = sqlite3_step(statement)
            do {
                while status == SQLITE_ROW { page.append(BackupPendingMedia(sourcePath:try db.text(statement,0),member:try db.text(statement,1),pinned:sqlite3_column_int(statement,2) != 0)); status = sqlite3_step(statement) }
                guard status == SQLITE_DONE else { throw db.error("Cannot enumerate backup media") }
                sqlite3_finalize(statement)
            } catch { sqlite3_finalize(statement); throw error }
            guard let last = page.last else { break }
            for pending in page { try Task.checkCancellation(); try body(pending) }
            cursor = last.sourcePath
        }
    }
    func entry(for path: String, requireActive: Bool = true) throws -> BackupMediaEntry? {
        let statement = try db.prepare("SELECT member,bytes,sha256 FROM media WHERE source_path=?"+(requireActive ? " AND active=1" : ""))
        defer { sqlite3_finalize(statement) }; db.bind(statement,1,path); let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, sqlite3_column_type(statement,1) == SQLITE_INTEGER else { throw BackupFileError.invalid("Backup media digest is incomplete") }
        return BackupMediaEntry(sourcePath:path,member:try db.text(statement,0),bytes:sqlite3_column_int64(statement,1),sha256:try db.text(statement,2))
    }
    func contains(member: String) throws -> Bool {
        let statement = try db.prepare("SELECT 1 FROM media WHERE member=? AND active=1"); defer { sqlite3_finalize(statement) }; db.bind(statement,1,member)
        let status = sqlite3_step(statement); guard status == SQLITE_ROW || status == SQLITE_DONE else { throw db.error("Cannot inspect backup member") }; return status == SQLITE_ROW
    }
    func write(to tree: BackupFileTree) throws -> BackupFileDigest {
        try tree.withNewFile("media.ndjson") { descriptor in
            let output = FileHandle(fileDescriptor:descriptor,closeOnDealloc:false), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            try forEachActive { pending in
                guard let entry = try self.entry(for:pending.sourcePath) else { throw BackupFileError.invalid("Missing backup media digest") }
                var line = try encoder.encode(entry); line.append(10); try output.write(contentsOf:line)
            }
        }
        return try tree.digest("media.ndjson")
    }
    func load(from tree: BackupFileTree, expectedCount: Int64, expectedDigest: BackupFileDigest) throws {
        guard expectedCount >= 0, expectedDigest.bytes >= 0 else { throw BackupFileError.invalid("Invalid backup media manifest bounds") }
        var count: Int64 = 0
        let digest = try BackupLineReader.read(tree,"media.ndjson") { line in
            guard count < expectedCount else { throw BackupFileError.invalid("Backup manifest contains extra entries") }
            let entry = try JSONDecoder().decode(BackupMediaEntry.self,from:line); try self.record(entry,rejectDuplicate:true); count += 1
        }
        guard count == expectedCount, digest == expectedDigest else { throw BackupFileError.invalid("Backup media manifest checksum or count differs") }
    }
}

enum BackupLineReader {
    /// SHA and records come from the same read, avoiding a hash-then-parse race.
    static func read(_ tree: BackupFileTree, _ member: String, maxLineBytes: Int = 262144,
                     body: (Data) throws -> Void) throws -> BackupFileDigest {
        guard maxLineBytes > 0 else { throw BackupFileError.invalid("Invalid manifest line bound") }
        return try tree.withFile(member) { file, before in
            var buffer = [UInt8](repeating:0,count:65536), pending = Data(), hash = SHA256(), total: Int64 = 0
            while true {
                try Task.checkCancellation(); let count = Darwin.read(file,&buffer,buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw BackupFileError.io("Cannot read backup manifest") }; if count == 0 { break }
                guard total <= Int64.max-Int64(count), total+Int64(count) <= before.bytes else { throw BackupFileError.changed("Backup manifest grew while being read") }
                buffer.withUnsafeBytes { hash.update(bufferPointer:UnsafeRawBufferPointer(start:$0.baseAddress,count:count)) }; total += Int64(count)
                pending.append(contentsOf:buffer.prefix(count)); var cursor = pending.startIndex
                while let end = pending[cursor...].firstIndex(of:10) {
                    guard end-cursor > 0, end-cursor <= maxLineBytes else { throw BackupFileError.invalid("Backup manifest has an empty or oversized line") }
                    try body(Data(pending[cursor..<end])); cursor = end+1
                    if cursor == pending.endIndex { break }
                }
                if cursor > pending.startIndex { pending.removeSubrange(pending.startIndex..<cursor) }
                guard pending.count <= maxLineBytes else { throw BackupFileError.invalid("Backup manifest line exceeds its bound") }
            }
            guard pending.isEmpty else { throw BackupFileError.invalid("Backup manifest ends with a truncated line") }
            var after = stat(); guard fstat(file,&after) == 0, BackupFileStamp(after) == before, total == before.bytes else { throw BackupFileError.changed("Backup manifest changed while being read") }
            return BackupFileDigest(bytes:total,sha256:hash.finalize().map { String(format:"%02x",$0) }.joined())
        }
    }
}
