import XCTest
import CSQLite
@testable import OSwindCore

final class SQLiteSnapshotTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    var source: URL { root.appendingPathComponent("memory.sqlite") }
    func testUncheckpointedWALAndChatsSurviveAsSingleFile() throws {
        let memory = Memory(id:"source",app:"Notes",text:"Synthetic WAL-backed evidence"); try store.insert(memory)
        _ = try store.saveVectors([VectorRecord(memory:memory,vector:[1,0])],modelID:"fixture")
        let chat = try store.createChat(); _ = try store.appendChatTurn(sessionID:chat.id,question:"What?",answer:Answer(text:"Evidence [1]",sources:[SearchHit(memory:memory,score:1,match:"semantic")],provider:"evidence",duration:0))
        let target = root.appendingPathComponent("snapshot.sqlite"); var pages = 0
        try SQLiteSnapshot.copy(source:source,to:target,pagesPerStep:1) { state in XCTAssertGreaterThanOrEqual(state.copiedPages,pages); pages = state.copiedPages }
        XCTAssertGreaterThan(pages,0)
        let files = try FileManager.default.contentsOfDirectory(atPath:root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path+"-wal"),"Unexpected snapshot WAL: \(files)")
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path+"-shm"),"Unexpected snapshot SHM: \(files)")
        let restoredRoot = root.appendingPathComponent("restored"); try Paths.ensure(restoredRoot); try FileManager.default.copyItem(at:target,to:restoredRoot.appendingPathComponent("memory.sqlite"))
        let restored = try MemoryStore(root:restoredRoot)
        XCTAssertEqual(try restored.get(memory.id)?.text,memory.text); XCTAssertEqual(try restored.vectorCount(modelID:"fixture"),1)
        XCTAssertEqual(try restored.chatTurns(chat.id).first?.answer.text,"Evidence [1]")
    }
    func testConcurrentCaptureWritesContinueButDoNotMixSourceVersions() throws {
        for i in 0..<80 { try store.insert(Memory(id:"original-\(i)",text:String(repeating:"Original synthetic record. ",count:200))) }
        let other = try MemoryStore(root:root), target = root.appendingPathComponent("pinned.sqlite"); var wrote = false
        try SQLiteSnapshot.copy(source:source,to:target,pagesPerStep:1) { _ in
            if !wrote { wrote = true; try other.insert(Memory(id:"later",text:"Later capture")); try other.delete("original-0") }
        }
        XCTAssertTrue(wrote); XCTAssertNil(try store.get("original-0")); XCTAssertNotNil(try store.get("later"))
        let restoredRoot = root.appendingPathComponent("pinned"); try Paths.ensure(restoredRoot); try FileManager.default.moveItem(at:target,to:restoredRoot.appendingPathComponent("memory.sqlite"))
        let restored = try MemoryStore(root:restoredRoot)
        XCTAssertEqual(try restored.matchingCount(),80); XCTAssertNotNil(try restored.get("original-0")); XCTAssertNil(try restored.get("later"))
    }
    func testInterruptedCopyLeavesNoPartialDestinationOrJournal() throws {
        try store.insert(Memory(text:"Synthetic cancellation fixture")); let target = root.appendingPathComponent("cancelled.sqlite")
        XCTAssertThrowsError(try SQLiteSnapshot.copy(source:source,to:target,pagesPerStep:1) { _ in throw CancellationError() })
        for suffix in ["","-wal","-shm","-journal"] { XCTAssertFalse(FileManager.default.fileExists(atPath:target.path+suffix)) }
        XCTAssertEqual(try store.matchingCount(),1)
    }
    func testExistingDestinationAndSymlinkCannotBeOverwritten() throws {
        let target = root.appendingPathComponent("existing.sqlite"), original = Data("Keep this file".utf8); try original.write(to:target)
        XCTAssertThrowsError(try SQLiteSnapshot.copy(source:source,to:target)); XCTAssertEqual(try Data(contentsOf:target),original)
        let link = root.appendingPathComponent("link.sqlite"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        XCTAssertThrowsError(try SQLiteSnapshot.copy(source:source,to:link)); XCTAssertEqual(try Data(contentsOf:target),original)
        let sourceLink = root.appendingPathComponent("source-link.sqlite"); try FileManager.default.createSymbolicLink(at:sourceLink,withDestinationURL:source)
        let fresh = root.appendingPathComponent("fresh.sqlite"); XCTAssertThrowsError(try SQLiteSnapshot.copy(source:sourceLink,to:fresh)); XCTAssertFalse(FileManager.default.fileExists(atPath:fresh.path))
    }
    func testInvalidOrMissingSourceNeverCreatesAnEmptyBackup() throws {
        let output = root.appendingPathComponent("bad.sqlite"), invalid = root.appendingPathComponent("invalid.sqlite")
        try Data("Not a SQLite database".utf8).write(to:invalid)
        XCTAssertThrowsError(try SQLiteSnapshot.copy(source:invalid,to:output)); XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        XCTAssertThrowsError(try SQLiteSnapshot.copy(source:root.appendingPathComponent("absent.sqlite"),to:output)); XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        XCTAssertThrowsError(try SQLiteSnapshot.copy(source:source,to:output,pagesPerStep:0))
    }
}

extension SQLiteSnapshotTests {
    func testTaskCancellationAfterFirstPageRemovesPartialOutput() async throws {
        for i in 0..<40 { try store.insert(Memory(id:"cancel-\(i)",text:String(repeating:"Synthetic cancellation input. ",count:100))) }
        let input = source, target = root.appendingPathComponent("task-cancelled.sqlite")
        let task = Task.detached {
            try SQLiteSnapshot.copy(source:input,to:target,pagesPerStep:1) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await task.value; XCTFail("Accepted a cancelled snapshot") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        for suffix in ["","-wal","-shm","-journal"] { XCTAssertFalse(FileManager.default.fileExists(atPath:target.path+suffix)) }
        XCTAssertEqual(try store.matchingCount(),40)
    }
}
