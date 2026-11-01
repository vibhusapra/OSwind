import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private struct PublicationQueueFixture {
        let a:MemoryStore,ac:SyncVersionStore,b:MemoryStore,bc:SyncVersionStore
        let producer:SyncObjectFolder,inbox:SyncObjectFolder,secret:SyncGroupSecret
        let operations:[SyncRevision],queue:SyncPublicationQueue
    }
    private func withQueueFixture(citations:Int=0,answers:Int=1,_ body:(PublicationQueueFixture)throws->Void)throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),producer=try publicationSpace("queue-producer"),secret=SyncGroupSecret()
        let inbox=try SyncObjectFolder.create(at:root.appendingPathComponent("queue-inbox"),secret:secret,group:group,epoch:epoch)
        defer {try? a.close();try? b.close();producer.close();inbox.close()};try bc.journal.allowPeer(producerID)
        var sources=[Memory]()
        for index in 0..<citations {let source=Memory(id:"queue-source-\(index)",timestamp:now,kind:.note,app:"Owned queue",text:"Owned queue original \(index)");try a.insert(source);sources.append(source)}
        let chat=try a.createChat(title:"Owned queue conversation")
        for index in 0..<answers {_=try a.appendChatTurn(sessionID:chat.id,question:"Queue question \(index)?",answer:.init(text:"Owned queue answer \(index) 👩🏽‍💻 e\u{301}",sources:sources.map{.init(memory:$0,score:1,match:"owned queue")},provider:"owned",duration:0))}
        try publicationDrain(a,ac,producer)
        let queue=try b.withRoutineDatabase {db in XCTAssertEqual(db.handle,bc.database.handle);return try SyncPublicationQueue.install(cache:bc)}
        try body(.init(a:a,ac:ac,b:b,bc:bc,producer:producer,inbox:inbox,secret:secret,operations:ac.journal.outbox(),queue:queue))
    }
    private func queueService(_ store:MemoryStore,_ cache:SyncVersionStore,_ queue:SyncPublicationQueue,_ inbox:SyncObjectFolder,admit:@escaping (SyncPortableRecord)throws->Void={_ in})->SyncPublicationAdmission {
        .init(queue:queue,writer:.init(library:store,cache:cache,admit:admit,pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in}),inbox:inbox)
    }
    @discardableResult private func queueReceive(_ operation:SyncRevision,_ producer:SyncVersionStore,_ service:SyncPublicationAdmission)throws->SyncPublicationAdmissionResult {
        let lease=try service.writer.library.mediaWriteLease();defer {lease.release()}
        return try service.receive(operation,record:operation.mutation == .put ? packet(operation,producer):nil,admission:lease,fetchSource:{try XCTUnwrap(producer.record($0,admit:{_ in}))})
    }
    private func queueRetry(_ producer:SyncVersionStore,_ service:SyncPublicationAdmission,limit:Int=64)throws->[SyncPublicationOutcome] {
        let lease=try service.writer.library.mediaWriteLease();defer {lease.release()}
        return try service.retry(limit:limit,admission:lease,fetchSource:{try XCTUnwrap(producer.record($0,admit:{_ in}))})
    }
    private func supplyDeclarations(_ operations:[SyncRevision],_ producer:SyncObjectFolder,_ service:SyncPublicationAdmission)throws {
        for ref in operations.compactMap(\.publication) {try service.retainDeclaration(XCTUnwrap(producer.content(ref)),reference:ref)}
    }

    func testPublicationQueuePersistsMissingDeclarationAndCompletesAfterLibraryAndInboxReopen()throws {
        try withQueueFixture {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),turn=try XCTUnwrap(f.operations.first{$0.key.kind == .turn}),owner=try packet(turn,f.ac)
            for op in f.operations {_=try queueReceive(op,f.ac,service)}
            XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertEqual(try f.queue.jobs(readyOnly:false).map(\.reason),[.missingDeclaration]);XCTAssertFalse(try f.queue.isComplete(owner.identity))
            let cursor=try f.bc.journal.cursor(for:producerID),outbox=try f.bc.journal.outbox(),inboxRoot=f.inbox.root
            try f.b.close();f.inbox.close()
            let (b,bc)=try endpoint("receiver",receiverID),inbox=try SyncObjectFolder.open(at:inboxRoot,secret:f.secret,group:group,epoch:epoch);defer {try? b.close();inbox.close()}
            let queue=try b.withRoutineDatabase {_ in try SyncPublicationQueue.install(cache:bc)},resumed=queueService(b,bc,queue,inbox)
            XCTAssertEqual(try queue.jobs(readyOnly:false).count,1);XCTAssertEqual(try bc.journal.cursor(for:producerID),cursor)
            try supplyDeclarations(f.operations,f.producer,resumed)
            guard case .projected=try queueRetry(f.ac,resumed).first else {return XCTFail("Durable reopened work must complete when its declaration arrives")}
            XCTAssertTrue(try queue.isComplete(owner.identity));XCTAssertTrue(try queue.jobs(readyOnly:false).isEmpty);XCTAssertEqual(try count(b,"chat_turns"),1)
            XCTAssertEqual(try bc.journal.cursor(for:producerID),cursor);XCTAssertEqual(try bc.journal.outbox(),outbox);try queue.checkAccounting()
        }
    }

    func testPublicationQueuePartialCitationsResumeAfterReopenWithoutPartialNativeAnswer()throws {
        try withQueueFixture(citations:2) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),last=try XCTUnwrap(f.operations.last{$0.key.kind == .conversationCitation}),owner=try packet(XCTUnwrap(f.operations.first{$0.key.kind == .turn}),f.ac)
            try supplyDeclarations(f.operations,f.producer,service)
            for op in f.operations where op.dot.counter<last.dot.counter {_=try queueReceive(op,f.ac,service)}
            XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertEqual(try count(f.b,"chat_sources"),0);XCTAssertEqual(try f.queue.jobs(readyOnly:false).map(\.reason),[.missingCitation])
            try f.b.close();let (b,bc)=try endpoint("receiver",receiverID);defer {try? b.close()}
            let queue=try b.withRoutineDatabase {_ in try SyncPublicationQueue.install(cache:bc)},resumed=queueService(b,bc,queue,f.inbox)
            let result=try queueReceive(last,f.ac,resumed);guard case .projected=result.publications.last else {return XCTFail("Last declared journal head must complete the reopened group")}
            XCTAssertEqual(try count(b,"chat_sources"),2);XCTAssertTrue(try queue.isComplete(owner.identity));XCTAssertTrue(try queue.jobs(readyOnly:false).isEmpty);try queue.checkAccounting()
            XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertEqual(try bc.journal.outbox().count,0)
        }
    }

    func testPublicationQueuePolicyDenialRollsBackNativeGroupButRetainsExplicitDurableWorkAndReceipt()throws {
        try withQueueFixture(citations:2) {f in
            var sawFirst=false
            let service=queueService(f.b,f.bc,f.queue,f.inbox,admit:{record in
                if case .conversationCitation(let body)=record.body,body.ordinal==1 {sawFirst=try self.count(f.b,"chat_sources")==1;throw SyncPublicationPolicyDenied()}
            }),last=try XCTUnwrap(f.operations.last{$0.key.kind == .conversationCitation})
            try supplyDeclarations(f.operations,f.producer,service)
            for op in f.operations where op.dot.counter<last.dot.counter {_=try queueReceive(op,f.ac,service)}
            let result=try queueReceive(last,f.ac,service)
            XCTAssertTrue(sawFirst);XCTAssertEqual(result.publications.last,.withheld(.policyDenied));XCTAssertEqual(result.receipt.applied,1)
            XCTAssertEqual(try f.bc.journal.cursor(for:producerID),last.dot.counter);XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertEqual(try count(f.b,"chat_sources"),0);XCTAssertEqual(try f.queue.jobs(readyOnly:false).map(\.reason),[.policyDenied])
            let allowed=queueService(f.b,f.bc,f.queue,f.inbox)
            guard case .projected=try queueRetry(f.ac,allowed).first else {return XCTFail("A later explicit local policy permit must retry durable work")}
            XCTAssertEqual(try count(f.b,"chat_sources"),2);XCTAssertEqual(try f.bc.journal.cursor(for:producerID),last.dot.counter);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueFullRollsBackSecondReceiptWithoutEvictingFirstJob()throws {
        try withQueueFixture(answers:2) {f in
            try f.queue.setBudgets(pending:640,binding:SyncPublicationQueue.defaultBudget)
            let service=queueService(f.b,f.bc,f.queue,f.inbox),turns=f.operations.filter{$0.key.kind == .turn};XCTAssertEqual(turns.count,2)
            for op in f.operations where op.dot.counter<turns[1].dot.counter {_=try queueReceive(op,f.ac,service)}
            let prior=try f.queue.jobs(readyOnly:false),cursor=try f.bc.journal.cursor(for:producerID),receipts=try count(f.b,"personal_sync_receipts")
            XCTAssertEqual(prior.count,1);XCTAssertThrowsError(try queueReceive(turns[1],f.ac,service))
            XCTAssertEqual(try f.queue.jobs(readyOnly:false).map(\.identity),prior.map(\.identity));XCTAssertEqual(try f.bc.journal.cursor(for:producerID),cursor);XCTAssertEqual(try count(f.b,"personal_sync_receipts"),receipts);XCTAssertTrue(try f.bc.journal.state(for:turns[1].key).heads.isEmpty)
            try f.queue.setBudgets(pending:1280,binding:SyncPublicationQueue.defaultBudget);_=try queueReceive(turns[1],f.ac,service)
            XCTAssertEqual(try f.queue.jobs(readyOnly:false).count,2);XCTAssertEqual(try count(f.b,"chat_turns"),0);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueNativeCitationChangeInvalidatesCompletedDeclarationBinding()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),owner=try packet(XCTUnwrap(f.operations.first{$0.key.kind == .turn}),f.ac)
            try supplyDeclarations(f.operations,f.producer,service)
            for op in f.operations {_=try queueReceive(op,f.ac,service)}
            XCTAssertTrue(try f.queue.isComplete(owner.identity))
            try f.b.withRoutineDatabase {try $0.execute("UPDATE chat_sources SET match='Owned native edit'")}
            XCTAssertFalse(try f.queue.isComplete(owner.identity));XCTAssertEqual(try count(f.b,"personal_sync_publication_bindings"),0);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueMissingProtectionRefusesBothCachedUseAndReinstall()throws {
        try withQueueFixture {f in
            _=try f.queue.jobs();try f.b.withRoutineDatabase {try $0.execute("DROP TRIGGER sync_publication_job_budget")}
            XCTAssertThrowsError(try f.queue.jobs());XCTAssertThrowsError(try SyncPublicationQueue.install(cache:f.bc))
            XCTAssertEqual(try count(f.b,"personal_sync_publication_jobs"),0)
        }
    }

    func testPublicationQueueGapDrainUsesEachOperationsOwnDurableBody()throws {
        try withQueueFixture(answers:2) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),turns=f.operations.filter{$0.key.kind == .turn};XCTAssertEqual(turns.count,2)
            try supplyDeclarations(f.operations,f.producer,service)
            let early=try queueReceive(turns[1],f.ac,service);XCTAssertTrue(early.receipt.inserted);XCTAssertEqual(early.receipt.applied,0)
            XCTAssertEqual(try count(f.b,"chat_turns"),0)
            for op in f.operations where op.dot.counter<turns[0].dot.counter {_=try queueReceive(op,f.ac,service)}
            let drained=try queueReceive(turns[0],f.ac,service);XCTAssertEqual(drained.receipt.applied,2);XCTAssertEqual(drained.publications.count,2)
            let chat=try XCTUnwrap(f.b.chats().first),questions=try f.b.chatTurns(chat.id).map(\.question)
            XCTAssertEqual(Set(questions),["Queue question 0?","Queue question 1?"]);XCTAssertEqual(try count(f.b,"chat_turns"),2)
            for op in turns {XCTAssertTrue(try f.queue.isComplete(packet(op,f.ac).identity))};try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueBindingBudgetRecoveryWakesStoragePressureAfterBlockedRetry()throws {
        try withQueueFixture(answers:2) {f in
            try f.queue.setBudgets(pending:SyncPublicationQueue.defaultBudget,binding:256)
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for op in f.operations {_=try queueReceive(op,f.ac,service)}
            XCTAssertEqual(try count(f.b,"chat_turns"),1);XCTAssertEqual(try f.queue.jobs(readyOnly:false).map(\.reason),[.storagePressure])
            XCTAssertEqual(try queueRetry(f.ac,service),[.withheld(.storagePressure)]);XCTAssertTrue(try f.queue.jobs().isEmpty)
            try f.queue.setBudgets(pending:SyncPublicationQueue.defaultBudget,binding:512)
            guard case .projected=try queueRetry(f.ac,service).first else {return XCTFail("Capacity recovery must wake durable storage-blocked work")}
            XCTAssertEqual(try count(f.b,"chat_turns"),2);XCTAssertEqual(try count(f.b,"personal_sync_publication_bindings"),2);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueAuthenticEarlyDeletionFreesCapacityWithoutAnswerBody()throws {
        try withQueueFixture(answers:2) {f in
            try f.queue.setBudgets(pending:640,binding:SyncPublicationQueue.defaultBudget)
            let service=queueService(f.b,f.bc,f.queue,f.inbox),turns=f.operations.filter{$0.key.kind == .turn},second=try packet(turns[1],f.ac)
            for op in f.operations where op.dot.counter<turns[1].dot.counter {_=try queueReceive(op,f.ac,service)}
            XCTAssertThrowsError(try queueReceive(turns[1],f.ac,service));XCTAssertEqual(try f.queue.jobs(readyOnly:false).count,1)
            let chat=try XCTUnwrap(f.a.chats().first);try f.a.deleteChat(chat.id);try publicationDrain(f.a,f.ac,f.producer)
            let deletions=try f.ac.journal.outbox(after:f.operations.last!.dot.counter),first=try XCTUnwrap(deletions.first{$0.key==turns[0].key})
            let early=try queueReceive(first,f.ac,service);XCTAssertEqual(early.receipt.applied,0,"Exercise the genuine early barrier while a prior put is still missing")
            XCTAssertTrue(try f.bc.journal.state(for:turns[0].key).isDeleted);XCTAssertTrue(try f.queue.jobs(readyOnly:false).isEmpty);try f.queue.checkAccounting()
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(turns[1],record:second,admission:lease,fetchSource:{_ in throw OSwindError.invalid("Source-free deletion fixture must not fetch evidence")})
            for deletion in deletions where deletion.dot.counter != first.dot.counter {_=try queueReceive(deletion,f.ac,service)}
            XCTAssertTrue(try f.queue.jobs(readyOnly:false).isEmpty);XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertEqual(try f.bc.journal.outbox().count,0);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueNativeWipeInvalidatesOldLifetimeWithoutReusingPendingAuthority()throws {
        try withQueueFixture {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            for op in f.operations {_=try queueReceive(op,f.ac,service)}
            XCTAssertEqual(try f.queue.jobs(readyOnly:false).count,1)
            _=try f.b.wipeLibrary()
            XCTAssertThrowsError(try f.queue.jobs());XCTAssertThrowsError(try SyncPublicationQueue.install(cache:f.bc));XCTAssertEqual(try count(f.b,"chat_turns"),0)
        }
    }
}
