import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func publicationSpace(_ name:String="publication-space")throws->SyncObjectFolder {
        try SyncObjectFolder.create(at:root.appendingPathComponent(name),secret:SyncGroupSecret(),group:group,epoch:epoch)
    }
    func publicationDrain(_ store:MemoryStore,_ cache:SyncVersionStore,_ space:SyncObjectFolder)throws {
        let processor=SyncOutgoingProcessor(queue:try .install(catalog:cache.catalog),cache:cache,admitRow:{_,_ in},admitVersion:{_ in},media:{memory in
            try self.paths(memory).map {role,path in
                let bytes=try Data(contentsOf:store.root.appendingPathComponent(path)),reference=try SyncContentReference(data:bytes)
                return SyncMediaManifest(role:role,sha256:reference.sha256,bytes:reference.bytes,chunks:[reference])
            }.sorted{$0.role.rawValue<$1.role.rawValue}
        },retainTurnPublication:{try space.publishContent($1,reference:$0)})
        for _ in 0..<2000 {if try processor.step() == .idle {return}}
        throw OSwindError.invalid("Owned publication queue did not drain")
    }
    @discardableResult func publicationReceive(_ operation:SyncRevision,_ record:SyncPortableRecord,_ store:MemoryStore,_ cache:SyncVersionStore,_ producer:SyncVersionStore,_ space:SyncObjectFolder?,admit:@escaping (SyncPortableRecord)throws->Void={_ in},manifest:((SyncContentReference)throws->Data?)?=nil)throws->SyncPublicationOutcome? {
        let lease=try store.mediaWriteLease();defer {lease.release()};var outcome:SyncPublicationOutcome?
        let writer=SyncIncomingConversationWriter(library:store,cache:cache,admit:admit,pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in}),gate=SyncIncomingTurnPublicationWriter(writer:writer)
        let fetch:(SyncVersionReference)throws->SyncPortableRecord={try XCTUnwrap(producer.record($0,admit:{_ in}))}
        let declaration:(SyncContentReference)throws->Data?=manifest ?? {try space?.content($0)}
        let received=try cache.journal.receive(operation,contentAvailable:{_ in true}) {change in
            if change.after.isDeleted {try writer.applyDeletion(change,admission:lease);outcome = .retired(change.revision.key)}
            else {switch record.body {
            case .turn:outcome=try gate.apply(record,admission:lease,fetchManifest:declaration,fetchExactSource:fetch)
            case .conversationCitation:outcome=try gate.applyCitation(record,admission:lease,fetchManifest:declaration,fetchRecord:fetch)
            default:_=try writer.apply(record,admission:lease,fetchExactSource:fetch)
            }}
        }
        XCTAssertEqual(received.applied,1,"A journal receipt is distinct from a projected publication")
        return outcome
    }
    /// Complete service delivery gate. The lower-level typed adapter currently
    /// learns a turn's evidence only from later, separately published citations.
    /// A future publication admission layer must not expose that interim body.
    func testIncompleteCitedTurnNeverBecomesReadableBeforeEvidenceDeclaration()throws {
        let eraser="00000000-0000-0000-0000-000000006196"
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(c,cc)=try endpoint("eraser",eraser)
        defer {try? a.close();try? b.close();try? c.close()}
        try bc.journal.allowPeer(producerID);try bc.journal.allowPeer(eraser);try cc.journal.allowPeer(producerID)
        let source=Memory(id:"owned-publication-evidence",timestamp:now,kind:.note,app:"Owned publication",text:"Authored original evidence for the visibility gate")
        try a.insert(source);try drain(a,ac)
        let initial=try XCTUnwrap(ac.journal.outbox().first),original=try packet(initial,ac)
        _=try receive(initial,original,b,bc,fetch:{_ in original})
        let eraserSource=try receive(initial,original,c,cc,fetch:{_ in original})
        let space=try publicationSpace();defer {space.close()}
        let chat=try a.createChat(title:"Owned cited publication"),canary="OwnedPublicationVisibilityCanary8k31"
        _=try a.appendChatTurn(sessionID:chat.id,question:"Owned cited question",answer:.init(text:"This authored answer must await complete evidence admission [1]. "+canary,sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0));try publicationDrain(a,ac,space)
        let operations=try ac.journal.outbox(after:initial.dot.counter),turn=try XCTUnwrap(operations.first {$0.key.kind == .turn}),citation=try XCTUnwrap(operations.first {$0.key.kind == .conversationCitation})
        XCTAssertLessThan(turn.dot.counter,citation.dot.counter,"Exercise the actual separate publication order")
        try c.delete(eraserSource);try drain(c,cc)
        for deletion in try cc.journal.outbox() {XCTAssertEqual(deletion.mutation,.delete);try receiveDeletion(deletion,b,bc)}
        XCTAssertTrue(try bc.journal.state(for:original.identity.key).isDeleted)
        var localChat:String?
        for operation in operations where operation.dot.counter<turn.dot.counter {
            let value=try packet(operation,ac),local=try receive(operation,value,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if value.identity.table == .conversation {localChat=local}
        }
        XCTAssertNotNil(turn.publication)
        XCTAssertEqual(try publicationReceive(turn,packet(turn,ac),b,bc,ac,nil,admit:{_ in XCTFail("No incomplete body admission")}),.withheld(.missingDeclaration))
        // This is the missing intermediate visibility gate, not merely an
        // after-all-children deletion assertion. Owned canary text only.
        XCTAssertEqual(try count(b,"chat_turns"),0,"An incomplete evidence publication must remain unreadable")
        let readable=try b.chatTurns(try XCTUnwrap(localChat));XCTAssertFalse(readable.contains {$0.answer.text.contains(canary)},"Retiring the body later does not close an earlier disclosure window")
        XCTAssertEqual(try publicationReceive(citation,packet(citation,ac),b,bc,ac,space,admit:{_ in XCTFail("Known-erased evidence must not reach body admission")}),.retired(turn.key))
        XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertTrue(try bc.journal.state(for:turn.key).isDeleted)
        XCTAssertEqual(try bc.journal.cursor(for:producerID),citation.dot.counter)
    }

    func testPublicationProjectsAllCitationsAtomicallyAfterLastDeclaredHead()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),space=try publicationSpace();defer {try? a.close();try? b.close();space.close()};try bc.journal.allowPeer(producerID)
        let sources=[Memory(id:"one",timestamp:now,kind:.note,app:"Owned",text:"First authored original"),Memory(id:"two",timestamp:now,kind:.note,app:"Owned",text:"Second authored original")]
        for source in sources {try a.insert(source)}
        let chat=try a.createChat(title:"Complete publication")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Owned complete?",answer:.init(text:"Both originals [1] [2]",sources:sources.map{.init(memory:$0,score:0.75,match:"authored")},provider:"owned",duration:0.25,warnings:["Owned warning"]));try publicationDrain(a,ac,space)
        let operations=try ac.journal.outbox(),turn=try XCTUnwrap(operations.first{$0.key.kind == .turn}),children=operations.filter{$0.key.kind == .conversationCitation}
        XCTAssertEqual(children.count,2);XCTAssertLessThan(turn.dot.counter,children[0].dot.counter)
        let declaration=try SyncTurnPublication.decode(XCTUnwrap(space.content(XCTUnwrap(turn.publication))),expected:XCTUnwrap(turn.publication));XCTAssertEqual(declaration.citations.count,2)
        var localChat="",last:SyncPublicationOutcome?
        let before=try bc.journal.outbox()
        for op in operations {
            let record=try packet(op,ac)
            if let outcome=try publicationReceive(op,record,b,bc,ac,space) {last=outcome}
            if record.identity.table == .conversation {localChat="peer-"+(try record.identity.key.digest)}
            if op.dot.counter < children.last!.dot.counter {XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertEqual(try count(b,"chat_sources"),0)}
            if op.key.kind == .turn {XCTAssertEqual(last,.withheld(.missingCitation))}
        }
        guard case .projected=last else {return XCTFail("Last complete child must publish the whole answer")}
        let read=try XCTUnwrap(b.chatTurns(localChat).first)
        XCTAssertEqual(read.answer.text,"Both originals [1] [2]");XCTAssertEqual(read.answer.sources.map{$0.memory.text},sources.map(\.text));XCTAssertEqual(read.answer.warnings,["Owned warning"])
        XCTAssertTrue(read.answer.sources.allSatisfy{$0.memory.originalEvidence != nil});XCTAssertEqual(try count(b,"chat_sources"),2)
        XCTAssertEqual(try bc.journal.outbox(),before);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }

    func testPublicationExplicitEmptyEvidencePublishesIndependentAnswer()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),space=try publicationSpace();defer {try? a.close();try? b.close();space.close()};try bc.journal.allowPeer(producerID)
        let chat=try a.createChat(title:"Independent answer")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Owned empty?",answer:.init(text:"Explicitly source-free authored answer",sources:[],provider:"owned",duration:0));try publicationDrain(a,ac,space)
        var result:SyncPublicationOutcome?
        for op in try ac.journal.outbox() {result=try publicationReceive(op,packet(op,ac),b,bc,ac,space)}
        guard case .projected=result else {return XCTFail("An authentic empty declaration is complete")}
        XCTAssertEqual(try count(b,"chat_turns"),1);XCTAssertEqual(try count(b,"chat_sources"),0)
    }

    func testPublicationLegacyOwnerIsWithheldInsteadOfAssumedSourceFree()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let chat=try a.createChat(title:"Legacy owner")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Legacy?",answer:.init(text:"No declaration does not mean no evidence",sources:[],provider:"owned",duration:0));try drain(a,ac)
        for op in try ac.journal.outbox() {let result=try publicationReceive(op,packet(op,ac),b,bc,ac,nil);if op.key.kind == .turn {XCTAssertEqual(result,.withheld(.legacyDeclaration))}}
        XCTAssertEqual(try count(b,"chat_turns"),0)
    }

    func testPublicationTamperedManifestRollsBackJournalAndReadableHistory()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),space=try publicationSpace();defer {try? a.close();try? b.close();space.close()};try bc.journal.allowPeer(producerID)
        let chat=try a.createChat(title:"Tamper fixture")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Tamper?",answer:.init(text:"Owned answer",sources:[],provider:"owned",duration:0));try publicationDrain(a,ac,space)
        let operations=try ac.journal.outbox(),turn=try XCTUnwrap(operations.first{$0.key.kind == .turn})
        for op in operations where op.dot.counter<turn.dot.counter {_=try publicationReceive(op,packet(op,ac),b,bc,ac,space)}
        let cursor=try bc.journal.cursor(for:producerID),receipts=try count(b,"personal_sync_receipts")
        XCTAssertThrowsError(try publicationReceive(turn,packet(turn,ac),b,bc,ac,space,manifest:{_ in Data("tampered".utf8)}))
        XCTAssertEqual(try bc.journal.cursor(for:producerID),cursor);XCTAssertEqual(try count(b,"personal_sync_receipts"),receipts);XCTAssertTrue(try bc.journal.state(for:turn.key).heads.isEmpty);XCTAssertEqual(try count(b,"chat_turns"),0)
        guard case .projected=try publicationReceive(turn,packet(turn,ac),b,bc,ac,space) else {return XCTFail("Exact retry must publish")}
    }

    func testPublicationUnlistedErasedCitationCannotDeleteIndependentOwner()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),space=try publicationSpace();defer {try? a.close();try? b.close();space.close()};try bc.journal.allowPeer(producerID)
        let source=Memory(id:"erased",timestamp:now,kind:.note,app:"Owned",text:"Owned erased evidence")
        try a.insert(source);try drain(a,ac);let initial=try XCTUnwrap(ac.journal.outbox().first),original=try packet(initial,ac)
        _=try receive(initial,original,b,bc,fetch:{_ in original})
        let chat=try a.createChat(title:"Independent protected owner")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Independent?",answer:.init(text:"Independent source-free answer",sources:[],provider:"owned",duration:0));try publicationDrain(a,ac,space)
        let ops=try ac.journal.outbox(after:initial.dot.counter),turn=try XCTUnwrap(ops.first{$0.key.kind == .turn}),owner=try packet(turn,ac)
        for op in ops {_=try publicationReceive(op,packet(op,ac),b,bc,ac,space)}
        try a.delete(source.id);try drain(a,ac)
        for deletion in try ac.journal.outbox(after:ops.last!.dot.counter) {try receiveDeletion(deletion,b,bc)}
        let identity=try SyncObjectIdentity(table:.conversationCitation,origin:producerID,lifetime:UUID().uuidString.lowercased())
        let forged=try SyncPortableRecord(identity:identity,body:.conversationCitation(.init(owner:owner.identity,ordinal:0,link:.init(source:original.reference,score:1,match:"unlisted",passage:nil))))
        let op=try ac.journal.put(key:identity.key,content:forged.reference.content)
        XCTAssertEqual(try publicationReceive(op,forged,b,bc,ac,space),.withheld(.unlistedCitation))
        XCTAssertEqual(try count(b,"chat_turns"),1);XCTAssertFalse(try bc.journal.state(for:turn.key).isDeleted);XCTAssertEqual(try count(b,"chat_sources"),0)
    }

    private func withPublication(citations:Int=2,_ body:(MemoryStore,SyncVersionStore,MemoryStore,SyncVersionStore,SyncObjectFolder,[SyncRevision])throws->Void)throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),space=try publicationSpace();defer {try? a.close();try? b.close();space.close()};try bc.journal.allowPeer(producerID)
        var sources=[Memory]()
        for index in 0..<citations {let source=Memory(id:"owned-\(index)",timestamp:now,kind:.note,app:"Owned publication",text:"Authored publication original \(index)");sources.append(source);try a.insert(source)}
        let chat=try a.createChat(title:"Owned publication test")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Owned publication?",answer:.init(text:"Owned publication answer",sources:sources.map{.init(memory:$0,score:1,match:"authored")},provider:"owned",duration:0));try publicationDrain(a,ac,space)
        try body(a,ac,b,bc,space,ac.journal.outbox())
    }

    func testPublicationFailureAfterFirstNativeCitationRollsBackWholeGroupAndReceipt()throws {
        try withPublication {_,ac,b,bc,space,ops in
            let last=try XCTUnwrap(ops.last{$0.key.kind == .conversationCitation}),record=try packet(last,ac),turn=try XCTUnwrap(ops.first{$0.key.kind == .turn})
            XCTAssertEqual(last.key.kind,.conversationCitation)
            for op in ops where op.dot.counter<last.dot.counter {_=try publicationReceive(op,packet(op,ac),b,bc,ac,space)}
            let receipts=try count(b,"personal_sync_receipts"),versions=try count(b,"personal_sync_versions"),originals=try count(b,"historical_evidence"),outbox=try bc.journal.outbox(),cursor=try bc.journal.cursor(for:producerID)
            var sawFirstNativeCitation=false
            XCTAssertThrowsError(try publicationReceive(last,record,b,bc,ac,space,admit:{value in
                if case .conversationCitation(let citation)=value.body,citation.ordinal==1 {
                    sawFirstNativeCitation = try self.count(b,"chat_sources")==1
                    throw OSwindError.unavailable("Owned policy failure after first native citation")
                }
            }))
            XCTAssertTrue(sawFirstNativeCitation,"Actually fail after partial work inside the uncommitted group")
            XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertEqual(try count(b,"chat_sources"),0);XCTAssertEqual(try count(b,"historical_evidence"),originals);XCTAssertEqual(try count(b,"personal_sync_versions"),versions)
            XCTAssertEqual(try count(b,"personal_sync_receipts"),receipts);XCTAssertEqual(try bc.journal.cursor(for:producerID),cursor);XCTAssertEqual(try bc.journal.outbox(),outbox);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
            guard case .projected=try publicationReceive(last,record,b,bc,ac,space) else {return XCTFail("Exact group retry must succeed")}
            XCTAssertFalse(try bc.journal.state(for:turn.key).isDeleted);XCTAssertEqual(try count(b,"chat_sources"),2)
        }
    }

    func testPublicationMissingDeclarationDoesNotBlockIndependentSenderProgressAndCanRetry()throws {
        try withPublication(citations:0) {a,ac,b,bc,space,ops in
            let turn=try XCTUnwrap(ops.first{$0.key.kind == .turn}),record=try packet(turn,ac)
            for op in ops {_=try publicationReceive(op,packet(op,ac),b,bc,ac,nil)}
            XCTAssertEqual(try count(b,"chat_turns"),0)
            _=try a.createChat(title:"Independent after withheld publication");try publicationDrain(a,ac,space)
            for op in try ac.journal.outbox(after:ops.last!.dot.counter) {_=try publicationReceive(op,packet(op,ac),b,bc,ac,space)}
            XCTAssertEqual(try b.chats().count,2);XCTAssertEqual(try bc.journal.cursor(for:producerID),try ac.journal.outbox().last?.dot.counter)
            let lease=try b.mediaWriteLease();defer {lease.release()}
            let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
            guard case .projected=try SyncIncomingTurnPublicationWriter(writer:writer).apply(record,admission:lease,fetchManifest:{try space.content($0)},fetchExactSource:{_ in throw OSwindError.invalid("Source-free answer cannot fetch evidence")}) else {return XCTFail("Explicit current-head retry must publish")}
            XCTAssertEqual(try count(b,"chat_turns"),1)
        }
    }

    func testPublicationReentrantHeadChangeDuringManifestLookupRollsBack()throws {
        try withPublication(citations:0) {_,ac,b,bc,space,ops in
            let turn=try XCTUnwrap(ops.first{$0.key.kind == .turn})
            for op in ops where op.dot.counter<turn.dot.counter {_=try publicationReceive(op,packet(op,ac),b,bc,ac,space)}
            let outbox=try bc.journal.outbox(),cursor=try bc.journal.cursor(for:producerID)
            XCTAssertThrowsError(try publicationReceive(turn,packet(turn,ac),b,bc,ac,space,manifest:{ref in
                _=try bc.journal.delete(key:turn.key);return try space.content(ref)
            }))
            XCTAssertEqual(try bc.journal.outbox(),outbox);XCTAssertEqual(try bc.journal.cursor(for:producerID),cursor);XCTAssertFalse(try bc.journal.state(for:turn.key).isDeleted);XCTAssertEqual(try count(b,"chat_turns"),0)
            guard case .projected=try publicationReceive(turn,packet(turn,ac),b,bc,ac,space) else {return XCTFail("Retry after rolled-back reentrant mutation must work")}
        }
    }

    func testPublicationWrongEpochWithCorrectContentHashIsRefusedAtomically()throws {
        try withPublication(citations:0) {_,ac,b,bc,space,ops in
            let turn=try XCTUnwrap(ops.first{$0.key.kind == .turn}),record=try packet(turn,ac)
            for op in ops where op.dot.counter<turn.dot.counter {_=try publicationReceive(op,packet(op,ac),b,bc,ac,space)}
            let wrong=try SyncTurnPublication(group:group,epoch:"00000000-0000-0000-0000-000000006198",owner:record.reference,citations:[])
            let altered=try SyncRevision(key:turn.key,dot:turn.dot,context:turn.context,mutation:.put,content:turn.content,publication:wrong.reference)
            XCTAssertThrowsError(try publicationReceive(altered,record,b,bc,ac,space,manifest:{_ in try wrong.encoded()}))
            XCTAssertTrue(try bc.journal.state(for:turn.key).heads.isEmpty);XCTAssertEqual(try count(b,"chat_turns"),0)
            guard case .projected=try publicationReceive(turn,record,b,bc,ac,space) else {return XCTFail("Trusted-context retry must work")}
        }
    }

    func testPublicationOutgoingRetentionFailureKeepsRetryableWorkWithoutAnswerRevision()throws {
        let (a,ac)=try endpoint("producer",producerID),space=try publicationSpace();defer {try? a.close();space.close()}
        let chat=try a.createChat(title:"Owned retention failure")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Retention?",answer:.init(text:"Retain before publishing",sources:[],provider:"owned",duration:0))
        var reachedSink=false
        let processor=SyncOutgoingProcessor(queue:try .install(catalog:ac.catalog),cache:ac,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []},retainTurnPublication:{_,_ in reachedSink=true;throw OSwindError.unavailable("Owned durable sink failure")})
        XCTAssertThrowsError(try {for _ in 0..<20 {_=try processor.step()}}())
        XCTAssertTrue(reachedSink);XCTAssertFalse(try ac.journal.outbox().contains{$0.key.kind == .turn});XCTAssertGreaterThan(try count(a,"personal_sync_work"),0)
        try publicationDrain(a,ac,space);let turn=try XCTUnwrap(ac.journal.outbox().first{$0.key.kind == .turn})
        XCTAssertNotNil(turn.publication);XCTAssertNotNil(try space.content(XCTUnwrap(turn.publication)))
    }

    func testPublicationOutgoingReentrantCitationChangeRollsBackBeforePublishing()throws {
        let (a,ac)=try endpoint("producer",producerID),space=try publicationSpace();defer {try? a.close();space.close()}
        let source=Memory(id:"original",timestamp:now,kind:.note,app:"Owned",text:"Owned exact original");try a.insert(source)
        let chat=try a.createChat(title:"Owned reentrant retention")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Snapshot?",answer:.init(text:"Owned snapshot",sources:[.init(memory:source,score:1,match:"original match")],provider:"owned",duration:0))
        var reachedSink=false
        let processor=SyncOutgoingProcessor(queue:try .install(catalog:ac.catalog),cache:ac,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []},retainTurnPublication:{ref,bytes in
            reachedSink=true;try space.publishContent(bytes,reference:ref)
            try a.withRoutineDatabase {try $0.execute("UPDATE chat_sources SET match='reentrant mismatch'")}
        })
        XCTAssertThrowsError(try {for _ in 0..<20 {_=try processor.step()}}())
        XCTAssertTrue(reachedSink);XCTAssertFalse(try ac.journal.outbox().contains{$0.key.kind == .turn});XCTAssertEqual(try a.chatTurns(chat.id).first?.answer.sources.first?.match,"original match")
        try publicationDrain(a,ac,space);XCTAssertEqual(try ac.journal.outbox().filter{$0.key.kind == .turn}.count,1)
    }

    func testPublicationPreparedLegacyOwnerUpgradeBindsExactExistingSnapshot()throws {
        let (a,ac)=try endpoint("producer",producerID),space=try publicationSpace();defer {try? a.close();space.close()}
        let chat=try a.createChat(title:"Legacy upgrade")
        _=try a.appendChatTurn(sessionID:chat.id,question:"Upgrade?",answer:.init(text:"Owned legacy body",sources:[],provider:"owned",duration:0));try drain(a,ac)
        let old=try XCTUnwrap(ac.journal.outbox().first{$0.key.kind == .turn}),packet=try packet(old,ac)
        let (revision,declaration)=try SyncTurnPublication.publish(owner:packet.identity,cache:ac,admit:{_ in},retainManifest:{try space.publishContent($1,reference:$0)})
        XCTAssertEqual(revision.content,old.content);XCTAssertEqual(revision.publication,try declaration.reference);XCTAssertEqual(declaration.owner,try packet.reference);XCTAssertGreaterThan(revision.dot.counter,old.dot.counter);XCTAssertEqual(declaration.citations.count,0)
    }

    func testPublicationReplacementCannotLeaveExcludedNativeCitationsOnNewBody()throws {
        try withPublication {_,ac,b,bc,space,ops in
            for op in ops {_=try publicationReceive(op,packet(op,ac),b,bc,ac,space)}
            let prior=try packet(XCTUnwrap(ops.first{$0.key.kind == .turn}),ac)
            guard case .turn(let old)=prior.body else {return XCTFail("Owned prior body missing")}
            // Authored protocol replacement fixture; the public app does not
            // expose editing stored answer bodies or removing their citations.
            let replacement=try SyncPortableRecord(identity:prior.identity,body:.turn(.init(conversation:old.conversation,timestamp:old.timestamp,question:old.question,text:"New body must not inherit old citations",provider:old.provider,duration:old.duration,warnings:old.warnings,filter:old.filter,timeZone:old.timeZone)))
            let declaration=try SyncTurnPublication(group:group,epoch:epoch,owner:replacement.reference,citations:[])
            try space.publishContent(declaration.encoded(),reference:declaration.reference)
            let revision=try ac.journal.put(key:replacement.identity.key,content:replacement.reference.content,publication:declaration.reference)
            XCTAssertEqual(try publicationReceive(revision,replacement,b,bc,ac,space),.withheld(.replacementRequiresReview))
            let chat="peer-"+(try old.conversation.key.digest),visible=try XCTUnwrap(b.chatTurns(chat).first)
            XCTAssertEqual(visible.answer.text,old.text);XCTAssertEqual(visible.answer.sources.count,2);XCTAssertEqual(try count(b,"chat_sources"),2);XCTAssertEqual(try bc.journal.outbox().count,0)
        }
    }

    func testPublicationChangedCitationHeadCannotSatisfyExactDeclaration()throws {
        try withPublication(citations:1) {_,ac,b,bc,space,ops in
            let target=try XCTUnwrap(ops.first{$0.key.kind == .conversationCitation}),owner=try packet(XCTUnwrap(ops.first{$0.key.kind == .turn}),ac),original=try packet(target,ac)
            for op in ops where op.dot.counter<target.dot.counter {_=try publicationReceive(op,packet(op,ac),b,bc,ac,space)}
            guard case .conversationCitation(let body)=original.body else {return XCTFail("Owned citation missing")}
            let altered=try SyncPortableRecord(identity:original.identity,body:.conversationCitation(.init(owner:body.owner,ordinal:body.ordinal,link:.init(source:body.link.source,score:body.link.score,match:"Changed exact version",passage:body.link.passage))))
            let revision=try SyncRevision(key:target.key,dot:target.dot,context:target.context,mutation:.put,content:altered.reference.content)
            XCTAssertEqual(try publicationReceive(revision,altered,b,bc,ac,space),.withheld(.unlistedCitation))
            let lease=try b.mediaWriteLease();defer {lease.release()}
            let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in XCTFail("No mismatching body admission")},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
            XCTAssertEqual(try SyncIncomingTurnPublicationWriter(writer:writer).apply(owner,admission:lease,fetchManifest:{try space.content($0)},fetchExactSource:{_ in throw OSwindError.invalid("No mismatching evidence fetch")}),.withheld(.changedCitation))
            XCTAssertEqual(try count(b,"chat_turns"),0);XCTAssertEqual(try count(b,"chat_sources"),0);XCTAssertFalse(try bc.journal.state(for:owner.identity.key).isDeleted)
        }
    }
}
