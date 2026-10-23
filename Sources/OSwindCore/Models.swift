import Foundation

public enum MemoryKind: String, Codable, CaseIterable, Sendable { case screen, audio, note, summary }
public struct TextRegion: Codable, Equatable, Sendable {
    public var text: String
    public var x, y, width, height: Double
    public init(text: String, x: Double, y: Double, width: Double, height: Double) { self.text = text; self.x = x; self.y = y; self.width = width; self.height = height }
}
public struct Memory: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var timestamp: Date
    public var endTimestamp: Date?
    public var kind: MemoryKind
    public var app: String
    public var bundleID: String
    public var title: String
    public var url: String?
    public var text: String
    public var imagePath: String?
    public var audioPath: String?
    public var display: String?
    public var regions: [TextRegion]
    public var favorite: Bool
    public var tags: [String]
    public var embedding: [Float]?
    public var embeddingModel: String?
    public init(id: String = UUID().uuidString, timestamp: Date = Date(), endTimestamp: Date? = nil, kind: MemoryKind = .screen, app: String = "", bundleID: String = "", title: String = "", url: String? = nil, text: String, imagePath: String? = nil, audioPath: String? = nil, display: String? = nil, regions: [TextRegion] = [], favorite: Bool = false, tags: [String] = [], embedding: [Float]? = nil, embeddingModel: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.endTimestamp = endTimestamp; self.kind = kind; self.app = app; self.bundleID = bundleID; self.title = title; self.url = url; self.text = text; self.imagePath = imagePath; self.audioPath = audioPath; self.display = display; self.regions = regions; self.favorite = favorite; self.tags = tags; self.embedding = embedding; self.embeddingModel = embeddingModel
    }
    public var searchableText: String { [title, app, url ?? "", text].joined(separator: "\n") }
}
public enum SearchMode: String, Codable, CaseIterable { case hybrid, keyword, semantic }
public struct SearchFilter: Codable, Equatable, Sendable {
    public var query = ""
    public var app: String?
    public var kind: MemoryKind?
    public var start: Date?
    public var end: Date?
    public var favoritesOnly = false
    public var tag: String?
    public var limit = 100
    public init(query: String = "", app: String? = nil, kind: MemoryKind? = nil, start: Date? = nil, end: Date? = nil, favoritesOnly: Bool = false, tag: String? = nil, limit: Int = 100) { self.query = query; self.app = app; self.kind = kind; self.start = start; self.end = end; self.favoritesOnly = favoritesOnly; self.tag = tag; self.limit = limit }
}
public struct SearchHit: Identifiable, Codable, Sendable {
    public var memory: Memory
    public var score: Double
    public var match: String
    public var id: String { memory.id }
    public init(memory: Memory, score: Double, match: String) { self.memory = memory; self.score = score; self.match = match }
}
public struct StoreStats: Codable, Sendable {
    public var count: Int = 0
    public var screenshots: Int = 0
    public var audioSegments: Int = 0
    public var embedded: Int = 0
    public var bytes: Int64 = 0
    public var oldest: Date?
    public var newest: Date?
    public var apps: [String: Int] = [:]
    public init() {}
}
public enum OSwindError: LocalizedError {
    case database(String), invalid(String), unavailable(String), network(String)
    public var errorDescription: String? { switch self { case .database(let s), .invalid(let s), .unavailable(let s), .network(let s): return s } }
}
public enum Paths {
    public static var data: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OSwind", isDirectory: true) }
    public static func ensure(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
}
