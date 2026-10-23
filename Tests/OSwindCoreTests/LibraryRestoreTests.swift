import XCTest
import CSQLite
@testable import OSwindCore

final class LibraryRestoreTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Paths.ensure(root); store = try MemoryStore(root:root.appendingPathComponent("original")) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    var archive: URL { root.appendingPathComponent("complete.oswindbackup") }
    var restoredURL: URL { root.appendingPathComponent("restored") }
    func seed() throws -> (Memory,String) {
        try Data("Synthetic retained image".utf8).write(to:store.root.appendingPathComponent("images/image.jpg"))
        try Data("Synthetic retained audio".utf8).write(to:store.root.appendingPathComponent("audio/record.wav"))
        var memory = Memory(id:"source\0suffix",timestamp:Date(timeIntervalSince1970:1234567890.123456),kind:.note,app:"Notes",title:"Original synthetic source",text:String(repeating:"Source background. ",count:300)+"Elian owns renewal Thursday.",imagePath:"images/image.jpg",audioPath:"audio/record.wav",favorite:true,tags:["work"])
        memory.embedding = [1,0]; memory.embeddingModel = "legacy"; try store.insert(memory)
        _ = try store.saveVectors([VectorRecord(memory:memory,vector:[0,1])],modelID:"additional")
        let plan = SemanticPassagePlan.make(memory); XCTAssertTrue(try store.savePassages(memory:memory,modelID:"additional",records:plan.map {PassageVector(range:$0.range,vector:[0,1])}))
        let session = try store.createChat(title:"Saved synthetic conversation")
        let scope = SearchFilter(app:"Notes",start:Date(timeIntervalSince1970:1234500000),end:Date(timeIntervalSince1970:1234600000),favoritesOnly:true,tag:"work")
        _ = try store.appendChatTurn(sessionID:session.id,question:"Who?",answer:Answer(text:"Elian [1]",sources:[SearchHit(memory:memory,score:1,match:"semantic",passage:plan.last!.range)],provider:"evidence",duration:0),filter:scope)
        var settings = AppSettings(); settings.profile = .light; settings.captureOnLaunch = true; settings.apiEnabled = true; settings.audioEnabled = true; settings.systemAudioEnabled = true; settings.ai.allowRemote = true; settings.ai.provider = .compatible; settings.ai.endpoint = "https://example.invalid"; settings.whisperBinary = "/tmp/archive-program"; try settings.save(root:store.root)
        return (memory,session.id)
    }
    func rewriteDatabase(_ sql: String) throws {
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(archive.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK)
        let code = sqlite3_exec(db,sql,nil,nil,nil), message = String(cString:sqlite3_errmsg(db)); sqlite3_close(db); XCTAssertEqual(code,SQLITE_OK,message)
        let tree = try BackupFileTree(root:archive)
        var header = try JSONDecoder().decode(LibraryBackupHeader.self,from:tree.read("header.json",limit:65536)); let previous = header.database.bytes
        header.database = try tree.digest("memory.sqlite"); header.info.payloadBytes = header.info.payloadBytes-previous+header.database.bytes
        try JSONEncoder().encode(header).write(to:archive.appendingPathComponent("header.json"))
    }
    func testFullRestorePreservesSourceChatsVectorsAnchorsAndQuietSettings() throws {
        let (original,session) = try seed(), info = try LibraryBackup.create(store:store,destination:archive)
        XCTAssertNotNil(info.archiveFingerprint)
        let result = try LibraryBackup.restore(archive,to:restoredURL,expectedFingerprint:info.archiveFingerprint)
        XCTAssertEqual(result.memories,1)
        let restored = try MemoryStore(root:restoredURL), memory = try XCTUnwrap(restored.get(original.id))
        XCTAssertEqual(memory.text,original.text); XCTAssertEqual(memory.contentHash,original.contentHash); XCTAssertEqual(memory.timestamp,original.timestamp); XCTAssertEqual(memory.tags,["work"]); XCTAssertTrue(memory.favorite)
        XCTAssertNotEqual(memory.imagePath,original.imagePath)
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(restored.assetURL(XCTUnwrap(memory.imagePath)))),Data("Synthetic retained image".utf8))
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(restored.assetURL(XCTUnwrap(memory.audioPath)))),Data("Synthetic retained audio".utf8))
        XCTAssertEqual(try restored.vectorCount(modelID:"legacy"),1); XCTAssertEqual(try restored.vectorCount(modelID:"additional"),1); XCTAssertTrue(try restored.passagesCurrent(memory,modelID:"additional"))
        let turn = try XCTUnwrap(restored.chatTurns(session).first)
        XCTAssertEqual(turn.answer.text,"Elian [1]"); XCTAssertEqual(turn.answer.sources.first?.passage,SemanticPassagePlan.make(original).last?.range); XCTAssertEqual(turn.filter.app,"Notes"); XCTAssertTrue(turn.filter.favoritesOnly)
        let settings = AppSettings.load(root:restoredURL); XCTAssertEqual(settings.profile,.light)
        XCTAssertFalse(settings.captureOnLaunch || settings.apiEnabled || settings.audioEnabled || settings.systemAudioEnabled || settings.automaticMaintenance || settings.ai.allowRemote)
        XCTAssertEqual(settings.ai.provider,.evidence); XCTAssertEqual(settings.whisperBinary,AppSettings().whisperBinary)
        XCTAssertTrue(AppSettings.load(root:store.root).automaticMaintenance); XCTAssertTrue(AppSettings.load(root:store.root).apiEnabled)
        let a = try VectorIndexSource(root:store.root,modelID:"additional",dimensions:2).state(), b = try VectorIndexSource(root:restoredURL,modelID:"additional",dimensions:2).state(); XCTAssertNotEqual(a.identity,b.identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath:restoredURL.appendingPathComponent("api-token").path)); XCTAssertFalse(FileManager.default.fileExists(atPath:restoredURL.appendingPathComponent("indexes").path))
    }
    func testMalformedRoutinePayloadCannotPublishRestoredLibrary() throws {
        _ = try store.saveRoutine(RoutineDefinition());_ = try LibraryBackup.create(store:store,destination:archive)
        try rewriteDatabase("UPDATE routines SET payload=x'7b7d';")
        XCTAssertThrowsError(try LibraryBackup.restore(archive,to:restoredURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath:restoredURL.path));XCTAssertEqual(try store.routines().count,1)
    }
    func testArchivedTriggerDoesNotReachTrustedRestoredSchema() throws {
        try store.insert(Memory(id:"one",text:"One")); try store.insert(Memory(id:"two",text:"Two")); _ = try LibraryBackup.create(store:store,destination:archive)
        try rewriteDatabase("CREATE TRIGGER archive_trap AFTER INSERT ON memories BEGIN DELETE FROM memories WHERE id<>new.id; END;")
        _ = try LibraryBackup.restore(archive,to:restoredURL)
        let restored = try MemoryStore(root:restoredURL); XCTAssertEqual(try restored.matchingCount(),2)
        try restored.insert(Memory(id:"three",text:"Three")); XCTAssertEqual(try restored.matchingCount(),3)
    }
    func testSourceMetadataAndVectorHashTamperingCannotPublishRestore() throws {
        _ = try seed(); _ = try LibraryBackup.create(store:store,destination:archive)
        try rewriteDatabase("UPDATE semantic_vectors SET content_hash='incorrect';")
        XCTAssertThrowsError(try LibraryBackup.restore(archive,to:restoredURL)); XCTAssertFalse(FileManager.default.fileExists(atPath:restoredURL.path)); XCTAssertEqual(try store.matchingCount(),1)
    }
    func testCancellationAndExistingDestinationLeaveOriginalLibrariesIntact() throws {
        _ = try seed(); _ = try LibraryBackup.create(store:store,destination:archive)
        XCTAssertThrowsError(try LibraryBackup.restore(archive,to:restoredURL) { event in if event.phase=="Publishing restored library" { throw CancellationError() } })
        XCTAssertFalse(FileManager.default.fileExists(atPath:restoredURL.path)); XCTAssertEqual(try store.matchingCount(),1)
        try Paths.ensure(restoredURL); try Data("keep".utf8).write(to:restoredURL.appendingPathComponent("keep"))
        XCTAssertThrowsError(try LibraryBackup.restore(archive,to:restoredURL)); XCTAssertEqual(try Data(contentsOf:restoredURL.appendingPathComponent("keep")),Data("keep".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy{ !$0.hasPrefix(".oswind-restore-partial-") })
    }
    func testFingerprintPinsPreviewAndRawBytes() throws {
        _ = try LibraryBackup.create(store:store,destination:archive)
        let info = try LibraryBackup.inspect(archive)
        let file = archive.appendingPathComponent("header.json"); var data = try Data(contentsOf:file); data.append(32); try data.write(to:file)
        XCTAssertNotEqual(try LibraryBackup.inspect(archive).archiveFingerprint,info.archiveFingerprint)
        XCTAssertThrowsError(try LibraryBackup.restore(archive,to:restoredURL,expectedFingerprint:info.archiveFingerprint)); XCTAssertFalse(FileManager.default.fileExists(atPath:restoredURL.path))
        XCTAssertNotEqual(BackupSHA256.hex(Data([0xff])),BackupSHA256.hex(Data([0xfe])))
    }
    func testMalformedOrMissingArchiveDoesNotCreateTarget() throws {
        XCTAssertThrowsError(try LibraryBackup.restore(root.appendingPathComponent("missing"),to:restoredURL)); XCTAssertFalse(FileManager.default.fileExists(atPath:restoredURL.path))
        _ = try seed(); _ = try LibraryBackup.create(store:store,destination:archive)
        try rewriteDatabase("ALTER TABLE memories ADD COLUMN calculated INTEGER GENERATED ALWAYS AS (length(text)) VIRTUAL;")
        XCTAssertThrowsError(try LibraryBackup.restore(archive,to:restoredURL)); XCTAssertFalse(FileManager.default.fileExists(atPath:restoredURL.path))
    }
    func testTaskCancellationInterruptsRestoreSQLAndClearsProgressHandler() async throws {
        let destination = try MemoryStore(root:restoredURL), started = expectation(description:"Restore SQL started")
        let task = Task.detached {
            try destination.withRestoreTransaction { handle in
                started.fulfill()
                let status = sqlite3_exec(handle,"WITH RECURSIVE numbers(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM numbers WHERE n<10000000) SELECT SUM(n) FROM numbers;",nil,nil,nil)
                guard status==SQLITE_OK else { throw OSwindError.database("Interrupted restore SQL") }
                XCTFail("Long restore SQL finished before cancellation")
            }
        }
        await fulfillment(of:[started],timeout:3); task.cancel()
        do { try await task.value; XCTFail("Expected restore cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try destination.matchingCount(),0)
        try destination.insert(Memory(id:"after-cancel",text:"A fresh task can still use the connection")); XCTAssertEqual(try destination.matchingCount(),1)
    }

}
