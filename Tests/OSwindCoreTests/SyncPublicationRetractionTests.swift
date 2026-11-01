import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func queueReplacement(_ fixture:PublicationQueueFixture,text:String,citations:[SyncPortableRecord]=[])throws->(SyncPortableRecord,SyncTurnPublication,SyncRevision) {
        let operation=try XCTUnwrap(fixture.operations.first{$0.key.kind == .turn}),old=try packet(operation,fixture.ac)
        guard case .turn(let body)=old.body else {throw OSwindError.invalid("Owned answer missing")}
        let next=try SyncPortableRecord(identity:old.identity,body:.turn(.init(conversation:body.conversation,timestamp:body.timestamp,question:body.question,text:text,provider:body.provider,duration:body.duration,warnings:body.warnings,filter:body.filter,timeZone:body.timeZone)))
        let proof=try SyncTurnPublication(group:group,epoch:epoch,owner:next.reference,citations:citations)
        return (next,proof,try fixture.ac.journal.put(key:operation.key,content:next.reference.content,publication:proof.reference))
    }

    func testPublicationQueueRetractionAbortRestoresMappingsNativeGraphCacheAndReceipt()throws {
        try withQueueFixture(citations:2) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let records=try f.operations.filter{[.turn,.conversationCitation].contains($0.key.kind)}.map{try packet($0,f.ac)},keys=try records.map{try f.bc.catalog.object($0.identity)?.primary}
            let chat=try XCTUnwrap(f.b.chats().first),before=try f.b.chatTurns(chat.id),cursor=try f.bc.journal.cursor(for:producerID),outbox=try f.bc.journal.outbox()
            let (next,_,revision)=try queueReplacement(f,text:"Pending owned replacement")
            // This trigger runs after the catalogue mappings have moved. Its
            // deliberate failure must roll the entire received update back.
            try f.b.withRoutineDatabase {db in try db.execute("""
                CREATE TEMP TRIGGER owned_retraction_abort BEFORE DELETE ON main.chat_turns BEGIN
                    SELECT CASE WHEN EXISTS(SELECT 1 FROM main.personal_sync_identity_current WHERE table_name='chat_turns' AND local_key=oswind_sync_key_v1(old.id)) THEN RAISE(ABORT,'owned test: bindings were not moved') END;
                    SELECT RAISE(ABORT,'owned test: abort after catalogue relocation');
                END
                """)}
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            XCTAssertThrowsError(try service.receive(revision,record:next,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})) {error in
                XCTAssertTrue(String(describing:error).contains("abort after catalogue relocation"),String(describing:error))
            }
            XCTAssertEqual(try f.b.chatTurns(chat.id).map(\.id),before.map(\.id));XCTAssertEqual(try f.b.chatTurns(chat.id).first?.answer.text,before.first?.answer.text)
            XCTAssertEqual(try count(f.b,"chat_sources"),2);XCTAssertEqual(try count(f.b,"personal_sync_version_revoked"),0)
            XCTAssertTrue(try f.queue.jobs(readyOnly:false).isEmpty);XCTAssertTrue(try f.queue.isComplete(next.identity));XCTAssertEqual(try f.bc.journal.cursor(for:producerID),cursor);XCTAssertEqual(try f.bc.journal.outbox(),outbox)
            for (index,record) in records.enumerated() {XCTAssertEqual(try f.bc.catalog.object(record.identity)?.primary,keys[index]);XCTAssertEqual(try f.bc.resolve(record.identity,content:nil,admit:{_ in}).reference,try record.reference)}
            try f.b.withRoutineDatabase {try $0.execute("DROP TRIGGER temp.owned_retraction_abort")}
            let received=try service.receive(revision,record:next,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})
            XCTAssertTrue(received.receipt.inserted);XCTAssertEqual(received.receipt.applied,1);XCTAssertTrue(try f.b.chatTurns(chat.id).isEmpty);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueRetractedBackupRestoresQuietWithoutAnswerOrQueueAuthority()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let (next,proof,revision)=try queueReplacement(f,text:"Independent backup replacement")
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(revision,record:next,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})
            let archive=root.appendingPathComponent("retracted.oswindbackup"),destination=root.appendingPathComponent("quiet-restore")
            let info=try LibraryBackup.create(store:f.b,destination:archive);XCTAssertEqual(info.turns,0)
            _=try LibraryBackup.restore(archive,to:destination)
            let restored=try MemoryStore(root:destination);defer {try? restored.close()}
            XCTAssertEqual(try count(restored,"chat_turns"),0);XCTAssertEqual(try count(restored,"chat_sources"),0)
            try restored.withRoutineDatabase {db in
                XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE type='table' AND name LIKE 'personal_sync_%' AND name NOT IN ('personal_sync_capture','personal_sync_changes')"),0,"A quiet restore may contain disabled native capture tables, but no enrollment, identity, journal or pending admission authority")
                XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM personal_sync_capture WHERE enabled!=0 OR suppressed!=0 OR used_bytes!=0"),0)
                XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM personal_sync_changes"),0)
                XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM store_metadata WHERE key='sync-publication-library-lifetime-v1'"),0)
                XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM pragma_foreign_key_check"),0)
            }
            XCTAssertEqual(try f.queue.jobs(readyOnly:false).count,1)
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            guard case .projected=try queueRetry(f.ac,service).first else {return XCTFail("Backing up must leave original durable admission available")}
            XCTAssertEqual(try count(f.b,"chat_turns"),1);XCTAssertEqual(try count(restored,"chat_turns"),0);try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueContiguousThirdPeerDeletionWaitsForItsMissingProducerContext()throws {
        try withQueueFixture(citations:1) {f in
            let third="00000000-0000-0000-0000-000000006213",(c,cc)=try endpoint("gap-eraser",third);defer {try? c.close()}
            try cc.journal.allowPeer(producerID);try f.bc.journal.allowPeer(third)
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service);_=try cc.journal.receive(operation,contentAvailable:{_ in true})}
            let (next,proof,update)=try queueReplacement(f,text:"Independent answer after third-peer causal gap")
            _=try cc.journal.receive(update,contentAvailable:{_ in true})
            let citation=try XCTUnwrap(f.operations.first{$0.key.kind == .conversationCitation}),deletion=try cc.journal.delete(key:citation.key)
            XCTAssertEqual(deletion.dot.counter,1);XCTAssertTrue(deletion.context.contains(update.dot))
            let early=try queueReceive(deletion,cc,service);XCTAssertEqual(early.receipt.applied,0)
            XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertFalse(try f.bc.journal.state(for:next.identity.key).isDeleted)
            XCTAssertEqual(try queueRetry(f.ac,service),[.withheld(.causalGap)])
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(update,record:next,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})
            guard case .projected=try queueRetry(f.ac,service).first else {return XCTFail("Cross-peer context arrival must wake durable withheld work")}
            XCTAssertTrue(try f.queue.isComplete(next.identity));XCTAssertEqual(try f.b.chatTurns(XCTUnwrap(f.b.chats().first).id).first?.answer.text,"Independent answer after third-peer causal gap");try f.queue.checkAccounting()
        }
    }

    func testPublicationQueueRetractedIndependentHeadSurvivesActualOldSourceErasure()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let (next,proof,update)=try queueReplacement(f,text:"Independent answer survives prior source erasure")
            let lease=try f.b.mediaWriteLease();defer {lease.release()}
            _=try service.receive(update,record:next,admission:lease,fetchSource:{try XCTUnwrap(f.ac.record($0,admit:{_ in}))})
            let source=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),deletion=try f.ac.journal.delete(key:source.key)
            _=try queueReceive(deletion,f.ac,service)
            XCTAssertEqual(try count(f.b,"memories"),0);XCTAssertEqual(try count(f.b,"chat_turns"),0)
            XCTAssertTrue(try f.bc.journal.state(for:source.key).isDeleted);XCTAssertFalse(try f.bc.journal.state(for:next.identity.key).isDeleted)
            try service.retainDeclaration(proof.encoded(),reference:proof.reference)
            guard case .projected=try queueRetry(f.ac,service).first else {return XCTFail("Old evidence cannot erase an independent admitted pending head")}
            XCTAssertTrue(try f.queue.isComplete(next.identity));XCTAssertEqual(try f.b.chatTurns(XCTUnwrap(f.b.chats().first).id).first?.answer.text,"Independent answer survives prior source erasure");try f.queue.checkAccounting()
        }
    }
}
