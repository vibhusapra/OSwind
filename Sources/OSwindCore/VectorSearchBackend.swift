import Foundation

/// Disposable candidate engines. SQLite remains the source of truth and reranks
/// every returned key using the original float32 vector and current SQL scope.
protocol VectorSearchBackend: AnyObject {
    var dimensions: Int { get }
    var count: Int { get throws }
    var indexFormat: String { get }
    var strategy: String { get }
    func reserve(_ count: Int) throws
    func remove(_ key: UInt64) throws
    func addBatch(_ records: [IndexedVector], threads: Int) throws
    func search(_ vector: [Float], count: Int) throws -> [UInt64]
    func search(_ vector: [Float], count: Int, include: @escaping (UInt64) -> Bool) throws -> [UInt64]
    func save(_ url: URL) throws
    func load(_ url: URL) throws
}
extension VectorSearchBackend {
    func addBatch(_ records: [IndexedVector]) throws { try addBatch(records,threads:4) }
}
extension NativeANN: VectorSearchBackend {
    var indexFormat: String { Self.format }
    var strategy: String { "ann-exact-rerank" }
}
enum VectorBackendFactory {
    static func format(dimensions: Int, count: Int) -> String {
        count >= 20_000 && MetalFlatIndex.canFit(dimensions:dimensions,count:count+512) ? MetalFlatIndex.format : NativeANN.format
    }
    static func make(dimensions: Int, format: String) throws -> any VectorSearchBackend {
        if format == MetalFlatIndex.format { return try MetalFlatIndex(dimensions:dimensions) }
        guard format == NativeANN.format else { throw OSwindError.invalid("Unknown search index format") }
        return try NativeANN(dimensions:dimensions)
    }
}
