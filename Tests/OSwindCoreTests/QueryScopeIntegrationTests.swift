import XCTest
import CSQLite
@testable import OSwindCore

final class QueryScopeIntegrationTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    let now = ISO8601DateFormatter().date(from:"2026-10-23T17:00:00Z")!
    let zone = TimeZone(identifier:"America/Los_Angeles")!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root)
        for (id,stamp,app,favorite,tags) in [("old","2026-10-21T20:00:00Z","Safari",false,[]),("start","2026-10-22T07:00:00Z","Safari",true,["work"]),("late","2026-10-23T06:59:59Z","Safari",false,[]),("end","2026-10-23T07:00:00Z","Safari",true,["work"]),("mail","2026-10-22T19:00:00Z","Mail",true,["work"])] {
            try store.insert(Memory(id:id,timestamp:ISO8601DateFormatter().date(from:stamp)!,kind:.note,app:app,text:"Comet decision for \(id). Content contains yesterday and app:Safari as words.",favorite:favorite,tags:tags))
        }
    }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    func testSharedEngineAppliesDateOperatorsAndBoundarySemantics() async throws {
        let result = try await RetrievalEngine(store:store).search(SearchFilter(query:"comet app:safari yesterday",limit:20),mode:.keyword,now:now,timeZone:zone)
        XCTAssertEqual(Set(result.hits.map(\.id)),["start","late"])
        XCTAssertEqual(result.resolution?.filter.app,"Safari"); XCTAssertEqual(result.resolution?.filter.query,"comet")
        XCTAssertEqual(result.resolution?.timeZone,zone.identifier)
        let saved = try await RetrievalEngine(store:store).search(SearchFilter(query:"app:Safari kind:note is:favorite tag:work yesterday"),mode:.keyword,now:now,timeZone:zone)
        XCTAssertEqual(saved.hits.map(\.id),["start"])
    }
    func testInvalidScopeEscapesHybridFallbackAndLiteralModeIsExplicit() async throws {
        var configuration = SearchConfiguration(); configuration.provider = .ollama; configuration.endpoint = "not-a-local-url"
        do {
            _ = try await RetrievalEngine(store:store).search(SearchFilter(query:"kind:invalid comet"),configuration:configuration,now:now,timeZone:zone)
            XCTFail("Invalid scope must fail before model fallback")
        } catch is QuerySyntaxError {} catch { XCTFail("Unexpected error: \(error)") }
        let literal = try await RetrievalEngine(store:store).search(SearchFilter(query:"kind:invalid comet"),configuration:configuration,interpretQuery:false,now:now,timeZone:zone)
        XCTAssertFalse(literal.hits.isEmpty); XCTAssertTrue(literal.resolution?.clauses.isEmpty == true); XCTAssertFalse(literal.warnings.isEmpty)
        XCTAssertNil(literal.resolution?.filter.kind)
        let words = try await RetrievalEngine(store:store).search(SearchFilter(query:"yesterday app:Safari",limit:20),mode:.keyword,interpretQuery:false,now:now,timeZone:zone)
        XCTAssertEqual(words.hits.count,5)
    }
    func testAppCatalogCanonicalizationSupportsUnicodeExactAndAmbiguousNames() throws {
        try store.insert(Memory(id:"unicode",app:"Éditeur",text:"Comet"))
        XCTAssertEqual(try store.resolveQueryScope(SearchFilter(query:"app:éditeur"),now:now,timeZone:zone).filter.app,"Éditeur")
        XCTAssertEqual(try store.resolveQueryScope(SearchFilter(query:"app:safari",app:"Safari"),now:now,timeZone:zone).filter.app,"Safari")
        for name in ["SAFARI","safari"] { try store.insert(Memory(app:name,text:"Comet")) }
        XCTAssertEqual(try store.resolveQueryScope(SearchFilter(query:"app:safari"),now:now,timeZone:zone).filter.app,"safari")
        XCTAssertThrowsError(try store.resolveQueryScope(SearchFilter(query:"app:SafAri"),now:now,timeZone:zone))
        XCTAssertThrowsError(try store.resolveQueryScope(SearchFilter(query:"app:Safari",app:"safari"),now:now,timeZone:zone))
    }
    func testCurrentQuestionScopeIsPersistedWithoutReinterpretingOldQuestionDates() async throws {
        var configuration = AIConfiguration(); configuration.provider = .evidence
        let engine = AnswerEngine(store:store,embedder:LocalEmbedder())
        let answer = try await engine.answer("Comet yesterday app:Safari",configuration:configuration,previousQuestions:["What did we decide last week app:Mail?"],now:now,timeZone:zone)
        XCTAssertEqual(Set(answer.sources.map(\.id)),["start","late"])
        let id = try store.createChat().id
        // Caller deliberately passes the old broad filter: storage must retain
        // the actual answer's resolved scope, not an unrelated UI snapshot.
        let turn = try store.appendChatTurn(sessionID:id,question:"Comet yesterday app:Safari",answer:answer)
        XCTAssertEqual(turn.filter.start,answer.resolution?.filter.start); XCTAssertEqual(turn.filter.end,answer.resolution?.filter.end)
        XCTAssertEqual(turn.filter.app,"Safari"); XCTAssertEqual(turn.filter.query,""); XCTAssertEqual(turn.timeZone,zone.identifier)
        let reopened = try MemoryStore(root:root), loaded = try XCTUnwrap(reopened.chatTurns(id).first)
        XCTAssertEqual(loaded.filter,turn.filter); XCTAssertEqual(loaded.timeZone,zone.identifier)
        let markdown = ConversationContext.markdown(try XCTUnwrap(reopened.chat(id)),turns:[loaded])
        XCTAssertTrue(markdown.contains(zone.identifier)); XCTAssertTrue(markdown.contains("2026-10-23T07:00:00Z"))
        let followup = try await engine.answer("Comet decision",configuration:configuration,filter:SearchFilter(app:"Safari"),previousQuestions:["Comet yesterday app:Mail"],now:now,timeZone:zone)
        XCTAssertNil(followup.resolution?.filter.start); XCTAssertNil(followup.resolution?.filter.end)
        XCTAssertEqual(followup.resolution?.filter.app,"Safari"); XCTAssertEqual(followup.sources.count,4)
    }
    func testSummaryUsesOnlyCurrentResolvedTimelineAndLiteralModeKeepsWords() async throws {
        var configuration = AIConfiguration(); configuration.provider = .evidence
        let engine = AnswerEngine(store:store,embedder:LocalEmbedder())
        let recap = try await engine.answer("Summarize yesterday app:Safari",configuration:configuration,summarize:true,previousQuestions:["last month app:Mail"],now:now,timeZone:zone)
        XCTAssertEqual(Set(recap.sources.map(\.id)),["start","late"])
        let literal = try await engine.answer("Comet yesterday",configuration:configuration,filter:SearchFilter(app:"Safari"),interpretQuery:false,now:now,timeZone:zone)
        XCTAssertNil(literal.resolution?.filter.start); XCTAssertEqual(literal.sources.count,4)
    }
    func testLegacyAnswerAndChatTurnDecodeWithoutOptionalScopeMetadata() throws {
        let answer = Data(#"{"text":"Legacy","sources":[],"provider":"evidence","duration":0,"warnings":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Answer.self,from:answer).resolution)
        let turn = ChatTurn(id:"turn",sessionID:"session",timestamp:now,question:"Legacy",answer:try JSONDecoder().decode(Answer.self,from:answer),filter:SearchFilter())
        var value = try JSONSerialization.jsonObject(with:JSONEncoder().encode(turn)) as! [String:Any]; value.removeValue(forKey:"timeZone")
        let decoded = try JSONDecoder().decode(ChatTurn.self,from:JSONSerialization.data(withJSONObject:value))
        XCTAssertNil(decoded.timeZone); XCTAssertEqual(decoded.question,"Legacy")
    }
    func testHTTPFormSpacesPreserveScopeAndEncodedPlusRemainsLiteral() async throws {
        let server = try LocalAPIServer(store:store,embedder:LocalEmbedder())
        func request(_ query: String) -> String { "GET /v1/search?mode=keyword&\(query) HTTP/1.1\r\nHost: 127.0.0.1:47831\r\nAuthorization: Bearer \(server.token)\r\n\r\n" }
        let form = await server.handle(request("query=Comet+app%3ASafari+since%3A2026-10-22T07%3A00%3A00Z+until%3A2026-10-23T07%3A00%3A00Z"))
        XCTAssertEqual(form.0,200)
        let body = try XCTUnwrap(form.1 as? [String:Any]), resolution = try XCTUnwrap(body["resolution"] as? [String:Any])
        let filter = try XCTUnwrap(resolution["filter"] as? [String:Any])
        XCTAssertEqual(filter["app"] as? String,"Safari"); XCTAssertEqual(filter["start"] as? String,"2026-10-22T07:00:00Z")
        let plus = await server.handle(request("query=C%2B%2B&literal=true"))
        XCTAssertEqual(plus.0,200)
        let plusResolution = try XCTUnwrap((plus.1 as? [String:Any])?["resolution"] as? [String:Any])
        XCTAssertEqual(plusResolution["originalQuery"] as? String,"C++")
    }
    func testStructuredParametersRejectWrongTypesUnknownFieldsAndInvalidInstants() throws {
        for args: [String:Any] in [["app":42],["query":false],["kind":3],["start":false],["end":"2026-02-30T12:00:00Z"],["start":"2026-10-22"],["literal":1],["favorites":0],["limit":true],["limit":2.5],["limit":0],["limit":101],["limt":5],["query":String(repeating:"x",count:4001)]] {
            XCTAssertThrowsError(try Integration.filter(args),String(describing:args.keys))
        }
        XCTAssertEqual(try Integration.filter(["favorites":true,"literal":false,"limit":5]).limit,5)
        XCTAssertEqual(try Integration.filter(["start":"2026-10-22T12:30:00.125Z"]).start!.timeIntervalSince1970,ISO8601DateFormatter().date(from:"2026-10-22T12:30:00Z")!.timeIntervalSince1970+0.125,accuracy:0.00001)
    }
    func testHTTPAndMCPReturnResolvedScopeAndRejectInvalidLiteralTypes() async throws {
        let query = "comet app:Safari on:2026-10-22", args: [String:Any] = ["query":query,"mode":"keyword"]
        let result = try await Integration.execute("search_memory",args:args,store:store,embedder:LocalEmbedder()) as! [String:Any]
        XCTAssertNotNil(result["resolution"])
        let server = try LocalAPIServer(store:store,embedder:LocalEmbedder())
        func request(_ suffix: String) -> String { "GET /v1/search?mode=keyword&query=\(query.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed)!)\(suffix) HTTP/1.1\r\nHost: 127.0.0.1:47831\r\nAuthorization: Bearer \(server.token)\r\n\r\n" }
        let good = await server.handle(request("&literal=false")), badLiteral = await server.handle(request("&literal=maybe"))
        XCTAssertEqual(good.0,200); XCTAssertEqual(badLiteral.0,400)
        let duplicate = await server.handle(request("&app=Safari&app=Mail")), invalidLimit = await server.handle(request("&limit=oops"))
        XCTAssertEqual(duplicate.0,400); XCTAssertEqual(invalidLimit.0,400)
        let scope = try XCTUnwrap((good.1 as? [String:Any])?["resolution"] as? [String:Any])
        XCTAssertEqual(scope["timeZone"] as? String,TimeZone.current.identifier)
        XCTAssertEqual((scope["filter"] as? [String:Any])?["app"] as? String,"Safari")
        let bad = await Integration.rpc(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"search_memory","arguments":["query":"on:2026-02-30"]]],store:store,embedder:LocalEmbedder())
        XCTAssertEqual((bad?["result"] as? [String:Any])?["isError"] as? Bool,true)
        XCTAssertThrowsError(try Integration.filter(["literal":"true"]))
    }
}
