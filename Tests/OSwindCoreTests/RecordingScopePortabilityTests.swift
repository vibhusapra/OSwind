import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private func scopedAudio(_ id:String,session:String?)->Memory {
        var m=Memory(id:id,timestamp:now,kind:.audio,app:"Owned scoped audio",title:"Same recording title",text:"Mira owns Apollo")
        m.audioSessionID=session;m.transcript = .init(text:m.text,duration:30,segments:[.init(start:0,end:30,text:m.text)],model:"Authored fixture");return m
    }
    private func deliverScoped(_ producer:SyncVersionStore,_ receiver:MemoryStore,_ cache:SyncVersionStore,after:Int64=0)throws {
        for operation in try producer.journal.outbox(after:after) {
            let record=try packet(operation,producer)
            _=try receive(operation,record,receiver,cache,fetch:{ref in try XCTUnwrap(producer.record(ref,admit:{_ in}))})
        }
    }
    func testRecordingSessionScopeSurvivesIncomingOriginRemappingAndReexport()throws {
        let (a,ac)=try endpoint("scope-producer",producerID),(b,bc)=try endpoint("scope-receiver",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        try b.insert(scopedAudio("local-same-id",session:"session"));try drain(b,bc)
        let first=scopedAudio("first",session:"session");try a.insert(first);try a.insert(scopedAudio("second",session:"session"));try a.insert(scopedAudio("neighbor",session:"other"));try drain(a,ac)
        try deliverScoped(ac,b,bc);let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        let turn=try a.saveChatTurn(question:"Who owns Apollo?",answer:.init(text:"Mira [1]",sources:[.init(memory:first,score:1,match:"owned")],provider:"evidence",duration:0),filter:.init(recordingScope:try .init(sessionID:"session")))
        try drain(a,ac);try deliverScoped(ac,b,bc,after:through)
        let session=try XCTUnwrap(b.chats().first),received=try XCTUnwrap(b.chatTurns(session.id).first),scope=try XCTUnwrap(received.filter.recordingScope)
        XCTAssertEqual(scope.selector,.session);XCTAssertNotEqual(scope.id,"session")
        let hits=try b.search(.init(recordingScope:scope),mode:.keyword)
        XCTAssertEqual(hits.count,2);XCTAssertFalse(hits.contains {$0.id=="local-same-id"});XCTAssertTrue(hits.allSatisfy {$0.memory.audioSessionID==scope.id})
        try drain(b,bc);let exported=try XCTUnwrap(ac.journal.outbox().first {$0.key.kind == .turn}),original=try packet(exported,ac)
        XCTAssertEqual(try bc.record(original.reference,admit:{_ in})?.encoded(),try original.encoded())
        XCTAssertEqual(try a.chatTurns(turn.sessionID).first?.filter.recordingScope?.id,"session")
    }
    func testSingleRecordingVersionScopeSurvivesExactIncomingProjection()throws {
        let (a,ac)=try endpoint("clip-producer",producerID),(b,bc)=try endpoint("clip-receiver",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let source=scopedAudio("legacy",session:nil);try a.insert(source);try a.insert(scopedAudio("neighbor",session:nil));try drain(a,ac);try deliverScoped(ac,b,bc)
        let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        _=try a.saveChatTurn(question:"Who?",answer:.init(text:"Mira [1]",sources:[.init(memory:source,score:1,match:"owned")],provider:"evidence",duration:0),filter:.init(recordingScope:try .init(sourceID:source.id,revision:source.evidenceHash)))
        try drain(a,ac);try deliverScoped(ac,b,bc,after:through)
        let chat=try XCTUnwrap(b.chats().first),turn=try XCTUnwrap(b.chatTurns(chat.id).first),scope=try XCTUnwrap(turn.filter.recordingScope)
        let hits=try b.search(.init(recordingScope:scope),mode:.keyword)
        XCTAssertEqual(hits.count,1);XCTAssertEqual(hits.first?.id,scope.id);XCTAssertNotEqual(scope.id,"legacy");XCTAssertEqual(hits.first?.memory.evidenceHash,scope.revision)
        try drain(b,bc)
    }
    func testRecordingScopedRunPreservesQuietRestoreAndRefusesLostSessionProvenance()throws {
        for single in [false,true] {
            let suffix=single ? "single":"session"
            let (a,ac)=try endpoint("run-producer-"+suffix,producerID),(b,bc)=try endpoint("run-receiver-"+suffix,receiverID)
            defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
            let source=scopedAudio("recorded",session:single ? nil:"selected")
            try a.insert(source);try a.insert(scopedAudio("neighbor",session:single ? nil:"other"))
            var recipe=RoutineDefinition();recipe.id="scoped-run";recipe.schedule.timeZone="UTC"
            _=try a.saveRoutine(recipe,now:now);let claim=try XCTUnwrap(a.claimRoutine(id:recipe.id,now:now))
            let scope:RecordingScope=try single ? .init(sourceID:source.id,revision:source.evidenceHash):.init(sessionID:"selected")
            // Exercise the generic retained-run filter adapter directly. The
            // routine editor does not offer recording-scoped schedules yet.
            var captured=claim.run.filter;captured.recordingScope=scope
            try a.withRoutineDatabase {db in let row=try db.statement("UPDATE routine_runs SET scope=? WHERE id=?");defer {sqlite3_finalize(row)};try db.bind(row,1,json:captured);db.bind(row,2,claim.run.id);try db.done(row)}
            try drain(a,ac);try deliverScoped(ac,b,bc)
            let run=try XCTUnwrap(b.routineRuns().first),received=try XCTUnwrap(run.filter.recordingScope)
            XCTAssertEqual(try b.search(.init(recordingScope:received),mode:.keyword).count,1)
            struct OlderWireFilter:Decodable {let kind:MemoryKind?}
            let operation=try XCTUnwrap(ac.journal.outbox().first {$0.key.kind == .routineRun}),original=try packet(operation,ac)
            guard case .routineRun(let body)=original.body else {return XCTFail("Expected authored run")}
            XCTAssertThrowsError(try JSONDecoder().decode(OlderWireFilter.self,from:JSONEncoder().encode(body.filter)))
            let archive=root.appendingPathComponent("scope-run-"+suffix+".oswindbackup"),destination=root.appendingPathComponent("restored-scope-run-"+suffix)
            _=try LibraryBackup.create(store:b,destination:archive);_=try LibraryBackup.restore(archive,to:destination)
            let restored=try MemoryStore(root:destination);defer {try? restored.close()}
            let retained=try XCTUnwrap(restored.routineRuns().first?.filter.recordingScope)
            XCTAssertEqual(retained,received);XCTAssertEqual(try restored.search(.init(recordingScope:retained),mode:.keyword).count,1)
            let fresh=try restored.withRoutineDatabase {db in
                _=try SyncChangeCapture.activate(db);let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:"00000000-0000-0000-0000-000000006109",group:group,epoch:epoch)
                return try SyncVersionStore.install(catalog:catalog,journal:journal)
            }
            if !single {
                XCTAssertThrowsError(try drain(restored,fresh)) {error in
                    XCTAssertTrue(error.localizedDescription.contains("Original sync session binding is unavailable"),"Expected explicit original-provenance refusal: \(error)")
                }
                XCTAssertEqual(try restored.routineRuns().first?.filter.recordingScope,retained)
                continue
            }
            try drain(restored,fresh)
            let forwardedOperation=try XCTUnwrap(fresh.journal.outbox().first {$0.key.kind == .routineRun}),forwarded=try packet(forwardedOperation,fresh)
            XCTAssertEqual(try fresh.resolve(forwarded.identity,content:nil,admit:{_ in}).encoded(),try forwarded.encoded())
            let localRun=try XCTUnwrap(restored.routineRuns().first);XCTAssertEqual(localRun.filter.recordingScope,retained)
        }
    }
}

