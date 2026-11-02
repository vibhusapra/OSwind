import XCTest
import CSQLite
@testable import OSwindCore

final class ChatAdmissionTests:XCTestCase {
    var root:URL!,store:MemoryStore!,source:Memory!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-chat-admission-"+UUID().uuidString);store=try MemoryStore(root:root)
        source=Memory(id:"original",kind:.note,text:"An authored source for atomic conversation admission");try store.insert(source)
    }
    override func tearDownWithError()throws {try store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func answer(_ source:Memory)->Answer {.init(text:"An authored answer [1].",sources:[.init(memory:source,score:1,match:"owned")],provider:"evidence",duration:0)}
    func testOuterRollbackRemovesWholeFirstConversationAndTurn()throws {
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction { ()throws->Void in
            let turn=try store.saveChatTurn(question:"Owned question",answer:answer(source))
            XCTAssertEqual(try store.chats().count,1);XCTAssertEqual(try store.chatTurns(turn.sessionID).count,1)
            throw OSwindError.unavailable("Owned outer rollback")
        }})
        XCTAssertTrue(try store.chats().isEmpty);XCTAssertNotNil(try store.get(source.id))
    }
    func testRejectedNestedAdmissionPreservesOuterConversationAndCommit()throws {
        let unrelated=try store.withRoutineDatabase {db in try db.transaction {
            let unrelated=try store.createChat(title:"Owned unrelated conversation")
            var changed=source!;changed.text="This revision was never stored"
            XCTAssertThrowsError(try store.saveChatTurn(question:"Owned rejected question",answer:answer(changed)))
            return unrelated
        }}
        XCTAssertEqual(try store.chats().map(\.id),[unrelated.id]);XCTAssertEqual(try store.chatTurns(unrelated.id).count,0)
        XCTAssertEqual(try store.get(source.id)?.text,source.text)
    }
    func testRejectedFollowupPreservesExistingCommittedTurn()throws {
        let first=try store.saveChatTurn(question:"Owned initial question",answer:answer(source));var changed=source!;changed.text="An uncommitted different revision"
        XCTAssertThrowsError(try store.saveChatTurn(sessionID:first.sessionID,question:"Owned rejected followup",answer:answer(changed)))
        XCTAssertEqual(try store.chats().count,1);XCTAssertEqual(try store.chatTurns(first.sessionID).map(\.id),[first.id])
        try store.close();store=try MemoryStore(root:root);XCTAssertEqual(try store.chatTurns(first.sessionID).map(\.id),[first.id])
    }
    func testCancellationDuringActualTurnInsertRollsBackWholeNewConversation()async throws {
        let store=self.store!,answer=answer(source)
        try store.withRoutineDatabase {db in
            sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,_,_,sql in
                if let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("INSERT INTO chat_turns(") {withUnsafeCurrentTask {$0?.cancel()}}
                return 0
            },nil)
        }
        defer {try? store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}}
        let worker=Task.detached {try store.saveChatTurn(question:"Owned interrupted question",answer:answer)}
        do {_ = try await worker.value;XCTFail("Mid-transaction cancellation committed")}
        catch is CancellationError {}catch {XCTFail("Expected cooperative cancellation")}
        XCTAssertTrue(try store.chats().isEmpty);XCTAssertNotNil(try store.get("original"))
    }
}
