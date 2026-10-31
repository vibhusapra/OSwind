import XCTest
import CSQLite
@testable import OSwindCore

private final class ExpressionModelRequests: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func reset() { lock.lock(); count = 0; lock.unlock() }
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class ExpressionModelProtocol: URLProtocol, @unchecked Sendable {
    static let requests = ExpressionModelRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.add()
        client?.urlProtocol(self,didFailWithError:URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}
private final class ExpressionCancelLatch: @unchecked Sendable {
    private let lock = NSLock(); private var action: (@Sendable () -> Void)?
    var installed: Bool { lock.lock(); defer { lock.unlock() }; return action != nil }
    func install(_ action: @escaping @Sendable () -> Void) { lock.lock(); self.action = action; lock.unlock() }
    func cancel() { lock.lock(); let callback = action; lock.unlock(); callback?() }
    func clear() { lock.lock(); action = nil; lock.unlock() }
}

final class SearchExpressionTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    let vector: [Float] = [1,0]
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    @discardableResult func source(_ id: String,_ text: String,app: String = "Notes",title: String = "Fixture") throws -> Memory {
        let memory = Memory(id:id,kind:.note,app:app,title:title,text:text,embedding:vector,embeddingModel:"fixture")
        try store.insert(memory); return memory
    }
    func ids(_ query: String, mode: SearchMode = .keyword, policy: SearchIndexPolicy = .exact) throws -> Set<String> {
        Set(try store.search(SearchFilter(query:query,limit:100),mode:mode,vector:mode == .keyword ? nil:vector,modelID:mode == .keyword ? nil:"fixture",minimumSimilarity:-1,indexPolicy:policy).map(\.id))
    }
    func testRequiredPhraseUsesAdjacentNormalizedTokensAndNeverPrefixDigits() throws {
        try source("exact","FRAME 21 launches Friday")
        try source("gap","Frame number 21 launches Friday")
        try source("prefix","Frame 210 launches Friday")
        try source("whitespace","Frame\n21 launches Friday")
        try source("title","Unrelated source text",title:"Frame 21")
        try source("other","Frame 19")
        for mode in [SearchMode.keyword,.hybrid,.semantic] {
            XCTAssertEqual(try ids(#""Frame 21""#,mode:mode),["exact","whitespace","title"])
            XCTAssertEqual(try ids("“Frame 21”",mode:mode),["exact","whitespace","title"])
        }
    }
    func testUnquotedQuestionsStaySoftAndOutsidePhraseWordsAreRankingCues() throws {
        try source("phrase","Mira owns archive launch")
        try source("words","Archive review for a different launch")
        XCTAssertFalse(try SearchExpressionPlan.make("Who owns archive launch?").hasConstraints)
        XCTAssertEqual(try ids("Who owns archive launch?"),["phrase","words"])
        XCTAssertEqual(try ids(#"missing-cue "archive launch""#),["phrase"])
        XCTAssertEqual(try ids(#""Mira owns" "archive launch""#),["phrase"])
    }
    func testBooleanPrecedenceGroupingNegationPrefixAndPositiveAnchors() throws {
        try source("ab","alpha beta")
        try source("ac","alpha comet")
        try source("b","beta")
        try source("c","comets")
        try source("bc","beta comet")
        XCTAssertEqual(try ids("alpha AND beta OR comet"),["ab","ac","c","bc"])
        XCTAssertEqual(try ids("alpha AND (beta OR comet)"),["ab","ac"])
        XCTAssertEqual(try ids("(alpha OR beta) NOT comet"),["ab","b"])
        XCTAssertEqual(try ids("alpha AND NOT (beta OR comet)"),[])
        XCTAssertEqual(try ids("NOT NOT alpha"),["ab","ac"])
        XCTAssertEqual(try ids("(NOT comet AND beta) OR alpha"),["ab","ac","b"])
        for query in ["NOT alpha","NOT alpha OR beta","alpha OR NOT beta","NOT (alpha AND beta)"] { XCTAssertThrowsError(try ids(query),query) }
    }
    func testExplicitWordsArePrefixesButQuotedPhrasesAreNot() throws {
        try source("exact","alpha beta")
        try source("prefix","alphabet betamax")
        XCTAssertEqual(try ids("alpha AND beta"),["exact","prefix"])
        XCTAssertEqual(try ids(#""alpha beta""#),["exact"])
        XCTAssertEqual(try ids(#""alpha beta" OR "alphabet betamax""#),["exact","prefix"])
    }
    func testLiteralModeDisablesBooleanAndPhraseConstraints() throws {
        try source("first","alpha")
        try source("second","beta")
        let plan = try SearchExpressionPlan.make(#""alpha beta" AND beta"#,interpret:false)
        XCTAssertFalse(plan.hasConstraints)
        XCTAssertEqual(Set(try store.search(SearchFilter(query:#""alpha beta" AND beta"#),mode:.keyword,expression:plan).map(\.id)),["first","second"])
    }
    func testMalformedOrExcessiveExpressionsFailWithoutBroadening() throws {
        for query in [#""unclosed"#, "alpha”", "”alpha", "AND alpha", "alpha AND", "alpha OR OR beta", "alpha AND (beta", "alpha AND ()", #""***""#, "alpha\0beta",String(repeating:"x",count:4001)] {
            XCTAssertThrowsError(try SearchExpressionPlan.make(query),query)
        }
        XCTAssertThrowsError(try SearchExpressionPlan.make(String(repeating:"NOT ",count:14)+"alpha"))
        XCTAssertThrowsError(try SearchExpressionPlan.make((0..<65).map { "word\($0)" }.joined(separator:" AND ")))
        XCTAssertThrowsError(try SearchExpressionPlan.make(String(repeating:#""word" "#,count:33)))
        XCTAssertFalse(try SearchExpressionPlan.make(String(repeating:"natural ",count:300)).hasConstraints)
    }
    func testQuotedInjectionIsDataAndEscapedQuotesRemainPhraseText() throws {
        try source("safe","Maya said \"archive launch\" today")
        try source("other","Archive unrelated launch")
        XCTAssertEqual(try ids(#""Maya said \"archive launch\"""#),["safe"])
        XCTAssertEqual(try ids(#""'; DROP TABLE memories; --""#),[])
        XCTAssertEqual(try store.stats(includeDiskUsage:false).count,2)
    }
    func testConstraintsAreEnforcedOnKeywordFullPreviewAndSemanticCandidates() async throws {
        for i in 0..<256 { try source("row-\(i)",i%2 == 0 ? "Maya owns archive":"Maya reviews archive") }
        _ = try await store.buildSearchIndex(modelID:"fixture",dimensions:2)
        let query = #""Maya owns" AND archive"#
        var strategy = ""
        let indexed = try store.search(SearchFilter(query:query,limit:5),mode:.semantic,vector:vector,modelID:"fixture",minimumSimilarity:-1,indexPolicy:.indexed) { strategy = $0.strategy }
        XCTAssertEqual(strategy,"ann-exact-rerank"); XCTAssertEqual(indexed.count,5)
        XCTAssertTrue(indexed.allSatisfy { Int($0.id.dropFirst(4))!%2 == 0 })
        let second = try store.search(SearchFilter(query:#""Maya reviews" AND archive"#,limit:5),mode:.semantic,vector:vector,modelID:"fixture",minimumSimilarity:-1,indexPolicy:.indexed)
        XCTAssertTrue(second.allSatisfy { Int($0.id.dropFirst(4))!%2 == 1 })
        for detail in [SearchDetail.full,.preview] {
            XCTAssertTrue(try store.search(SearchFilter(query:query,limit:100),mode:.hybrid,vector:vector,modelID:"fixture",minimumSimilarity:-1,detail:detail).allSatisfy { Int($0.id.dropFirst(4))!%2 == 0 })
        }
    }
    func testInvalidSyntaxPrecedesModelRequestsAndFallbackPreservesConstraints() async throws {
        try source("yes","archive launch")
        try source("no","archive unrelated launch")
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [ExpressionModelProtocol.self]
        let client = OllamaClient(session:URLSession(configuration:session)), engine = RetrievalEngine(store:store,client:client)
        var configuration = SearchConfiguration(); configuration.provider = .ollama
        ExpressionModelProtocol.requests.reset()
        do { _ = try await engine.search(SearchFilter(query:"alpha AND"),mode:.hybrid,configuration:configuration); XCTFail("Invalid Boolean query accepted") }
        catch is QuerySyntaxError {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertEqual(ExpressionModelProtocol.requests.value,0)
        let fallback = try await engine.search(SearchFilter(query:#""archive launch""#),mode:.hybrid,configuration:configuration)
        XCTAssertGreaterThan(ExpressionModelProtocol.requests.value,0); XCTAssertEqual(fallback.hits.map(\.id),["yes"]); XCTAssertFalse(fallback.warnings.isEmpty)
    }
    func testQuotedSpeakerNamesCombineWithSourceContentAndMetadata() throws {
        var memory = Memory(id:"speaker",kind:.audio,app:"Meetings",text:"Archive launch is Friday")
        memory.transcript = SpeechTranscript(text:memory.text,duration:2,segments:[TranscriptSegment(start:0,end:2,text:memory.text,speaker:"Maya Chen")],model:"fixture")
        memory.embedding = vector; memory.embeddingModel = "fixture"; try store.insert(memory)
        try source("other","Maya joined Chen for archive review")
        for mode in [SearchMode.keyword,.hybrid,.semantic] { XCTAssertEqual(try ids(#""Maya Chen" AND archive"#,mode:mode),["speaker"]) }
        let filter = SearchFilter(query:#""Maya Chen" AND archive"#,app:"Notes")
        XCTAssertTrue(try store.search(filter,mode:.keyword).isEmpty)
        _ = try store.renameAudioSpeaker("speaker",from:"Maya Chen",to:"Theo Chen")
        XCTAssertTrue(try ids(#""Maya Chen" AND archive"#).isEmpty)
        XCTAssertEqual(try ids(#""Theo Chen" AND archive"#),["speaker"])
    }
    func testRequiredReplayPhraseSelectsExactFrameRatherThanPrefixSibling() {
        let recording = VisualRecording(duration:2,width:1280,height:720,codec:"hevc",hardwareRequired:true,frames:[VisualFrame(time:0,text:"Frame 210",regions:[]),VisualFrame(time:1,text:"Frame 21",regions:[])])
        XCTAssertEqual(recording.frameTime(query:#""Frame 21""#),1)
        XCTAssertEqual(recording.frameTime(passage:recording.ranges()[0].range,query:#""Frame 21""#),1)
    }
    func testAskRequiresCurrentExpressionWithoutInheritingEarlierConstraints() async throws {
        try source("current","Maya owns archive launch")
        try source("old","Theo owns archive unrelated launch",app:"Other")
        let engine = AnswerEngine(store:store,embedder:LocalEmbedder())
        var configuration = AIConfiguration(); configuration.provider = .evidence
        let constrained = try await engine.answer(#""archive launch""#,configuration:configuration,previousQuestions:[#""archive unrelated launch""#])
        XCTAssertEqual(Set(constrained.sources.map(\.id)),["current"])
        let followup = try await engine.answer("Who owns archive? app:Other",configuration:configuration,previousQuestions:[#""archive launch""#])
        XCTAssertEqual(Set(followup.sources.map(\.id)),["old"])
    }
    func testMetalExpressionMasksAcrossQueriesAndUnreplayedContentChange() async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_EXPRESSION_METAL"] == "1" else { throw XCTSkip("Opt in to the owned 20k-vector Metal scope workload") }
        guard MetalFlatIndex.canFit(dimensions:32,count:20512) else { throw XCTSkip("Metal device unavailable") }
        for i in 0..<20000 {
            let vector = VectorScalingEvaluation.vector(row:i,dimensions:32)
            try store.insert(Memory(id:"metal-\(i)",timestamp:Date(timeIntervalSince1970:Double(i)),text:i%2 == 0 ? "even branch":"odd branch",embedding:vector,embeddingModel:"metal-expression"))
        }
        _ = try await store.buildSearchIndex(modelID:"metal-expression",dimensions:32,allowLowPower:true)
        let vector = VectorScalingEvaluation.vector(row:42,dimensions:32)
        var timings = [[String:Any]]()
        for phrase in [#""even branch""#,#""odd branch""#,#""even branch""#] {
            let filter = SearchFilter(query:phrase,limit:10)
            let exact = try store.search(filter,mode:.semantic,vector:vector,modelID:"metal-expression",minimumSimilarity:-1)
            var strategy = ""; let start = Date()
            let indexed = try store.search(filter,mode:.semantic,vector:vector,modelID:"metal-expression",minimumSimilarity:-1,indexPolicy:.indexed) { strategy = $0.strategy }
            XCTAssertTrue(strategy.hasPrefix("metal"),strategy); XCTAssertEqual(indexed.map(\.id),exact.map(\.id))
            timings.append(["query":phrase,"milliseconds":Date().timeIntervalSince(start)*1000,"strategy":strategy,"exact_top10_equal":indexed.map(\.id)==exact.map(\.id)])
        }
        var changed = try XCTUnwrap(store.get("metal-42")); changed.text = "odd branch"; try store.insert(changed)
        let scorer = try XCTUnwrap(CosineScorer(vector))
        // Use the old graph deliberately: both the required-query mask and the
        // live content revision must prevent returning a stale match.
        for phrase in [#""even branch""#,#""odd branch""#] {
            let filter = SearchFilter(query:phrase,limit:10), plan = try SearchExpressionPlan.make(phrase)
            let exact = try store.search(filter,mode:.semantic,vector:vector,modelID:"metal-expression",minimumSimilarity:-1)
            let old = try XCTUnwrap(store.indexedCandidates(filter,modelID:"metal-expression",dimensions:32,scorer:scorer,minimumSimilarity:-1,limit:10,expression:plan))
            XCTAssertEqual(old.map(\.id),exact.map(\.id))
        }
        print("Metal required-expression trial: "+String(data:try JSONSerialization.data(withJSONObject:timings,options:[.sortedKeys]),encoding:.utf8)!)
    }
    func testCancelledKeywordSQLLeavesTheConnectionAndNextQueryUsable() async throws {
        for i in 0..<1000 { try source("cancel-\(i)","alpha beta") }
        let latch = ExpressionCancelLatch(), context = Unmanaged.passUnretained(latch).toOpaque()
        try store.withRoutineDatabase { db in
            sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{ _,context,_,sql in
                if let context,let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).contains("FROM memory_fts f JOIN memories") {
                    Unmanaged<ExpressionCancelLatch>.fromOpaque(context).takeUnretainedValue().cancel()
                }
                return 0
            },context)
        }
        defer { try? store.withRoutineDatabase { sqlite3_trace_v2($0.handle,0,nil,nil) }; latch.clear(); withExtendedLifetime(latch) {} }
        let store = self.store!
        let worker = Task.detached {
            while !latch.installed { await Task.yield() }
            _ = try store.search(SearchFilter(query:#""alpha beta""#),mode:.keyword)
        }
        latch.install { worker.cancel() }
        do { try await worker.value; XCTFail("Expected SQL cancellation") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation: \(error)") }
        try store.withRoutineDatabase { sqlite3_trace_v2($0.handle,0,nil,nil) }
        XCTAssertEqual(try ids(#""alpha beta""#).count,100)
        try store.withRoutineDatabase { db in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db.handle,"SELECT COUNT(*) FROM sqlite_temp_master WHERE name='search_expression_scope'",-1,&statement,nil),SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(statement,0),0)
        }
        XCTAssertEqual(try store.stats(includeDiskUsage:false).count,1000)
    }
}
