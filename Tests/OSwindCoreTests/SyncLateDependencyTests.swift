import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private enum LateOwner:Equatable {case conversation,routine}
    private func lateOwnedLifetime(_ owner:LateOwner)throws {
        let thirdID="00000000-0000-0000-0000-000000006151"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID)
        try cc.journal.allowPeer(producerID);try cc.journal.allowPeer(receiverID)
        let parentID:String
        if owner == .conversation {parentID=try a.createChat(title:"Owned offline parent").id}
        else {var recipe=RoutineDefinition();recipe.id="owned-offline-recipe";recipe.prompt="Owned offline prompt";recipe.schedule.timeZone="UTC";parentID=try a.saveRoutine(recipe,now:now).definition.id}
        try drain(a,ac);let initial=try XCTUnwrap(ac.journal.outbox().first),definition=try packet(initial,ac)
        _=try receive(initial,definition,b,bc,fetch:{_ in definition})
        let offlineParent=try receive(initial,definition,c,cc,fetch:{_ in definition})
        if owner == .conversation {
            _=try c.appendChatTurn(sessionID:offlineParent,question:"Owned offline question",answer:.init(text:"Owned offline answer",sources:[],provider:"owned",duration:0,warnings:[]))
        }else {
            let claim=try XCTUnwrap(c.claimRoutine(id:offlineParent,now:now));_=try c.finishRoutine(claim.run.id,status:.failed,message:"Owned offline run")
        }
        try drain(c,cc)
        let child=try XCTUnwrap(cc.journal.outbox().last),record=try packet(child,cc)
        XCTAssertEqual(child.key.kind,owner == .conversation ? .turn:.routineRun)
        _=try c.createChat(title:"Independent later sender record");try drain(c,cc)
        let later=try XCTUnwrap(cc.journal.outbox().last),laterRecord=try packet(later,cc)
        XCTAssertEqual(later.key.kind,.conversation);XCTAssertEqual(later.dot.counter,child.dot.counter+1)
        if owner == .conversation {try a.deleteChat(parentID)}else{try a.deleteRoutine(parentID)}
        try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last)
        try receiveDeletion(deletion,b,bc)
        XCTAssertTrue(try bc.journal.state(for:deletion.key).isDeleted)
        XCTAssertTrue(try bc.journal.outbox().isEmpty)
        // Conversation metadata can precede the turn in the same sender stream.
        // Deliver every predecessor even though its parent is already deleted.
        for preceding in try cc.journal.outbox() where preceding.dot.counter<child.dot.counter {try receiveDeletion(preceding,b,bc)}
        let beforeCursor=try XCTUnwrap(bc.journal.cursor(for:thirdID))
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("Retired data needs no body policy callback")},pathsFor:{_,_ in XCTFail("No late media");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        var changed=try XCTUnwrap(JSONSerialization.jsonObject(with:SyncProtocolLimits.encode(record)) as? [String:Any])
        var body=try XCTUnwrap(changed["body"] as? [String:Any]),variant=try XCTUnwrap(body[owner == .conversation ? "turn":"routineRun"] as? [String:Any]),payload=try XCTUnwrap(variant["_0"] as? [String:Any])
        payload[owner == .conversation ? "question":"message"]="Not the authenticated head"
        variant["_0"]=payload;body[owner == .conversation ? "turn":"routineRun"]=variant;changed["body"]=body
        let altered=try JSONDecoder().decode(SyncPortableRecord.self,from:JSONSerialization.data(withJSONObject:changed))
        XCTAssertThrowsError(try bc.journal.receive(child,contentAvailable:{_ in true}) {_ in
            _=try writer.apply(altered,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("No altered-head dependency fetch")})
        })
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),beforeCursor);XCTAssertTrue(try bc.journal.outbox().isEmpty)
        XCTAssertFalse(try bc.journal.state(for:child.key).isDeleted)
        try b.withRoutineDatabase {try $0.execute("CREATE TEMP TRIGGER owned_late_reject BEFORE INSERT ON personal_sync_outbox WHEN json_extract(CAST(new.revision AS TEXT),'$.mutation')='delete' BEGIN SELECT RAISE(ABORT,'Owned late retirement rejection'); END")}
        XCTAssertThrowsError(try bc.journal.receive(child,contentAvailable:{_ in true}) {_ in
            _=try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("No rejected dependency fetch")})
        })
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),beforeCursor);XCTAssertTrue(try bc.journal.outbox().isEmpty)
        XCTAssertFalse(try bc.journal.state(for:child.key).isDeleted)
        XCTAssertEqual(try b.withRoutineDatabase {try $0.eraseCount("SELECT sequence FROM personal_sync_local")},0)
        XCTAssertTrue(try bc.journal.state(for:deletion.key).isDeleted)
        try b.withRoutineDatabase {try $0.execute("DROP TRIGGER owned_late_reject")}
        let receipt=try bc.journal.receive(child,contentAvailable:{_ in true}) {_ in
            let local=try writer.apply(record,admission:lease,fetchExactSource:{_ in XCTFail("Never fetch an erased owner");throw OSwindError.invalid("Unexpected erased-owner fetch")})
            XCTAssertEqual(local,"")
        }
        XCTAssertTrue(receipt.inserted);XCTAssertEqual(receipt.applied,1)
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),child.dot.counter)
        XCTAssertTrue(try bc.journal.state(for:child.key).isDeleted)
        XCTAssertEqual(try count(b,owner == .conversation ? "chat_turns":"routine_runs"),0)
        let announcement=try XCTUnwrap(bc.journal.outbox().last)
        XCTAssertEqual(try bc.journal.outbox().count,1);XCTAssertEqual(announcement.key,child.key)
        XCTAssertEqual(announcement.mutation,.delete);XCTAssertNil(announcement.content)
        XCTAssertTrue(announcement.context.contains(child.dot));XCTAssertTrue(announcement.context.contains(deletion.dot))
        let duplicate=try bc.journal.receive(child,contentAvailable:{_ in XCTFail("Committed retired put needs no body");return false}) {_ in XCTFail("Retired receipt must be idempotent")}
        XCTAssertFalse(duplicate.inserted);XCTAssertEqual(duplicate.applied,0)
        _=try receive(later,laterRecord,b,bc,fetch:{_ in laterRecord})
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),later.dot.counter)
        XCTAssertEqual(try b.chats().map(\.title),["Independent later sender record"])
        XCTAssertEqual(try bc.journal.outbox(),[announcement])
        // The offline origin gets both the parent and receiver's derived
        // barrier; an independent later record survives in every ordering.
        try receiveDeletion(deletion,c,cc);try receiveDeletion(announcement,c,cc)
        XCTAssertTrue(try cc.journal.state(for:child.key).isDeleted)
        XCTAssertEqual(try count(c,owner == .conversation ? "chat_turns":"routine_runs"),0)
        XCTAssertEqual(try c.chats().map(\.title),["Independent later sender record"])
    }
    func testLateConversationChildRetiresAndLaterSenderRecordProgresses()throws {try lateOwnedLifetime(.conversation)}
    func testLateRoutineRunRetiresAndLaterSenderRecordProgresses()throws {try lateOwnedLifetime(.routine)}
    func testLateMissingLiveOwnerStaysRetryableAndIsNotAcknowledgedAsErased()throws {
        let thirdID="00000000-0000-0000-0000-000000006151"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        _=try a.createChat(title:"Live owner waiting for typed preparation");try drain(a,ac)
        let parent=try XCTUnwrap(ac.journal.outbox().first),definition=try packet(parent,ac)
        // Journal receipt alone intentionally does not claim typed preparation.
        XCTAssertEqual(try bc.journal.receive(parent,contentAvailable:{_ in true}) {_ in}.applied,1)
        let local=try receive(parent,definition,c,cc,fetch:{_ in definition})
        _=try c.appendChatTurn(sessionID:local,question:"Owned deferred question",answer:.init(text:"Owned deferred answer",sources:[],provider:"owned",duration:0,warnings:[]));try drain(c,cc)
        let child=try XCTUnwrap(cc.journal.outbox().last),record=try packet(child,cc)
        let predecessors=try cc.journal.outbox().filter {$0.dot.counter<child.dot.counter}
        for operation in predecessors {XCTAssertEqual(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in}.applied,1)}
        let beforeCursor=try XCTUnwrap(bc.journal.cursor(for:thirdID)),currentParent=try packet(XCTUnwrap(predecessors.last),cc)
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        XCTAssertThrowsError(try bc.journal.receive(child,contentAvailable:{_ in true}) {_ in
            _=try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("Missing live preparation")})
        })
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),beforeCursor);XCTAssertTrue(try bc.journal.outbox().isEmpty)
        XCTAssertFalse(try bc.journal.state(for:child.key).isDeleted)
        _=try writer.apply(currentParent,admission:lease,fetchExactSource:{_ in currentParent})
        XCTAssertEqual(try bc.journal.receive(child,contentAvailable:{_ in true}) {_ in
            _=try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("No source dependencies")})
        }.applied,1)
        XCTAssertEqual(try count(b,"chat_turns"),1);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }
}
