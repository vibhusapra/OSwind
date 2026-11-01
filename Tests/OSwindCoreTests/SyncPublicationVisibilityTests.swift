import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    /// Complete service delivery gate. The lower-level typed adapter currently
    /// learns a turn's evidence only from later, separately published citations.
    /// A future publication admission layer must not expose that interim body.
    func testIncompleteCitedTurnNeverBecomesReadableBeforeEvidenceDeclaration()throws {
        let eraser="00000000-0000-0000-0000-000000006196"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("eraser",eraser)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(eraser);try cc.journal.allowPeer(producerID)
        let source=Memory(id:"owned-publication-evidence",timestamp:now,kind:.note,app:"Owned publication",text:"Authored original evidence for the visibility gate")
        try a.insert(source);try drain(a,ac)
        let initial=try XCTUnwrap(ac.journal.outbox().first),original=try packet(initial,ac)
        _=try receive(initial,original,b,bc,fetch:{_ in original})
        let eraserSource=try receive(initial,original,c,cc,fetch:{_ in original})
        let chat=try a.createChat(title:"Owned cited publication"),canary="OwnedPublicationVisibilityCanary8k31"
        _=try a.appendChatTurn(sessionID:chat.id,question:"Owned cited question",answer:.init(text:"This authored answer must await complete evidence admission [1]. "+canary,sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0));try drain(a,ac)
        let operations=try ac.journal.outbox(after:initial.dot.counter),turn=try XCTUnwrap(operations.first {$0.key.kind == .turn}),citation=try XCTUnwrap(operations.first {$0.key.kind == .conversationCitation})
        XCTAssertLessThan(turn.dot.counter,citation.dot.counter,"Exercise the actual separate publication order")
        try c.delete(eraserSource);try drain(c,cc)
        for deletion in try cc.journal.outbox() {XCTAssertEqual(deletion.mutation,.delete);try receiveDeletion(deletion,b,bc)}
        XCTAssertTrue(try bc.journal.state(for:original.identity.key).isDeleted)
        var localChat:String?
        for operation in operations where operation.dot.counter<turn.dot.counter {
            let value=try packet(operation,ac),local=try receive(operation,value,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if value.identity.table == .conversation {localChat=local}
        }
        _=try receive(turn,packet(turn,ac),b,bc,fetch:{_ in XCTFail("A withheld citation cannot authorize fetching erased source evidence");throw OSwindError.invalid("No evidence declaration")})
        // This is the missing intermediate visibility gate, not merely an
        // after-all-children deletion assertion. Owned canary text only.
        XCTAssertEqual(try count(b,"chat_turns"),0,"An incomplete evidence publication must remain unreadable")
        let readable=try b.chatTurns(try XCTUnwrap(localChat));XCTAssertFalse(readable.contains {$0.answer.text.contains(canary)},"Retiring the body later does not close an earlier disclosure window")
        _=try receive(citation,packet(citation,ac),b,bc,fetch:{_ in XCTFail("Known-erased evidence must not be fetched");throw OSwindError.invalid("No erased source fetch")})
        XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertTrue(try bc.journal.state(for:turn.key).isDeleted)
        XCTAssertEqual(try bc.journal.cursor(for:producerID),citation.dot.counter)
    }
}
