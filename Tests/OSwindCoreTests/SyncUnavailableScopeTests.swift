import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testNativeScopeRetirementThenPeerConversationDeletionKeepsCurrentRunHeadAndOriginal()throws {try scopeAndConversationRetirement(local:true)}
    func testPeerKnowsScopedTurnAndRetiresScopeThenConversationWithoutEcho()throws {try scopeAndConversationRetirement(local:false)}
    private func scopeAndConversationRetirement(local:Bool)throws {
        let eraser="00000000-0000-0000-0000-000000006193"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("eraser",eraser)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(eraser);try cc.journal.allowPeer(producerID)
        let entity=try a.createEntity(kind:.project,name:"Owned run scope")
        var recipe=RoutineDefinition();recipe.id="owned-mixed-scope";recipe.prompt="Original 👩🏽‍💻 e\u{301} prompt";_=try a.saveRoutine(recipe,now:now)
        let claim=try XCTUnwrap(a.claimRoutine(id:recipe.id,now:now));_=try a.completeRoutine(claim,answer:.init(text:"Original independent answer",sources:[],provider:"owned",duration:0),policy:.init())
        // Owned stored-run fixture: the public routine recipe has no entity
        // selector. Export and receive use the real native/wire pipeline.
        let chat=try XCTUnwrap(a.routineRuns().first?.chatID)
        try a.withRoutineDatabase {db in try db.transaction {
            let run=try db.statement("UPDATE routine_runs SET scope=? WHERE id=?");defer {sqlite3_finalize(run)};try db.bind(run,1,json:SearchFilter(entityID:entity.id));db.bind(run,2,claim.run.id);try db.done(run)
            let row=try db.statement("SELECT id,payload FROM chat_turns WHERE session_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,chat);XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);let id=db.text(row,0);var value=try db.decode(row,1,as:ChatPayload.self);value.filter.entityID=entity.id
            let turn=try db.statement("UPDATE chat_turns SET payload=? WHERE id=?");defer {sqlite3_finalize(turn)};try db.bind(turn,1,json:value);db.bind(turn,2,id);try db.done(turn)
        }};try drain(a,ac)
        let initial=try ac.journal.outbox(),runOp=try XCTUnwrap(initial.last {$0.key.kind == .routineRun}),original=try packet(runOp,ac)
        guard case .routineRun(let body)=original.body else {return XCTFail("Expected native run")}
        let scope=try XCTUnwrap(body.filter.entity),conversation=try XCTUnwrap(body.conversation);var bEntity:String?,cEntity:String?,cChat:String?,bRun:String?
        for operation in initial {
            let value=try packet(operation,ac),id=try receive(operation,value,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if value.identity==scope {bEntity=id};if value.identity==original.identity {bRun=id}
            if !local || operation.dot.counter<runOp.dot.counter {
                let third=try receive(operation,value,c,cc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
                if value.identity==scope {cEntity=third};if value.identity==conversation {cChat=third}
            }
        }
        var eraserCursor:Int64=0
        if local {try b.deleteEntity(try XCTUnwrap(bEntity));try drain(b,bc)}
        else {
            try c.deleteEntity(try XCTUnwrap(cEntity));try drain(c,cc)
            let operations=try cc.journal.outbox();XCTAssertTrue(operations.contains {$0.mutation == .put && $0.key.kind == .turn},"An eraser that knows the turn emits its explicit unavailable update")
            for operation in operations {
                if operation.mutation == .delete {try receiveDeletion(operation,b,bc)}
                else {_=try receive(operation,packet(operation,cc),b,bc,fetch:{ref in try XCTUnwrap(cc.record(ref,admit:{_ in}) ?? ac.record(ref,admit:{_ in}))})}
                eraserCursor=operation.dot.counter
            }
        }
        let run=try XCTUnwrap(bRun),before=try bc.resolve(original.identity,content:nil,admit:{_ in}),outbox=try bc.journal.outbox()
        if local {XCTAssertNotEqual(try before.encoded(),try original.encoded());guard case .routineRun(let current)=before.body else {return XCTFail("No current run")};XCTAssertNotNil(current.filter.unavailableEntityScope)}
        else {guard case .routineRun(let current)=before.body else {return XCTFail("No peer updated run")};XCTAssertNotNil(current.filter.unavailableEntityScope);XCTAssertTrue(outbox.isEmpty)}
        XCTAssertNotNil(try b.routineRuns().first?.filter.unavailableEntityScope)
        try c.deleteChat(try XCTUnwrap(cChat));try drain(c,cc)
        for operation in try cc.journal.outbox(after:eraserCursor) {
            if operation.mutation == .delete {try receiveDeletion(operation,b,bc)}
            else {_=try receive(operation,packet(operation,cc),b,bc,fetch:{ref in try XCTUnwrap(cc.record(ref,admit:{_ in}) ?? ac.record(ref,admit:{_ in}))})}
        }
        let stored=try XCTUnwrap(b.routineRuns().first);XCTAssertNil(stored.chatID);XCTAssertNotNil(stored.filter.unavailableEntityScope);XCTAssertEqual(stored.original?.recipePrompt,recipe.prompt)
        let retained=try b.withRoutineDatabase {try XCTUnwrap(RoutineRunOriginalStore(db:$0).read(run))}
        if local {
            XCTAssertEqual(try retained.record.encoded(),try original.encoded());XCTAssertEqual(try bc.resolve(original.identity,content:nil,admit:{_ in}).encoded(),try before.encoded())
            // This eraser never saw the turn after the withheld run. The
            // receiver must publish the actual known child retirement once.
            let extra=Array(try bc.journal.outbox().dropFirst(outbox.count));XCTAssertEqual(extra.count,1);XCTAssertTrue(extra.allSatisfy {$0.key.kind == .turn && $0.mutation == .delete})
        }else {
            XCTAssertEqual(try bc.resolve(original.identity,content:nil,admit:{_ in}).encoded(),try retained.record.encoded());XCTAssertEqual(try bc.journal.outbox(),outbox)
        }
    }
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
            let value=try packet(operation,ac),local=try receive(operation,value,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if value.identity==oldScope {oldNative=local}
            if operation.dot.counter<turnOp.dot.counter {
                let third=try receive(operation,value,c,cc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
                if value.identity==oldScope {eraserNative=third}
            }
            if value.identity==body.conversation {chatNative=local}
        }
        let retired=try XCTUnwrap(oldNative),conversation=try XCTUnwrap(chatNative),cursor=try XCTUnwrap(initial.last).dot.counter
        try c.deleteEntity(try XCTUnwrap(eraserNative));try drain(c,cc)
        for operation in try cc.journal.outbox() {try receiveDeletion(operation,b,bc)}
        XCTAssertTrue(try bc.journal.state(for:oldScope.key).isDeleted);XCTAssertNil(try b.entity(retired))
        let marker=try XCTUnwrap(b.chatTurns(conversation).first?.filter.unavailableEntityScope)
        if case .entity(let reconstructed)=try bc.projectionFilterScope(marker,record:turnPacket) {XCTAssertEqual(reconstructed,oldScope)}else{XCTFail("Exact old packet requires its original active reference")}
        for field in 0..<4 {
            var wrong=marker;let current=try XCTUnwrap(marker.projection),other=UUID().uuidString.lowercased()
            wrong.projection = .init(origin:field==0 ? other:current.origin,generation:field==1 ? other:current.generation,group:field==2 ? other:current.group,epoch:field==3 ? other:current.epoch)
            XCTAssertThrowsError(try bc.projectionFilterScope(wrong,record:turnPacket),"Old scope authority must match every current namespace component")
        }
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
    func testMissingLiveEntityScopeDoesNotAcquireAnErasureBarrierOrAcknowledgeTurn()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let entity=try a.createEntity(kind:.project,name:"Owned missing live scope"),chat=try a.createChat(title:"Owned")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Owned",answer:.init(text:"Exact answer",sources:[],provider:"owned",duration:0),filter:.init(entityID:entity.id));try drain(a,ac)
        let initial=try ac.journal.outbox(),operation=try XCTUnwrap(initial.last {$0.key.kind == .turn}),record=try packet(operation,ac)
        guard case .turn(let body)=record.body else {return XCTFail("No native turn")};let scope=try XCTUnwrap(body.filter.entity)
        for previous in initial where previous.dot.counter<operation.dot.counter {_=try receive(previous,packet(previous,ac),b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}
        let primary=try XCTUnwrap(bc.catalog.object(scope)?.primary)
        // Owned corruption injection removes the native projection under echo
        // suppression; it does not invent a received deletion or local intent.
        try b.withRoutineDatabase {db in try SyncChangeCapture.withoutEcho(db,scope:bc.catalog.scope) {
            let row=try db.statement("DELETE FROM memory_entities WHERE id=?");defer {sqlite3_finalize(row)};guard case .text(let bytes)=primary[0],let local=String(data:bytes,encoding:.utf8) else {throw OSwindError.invalid("Owned key differs")};db.bind(row,1,local);try db.done(row)
        }}
        let cursor=try bc.journal.cursor(for:producerID),outbox=try bc.journal.outbox()
        XCTAssertNil(try bc.projectErasedFilterScope(scope));XCTAssertThrowsError(try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))}))
        XCTAssertEqual(try bc.journal.cursor(for:producerID),cursor);XCTAssertEqual(try bc.journal.outbox(),outbox);XCTAssertFalse(try bc.journal.state(for:scope.key).isDeleted);XCTAssertFalse(try bc.journal.state(for:record.identity.key).isDeleted);XCTAssertEqual(try count(b,"chat_turns"),0)
    }
}
