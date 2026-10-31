import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testIncomingRecipeUsesDisabledLocalConfigurationWithoutExecutionOrEcho()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="owned-incoming-recipe";recipe.title="Owned peer recipe";recipe.prompt="Summarize recorded evidence with citations";recipe.enabled=true;recipe.allowRemote=true;recipe.ai.provider = .compatible;recipe.ai.model="OWNED-PRIVATE-MODEL";recipe.ai.endpoint="https://owned-private-provider.example.test/v1";recipe.ai.allowRemote=true;recipe.schedule.timeZone="UTC"
        _=try a.saveRoutine(recipe,now:now);try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().first),record=try packet(operation,ac),before=try bc.journal.outbox()
        XCTAssertFalse(String(decoding:try record.encoded(),as:UTF8.self).contains("OWNED-PRIVATE-MODEL"));XCTAssertFalse(String(decoding:try record.encoded(),as:UTF8.self).contains("owned-private-provider"))
        let local=try receive(operation,record,b,bc,fetch:{_ in throw OSwindError.invalid("Recipe has no source dependencies")}),stored=try XCTUnwrap(b.routines().first)
        guard case .routine(let body)=record.body else {return XCTFail("No recipe body")}
        XCTAssertEqual(stored.definition,try body.projected(id:local));XCTAssertFalse(stored.definition.enabled);XCTAssertFalse(stored.definition.allowRemote);XCTAssertFalse(stored.definition.ai.allowRemote)
        XCTAssertNil(try b.claimRoutine(now:now.addingTimeInterval(86400*20)));XCTAssertEqual(try count(b,"routine_runs"),0);XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertEqual(try bc.journal.outbox(),before)
        XCTAssertEqual(try bc.resolve(record.identity,content:nil,admit:{_ in}).encoded(),try record.encoded())
    }
    func testIncomingRunKeepsOriginalRecipeAndSafeInterruptedStatusAcrossRecipeUpdate()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="owned-run-recipe";recipe.title="Original run recipe";recipe.prompt="Original recorded prompt";recipe.schedule.timeZone="UTC"
        let first=try a.saveRoutine(recipe,now:now),claim=try XCTUnwrap(a.claimRoutine(id:recipe.id,now:now));try drain(a,ac)
        var receivedRecipe="",receivedRun="",oldRun:SyncPortableRecord?
        for operation in try ac.journal.outbox() {
            let record=try packet(operation,ac),local=try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if case .routine=record.body {receivedRecipe=local}
            if case .routineRun=record.body {receivedRun=local;oldRun=record}
        }
        let original=try XCTUnwrap(oldRun);guard case .routineRun(let body)=original.body else {return XCTFail("No run body")}
        let run=try XCTUnwrap(b.routineRuns().first)
        XCTAssertEqual(run.id,receivedRun);XCTAssertEqual(run.routineID,receivedRecipe);XCTAssertEqual(run.status,.interrupted);XCTAssertNil(run.finished)
        XCTAssertEqual(body.status,.running);XCTAssertEqual(try bc.resolve(original.identity,content:nil,admit:{_ in}).encoded(),try original.encoded())
        let outbox=try bc.journal.outbox(),through=try ac.journal.outbox().last!.dot.counter
        recipe.prompt="New current prompt";_=try a.saveRoutine(recipe,expectedRevision:first.revision,now:now.addingTimeInterval(1));_=try a.finishRoutine(claim.run.id,status:.failed,message:"Peer finished after editing recipe");try drain(a,ac)
        for operation in try ac.journal.outbox(after:through) {
            let record=try packet(operation,ac);_=try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        }
        XCTAssertEqual(try b.routines().first?.definition.prompt,recipe.prompt);XCTAssertEqual(try b.routineRuns().first?.status,.failed)
        let attribution=try XCTUnwrap(b.routineRuns().first?.original)
        XCTAssertEqual(attribution.recipePrompt,"Original recorded prompt");XCTAssertEqual(attribution.recipeTitle,"Original run recipe");XCTAssertEqual(attribution.recipeOrdinal,1);XCTAssertEqual(attribution.recordedStatus,.failed)
        let latest=try bc.resolve(original.identity,content:nil,admit:{_ in});guard case .routineRun(let changed)=latest.body else {return XCTFail("No updated run")}
        XCTAssertEqual(changed.recipe,body.recipe);XCTAssertEqual(changed.status,.failed);XCTAssertEqual(try bc.record(original.reference,admit:{_ in})?.encoded(),try original.encoded())
        XCTAssertEqual(try bc.journal.outbox(),outbox);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }
    func testIncomingRecipeEditPreservesExactHistoricalDefinitionAndResetsLocalActivation()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="recipe";recipe.prompt="Original prompt";recipe.schedule.timeZone="UTC";let first=try a.saveRoutine(recipe,now:now);try drain(a,ac)
        let op=try XCTUnwrap(ac.journal.outbox().first),old=try packet(op,ac),local=try receive(op,old,b,bc,fetch:{_ in old})
        recipe.prompt="Updated prompt";_=try a.saveRoutine(recipe,expectedRevision:first.revision,now:now);try drain(a,ac)
        let next=try XCTUnwrap(ac.journal.outbox().last),new=try packet(next,ac);XCTAssertEqual(try receive(next,new,b,bc,fetch:{_ in old}),local)
        let native=try XCTUnwrap(b.routines().first);XCTAssertEqual(native.definition.prompt,recipe.prompt);XCTAssertEqual(native.revision,2);XCTAssertFalse(native.definition.enabled)
        XCTAssertEqual(try bc.record(old.reference,admit:{_ in})?.encoded(),try old.encoded());XCTAssertEqual(try bc.resolve(new.identity,content:nil,admit:{_ in}).encoded(),try new.encoded())
        XCTAssertEqual(try bc.recipeVersion(localID:local,ordinal:1,admit:{_ in}).definition,try old.reference.content);XCTAssertEqual(try bc.recipeVersion(localID:local,ordinal:2,admit:{_ in}).definition,try new.reference.content)
        XCTAssertTrue(try bc.journal.outbox().isEmpty);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }
    func testIncomingRecipeCannotGainSQLActivationInsideLateAdmission()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="recipe";recipe.schedule.timeZone="UTC";_=try a.saveRoutine(recipe,now:now);try drain(a,ac)
        let op=try XCTUnwrap(ac.journal.outbox().first),record=try packet(op,ac),lease=try b.mediaWriteLease();defer {lease.release()};var mutated=false
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{packet in
            if !mutated,packet.identity==record.identity,let object=try bc.catalog.object(record.identity),let primary=object.primary,case .text(let bytes)=primary[0],let local=String(data:bytes,encoding:.utf8) {
                mutated=true;try b.withRoutineDatabase {db in let row=try db.statement("UPDATE routines SET enabled=1 WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,local);try db.done(row)}
            }
        },pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        XCTAssertThrowsError(try bc.journal.receive(op,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:lease,fetchExactSource:{_ in record})})
        XCTAssertTrue(mutated);XCTAssertTrue(try b.routines().isEmpty);XCTAssertNil(try bc.catalog.object(record.identity));XCTAssertTrue(try bc.journal.state(for:record.identity.key).heads.isEmpty)
        XCTAssertEqual(try count(b,"personal_sync_versions"),0);XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
        _=try receive(op,record,b,bc,fetch:{_ in record});XCTAssertFalse(try XCTUnwrap(b.routines().first).definition.enabled)
    }

    private func importedRun()throws->(MemoryStore,SyncVersionStore,MemoryStore,SyncVersionStore,String,SyncPortableRecord) {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);try bc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="original-recipe";recipe.title="Recorded original title";recipe.prompt="Recorded original prompt";recipe.schedule.timeZone="UTC"
        _=try a.saveRoutine(recipe,now:now);_=try a.claimRoutine(id:recipe.id,now:now);try drain(a,ac)
        var local="",original:SyncPortableRecord?
        for operation in try ac.journal.outbox() {let packet=try self.packet(operation,ac),id=try receive(operation,packet,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))});if case .routineRun=packet.body {local=id;original=packet}}
        return(a,ac,b,bc,local,try XCTUnwrap(original))
    }
    func testIncomingRunOriginalSurvivesRestartAndQuietBackupRestore()throws {
        let (a,_,b,_,local,original)=try importedRun();defer {try? a.close();try? b.close()}
        let before=try b.routineRuns();XCTAssertEqual(before.first?.original?.recordedStatus,.running);XCTAssertEqual(before.first?.original?.recipePrompt,"Recorded original prompt")
        let destination=b.root;try b.close();let reopened=try MemoryStore(root:destination);defer {try? reopened.close()}
        XCTAssertEqual(try SyncProtocolLimits.encode(reopened.routineRuns()),try SyncProtocolLimits.encode(before))
        let archive=root.appendingPathComponent("originals.oswindbackup"),restored=root.appendingPathComponent("restored")
        var settings=AppSettings();settings.routinesEnabled=true;try settings.save(root:destination)
        _=try LibraryBackup.create(store:reopened,destination:archive);_=try LibraryBackup.inspect(archive);_=try LibraryBackup.restore(archive,to:restored)
        let target=try MemoryStore(root:restored);defer {try? target.close()}
        XCTAssertEqual(try SyncProtocolLimits.encode(target.routineRuns()),try SyncProtocolLimits.encode(before));XCTAssertFalse(AppSettings.load(root:restored).routinesEnabled)
        XCTAssertEqual(try target.withRoutineDatabase {try RoutineRunOriginalStore(db:$0).read(local)?.record.encoded()},try original.encoded())
        XCTAssertNil(try target.claimRoutine(now:now.addingTimeInterval(86400*20)));XCTAssertEqual(try count(target,"personal_sync_changes"),0)
        let fresh=try target.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:"00000000-0000-0000-0000-000000006109",group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        }
        try drain(target,fresh)
        let runOperation=try XCTUnwrap(fresh.journal.outbox().first {$0.key.kind == .routineRun}),forwarded=try packet(runOperation,fresh)
        guard case .routineRun(let body)=forwarded.body,case .routineRun(let old)=original.body else {return XCTFail("No forwarded run")}
        XCTAssertNotEqual(forwarded.identity,original.identity);XCTAssertEqual(body.status,.running);XCTAssertEqual(body.recipe.editorOrigin,old.recipe.editorOrigin);XCTAssertEqual(body.recipe.ordinal,old.recipe.ordinal);XCTAssertNil(body.recipe.definition)
        XCTAssertEqual(try fresh.resolve(forwarded.identity,content:nil,admit:{_ in}).encoded(),try forwarded.encoded())
        XCTAssertEqual(try target.routineRuns().first?.original?.recipePrompt,"Recorded original prompt")
        try target.deleteAll();XCTAssertEqual(try count(target,"routine_run_originals"),0)
    }
    func testIncomingRunOriginalCannotBeChangedOrDroppedWithoutNativeMutation()throws {
        let (a,_,b,bc,local,original)=try importedRun();defer {try? a.close();try? b.close()}
        try b.withRoutineDatabase {db in
            XCTAssertThrowsError(try db.execute("DELETE FROM routine_run_originals"));XCTAssertThrowsError(try db.execute("UPDATE routine_run_originals SET native_sha=printf('%064d',0)"))
            XCTAssertThrowsError(try db.execute("INSERT INTO routine_run_originals SELECT 'forged',payload,native_sha FROM routine_run_originals"))
            XCTAssertEqual(try RoutineRunOriginalStore(db:db).read(local)?.record.encoded(),try original.encoded())
        }
        XCTAssertEqual(try bc.resolve(original.identity,content:nil,admit:{_ in}).encoded(),try original.encoded())
    }
    func testIncomingRunOrdinaryMutationClearsOriginalAndCachedWireVersions()throws {
        let (a,_,b,bc,local,original)=try importedRun();defer {try? a.close();try? b.close()}
        try b.withRoutineDatabase {db in let row=try db.statement("UPDATE routine_runs SET message='Local correction' WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,local);try db.done(row)}
        XCTAssertNil(try b.routineRuns().first?.original);XCTAssertEqual(try count(b,"routine_run_originals"),0)
        XCTAssertNil(try bc.record(original.reference,admit:{_ in}));XCTAssertThrowsError(try bc.resolve(original.identity,content:nil,admit:{_ in}))
        XCTAssertEqual(try count(b,"personal_sync_changes"),1)
    }
    func testIncomingRunLateNativeMutationRollsBackOriginalAndJournalTogether()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="recipe";recipe.schedule.timeZone="UTC";_=try a.saveRoutine(recipe,now:now);_=try a.claimRoutine(id:recipe.id,now:now);try drain(a,ac)
        let operations=try ac.journal.outbox(),recipeOp=try XCTUnwrap(operations.first),runOp=try XCTUnwrap(operations.last)
        _=try receive(recipeOp,packet(recipeOp,ac),b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        let record=try packet(runOp,ac),lease=try b.mediaWriteLease();defer {lease.release()};var mutated=false
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{packet in
            if !mutated,packet.identity==record.identity,try self.count(b,"routine_run_originals")==1 {
                mutated=true;try b.withRoutineDatabase {try $0.execute("UPDATE routine_runs SET status='completed',message='Late changed status'")}
            }
        },pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        XCTAssertThrowsError(try bc.journal.receive(runOp,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})})
        XCTAssertTrue(mutated);XCTAssertTrue(try b.routineRuns().isEmpty);XCTAssertEqual(try count(b,"routine_run_originals"),0);XCTAssertNil(try bc.catalog.object(record.identity));XCTAssertTrue(try bc.journal.state(for:record.identity.key).heads.isEmpty)
        _=try receive(runOp,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))});XCTAssertEqual(try b.routineRuns().first?.original?.recordedStatus,.running)
    }

    func testIncomingRunAuthoredBootstrapFetchesExactOldRecipeWithNewerCurrentDefinition()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var recipe=RoutineDefinition();recipe.id="recipe";recipe.prompt="Original recipe before run";recipe.schedule.timeZone="UTC"
        let first=try a.saveRoutine(recipe,now:now);_=try a.claimRoutine(id:recipe.id,now:now);try drain(a,ac)
        let initial=try ac.journal.outbox(),oldRecipe=try packet(XCTUnwrap(initial.first),ac),runOp=try XCTUnwrap(initial.last),run=try packet(runOp,ac)
        recipe.prompt="New current recipe without old prompt";_=try a.saveRoutine(recipe,expectedRevision:first.revision,now:now);try drain(a,ac)
        let newest=try XCTUnwrap(ac.journal.outbox().last)
        // Authored valid snapshot journal, using actual producer packet bytes.
        // This tests the adapter's exact fetch; transport/bootstrap remains open.
        let current=try packet(newest,ac),snapshotRecipe=try SyncRevision(key:current.identity.key,dot:.init(replica:producerID,counter:1),context:.empty,mutation:.put,content:current.reference.content)
        let snapshotRun=try SyncRevision(key:run.identity.key,dot:.init(replica:producerID,counter:2),context:snapshotRecipe.clock,mutation:.put,content:run.reference.content)
        _=try receive(snapshotRecipe,current,b,bc,fetch:{_ in throw OSwindError.invalid("Recipe has no dependencies")})
        var fetched=[SyncVersionReference]()
        _=try receive(snapshotRun,run,b,bc,fetch:{ref in fetched.append(ref);return try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        XCTAssertEqual(fetched,[try oldRecipe.reference]);XCTAssertEqual(try b.routines().first?.definition.prompt,recipe.prompt)
        XCTAssertEqual(try b.routineRuns().first?.original?.recipePrompt,"Original recipe before run");XCTAssertEqual(try b.routineRuns().first?.original?.recipeOrdinal,1)
        XCTAssertEqual(try bc.resolve(run.identity,content:nil,admit:{_ in}).encoded(),try run.encoded());XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }
    func testIncomingRunPermitIsExactConnectionScopedAndClearsAfterThrow()throws {
        let (a,_,b,_,local,_)=try importedRun();defer {try? a.close();try? b.close()}
        try b.withRoutineDatabase {db in
            let store=RoutineRunOriginalStore(db:db),frame=try XCTUnwrap(store.frame(local)),payload=try XCTUnwrap(store.read(local)).encoded()
            func allowed(_ connection:RoutineDatabase)throws->Int64 {
                let row=try connection.statement("SELECT oswind_incoming_run_projection_v1(?)");defer {sqlite3_finalize(row)};let bytes=try frame.encoded();bytes.withUnsafeBytes {_=sqlite3_bind_blob(row,1,$0.baseAddress,Int32(bytes.count),connection.transient)};guard sqlite3_step(row)==SQLITE_ROW else {throw connection.error()};return sqlite3_column_int64(row,0)
            }
            XCTAssertEqual(try allowed(db),0)
            XCTAssertThrowsError(try b.incomingRunProjection.withRun(frame,payload:payload) {
                XCTAssertEqual(try allowed(db),1)
                try a.withRoutineDatabase {other in XCTAssertEqual(try allowed(other),0)}
                throw OSwindError.invalid("Owned forced throw")
            })
            XCTAssertEqual(try allowed(db),0)
            let functions=try db.statement("SELECT name,flags FROM pragma_function_list WHERE name IN ('oswind_incoming_run_projection_v1','oswind_incoming_run_original_v1')");defer {sqlite3_finalize(functions)};var count=0
            while sqlite3_step(functions)==SQLITE_ROW {count+=1;XCTAssertEqual(sqlite3_column_int(functions,1)&SQLITE_DETERMINISTIC,0)}
            XCTAssertEqual(count,2)
        }
    }

}
