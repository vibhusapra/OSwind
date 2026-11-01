import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testPublicationQueueOldCitationTombstoneCannotWithdrawAlreadyCompleteIndependentVersion()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let (next,proof,revision)=try queueReplacement(f,text:"Already complete independent answer")
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(revision,record:next,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})
            _=try queueRetry(f.ac,service)
            XCTAssertTrue(try f.queue.isComplete(next.identity));XCTAssertEqual(try count(f.b,"chat_sources"),0)
            let citation=try XCTUnwrap(f.operations.first{$0.key.kind == .conversationCitation}),deletion=try f.ac.journal.delete(key:citation.key)
            _=try queueReceive(deletion,f.ac,service)
            XCTAssertEqual(try count(f.b,"chat_turns"),1,"A catalogue key surviving retraction is not proof of current native citation membership")
            XCTAssertTrue(try f.queue.isComplete(next.identity));XCTAssertTrue(try f.queue.jobs(readyOnly:false).isEmpty)
            XCTAssertFalse(try f.bc.journal.state(for:next.identity.key).isDeleted);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueActualSourceUpdatePreservesCertifiedOriginalAndLaterCitationErasureWithdrawsIt()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let owner=try packet(XCTUnwrap(f.operations.first{$0.key.kind == .turn}),f.ac),citation=try XCTUnwrap(f.operations.first{$0.key.kind == .conversationCitation})
            // A real third native replica edits the source without possessing
            // this answer. Its stream contains no direct answer deletion.
            let third="00000000-0000-0000-0000-000000006215",(c,cc)=try endpoint("source-editor",third);defer {try? c.close()}
            try cc.journal.allowPeer(producerID);try f.bc.journal.allowPeer(third)
            let initial=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),original=try packet(initial,f.ac),local=try receive(initial,original,c,cc,fetch:{_ in original})
            var source=try XCTUnwrap(c.get(local));source.text="Actual newer native source revision"
            try c.insert(source);let edited=try publicationSpace("source-editor-space");defer {edited.close()};try publicationDrain(c,cc,edited)
            let updates=try cc.journal.outbox();XCTAssertTrue(updates.contains{$0.key.kind == .source});XCTAssertFalse(updates.contains{$0.key.kind == .turn && $0.mutation == .delete})
            for operation in updates {_=try queueReceive(operation,cc,service)}
            let chat=try XCTUnwrap(f.b.chats().first),turn=try XCTUnwrap(f.b.chatTurns(chat.id).first)
            XCTAssertEqual(turn.answer.sources.first?.memory.text,"Owned queue original 0","The answer must retain its exact original, not silently cite the newer source text")
            XCTAssertTrue(try f.queue.isComplete(owner.identity),"Legitimate original promotion must leave a complete current declaration certified or durably scheduled")
            let deletion=try f.ac.journal.delete(key:citation.key);_=try queueReceive(deletion,f.ac,service)
            XCTAssertEqual(try count(f.b,"chat_turns"),0,"Erasing an actually required promoted citation must withdraw its answer even after native evidence rebinding")
            XCTAssertFalse(try f.bc.journal.state(for:owner.identity.key).isDeleted);XCTAssertTrue(try f.bc.journal.state(for:citation.key).isDeleted);try f.queue.checkAccounting()
        }
    }
}
