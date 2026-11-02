import XCTest
@testable import OSwindCore

/// Only the parent authored fixture may launch this bounded ordinary process.
final class PendingMediaNotificationWorkerTests:XCTestCase {
    func testOwnedNotificationWriterWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_PENDING_MEDIA_WORKER_ROOT"],let nonce=env["OSWIND_PENDING_MEDIA_WORKER_NONCE"] else {throw XCTSkip("Only run as owned pending-media notification child")}
        let root=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
        guard UUID(uuidString:nonce) != nil,root.lastPathComponent=="owned-pending-cleanup-"+nonce,
              root.deletingLastPathComponent()==fm.temporaryDirectory.resolvingSymlinksInPath(),
              try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OSwindError.invalid("Invalid owned pending-media worker root")}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        let lease=try store.mediaWriteLease();defer {lease.release()}
        guard try Data(contentsOf:root.appendingPathComponent("images/owned-pending"))==Data([31,41,59]) else {throw OSwindError.invalid("Owned media fixture changed")}
        try Data(nonce.utf8).write(to:root.appendingPathComponent("ready"),options:.withoutOverwriting)
        let gate=root.appendingPathComponent("release"),deadline=ProcessInfo.processInfo.systemUptime+10
        while !fm.fileExists(atPath:gate.path),ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard try String(contentsOf:gate,encoding:.utf8)==nonce else {throw OSwindError.invalid("Owned media worker did not receive its release")}
        lease.release()
        try Data(nonce.utf8).write(to:root.appendingPathComponent("done"),options:.withoutOverwriting)
    }
}
