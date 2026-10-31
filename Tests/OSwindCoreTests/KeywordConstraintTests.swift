import XCTest
import CSQLite
@testable import OSwindCore

final class KeywordConstraintTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {store=nil;try? FileManager.default.removeItem(at:root)}
    func temporaryScopes()throws->Int {try store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM sqlite_temp_master WHERE name='search_expression_scope'")}}

    func testRequiredEligibilityPrecedesLimitEvenBelowManyHigherRankedSoftMatches()throws {
        for i in 0..<200 {try store.insert(Memory(id:"decoy-\(i)",text:String(repeating:"needlecue ",count:12),favorite:true))}
        for i in 0..<250 {try store.insert(Memory(id:"eligible-\(i)",text:"required phrase",favorite:i==0))}
        let query=#"needlecue "required phrase""#
        let filter=SearchFilter(query:query,favoritesOnly:true,limit:1)
        let soft=try SearchExpressionPlan.make(query,interpret:false)
        XCTAssertTrue(try XCTUnwrap(store.search(filter,mode:.keyword,expression:soft).first).id.hasPrefix("decoy-"))
        for mode in [SearchMode.keyword,.hybrid] {
            let result=try store.search(filter,mode:mode)
            XCTAssertEqual(result.map(\.id),["eligible-0"])
            XCTAssertEqual(result.first?.score,1.0/60)
            XCTAssertEqual(result.first?.match,"keyword")
        }
        XCTAssertEqual(try temporaryScopes(),0,"Bounded keyword/vectorless queries must not build an archive-wide ID set")
    }

    func testEmptyModelSkipsEligibilityButLateVectorsIgnoreStaleCallerHint()throws {
        let memory=Memory(id:"late",text:"required phrase")
        try store.insert(memory)
        let filter=SearchFilter(query:#""required phrase""#)
        XCTAssertEqual(try store.search(filter,mode:.hybrid,vector:[1,0],modelID:"late-model",indexedCount:900).map(\.id),["late"])
        XCTAssertTrue(try store.search(filter,mode:.semantic,vector:[1,0],modelID:"late-model").isEmpty)
        XCTAssertEqual(try temporaryScopes(),0)
        let other=try MemoryStore(root:root)
        _=try other.saveVectors([VectorRecord(memory:memory,vector:[1,0])],modelID:"late-model")
        let result=try store.search(filter,mode:.semantic,vector:[1,0],modelID:"late-model",indexedCount:0)
        XCTAssertEqual(result.map(\.id),["late"]);XCTAssertEqual(result.first?.score,1)
        XCTAssertEqual(result.first?.match,"semantic")
    }

    func testMixedBodySpeakerBooleanScopesSurviveSourceRowidChangesAndVacuum()throws {
        let rows:[(String,String,String?)]=[("speaker\0one","archive launch approved","Maya Chen"),("speaker-two","archive review deferred","Theo Chen"),("body","Maya Chen approves archive",nil),("other","unrelated tasks",nil)]
        for (id,text,label) in rows {
            var memory=Memory(id:id,timestamp:Date(timeIntervalSince1970:100),kind:label==nil ? .note:.audio,app:label==nil ? "Notes":"Meetings",text:text,embedding:[1,0],embeddingModel:"fixture")
            if let label {memory.transcript=SpeechTranscript(text:text,duration:1,segments:[TranscriptSegment(start:0,end:1,text:text,speaker:label)],model:"fixture")}
            try store.insert(memory)
        }
        try store.withRoutineDatabase {try $0.execute("UPDATE memories SET rowid=rowid+100000; PRAGMA wal_checkpoint(TRUNCATE); VACUUM; PRAGMA wal_checkpoint(TRUNCATE)")}
        let cases:[(String,Set<String>)]=[
            (#"("Maya Chen" AND archive) OR ("Theo Chen" AND NOT launch)"#,["speaker\0one","speaker-two","body"]),
            (#"archive AND NOT "Maya Chen""#,["speaker-two"]),
            (#""Maya Chen" AND NOT deferred"#,["speaker\0one","body"]),
            (#""Theo Chen" "archive review""#,["speaker-two"])
        ]
        for (query,expected) in cases {
            for detail in [SearchDetail.full,.preview] {
                XCTAssertEqual(Set(try store.search(SearchFilter(query:query,limit:100),mode:.keyword,detail:detail).map(\.id)),expected,query)
            }
        }
        XCTAssertEqual(try temporaryScopes(),0)
        for mode in [SearchMode.hybrid,.semantic] {
            XCTAssertEqual(Set(try store.search(SearchFilter(query:cases[0].0,limit:100),mode:mode,vector:[1,0],modelID:"fixture",minimumSimilarity:-1).map(\.id)),cases[0].1)
        }
        XCTAssertTrue(try store.search(SearchFilter(query:#""Maya Chen" AND archive"#,app:"Other"),mode:.keyword).isEmpty)
        _=try store.renameAudioSpeaker("speaker\0one",from:"Maya Chen",to:"Māya René")
        XCTAssertEqual(try store.search(SearchFilter(query:#""Maya Rene" AND archive"#),mode:.keyword).map(\.id),["speaker\0one"])
        XCTAssertEqual(try store.search(SearchFilter(query:#""Maya Chen" AND archive"#),mode:.keyword).map(\.id),["body"])
    }
}
