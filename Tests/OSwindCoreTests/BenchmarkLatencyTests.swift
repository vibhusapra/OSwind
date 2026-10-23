import XCTest
@testable import OSwindCore

final class BenchmarkLatencyTests: XCTestCase {
    func testSmallSampleTailRetainsTheSlowestObservation() throws {
        let five = try BenchmarkLatency(samples:[1,2,3,4,100])
        XCTAssertEqual(five.median,3); XCTAssertEqual(five.p95,100); XCTAssertEqual(five.maximum,100)
        let even = try BenchmarkLatency(samples:[100,0])
        XCTAssertEqual(even.median,50); XCTAssertEqual(even.p95,100)
        let twenty = try BenchmarkLatency(samples:(1...20).map(Double.init))
        XCTAssertEqual(twenty.p95,19); XCTAssertEqual(twenty.maximum,20)
    }
    func testInvalidMeasurementsFailRatherThanDisappear() {
        for samples in [[Double](),[-1],[Double.nan],[Double.infinity]] { XCTAssertThrowsError(try BenchmarkLatency(samples:samples)) }
    }
}
