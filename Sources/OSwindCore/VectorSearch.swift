import Foundation
import Accelerate

public struct SearchExecution: Sendable {
    public var strategy: String
    public var warnings: [String]
}

/// Reads SQLite-owned vector bytes synchronously; no pointer escapes sqlite3_step.
struct CosineScorer {
    private let query: [Float]
    var queryVector: [Float] { query }
    private let norm: Float
    init?(_ query: [Float]) {
        guard !query.isEmpty, query.allSatisfy(\.isFinite) else { return nil }
        var squared: Float = 0; vDSP_svesq(query,1,&squared,vDSP_Length(query.count))
        guard squared > 0, squared.isFinite else { return nil }; self.query = query; norm = sqrt(squared)
    }
    func score(_ stored: UnsafePointer<Float>, count: Int) -> Double {
        guard count == query.count else { return -.infinity }
        var dot: Float = 0, squared: Float = 0
        vDSP_dotpr(query,1,stored,1,&dot,vDSP_Length(count)); vDSP_svesq(stored,1,&squared,vDSP_Length(count))
        guard squared > 0, squared.isFinite, dot.isFinite else { return -.infinity }
        return Double(dot / (norm * sqrt(squared)))
    }
}
struct SemanticCandidate {
    var id: String
    var similarity: Double
    var timestamp: Double
    var passage: PassageRange? = nil
    var visual:VisualMatch? = nil
    static func better(_ a: Self, _ b: Self) -> Bool {
        if a.similarity != b.similarity { return a.similarity > b.similarity }
        if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
        return a.id < b.id
    }
}
/// A min heap keeps only the requested candidates. The root is the worst item.
struct SemanticTopK {
    private(set) var heap = [SemanticCandidate]()
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity }
    func mayImprove(_ similarity: Double) -> Bool { capacity > 0 && (heap.count < capacity || similarity >= heap[0].similarity) }
    private var positions = [String:Int]()
    private mutating func swap(_ a: Int,_ b: Int) { heap.swapAt(a,b); positions[heap[a].id] = a; positions[heap[b].id] = b }
    private mutating func sink(_ first: Int) {
        var parent = first
        while parent*2+1 < heap.count {
            let left = parent*2+1, right = left+1
            let child = right < heap.count && SemanticCandidate.better(heap[left],heap[right]) ? right : left
            guard SemanticCandidate.better(heap[parent],heap[child]) else { break }
            swap(parent,child); parent = child
        }
    }
    mutating func offer(_ item: SemanticCandidate) {
        guard capacity > 0 else { return }
        if let index = positions[item.id] {
            guard SemanticCandidate.better(item,heap[index]) else { return }
            heap[index] = item; sink(index); return
        }
        if heap.count < capacity {
            heap.append(item); var child = heap.count-1; positions[item.id] = child
            while child > 0 {
                let parent = (child-1)/2
                guard SemanticCandidate.better(heap[parent],heap[child]) else { break }
                swap(parent,child); child = parent
            }
        } else if SemanticCandidate.better(item,heap[0]) {
            positions.removeValue(forKey:heap[0].id); heap[0] = item; positions[item.id] = 0; sink(0)
        }
    }
    var sorted: [SemanticCandidate] { heap.sorted(by:SemanticCandidate.better) }
}
