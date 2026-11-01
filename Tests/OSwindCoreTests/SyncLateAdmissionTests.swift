import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testLateRetirementRejectsForeignReleasedAndWrongConnectionReservationsAndCancellation()async throws {
        let thirdID="00000000-0000-0000-0000-000000006181"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        let chat=try a.createChat(title:"Owned guarded parent");try drain(a,ac);try derivedDeliver(ac,b,bc);try derivedDeliver(ac,c,cc)
        let local=try XCTUnwrap(c.chats().first)
        _=try c.appendChatTurn(sessionID:local.id,question:"Owned guarded late question",answer:.init(text:"Owned guarded late answer",sources:[],provider:"owned",duration:0,warnings:[]));try drain(c,cc)
        let operation=try XCTUnwrap(cc.journal.outbox().last),record=try packet(operation,cc)
        try a.deleteChat(chat.id);try drain(a,ac);let deletion=try XCTUnwrap(ac.journal.outbox().last);try receiveDeletion(deletion,b,bc)
        for preceding in try cc.journal.outbox() where preceding.dot.counter<operation.dot.counter {try receiveDeletion(preceding,b,bc)}
        let cursor=try XCTUnwrap(bc.journal.cursor(for:thirdID)),before=try bc.journal.outbox()
        func clock()throws->String {try b.withRoutineDatabase {db in
            let row=try db.statement("SELECT hex(clock) FROM personal_sync_observed WHERE singleton=1");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return db.text(row,0)
        }}
        let observed=try clock()
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("No retired body policy")},pathsFor:{_,_ in XCTFail("No media");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        func apply(_ lease:MediaAdmissionLease,_ adapter:SyncIncomingConversationWriter)throws->SyncReceiveResult {
            try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in
                _=try adapter.apply(record,admission:lease,fetchExactSource:{_ in XCTFail("No erased-parent fetch");throw OSwindError.invalid("No fetch")})
            }
        }
        func unchanged()throws {
            XCTAssertEqual(try bc.journal.cursor(for:thirdID),cursor);XCTAssertEqual(try bc.journal.outbox(),before)
            XCTAssertFalse(try bc.journal.state(for:operation.key).isDeleted);XCTAssertTrue(try bc.journal.state(for:deletion.key).isDeleted)
            XCTAssertEqual(try clock(),observed);XCTAssertEqual(try count(b,"chat_turns"),0)
            XCTAssertEqual(try count(b,"personal_sync_pending"),0);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
        }
        let foreign=try c.mediaWriteLease();defer {foreign.release()}
        XCTAssertThrowsError(try apply(foreign,writer));try unchanged()
        let released=try b.mediaWriteLease();released.release()
        XCTAssertThrowsError(try apply(released,writer));try unchanged()
        let wrong=SyncIncomingConversationWriter(library:c,cache:bc,admit:{_ in XCTFail("No wrong-connection admission")},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        XCTAssertThrowsError(try apply(foreign,wrong));try unchanged()
        let active=try b.mediaWriteLease();defer {active.release()}
        let cancelled=Task { ()->Bool in
            withUnsafeCurrentTask {$0?.cancel()}
            do {_=try apply(active,writer);return false}
            catch {return error is CancellationError}
        }
        let cancellationRefused=await cancelled.value;XCTAssertTrue(cancellationRefused);try unchanged()
        XCTAssertEqual(try apply(active,writer).applied,1)
        XCTAssertTrue(try bc.journal.state(for:operation.key).isDeleted)
        XCTAssertEqual(try bc.journal.cursor(for:thirdID),operation.dot.counter)
        XCTAssertEqual(try bc.journal.outbox().count,before.count+1)
    }
}
