import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    struct PublicationQueueFixture {
        let a:MemoryStore,ac:SyncVersionStore,b:MemoryStore,bc:SyncVersionStore
        let producer:SyncObjectFolder,inbox:SyncObjectFolder,secret:SyncGroupSecret
        let operations:[SyncRevision],queue:SyncPublicationQueue
    }
    func withQueueFixture(citations:Int=0,answers:Int=1,secret:SyncGroupSecret=SyncGroupSecret(),_ body:(PublicationQueueFixture)throws->Void)throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),producer=try publicationSpace("queue-producer")
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
    func queueService(_ store:MemoryStore,_ cache:SyncVersionStore,_ queue:SyncPublicationQueue,_ inbox:SyncObjectFolder,admit:@escaping (SyncPortableRecord)throws->Void={_ in})->SyncPublicationAdmission {
        .init(queue:queue,writer:.init(library:store,cache:cache,admit:admit,pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in}),inbox:inbox)
    }
    @discardableResult func queueReceive(_ operation:SyncRevision,_ producer:SyncVersionStore,_ service:SyncPublicationAdmission)throws->SyncPublicationAdmissionResult {
        let lease=try service.writer.library.mediaWriteLease();defer {lease.release()}
        return try service.receive(operation,record:operation.mutation == .put ? packet(operation,producer):nil,admission:lease,fetchSource:{try XCTUnwrap(producer.record($0,admit:{_ in}))})
    }
    func queueRetry(_ producer:SyncVersionStore,_ service:SyncPublicationAdmission,limit:Int=64)throws->[SyncPublicationOutcome] {
        let lease=try service.writer.library.mediaWriteLease();defer {lease.release()}
        return try service.retry(limit:limit,admission:lease,fetchSource:{try XCTUnwrap(producer.record($0,admit:{_ in}))})
    }
    func supplyDeclarations(_ operations:[SyncRevision],_ producer:SyncObjectFolder,_ service:SyncPublicationAdmission)throws {
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

    func testPublicationQueueExplicitPolicyReviewWakesOnlyBlockedWorkAfterRepeatedDenial()throws {
        try withQueueFixture {f in
            let denied=queueService(f.b,f.bc,f.queue,f.inbox,admit:{packet in if packet.identity.table == .turn {throw SyncPublicationPolicyDenied()}})
            try supplyDeclarations(f.operations,f.producer,denied)
            for op in f.operations {_=try queueReceive(op,f.ac,denied)}
            XCTAssertEqual(try queueRetry(f.ac,denied),[.withheld(.policyDenied)]);XCTAssertTrue(try f.queue.jobs().isEmpty)
            XCTAssertEqual(try f.queue.wakeReason(.policyDenied,limit:1),1)
            guard case .projected=try queueRetry(f.ac,queueService(f.b,f.bc,f.queue,f.inbox)).first else {return XCTFail("Explicit local policy review must wake its durable reason bucket")}
            XCTAssertEqual(try count(f.b,"chat_turns"),1);XCTAssertTrue(try f.queue.jobs(readyOnly:false).isEmpty);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueLateDeclarationRetiresAuthenticErasedEvidenceBeforePolicyAtBindingCapacity()throws {
        try withQueueFixture(citations:1) {f in
            let third="00000000-0000-0000-0000-000000006211",(c,cc)=try endpoint("queue-eraser",third);defer {try? c.close()}
            try cc.journal.allowPeer(producerID);try f.bc.journal.allowPeer(third)
            let initial=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),source=try packet(initial,f.ac),local=try receive(initial,source,c,cc,fetch:{_ in source})
            let service=queueService(f.b,f.bc,f.queue,f.inbox,admit:{packet in if packet.identity.table == .turn {XCTFail("Known-erased evidence must not reach answer policy")}}),turn=try XCTUnwrap(f.operations.first{$0.key.kind == .turn})
            for op in f.operations where op.dot.counter<=turn.dot.counter {_=try queueReceive(op,f.ac,service)}
            try f.queue.setBudgets(pending:SyncPublicationQueue.defaultBudget,binding:1)
            try c.delete(local);try drain(c,cc)
            for deletion in try cc.journal.outbox() {_=try queueReceive(deletion,f.ac,service)}
            try supplyDeclarations(f.operations,f.producer,service)
            XCTAssertEqual(try queueRetry(f.ac,service),[.retired(turn.key)])
            XCTAssertTrue(try f.bc.journal.state(for:turn.key).isDeleted);XCTAssertTrue(try f.queue.jobs(readyOnly:false).isEmpty)
            XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertEqual(try count(f.b,"chat_sources"),0);try f.queue.checkAccounting()
            let announced=try XCTUnwrap(f.bc.journal.outbox().first{$0.key==turn.key});XCTAssertTrue(announced.context.contains(turn.dot));XCTAssertTrue(try announced.context.contains(XCTUnwrap(cc.journal.outbox().last).dot))
        }
    }

    func testPublicationQueueCoalescesOneOwnerAndIndexesOnlyDeclaredDependencyKeys()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),turn=try XCTUnwrap(f.operations.first{$0.key.kind == .turn}),owner=try packet(turn,f.ac)
            try supplyDeclarations(f.operations,f.producer,service)
            for op in f.operations where op.dot.counter<=turn.dot.counter {_=try queueReceive(op,f.ac,service)}
            let initial=try XCTUnwrap(f.queue.jobs(readyOnly:false).first)
            _=try queueRetry(f.ac,service);XCTAssertEqual(try f.queue.jobs(readyOnly:false).count,1)
            XCTAssertEqual(try f.queue.jobs(readyOnly:false).first?.ordinal,initial.ordinal);XCTAssertEqual(try count(f.b,"personal_sync_publication_dependencies"),3)
            let unrelated=try SyncObjectKey(kind:.source,digest:String(repeating:"a",count:64));try f.queue.wake(unrelated);XCTAssertTrue(try f.queue.jobs().isEmpty)
            let citation=try XCTUnwrap(f.operations.first{$0.key.kind == .conversationCitation});try f.queue.wake(citation.key)
            XCTAssertEqual(try f.queue.jobs().map(\.identity),[owner.identity]);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueDeclaredCitationDeletionRetiresItsReadableOwner()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),turn=try XCTUnwrap(f.operations.first{$0.key.kind == .turn}),citation=try XCTUnwrap(f.operations.first{$0.key.kind == .conversationCitation})
            try supplyDeclarations(f.operations,f.producer,service)
            for op in f.operations {_=try queueReceive(op,f.ac,service)}
            XCTAssertEqual(try count(f.b,"chat_turns"),1)
            // Authenticated content-free wire deletion of an actual declared
            // lifetime; no fabricated child body supplies owner authority.
            let deletion=try f.ac.journal.delete(key:citation.key);_=try queueReceive(deletion,f.ac,service)
            XCTAssertEqual(try count(f.b,"chat_turns"),0,"An admitted answer cannot remain readable after required citation retirement")
            XCTAssertTrue(try f.bc.journal.state(for:turn.key).isDeleted);XCTAssertTrue(try f.queue.jobs(readyOnly:false).isEmpty);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueuePendingIndependentHeadWithdrawsOldReadableBodyWithoutGlobalRetirement()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),turn=try XCTUnwrap(f.operations.first{$0.key.kind == .turn}),citation=try XCTUnwrap(f.operations.first{$0.key.kind == .conversationCitation}),old=try packet(turn,f.ac)
            try supplyDeclarations(f.operations,f.producer,service)
            for op in f.operations {_=try queueReceive(op,f.ac,service)}
            guard case .turn(let body)=old.body else {return XCTFail("Owned prior turn missing")}
            // Authored supported wire-version update, not a claim that the app
            // exposes a public stored-answer editing UI. The newer version is
            // independently source-free and its declaration is withheld.
            let next=try SyncPortableRecord(identity:old.identity,body:.turn(.init(conversation:body.conversation,timestamp:body.timestamp,question:body.question,text:"Independent newer answer",provider:body.provider,duration:body.duration,warnings:body.warnings,filter:body.filter,timeZone:body.timeZone)))
            let declaration=try SyncTurnPublication(group:group,epoch:epoch,owner:next.reference,citations:[]),revision=try f.ac.journal.put(key:turn.key,content:next.reference.content,publication:declaration.reference)
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(revision,record:next,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})
            let deletion=try f.ac.journal.delete(key:citation.key);_=try queueReceive(deletion,f.ac,service)
            let chat=try XCTUnwrap(f.b.chats().first)
            XCTAssertTrue(try f.b.chatTurns(chat.id).isEmpty,"The old source-derived body must be withdrawn while the new declaration is missing")
            XCTAssertFalse(try f.bc.journal.state(for:turn.key).isDeleted,"An old citation cannot globally erase an independent newer head")
            try service.retainDeclaration(declaration.encoded(),reference:declaration.reference)
            guard case .projected=try queueRetry(f.ac,service).first else {return XCTFail("The independent new head must survive and complete")}
            XCTAssertEqual(try f.b.chatTurns(chat.id).first?.answer.text,"Independent newer answer");XCTAssertTrue(try f.queue.isComplete(next.identity));try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueEarlyCitationDeletionCannotRetireUnseenIndependentOwnerHead()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),turn=try XCTUnwrap(f.operations.first{$0.key.kind == .turn}),citation=try XCTUnwrap(f.operations.first{$0.key.kind == .conversationCitation}),old=try packet(turn,f.ac)
            try supplyDeclarations(f.operations,f.producer,service)
            for op in f.operations {_=try queueReceive(op,f.ac,service)}
            guard case .turn(let body)=old.body else {return XCTFail("Owned turn missing")}
            let next=try SyncPortableRecord(identity:old.identity,body:.turn(.init(conversation:body.conversation,timestamp:body.timestamp,question:body.question,text:"Independent answer across real sender gap",provider:body.provider,duration:body.duration,warnings:body.warnings,filter:body.filter,timeZone:body.timeZone)))
            let proof=try SyncTurnPublication(group:group,epoch:epoch,owner:next.reference,citations:[]),update=try f.ac.journal.put(key:turn.key,content:next.reference.content,publication:proof.reference),deletion=try f.ac.journal.delete(key:citation.key)
            XCTAssertTrue(deletion.context.contains(update.dot))
            let early=try queueReceive(deletion,f.ac,service)
            XCTAssertEqual(early.receipt.applied,0,"The replacement must be genuinely absent, not merely lack its declaration")
            XCTAssertEqual(try count(f.b,"chat_turns"),0,"Erase the stale native answer immediately even across a sender gap")
            XCTAssertFalse(try f.bc.journal.state(for:turn.key).isDeleted,"A citation's causal clock can hide a valid independent owner update")
            XCTAssertEqual(try queueRetry(f.ac,service),[.withheld(.causalGap)],"A worker retry must not turn an unresolved causal gap into global deletion")
            XCTAssertTrue(try f.queue.jobs().isEmpty);XCTAssertEqual(try f.queue.jobs(readyOnly:false).first?.reason,.causalGap)
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(update,record:next,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})
            _=try queueRetry(f.ac,service)
            let chat=try XCTUnwrap(f.b.chats().first)
            XCTAssertEqual(try f.b.chatTurns(chat.id).first?.answer.text,"Independent answer across real sender gap")
            XCTAssertTrue(try f.queue.isComplete(next.identity));XCTAssertFalse(try f.bc.journal.state(for:turn.key).isDeleted);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueRetractionPreservesExactLiveCitationKeysAndReprojectsSameEvidence()throws {
        try withQueueFixture(citations:2) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox),turn=try XCTUnwrap(f.operations.first{$0.key.kind == .turn}),old=try packet(turn,f.ac)
            try supplyDeclarations(f.operations,f.producer,service)
            for op in f.operations {_=try queueReceive(op,f.ac,service)}
            let records=try [old]+f.operations.filter{$0.key.kind == .conversationCitation}.map{try packet($0,f.ac)}
            let mappings=try records.map{try XCTUnwrap(f.bc.catalog.object($0.identity)).primary},outbox=try f.bc.journal.outbox()
            guard case .turn(let body)=old.body else {return XCTFail("Owned turn missing")}
            let next=try SyncPortableRecord(identity:old.identity,body:.turn(.init(conversation:body.conversation,timestamp:body.timestamp,question:body.question,text:"Revised answer with identical declared evidence",provider:body.provider,duration:body.duration,warnings:body.warnings,filter:body.filter,timeZone:body.timeZone)))
            let proof=try SyncTurnPublication(group:group,epoch:epoch,owner:next.reference,citations:Array(records.dropFirst())),update=try f.ac.journal.put(key:turn.key,content:next.reference.content,publication:proof.reference)
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(update,record:next,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})
            XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertEqual(try count(f.b,"chat_sources"),0)
            XCTAssertEqual(try count(f.b,"personal_sync_version_revoked"),0);XCTAssertEqual(try count(f.b,"personal_sync_publication_bindings"),0)
            XCTAssertEqual(try f.bc.journal.outbox(),outbox);XCTAssertEqual(try count(f.b,"personal_sync_changes"),0)
            for (index,record) in records.enumerated() {
                XCTAssertEqual(try f.bc.catalog.object(record.identity)?.primary,mappings[index]);XCTAssertFalse(try XCTUnwrap(f.bc.catalog.object(record.identity)).deleted)
                XCTAssertFalse(try f.bc.catalog.nativeExists(for:record.identity.key))
                let row=try f.bc.database.statement("SELECT count(*) FROM personal_sync_versions WHERE object_digest=?");defer {sqlite3_finalize(row)};f.bc.database.bind(row,1,try record.identity.key.digest)
                XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int64(row,0),0,"Retracted native body cache must be purged")
            }
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            guard case .projected=try queueRetry(f.ac,service).first else {return XCTFail("Same live citation lifetimes must reproject without revocation bypass")}
            for (index,record) in records.enumerated() {XCTAssertEqual(try f.bc.catalog.object(record.identity)?.primary,mappings[index]);XCTAssertTrue(try f.bc.catalog.nativeExists(for:record.identity.key))}
            XCTAssertEqual(try count(f.b,"personal_sync_version_revoked"),0);XCTAssertTrue(try f.queue.isComplete(next.identity));XCTAssertEqual(try f.bc.journal.outbox(),outbox);try f.queue.checkAccounting()
        }
    }
}
