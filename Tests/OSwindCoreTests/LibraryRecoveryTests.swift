import XCTest
import CSQLite
@testable import OSwindCore

final class LibraryRecoveryTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-native-recovery-"+UUID().uuidString)
        try Paths.ensure(root);store=try MemoryStore(root:root.appendingPathComponent("source"))
        try store.insert(Memory(id:"owned",kind:.note,text:"Owned local content survives missing sync credentials"))
    }
    override func tearDownWithError()throws {try store?.close();try FileManager.default.removeItem(at:root)}
    func testRecoveryConnectionDeniesDataSchemaAndVersionWritesButAllowsBackupReservation()throws {
        let source=store!.root;try store.close()
        let reader=try MemoryStore(root:source,recoveryReadOnly:true);defer {try? reader.close()}
        XCTAssertEqual(try reader.get("owned")?.kind,.note)
        for sql in ["DELETE FROM memories","UPDATE memories SET title='changed'","CREATE TABLE unauthorized(x)","DROP TABLE memories","PRAGMA user_version=1","ATTACH ':memory:' AS extra"] {
            XCTAssertThrowsError(try reader.withRoutineDatabase {try $0.execute(sql)},sql)
        }
        try reader.withRoutineDatabase {try $0.execute("BEGIN IMMEDIATE; ROLLBACK")}
        XCTAssertEqual(try reader.get("owned")?.text,"Owned local content survives missing sync credentials")
    }
    func testRecoveryBackupRestoresContentIntoFreshIdentityWithoutSyncMetadata()throws {
        let source=store!.root
        let media=Data("Owned retained recovery image".utf8)
        try media.write(to:source.appendingPathComponent("images/owned.jpg"))
        try store.insert(Memory(id:"owned",kind:.note,text:"Owned local content survives missing sync credentials",imagePath:"images/owned.jpg"))
        try store.withRoutineDatabase {try $0.execute("INSERT INTO store_metadata(key,value) VALUES('sync-pairing-handle-v1','owned missing credential handle')")}
        try store.close()
        let archive=root.appendingPathComponent("Recovered.oswindbackup"),destination=root.appendingPathComponent("restored")
        let info=try LibraryRecovery.createBackup(from:source,destination:archive)
        XCTAssertEqual(info.memories,1)
        XCTAssertEqual(info.mediaFiles,1)
        _=try LibraryBackup.restore(archive,to:destination)
        let restored=try MemoryStore(root:destination);defer {try? restored.close()}
        XCTAssertEqual(try restored.get("owned")?.text,"Owned local content survives missing sync credentials")
        let restoredPath=try XCTUnwrap(restored.get("owned")?.imagePath)
        XCTAssertNotEqual(restoredPath,"images/owned.jpg","Restore assigns new retained-media paths")
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(restored.assetURL(restoredPath))),media)
        XCTAssertEqual(try restored.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key LIKE 'sync-pairing-%'")},0)
        XCTAssertEqual(try restored.withRoutineDatabase {try $0.eraseCount("SELECT enabled FROM personal_sync_capture")},0)
    }
    func testRecoveryDoesNotCreateAMissingSourceOrOverwriteDestination()throws {
        let missing=root.appendingPathComponent("missing"),output=root.appendingPathComponent("backup")
        XCTAssertThrowsError(try LibraryRecovery.createBackup(from:missing,destination:output))
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
        try Paths.ensure(output);try Data("Owned sentinel".utf8).write(to:output.appendingPathComponent("keep"))
        XCTAssertThrowsError(try LibraryRecovery.createBackup(from:store.root,destination:output))
        XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("keep")),Data("Owned sentinel".utf8))
    }
    func testCancelledRecoveryPublishesNothingAndClosesItsSourceConnection()throws {
        let source=store!.root,output=root.appendingPathComponent("cancelled.oswindbackup")
        try store.close()
        XCTAssertThrowsError(try LibraryRecovery.createBackup(from:source,destination:output,progress:{event in
            if event.phase=="Publishing backup" {throw CancellationError()}
        })) {XCTAssertTrue($0 is CancellationError)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains {$0.hasPrefix(".oswind-backup-partial-")})
        store=try MemoryStore(root:source)
        XCTAssertNotNil(try store.get("owned"))
        try store.close()
    }
}
