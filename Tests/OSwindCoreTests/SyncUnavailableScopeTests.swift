import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testUnseenTurnWithErasedEntityScopeKeepsAnswerWithoutBecomingUnscoped()throws {
        let eraser="00000000-0000-0000-0000-000000006191"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("eraser",eraser)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(eraser);try cc.journal.allowPeer(producerID)
        let entity=try a.createEntity(kind:.project,name:"Owned original scope"),chat=try a.createChat(title:"Keep this independent conversation")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Question in the original scope",answer:.init(text:"Keep this exact answer",sources:[],provider:"owned",duration:0),filter:SearchFilter(entityID:entity.id))
        try drain(a,ac)
        let initial=try ac.journal.outbox(),operation=try XCTUnwrap(initial.last {$0.key.kind == .turn}),record=try packet(operation,ac)
        guard case .turn(let body)=record.body else {return XCTFail("Expected an actual native turn")}
        let scope=try XCTUnwrap(body.filter.entity);var eraserLocal:String?,chatLocal:String?
        for preceding in initial where preceding.dot.counter<operation.dot.counter {
            let value=try packet(preceding,ac),local=try receive(preceding,value,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            let thirdLocal=try receive(preceding,value,c,cc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if value.identity==scope {eraserLocal=thirdLocal}
            if value.identity==body.conversation {chatLocal=local}
        }
        XCTAssertEqual(try count(b,"chat_turns"),0)
        try c.deleteEntity(try XCTUnwrap(eraserLocal));try drain(c,cc)
        for deletion in try cc.journal.outbox() {XCTAssertEqual(deletion.mutation,.delete);try receiveDeletion(deletion,b,bc)}
        XCTAssertTrue(try bc.journal.state(for:scope.key).isDeleted)
        let before=try bc.journal.outbox();var projected:String?,failure:Error?
        do {projected=try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}catch {failure=error}
        XCTAssertNil(failure,"An erased optional entity scope must preserve the independent answer without an unscoped fallback: \(String(describing:failure))")
        XCTAssertEqual(try count(b,"chat_turns"),1);XCTAssertEqual(try bc.journal.cursor(for:producerID),operation.dot.counter)
        XCTAssertFalse(try bc.journal.state(for:record.identity.key).isDeleted)
        guard failure==nil else {return}
        let turn=try XCTUnwrap(b.chatTurns(try XCTUnwrap(chatLocal)).first)
        XCTAssertEqual(turn.id,projected);XCTAssertEqual(turn.question,body.question);XCTAssertEqual(turn.answer.text,body.text)
        XCTAssertEqual(try bc.resolve(record.identity,content:nil,admit:{_ in}).encoded(),try record.encoded())
        XCTAssertEqual(try bc.journal.outbox(),before,"Peer scope projection must not invent an echo or owning deletion")
        try b.insert(Memory(id:"unrelated-scope-control",timestamp:now,kind:.note,app:"Owned",title:"Unrelated source",text:"This must never appear in the old scoped query"))
        do {let hits=try b.search(turn.filter,mode:.keyword);XCTAssertTrue(hits.isEmpty,"An erased scope must never become a broad query")}
        catch {guard case OSwindError.unavailable=error else {return XCTFail("Unexpected scope refusal: \(error)")}}
        XCTAssertTrue(initial.allSatisfy {$0.dot.counter<=operation.dot.counter},"Keep the owned turn as the final initial operation")
        _=try a.createChat(title:"Later independent sender record");try drain(a,ac)
        let later=try XCTUnwrap(ac.journal.outbox().last),packet=try self.packet(later,ac)
        _=try receive(later,packet,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        XCTAssertEqual(try bc.journal.cursor(for:producerID),later.dot.counter)
    }
}
