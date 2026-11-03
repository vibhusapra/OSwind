import XCTest
import CSQLite
@testable import OSwindCore

final class RecordedMeetingPortabilityTests:XCTestCase {
    private var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recorded-portability-"+UUID().uuidString);store=try MemoryStore(root:root.appendingPathComponent("source"))}
    override func tearDownWithError()throws {try store.close();try FileManager.default.removeItem(at:root)}
    private func audio(_ id:String,_ timestamp:Double,session:String)throws {
        var memory=Memory(id:id,timestamp:Date(timeIntervalSince1970:timestamp),endTimestamp:Date(timeIntervalSince1970:timestamp+30),kind:.audio,app:"Authored meeting",title:"Authored recording",text:"Literal authored words "+id)
        memory.audioSessionID=session;memory.transcript = .init(text:memory.text,duration:30,segments:[.init(start:0,end:30,text:memory.text)],model:"Authored fixture")
        try store.insert(memory)
    }
    func testBackupRestoreRebuildsPendingMetadataAndKeepsCanonicalSessionFields()throws {
        try audio("a",100,session:"same-session");try audio("b",145,session:"same-session")
        let oldPage=try store.recordedMeetingPage(),old=try XCTUnwrap(oldPage.sources.first)
        try store.withRoutineDatabase {db in try db.transaction {
            try db.execute("DROP TRIGGER recorded_meeting_update; DELETE FROM recorded_meeting_sources")
            try RecordedMeetingSchema.install(db)
        }}
        let archive=root.appendingPathComponent("owned.oswindbackup"),destination=root.appendingPathComponent("restored")
        let receipt=try LibraryBackup.create(store:store,destination:archive)
        XCTAssertEqual(receipt.memories,2)
        _=try LibraryBackup.restore(archive,to:destination,expectedFingerprint:receipt.archiveFingerprint)
        let restored=try MemoryStore(root:destination);defer {try? restored.close()}
        let page=try restored.recordedMeetingPage(),groups=RecordedMeetingPlanner.group(page.sources)
        XCTAssertEqual(Set(page.sources.map(\.memoryID)),["a","b"]);XCTAssertEqual(groups.count,1);XCTAssertEqual(groups.first?.observedSeconds,60)
        for source in page.sources {let memory=try restored.recordedMeetingEvidence(source);XCTAssertEqual(memory.audioSessionID,"same-session");XCTAssertEqual(memory.transcript?.text,"Literal authored words "+memory.id)}
        XCTAssertThrowsError(try restored.recordedMeetingEvidence(old));XCTAssertThrowsError(try restored.withCurrentRecordedMeetingPage(oldPage) {})
        let reference=try XCTUnwrap(page.sources.first);var settings=AppSettings.load(root:destination);settings.privacy.excludedApps.append("Authored meeting");try settings.save(root:destination)
        XCTAssertTrue(try restored.recordedMeetingPage().sources.isEmpty);XCTAssertThrowsError(try restored.recordedMeetingEvidence(reference))
        XCTAssertEqual(try restored.stats(includeDiskUsage:false).count,2,"Current privacy hides metadata without silently deleting canonical sources")
    }
    func testReviewedHistoryErasureRemovesDerivedRowsAndRefusesRetainedReferences()throws {
        try audio("a",100,session:"erase");try audio("b",120,session:"erase");try audio("keep",400,session:"keep")
        let page=try store.recordedMeetingPage(),removed=try XCTUnwrap(page.sources.first {$0.memoryID=="a"})
        let scope=HistoryErasureScope(start:Date(timeIntervalSince1970:90),end:Date(timeIntervalSince1970:150),kind:.audio),review=try store.previewErasure(scope)
        XCTAssertEqual(review.sources,2);XCTAssertEqual(try store.eraseHistory(scope,expectedToken:review.token).sources,2)
        XCTAssertEqual(try store.recordedMeetingPage().sources.map(\.memoryID),["keep"]);XCTAssertThrowsError(try store.recordedMeetingEvidence(removed))
        try store.close();store=try MemoryStore(root:store.root)
        XCTAssertEqual(try store.recordedMeetingPage().sources.map(\.memoryID),["keep"])
    }
}

extension SyncIncomingSourceTests {
    func testIncomingRecordingProjectionKeepsOriginSessionSeparateAndDeletionRemovesMetadata()throws {
        let (a,ac)=try endpoint("recording-producer",producerID),(b,bc)=try endpoint("recording-receiver",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        func memory(_ id:String,_ offset:Double)->Memory {
            var result=Memory(id:id,timestamp:now.addingTimeInterval(offset),endTimestamp:now.addingTimeInterval(offset+30),kind:.audio,app:"Authored sync",title:"Same recording title",text:"Literal sync words "+id)
            result.audioSessionID="same-raw-id";result.transcript = .init(text:result.text,duration:30,segments:[.init(start:0,end:30,text:result.text)],model:"Authored fixture");return result
        }
        try b.insert(memory("local-native",0));try drain(b,bc)
        try a.insert(memory("remote-a",0));try a.insert(memory("remote-b",45));try drain(a,ac)
        var received=[String]()
        for operation in try ac.journal.outbox() {let record=try packet(operation,ac);received.append(try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))}))}
        let page=try b.recordedMeetingPage(),groups=RecordedMeetingPlanner.group(page.sources)
        XCTAssertEqual(page.sources.count,3);XCTAssertEqual(groups.count,2,"Equal raw IDs from different origins must not merge")
        XCTAssertEqual(groups.map {$0.sources.count}.sorted(),[1,2]);XCTAssertEqual(Set(page.sources.map(\.memoryID)),Set(received+["local-native"]))
        let remote=try XCTUnwrap(page.sources.first {$0.memoryID != "local-native"}),canonical=try b.recordedMeetingEvidence(remote)
        XCTAssertNotEqual(canonical.audioSessionID,"same-raw-id");XCTAssertTrue(canonical.text.hasPrefix("Literal sync words remote-"))
        let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        try a.delete("remote-a");try a.delete("remote-b");try drain(a,ac)
        for operation in try ac.journal.outbox(after:through) {try receiveDeletion(operation,b,bc)}
        XCTAssertEqual(try b.recordedMeetingPage().sources.map(\.memoryID),["local-native"]);XCTAssertThrowsError(try b.recordedMeetingEvidence(remote))
        XCTAssertEqual(try b.recordedMeetingEvidence(try XCTUnwrap(b.recordedMeetingPage().sources.first)).audioSessionID,"same-raw-id")
    }
}
