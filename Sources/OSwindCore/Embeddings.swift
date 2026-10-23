import Foundation
import NaturalLanguage
import Accelerate

public final class LocalEmbedder {
    private let model: NLEmbedding?
    private let lock = NSLock()
    public let modelID = "apple-nl-sentence-en-v1"
    public var available: Bool { model != nil }
    public init() { model = NLEmbedding.sentenceEmbedding(for: .english) }
    public func embed(_ text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let model, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Bound ingestion cost. Sentence vectors are normalized after pooling text windows.
        let chars = Array(text.prefix(6000)); var sum = [Float](repeating: 0, count: model.dimension); var count = 0
        for start in stride(from: 0, to: chars.count, by: 700) {
            let part = String(chars[start..<min(start + 900, chars.count)])
            guard let vector = model.vector(for: part) else { continue }
            for i in vector.indices { sum[i] += Float(vector[i]) }; count += 1
        }
        guard count > 0 else { return nil }; return Self.normalized(sum)
    }
    public static func normalized(_ vector: [Float]) -> [Float] {
        var norm: Float = 0; vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count)); guard norm > 0 else { return vector }; var divisor = sqrt(norm); var out = vector; vDSP_vsdiv(vector, 1, &divisor, &out, 1, vDSP_Length(vector.count)); return out
    }
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty && a.count == b.count else { return 0 }
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count)); vDSP_svesq(a, 1, &aa, vDSP_Length(a.count)); vDSP_svesq(b, 1, &bb, vDSP_Length(b.count))
        return aa > 0 && bb > 0 ? Double(dot / sqrt(aa * bb)) : 0
    }
}
