import XCTest
import CSQLite
@testable import OSwindCore

final class RecordedMeetingIdentifierTests:XCTestCase {
    private var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recording-identifiers-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store.close();try FileManager.default.removeItem(at:root)}
    private func audio(_ id:String,session:String)throws {
        var source=Memory(id:id,timestamp:Date(timeIntervalSince1970:100),endTimestamp:Date(timeIntervalSince1970:130),kind:.audio,app:"Authored recording",title:"Identifier fixture",text:"Literal words "+id)
        source.audioSessionID=session;source.transcript = .init(text:source.text,duration:30,segments:[.init(start:0,end:30,text:source.text)],model:"Authored fixture")
        try store.insert(source)
    }
    func testCanonicalGraphemeLimitedIdentifierGroupsAndOpensEverySource()throws {
        let session=String(repeating:"e\u{301}",count:200)
        XCTAssertEqual(session.count,200);XCTAssertEqual(session.unicodeScalars.count,400)
        try audio("a",session:session);try audio("b",session:session)
        let page=try store.recordedMeetingPage();XCTAssertEqual(page.sources.count,2);XCTAssertEqual(RecordedMeetingPlanner.group(page.sources).count,1)
        for reference in page.sources {
            do {let source=try store.recordedMeetingEvidence(reference);XCTAssertEqual(source.audioSessionID.map {Data($0.utf8)},Data(session.utf8))}
            catch {XCTFail("A canonical accepted recording ID must open its source: \(error)")}
        }
    }
    func testNULAndByteDistinctIdentifiersNeverSplitOrMergeAndSurviveReopen()throws {
        let identifiers=["\0meeting","m\0left","m\0right","é","e\u{301}"]
        for (index,session) in identifiers.enumerated() {try audio("\(index)-a",session:session);try audio("\(index)-b",session:session)}
        for reopening in 0..<2 {
            if reopening>0 {try store.close();store=try MemoryStore(root:root)}
            let page=try store.recordedMeetingPage(),groups=RecordedMeetingPlanner.group(page.sources)
            XCTAssertEqual(page.sources.count,10);XCTAssertEqual(groups.count,5);XCTAssertTrue(groups.allSatisfy {$0.sources.count==2})
            XCTAssertEqual(Set(groups.map(\.id)).count,5)
            for reference in page.sources {
                do {let source=try store.recordedMeetingEvidence(reference);XCTAssertEqual(source.audioSessionID.map {Data($0.utf8)},Data(identifiers[Int(source.id.prefix(1))!].utf8))}
                catch {XCTFail("The exact NUL/Unicode session must remain openable: \(error)")}
            }
        }
    }
    func testSourceAdmissionStillRejectsEmptyAndOverLimitGraphemeIdentifiers()throws {
        for (index,session) in ["",String(repeating:"e\u{301}",count:201)].enumerated() {XCTAssertThrowsError(try audio("invalid-\(index)",session:session))}
        XCTAssertTrue(try store.recordedMeetingPage().sources.isEmpty)
    }
    func testPriorCacheCannotBeConsumedUntilReopenRepairsItsGroupingSemantics()throws {
        let session=String(repeating:"e\u{301}",count:200)
        try audio("a",session:session);try audio("b",session:session)
        let before=try store.recordedMeetingPage();XCTAssertEqual(RecordedMeetingPlanner.group(before.sources).count,1)
        try store.withRoutineDatabase {db in
            // Exact old projection rule, on this generated fixture only.
            try db.execute("UPDATE recorded_meeting_sources SET grouped=0,recording_id=memory_id; UPDATE store_metadata SET value='1' WHERE key='recorded_meeting_index_version'")
        }
        XCTAssertThrowsError(try store.recordedMeetingPage(),"An open newer reader must refuse older cache semantics")
        try store.close();store=try MemoryStore(root:root)
        let page=try store.recordedMeetingPage();XCTAssertEqual(RecordedMeetingPlanner.group(page.sources).count,1)
        for reference in page.sources {XCTAssertEqual(try store.recordedMeetingEvidence(reference).audioSessionID.map {Data($0.utf8)},Data(session.utf8))}
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='recorded_meeting_index_version'");defer {sqlite3_finalize(row)}
            XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(db.text(row,0),"2")
        }
    }
}
