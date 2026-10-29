import XCTest
import Darwin
import CSQLite
@testable import OSwindCore

final class LibraryImportFileTests:XCTestCase {
    var root:URL!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-import-file-"+UUID().uuidString);try Paths.ensure(root)}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    func file(_ data:Data) throws -> URL {let url=root.appendingPathComponent(UUID().uuidString+".json");try data.write(to:url);return url}
    func testExactBoundAndUnicodeBytesAcrossChunks() throws {
        let data=Data((String(repeating:"é😀\r\n",count:14000)+"tail").utf8),url=try file(data)
        XCTAssertEqual(try LibraryImportFile.read(url,maximumBytes:data.count),data)
        var reads=0;XCTAssertThrowsError(try LibraryImportFile.read(url,maximumBytes:data.count-1,progress:{_ in reads+=1}));XCTAssertEqual(reads,0)
    }
    func testPublicJSONRejectsSparseOversizeBeforeReadingAnyBytes() throws {
        let store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()}
        let url=root.appendingPathComponent("oversize.json"),fd=open(url.path,O_RDWR | O_CREAT | O_EXCL,0o600);XCTAssertGreaterThanOrEqual(fd,0);defer {close(fd)}
        XCTAssertEqual(ftruncate(fd,off_t(LibraryImportFile.jsonMaximumBytes+1)),0)
        var reads=0
        XCTAssertThrowsError(try store.importJSONFile(from:url,inputProgress:{_ in reads+=1})) {XCTAssertTrue($0.localizedDescription.contains("byte limit"))}
        XCTAssertEqual(reads,0);XCTAssertEqual(try store.stats().count,0)
    }
    func testNonFileSymlinkFIFOAndDirectoryRefuseWithoutBlocking() throws {
        let source=try file(Data("[]".utf8)),link=root.appendingPathComponent("link"),fifo=root.appendingPathComponent("pipe")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source);XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        for url in [URL(string:"https://example.invalid/source")!,URL(string:"file://remote.invalid/source")!,root!,link,fifo] {XCTAssertThrowsError(try LibraryImportFile.read(url,maximumBytes:100))}
    }
    func testGrowthBeyondLimitAndTruncationRefuse() throws {
        let data=Data(repeating:65,count:70000),growing=try file(data)
        XCTAssertThrowsError(try LibraryImportFile.read(growing,maximumBytes:100000,progress:{count in if count==65536 {
            let h=try FileHandle(forWritingTo:growing);defer {try? h.close()};try h.seekToEnd();try h.write(contentsOf:Data(repeating:66,count:40000))
        }}))
        let shrinking=try file(data)
        XCTAssertThrowsError(try LibraryImportFile.read(shrinking,maximumBytes:100000,progress:{count in if count==65536 {
            let h=try FileHandle(forWritingTo:shrinking);defer {try? h.close()};try h.truncate(atOffset:65536)
        }}))
    }
    func testSameSizeEditAndIdenticalAtomicReplacementRefuse() throws {
        let data=Data(repeating:65,count:70000),editing=try file(data)
        XCTAssertThrowsError(try LibraryImportFile.read(editing,maximumBytes:100000,progress:{count in if count==65536 {
            let h=try FileHandle(forWritingTo:editing);defer {try? h.close()};try h.write(contentsOf:Data([66]))
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:100)],ofItemAtPath:editing.path)
        }}))
        let replacing=try file(data)
        XCTAssertThrowsError(try LibraryImportFile.read(replacing,maximumBytes:100000,progress:{count in if count==65536 {try data.write(to:replacing,options:.atomic)}}))
    }
    func testParentReplacementRefusesRetainedOriginal() throws {
        let parent=root.appendingPathComponent("parent");try Paths.ensure(parent);let source=parent.appendingPathComponent("input.json")
        try Data(repeating:65,count:70000).write(to:source)
        XCTAssertThrowsError(try LibraryImportFile.read(source,maximumBytes:100000,progress:{count in if count==65536 {
            try FileManager.default.moveItem(at:parent,to:self.root.appendingPathComponent("moved"));try Paths.ensure(parent)
        }}))
    }
    func testCancellationBeforeAndDuringReadReleasesReservations() async throws {
        let store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()}
        let source=try file(Data(repeating:32,count:70000))
        for before in [true,false] {
            let worker=Task.detached {
                if before {withUnsafeCurrentTask {$0?.cancel()}}
                return try store.importJSONFile(from:source,inputProgress:{_ in withUnsafeCurrentTask {$0?.cancel()}})
            }
            do {_ = try await worker.value;XCTFail("Cancelled reader admitted input")} catch is CancellationError {} catch {throw error}
            let lease=try MediaAdmissionLease.acquire(root:store.root,exclusive:true,timeout:0);lease.release()
            XCTAssertEqual(try store.stats().count,0)
        }
    }
    func testOneReservationCoversFileReadingAndNestedAdmissionWithoutHoldingSQL() throws {
        let store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()}
        let source=Memory(id:"owned",kind:.note,text:String(repeating:"Owned fixture ",count:6000)),url=try file(JSONEncoder().encode([source]))
        var observed=false
        let result=try store.importJSONFile(from:url,inputProgress:{count in if !observed {
            observed=true;XCTAssertGreaterThan(count,0)
            XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:store.root,exclusive:true,timeout:0))
            try store.withRoutineDatabase {XCTAssertEqual(sqlite3_get_autocommit($0.handle),1)}
            try store.insert(Memory(id:"unrelated",kind:.note,text:"Other work progresses"))
            var metadata=stat();XCTAssertEqual(lstat(store.root.appendingPathComponent(".media-admission.lock").path,&metadata),0)
            let matching=try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").compactMap(Int32.init).filter {fd in
                var opened=stat();return fstat(fd,&opened)==0 && opened.st_dev==metadata.st_dev && opened.st_ino==metadata.st_ino
            }
            XCTAssertEqual(matching.count,1,"One operation borrows its original reservation instead of nesting flocks")
        }})
        XCTAssertTrue(observed);XCTAssertEqual(result.imported,1);XCTAssertEqual(try store.stats().count,2)
    }
    func testBorrowedWrongRootReleasedAndPrematurelyReleasedReservationsRefuse() throws {
        let store=try MemoryStore(root:root.appendingPathComponent("library")),other=try MemoryStore(root:root.appendingPathComponent("other"));defer {try? store.close();try? other.close()}
        let source=Memory(id:"owned",kind:.note,text:"Owned input"),data=try JSONEncoder().encode([source]),url=try file(data)
        let wrong=try other.mediaWriteLease();defer {wrong.release()}
        XCTAssertThrowsError(try store.importJSONDetailed(data:data,admission:wrong))
        let released=try store.mediaWriteLease();released.release();XCTAssertThrowsError(try store.importJSONDetailed(data:data,admission:released))
        let duringRead=try store.mediaWriteLease()
        XCTAssertThrowsError(try store.importJSONFile(from:url,admission:duringRead,inputProgress:{_ in duringRead.release()}))
        let duringPreparation=try store.mediaWriteLease()
        XCTAssertThrowsError(try store.importDecodedMemoriesDetailed([source],embedder:nil,policy:.init(),admission:duringPreparation,preparationProgress:{_ in duringPreparation.release()}))
        XCTAssertEqual(try store.stats().count,0)
    }
    func testBorrowedReservationStaysOwnedByCallerAfterSuccess() throws {
        let store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()}
        let activity=try store.mediaWriteLease(),source=Memory(id:"owned",kind:.note,text:"Owned input")
        XCTAssertEqual(try store.importJSONDetailed(data:JSONEncoder().encode([source]),admission:activity).imported,1)
        XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:store.root,exclusive:true,timeout:0));activity.release()
        let exclusive=try MediaAdmissionLease.acquire(root:store.root,exclusive:true,timeout:0);exclusive.release()
    }
    func testStaleSettingsRefuseBeforeInputReadOrDecodeInAllDataRoutes() throws {
        let store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()}
        let snapshot=try LibrarySettingsSnapshot.capture(root:store.root);defer {snapshot.release()};try snapshot.settings.save(root:store.root)
        let bad=Data("{invalid".utf8),url=try file(bad);var reads=0
        XCTAssertThrowsError(try store.importJSONFile(from:url,policy:snapshot.settings.privacy,settingsSnapshot:snapshot,inputProgress:{_ in reads+=1})) {XCTAssertTrue($0.localizedDescription.contains("Saved settings changed"))}
        XCTAssertEqual(reads,0)
        for operation in [
            {try store.importJSONDetailed(data:bad,policy:snapshot.settings.privacy,settingsSnapshot:snapshot).imported},
            {try store.importCollectorBatch(bad,policy:snapshot.settings.privacy,settingsSnapshot:snapshot).imported},
            {try store.importLimitlessAPI(data:bad,policy:snapshot.settings.privacy,settingsSnapshot:snapshot).imported}
        ] {XCTAssertThrowsError(try operation()) {XCTAssertTrue($0.localizedDescription.contains("Saved settings changed"))}}
    }
}
