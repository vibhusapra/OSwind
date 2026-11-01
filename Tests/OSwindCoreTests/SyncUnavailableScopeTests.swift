import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testStoredTurnScopeNeverRetargetsAReusedPeerNativeEntityID()throws {
        let eraser="00000000-0000-0000-0000-000000006192"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("eraser",eraser)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(eraser);try cc.journal.allowPeer(producerID)
        let entity=try a.createEntity(kind:.project,name:"Owned retired scope"),chat=try a.createChat(title:"Known scoped history")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Keep the original scope",answer:.init(text:"Exact original scoped answer",sources:[],provider:"owned",duration:0),filter:SearchFilter(entityID:entity.id));try drain(a,ac)
        let initial=try ac.journal.outbox(),turnOp=try XCTUnwrap(initial.last {$0.key.kind == .turn}),turnPacket=try packet(turnOp,ac)
        guard case .turn(let body)=turnPacket.body else {return XCTFail("No native turn")}
        let oldScope=try XCTUnwrap(body.filter.entity);var oldNative:String?,eraserNative:String?,chatNative:String?
        for operation in initial {
            let value=try packet(operation,ac),local=try receive(operation,value,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))}),third=try receive(operation,value,c,cc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if value.identity==oldScope {oldNative=local;eraserNative=third}
            if value.identity==body.conversation {chatNative=local}
        }
        let retired=try XCTUnwrap(oldNative),conversation=try XCTUnwrap(chatNative),cursor=try XCTUnwrap(initial.last).dot.counter
        try c.deleteEntity(try XCTUnwrap(eraserNative));try drain(c,cc)
        for operation in try cc.journal.outbox() {try receiveDeletion(operation,b,bc)}
        XCTAssertTrue(try bc.journal.state(for:oldScope.key).isDeleted);XCTAssertNil(try b.entity(retired))
        _=try a.createEntity(kind:.project,name:"Owned new independent scope");try drain(a,ac)
        let next=try XCTUnwrap(ac.journal.outbox(after:cursor).first),value=try packet(next,ac)
        guard case .entity=value.body else {return XCTFail("Expected actual new entity definition before its alias")}
        let lease=try b.mediaWriteLease();defer {lease.release()}
        // Owned collision injection through the internal writer hook. Public
        // createEntity chooses a fresh UUID and exposes no caller-supplied ID.
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in},newID:{identity in identity==value.identity ? retired:"peer-"+(try identity.key.digest)})
        var replacement:String?,refusal:Error?
        do {_=try bc.journal.receive(next,contentAvailable:{_ in true}) {_ in replacement=try writer.apply(value,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}}catch {refusal=error}
        if let refusal {
            switch refusal {case OSwindError.invalid,OSwindError.unavailable:break;default:return XCTFail("Unexpected reuse refusal: \(refusal)")}
            XCTAssertEqual(try bc.journal.cursor(for:producerID),cursor)
            replacement=try receive(next,value,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        }
        try b.insert(Memory(id:"replacement-scope-control",timestamp:now,kind:.note,app:"Owned",title:"Replacement only",text:"A new entity must not retarget the old saved scope"))
        try b.linkEntity(try XCTUnwrap(replacement),to:"replacement-scope-control")
        try drain(b,bc)
        let stored=try XCTUnwrap(b.chatTurns(conversation).first);XCTAssertEqual(stored.answer.text,body.text)
        do {let hits=try b.search(stored.filter,mode:.keyword);XCTAssertTrue(hits.isEmpty,"A new entity lifetime must not retarget an old saved scope, even under injected native-key reuse")}
        catch {guard case OSwindError.unavailable=error else {return XCTFail("Unexpected stored-scope refusal: \(error)")}}
        XCTAssertEqual(try bc.resolve(turnPacket.identity,content:nil,admit:{_ in}).encoded(),try turnPacket.encoded())
        XCTAssertFalse(try bc.journal.state(for:value.identity.key).isDeleted)
    }
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
        try drain(b,bc)
        XCTAssertTrue(initial.allSatisfy {$0.dot.counter<=operation.dot.counter},"Keep the owned turn as the final initial operation")
        _=try a.createChat(title:"Later independent sender record");try drain(a,ac)
        let later=try XCTUnwrap(ac.journal.outbox().last),packet=try self.packet(later,ac)
        _=try receive(later,packet,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        XCTAssertEqual(try bc.journal.cursor(for:producerID),later.dot.counter)
    }
}
