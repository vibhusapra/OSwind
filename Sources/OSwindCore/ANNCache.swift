import Foundation
import CryptoKit
import Darwin

public struct SearchIndexStatus: Codable, Sendable {
    public var state: String
    public var message: String
    public var indexed: Int
    public var total: Int
    public var sequence: Int64
}
struct ANNManifest: Codable {
    var storeID: String
    var modelID: String
    var dimensions: Int
    var format: String
    var sequence: Int64
    var count: Int
    var graph: String
    var sha256: String
}
private final class IndexBuildLease {
    private var descriptor: Int32 = -1
    init?(_ url: URL) throws {
        let opened = open(url.path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard opened >= 0 else { throw OSwindError.unavailable("Cannot open the search index lock") }
        guard flock(opened,LOCK_EX | LOCK_NB) == 0 else { close(opened); return nil }
        descriptor = opened
    }
    deinit { if descriptor >= 0 { flock(descriptor,LOCK_UN); close(descriptor) } }
}
/// One active model per store keeps memory bounded when users change models.
/// The native graph is a cache. Journal replay and live SQL filters protect
/// against stale snapshots and other processes writing to the same store.
final class ANNCache: @unchecked Sendable {
    private final class Session {
        let native: any VectorSearchBackend
        let source: VectorIndexSource
        let modelID: String
        let identity: String
        var sequence: Int64
        var lastCheckpoint = Date()
        var checkpointSequence: Int64 = -1
        var lastQuery = Date()
        init(native: any VectorSearchBackend, source: VectorIndexSource, modelID: String, identity: String, sequence: Int64) {
            self.native = native; self.source = source; self.modelID = modelID; self.identity = identity; self.sequence = sequence
        }
    }
    private let root: URL
    private let lock = NSRecursiveLock()
    private var session: Session?
    private var job: Task<Void,Never>?
    private var generation = UUID()
    private var requested = ""
    private var activeIdentity = ""
    private var automaticBuildPaused = false
    private var attemptedLoad = false
    private var retryAfter = Date.distantPast
    private var currentStatus = SearchIndexStatus(state:"idle",message:"Search index has not been prepared",indexed:0,total:0,sequence:0)
    init(root: URL) { self.root = root }
    var status: SearchIndexStatus {
        guard lock.try() else { return SearchIndexStatus(state:"preparing",message:"Preparing the search index",indexed:0,total:0,sequence:0) }
        defer { lock.unlock() }; return currentStatus
    }
    private func completedStatus() -> SearchIndexStatus { lock.lock(); defer { lock.unlock() }; return currentStatus }
    private var directory: URL { root.appendingPathComponent("indexes",isDirectory:true) }
    private func ensureDirectory() throws {
        if let attrs = try? FileManager.default.attributesOfItem(atPath:directory.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw OSwindError.invalid("Search index directory cannot be a symbolic link") }
        try Paths.ensure(directory); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
    }
    private func prefix(identity: String, modelID: String, dimensions: Int, format: String) -> String {
        SHA256.hash(data:Data("\(identity)\n\(modelID)\n\(dimensions)\n\(format)".utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private func manifestURL(_ prefix: String) -> URL { directory.appendingPathComponent(prefix+".json") }
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }; var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let finished = try autoreleasepool { () throws -> Bool in
                guard let data = try handle.read(upToCount:4*1024*1024), !data.isEmpty else { return true }
                hash.update(data:data); return false
            }
            if finished { break }
        }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    private func graphURL(_ name: String, prefix: String) throws -> URL {
        guard name.hasPrefix(prefix+"-"), (name.hasSuffix(".usearch") || name.hasSuffix(".metal")), name == URL(fileURLWithPath:name).lastPathComponent, !name.contains("..") else { throw OSwindError.invalid("Invalid search index path") }
        let url = directory.appendingPathComponent(name)
        if let attrs = try? FileManager.default.attributesOfItem(atPath:url.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw OSwindError.invalid("Search index cannot be a symbolic link") }
        return url
    }
    private func load(source: VectorIndexSource, modelID: String, state: VectorSourceState) throws -> Session? {
        let format = VectorBackendFactory.format(dimensions:source.dimensions,count:try source.state().count)
        let key = prefix(identity:state.identity,modelID:modelID,dimensions:source.dimensions,format:format), manifest = manifestURL(key)
        guard FileManager.default.fileExists(atPath:manifest.path) else { return nil }
        try ensureDirectory()
        let decoded = try JSONDecoder().decode(ANNManifest.self,from:Data(contentsOf:manifest))
        guard decoded.storeID == state.identity, decoded.modelID == modelID, decoded.dimensions == source.dimensions, decoded.format == format, decoded.sequence <= state.head, decoded.sequence >= 0 else { throw OSwindError.invalid("Search index belongs to a different store or model version") }
        let file = try graphURL(decoded.graph,prefix:key)
        guard try digest(file) == decoded.sha256 else { throw OSwindError.invalid("Search index checksum mismatch; rebuild required") }
        let native = try VectorBackendFactory.make(dimensions:source.dimensions,format:format); try native.load(file)
        guard try native.count == decoded.count else { throw OSwindError.invalid("Search index count mismatch") }
        let loaded = Session(native:native,source:source,modelID:modelID,identity:state.identity,sequence:decoded.sequence)
        loaded.checkpointSequence = decoded.sequence; return loaded
    }
    private func catchUp(_ session: Session, deadline: Date? = nil) throws {
        let state = try session.source.state(includeCount:false)
        guard state.identity == session.identity else { throw OSwindError.unavailable("Memory store identity changed") }
        guard session.sequence < state.head else { return }
        repeat {
            let changes = try session.source.changes(after:session.sequence)
            try session.native.reserve(try session.native.count+changes.records.count+256)
            for record in changes.records { try session.native.remove(record.key) }
            try session.native.addBatch(changes.records)
            session.sequence = changes.sequence
            if changes.sequence >= changes.head { break }
            if let deadline, Date() >= deadline { break }
            try Task.checkCancellation()
        } while true
    }
    private func checkpoint(_ session: Session, leaseHeld: Bool = false) throws {
        try ensureDirectory()
        let key = prefix(identity:session.identity,modelID:session.modelID,dimensions:session.source.dimensions,format:session.native.indexFormat)
        var lease: IndexBuildLease?
        if !leaseHeld { lease = try IndexBuildLease(directory.appendingPathComponent(key+".lock")); guard lease != nil else { return } }
        defer { withExtendedLifetime(lease) {} }
        let state = try session.source.state(includeCount:false)
        guard state.identity == session.identity else { throw CancellationError() }
        let manifestFile = manifestURL(key)
        let previous = (try? Data(contentsOf:manifestFile)).flatMap { try? JSONDecoder().decode(ANNManifest.self,from:$0) }
        if let previous, previous.storeID == state.identity, previous.sequence > session.sequence, previous.sequence <= state.head { return }
        let graphName = key+"-"+UUID().uuidString+(session.native.indexFormat == MetalFlatIndex.format ? ".metal" : ".usearch"), file = try graphURL(graphName,prefix:key)
        var committed = false; defer { if !committed { try? FileManager.default.removeItem(at:file) } }
        try session.native.save(file); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let handle = try FileHandle(forWritingTo:file); try handle.synchronize(); try handle.close()
        let manifest = ANNManifest(storeID:session.identity,modelID:session.modelID,dimensions:session.source.dimensions,format:session.native.indexFormat,sequence:session.sequence,count:try session.native.count,graph:graphName,sha256:try digest(file))
        try Task.checkCancellation()
        guard try session.source.state(includeCount:false).identity == session.identity else { throw CancellationError() }
        try JSONEncoder().encode(manifest).write(to:manifestFile,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifestFile.path)
        committed = true; session.lastCheckpoint = Date(); session.checkpointSequence = session.sequence
        if let previous, previous.graph != graphName, let old = try? graphURL(previous.graph,prefix:key) { try? FileManager.default.removeItem(at:old) }
    }
    @discardableResult func prepare(modelID: String, dimensions: Int, count: Int, force: Bool = false, allowLowPower: Bool = false, replayAll: Bool = false, resumeBuild: Bool = false) -> SearchIndexStatus {
        lock.lock(); defer { lock.unlock() }
        let request = "\(modelID)\n\(dimensions)"
        if requested != request { generation = UUID(); job?.cancel(); job = nil; session = nil; attemptedLoad = false; requested = request; retryAfter = .distantPast; automaticBuildPaused = false }
        if resumeBuild { automaticBuildPaused = false; retryAfter = .distantPast }
        do {
            let source = try session?.source ?? VectorIndexSource(root:root,modelID:modelID,dimensions:dimensions)
            let state = try source.state(includeCount:false)
            if !activeIdentity.isEmpty && activeIdentity != state.identity { generation = UUID(); job?.cancel(); job = nil; self.session = nil; attemptedLoad = false; retryAfter = .distantPast }
            activeIdentity = state.identity
            if self.session == nil && job == nil && Date() >= retryAfter { attemptedLoad = false }
            if self.session == nil && !attemptedLoad {
                attemptedLoad = true
                do { self.session = try load(source:source,modelID:modelID,state:state) }
                catch { currentStatus = SearchIndexStatus(state:"rebuilding",message:"Index cache unavailable; rebuilding. Exact search remains available.",indexed:0,total:count,sequence:0) }
            }
            if let session = self.session {
                if IndexPowerPolicy.blockedReason(allowLowPower:allowLowPower) == nil { try catchUp(session,deadline:replayAll ? nil : Date().addingTimeInterval(0.15)) }
                if job == nil { currentStatus = SearchIndexStatus(state:"ready",message:"Indexed search ready",indexed:try session.native.count,total:count,sequence:session.sequence) }
            }
            if (force || self.session == nil), job == nil, force || Date() >= retryAfter {
                if automaticBuildPaused { currentStatus = SearchIndexStatus(state:"paused",message:"Fast index preparation paused; use Prepare fast retrieval to resume",indexed:0,total:count,sequence:0) }
                else if let reason = IndexPowerPolicy.blockedReason(allowLowPower:allowLowPower) { currentStatus = SearchIndexStatus(state:"deferred",message:reason,indexed:0,total:count,sequence:0) }
                else { startBuild(modelID:modelID,dimensions:dimensions,total:count,identity:state.identity,allowLowPower:allowLowPower) }
            }
        } catch is CancellationError {
            attemptedLoad = false; retryAfter = .distantPast
            currentStatus = SearchIndexStatus(state:"cancelled",message:"Search preparation cancelled",indexed:0,total:count,sequence:session?.sequence ?? 0)
        } catch {
            currentStatus = SearchIndexStatus(state:"failed",message:"Index unavailable; using exact search. "+error.localizedDescription,indexed:0,total:count,sequence:0)
            session = nil; retryAfter = Date().addingTimeInterval(30)
        }
        return currentStatus
    }
    private func startBuild(modelID: String, dimensions: Int, total: Int, identity: String, allowLowPower: Bool) {
        let token = generation, root = self.root
        currentStatus = SearchIndexStatus(state:"building",message:"Building fast search index",indexed:0,total:total,sequence:0)
        job = Task.detached(priority:.utility) { [self] in
            do {
                try ensureDirectory()
                let source = try VectorIndexSource(root:root,modelID:modelID,dimensions:dimensions), initial = try source.state()
                guard initial.identity == identity else { throw CancellationError() }
                let format = VectorBackendFactory.format(dimensions:dimensions,count:initial.count)
                let key = prefix(identity:identity,modelID:modelID,dimensions:dimensions,format:format)
                guard let lease = try IndexBuildLease(directory.appendingPathComponent(key+".lock")) else {
                    finish(token:token,status:SearchIndexStatus(state:"waiting",message:"Another process is building the search index",indexed:0,total:total,sequence:0),retry:2); return
                }
                defer { withExtendedLifetime(lease) {} }
                let native = try VectorBackendFactory.make(dimensions:dimensions,format:format); try native.reserve(initial.count+512)
                var cursor: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    if let reason = IndexPowerPolicy.blockedReason(allowLowPower:allowLowPower) { throw IndexBuildDeferred(reason:reason) }
                    guard try source.state(includeCount:false).identity == identity else { throw CancellationError() }
                    let page = try source.page(after:cursor,through:initial.highKey)
                    guard let last = page.last else { break }
                    try native.addBatch(page); cursor = last.key
                    update(token:token,indexed:try native.count,total:initial.count)
                }
                let built = Session(native:native,source:source,modelID:modelID,identity:identity,sequence:initial.head)
                try catchUp(built); try Task.checkCancellation(); try checkpoint(built,leaseHeld:true)
                publish(built,token:token,total:initial.count,count:try native.count)
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                let message = cancelled ? "Index build cancelled; source vectors are retained" : error is IndexBuildDeferred ? error.localizedDescription : "Index build failed: "+error.localizedDescription
                finish(token:token,status:SearchIndexStatus(state:cancelled ? "cancelled" : error is IndexBuildDeferred ? "deferred" : "failed",message:message,indexed:0,total:total,sequence:0),retry:30)
            }
        }
    }
    private func update(token: UUID, indexed: Int, total: Int) { lock.lock(); defer { lock.unlock() }; if token == generation { currentStatus.indexed = indexed; currentStatus.total = total } }
    private func publish(_ built: Session, token: UUID, total: Int, count: Int) {
        lock.lock(); defer { lock.unlock() }
        if token == generation && !Task.isCancelled { session = built; currentStatus = SearchIndexStatus(state:"ready",message:"Indexed search ready",indexed:count,total:total,sequence:built.sequence); job = nil }
    }
    private func finish(token: UUID, status: SearchIndexStatus, retry: Double) {
        lock.lock(); defer { lock.unlock() }; if token == generation { currentStatus = status; job = nil; retryAfter = Date().addingTimeInterval(retry); if status.state == "waiting" { attemptedLoad = false } }
    }
    func waitForBuild() async throws -> SearchIndexStatus {
        let task = pendingJob()
        await withTaskCancellationHandler { await task?.value } onCancel: { task?.cancel() }
        try Task.checkCancellation(); let state = completedStatus()
        guard state.state == "ready" else { throw OSwindError.unavailable(state.message) }; return state
    }
    private func pendingJob() -> Task<Void,Never>? { lock.lock(); defer { lock.unlock() }; return job }
    func withReady<T>(modelID: String, dimensions: Int, identity: String, snapshotHead: Int64, _ body: (any VectorSearchBackend,Int64) throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let session, session.modelID == modelID, session.source.dimensions == dimensions, session.identity == identity, session.sequence <= snapshotHead else { return nil }
        session.lastQuery = Date(); return try body(session.native,session.sequence)
    }
    func checkpointIfIdle(allowLowPower: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard job == nil, let session, IndexPowerPolicy.blockedReason(allowLowPower:allowLowPower) == nil, Date().timeIntervalSince(session.lastQuery) >= 30, Date().timeIntervalSince(session.lastCheckpoint) >= 60 else { return }
        try catchUp(session,deadline:Date().addingTimeInterval(0.15))
        if session.sequence > session.checkpointSequence { try checkpoint(session) }
    }
    func cancel(pauseAutomatic: Bool = false) {
        if lock.try() { if pauseAutomatic { automaticBuildPaused = true }; let task = job; lock.unlock(); task?.cancel() }
        else { DispatchQueue.global(qos:.utility).async { [weak self] in self?.cancelSynchronously(pauseAutomatic:pauseAutomatic) } }
    }
    private func cancelSynchronously(pauseAutomatic: Bool) { lock.lock(); if pauseAutomatic { automaticBuildPaused = true }; let task = job; lock.unlock(); task?.cancel() }
    func reset() { lock.lock(); defer { lock.unlock() }; generation = UUID(); job?.cancel(); job = nil; session = nil; requested = ""; activeIdentity = ""; attemptedLoad = false; retryAfter = .distantPast; currentStatus = SearchIndexStatus(state:"idle",message:"Search cache cleared",indexed:0,total:0,sequence:0) }
}
