import XCTest
@testable import OSwindCore

final class RecordingScopeTests:XCTestCase {
    private var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recording-scope-"+UUID().uuidString);store=try MemoryStore(root:root.appendingPathComponent("library"))}
    override func tearDownWithError()throws {try store.close();try FileManager.default.removeItem(at:root)}
    @discardableResult private func audio(_ id:String,_ session:String?,text:String="Apollo owner Mira")throws->Memory {
        var m=Memory(id:id,timestamp:Date(timeIntervalSince1970:100),kind:.audio,app:"Authored scope",title:"Same title",text:text)
        m.audioSessionID=session;m.transcript = .init(text:text,duration:30,segments:[.init(start:0,end:30,text:text)],model:"Authored fixture")
        try store.insert(m);return m
    }
    func testSessionSelectsAllMatchingClipsAndNeverNeighborsWithSameTimeTitleOrWords()throws {
        for index in 0..<520 {try audio("a-\(index)","selected")}
        try audio("neighbor","other");try audio("legacy",nil)
        var f=SearchFilter(query:"Apollo",recordingScope:try .init(sessionID:"selected"));f.limit=500
        let result=try store.search(f,mode:.keyword)
        XCTAssertEqual(result.count,500);XCTAssertTrue(result.allSatisfy {$0.memory.audioSessionID=="selected"})
        XCTAssertEqual(try store.matchingCount(SearchFilter(recordingScope:f.recordingScope)),520)
        XCTAssertTrue(try store.timelineSample(f).allSatisfy {$0.audioSessionID=="selected"})
        try audio("new-clip","selected");XCTAssertEqual(try store.matchingCount(SearchFilter(recordingScope:f.recordingScope)),521)
    }
    func testSingleSourceVersionDoesNotFollowAnEditedOrReplacedClip()throws {
        var source=try audio("clip",nil),f=SearchFilter(recordingScope:try .init(sourceID:source.id,revision:source.evidenceHash))
        XCTAssertEqual(try store.search(f,mode:.keyword).map(\.id),["clip"])
        source.text="Apollo owner Bob";source.transcript?.text=source.text;source.transcript?.segments[0].text=source.text;try store.insert(source)
        XCTAssertTrue(try store.search(f,mode:.keyword).isEmpty)
        f.recordingScope = .unavailable;XCTAssertThrowsError(try store.resolveQueryScope(f))
    }
    func testCodecRoundTripAndOlderStringKindReaderRefusesRestriction()throws {
        struct OlderFilter:Decodable {let kind:MemoryKind?}
        let original=SearchFilter(recordingScope:try .init(sessionID:"e\u{301}\0session")),encoded=try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(SearchFilter.self,from:encoded),original)
        XCTAssertThrowsError(try JSONDecoder().decode(OlderFilter.self,from:encoded))
        let plain=SearchFilter(kind:.audio);XCTAssertNoThrow(try JSONDecoder().decode(OlderFilter.self,from:JSONEncoder().encode(plain)))
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any]);json.removeValue(forKey:"recordingScope")
        XCTAssertThrowsError(try JSONDecoder().decode(SearchFilter.self,from:JSONSerialization.data(withJSONObject:json)))
    }
    func testScopeRecheckedAfterRegroupingAndSavedAnswerCannotBroadenIt()throws {
        var source=try audio("a","selected");let scope=try RecordingScope(sessionID:"selected"),hit=SearchHit(memory:source,score:1,match:"authored")
        source.audioSessionID="other";try store.insert(source)
        XCTAssertThrowsError(try store.requireRecordingEvidence([hit],scope:scope),"Evidence hash alone does not detect regrouping")
        XCTAssertThrowsError(try store.saveChatTurn(question:"Who?",answer:.init(text:"Mira [1]",sources:[hit],provider:"evidence",duration:0),filter:.init(recordingScope:scope)))
        XCTAssertTrue(try store.chats().isEmpty)
    }
    func testEvidenceOnlyAnswerAndSavedHistoryKeepScopeWithoutModelCalls()async throws {
        try audio("allowed","selected");try audio("wrong","other",text:"Apollo owner Bob")
        let scope=try RecordingScope(sessionID:"selected"),configuration=AIConfiguration()
        var ai=configuration;ai.provider = .evidence
        let answer=try await AnswerEngine(store:store,embedder:LocalEmbedder(loadModel:{nil})).answer("Apollo owner",configuration:ai,filter:.init(recordingScope:scope),searchConfiguration:SearchConfiguration(),interpretQuery:false)
        XCTAssertEqual(answer.sources.map(\.id),["allowed"]);XCTAssertEqual(answer.resolution?.filter.recordingScope,scope)
        let turn=try store.saveChatTurn(question:"Who owns Apollo?",answer:answer,filter:.init(recordingScope:scope))
        XCTAssertEqual(try store.chatTurns(turn.sessionID).first?.filter.recordingScope,scope)
        XCTAssertThrowsError(try store.appendChatTurn(sessionID:turn.sessionID,question:"Forgot scope",answer:Answer(text:"No evidence",sources:[],provider:"evidence",duration:0)))
        XCTAssertEqual(try store.chatTurns(turn.sessionID).count,1)
    }
    func testActualCLIRecordingFollowupExcludesNeighborAgainstRetainedUnscopedControl()throws {
        let environment=ProcessInfo.processInfo.environment
        guard let current=environment["OSWIND_RECORDING_CURRENT_CLI"],let negative=environment["OSWIND_RECORDING_UNSCOPED_CLI"] else {throw XCTSkip("Explicit current CLI and retained development-v10 control required")}
        let source=try audio("allowed","selected");try audio("neighbor","other",text:"Apollo owner Bob")
        let answer=Answer(text:"Mira [1]",sources:[.init(memory:source,score:1,match:"owned")],provider:"evidence",duration:0),scope=SearchFilter(recordingScope:try .init(sessionID:"selected"))
        let control=try store.saveChatTurn(question:"Apollo owner",answer:answer,filter:scope),fixed=try store.saveChatTurn(question:"Apollo owner",answer:answer,filter:scope)
        try store.close()
        func ask(_ binary:String,_ id:String,_ label:String)throws {
            let process=Process(),output=Pipe(),error=Pipe();process.executableURL=URL(fileURLWithPath:binary);process.arguments=["chat","ask",id,"Apollo owner","--provider","evidence","--literal","--data",store.root.path];process.standardOutput=output;process.standardError=error
            try process.run();process.waitUntilExit()
            let stdout=output.fileHandleForReading.readDataToEndOfFile(),stderr=error.fileHandleForReading.readDataToEndOfFile()
            XCTAssertEqual(process.terminationStatus,0,String(decoding:stderr,as:UTF8.self))
            if let path=environment["OSWIND_RECORDING_CLI_QA_DIR"] {
                let out=URL(fileURLWithPath:path);try Paths.ensure(out);try stdout.write(to:out.appendingPathComponent(label+".stdout"));try stderr.write(to:out.appendingPathComponent(label+".stderr"))
            }
        }
        try ask(negative,control.sessionID,"retained-unscoped-control");try ask(current,fixed.sessionID,"current-scoped-followup")
        store=try MemoryStore(root:store.root)
        let bad=try XCTUnwrap(store.chatTurns(control.sessionID).last),good=try XCTUnwrap(store.chatTurns(fixed.sessionID).last)
        XCTAssertNil(bad.filter.recordingScope);XCTAssertEqual(Set(bad.answer.sources.map(\.id)),Set(["allowed","neighbor"]))
        XCTAssertEqual(good.filter.recordingScope,scope.recordingScope);XCTAssertEqual(good.answer.sources.map(\.id),["allowed"])
        XCTAssertEqual(try store.chatTurns(fixed.sessionID).count,2)
        print("OWNED_RECORDING_CLI negativeNeighborIncluded=true currentNeighborExcluded=true scopePreserved=true")
    }
    func testCalendarSerializationAndVectorMaskCacheKeepRecordingRestriction()throws {
        let a=try RecordingScope(sessionID:"é"),b=try RecordingScope(sessionID:"e\u{301}")
        XCTAssertNotEqual(a,b)
        let scope=ActivitySourceScope(SearchFilter(recordingScope:a))
        XCTAssertEqual(try JSONDecoder().decode(ActivitySourceScope.self,from:JSONEncoder().encode(scope)).filter.recordingScope,a)
        struct OlderCalendarScope:Decodable {let kind:MemoryKind?}
        XCTAssertThrowsError(try JSONDecoder().decode(OlderCalendarScope.self,from:JSONEncoder().encode(scope)))
        let first=MetalScopeKey(identity:"owned",model:"owned",sequence:0,revision:"owned",predicate:"recording_id=?",values:[a.id!])
        var second=first;second.values=[b.id!];XCTAssertNotEqual(first,second)
        var cache=MetalScopeCache();cache.insert(.init(key:first,allowed:[1]));XCTAssertNil(cache.lookup(second));XCTAssertEqual(cache.lookup(first),[1])
    }
    func testScopedCalendarIntersectsTagAndEvidenceValidationCanJoinOwnedTransaction()throws {
        let allowed=try audio("allowed","selected");try audio("untagged","selected");try audio("neighbor","other")
        try store.setTags("allowed",tags:["work"]);try store.setTags("neighbor",tags:["work"])
        let scope=try RecordingScope(sessionID:"selected"),f=SearchFilter(tag:"work",recordingScope:scope)
        let calendar=try store.activityCalendar(.init(month:"1970-01",timeZone:TimeZone(secondsFromGMT:0)!,filter:f))
        XCTAssertEqual(calendar.totalSources,1);XCTAssertEqual(calendar.scope.filter.recordingScope,scope);XCTAssertEqual(calendar.scope.tag,"work")
        try store.withRoutineDatabase {db in try db.transaction {try store.requireRecordingEvidence([.init(memory:allowed,score:1,match:"owned")],scope:scope)}}
    }
    func testReadyRecordingScopeReadsWhileOtherConnectionOwnsCaptureWriteTransaction()throws {
        let source=try audio("allowed","selected"),filter=SearchFilter(query:"Apollo",recordingScope:try .init(sessionID:"selected"))
        XCTAssertEqual(try store.search(filter,mode:.keyword).map(\.id),["allowed"])
        let writer=try MemoryStore(root:store.root);defer {try? writer.close()}
        try writer.withRoutineDatabase {db in try db.transaction {
            // The write reservation remains live until the reader returns.
            XCTAssertEqual(try store.search(filter,mode:.keyword).map(\.id),["allowed"])
            try store.requireRecordingEvidence([.init(memory:source,score:1,match:"owned")],scope:filter.recordingScope)
        }}
    }
    func testQuietBackupRestoreKeepsScopedHistoryAndEvidenceVersion()throws {
        let source=try audio("a","selected");try audio("neighbor","other")
        let scope=try RecordingScope(sourceID:source.id,revision:source.evidenceHash)
        let turn=try store.saveChatTurn(question:"Who?",answer:.init(text:"Mira [1]",sources:[.init(memory:source,score:1,match:"owned")],provider:"evidence",duration:0),filter:.init(recordingScope:scope))
        let archive=root.appendingPathComponent("owned.oswindbackup"),destination=root.appendingPathComponent("restored")
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:destination)
        let restored=try MemoryStore(root:destination);defer {try? restored.close()}
        let retained=try XCTUnwrap(restored.chatTurns(turn.sessionID).first?.filter.recordingScope)
        XCTAssertEqual(retained,scope);XCTAssertEqual(try restored.search(.init(recordingScope:retained),mode:.keyword).map(\.id),["a"])
    }
    func testScopedMCPAndHTTPQueriesIntersectRecordingAndRejectUnavailableOrMalformedScope()async throws {
        try audio("allowed","selected");try audio("neighbor","other")
        let selected:[String:Any] = ["selector":"session","id":"selected"],embedder=LocalEmbedder(loadModel:{nil})
        let filter=try Integration.filter(["recordingScope":selected,"query":"Apollo","mode":"keyword"])
        XCTAssertEqual(try store.search(filter,mode:.keyword).map(\.id),["allowed"])
        XCTAssertThrowsError(try Integration.filter(["recordingScope":["selector":"source","id":"allowed"]]))
        let response=try await Integration.execute("search_memory",args:["recordingScope":selected,"query":"Apollo","mode":"keyword"],store:store,embedder:embedder)
        let result=try XCTUnwrap(response as? [String:Any]),hits=try XCTUnwrap(result["hits"] as? [[String:Any]])
        XCTAssertEqual(hits.compactMap {($0["memory"] as? [String:Any])?["id"] as? String},["allowed"])
        let server=try LocalAPIServer(store:store,embedder:embedder)
        func request(_ object:[String:Any])throws->String {
            let json=String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
            var url=URLComponents();url.path="/v1/search";url.queryItems=[.init(name:"recordingScope",value:json),.init(name:"query",value:"Apollo"),.init(name:"mode",value:"keyword")]
            return "GET \(url.string!) HTTP/1.1\r\nHost: 127.0.0.1:47831\r\nAuthorization: Bearer \(server.token)\r\n\r\n"
        }
        let success=await server.handle(try request(selected));XCTAssertEqual(success.0,200)
        let refused=await server.handle(try request(["selector":"unavailable"]));XCTAssertEqual(refused.0,400)
        let schema=try XCTUnwrap(Integration.tools.first {$0["name"] as? String=="search_memory"}?["inputSchema"] as? [String:Any])
        XCTAssertNotNil((schema["properties"] as? [String:Any])?["recordingScope"])
    }
    func testActualPriorReaderShowsPlainChatAndRefusesRecordingScopedChat()throws {
        guard let binary=ProcessInfo.processInfo.environment["OSWIND_RECORDING_OLD_CLI"] else {throw XCTSkip("Explicit frozen prior reader required")}
        let source=try audio("a","selected"),answer=Answer(text:"Owned reader control [1]",sources:[.init(memory:source,score:1,match:"owned")],provider:"evidence",duration:0)
        let plain=try store.saveChatTurn(question:"Plain control",answer:answer),scoped=try store.saveChatTurn(question:"Scoped control",answer:answer,filter:.init(recordingScope:try .init(sessionID:"selected")))
        try store.close()
        func read(_ id:String)throws->(Int32,String) {
            let process=Process(),output=Pipe(),error=Pipe();process.executableURL=URL(fileURLWithPath:binary);process.arguments=["chat","show",id,"--data",store.root.path];process.standardOutput=output;process.standardError=error
            try process.run();process.waitUntilExit()
            return (process.terminationStatus,String(decoding:output.fileHandleForReading.readDataToEndOfFile()+error.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self))
        }
        let control=try read(plain.sessionID);XCTAssertEqual(control.0,0);XCTAssertTrue(control.1.contains("Plain control"))
        let refused=try read(scoped.sessionID);XCTAssertNotEqual(refused.0,0);XCTAssertFalse(refused.1.contains("Owned reader control"))
        store=try MemoryStore(root:store.root);XCTAssertEqual(try store.chatTurns(scoped.sessionID).first?.filter.recordingScope?.id,"selected")
        XCTAssertEqual(try store.get("a")?.evidenceHash,source.evidenceHash)
        print("OWNED_RECORDING_OLD_READER plainExit=\(control.0) scopedExit=\(refused.0) currentScopePreserved=true")
    }
}
