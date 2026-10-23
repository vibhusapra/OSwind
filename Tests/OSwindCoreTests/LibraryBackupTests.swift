import XCTest
@testable import OSwindCore

final class LibraryBackupTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Paths.ensure(root); store = try MemoryStore(root:root.appendingPathComponent("library")) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    func asset(_ path: String, text: String = "Synthetic retained bytes") throws {
        let file = store.root.appendingPathComponent(path); try Paths.ensure(file.deletingLastPathComponent()); try Data(text.utf8).write(to:file)
    }
    var output: URL { root.appendingPathComponent("complete.oswindbackup") }
    func testFullPackageHasMediaChatsVectorsSettingsAndNoSecretsOrCaches() throws {
        try asset("images/A.jpg"); try asset("audio/a.wav",text:"Synthetic audio bytes")
        let memory = Memory(id:"source",app:"Notes",text:"Synthetic source evidence",imagePath:"images/A.jpg",audioPath:"audio/a.wav")
        try store.insert(memory); _ = try store.saveVectors([VectorRecord(memory:memory,vector:[1,0])],modelID:"fixture")
        let session = try store.createChat(); _ = try store.appendChatTurn(sessionID:session.id,question:"What?",answer:Answer(text:"Evidence [1]",sources:[SearchHit(memory:memory,score:1,match:"semantic")],provider:"evidence",duration:0))
        var settings = AppSettings(); settings.profile = .light; settings.apiEnabled = true; settings.automaticMaintenance = true; try settings.save(root:store.root)
        try Data("not-for-backup".utf8).write(to:store.root.appendingPathComponent("api-token")); try Paths.ensure(store.root.appendingPathComponent("indexes")); try Data("cache".utf8).write(to:store.root.appendingPathComponent("indexes/graph"))
        let info = try LibraryBackup.create(store:store,destination:output)
        XCTAssertEqual(info.memories,1); XCTAssertEqual(info.conversations,1); XCTAssertEqual(info.turns,1); XCTAssertEqual(info.mediaFiles,2); XCTAssertEqual(info.encryption,"none")
        let checked = try LibraryBackup.inspect(output); XCTAssertEqual(checked.payloadBytes,info.payloadBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.appendingPathComponent("api-token").path)); XCTAssertFalse(FileManager.default.fileExists(atPath:output.appendingPathComponent("indexes").path))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,from:Data(contentsOf:output.appendingPathComponent("settings.json"))).profile,.light)
        XCTAssertThrowsError(try MemoryStore(root:output))
        XCTAssertEqual(try store.chatTurns(session.id).count,1); XCTAssertEqual(try store.vectorCount(modelID:"fixture"),1)
    }
    func testEmptyLibraryAndCaseDistinctLogicalPathsRemainValid() throws {
        let empty = try LibraryBackup.create(store:store,destination:output); XCTAssertEqual(empty.mediaFiles,0); XCTAssertEqual(try LibraryBackup.inspect(output).memories,0)
        try asset("images/A.jpg")
        try store.insert(Memory(id:"a",text:"A",imagePath:"images/A.jpg")); try store.insert(Memory(id:"b",text:"B",imagePath:"images/a.jpg"))
        let second = root.appendingPathComponent("case.oswindbackup"); XCTAssertEqual(try LibraryBackup.create(store:store,destination:second).mediaFiles,2)
        XCTAssertEqual(try LibraryBackup.inspect(second).mediaFiles,2)
    }
    func testPinnedMediaSurvivesDeletionButOrphansAreNotIncluded() throws {
        try asset("images/a.jpg"); try store.insert(Memory(id:"gone",text:"Will be deleted",imagePath:"images/a.jpg")); var deleted = false
        let info = try LibraryBackup.create(store:store,destination:output) { event in
            if event.phase=="Protecting media", !deleted { deleted = true; try self.store.delete("gone") }
        }
        XCTAssertTrue(deleted); XCTAssertEqual(info.memories,0); XCTAssertEqual(info.mediaFiles,0); XCTAssertEqual(try LibraryBackup.inspect(output).mediaFiles,0)
    }
    func testMissingPostSnapshotMediaRetriesAndExhaustionPublishesNothing() throws {
        var added = false, removed = false, retried = false
        let info = try LibraryBackup.create(store:store,destination:output) { event in
            if event.phase=="Snapshotting database", event.totalItems==0, !added { added = true; try self.asset("images/transient.jpg"); try self.store.insert(Memory(id:"transient",text:"Transient source",imagePath:"images/transient.jpg")) }
            if event.phase=="Snapshotting database", event.completedItems>0, !removed { removed = true; try self.store.delete("transient") }
            if event.phase=="Retrying changed media" { retried = true }
        }
        XCTAssertTrue(added && removed && retried); XCTAssertEqual(info.memories,0); XCTAssertEqual(info.mediaFiles,0)
        let failed = root.appendingPathComponent("failed.oswindbackup"); var addedAttempt = 0, removedAttempt = 0
        XCTAssertThrowsError(try LibraryBackup.create(store:store,destination:failed,maxAttempts:2) { event in
            if event.phase=="Snapshotting database", event.totalItems==0, addedAttempt != event.attempt {
                addedAttempt = event.attempt; try self.asset("images/retry.jpg"); try self.store.insert(Memory(id:"retry",text:"Racing source",imagePath:"images/retry.jpg"))
            }
            if event.phase=="Snapshotting database", event.completedItems>0, removedAttempt != event.attempt { removedAttempt = event.attempt; try self.store.delete("retry") }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath:failed.path))
    }
    func testCancellationExistingDestinationAndSourceOverlapNeverOverwrite() throws {
        XCTAssertThrowsError(try LibraryBackup.create(store:store,destination:output) { event in if event.phase=="Verifying package" { throw CancellationError() } })
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        try Paths.ensure(output); try Data("keep".utf8).write(to:output.appendingPathComponent("keep"))
        XCTAssertThrowsError(try LibraryBackup.create(store:store,destination:output)); XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("keep")),Data("keep".utf8))
        XCTAssertThrowsError(try LibraryBackup.create(store:store,destination:store.root.appendingPathComponent("bad.oswindbackup")))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy { !$0.hasPrefix(".oswind-backup-partial-") })
    }
    func testCorruptionMissingExtraAndSymlinkMediaCannotInspect() throws {
        try asset("images/a.jpg"); try store.insert(Memory(text:"Source",imagePath:"images/a.jpg")); _ = try LibraryBackup.create(store:store,destination:output)
        let member = output.appendingPathComponent(BackupMediaEntry.member(for:"images/a.jpg")); let original = try Data(contentsOf:member)
        try Data("changed".utf8).write(to:member); XCTAssertThrowsError(try LibraryBackup.inspect(output)); try original.write(to:member)
        let extra = output.appendingPathComponent("media/unlisted"); try Data().write(to:extra); XCTAssertThrowsError(try LibraryBackup.inspect(output)); try FileManager.default.removeItem(at:extra)
        try FileManager.default.removeItem(at:member); try FileManager.default.createSymbolicLink(at:member,withDestinationURL:store.root.appendingPathComponent("images/a.jpg")); XCTAssertThrowsError(try LibraryBackup.inspect(output))
    }
    func testRestoredSettingsAreQuietAndMachineConnectionsNeedSetup() throws {
        var settings = AppSettings(); settings.captureOnLaunch = true; settings.apiEnabled = true; settings.audioEnabled = true; settings.systemAudioEnabled = true; settings.ai.allowRemote = true; settings.ai.provider = .compatible; settings.ai.endpoint = "https://example.invalid"; settings.search.provider = .ollama; settings.whisperBinary = "/tmp/untrusted-program"
        let quiet = LibraryBackup.quietSettings(settings)
        XCTAssertFalse(quiet.captureOnLaunch || quiet.apiEnabled || quiet.audioEnabled || quiet.systemAudioEnabled || quiet.automaticMaintenance || quiet.ai.allowRemote)
        XCTAssertEqual(quiet.ai.provider,.evidence); XCTAssertEqual(quiet.search.provider,.apple); XCTAssertEqual(quiet.ai.endpoint,AIConfiguration().endpoint); XCTAssertEqual(quiet.whisperBinary,AppSettings().whisperBinary)
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(AppSettings())) as! [String:Any]; object.removeValue(forKey:"automaticMaintenance")
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self,from:JSONSerialization.data(withJSONObject:object)).automaticMaintenance)
    }
    func testTrustedLibraryAliasCanBackUpWithoutAllowingArchiveRootSymlinks() throws {
        try asset("images/a.jpg"); try store.insert(Memory(id:"aliased",text:"Source behind a user-selected alias",imagePath:"images/a.jpg"))
        let alias = root.appendingPathComponent("library-alias"); try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:store.root)
        let aliasedStore = try MemoryStore(root:alias)
        XCTAssertEqual(try LibraryBackup.create(store:aliasedStore,destination:output).memories,1)
        let archiveAlias = root.appendingPathComponent("backup-alias"); try FileManager.default.createSymbolicLink(at:archiveAlias,withDestinationURL:output)
        XCTAssertThrowsError(try LibraryBackup.inspect(archiveAlias))
    }

}
