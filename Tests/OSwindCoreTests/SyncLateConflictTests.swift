import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private func lateConflictedTurn(retireParent:Bool)throws {
        let thirdID="00000000-0000-0000-0000-000000006161"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("offline",thirdID)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(thirdID);try cc.journal.allowPeer(producerID)
        let chat=try a.createChat(title:"Owned conflict parent");try drain(a,ac)
        try derivedDeliver(ac,b,bc);try derivedDeliver(ac,c,cc)
        let local=try XCTUnwrap(c.chats().first)
        _=try c.appendChatTurn(sessionID:local.id,question:"Offline conflict question",answer:.init(text:"Offline conflict answer",sources:[],provider:"owned",duration:0,warnings:[]));try drain(c,cc)
        let incoming=try XCTUnwrap(cc.journal.outbox().last),record=try packet(incoming,cc)
        guard case .turn(let body)=record.body else {return XCTFail("Expected typed turn")}
        let alternate=try SyncPortableRecord(identity:record.identity,body:.turn(.init(conversation:body.conversation,timestamp:body.timestamp,question:"Another admitted branch",text:body.text,provider:body.provider,duration:body.duration,warnings:body.warnings,filter:body.filter,timeZone:body.timeZone)))
        // A genuine local revision of the same lifetime is concurrent with the
        // incoming sender. Both head references have valid distinct packets.
        let existing=try bc.journal.put(key:incoming.key,content:alternate.reference.content)
        var parentDeletion:SyncRevision?
        if retireParent {try a.deleteChat(chat.id);try drain(a,ac);parentDeletion=try XCTUnwrap(ac.journal.outbox().last);try receiveDeletion(XCTUnwrap(parentDeletion),b,bc)}
        for operation in try cc.journal.outbox() where operation.dot.counter<incoming.dot.counter {
            if retireParent {try receiveDeletion(operation,b,bc)}
            else {_=try receive(operation,packet(operation,cc),b,bc,fetch:{reference in try XCTUnwrap(cc.record(reference,admit:{_ in}))})}
        }
        let cursor=try XCTUnwrap(bc.journal.cursor(for:thirdID)),before=try bc.journal.outbox()
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("Conflicted positive or retired data must not reach policy admission")},pathsFor:{_,_ in XCTFail("No media");return [:]},admitMedia:{_,_,_ in XCTFail("No media admission")})
        var sawBothHeads=false
        func accept()throws->SyncReceiveResult {
            try bc.journal.receive(incoming,contentAvailable:{_ in true}) {_ in
                let state=try bc.journal.state(for:incoming.key)
                XCTAssertEqual(Set(state.heads.map(\.dot)),[existing.dot,incoming.dot]);sawBothHeads=state.isConflicted
                let result=try writer.apply(record,admission:lease,fetchExactSource:{_ in XCTFail("No conflicting dependency fetch");throw OSwindError.invalid("No fetch")})
                if retireParent {XCTAssertEqual(result,"")}
            }
        }
        if retireParent {
            XCTAssertEqual(try accept().applied,1);XCTAssertTrue(sawBothHeads)
            XCTAssertTrue(try bc.journal.state(for:incoming.key).isDeleted)
            let deletion=try XCTUnwrap(bc.journal.outbox().last)
            XCTAssertEqual(deletion.key,incoming.key);XCTAssertEqual(deletion.mutation,.delete)
            XCTAssertTrue(deletion.context.contains(existing.dot));XCTAssertTrue(deletion.context.contains(incoming.dot));XCTAssertTrue(try deletion.context.contains(XCTUnwrap(parentDeletion).dot))
            XCTAssertEqual(try bc.journal.outbox().count,before.count+1)
            XCTAssertEqual(try bc.journal.receive(incoming,contentAvailable:{_ in XCTFail("No duplicate body");return false}) {_ in XCTFail("No duplicate apply")}.applied,0)
            _=try c.createChat(title:"Independent after conflicted retirement");try drain(c,cc)
            let later=try XCTUnwrap(cc.journal.outbox().last)
            _=try receive(later,packet(later,cc),b,bc,fetch:{_ in throw OSwindError.invalid("No source dependency")})
            XCTAssertEqual(try bc.journal.cursor(for:thirdID),later.dot.counter)
            XCTAssertEqual(try b.chats().map(\.title),["Independent after conflicted retirement"])
        }else {
            XCTAssertThrowsError(try accept());XCTAssertTrue(sawBothHeads)
            XCTAssertEqual(try bc.journal.cursor(for:thirdID),cursor);XCTAssertEqual(try bc.journal.outbox(),before)
            let state=try bc.journal.state(for:incoming.key);XCTAssertFalse(state.isDeleted);XCTAssertEqual(state.heads.map(\.dot),[existing.dot])
        }
        XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertEqual(try count(b,"personal_sync_pending"),0)
    }
    func testLateConflictedChildRetirementObservesEveryAdmittedHeadAndLaterRecordProgresses()throws {try lateConflictedTurn(retireParent:true)}
    func testLateConflictedLiveChildStillRequiresExplicitReview()throws {try lateConflictedTurn(retireParent:false)}
}
