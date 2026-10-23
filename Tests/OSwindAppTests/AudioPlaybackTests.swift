import XCTest
import OSwindCore
@testable import OSwind

final class AudioPlaybackTests: XCTestCase {
    @MainActor func testMutedRuntimeSeekPauseFinishAndDeletion() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Paths.ensure(root); defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("synthetic.wav"); try WAV.data(samples:Array(repeating:0.05,count:32000)).write(to:file)
        let playback=AudioPlaybackModel(); playback.volume=0; playback.load(file); defer { playback.stop() }
        XCTAssertNil(playback.error); XCTAssertEqual(playback.duration,2,accuracy:0.01)
        playback.seek(0.4); XCTAssertEqual(playback.position,0.4,accuracy:0.02)
        playback.toggle()
        guard playback.playing else { throw XCTSkip("Audio output unavailable on this host: \(playback.error ?? "unknown")") }
        try await Task.sleep(nanoseconds:350_000_000)
        XCTAssertGreaterThan(playback.position,0.5)
        playback.toggle(); let paused=playback.position
        try await Task.sleep(nanoseconds:200_000_000); XCTAssertEqual(playback.position,paused,accuracy:0.02); XCTAssertFalse(playback.playing)
        playback.seek(1.8); playback.toggle(); try await Task.sleep(nanoseconds:500_000_000)
        XCTAssertFalse(playback.playing); XCTAssertEqual(playback.position,playback.duration,accuracy:0.02); XCTAssertNil(playback.error)
        playback.seek(0); playback.toggle(); XCTAssertTrue(playback.playing)
        try FileManager.default.removeItem(at:file); try await Task.sleep(nanoseconds:350_000_000)
        XCTAssertFalse(playback.playing); XCTAssertNotNil(playback.error)
    }
}
