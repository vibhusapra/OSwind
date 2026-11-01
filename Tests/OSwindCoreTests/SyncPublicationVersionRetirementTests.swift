import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testPublicationQueueIndependentFutureHeadSurvivesPriorCitationRetirement()throws {
        try queueIndependentHeadAfterRetirement(concurrent:false)
    }
    func testPublicationQueueIndependentConcurrentHeadSurvivesThirdPeerCitationRetirement()throws {
        try queueIndependentHeadAfterRetirement(concurrent:true)
    }
    func testPublicationQueueIndependentFutureHeadSurvivesPriorWholeSourceRetirement()throws {
        try queueIndependentHeadAfterRetirement(concurrent:false,wholeSource:true)
    }
    func testPublicationQueueIndependentConcurrentHeadSurvivesThirdPeerWholeSourceRetirement()throws {
        try queueIndependentHeadAfterRetirement(concurrent:true,wholeSource:true)
    }
    private func queueIndependentHeadAfterRetirement(concurrent:Bool,wholeSource:Bool=false)throws {
        try withQueueFixture(citations:1) {f in
            var erasing=false
            let service=queueService(f.b,f.bc,f.queue,f.inbox,admit:{_ in if erasing {XCTFail("Authenticated evidence erasure must not invoke body policy")}})
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let dependency=try XCTUnwrap(f.operations.first{$0.key.kind == (wholeSource ? .source:.conversationCitation)})
            let next:SyncPortableRecord,proof:SyncTurnPublication,update:SyncRevision,deletion:SyncRevision
            if concurrent {
                let third="00000000-0000-0000-0000-000000006214",(c,cc)=try endpoint("concurrent-eraser",third);defer {try? c.close()}
                try cc.journal.allowPeer(producerID);try f.bc.journal.allowPeer(third)
                // The third replica has authenticated the initial journal, but
                // has never seen the separately authored independent update.
                for operation in f.operations {_=try cc.journal.receive(operation,contentAvailable:{_ in true})}
                (next,proof,update)=try queueReplacement(f,text:"Independent concurrent answer")
                deletion=try cc.journal.delete(key:dependency.key)
                XCTAssertEqual(try update.clock.relation(to:deletion.clock),.concurrent)
                erasing=true;_=try queueReceive(deletion,cc,service);erasing=false
            }else {
                deletion=try f.ac.journal.delete(key:dependency.key);erasing=true;_=try queueReceive(deletion,f.ac,service);erasing=false
                (next,proof,update)=try queueReplacement(f,text:"Independent future answer")
                XCTAssertTrue(update.context.contains(deletion.dot))
            }
            XCTAssertFalse(try f.ac.journal.state(for:next.identity.key).isDeleted,"The producing journal legitimately permits this same-owner version")
            XCTAssertEqual(try count(f.b,"chat_turns"),0,"The old source-derived body must be removed immediately")
            if wholeSource {
                XCTAssertEqual(try count(f.b,"memories"),0,"Exercise actual whole-source native erasure")
                XCTAssertEqual(try f.b.chats().first?.title,"Conversation")
                let original=try packet(XCTUnwrap(f.operations.first{$0.key.kind == .conversation}),f.ac),redaction=try XCTUnwrap(f.bc.journal.outbox().first)
                XCTAssertEqual(redaction.key,try original.identity.key);XCTAssertEqual(redaction.mutation,.put);XCTAssertTrue(redaction.context.contains(deletion.dot))
                let remaining=try f.bc.journal.outbox().filter{$0.key != redaction.key},pins=Set(f.operations.filter{$0.key.kind == .evidencePin}.map(\.key))
                XCTAssertEqual(Set(remaining.map(\.key)),pins,"Actual source-owned pins still retire; no dependent answer or citation lifetime is erased")
                for pin in remaining {XCTAssertEqual(pin.mutation,.delete);XCTAssertTrue(pin.context.contains(deletion.dot));XCTAssertTrue(try f.bc.journal.state(for:pin.key).isDeleted)}
                XCTAssertNil(try f.bc.record(original.reference,admit:{_ in}),"The prior canonical title must be purged from the native version cache")
                let bytes=try XCTUnwrap(f.inbox.content(XCTUnwrap(redaction.content))),metadata=try SyncPortableRecord.decode(bytes)
                guard case .conversation(let title)=metadata.body else {return XCTFail("Redaction is not canonical conversation metadata")}
                XCTAssertEqual(title.title,"Conversation");XCTAssertEqual(try f.bc.resolve(original.identity,content:nil,admit:{_ in}),metadata)
            }
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(update,record:next,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Independent version must not fetch retired evidence")})
            _=try queueRetry(f.ac,service)
            XCTAssertFalse(try f.bc.journal.state(for:next.identity.key).isDeleted,"A dependency tombstone must not become an irreversible whole-owner deletion for an independent version")
            XCTAssertEqual(try count(f.b,"chat_turns"),1)
            XCTAssertTrue(try f.queue.isComplete(next.identity));try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueEarlyWholeSourceErasureAcrossUnseenIndependentHeadDefersUntilGapCloses()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let (next,proof,update)=try queueReplacement(f,text:"Independent answer across genuine source-deletion gap")
            let source=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),deletion=try f.ac.journal.delete(key:source.key)
            XCTAssertTrue(deletion.context.contains(update.dot));let early=try queueReceive(deletion,f.ac,service);XCTAssertEqual(early.receipt.applied,0)
            XCTAssertEqual(try count(f.b,"memories"),0);XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertFalse(try f.bc.journal.state(for:next.identity.key).isDeleted)
            XCTAssertEqual(try queueRetry(f.ac,service),[.withheld(.causalGap)])
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(update,record:next,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Independent answer cannot fetch erased source")})
            guard case .projected=try queueRetry(f.ac,service).first else {return XCTFail("Source gap closure must wake independent current-version publication")}
            XCTAssertTrue(try f.queue.isComplete(next.identity));XCTAssertEqual(try f.b.chats().first?.title,"Conversation");try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueChangedDeclaredCitationWithdrawsStaleCompleteOwnerUntilNewDeclaration()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let initial=try packet(XCTUnwrap(f.operations.first{$0.key.kind == .conversationCitation}),f.ac)
            guard case .conversationCitation(let body)=initial.body else {return XCTFail("Owned citation missing")}
            let changed=try SyncPortableRecord(identity:initial.identity,body:.conversationCitation(.init(owner:body.owner,ordinal:body.ordinal,link:.init(source:body.link.source,score:body.link.score,match:"A different authenticated citation version",passage:body.link.passage))))
            let change=try f.ac.journal.put(key:changed.identity.key,content:changed.reference.content)
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(change,record:changed,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})
            XCTAssertEqual(try count(f.b,"chat_turns"),0,"A genuinely declared child's changed journal head invalidates current publication")
            XCTAssertFalse(try f.queue.isComplete(body.owner));XCTAssertFalse(try f.bc.journal.state(for:body.owner.key).isDeleted)
            let (next,proof,update)=try queueReplacement(f,text:"Answer with new exact evidence declaration",citations:[changed])
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            _=try service.receive(update,record:next,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})
            _=try queueRetry(f.ac,service)
            XCTAssertTrue(try f.queue.isComplete(next.identity));XCTAssertEqual(try count(f.b,"chat_sources"),1);try f.queue.checkAccounting()
        }
    }
}
