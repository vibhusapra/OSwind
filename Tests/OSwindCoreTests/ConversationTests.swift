import XCTest
import CSQLite
@testable import OSwindCore

final class ConversationTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    func source(_ id: String = "source", text: String = "Maya owns the release; deadline Friday.") throws -> Memory { let memory = Memory(id:id,kind:.note,app:"Notes",title:"Release decision",text:text); try store.insert(memory); return memory }
    func answer(_ memory: Memory) -> Answer { Answer(text:"Maya owns it [1].",sources:[SearchHit(memory:memory,score:0.8,match:"semantic")],provider:"fixture",duration:0.2) }
    func testConversationSurvivesReopenAndHydratesCurrentMetadata() throws {
        let memory = try source(), chat = try store.createChat()
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Who owns the release?",answer:answer(memory),filter:SearchFilter(query:"unrelated private search",app:"Notes"))
        store = nil; store = try MemoryStore(root:root); try store.setFavorite(memory.id,value:true)
        let turns = try store.chatTurns(chat.id)
        XCTAssertEqual(turns.count,1); XCTAssertEqual(turns[0].answer.sources[0].id,memory.id); XCTAssertTrue(turns[0].answer.sources[0].memory.favorite)
        XCTAssertEqual(turns[0].filter.app,"Notes"); XCTAssertEqual(turns[0].filter.query,""); XCTAssertEqual(try store.chat(chat.id)?.title,"Who owns the release?")
    }
    func testSourceErasureRemovesDerivedTurnButPreservesOtherConversation() throws {
        let first = try source(), second = try source("other",text:"A separate recipe"), chat = try store.createChat()
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Release?",answer:answer(first))
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Recipe?",answer:answer(second))
        try store.delete(first.id)
        XCTAssertEqual(try store.chatTurns(chat.id).map(\.question),["Recipe?"])
        XCTAssertEqual(try store.chat(chat.id)?.turnCount,1)
        XCTAssertEqual(try store.chat(chat.id)?.title,"Conversation")
    }
    func testSourceEditInvalidatesSavedAnswerAndInflightSnapshot() throws {
        let original = try source(), chat = try store.createChat()
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Owner?",answer:answer(original))
        try store.insert(Memory(id:original.id,text:"Changed private evidence"))
        XCTAssertTrue(try store.chatTurns(chat.id).isEmpty)
        XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Stale?",answer:answer(original)))
        XCTAssertEqual(try store.chat(chat.id)?.turnCount,0)
    }
    func testDeletedSessionCannotBeResurrectedByInflightAnswer() throws {
        let memory = try source(), chat = try store.createChat(); try store.deleteChat(chat.id)
        XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Owner?",answer:answer(memory)))
        XCTAssertTrue(try store.chats().isEmpty)
    }
    func testSourceDateAndKindChangesInvalidateSavedAndInflightClaims() throws {
        for field in ["date","kind"] {
            let original = try source(field), chat = try store.createChat()
            _ = try store.appendChatTurn(sessionID:chat.id,question:"When and what?",answer:answer(original))
            var changed = original
            if field == "date" { changed.timestamp = original.timestamp.addingTimeInterval(86400) }
            else { changed.kind = .audio }
            XCTAssertEqual(changed.contentHash,original.contentHash)
            XCTAssertNotEqual(changed.evidenceHash,original.evidenceHash)
            try store.insert(changed)
            XCTAssertTrue(try store.chatTurns(chat.id).isEmpty)
            XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Stale date/kind?",answer:answer(original)))
            XCTAssertEqual(try store.chat(chat.id)?.title,"Conversation")
        }
    }
    func testPartialSourceFailureRollsBackEntireTurn() throws {
        let memory = try source(), chat = try store.createChat(); var result = answer(memory)
        result.sources.append(SearchHit(memory:Memory(id:"missing",text:"missing"),score:1,match:"test"))
        XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Owner?",answer:result))
        XCTAssertTrue(try store.chatTurns(chat.id).isEmpty)
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Valid?",answer:answer(memory))
        XCTAssertEqual(try store.chat(chat.id)?.turnCount,1)
    }
    func testDeleteAllAlsoErasesSourcelessChats() throws {
        let chat = try store.createChat()
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Unknown?",answer:Answer(text:"No evidence",sources:[],provider:"evidence",duration:0))
        try store.deleteAll(); XCTAssertTrue(try store.chats().isEmpty); XCTAssertTrue(try store.chatTurns(chat.id).isEmpty)
    }
    func testFollowupContextDoesNotTreatEarlierModelOutputAsEvidence() throws {
        let memory = try source(), chat = try store.createChat(); var result = answer(memory); result.text = "INVENTED MODEL FACT [1]"
        let turn = try store.appendChatTurn(sessionID:chat.id,question:"Who owns the release?",answer:result)
        let history = ConversationContext.questions([turn]), query = ConversationContext.retrievalQuery("And the deadline?",previousQuestions:history)
        XCTAssertTrue(query.contains("release")); XCTAssertTrue(query.contains("deadline")); XCTAssertFalse(query.contains("INVENTED"))
        let export = ConversationContext.markdown(try XCTUnwrap(store.chat(chat.id)),turns:[turn])
        XCTAssertTrue(export.contains("[1] Release decision")); XCTAssertTrue(export.contains("Memory ID:")); XCTAssertFalse(export.contains(root.path))
    }
    func testSchemaTwoMigrationPreservesMemories() throws {
        _ = try source(); store = nil
        var connection: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&connection),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection,"DROP TRIGGER chat_source_erasure; DROP TRIGGER chat_source_revision; DROP TABLE chat_sources; DROP TABLE chat_turns; DROP TABLE chat_sessions; PRAGMA user_version=2;",nil,nil,nil),SQLITE_OK); sqlite3_close(connection)
        store = try MemoryStore(root:root); XCTAssertNotNil(try store.get("source")); XCTAssertTrue(try store.chats().isEmpty)
        let session = try store.createChat(); XCTAssertNotNil(try store.chat(session.id))
    }
    func testFutureSchemaIsRejectedWithoutDowngrade() throws {
        store = nil; var connection: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&connection),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection,"PRAGMA user_version=99;",nil,nil,nil),SQLITE_OK)
        XCTAssertThrowsError(try MemoryStore(root:root))
        var statement: OpaquePointer?; sqlite3_prepare_v2(connection,"PRAGMA user_version",-1,&statement,nil); XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(statement,0),99); sqlite3_finalize(statement); sqlite3_close(connection)
    }
    func testRetentionErasesSourcelessTurnAndItsTitle() throws {
        let chat = try store.createChat()
        _ = try store.appendChatTurn(sessionID:chat.id,question:"An old question",answer:Answer(text:"No evidence",sources:[],provider:"evidence",duration:0))
        _ = try store.prune(before:Date().addingTimeInterval(1))
        XCTAssertTrue(try store.chatTurns(chat.id).isEmpty); XCTAssertEqual(try store.chat(chat.id)?.title,"Conversation")
    }
    func testClaimRenderingRejectsUnbackedOrInvalidCitations() throws {
        XCTAssertEqual(try AnswerEngine.renderClaims([("Maya owns it [9]",[1,1])],sourceCount:2,insufficientEvidence:false),"Maya owns it [1]")
        for sources in [[],[0],[3]] { XCTAssertThrowsError(try AnswerEngine.renderClaims([("Unsupported",sources)],sourceCount:2,insufficientEvidence:false)) }
        XCTAssertThrowsError(try AnswerEngine.renderClaims([],sourceCount:1,insufficientEvidence:false))
        XCTAssertTrue(try AnswerEngine.renderClaims([],sourceCount:1,insufficientEvidence:true).contains("enough recorded evidence"))
        XCTAssertFalse(AnswerEngine.citationWarnings("An answer [oops]",sourceCount:2).isEmpty)
        XCTAssertFalse(AnswerEngine.citationWarnings("An answer [99]",sourceCount:2).isEmpty)
        XCTAssertTrue(AnswerEngine.citationWarnings("An answer [1]",sourceCount:2).isEmpty)
    }
}
