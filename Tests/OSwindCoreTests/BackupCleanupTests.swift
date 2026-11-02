import XCTest
@testable import OSwindCore

final class BackupCleanupTests:XCTestCase {
    func testCancelledCleanupCannotFollowSymlinkParent()async throws {
        let fixture=FileManager.default.temporaryDirectory.appendingPathComponent("owned-cancelled-cleanup-"+UUID().uuidString),root=fixture.appendingPathComponent("root"),outside=fixture.appendingPathComponent("outside")
        try Paths.ensure(root);try Paths.ensure(outside);defer {try? FileManager.default.removeItem(at:fixture)}
        let file=outside.appendingPathComponent("keep");try Data([7,8,9]).write(to:file)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("redirect"),withDestinationURL:outside)
        let tree=try BackupFileTree(root:root,writable:true)
        let worker=Task.detached {withUnsafeCurrentTask {$0?.cancel()};try tree.removeForCleanup("redirect/keep")}
        do {try await worker.value;XCTFail("Cleanup followed an external parent")}
        catch is CancellationError {XCTFail("Cleanup must perform its structural checks even after cancellation")}catch {}
        XCTAssertEqual(try Data(contentsOf:file),Data([7,8,9]))
    }
    func testCancelledCleanupCannotWriteReadOnlyTree()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-readonly-cleanup-"+UUID().uuidString)
        try Paths.ensure(root);defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("keep");try Data([9]).write(to:file);let tree=try BackupFileTree(root:root)
        let worker=Task.detached {withUnsafeCurrentTask {$0?.cancel()};try tree.removeForCleanup("keep")}
        do {try await worker.value;XCTFail("Cleanup wrote to a read-only tree")}
        catch is CancellationError {XCTFail("The read-only guard must still execute")}catch {}
        XCTAssertEqual(try Data(contentsOf:file),Data([9]))
    }
}
