import XCTest
import OSwindCore
@testable import OSwind

final class AudioPlaybackTests: XCTestCase {
    @MainActor func testMutedRuntimeSeekPauseFinishAndDeletion() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Paths.ensure(root); defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("synthetic.wav"); try WAV.data(samples:Array(repeating:0.05,count:160000)).write(to:file)
        let playback=AudioPlaybackModel(); playback.volume=0; playback.load(file); defer { playback.stop() }
        XCTAssertNil(playback.error); XCTAssertEqual(playback.duration,10,accuracy:0.01)
        playback.seek(0.4); XCTAssertEqual(playback.position,0.4,accuracy:0.02)
        playback.toggle()
        guard playback.playing else { throw XCTSkip("Audio output unavailable on this host: \(playback.error ?? "unknown")") }
        let advanced=ContinuousClock.now.advanced(by:.seconds(10))
        while playback.position<=0.5,playback.playing,ContinuousClock.now<advanced {try await Task.sleep(for:.milliseconds(20))}
        XCTAssertGreaterThan(playback.position,0.5)
        // Deliberately keep the actor busy while the real muted player advances:
        // pause must publish its actual position before a queued timer can run.
        let beforePause=playback.position;Thread.sleep(forTimeInterval:0.08)
        playback.toggle();let paused=playback.position;XCTAssertGreaterThan(paused,beforePause+0.03)
        try await Task.sleep(nanoseconds:200_000_000); XCTAssertEqual(playback.position,paused,accuracy:0.02); XCTAssertFalse(playback.playing)
        playback.seek(playback.duration-0.2);playback.toggle()
        let finished=ContinuousClock.now.advanced(by:.seconds(10))
        while playback.playing,ContinuousClock.now<finished {try await Task.sleep(for:.milliseconds(20))}
        XCTAssertFalse(playback.playing); XCTAssertEqual(playback.position,playback.duration,accuracy:0.02); XCTAssertNil(playback.error)
        playback.seek(0); playback.toggle(); XCTAssertTrue(playback.playing)
        try FileManager.default.removeItem(at:file)
        let removed=ContinuousClock.now.advanced(by:.seconds(10))
        while playback.playing,ContinuousClock.now<removed {try await Task.sleep(for:.milliseconds(20))}
        XCTAssertFalse(playback.playing); XCTAssertNotNil(playback.error)
    }
}
