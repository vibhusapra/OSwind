import XCTest
import CSQLite
@testable import OSwindCore

extension LibraryBackupTests {
    func testErasureFenceTextOnlyDeletionRetriesSnapshot() throws {
        try store.insert(Memory(id:"text",text:"Owned text with no media"))
        var removed=false,retried=false
        let info=try LibraryBackup.create(store:store,destination:output) {event in
            if event.phase=="Snapshotting database",event.completedItems>0,!removed {removed=true;try self.store.delete("text")}
            if event.phase=="Retrying changed media" {retried=true}
        }
        XCTAssertTrue(removed && retried);XCTAssertEqual(info.memories,0);XCTAssertEqual(info.mediaFiles,0)
        XCTAssertEqual(try LibraryBackup.inspect(output).memories,0)
    }
    func testErasureFencePinnedMediaDeletionRetriesSnapshot() throws {
        try asset("images/pinned");try store.insert(Memory(id:"pinned",text:"Owned pinned source",imagePath:"images/pinned"))
        var removed=false,retried=false
        let info=try LibraryBackup.create(store:store,destination:output) {event in
            if event.phase=="Snapshotting database",event.completedItems>0,!removed {removed=true;try self.store.delete("pinned")}
            if event.phase=="Retrying changed media" {retried=true}
        }
        XCTAssertTrue(removed && retried);XCTAssertEqual(info.memories,0);XCTAssertEqual(info.mediaFiles,0)
        XCTAssertEqual(try LibraryBackup.inspect(output).mediaFiles,0)
        XCTAssertEqual(store.retryErasureCleanup().pendingMedia,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("images/pinned").path))
    }
    func testErasureFenceRecreatedSourceDoesNotReuseErasedVersionsPinnedBytes() throws {
        try asset("images/reused",text:"Old owned pixels")
        try store.insert(Memory(id:"reuse",text:"Old source",imagePath:"images/reused"))
        var replaced=false,retried=false
        let next=Data("New owned pixels".utf8)
        let info=try LibraryBackup.create(store:store,destination:output) {event in
            if event.phase=="Snapshotting database",event.completedItems>0,!replaced {
                replaced=true;try self.store.delete("reuse")
                try next.write(to:self.store.root.appendingPathComponent("images/reused"),options:.atomic)
                try self.store.insert(Memory(id:"reuse",text:"New source",imagePath:"images/reused"))
            }
            if event.phase=="Retrying changed media" {retried=true}
        }
        XCTAssertTrue(replaced && retried);XCTAssertEqual(info.memories,1);XCTAssertEqual(info.mediaFiles,1)
        XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent(BackupMediaEntry.member(for:"images/reused"))),next)
        XCTAssertEqual(try LibraryBackup.inspect(output).mediaFiles,1)
    }
    func testErasureFenceDeletionDuringCopyVerificationOrPublicationPublishesNothing() throws {
        for phase in ["Copying media","Verifying package","Publishing backup"] {
            try asset("images/pinned");try store.insert(Memory(id:"pinned",text:"Owned source",imagePath:"images/pinned"))
            var removed=false
            XCTAssertThrowsError(try LibraryBackup.create(store:store,destination:output) {event in
                if event.phase==phase,!removed {removed=true;try self.store.delete("pinned")}
            },phase)
            XCTAssertTrue(removed,phase);XCTAssertFalse(FileManager.default.fileExists(atPath:output.path),phase)
            XCTAssertEqual(store.retryErasureCleanup().pendingMedia,0)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy {!$0.hasPrefix(".oswind-backup-partial-")})
        }
    }
    func testErasureFenceConcurrentAppendDoesNotInvalidatePointInTimeBackup() throws {
        try store.insert(Memory(id:"before",text:"Before snapshot"));var appended=false,retried=false
        let info=try LibraryBackup.create(store:store,destination:output) {event in
            if event.phase=="Publishing backup",!appended {appended=true;try self.store.insert(Memory(id:"after",text:"After snapshot"))}
            if event.phase=="Retrying changed media" {retried=true}
        }
        XCTAssertTrue(appended);XCTAssertFalse(retried);XCTAssertEqual(info.memories,1)
        XCTAssertEqual(try store.stats().count,2);XCTAssertEqual(try LibraryBackup.inspect(output).memories,1)
    }
    func testErasureFenceRolledBackDeletionDoesNotInvalidateBackup() throws {
        try store.insert(Memory(id:"keep",text:"Keep committed source"));var rolledBack=false
        let info=try LibraryBackup.create(store:store,destination:output) {event in
            if event.phase=="Publishing backup" {
                try self.store.withRoutineDatabase {db in
                    let before=try BackupErasureFence.current(db)
                    try db.execute("BEGIN IMMEDIATE; DELETE FROM memories WHERE id='keep'")
                    XCTAssertNotEqual(try BackupErasureFence.current(db),before)
                    try db.execute("ROLLBACK");XCTAssertEqual(try BackupErasureFence.current(db),before)
                };rolledBack=true
            }
        }
        XCTAssertTrue(rolledBack);XCTAssertEqual(info.memories,1);XCTAssertNotNil(try store.get("keep"))
    }
    func testErasureFenceChangedTriggerRefusesPublicationAndReopenRepairsIt() throws {
        try store.insert(Memory(id:"keep",text:"Owned source"));var changed=false
        XCTAssertThrowsError(try LibraryBackup.create(store:store,destination:output) {event in
            if event.phase=="Publishing backup" {
                try self.store.withRoutineDatabase {try $0.execute("DROP TRIGGER oswind_backup_erasure_memories; CREATE TRIGGER oswind_backup_erasure_memories AFTER DELETE ON memories BEGIN SELECT 1; END")};changed=true
            }
        })
        XCTAssertTrue(changed);XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        try store.close();store=try MemoryStore(root:root.appendingPathComponent("library"))
        XCTAssertEqual(try LibraryBackup.create(store:store,destination:output).memories,1)
    }
    func testErasureFenceMalformedGenerationRefusesWithoutPublication() throws {
        for value in ["X'6162'","'short'","'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF'"] {
            try store.withRoutineDatabase {try $0.execute("UPDATE store_metadata SET value="+value+" WHERE key='backup-erasure-generation-v1'")}
            XCTAssertThrowsError(try LibraryBackup.create(store:store,destination:output))
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        }
        try store.withRoutineDatabase {try $0.execute("UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='backup-erasure-generation-v1'")}
        XCTAssertEqual(try LibraryBackup.create(store:store,destination:output).memories,0)
    }
}
