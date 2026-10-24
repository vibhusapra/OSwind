import XCTest
@testable import OSwindCore

final class VisualImageSnapshotTests:XCTestCase {
    var root:URL!,store:MemoryStore!,memory:Memory!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-visual-snapshot-"+UUID().uuidString)
        store=try MemoryStore(root:root)
        memory=Memory(id:"image",app:"Fixture",text:"",imagePath:"images/image.dat")
        try Data("original authored bytes".utf8).write(to:root.appendingPathComponent(memory.imagePath!));try store.insert(memory)
    }
    override func tearDownWithError() throws {try? store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func testSnapshotRevalidatesAndReleaseEndsAdmission() throws {
        let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:memory.id));defer {snapshot.release()}
        XCTAssertEqual(snapshot.data,Data("original authored bytes".utf8));XCTAssertEqual(try snapshot.validatedMemory().id,memory.id)
        XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:0.02))
        snapshot.release();XCTAssertThrowsError(try snapshot.validatedMemory());snapshot.release()
        let exclusive=try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:0.1);exclusive.release()
    }
    func testChangedPixelsAreRejectedEvenWithUnchangedTextAndPath() throws {
        let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:memory.id));defer {snapshot.release()}
        try Data("different authored bytes".utf8).write(to:root.appendingPathComponent(memory.imagePath!))
        XCTAssertThrowsError(try snapshot.validatedMemory())
    }
    func testChangedContextIsRejectedButFavoriteRemainsValid() throws {
        let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:memory.id));defer {snapshot.release()}
        try store.setFavorite(memory.id,value:true);XCTAssertTrue(try snapshot.validatedMemory().favorite)
        memory.bundleID="changed";try store.insert(memory);XCTAssertThrowsError(try snapshot.validatedMemory())
    }
    func testMissingAndSymlinkedImagesNeverReadForeignBytes() throws {
        let target=root.appendingPathComponent("foreign");try Data("private sentinel".utf8).write(to:target)
        let image=root.appendingPathComponent(memory.imagePath!);try FileManager.default.removeItem(at:image)
        XCTAssertThrowsError(try VisualImageSnapshot.make(store:store,id:memory.id))
        try FileManager.default.createSymbolicLink(at:image,withDestinationURL:target)
        XCTAssertThrowsError(try VisualImageSnapshot.make(store:store,id:memory.id));XCTAssertEqual(try Data(contentsOf:target),Data("private sentinel".utf8))
    }
    func testCloseWaitsForSnapshotThenCompletesWhileSnapshotObjectRemainsAlive() async throws {
        let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:memory.id));defer {snapshot.release()}
        let source=store!,entered=XCTestExpectation(description:"close entered"),worker=Task.detached {entered.fulfill();try source.close()}
        await fulfillment(of:[entered],timeout:2)
        try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(source.isClosed)
        snapshot.release();try await worker.value;XCTAssertTrue(source.isClosed)
        XCTAssertThrowsError(try snapshot.validatedMemory())
    }
}
