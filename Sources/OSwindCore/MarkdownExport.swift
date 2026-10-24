import Foundation
import CSQLite
import Darwin

public struct MarkdownExportInfo: Codable, Sendable {
    public var format = "OSwind portable Markdown library"
    public var version = 1
    public var createdAt: String
    public var sourceSchema: Int
    public var memories: Int64 = 0
    public var excludedMemories: Int64 = 0
    public var conversations: Int64 = 0
    public var turns: Int64 = 0
    public var excludedTurns: Int64 = 0
    public var mediaFiles: Int64 = 0
    public var mediaBytes: Int64 = 0
    public var includeMedia: Bool
}

/// Independent, explicit snapshot export. No models, live capture, remote calls,
/// tokens, settings, vectors or speaker embeddings enter the portable folder.
public enum MarkdownExport {
    public static func create(store: MemoryStore, destination: URL, policy: PrivacyPolicy,
                              includeMedia: Bool = false,
                              progress: (LibraryBackupProgress) throws -> Void = { _ in }) throws -> MarkdownExportInfo {
        try BackupWorkspace.requireNewDestination(destination)
        _ = try BackupWorkspace.cleanupAbandoned()
        _ = try BackupWorkspace.cleanupAbandoned(in:destination.deletingLastPathComponent())
        let source = try BackupFileTree(root:store.root.standardizedFileURL.resolvingSymlinksInPath())
        let parent = try BackupFileTree(root:destination.deletingLastPathComponent())
        guard try !source.isAncestor(of:parent) else { throw OSwindError.invalid("Save the export outside its source library") }
        let scratch = try BackupWorkspace(label:"oswind-markdown-snapshot")
        let output = try BackupWorkspace(in:destination.deletingLastPathComponent(),label:"oswind-markdown-partial")
        defer { withExtendedLifetime(scratch) {}; withExtendedLifetime(output) {} }
        try source.requireRootIdentity(at:store.root)
        try progress(LibraryBackupProgress(phase:"Snapshotting library"))
        try SQLiteSnapshot.copy(source:store.root.appendingPathComponent("memory.sqlite"),to:scratch.url.appendingPathComponent("memory.sqlite")) { state in
            try progress(LibraryBackupProgress(phase:"Snapshotting library",completedItems:Int64(state.copiedPages),totalItems:Int64(state.totalPages),unit:"pages"))
        }
        try source.requireRootIdentity(at:store.root)
        let reader = try BackupDataReader(scratch.url.appendingPathComponent("memory.sqlite")); defer { reader.close() }
        let index = try BackupDatabase(scratch.url.appendingPathComponent("links.sqlite"),createPrivate:true); defer { index.close() }
        try index.execute("CREATE TABLE sources(id TEXT PRIMARY KEY,member TEXT NOT NULL,title TEXT NOT NULL); BEGIN IMMEDIATE;")
        let total = try reader.counts().0
        var info = MarkdownExportInfo(createdAt:try ISOTime.string(Date()),sourceSchema:reader.schema,includeMedia:includeMedia)
        try output.tree.withNewFile("index.md") { descriptor in
            let contents = MarkdownSink(descriptor)
            try contents.write("# OSwind memory\n\nExported \(info.createdAt). Open this folder as an Obsidian vault, or start here in any Markdown reader.\n\nThis is an independent snapshot. Later changes or deletions in OSwind do not update it. Current privacy exclusions and redaction were applied at export start. Media is optional; this folder is not encrypted.\n\n## Sources\n\n")
            let rows = try reader.db.prepare("SELECT id,payload FROM memories NOT INDEXED ORDER BY rowid"); defer { sqlite3_finalize(rows) }
            var status = sqlite3_step(rows)
            while status == SQLITE_ROW {
                // This worker may run without a run-loop pool for hours. Drain
                // Foundation's bridged formatting/regex objects per record.
                try autoreleasepool {
                try Task.checkCancellation()
                let id = try reader.db.text(rows,0)
                let original = try JSONDecoder().decode(Memory.self,from:payload(rows,1))
                guard original.id == id else { throw OSwindError.invalid("Source identity differs from its stored record") }
                if policy.exclusion(app:original.bundleID,title:original.title,url:original.url) != nil {
                    info.excludedMemories += 1
                } else {
                    let (memory,suppressMedia) = try sanitized(original,policy:policy)
                    let key = digest(id), member = "sources/"+key+".md"
                    let insert = try index.prepare("INSERT INTO sources(id,member,title) VALUES(?,?,?)"); defer { sqlite3_finalize(insert) }
                    index.bind(insert,1,id); index.bind(insert,2,member); index.bind(insert,3,memory.title)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw index.error("Cannot index exported source") }
                    var media = [(String,String)]()
                    if includeMedia && !suppressMedia {
                        for (label,path) in [("image",policy.retainImages ? memory.imagePath:nil),("audio",memory.audioPath),("video",policy.retainImages ? memory.videoPath:nil)] {
                            guard let path else { continue }
                            try BackupMediaEntry.validateSourcePath(path)
                            let suffix = URL(fileURLWithPath:path).pathExtension.lowercased()
                            let allowed = label == "image" ? ["jpg","jpeg","png"] : label == "video" ? ["mov","mp4"] : ["wav","m4a","mp3","flac","aif","aiff","caf","ogg","opus","mp4"]
                            guard allowed.contains(suffix) else { throw OSwindError.invalid("Unsupported retained media format in export") }
                            let target = "media/"+key+"-"+label+"."+suffix
                            try source.requireRootIdentity(at:store.root)
                            let copied = try source.copy(path,to:output.tree,as:target) { bytes in
                                try progress(LibraryBackupProgress(phase:"Copying retained media",completedItems:info.memories,totalItems:total,copiedBytes:try BackupMath.add(info.mediaBytes,bytes)))
                            }
                            info.mediaFiles += 1; info.mediaBytes = try BackupMath.add(info.mediaBytes,copied.bytes)
                            media.append((label,"../"+target))
                        }
                    }
                    try output.tree.withNewFile(member) { file in
                        let page = MarkdownSink(file)
                        var metadata: [String:Any] = ["oswind_id":policy.sanitize(id).text,"kind":memory.kind.rawValue,"created":try ISOTime.string(memory.timestamp),"title":memory.title,"app":memory.app,"bundle_id":memory.bundleID,"favorite":memory.favorite,"tags":memory.tags,"aliases":[memory.title]]
                        if let end = memory.endTimestamp { metadata["ended"] = try ISOTime.string(end) }
                        if let session = memory.audioSessionID { metadata["audio_session_id"] = session }
                        try page.write("---\n")
                        for name in metadata.keys.sorted() { try page.write(name+": "+yaml(metadata[name]!)+"\n") }
                        try page.write("---\n\n# "+inline(memory.title)+"\n\n[All sources](../index.md)\n\n")
                        if let url = memory.url { try page.write("## Original location\n\n"+literal(url)) }
                        for (label,path) in media { try page.write("[Open retained \(label)](\(path))\n\n") }
                        if includeMedia && suppressMedia { try page.write("Retained media omitted because this source contains redacted material.\n\n") }
                        try page.write("## Source text\n\n"+literal(memory.text))
                        if let transcript = memory.transcript {
                            try page.write("## Timed transcript\n\nTimes are seconds within the recording. Speaker names are recording-local labels, not verified identities.\n\n")
                            for segment in transcript.segments {
                                try Task.checkCancellation()
                                try page.write("### "+seconds(segment.start)+" – "+seconds(segment.end)+"\n\n")
                                if let speaker = segment.speaker { try page.write("Speaker: "+inline(speaker)+"\n\n") }
                                try page.write(literal(segment.text))
                            }
                        }
                        if let recording = memory.visualRecording {
                            try page.write("## Sampled replay frames\n\nTimes are seconds within the clip. Unchanged frames and gaps can be omitted; this is not uninterrupted coverage.\n\n")
                            for frame in recording.frames { try Task.checkCancellation(); try page.write("### "+seconds(frame.time)+"\n\n"+literal(frame.text)) }
                        }
                    }
                    try contents.write("- ["+inline(String(memory.title.prefix(180)))+"]("+member+") · "+inline(memory.app)+" · "+(try ISOTime.string(memory.timestamp))+"\n")
                    info.memories += 1
                }
                try progress(LibraryBackupProgress(phase:"Exporting sources",completedItems:info.memories+info.excludedMemories,totalItems:total,unit:"sources"))
                }
                status = sqlite3_step(rows)
            }
            guard status == SQLITE_DONE else { throw reader.db.error("Cannot enumerate sources") }
            try contents.write("\n## Conversations\n\nSource numbers restart in every answer. A turn is omitted entirely if any cited source was excluded. Conversation names are generic to avoid exposing a hidden question through its title.\n\n")
            let sessions = try reader.db.prepare("SELECT id FROM chat_sessions NOT INDEXED ORDER BY rowid"); defer { sqlite3_finalize(sessions) }
            status = sqlite3_step(sessions)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                let session = try reader.db.text(sessions,0), member = "conversations/"+digest(session)+".md"
                try output.tree.withNewFile(member) { file in
                    let page = MarkdownSink(file)
                    try page.write("# OSwind conversation\n\n[All sources](../index.md)\n\nSource numbers restart per answer. Turns citing excluded sources are omitted.\n\n")
                    let turns = try reader.db.prepare("SELECT id,timestamp,payload FROM chat_turns WHERE session_id=? ORDER BY timestamp,id"); defer { sqlite3_finalize(turns) }; reader.db.bind(turns,1,session)
                    var turnStatus = sqlite3_step(turns), number = 0
                    while turnStatus == SQLITE_ROW {
                        try autoreleasepool {
                        try Task.checkCancellation()
                        let turn = try reader.db.text(turns,0), date = Date(timeIntervalSince1970:sqlite3_column_double(turns,1))
                        let value = try JSONDecoder().decode(ChatPayload.self,from:payload(turns,2))
                        let sources = try reader.db.prepare("SELECT memory_id,ordinal FROM chat_sources WHERE turn_id=? ORDER BY ordinal"); defer { sqlite3_finalize(sources) }; reader.db.bind(sources,1,turn)
                        var links = [(Int,String,String)](), hidden = false, sourceStatus = sqlite3_step(sources), sourceCount = 0
                        while sourceStatus == SQLITE_ROW {
                            sourceCount += 1
                            guard sourceCount <= 60 else { throw OSwindError.invalid("Conversation exceeds source bound") }
                            let id = try reader.db.text(sources,0), ordinal = Int(sqlite3_column_int64(sources,1))
                            let lookup = try index.prepare("SELECT member,title FROM sources WHERE id=?"); defer { sqlite3_finalize(lookup) }; index.bind(lookup,1,id)
                            let found = sqlite3_step(lookup)
                            if found == SQLITE_ROW { links.append((ordinal+1,try index.text(lookup,0),try index.text(lookup,1))) }
                            else if found == SQLITE_DONE { hidden = true }
                            else { throw index.error("Cannot resolve source link") }
                            sourceStatus = sqlite3_step(sources)
                        }
                        guard sourceStatus == SQLITE_DONE else { throw reader.db.error("Cannot read conversation sources") }
                        if hidden { info.excludedTurns += 1 }
                        else {
                            number += 1
                            try page.write("## Turn \(number) · "+(try ISOTime.string(date))+"\n\n### Question\n\n"+literal(policy.sanitize(value.question).text)+"### Answer\n\n"+literal(policy.sanitize(value.text).text))
                            try page.write("Provider: "+inline(policy.sanitize(value.provider).text)+"\n\n### Search scope\n\n"+literal(policy.sanitize(json(Integration.json(value.filter))).text))
                            if let zone = value.timeZone { try page.write("Time zone: "+inline(policy.sanitize(zone).text)+"\n\n") }
                            for warning in value.warnings { try page.write("Warning: "+inline(policy.sanitize(warning).text)+"\n\n") }
                            for (ordinal,path,title) in links { try page.write("[\(ordinal)] ["+inline(title)+"](../"+path+")\n\n") }
                            info.turns += 1
                        }
                        }
                        turnStatus = sqlite3_step(turns)
                    }
                    guard turnStatus == SQLITE_DONE else { throw reader.db.error("Cannot read conversation turns") }
                }
                info.conversations += 1
                try contents.write("- [Conversation \(info.conversations)](\(member))\n")
                try progress(LibraryBackupProgress(phase:"Exporting conversations",completedItems:info.conversations,unit:"conversations"))
                status = sqlite3_step(sessions)
            }
            guard status == SQLITE_DONE else { throw reader.db.error("Cannot enumerate conversations") }
            try contents.write("\n\(info.memories) sources, \(info.conversations) conversations, \(info.turns) turns, \(info.mediaFiles) media files. Privacy excluded \(info.excludedMemories) sources and \(info.excludedTurns) dependent turns.\n")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        try output.tree.write(encoder.encode(info),as:"export.json")
        try progress(LibraryBackupProgress(phase:"Publishing Markdown export",completedItems:info.memories,totalItems:info.memories,unit:"sources"))
        try source.requireRootIdentity(at:store.root)
        try output.publish(as:destination)
        return info
    }
    private static func digest(_ id: String) -> String { BackupSHA256.hex(Data(id.utf8)) }
    private static func payload(_ row: OpaquePointer,_ column: Int32) throws -> Data {
        let size = Int(sqlite3_column_bytes(row,column))
        guard size > 0,size <= MemoryStore.maximumRecordBytes,let data = sqlite3_column_blob(row,column) else { throw OSwindError.invalid("Invalid export record size") }
        return Data(bytes:data,count:size)
    }
    private static func sanitized(_ original: Memory,policy: PrivacyPolicy) throws -> (Memory,Bool) {
        var memory = original, suppressed = false
        func clean(_ text: String) -> String { let value = policy.sanitize(text); suppressed = suppressed || value.redacted || text.contains("[REDACTED"); return value.text }
        memory.title = clean(original.title); memory.app = clean(original.app); memory.bundleID = clean(original.bundleID)
        memory.url = original.url.map(clean); memory.audioSessionID = original.audioSessionID.map(clean); memory.tags = original.tags.map(clean); memory.text = clean(original.text)
        if let transcript = original.transcript {
            guard transcript.text == original.text else { throw OSwindError.invalid("Transcript text differs from source") }
            let value = try transcript.sanitized(policy:policy); memory.transcript = value.transcript; memory.text = value.transcript.text; suppressed = suppressed || value.suppressAudio
            for segment in transcript.segments { _ = clean(segment.text); if let speaker = segment.speaker { _ = clean(speaker) } }
        }
        if let recording = original.visualRecording {
            guard recording.text == original.text else { throw OSwindError.invalid("Replay text differs from source") }
            memory.visualRecording = try recording.sanitized(policy:policy); memory.text = memory.visualRecording!.text
            for frame in recording.frames { for region in frame.regions { _ = clean(region.text) } }
        }
        return (memory,suppressed)
    }
    private static func seconds(_ value: Double) -> String { String(format:"%.3f s",locale:Locale(identifier:"en_US_POSIX"),value) }
    private static func json(_ value: Any) -> String { (try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys])).flatMap { String(data:$0,encoding:.utf8) } ?? "null" }
    /// YAML accepts JSON scalars. Escape Markdown syntax inside string values
    /// too, for readers that render front matter as ordinary Markdown text.
    private static func yaml(_ value: Any) -> String {
        if let strings = value as? [String] { return "["+strings.map { yaml($0) }.joined(separator:",")+"]" }
        guard let string = value as? String else { return json(value) }
        var result = json(string)
        for byte in "<>![]()*_`#&".utf8 {
            result = result.replacingOccurrences(of:String(UnicodeScalar(byte)),with:String(format:"\\u%04x",Int(byte)))
        }
        return result
    }
    private static func inline(_ text: String) -> String {
        let punctuation = Set("\\`*_{}[]<>()#+-.!|~=")
        return text.map { $0 == "\n" || $0 == "\r" ? " " : punctuation.contains($0) ? "\\"+String($0) : String($0) }.joined()
    }
    /// Literal blocks stop captured Markdown/HTML/Obsidian embeds executing in
    /// the reader. A bounded fence is used; pathological fences fall back to indent.
    private static func literal(_ text: String) -> String {
        var longest = 0, run = 0
        for byte in text.utf8 { if byte == 96 { run += 1; longest = max(longest,run) } else { run = 0 } }
        if longest >= 128 { return text.components(separatedBy:"\n").map { "    "+$0 }.joined(separator:"\n")+"\n\n" }
        let fence = String(repeating:"`",count:max(3,longest+1))
        return fence+"text\n"+text+"\n"+fence+"\n\n"
    }
}

private final class MarkdownSink {
    private let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    func write(_ text: String) throws {
        let data = Data(text.utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor,bytes.baseAddress!.advanced(by:offset),min(65536,bytes.count-offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw OSwindError.unavailable("Cannot write Markdown export") }; offset += count
            }
        }
    }
}
