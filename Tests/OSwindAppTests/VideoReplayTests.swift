import XCTest
import OSwindCore
@testable import OSwind

final class VideoReplayTests:XCTestCase {
    @MainActor func testSyntheticReplayLoadSeekPauseReplacementAndDeletion() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        _ = try await VisualReplayBenchmark.run(directory:root,frames:2,hardwareRequired:false)
        let store=try MemoryStore(root:root.appendingPathComponent("library")),memory=try XCTUnwrap(store.search(SearchFilter(),mode:.keyword).first?.memory),url=try XCTUnwrap(memory.videoPath.flatMap {store.assetURL($0)})
        let playback=VideoReplayModel();await playback.load(url,seek:1);defer {playback.stop()}
        XCTAssertNil(playback.error);XCTAssertNotNil(playback.player);XCTAssertEqual(playback.duration,2,accuracy:0.05);XCTAssertEqual(playback.position,1,accuracy:0.01);XCTAssertFalse(playback.playing)
        playback.seek(.infinity);XCTAssertEqual(playback.position,1,accuracy:0.01)
        playback.seek(-1);XCTAssertEqual(playback.position,0)
        playback.seek(1.8);playback.toggle();try await Task.sleep(nanoseconds:700_000_000)
        XCTAssertFalse(playback.playing);XCTAssertEqual(playback.position,playback.duration,accuracy:0.05)
        playback.toggle();XCTAssertTrue(playback.playing);playback.toggle();XCTAssertFalse(playback.playing)
        await playback.load(root.appendingPathComponent("missing.mov"));XCTAssertNil(playback.player);XCTAssertNotNil(playback.error)
        await playback.load(url);XCTAssertNil(playback.error);try store.delete(memory.id)
        playback.toggle();XCTAssertFalse(playback.playing);XCTAssertNotNil(playback.error);XCTAssertNil(playback.player)
    }
}
