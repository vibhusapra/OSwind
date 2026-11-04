import XCTest
import CSQLite
import CryptoKit
import Darwin
@testable import OSwindCore

private final class RecordingDatabaseGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"Owned database gate")
    private let released=DispatchSemaphore(value:0)
    func pause() {entered.fulfill();released.wait()}
    func release() {released.signal()}
}
final class RecordedMeetingRevisionTests:XCTestCase {
    private var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recording-revision-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store.close();try FileManager.default.removeItem(at:root)}
    private func audio(_ index:Int,in library:MemoryStore?=nil)throws {
        var memory=Memory(id:"clip-\(index)",timestamp:Date(timeIntervalSince1970:Double(index)),kind:.audio,app:"Owned audio",title:"Clip \(index)",text:"Authored source \(index)")
        memory.audioSessionID="session-\(index)";memory.transcript = .init(text:memory.text,duration:30,segments:[.init(start:0,end:30,text:memory.text)],model:"Authored fixture");try (library ?? store).insert(memory)
    }
    func testAudioRevisionTracksCommitsButNotUnrelatedWritesOrRollback()throws {
        let initial=try store.recordedMeetingRevision();try audio(0);let added=try store.recordedMeetingRevision();XCTAssertNotEqual(initial,added)
        try store.insert(Memory(id:"note",kind:.note,app:"Owned note",text:"Authored note"));XCTAssertEqual(try store.recordedMeetingRevision(),added)
        try store.withRoutineDatabase {db in
            try db.execute("BEGIN IMMEDIATE");do {try db.execute("DELETE FROM memories WHERE id='clip-0'");XCTAssertNotEqual(try store.recordedMeetingRevision(),added);try db.execute("ROLLBACK")}catch {try? db.execute("ROLLBACK");throw error}
        }
        XCTAssertEqual(try store.recordedMeetingRevision(),added);try store.delete("clip-0");XCTAssertNotEqual(try store.recordedMeetingRevision(),added)
    }
    func testReadyPageRevisionAndPublicationReadThroughAnotherWALWriterReservation()throws {
        try audio(0);let page=try store.recordedMeetingPage(),other=try MemoryStore(root:root);defer {try? other.withRoutineDatabase {try $0.execute("ROLLBACK")};try? other.close()}
        try other.withRoutineDatabase {try $0.execute("BEGIN IMMEDIATE")}
        XCTAssertEqual(try store.recordedMeetingRevision(),page.revision)
        XCTAssertEqual(try store.recordedMeetingPage().sources,page.sources)
        var published=false;try store.withCurrentRecordedMeetingPage(page) {published=true};XCTAssertTrue(published)
    }
    func testPublicationRefusesBusySameConnectionWithoutWaitingForItsWorker()async throws {
        try audio(0);let page=try store.recordedMeetingPage(),gate=RecordingDatabaseGate(),library=store!
        let worker=Task.detached {try library.withRoutineDatabase {_ in gate.pause()}}
        await fulfillment(of:[gate.entered],timeout:5)
        // A fuse lets a broken blocking implementation fail instead of hanging
        // the test process. Passing must return while the gate is still held.
        DispatchQueue.global().asyncAfter(deadline:.now()+2) {gate.release()}
        let start=ContinuousClock.now
        XCTAssertThrowsError(try store.withCurrentRecordedMeetingPage(page) {}) {XCTAssertTrue($0 is RecordedMeetingRefreshError)}
        XCTAssertLessThan(start.duration(to:.now),.milliseconds(500))
        gate.release();try await worker.value
    }
    func testPublicationForbidsWritesAndRestoresConnectionConfigurationOnFailure()throws {
        try audio(0);let page=try store.recordedMeetingPage()
        try store.withRoutineDatabase {try $0.execute("PRAGMA busy_timeout=1234")}
        XCTAssertThrowsError(try store.withCurrentRecordedMeetingPage(page) {try store.withRoutineDatabase {try $0.execute("UPDATE memories SET title='Wrong' WHERE id='clip-0'")}})
        try store.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("PRAGMA busy_timeout"),1234);XCTAssertEqual(try db.eraseCount("PRAGMA query_only"),0)}
        XCTAssertEqual(try store.get("clip-0")?.title,"Clip 0");try audio(1)
    }
    func testWindowRetainsSelectedOlderSourceWithoutSkippingNewHeadGap()throws {
        for index in 0..<600 {try audio(index)}
        let first=try store.recordedMeetingPage(),second=try store.recordedMeetingPage(before:first.next),selected=try XCTUnwrap(second.sources.first {$0.memoryID=="clip-0"})
        let other=try MemoryStore(root:root);defer {try? other.close()};for index in 600..<1300 {try audio(index,in:other)}
        let window=try store.recordedMeetingWindow(pages:2,retaining:[selected]);XCTAssertEqual(window.pages.count,2);XCTAssertEqual(window.pages.flatMap(\.sources).count,1024)
        XCTAssertEqual(window.retained.map(\.memoryID),["clip-0"]);XCTAssertTrue(window.pages.allSatisfy {$0.revision==window.pages[0].revision})
        var ids=Set((window.pages.flatMap(\.sources)+window.retained).map(\.memoryID)),cursor=window.pages.last?.next
        while let next=cursor {let page=try store.recordedMeetingPage(before:next);ids.formUnion(page.sources.map(\.memoryID));cursor=page.next}
        XCTAssertEqual(ids,Set((0..<1300).map {"clip-\($0)"}))
        try other.delete("clip-0");let changed=try store.recordedMeetingWindow(pages:2,retaining:[selected]);XCTAssertTrue(changed.retained.isEmpty)
    }
    func testRepairingNonceTriggersInvalidatesClockWithoutRebuildingReadyRows()throws {
        try audio(0);let page=try store.recordedMeetingPage(),value=page.revision.value,rowRevision=try XCTUnwrap(page.sources.first?.revision)
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER recorded_meeting_revision_insert")};try store.close();store=try MemoryStore(root:root)
        let current=try store.recordedMeetingPage();XCTAssertNotEqual(current.revision.value,value);XCTAssertEqual(current.sources.first?.revision,rowRevision)
    }
    func testReadyWindowAndRevisionNeverReadPayloadOrWrite()throws {
        try audio(0);let selected=try XCTUnwrap(store.recordedMeetingPage().sources.first)
        try store.withRoutineDatabase {db in
            XCTAssertEqual(sqlite3_set_authorizer(db.handle,{_,action,table,column,_,_ in
                if [SQLITE_INSERT,SQLITE_UPDATE,SQLITE_DELETE].contains(action) {return SQLITE_DENY}
                if action==SQLITE_READ,let table,let column,String(cString:table)=="memories",String(cString:column)=="payload" {return SQLITE_DENY}
                return SQLITE_OK
            },nil),SQLITE_OK)
        }
        defer {try? store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)}}
        let window=try store.recordedMeetingWindow(pages:2,retaining:[selected]);XCTAssertEqual(window.pages.count,1);XCTAssertEqual(window.retained,[selected])
        XCTAssertEqual(try store.recordedMeetingRevision(),window.pages[0].revision);try store.withCurrentRecordedMeetingPage(window.pages[0]) {}
    }
    func testWindowUsesOneReadSnapshotWhenAnotherWriterCommitsDuringItsTraversal()throws {
        try audio(0);let selected=try XCTUnwrap(store.recordedMeetingPage().sources.first),other=try MemoryStore(root:root);defer {try? other.close()}
        let mutation=RecordingTraceMutation {try self.audio(1,in:other)}
        try store.withRoutineDatabase {db in
            sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,sql in
                guard let context,let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).contains("FROM recorded_meeting_sources") else {return 0}
                Unmanaged<RecordingTraceMutation>.fromOpaque(context).takeUnretainedValue().run();return 0
            },Unmanaged.passUnretained(mutation).toOpaque())
        }
        defer {try? store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}}
        let window=try store.recordedMeetingWindow(pages:2,retaining:[selected]);XCTAssertTrue(mutation.called);XCTAssertNil(mutation.error)
        XCTAssertEqual(window.pages.flatMap(\.sources).map(\.memoryID),["clip-0"]);XCTAssertEqual(window.retained,[selected])
        XCTAssertThrowsError(try store.withCurrentRecordedMeetingPage(window.pages[0]) {})
    }
    func testMalformedOrMissingNonceRepairsOnReopenWithoutReplacingSourceRows()throws {
        try audio(0);let original=try XCTUnwrap(store.recordedMeetingPage().sources.first?.revision)
        for damage in ["UPDATE store_metadata SET value='invalid' WHERE key='recorded_meeting_revision_v1'","DELETE FROM store_metadata WHERE key='recorded_meeting_revision_v1'"] {
            try store.withRoutineDatabase {try $0.execute(damage)};XCTAssertThrowsError(try store.recordedMeetingRevision());try store.close();store=try MemoryStore(root:root)
            let page=try store.recordedMeetingPage();XCTAssertEqual(page.sources.first?.revision,original);try store.withCurrentRecordedMeetingPage(page) {}
        }
    }
    func testRevisionIncludesExternalPrivacySettingsWithoutPretendingAudioRowsChanged()throws {
        try audio(0);let before=try store.recordedMeetingRevision()
        var settings=AppSettings();settings.privacy.excludedApps.append("Owned audio");try settings.save(root:root)
        let changed=try store.recordedMeetingRevision();XCTAssertNotEqual(before,changed);XCTAssertEqual(before.value,changed.value);XCTAssertFalse(before.hasSamePrivacy(as:changed))
        XCTAssertTrue(try store.recordedMeetingPage().sources.isEmpty)
    }
    func testActualRetainedPriorCLIImportAdvancesAudioNonceWithoutReinstallingItsTriggers()throws {
        let env=ProcessInfo.processInfo.environment
        guard let path=env["OSWIND_RECORDING_PRIOR_WRITER_CLI"],let output=env["OSWIND_RECORDING_WRITER_QA_DIR"] else {throw XCTSkip("Explicit retained prior recording-writer CLI and owned output required")}
        let binary=URL(fileURLWithPath:path),qa=URL(fileURLWithPath:output)
        func hash()throws->String {SHA256.hash(data:try Data(contentsOf:binary)).map {String(format:"%02x",$0)}.joined()}
        XCTAssertEqual(try hash(),"ca15100379032784c4013600431630808e680809db2d2b36005566a2c6011541")
        try Paths.ensure(qa);let before=try store.recordedMeetingRevision(),page=try store.recordedMeetingPage()
        var memory=Memory(id:"old-writer-audio",timestamp:Date(timeIntervalSince1970:1_793_738_000),kind:.audio,app:"Authored earlier writer",title:"Owned JSON audio import",text:"Authored earlier writer words")
        memory.audioSessionID="old-writer-session";memory.transcript = .init(text:memory.text,duration:30,segments:[.init(start:0,end:30,text:memory.text)],model:"Authored fixture, no ASR claim")
        let input=root.appendingPathComponent("owned-import.json");try JSONEncoder().encode([memory]).write(to:input,options:.withoutOverwriting)
        let process=Process(),stdout=Pipe(),stderr=Pipe();process.executableURL=binary;process.arguments=["--data",root.path,"import",input.path,"--json"];process.standardOutput=stdout;process.standardError=stderr
        var childEnvironment=env;childEnvironment.removeValue(forKey:"DYLD_INSERT_LIBRARIES");process.environment=childEnvironment
        try process.run();let deadline=ProcessInfo.processInfo.systemUptime+30
        while process.isRunning,ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        let exceeded=process.isRunning
        if exceeded {process.terminate();let stop=ProcessInfo.processInfo.systemUptime+3;while process.isRunning,ProcessInfo.processInfo.systemUptime<stop {Thread.sleep(forTimeInterval:0.01)};if process.isRunning {kill(process.processIdentifier,SIGKILL)}}
        process.waitUntilExit();let out=stdout.fileHandleForReading.readDataToEndOfFile(),err=stderr.fileHandleForReading.readDataToEndOfFile()
        try out.write(to:qa.appendingPathComponent("old-writer.stdout"),options:.withoutOverwriting);try err.write(to:qa.appendingPathComponent("old-writer.stderr"),options:.withoutOverwriting)
        XCTAssertFalse(exceeded);XCTAssertEqual(process.terminationStatus,0)
        XCTAssertNotEqual(try store.recordedMeetingRevision().value,before.value);XCTAssertEqual(try store.get(memory.id)?.kind,.audio)
        XCTAssertEqual(try store.recordedMeetingPage().sources.map(\.memoryID),[memory.id]);XCTAssertThrowsError(try store.withCurrentRecordedMeetingPage(page) {})
        try store.withRoutineDatabase {db in
            for (name,expected) in RecordedMeetingRevisionSchema.triggers {
                let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");db.bind(row,1,name);defer {sqlite3_finalize(row)}
                XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(db.text(row,0),expected)
            }
        }
        XCTAssertEqual(try hash(),"ca15100379032784c4013600431630808e680809db2d2b36005566a2c6011541")
    }
    func testForeignAndClosedWindowReferencesRefuse()throws {
        try audio(0);let ref=try XCTUnwrap(store.recordedMeetingPage().sources.first),other=try MemoryStore(root:root.appendingPathComponent("other"));defer {try? other.close()}
        XCTAssertThrowsError(try other.recordedMeetingWindow(pages:1,retaining:[ref]));XCTAssertThrowsError(try store.recordedMeetingWindow(pages:0,retaining:[]))
        try store.close();XCTAssertThrowsError(try store.recordedMeetingRevision())
    }
}

private final class RecordingTraceMutation {
    private let action:()throws->Void
    private(set) var called=false,error:Error?
    init(_ action:@escaping ()throws->Void) {self.action=action}
    func run() {guard !called else {return};called=true;do {try action()}catch {self.error=error}}
}
