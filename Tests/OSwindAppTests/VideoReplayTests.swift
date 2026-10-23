import XCTest
import OSwindCore
@testable import OSwind

final class VideoReplayTests:XCTestCase {
    func testOCRGeometryUsesVideoImageWithinLetterboxedPlayer() {
        let region=TextRegion(text:"target",x:0.1,y:0.7,width:0.6,height:0.1)
        let pillarbox=ReplayVideoGeometry.regionRect(region,video:CGSize(width:1920,height:1290),container:CGSize(width:785,height:350))
        let fittedWidth=350.0*1920/1290
        XCTAssertEqual(pillarbox.minX,(785-fittedWidth)/2+fittedWidth*0.1,accuracy:0.0001)
        XCTAssertEqual(pillarbox.minY,70,accuracy:0.0001)
        XCTAssertEqual(pillarbox.width,fittedWidth*0.6,accuracy:0.0001)
        XCTAssertEqual(pillarbox.height,35,accuracy:0.0001)
        let letterbox=ReplayVideoGeometry.regionRect(region,video:CGSize(width:1920,height:1080),container:CGSize(width:400,height:350))
        XCTAssertEqual(letterbox.minX,40,accuracy:0.0001)
        XCTAssertEqual(letterbox.minY,107.5,accuracy:0.0001)
        XCTAssertEqual(letterbox.width,240,accuracy:0.0001)
        XCTAssertEqual(letterbox.height,22.5,accuracy:0.0001)
        let full=ReplayVideoGeometry.regionRect(TextRegion(text:"all",x:0,y:0,width:1,height:1),video:CGSize(width:400,height:200),container:CGSize(width:400,height:200))
        XCTAssertEqual(full,CGRect(x:0,y:0,width:400,height:200))
    }
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
