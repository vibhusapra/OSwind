import XCTest
import CSQLite
@testable import OSwindCore

private final class FeasibilityTrace: @unchecked Sendable {
    private let lock=NSLock()
    private var statements=[String]()
    private var cancellation:(@Sendable ()->Void)?
    func record(_ sql:String) {
        lock.lock();statements.append(sql);let cancel=sql.hasPrefix("SELECT EXISTS(SELECT 1 FROM memory_fts") ? cancellation:nil;lock.unlock()
        cancel?()
    }
    func reset() {lock.lock();statements=[];lock.unlock()}
    var values:[String] {lock.lock();defer {lock.unlock()};return statements}
    var armed:Bool {lock.lock();defer {lock.unlock()};return cancellation != nil}
    func arm(_ action:@escaping @Sendable ()->Void) {lock.lock();cancellation=action;lock.unlock()}
    func disarm() {lock.lock();cancellation=nil;lock.unlock()}
    var probes:Int {values.filter {$0.hasPrefix("SELECT EXISTS(SELECT 1 FROM memory_fts")}.count}
    var ranked:Int {values.filter {$0.contains("FROM memory_fts f JOIN memories")}.count}
}

final class SearchExpressionFeasibilityTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    private let trace=FeasibilityTrace()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store=try MemoryStore(root:root)
        let context=Unmanaged.passUnretained(trace).toOpaque()
        try store.withRoutineDatabase {db in
            sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,sql in
                if let context,let sql {Unmanaged<FeasibilityTrace>.fromOpaque(context).takeUnretainedValue().record(String(cString:sql.assumingMemoryBound(to:CChar.self)))}
                return 0
            },context)
        }
    }
    override func tearDownWithError()throws {
        try store?.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}
        trace.disarm();store=nil;try? FileManager.default.removeItem(at:root)
    }
    func source(_ id:String,_ text:String)throws {try store.insert(Memory(id:id,text:text,embedding:[1,0],embeddingModel:"fixture"))}
    func ids(_ query:String,_ mode:SearchMode = .keyword,expression:SearchExpressionPlan?=nil)throws->[String] {
        try store.search(SearchFilter(query:query,limit:100),mode:mode,vector:mode == .keyword ? nil:[1,0],modelID:mode == .keyword ? nil:"fixture",minimumSimilarity:-1,expression:expression).map(\.id)
    }
    func testAbsentRequiredPhraseSkipsRankingAndReportsEmptyExactExecution()throws {
        for n in 0..<120 {try source("source-\(n)","Nebula review \(n)")}
        for mode in [SearchMode.keyword,.hybrid,.semantic] {
            trace.reset();var execution:SearchExecution?
            let hits=try store.search(SearchFilter(query:#"nebula "never offered""#),mode:mode,vector:[1,0],modelID:"fixture",minimumSimilarity:-1) {execution=$0}
            XCTAssertTrue(hits.isEmpty);XCTAssertEqual(trace.probes,1);XCTAssertEqual(trace.ranked,0)
            XCTAssertEqual(execution?.strategy,"exact");XCTAssertEqual(execution?.warnings,[])
        }
    }
    func testBooleanOrAndNegationNeverDiscardPossibleBranches()throws {
        try source("alpha","alpha archive");try source("beta","beta archive")
        XCTAssertEqual(Set(try ids("missing OR alpha")),["alpha"])
        XCTAssertEqual(Set(try ids("missing AND alpha OR beta")),["beta"])
        XCTAssertEqual(Set(try ids("alpha AND NOT missing")),["alpha"])
        XCTAssertEqual(Set(try ids("NOT missing AND (alpha OR beta)")),["alpha","beta"])
        XCTAssertEqual(Set(try ids("alpha AND NOT beta")),["alpha"])
        XCTAssertTrue(try ids("alpha AND NOT alpha").isEmpty)
        trace.reset();XCTAssertTrue(try ids("missing AND alpha").isEmpty);XCTAssertEqual(trace.ranked,0)
    }
    func testPresentAtomsOnDifferentSourcesDoNotReplaceCompleteRowPredicate()throws {
        try source("alpha","alpha");try source("beta","beta")
        trace.reset();XCTAssertTrue(try ids("alpha AND beta").isEmpty)
        XCTAssertEqual(trace.probes,2);XCTAssertEqual(trace.ranked,1)
        try source("both","alpha beta")
        XCTAssertEqual(try ids("alpha AND beta"),["both"])
    }
    func testExactPhraseAndPrefixRemainDistinctIncludingUnicodeTokens()throws {
        try source("gapped","café preliminary review 210")
        trace.reset();XCTAssertTrue(try ids(#""CAFE review""#).isEmpty);XCTAssertEqual(trace.ranked,0)
        XCTAssertEqual(try ids("cafe AND revi"),["gapped"])
        trace.reset();XCTAssertTrue(try ids(#""21""#).isEmpty);XCTAssertEqual(trace.ranked,0)
        try source("exact","CAFÉ review 21")
        XCTAssertEqual(try ids(#""cafe review" AND "21""#),["exact"])
    }
    func testSpeakerOnlyAndSplitBodyLabelsRemainEligible()throws {
        var memory=Memory(id:"speaker",kind:.audio,text:"Archive delivery")
        memory.transcript=SpeechTranscript(text:memory.text,duration:2,segments:[TranscriptSegment(start:0,end:1,text:"Archive",speaker:"Maya"),TranscriptSegment(start:1,end:2,text:"delivery",speaker:"Chen")],model:"fixture")
        try store.insert(memory)
        XCTAssertEqual(try ids("Maya AND Chen AND archive"),["speaker"])
        XCTAssertTrue(try ids(#""Maya Chen" AND archive"#).isEmpty)
        _=try store.renameAudioSpeaker("speaker",from:"Maya",to:"Maya Chen")
        XCTAssertEqual(try ids(#""Maya Chen" AND archive"#),["speaker"])
    }
    func testObservationIsNotCachedAcrossSourceWritesOrSpeakerRenames()throws {
        try source("one","alpha beta")
        XCTAssertTrue(try ids(#""alpha gamma""#).isEmpty)
        try source("one","alpha gamma")
        XCTAssertEqual(try ids(#""alpha gamma""#),["one"])
        try source("one","alpha beta")
        XCTAssertTrue(try ids(#""alpha gamma""#).isEmpty)
    }
    func testUnconstrainedAndLiteralQueriesDoNotAddProbesAndDuplicatesProbeOnce()throws {
        try source("one","alpha beta")
        trace.reset();XCTAssertEqual(try ids("alpha beta"),["one"]);XCTAssertEqual(trace.probes,0)
        let literal=try SearchExpressionPlan.make(#""alpha beta" AND missing"#,interpret:false)
        trace.reset();XCTAssertEqual(try ids(#""alpha beta" AND missing"#,expression:literal),["one"]);XCTAssertEqual(trace.probes,0)
        trace.reset();XCTAssertEqual(try ids("alpha AND alpha AND alpha"),["one"]);XCTAssertEqual(trace.probes,1)
    }
    func testCancellationDuringProbeLeavesConnectionAndFollowingSearchUsable()async throws {
        try source("one","alpha beta")
        let store=self.store!,trace=self.trace
        let task=Task.detached {
            while !trace.armed {await Task.yield()}
            return try store.search(SearchFilter(query:#""alpha beta""#),mode:.keyword)
        }
        trace.arm {task.cancel()}
        do {_=try await task.value;XCTFail("Expected cancellation")} catch is CancellationError {} catch {XCTFail("Wrong error: \(error)")}
        trace.disarm();XCTAssertEqual(try ids(#""alpha beta""#),["one"])
        XCTAssertEqual(try store.stats(includeDiskUsage:false).count,1)
    }
}

/// Create-only authored archive for a separately declared paired CLI workload.
/// It never opens an existing library or requests an embedding/model.
final class SearchExpressionScaleFixtureTests:XCTestCase {
    func testCreateExplicitlyOwnedFeasibilityArchive()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_FEASIBILITY_FIXTURE"]=="1",let path=ProcessInfo.processInfo.environment["OSWIND_TEST_FEASIBILITY_DESTINATION"] else {throw XCTSkip("Opt in to a new authored keyword feasibility archive")}
        let root=URL(fileURLWithPath:path,isDirectory:true)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path));guard !FileManager.default.fileExists(atPath:root.path) else {throw OSwindError.invalid("The authored fixture destination already exists")}
        let store=try MemoryStore(root:root)
        let texts=["Nebula review greenlit.","Nebula preliminary review postponed.","Nebulous reviewers archive.","Archive review completed.","Nebula roadmap blocked.","Unrelated cedar orchard."]
        for n in 0..<48000 {
            let text=texts[n%6]+" Authored entry \(n). "+String(repeating:"context ",count:(n/6)%7)
            let memory=Memory(id:String(format:"profile-%05d",n),timestamp:Date(timeIntervalSinceReferenceDate:700000000+Double(n)),kind:.note,app:n>=47958 ? "Admitted group":"Authored desktop",title:n<300 ? String(repeating:"Nebula review ",count:4):"Generated note",text:text)
            try store.insert(memory)
        }
        XCTAssertEqual(try store.stats(includeDiskUsage:false).count,48000)
        let settings:[String:Any]=["captureOnLaunch":false,"automaticMaintenance":false,"apiEnabled":false,"routinesEnabled":false,"search":["provider":"apple","indexPolicy":"exact"]]
        try JSONSerialization.data(withJSONObject:settings,options:[.sortedKeys]).write(to:root.appendingPathComponent("settings.json"),options:.withoutOverwriting)
        let marker:[String:Any]=["format":"OSwind owned feasibility archive v1","rows":48000,"normalHistory":false,"ingestion":"Actual MemoryStore.insert with no model/embedder; fixture generated from declared texts, titles, applications and IDs. Not capture or ingestion-throughput qualification."]
        try JSONSerialization.data(withJSONObject:marker,options:[.sortedKeys]).write(to:root.appendingPathComponent("fixture.json"),options:.withoutOverwriting)
    }
}
