import XCTest
import Darwin
@testable import OSwindCore

final class BackupWorkspaceTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Paths.ensure(root) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    func testCleanupDoesNotFollowLinksAndIsIdempotent() throws {
        let workspace = try BackupWorkspace(in:root), outside = root.appendingPathComponent("outside")
        try Paths.ensure(outside); try Data("keep".utf8).write(to:outside.appendingPathComponent("keep"))
        try workspace.tree.write(Data("payload".utf8),as:"nested/data")
        try FileManager.default.createSymbolicLink(at:workspace.url.appendingPathComponent("link"),withDestinationURL:outside)
        try workspace.cleanup(); try workspace.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath:workspace.url.path)); XCTAssertEqual(try Data(contentsOf:outside.appendingPathComponent("keep")),Data("keep".utf8))
    }
    func testAtomicPublicationRefusesExistingEvenEmptyDirectories() throws {
        let workspace = try BackupWorkspace(in:root), existing = root.appendingPathComponent("existing")
        try workspace.tree.write(Data("complete".utf8),as:"member"); try Paths.ensure(existing)
        XCTAssertThrowsError(try workspace.publish(as:existing)); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:existing.path).isEmpty)
        try Data("keep".utf8).write(to:existing.appendingPathComponent("keep")); XCTAssertThrowsError(try workspace.publish(as:existing))
        let target = root.appendingPathComponent("complete.oswindbackup"); try workspace.publish(as:target); try workspace.cleanup()
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("member")),Data("complete".utf8)); XCTAssertTrue(FileManager.default.fileExists(atPath:existing.appendingPathComponent("keep").path))
    }
    func testReplacedWorkspaceAndOtherParentCannotBeDeletedOrPublished() throws {
        let workspace = try BackupWorkspace(in:root), elsewhere = root.appendingPathComponent("elsewhere")
        try Paths.ensure(elsewhere); XCTAssertThrowsError(try workspace.publish(as:elsewhere.appendingPathComponent("backup")))
        try FileManager.default.moveItem(at:workspace.url,to:root.appendingPathComponent("moved")); try Paths.ensure(workspace.url)
        try Data("replacement".utf8).write(to:workspace.url.appendingPathComponent("keep"))
        XCTAssertThrowsError(try workspace.cleanup()); XCTAssertEqual(try Data(contentsOf:workspace.url.appendingPathComponent("keep")),Data("replacement".utf8))
    }
    func testDirectoryAncestryUsesIdentityAndRejectsArchiveMutation() throws {
        let child = root.appendingPathComponent("child"), sibling = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Paths.ensure(child); try Paths.ensure(sibling); defer { try? FileManager.default.removeItem(at:sibling) }
        let parentTree = try BackupFileTree(root:root), childTree = try BackupFileTree(root:child), siblingTree = try BackupFileTree(root:sibling)
        XCTAssertTrue(try parentTree.isAncestor(of:childTree)); XCTAssertTrue(try parentTree.isAncestor(of:parentTree)); XCTAssertFalse(try childTree.isAncestor(of:parentTree)); XCTAssertFalse(try parentTree.isAncestor(of:siblingTree))
        XCTAssertThrowsError(try parentTree.removeAllChildren()); XCTAssertTrue(FileManager.default.fileExists(atPath:child.path))
    }
    private func deadPID() throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/true"); try process.run(); process.waitUntilExit(); return process.processIdentifier
    }
    private func abandoned(pid: Int32? = nil) throws -> (URL,URL) {
        let id = UUID().uuidString.lowercased(), payload = root.appendingPathComponent(".oswind-backup-partial-"+id), control = root.appendingPathComponent(".oswind-job-"+id)
        try Paths.ensure(payload); try Paths.ensure(control)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:payload.path); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:control.path)
        var metadata = stat(); XCTAssertEqual(lstat(payload.path,&metadata),0)
        let marker = BackupWorkspaceMarker(jobID:id,label:"oswind-backup-partial",workspaceName:payload.lastPathComponent,device:metadata.st_dev,inode:metadata.st_ino,pid:try pid ?? deadPID(),createdAt:Date().timeIntervalSince1970)
        try JSONEncoder().encode(marker).write(to:control.appendingPathComponent("marker.json")); try Data().write(to:control.appendingPathComponent("lease")); try Data("partial".utf8).write(to:payload.appendingPathComponent("data"))
        return (payload,control)
    }
    func testAbandonedCleanupRequiresDeadCreatorAndExclusiveKernelLease() throws {
        let live = try BackupWorkspace(in:root)
        XCTAssertEqual(try BackupWorkspace.cleanupAbandoned(in:root),0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:live.url.path))
        let (payload,control) = try abandoned(), lease = open(control.appendingPathComponent("lease").path,O_RDWR)
        XCTAssertGreaterThanOrEqual(lease,0); defer { close(lease) }
        XCTAssertEqual(flock(lease,LOCK_EX | LOCK_NB),0)
        XCTAssertEqual(try BackupWorkspace.cleanupAbandoned(in:root),0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:payload.path))
        XCTAssertEqual(flock(lease,LOCK_UN),0)
        XCTAssertEqual(try BackupWorkspace.cleanupAbandoned(in:root),1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:payload.path)); XCTAssertFalse(FileManager.default.fileExists(atPath:control.path))
        let (current,_) = try abandoned(pid:getpid())
        XCTAssertEqual(try BackupWorkspace.cleanupAbandoned(in:root),0); XCTAssertTrue(FileManager.default.fileExists(atPath:current.path))
    }
    func testCleanupPreservesPublishedPayloadAndRefusesReplacedPayload() throws {
        let (payload,control) = try abandoned(), published = root.appendingPathComponent("finished.oswindbackup")
        try FileManager.default.moveItem(at:payload,to:published)
        XCTAssertEqual(try BackupWorkspace.cleanupAbandoned(in:root),1)
        XCTAssertEqual(try Data(contentsOf:published.appendingPathComponent("data")),Data("partial".utf8)); XCTAssertFalse(FileManager.default.fileExists(atPath:control.path))
        let (original,companion) = try abandoned(), moved = root.appendingPathComponent("saved-original")
        try FileManager.default.moveItem(at:original,to:moved); try Paths.ensure(original); try Data("keep".utf8).write(to:original.appendingPathComponent("keep"))
        XCTAssertEqual(try BackupWorkspace.cleanupAbandoned(in:root),0)
        XCTAssertEqual(try Data(contentsOf:original.appendingPathComponent("keep")),Data("keep".utf8)); XCTAssertTrue(FileManager.default.fileExists(atPath:companion.path))
    }
    func testCleanupRefusesForgedNamesPublicPermissionsAndSymlinkLease() throws {
        let (payload,control) = try abandoned()
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:control.path)
        XCTAssertEqual(try BackupWorkspace.cleanupAbandoned(in:root),0)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:control.path)
        let lease = control.appendingPathComponent("lease"), outside = root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to:outside); try FileManager.default.removeItem(at:lease); try FileManager.default.createSymbolicLink(at:lease,withDestinationURL:outside)
        XCTAssertEqual(try BackupWorkspace.cleanupAbandoned(in:root),0); XCTAssertEqual(try Data(contentsOf:outside),Data("keep".utf8))
        try FileManager.default.removeItem(at:lease); try Data().write(to:lease)
        var marker = try JSONDecoder().decode(BackupWorkspaceMarker.self,from:Data(contentsOf:control.appendingPathComponent("marker.json"))); marker.workspaceName = "../outside"
        try JSONEncoder().encode(marker).write(to:control.appendingPathComponent("marker.json"))
        XCTAssertEqual(try BackupWorkspace.cleanupAbandoned(in:root),0); XCTAssertTrue(FileManager.default.fileExists(atPath:payload.path))
    }

}
