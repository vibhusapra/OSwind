import Foundation
import USearchC

/// Owns a mutable native HNSW index. All calls are serialized by its owning cache.
/// The original float32 vectors stay in SQLite for exact candidate reranking.
final class NativeANN {
    static let format = "usearch-2.26.5-f16-cos-m32-passages-v2"
    private let handle: usearch_index_t
    let dimensions: Int
    init(dimensions: Int, expansion: Int = 8192) throws {
        guard (1...8192).contains(dimensions) else { throw OSwindError.invalid("Invalid index dimensions") }
        self.dimensions = dimensions
        var options = usearch_init_options_t(metric_kind:usearch_metric_cos_k,metric:nil,quantization:usearch_scalar_f16_k,dimensions:dimensions,connectivity:32,expansion_add:128,expansion_search:expansion,multi:false)
        var error: usearch_error_t?
        guard let index = usearch_init(&options,&error) else { throw Self.failure(error) }
        if let error { var cleanup: usearch_error_t?; usearch_free(index,&cleanup); throw Self.failure(error) }
        handle = index
    }
    deinit { var error: usearch_error_t?; usearch_free(handle,&error) }
    private static func failure(_ error: usearch_error_t?) -> OSwindError { .unavailable("Search index: " + (error.map { String(cString:$0) } ?? "unknown native error")) }
    private func check(_ error: usearch_error_t?) throws { if let error { throw Self.failure(error) } }
    var count: Int { get throws { var error: usearch_error_t?; let value = usearch_size(handle,&error); try check(error); return value } }
    func reserve(_ count: Int) throws { var error: usearch_error_t?; usearch_reserve(handle,max(16,count),&error); try check(error) }
    func setExpansion(_ expansion: Int) throws { var error: usearch_error_t?; usearch_change_expansion_search(handle,max(64,expansion),&error); try check(error) }
    func remove(_ key: UInt64) throws { var error: usearch_error_t?; _ = usearch_remove(handle,key,&error); try check(error) }
    func add(_ key: UInt64, vector: [Float]) throws {
        guard vector.count == dimensions, CosineScorer(vector) != nil else { throw OSwindError.invalid("Invalid index vector") }
        let normalized = LocalEmbedder.normalized(vector)
        var error: usearch_error_t?
        normalized.withUnsafeBufferPointer { usearch_add(handle,key,$0.baseAddress!,usearch_scalar_f32_k,&error) }; try check(error)
    }
    /// Used only while building an unpublished index, after reserving capacity.
    /// USearch supports concurrent insertions; each call has its own error slot.
    func addBatch(_ records: [IndexedVector], threads: Int = 4) throws {
        let workers = max(1,min(threads,max(1,ProcessInfo.processInfo.activeProcessorCount/2),records.count)), errorLock = NSLock(); var firstError: Error?
        var error: usearch_error_t?; usearch_change_threads_add(handle,workers,&error); try check(error)
        DispatchQueue.concurrentPerform(iterations:workers) { worker in
            do { for i in stride(from:worker,to:records.count,by:workers) { if let vector = records[i].vector { try self.add(records[i].key,vector:vector) } } }
            catch { errorLock.lock(); if firstError == nil { firstError = error }; errorLock.unlock() }
        }
        if let firstError { throw firstError }
    }
    private final class FilterBox { let include: (UInt64) -> Bool; init(_ include: @escaping (UInt64) -> Bool) { self.include = include } }
    func search(_ vector: [Float], count: Int, include: @escaping (UInt64) -> Bool) throws -> [UInt64] {
        guard vector.count == dimensions, CosineScorer(vector) != nil else { throw OSwindError.invalid("Invalid index query") }
        let normalized = LocalEmbedder.normalized(vector)
        let limit = min(2000,max(1,count)); var keys = [UInt64](repeating:0,count:limit), distances = [Float](repeating:0,count:limit), error: usearch_error_t?
        let box = FilterBox(include)
        let found = withExtendedLifetime(box) { normalized.withUnsafeBufferPointer { query in
            usearch_filtered_search(handle,query.baseAddress!,usearch_scalar_f32_k,limit,{ key,state in
                guard let state else { return 0 }; return Unmanaged<FilterBox>.fromOpaque(state).takeUnretainedValue().include(key) ? 1 : 0
            },Unmanaged.passUnretained(box).toOpaque(),&keys,&distances,&error)
        } }; try check(error); return Array(keys.prefix(Int(found)))
    }
    func search(_ vector: [Float], count: Int) throws -> [UInt64] {
        guard vector.count == dimensions, CosineScorer(vector) != nil else { throw OSwindError.invalid("Invalid index query") }
        let normalized = LocalEmbedder.normalized(vector)
        let limit = min(2000,max(1,count)); var keys = [UInt64](repeating:0,count:limit), distances = [Float](repeating:0,count:limit), error: usearch_error_t?
        let found = normalized.withUnsafeBufferPointer { usearch_search(handle,$0.baseAddress!,usearch_scalar_f32_k,limit,&keys,&distances,&error) }
        try check(error); return Array(keys.prefix(Int(found)))
    }
    func save(_ url: URL) throws { var error: usearch_error_t?; url.path.withCString { usearch_save(handle,$0,&error) }; try check(error) }
    func load(_ url: URL) throws {
        var error: usearch_error_t?; url.path.withCString { usearch_load(handle,$0,&error) }; try check(error)
        let actual = usearch_dimensions(handle,&error); try check(error)
        guard actual == dimensions else { throw OSwindError.invalid("Search index dimensions do not match the selected model") }
    }
}
