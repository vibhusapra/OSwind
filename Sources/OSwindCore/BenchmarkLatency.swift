import Foundation

/// Explicit estimators keep small benchmark samples from hiding the slowest
/// observation behind a lower array index labeled p95.
public struct BenchmarkLatency {
    public static let method = "median averages the center pair; p95 is nearest rank ceil(0.95*n); max includes every sample"
    public let median: Double
    public let p95: Double
    public let maximum: Double
    public init(samples: [Double]) throws {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw OSwindError.invalid("Latency samples must be nonempty, finite and nonnegative") }
        let ordered = samples.sorted(), middle = ordered.count/2
        median = ordered.count%2 == 0 ? ordered[middle-1]/2+ordered[middle]/2 : ordered[middle]
        p95 = ordered[max(0,Int(ceil(0.95*Double(ordered.count)))-1)]
        maximum = ordered.last!
    }
}
