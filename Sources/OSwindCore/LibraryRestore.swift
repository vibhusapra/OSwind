import Foundation
import CSQLite

private final class RestoreContentIndex {
    let db: BackupDatabase
    init(_ url: URL) throws {
        db = try BackupDatabase(url,createPrivate:true)
        try db.execute("CREATE TABLE sources(id TEXT PRIMARY KEY,hash TEXT NOT NULL); BEGIN IMMEDIATE;")
    }
    func close() { db.close() }
    func record(_ memory: Memory) throws {
        let statement = try db.prepare("INSERT INTO sources(id,hash) VALUES(?,?)"); defer { sqlite3_finalize(statement) }
        db.bind(statement,1,memory.id); db.bind(statement,2,memory.contentHash)
        guard sqlite3_step(statement)==SQLITE_DONE else { throw BackupFileError.invalid("Duplicate restored source identifier") }
    }
    func hash(_ id: String) throws -> String {
        let statement = try db.prepare("SELECT hash FROM sources WHERE id=?"); defer { sqlite3_finalize(statement) }; db.bind(statement,1,id)
        guard sqlite3_step(statement)==SQLITE_ROW else { throw BackupFileError.invalid("Restored vector references a missing source") }; return try db.text(statement,0)
    }
}
private final class RestoreRows {
    let source: BackupDataReader
    let destination: MemoryStore
    let index: BackupManifestIndex
    let hashes: RestoreContentIndex
    var lastMemory: Memory?
    var lastRanges = [PassageRange]()
    init(source: BackupDataReader, destination: MemoryStore, index: BackupManifestIndex, hashes: RestoreContentIndex) { self.source = source; self.destination = destination; self.index = index; self.hashes = hashes }
    func mappedPath(_ path: String?) throws -> String? {
        guard let path else { return nil }
        guard let entry = try index.entry(for:path) else { throw BackupFileError.invalid("Restored source references missing media") }
        let prefix = path.split(separator:"/")[0], extensionPart = (path as NSString).pathExtension
        let suffix = !extensionPart.isEmpty && extensionPart.count<=12 && extensionPart.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) ? "."+extensionPart : ""
        return String(prefix)+"/restored-"+entry.member.dropFirst(6)+suffix
    }
    func optionalText(_ row: OpaquePointer,_ column: Int32) throws -> String? { sqlite3_column_type(row,column)==SQLITE_NULL ? nil : try source.db.text(row,column) }
    func number(_ row: OpaquePointer,_ column: Int32) throws -> Double {
        let kind = sqlite3_column_type(row,column), value = sqlite3_column_double(row,column)
        guard (kind==SQLITE_FLOAT || kind==SQLITE_INTEGER) && value.isFinite else { throw BackupFileError.invalid("Invalid numeric backup field") }; return value
    }
    func integer(_ row: OpaquePointer,_ column: Int32) throws -> Int64 {
        guard sqlite3_column_type(row,column)==SQLITE_INTEGER else { throw BackupFileError.invalid("Invalid integer backup field") }; return sqlite3_column_int64(row,column)
    }
    func payload(_ row: OpaquePointer,_ column: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(row,column))
        guard count>0, count<=MemoryStore.maximumRecordBytes, let bytes = sqlite3_column_blob(row,column) else { throw BackupFileError.invalid("Invalid or oversized backup payload") }
        return Data(bytes:bytes,count:count)
    }
    func vector(_ row: OpaquePointer,_ column: Int32, dimension: Int? = nil) throws -> [Float] {
        let bytes = Int(sqlite3_column_bytes(row,column)), count = bytes/4
        guard sqlite3_column_type(row,column)==SQLITE_BLOB, bytes>0, bytes%4==0, count<=8192, dimension.map({$0==count}) ?? true, let pointer = sqlite3_column_blob(row,column) else { throw BackupFileError.invalid("Invalid restored vector shape") }
        let result = Array(UnsafeBufferPointer(start:pointer.assumingMemoryBound(to:Float.self),count:count))
        guard result.allSatisfy(\.isFinite) else { throw BackupFileError.invalid("Invalid restored vector values") }; return result
    }
    func rows(_ table: String, columns: String, _ body: (OpaquePointer) throws -> Void) throws -> Int64 {
        let allowed = ["memories","semantic_vectors","semantic_passages","passage_manifests","chat_sessions","chat_turns","chat_sources","routines","routine_runs"]
        guard allowed.contains(table) else { throw BackupFileError.invalid("Unsupported restore table") }
        let statement = try source.db.prepare("SELECT \(columns) FROM \(table) NOT INDEXED ORDER BY rowid"); defer { sqlite3_finalize(statement) }
        var count: Int64 = 0, status = sqlite3_step(statement)
        while status==SQLITE_ROW { try Task.checkCancellation(); try body(statement); count = try BackupMath.add(count,1); status = sqlite3_step(statement) }
        guard status==SQLITE_DONE else { try Task.checkCancellation(); throw source.db.error("Cannot read backup data rows") }; return count
    }
    func cachedMemory(_ id: String) throws -> Memory {
        if let lastMemory, lastMemory.id==id { return lastMemory }
        guard let memory = try destination.get(id) else { throw BackupFileError.invalid("Backup references a missing source") }
        lastMemory = memory; lastRanges = SemanticPassagePlan.make(memory).map(\.range); return memory
    }
    func memories(_ progress: (Int64) throws -> Void) throws -> Int64 {
        var count: Int64 = 0
        return try rows("memories",columns:"id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model") { row in
            var memory = try JSONDecoder().decode(Memory.self,from:self.payload(row,8))
            guard !memory.id.isEmpty, memory.id.count<200, memory.text.count<=1_000_000,
                  memory.id == (try self.source.db.text(row,0)), memory.timestamp.timeIntervalSince1970 == (try self.number(row,1)), memory.kind.rawValue == (try self.source.db.text(row,2)),
                  memory.app == (try self.source.db.text(row,3)), memory.title == (try self.source.db.text(row,4)), memory.url == (try self.optionalText(row,5)), memory.text == (try self.source.db.text(row,6)),
                  (try self.integer(row,7)) == (memory.favorite ? 1 : 0), memory.embeddingModel == (try self.optionalText(row,10)) else { throw BackupFileError.invalid("Source payload and database metadata differ") }
            memory.imagePath = try self.mappedPath(memory.imagePath); memory.audioPath = try self.mappedPath(memory.audioPath);memory.videoPath=try self.mappedPath(memory.videoPath)
            memory.embedding = sqlite3_column_type(row,9)==SQLITE_NULL ? nil : try self.vector(row,9)
            try self.hashes.record(memory); try self.destination.insert(memory)
            count = try BackupMath.add(count,1); if count%64==0 { try progress(count) }
        }
    }
    func copy(_ table: String, columns: [String], into handle: OpaquePointer,
              validate: (OpaquePointer) throws -> Void, afterBind: (OpaquePointer,OpaquePointer) throws -> Void = {_,_ in}, progress: (Int64) throws -> Void = { _ in }) throws -> Int64 {
        let list = columns.joined(separator:","), sql = "INSERT INTO \(table)(\(list)) VALUES("+Array(repeating:"?",count:columns.count).joined(separator:",")+")"
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(handle,sql,-1,&insert,nil)==SQLITE_OK else { throw OSwindError.database("Cannot prepare trusted restore table") }; defer { sqlite3_finalize(insert) }
        var count: Int64 = 0
        return try rows(table,columns:list) { row in
            try validate(row); sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            for column in columns.indices { guard sqlite3_bind_value(insert,Int32(column+1),sqlite3_column_value(row,Int32(column)))==SQLITE_OK else { throw OSwindError.database("Cannot bind restored data") } }
            try afterBind(row,insert!)
            guard sqlite3_step(insert)==SQLITE_DONE else { throw BackupFileError.invalid("Backup data violates the current library schema") }
            count = try BackupMath.add(count,1); if count%64==0 { try progress(count) }
        }
    }
    func restore(into handle: OpaquePointer, progress: (LibraryBackupProgress) throws -> Void) throws {
        _ = try memories { try progress(LibraryBackupProgress(phase:"Restoring sources",completedItems:$0,unit:"records")) }
        _ = try copy("semantic_vectors",columns:["memory_id","model","dimension","vector","content_hash"],into:handle,validate:{ row in
            let id = try self.source.db.text(row,0), hash = try self.source.db.text(row,4), dimension = try self.integer(row,2)
            guard (1...8192).contains(dimension), hash == (try self.hashes.hash(id)) else { throw BackupFileError.invalid("Restored vector source hash differs") }
            _ = try self.vector(row,3,dimension:Int(dimension)); _ = try self.source.db.text(row,1)
        },progress:{ try progress(LibraryBackupProgress(phase:"Restoring search vectors",completedItems:$0,unit:"vectors")) })
        _ = try copy("semantic_passages",columns:["memory_id","model","ordinal","start","length","dimension","vector"],into:handle,validate:{ row in
            let id = try self.source.db.text(row,0), model = try self.source.db.text(row,1), ordinal = try self.integer(row,2), start = try self.integer(row,3), length = try self.integer(row,4), dimension = try self.integer(row,5)
            _ = try self.cachedMemory(id)
            guard ordinal>0, ordinal<=self.lastRanges.count, (1...8192).contains(dimension), start>=0,length>0,
                  self.lastRanges[Int(ordinal)-1]==PassageRange(start:Int(start),length:Int(length)) else { throw BackupFileError.invalid("Restored passage range differs from its source") }
            _ = try self.vector(row,6,dimension:Int(dimension))
            var base: OpaquePointer?
            let sql = "SELECT length(COALESCE(v.vector,CASE WHEN m.embedding_model=? THEN m.embedding END))/4 FROM memories m LEFT JOIN semantic_vectors v ON v.memory_id=m.id AND v.model=? WHERE m.id=?"
            guard sqlite3_prepare_v2(handle,sql,-1,&base,nil)==SQLITE_OK else { throw OSwindError.database("Cannot check passage source vector") }; defer { sqlite3_finalize(base) }
            let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
            for (i,value) in [model,model,id].enumerated() { sqlite3_bind_text64(base,Int32(i+1),value,UInt64(value.utf8.count),transient,UInt8(SQLITE_UTF8)) }
            guard sqlite3_step(base)==SQLITE_ROW, sqlite3_column_int64(base,0)==dimension else { throw BackupFileError.invalid("Restored passage lacks a compatible base vector") }
        })
        _ = try copy("passage_manifests",columns:["memory_id","model","content_hash","version","count"],into:handle,validate:{ row in
            let id = try self.source.db.text(row,0), model = try self.source.db.text(row,1), hash = try self.source.db.text(row,2), version = try self.integer(row,3), count = try self.integer(row,4)
            _ = try self.cachedMemory(id)
            guard version==SemanticPassagePlan.version, count==self.lastRanges.count, hash == (try self.hashes.hash(id)) else { throw BackupFileError.invalid("Unsupported or incomplete restored passage manifest") }
            var statement: OpaquePointer?; guard sqlite3_prepare_v2(handle,"SELECT COUNT(*) FROM semantic_passages WHERE memory_id=? AND model=?",-1,&statement,nil)==SQLITE_OK else { throw OSwindError.database("Cannot inspect restored passages") }; defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self); sqlite3_bind_text64(statement,1,id,UInt64(id.utf8.count),transient,UInt8(SQLITE_UTF8)); sqlite3_bind_text64(statement,2,model,UInt64(model.utf8.count),transient,UInt8(SQLITE_UTF8))
            guard sqlite3_step(statement)==SQLITE_ROW, sqlite3_column_int64(statement,0)==count else { throw BackupFileError.invalid("Restored passage count differs") }
        })
        _ = try copy("chat_sessions",columns:["id","title","created","updated"],into:handle,validate:{ row in
            for column: Int32 in [0,1] { _ = try self.source.db.text(row,column) }; _ = try self.number(row,2); _ = try self.number(row,3)
        })
        _ = try copy("chat_turns",columns:["id","session_id","timestamp","payload"],into:handle,validate:{ row in
            _ = try self.source.db.text(row,0); _ = try self.source.db.text(row,1); _ = try self.number(row,2)
            let payload = try JSONDecoder().decode(ChatPayload.self,from:self.payload(row,3))
            guard !payload.question.isEmpty, payload.question.count<=8000, payload.text.count<=100000,payload.duration.isFinite else { throw BackupFileError.invalid("Invalid restored conversation payload") }
        })
        _ = try copy("chat_sources",columns:["turn_id","memory_id","ordinal","score","match","passage_start","passage_length"],into:handle,validate:{ row in
            _ = try self.source.db.text(row,0); let id = try self.source.db.text(row,1), memory = try self.cachedMemory(id), ordinal = try self.integer(row,2)
            guard (0..<60).contains(ordinal) else { throw BackupFileError.invalid("Invalid restored source ordinal") }; _ = try self.number(row,3); _ = try self.source.db.text(row,4)
            let startNull = sqlite3_column_type(row,5)==SQLITE_NULL, lengthNull = sqlite3_column_type(row,6)==SQLITE_NULL
            guard startNull==lengthNull else { throw BackupFileError.invalid("Incomplete restored evidence anchor") }
            if !startNull { let start = try self.integer(row,5), length = try self.integer(row,6); guard start>=0,length>0, PassageRange(start:Int(start),length:Int(length)).text(in:memory.text) != nil else { throw BackupFileError.invalid("Invalid restored evidence anchor") } }
        },progress:{ try progress(LibraryBackupProgress(phase:"Restoring conversations",completedItems:$0,unit:"sources")) })
        if source.schema>=13 {
            _ = try copy("routines",columns:["id","revision","enabled","next_due","payload"],into:handle,validate:{ row in
                let id=try self.source.db.text(row,0),revision=try self.integer(row,1),enabled=try self.integer(row,2)
                let definition=try JSONDecoder().decode(RoutineDefinition.self,from:self.payload(row,4));_ = try definition.validated()
                guard id==definition.id,revision>0,revision<Int64.max,enabled==(definition.enabled ? 1:0) else {throw BackupFileError.invalid("Invalid restored routine definition")}
                try RoutineDefinition.validateDate(Date(timeIntervalSince1970:self.number(row,3)))
            })
            _ = try copy("routine_runs",columns:["id","routine_id","revision","scheduled_at","started","finished","trigger","status","chat_id","message","scope"],into:handle,validate:{ row in
                for column:Int32 in [0,1] {let value=try self.source.db.text(row,column);guard !value.isEmpty,value.utf8.count<=128 else {throw BackupFileError.invalid("Invalid routine run identifier")}}
                guard try self.integer(row,2)>0,RoutineTrigger(rawValue:try self.source.db.text(row,6)) != nil,RoutineRunStatus(rawValue:try self.source.db.text(row,7)) != nil else {throw BackupFileError.invalid("Invalid routine run state")}
                for column:Int32 in [3,4] {try RoutineDefinition.validateDate(Date(timeIntervalSince1970:self.number(row,column)))}
                if sqlite3_column_type(row,5) != SQLITE_NULL {_ = try self.number(row,5)}
                if let message=try self.optionalText(row,9) {guard message.utf8.count<=2000 else {throw BackupFileError.invalid("Oversized routine message")}}
                let scope=try JSONDecoder().decode(SearchFilter.self,from:self.payload(row,10))
                guard scope.query.isEmpty,let start=scope.start,let end=scope.end,start<=end else {throw BackupFileError.invalid("Invalid routine scope")}
                try RoutineDefinition.validateDate(start);try RoutineDefinition.validateDate(end)
            },afterBind:{row,insert in
                if try self.source.db.text(row,7)=="running" {
                    let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
                    sqlite3_bind_text(insert,8,"interrupted",-1,transient);sqlite3_bind_double(insert,6,Date().timeIntervalSince1970)
                    sqlite3_bind_text(insert,10,"Restored interrupted run; automatic execution stays off.",-1,transient)
                }
            })
        }

    }
}

extension LibraryBackup {
    @discardableResult public static func restore(_ archive: URL, to destination: URL, expectedFingerprint: String? = nil,
                                                  progress: (LibraryBackupProgress) throws -> Void = { _ in }) throws -> LibraryBackupInfo {
        try BackupWorkspace.requireNewDestination(destination)
        _ = try BackupWorkspace.cleanupAbandoned()
        _ = try BackupWorkspace.cleanupAbandoned(in:destination.deletingLastPathComponent())
        let checked = try inspect(archive,progress:progress), source = try BackupFileTree(root:archive), parent = try BackupFileTree(root:destination.deletingLastPathComponent())
        guard try !source.isAncestor(of:parent) else { throw BackupFileError.invalid("Restore outside the backup package") }
        let headerData = try source.read("header.json",limit:65536), fingerprint = BackupSHA256.hex(headerData)
        guard fingerprint == (expectedFingerprint ?? checked.archiveFingerprint) else { throw BackupFileError.changed("Backup changed after inspection") }
        let header = try JSONDecoder().decode(LibraryBackupHeader.self,from:headerData); try header.validate()
        let scratch = try BackupWorkspace(label:"oswind-restore-input"), output = try BackupWorkspace(in:destination.deletingLastPathComponent(),label:"oswind-restore-partial")
        defer { withExtendedLifetime(scratch) {} }
        let index = try BackupManifestIndex(scratch.url.appendingPathComponent("manifest-index.sqlite")), hashes = try RestoreContentIndex(scratch.url.appendingPathComponent("content-index.sqlite"))
        defer { index.close(); hashes.close(); withExtendedLifetime(scratch) {} }
        try index.load(from:source,expectedCount:header.info.mediaFiles,expectedDigest:header.manifest)
        _ = try source.pin("memory.sqlite",to:scratch.tree,as:"memory.sqlite")
        guard try scratch.tree.digest("memory.sqlite")==header.database else { throw BackupFileError.changed("Backup database changed after inspection") }
        let reader = try BackupDataReader(scratch.url.appendingPathComponent("memory.sqlite")); defer { reader.close() }
        let target = try MemoryStore(root:output.url); defer { target.discardRestoreConnection() }
        let rows = RestoreRows(source:reader,destination:target,index:index,hashes:hashes)
        var completed: Int64 = 0
        try index.forEachActive { pending in
            guard let entry = try index.entry(for:pending.sourcePath), let path = try rows.mappedPath(pending.sourcePath) else { throw BackupFileError.invalid("Missing restore media mapping") }
            _ = try source.pin(entry.member,to:output.tree,as:path) { bytes in try progress(LibraryBackupProgress(phase:"Restoring media",completedItems:completed,totalItems:header.info.mediaFiles,copiedBytes:bytes)) }
            guard try output.tree.digest(path)==BackupFileDigest(bytes:entry.bytes,sha256:entry.sha256) else { throw BackupFileError.changed("Backup media changed after inspection") }
            completed = try BackupMath.add(completed,1)
        }
        try target.withRestoreTransaction { handle in try rows.restore(into:handle,progress:progress) }
        let verify = try BackupDataReader(output.url.appendingPathComponent("memory.sqlite"))
        let counts = try verify.counts(); verify.close()
        guard counts.0==header.info.memories, counts.1==header.info.conversations, counts.2==header.info.turns else { throw BackupFileError.invalid("Restored library counts differ") }
        let settingsData = try source.read("settings.json",limit:1_048_576)
        let settingsDigest = BackupFileDigest(bytes:Int64(settingsData.count),sha256:BackupSHA256.hex(settingsData))
        guard settingsDigest==header.settings else { throw BackupFileError.changed("Backup settings changed after inspection") }
        let settings = quietSettings(try JSONDecoder().decode(AppSettings.self,from:settingsData)); try settings.save(root:output.url)
        try target.sealRestoredLibrary()
        try progress(LibraryBackupProgress(phase:"Publishing restored library",completedItems:completed,totalItems:header.info.mediaFiles))
        try output.publish(as:destination)
        var result = header.info; result.archiveFingerprint = fingerprint; return result
    }
}
