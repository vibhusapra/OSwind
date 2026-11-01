import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testUnseenRunSurvivesErasedOptionalConversationAndKeepsExactOriginal()throws {
        let thirdID="00000000-0000-0000-0000-000000006171"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("eraser",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="owned-optional-conversation";recipe.title="Independent recipe";recipe.prompt="Preserve this exact original prompt";recipe.schedule.timeZone="UTC"
        _=try a.saveRoutine(recipe,now:now)
        let claim=try XCTUnwrap(a.claimRoutine(id:recipe.id,now:now))
        let finished=try XCTUnwrap(a.completeRoutine(claim,answer:.init(text:"Owned completed result",sources:[],provider:"owned",duration:0),policy:.init()))
        XCTAssertEqual(finished.status,.completed);XCTAssertNotNil(finished.chatID)
        try drain(a,ac)
        let initial=try ac.journal.outbox(),operation=try XCTUnwrap(initial.last {$0.key.kind == .routineRun}),record=try packet(operation,ac)
        guard case .routineRun(let body)=record.body else {return XCTFail("Expected actual completed run")}
        let optional=try XCTUnwrap(body.conversation);var erasedLocal:String?
        for preceding in initial where preceding.dot.counter<operation.dot.counter {
            let packet=try self.packet(preceding,ac)
            _=try receive(preceding,packet,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            let local=try receive(preceding,packet,c,cc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if packet.identity==optional {erasedLocal=local}
        }
        XCTAssertEqual(try count(b,"routine_runs"),0,"Withhold the actual run, not its optional conversation")
        try c.deleteChat(try XCTUnwrap(erasedLocal));try drain(c,cc)
        for deletion in try cc.journal.outbox() {XCTAssertEqual(deletion.mutation,.delete);try receiveDeletion(deletion,b,bc)}
        XCTAssertTrue(try bc.journal.state(for:optional.key).isDeleted)
        let before=try bc.journal.outbox();var projected:String?,failure:Error?
        do {projected=try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}catch {failure=error}
        XCTAssertNil(failure,"An erased optional conversation must not block an independent completed run: \(String(describing:failure))")
        XCTAssertEqual(try count(b,"routine_runs"),1)
        XCTAssertEqual(try bc.journal.cursor(for:producerID),operation.dot.counter)
        XCTAssertFalse(try bc.journal.state(for:record.identity.key).isDeleted,"A nullable conversation is not the run's owner")
        guard failure==nil else {return}
        let run=try XCTUnwrap(b.routineRuns().first)
        XCTAssertEqual(run.id,projected);XCTAssertEqual(run.status,.completed);XCTAssertNil(run.chatID);XCTAssertFalse(run.resultAvailable)
        XCTAssertEqual(run.original?.recipePrompt,recipe.prompt)
        XCTAssertEqual(try bc.resolve(record.identity,content:nil,admit:{_ in}).encoded(),try record.encoded())
        XCTAssertEqual(try b.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).read(run.id)?.record.encoded()},try record.encoded())
        XCTAssertEqual(try bc.journal.outbox(),before,"Preserving an independent run must not invent a deletion or echo")
        // Remaining predecessors can be stale puts for the erased conversation.
        // The caller must use their admitted outcome, not blindly project them.
        for following in initial where following.dot.counter>operation.dot.counter {
            let packet=try self.packet(following,ac),lease=try b.mediaWriteLease();defer {lease.release()}
            let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
            _=try bc.journal.receive(following,contentAvailable:{_ in true}) {change in
                if change.after.isDeleted {try writer.applyDeletion(change,admission:lease)}
                else {_=try writer.applyOutcome(packet,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}
            }
        }
        _=try a.createChat(title:"Independent later sender record");try drain(a,ac)
        let later=try XCTUnwrap(ac.journal.outbox().last),laterRecord=try packet(later,ac)
        _=try receive(later,laterRecord,b,bc,fetch:{_ in laterRecord})
        XCTAssertEqual(try bc.journal.cursor(for:producerID),later.dot.counter)
        XCTAssertEqual(try b.chats().map(\.title),["Independent later sender record"])
        XCTAssertTrue(try bc.journal.state(for:optional.key).isDeleted)
    }
}
