import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import OSwindCore

/// Native-only authored component measurements, never model/ingestion/energy or
/// whole-app throughput. Opt-in output is marked and private; no normal history.
final class NativeANNBuildMeasurementsTests:XCTestCase {
    private struct Trial:Codable {
        let count:Int,dimensions:Int,requestedWorkers:Int,repetition:Int
        let sourceSHA256:String,format:String
        let generationSeconds:Double,prepareSeconds:Double,batches:[Double],probeSeconds:Double
        let sampledQueries:Int,sampledSelfMisses:[UInt64],nativeCount:Int
        let graph:String,graphSHA256:String,wholeProcessPeakRSS:Int64
    }
    private func seconds(_ start:ContinuousClock.Instant)->Double {let d=start.duration(to:.now).components;return Double(d.seconds)+Double(d.attoseconds)/1e18}
    func testAuthoredNativePreparationAndSampledSelfRecall()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_BUILD_MEASUREMENTS"]=="1" else {throw XCTSkip("Explicit authored native build measurements")}
        let output=try XCTUnwrap(OwnedIndexedRetrievalProbe.outputDirectory(prefix:"native-build-"));var trials=[Trial]()
        for count in [1000,5000,10000] {
            let generation=ContinuousClock.now,dimensions=512
            let rows=(0..<count).map {IndexedVector(key:UInt64($0+1),revision:Int64($0+1),vector:VectorScalingEvaluation.vector(row:$0,dimensions:dimensions),parentKey:UInt64($0+1))}
            let generationSeconds=seconds(generation);var hash=SHA256()
            for row in rows {var key=row.key.littleEndian;withUnsafeBytes(of:&key){hash.update(data:Data($0))};row.vector!.withUnsafeBytes {hash.update(data:Data($0))}}
            let sourceSHA=hash.finalize().map {String(format:"%02x",$0)}.joined()
            for repetition in 1...3 {for workers in [1,4] {
                let start=ContinuousClock.now,native=try NativeANN(dimensions:dimensions);try native.reserve(count+512);var batches=[Double]()
                for first in stride(from:0,to:rows.count,by:256) {let batch=Array(rows[first..<min(first+256,rows.count)]),stamp=ContinuousClock.now;try native.addBatch(batch,threads:workers);batches.append(seconds(stamp))}
                let elapsed=seconds(start),probe=ContinuousClock.now;var misses=[UInt64]()
                for sample in 0..<128 {let row=rows[sample*count/128];if try native.search(row.vector!,count:1).first != row.key {misses.append(row.key)}}
                let probeSeconds=seconds(probe),name="n\(count)-w\(workers)-r\(repetition).usearch",path=output.appendingPathComponent(name);try native.save(path)
                var usage=rusage();getrusage(RUSAGE_SELF,&usage)
                trials.append(.init(count:count,dimensions:dimensions,requestedWorkers:workers,repetition:repetition,sourceSHA256:sourceSHA,format:native.indexFormat,generationSeconds:generationSeconds,prepareSeconds:elapsed,batches:batches,probeSeconds:probeSeconds,sampledQueries:128,sampledSelfMisses:misses,nativeCount:try native.count,graph:name,graphSHA256:SHA256.hash(data:try Data(contentsOf:path)).map {String(format:"%02x",$0)}.joined(),wholeProcessPeakRSS:Int64(usage.ru_maxrss)))
                try SyncProtocolLimits.encode(trials).write(to:output.appendingPathComponent("trials.json"),options:.atomic)
                XCTAssertEqual(try native.count,count)
                print("OWNED_NATIVE_BUILD rows=\(count) hint=\(workers) repetition=\(repetition) seconds=\(elapsed) sampledMisses=\(misses.count)")
            }}
        }
        XCTAssertEqual(trials.count,18)
    }
}
