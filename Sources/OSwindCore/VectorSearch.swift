import Foundation
import Accelerate

/// Reads SQLite-owned vector bytes synchronously; no pointer escapes sqlite3_step.
struct CosineScorer {
    private let query: [Float]
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
    func mayImprove(_ similarity: Double) -> Bool { capacity > 0 && (heap.count < capacity || similarity >= heap[0].similarity) }
    mutating func offer(_ item: SemanticCandidate) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(item); var child = heap.count-1
            while child > 0 {
                let parent = (child-1)/2
                guard SemanticCandidate.better(heap[parent],heap[child]) else { break }
                heap.swapAt(parent,child); child = parent
            }
        } else if SemanticCandidate.better(item,heap[0]) {
            heap[0] = item; var parent = 0
            while parent*2+1 < heap.count {
                let left = parent*2+1, right = left+1
                let child = right < heap.count && SemanticCandidate.better(heap[left],heap[right]) ? right : left
                guard SemanticCandidate.better(heap[parent],heap[child]) else { break }
                heap.swapAt(parent,child); parent = child
            }
        }
    }
    var sorted: [SemanticCandidate] { heap.sorted(by:SemanticCandidate.better) }
}
