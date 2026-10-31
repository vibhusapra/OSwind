import XCTest
import CSQLite
@testable import OSwindCore

final class SyncVersionStoreTests:XCTestCase {
    let replica="00000000-0000-0000-0000-000000000701",group="00000000-0000-0000-0000-000000000702",epoch="00000000-0000-0000-0000-000000000703"
    var root:URL!,store:MemoryStore!,catalog:SyncIdentityCatalog!,journal:SyncJournal!,cache:SyncVersionStore!
    var ids=[String:SyncObjectIdentity]()
    let now=Date(timeIntervalSince1970:1_792_700_000)
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-sync-versions-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store.close();store=nil;try FileManager.default.removeItem(at:root)}
    func seed(_ id:String="owned-source",text:String="Alice owns Orion.")throws {try store.insert(Memory(id:id,timestamp:now,kind:.note,app:"Owned",title:"Owned source",text:text))}
    func install(budget:Int64=SyncVersionStore.defaultBudget)throws {
        try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);catalog=try SyncIdentityCatalog.install(db);journal=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch);cache=try SyncVersionStore.install(catalog:catalog,journal:journal,budget:budget)
        }
    }
    func identity(_ table:SyncCanonicalTable,_ primary:[SyncRowCell])throws->SyncObjectIdentity {
        let key=table.rawValue+SyncProtocolLimits.hex(try SyncIdentityCatalog.keyFrame(table,primary))
        if let id=ids[key] {return id};let id=try catalog.registerExisting(table,primary:primary);ids[key]=id;return id
    }
    func identity(_ table:SyncCanonicalTable,_ id:String)throws->SyncObjectIdentity {try identity(table,[.text(Data(id.utf8))])}
    var references:SyncPortableReferences {.init(identity:{try self.identity($0,$1)},source:{try self.cache.sourceVersion(localID:$0,revision:$1,admit:{_ in})},media:{_ in []},recipe:{try self.cache.recipeVersion(localID:$0,ordinal:$1,admit:{_ in})},session:{try self.cache.sessionBinding(localID:$0.id,admit:{_ in})},runRecipe:{try self.cache.runRecipe(localRunID:$0,recipeID:$1,ordinal:$2,admit:{_ in})})}
    func rows(_ table:SyncCanonicalTable)throws->[SyncRowSnapshot] {
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT "+table.schema.snapshot("t")+" FROM "+table.rawValue+" t ORDER BY "+table.schema.primary.joined(separator:","));defer {sqlite3_finalize(row)}
            var result=[SyncRowSnapshot](),status=sqlite3_step(row)
            while status==SQLITE_ROW {let n=Int(sqlite3_column_bytes(row,0));guard let p=sqlite3_column_blob(row,0) else {throw db.error()};result.append(try .decode(Data(bytes:p,count:n)));status=sqlite3_step(row)}
            guard status==SQLITE_DONE else {throw db.error()};return result
        }
    }
    func make(_ table:SyncCanonicalTable,_ row:SyncRowSnapshot)throws->SyncPortableRecord {
        let primary=table.schema.primary.map {row.cells[table.schema.columns.firstIndex(of:$0)!]}
        return try SyncPortableExporter(references:references).record(identity:identity(table,primary),row:row)
    }
    @discardableResult func prepare(_ record:SyncPortableRecord,bind:Bool=true)throws->SyncVersionReference {
        let ref=try record.reference
        _=try journal.put(key:record.identity.key,content:ref.content) {_ in
            _=try self.cache.retain(record,admit:{_ in});if bind {try self.cache.bindProjection(ref,references:self.references,admit:{_ in})}
        };return ref
    }
    func source(_ id:String="owned-source")throws->SyncPortableRecord {
        let row=try XCTUnwrap(rows(.source).first {if case .text(let bytes)=$0.cells[0] {return bytes==Data(id.utf8)};return false});return try make(.source,row)
    }
    func count(_ table:String)throws->Int {try store.withRoutineDatabase {db in let row=try db.statement("SELECT COUNT(*) FROM "+table);defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return Int(sqlite3_column_int(row,0))}}
    func drain()throws {_=try catalog.process {_ in}}
    func testOrdinaryLibraryDoesNotInstallOrEnableVersionStore()throws {
        try store.withRoutineDatabase {db in let row=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'personal_sync_version%'");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),0)}
        XCTAssertEqual(MemoryStore.schemaVersion,25)
    }
    func testDurableExactSourceBindingSurvivesReopenWithoutChangingOriginalFrames()throws {
        try seed();try install();let before=try rows(.source).map {try $0.encoded()},record=try source(),ref=try prepare(record),memory=try XCTUnwrap(store.get("owned-source"))
        XCTAssertEqual(try cache.sourceVersion(localID:memory.id,revision:.evidence(memory.evidenceHash),admit:{_ in}),ref)
        XCTAssertThrowsError(try cache.sourceVersion(localID:memory.id,revision:.entity(memory.evidenceHash),admit:{_ in}))
        try store.close();store=try MemoryStore(root:root);try install()
        XCTAssertEqual(try cache.record(ref,admit:{_ in}),record);XCTAssertEqual(try cache.resolve(record.identity,content:nil,admit:{_ in}),record)
        XCTAssertEqual(try rows(.source).map {try $0.encoded()},before)
    }
    func testMissingImmutableVersionCannotFallBackToCurrentProjection()throws {
        try seed();try install();let record=try source();_=try prepare(record)
        let wrong=try SyncVersionReference(identity:record.identity,content:.init(data:Data("unavailable".utf8)))
        XCTAssertNil(try cache.record(wrong,admit:{_ in}));XCTAssertThrowsError(try cache.resolve(record.identity,content:wrong.content,admit:{_ in}))
        XCTAssertEqual(try cache.resolve(record.identity,content:nil,admit:{_ in}),record)
    }
    func testPolicyIsCheckedOnEveryCacheReadAndDuplicateRetention()throws {
        try seed();try install();let record=try source(),ref=try prepare(record);var calls=0
        XCTAssertThrowsError(try cache.record(ref) {_ in calls+=1;throw OSwindError.invalid("Owned denied current policy")})
        XCTAssertThrowsError(try cache.retain(record) {_ in calls+=1;throw OSwindError.invalid("Owned denied current policy")})
        XCTAssertEqual(calls,2);XCTAssertEqual(try count("personal_sync_versions"),1)
    }
    func testUnadmittedRecordAndUnmappedIdentityCannotEnterCache()throws {
        try seed();try install();let record=try source()
        XCTAssertThrowsError(try cache.retain(record,admit:{_ in}));XCTAssertEqual(try count("personal_sync_versions"),0)
        let other=try SyncPortableRecord(identity:.init(table:.source,origin:replica,lifetime:UUID().uuidString.lowercased()),body:record.body)
        XCTAssertThrowsError(try journal.put(key:other.identity.key,content:other.reference.content) {_ in _=try self.cache.retain(other,admit:{_ in})})
        XCTAssertEqual(try journal.outbox().count,0)
    }
    func testProjectionMustMatchTheActualTypedLocalRow()throws {
        try seed();try install();let record=try source();_=try prepare(record,bind:false)
        let different=try SyncPortableRecord(identity:record.identity,body:.source(.init(memory:Memory(id:"owned-source",timestamp:now,kind:.note,text:"unrelated"),origin:replica,media:[]) {_,_ in throw OSwindError.invalid("No recap")}))
        let ref=try prepare(different,bind:false)
        XCTAssertThrowsError(try cache.bindProjection(ref,references:references,admit:{_ in}));XCTAssertThrowsError(try cache.resolve(record.identity,content:nil,admit:{_ in}))
        XCTAssertEqual(try store.get("owned-source")?.text,"Alice owns Orion.")
    }
    func testOuterRollbackRemovesBodyProjectionJournalAndCursorTogether()throws {
        try seed();try install();let record=try source()
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {_=try self.prepare(record);throw OSwindError.invalid("Owned transaction failure")}})
        XCTAssertEqual(try count("personal_sync_versions"),0);XCTAssertEqual(try count("personal_sync_version_projection"),0);XCTAssertTrue(try journal.outbox().isEmpty);XCTAssertEqual(try journal.cursor(for:replica),0)
    }
    func testLogicalBudgetRefusalRollsBackTheJournalHeadAndBody()throws {
        try seed();try install(budget:128);let record=try source()
        XCTAssertThrowsError(try prepare(record));XCTAssertEqual(try count("personal_sync_versions"),0);XCTAssertTrue(try journal.outbox().isEmpty)
    }
    func testSourceDeletionPurgesBodiesBindingsAndRejectsLateOldHeadBeforeProcessorRuns()throws {
        try seed();try install();let record=try source(),ref=try prepare(record)
        _=try store.delete("owned-source")
        XCTAssertEqual(try count("personal_sync_versions"),0);XCTAssertEqual(try count("personal_sync_version_projection"),0)
        XCTAssertThrowsError(try cache.record(ref,admit:{_ in}));XCTAssertThrowsError(try cache.retain(record,admit:{_ in}))
        XCTAssertEqual(try count("personal_sync_version_revoked"),1)
    }
    func testSamePrimaryKeyRestorationUsesFreshLifetimeAndCannotReadOldBody()throws {
        try seed();try install();let old=try source(),oldRef=try prepare(old)
        _=try store.delete("owned-source");try seed(text:"Restored authored evidence");try drain();ids.removeAll()
        let replacement=try source(),ref=try prepare(replacement);XCTAssertNotEqual(old.identity,replacement.identity)
        XCTAssertThrowsError(try cache.record(oldRef,admit:{_ in}));XCTAssertEqual(try cache.record(ref,admit:{_ in}),replacement)
    }
    func testSensitiveSourceEditPurgesOldBodiesWhileMetadataKeepsImmutableEvidence()throws {
        try seed();try install();let original=try source(),ref=try prepare(original)
        _=try store.setFavorite("owned-source",value:true)
        XCTAssertEqual(try cache.record(ref,admit:{_ in}),original)
        XCTAssertThrowsError(try cache.resolve(original.identity,content:nil,admit:{_ in}))
        try drain();let current=try source();_=try prepare(current)
        try store.withRoutineDatabase {db in let m=try XCTUnwrap(self.store.get("owned-source"));var changed=m;changed.text="Safe replacement";let row=try db.statement("UPDATE memories SET text=?,payload=? WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,changed.text);let data=try JSONEncoder().encode(changed);data.withUnsafeBytes {_ = sqlite3_bind_blob(row,2,$0.baseAddress,Int32(data.count),db.transient)};db.bind(row,3,m.id);try db.done(row)}
        XCTAssertEqual(try count("personal_sync_versions"),0);XCTAssertNil(try cache.record(ref,admit:{_ in}))
    }
    func testCanonicalUnicodePrimaryBytesRemainDistinctInDurableBindings()throws {
        let a="e\u{301}",b="é";try seed(a,text:"Decomposed identifier");try seed(b,text:"Composed identifier");try install()
        let first=try source(a),second=try source(b),one=try prepare(first),two=try prepare(second)
        XCTAssertNotEqual(first.identity,second.identity);XCTAssertEqual(try cache.sourceVersion(localID:a,revision:.current,admit:{_ in}),one);XCTAssertEqual(try cache.sourceVersion(localID:b,revision:.current,admit:{_ in}),two)
    }
    func testHistoricalDependencyRequiresAnExactAuthenticatedRequester()throws {
        try seed();let conversation=try store.createChat(title:"Owned chat");let originalMemory=try XCTUnwrap(store.get("owned-source")),answer=Answer(text:"Owned answer",sources:[SearchHit(memory:originalMemory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[])
        _=try store.appendChatTurn(sessionID:conversation.id,question:"Owned question",answer:answer,filter:SearchFilter());try install()
        let original=try source(),ref=try prepare(original),chat=try make(.conversation,XCTUnwrap(rows(.conversation).first));_=try prepare(chat)
        let turn=try make(.turn,XCTUnwrap(rows(.turn).first));_=try prepare(turn)
        let citation=try make(.conversationCitation,XCTUnwrap(rows(.conversationCitation).first));_=try prepare(citation)
        // Remove only this cache entry; original source remains live. Its old
        // version is no longer a journal head after an authored metadata update.
        _=try store.setFavorite("owned-source",value:true);try drain();let newer=try source();_=try prepare(newer)
        try store.withRoutineDatabase {db in let row=try db.statement("DELETE FROM personal_sync_versions WHERE content_sha=?");defer {sqlite3_finalize(row)};db.bind(row,1,ref.content.sha256);try db.done(row)}
        XCTAssertThrowsError(try cache.retain(original,admit:{_ in}))
        guard case .conversationCitation(let body)=citation.body else {return XCTFail("Owned citation missing")}
        let forged=try SyncPortableRecord(identity:citation.identity,body:.conversationCitation(.init(owner:body.owner,ordinal:body.ordinal,link:.init(source:ref,score:1,match:"forged",passage:nil))))
        XCTAssertThrowsError(try cache.retain(original,requiredBy:forged,admit:{_ in}))
        XCTAssertEqual(try cache.retain(original,requiredBy:citation,admit:{_ in}),ref)
    }
    func testReadRefusesErasureDuringCurrentPolicyAdmissionAndRollsBack()throws {
        try seed();try install();let record=try source(),ref=try prepare(record)
        var erased=false
        XCTAssertThrowsError(try cache.record(ref) {_ in try self.store.withRoutineDatabase {try $0.execute("DELETE FROM memories WHERE id='owned-source'")};erased=true})
        XCTAssertTrue(erased,"The fixture must reach its actual canonical erasure before final admission validation")
        XCTAssertNotNil(try store.get("owned-source"));XCTAssertEqual(try count("personal_sync_versions"),1)
    }
    func testDuplicateRetentionRefusesEpochChangeInsideAdmissionAndRollsBack()throws {
        try seed();try install();let record=try source();_=try prepare(record)
        XCTAssertThrowsError(try cache.retain(record) {_ in try self.store.withRoutineDatabase {try $0.execute("UPDATE personal_sync_local SET epoch='00000000-0000-0000-0000-000000000799'")}})
        try store.withRoutineDatabase {db in let row=try db.statement("SELECT epoch FROM personal_sync_local");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(db.text(row,0),epoch)}
    }
    func seedGraph()throws {
        try seed();var sampled=Memory(id:"owned-samples",timestamp:now,endTimestamp:now.addingTimeInterval(2),kind:.screen,app:"Owned",text:"Owned sampled text",display:AccessibilityCaptureRecord.display)
        sampled.textObservation = .init(sessionID:"00000000-0000-0000-0000-000000000704",samples:2,largestGapSeconds:2);try store.insert(sampled);try store.withRoutineDatabase {try $0.pinTextObservation(sampled)}
        let project=try store.createEntity(kind:.project,name:"Orion",aliases:["Project Orion"]);try store.linkEntity(project.id,to:"owned-source")
        let person=try store.createEntity(kind:.person,name:"Alice");try store.unlinkEntity(person.id,from:"owned-source")
        let rejected=try store.createEntity(kind:.project,name:"Pluto");try store.unlinkEntity(rejected.id,from:"owned-source")
        let chat=try store.createChat(title:"Owned conversation"),memory=try XCTUnwrap(store.get("owned-source"))
        let answer=Answer(text:"Owned source-linked answer",sources:[SearchHit(memory:memory,score:1,match:"owned",passage:.init(start:0,length:5))],provider:"owned",duration:0,warnings:[])
        _=try store.appendChatTurn(sessionID:chat.id,question:"Owned graph question",answer:answer,filter:SearchFilter(entityID:project.id));_=try store.saveRecap(answer,title:"Owned recap")
        var recipe=RoutineDefinition();recipe.id="owned-recipe";recipe.title="Owned recipe";_=try store.saveRoutine(recipe,now:now)
        let run=try XCTUnwrap(store.claimRoutine(id:recipe.id,now:now));_=try store.finishRoutine(run.run.id,status:.failed,message:"Owned failure")
    }
    func prepareGraph()throws->[SyncPortableRecord] {
        let order:[SyncCanonicalTable]=[.source,.entity,.conversation,.routine,.turn,.conversationCitation,.recapCitation,.entityAlias,.entityMention,.entityRejection,.projectRejection,.evidencePin,.routineRun];var all=[SyncPortableRecord]()
        for table in order {
            var values=try rows(table)
            if table == .source {values.sort {a,b in
                func recap(_ r:SyncRowSnapshot)->Bool {if case .blob(let data)=r.cells[8] {return (try? JSONDecoder().decode(Memory.self,from:data).recap) != nil};return false}
                return !recap(a) && recap(b)
            }}
            for row in values {let record=try make(table,row);_=try prepare(record);all.append(record)}
        };return all
    }
    func testAllThirteenActualCanonicalTablesPersistTypedVersionsAndResolveAfterReopen()throws {
        try seedGraph();try install();let before=try SyncCanonicalTable.allCases.map {try rows($0).map {try $0.encoded()}},all=try prepareGraph()
        XCTAssertEqual(Set(all.map(\.identity.table)),Set(SyncCanonicalTable.allCases));XCTAssertEqual(try count("personal_sync_versions"),all.count)
        try store.close();store=try MemoryStore(root:root);try install()
        for record in all {XCTAssertEqual(try cache.record(record.reference,admit:{_ in}),record);try record.validateDependencies {try self.cache.resolve($0,content:$1,admit:{_ in})}}
        XCTAssertEqual(try SyncCanonicalTable.allCases.map {try rows($0).map {try $0.encoded()}},before)
    }
    func testPublicSourceErasurePurgesCachedDependentAnswersRecapsAndLabels()throws {
        try seedGraph();try install();let all=try prepareGraph();XCTAssertGreaterThan(all.count,13)
        _=try store.delete("owned-source")
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT COUNT(*) FROM personal_sync_versions WHERE instr(CAST(body AS TEXT),'Alice owns Orion.')>0 OR instr(CAST(body AS TEXT),'Owned graph question')>0 OR instr(CAST(body AS TEXT),'Owned source-linked answer')>0 OR instr(CAST(body AS TEXT),'Owned conversation')>0");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),0)
        }
        XCTAssertEqual(try store.chats().first?.title,"Conversation")
    }
    func testFullPublicWipeClearsAllVersionBodiesAndProjections()throws {
        try seedGraph();try install();_=try prepareGraph();_=try store.wipeLibrary()
        XCTAssertEqual(try count("personal_sync_versions"),0);XCTAssertEqual(try count("personal_sync_version_projection"),0)
        for table in ["personal_sync_version_recipes","personal_sync_version_sessions","personal_sync_version_runs"] {XCTAssertEqual(try count(table),0)}
    }
    func testMissingProtectionTriggerRefusesReadsAndReinstallDoesNotSilentlyRepair()throws {
        try seed();try install();let record=try source(),ref=try prepare(record)
        try store.withRoutineDatabase {try $0.execute("DROP TRIGGER sync_versions_memories_delete")}
        XCTAssertThrowsError(try cache.record(ref,admit:{_ in}));XCTAssertThrowsError(try SyncVersionStore.install(catalog:catalog,journal:journal))
        XCTAssertEqual(try count("personal_sync_versions"),1)
    }
    func testInPlaceBlobCorruptionIsDetectedWithoutChangingCanonicalEvidence()throws {
        try seed();try install();let record=try source(),ref=try prepare(record),before=try rows(.source).map {try $0.encoded()}
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT rowid FROM personal_sync_versions");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);let id=sqlite3_column_int64(row,0)
            var blob:OpaquePointer?;XCTAssertEqual(sqlite3_blob_open(db.handle,"main","personal_sync_versions","body",id,1,&blob),SQLITE_OK);guard let blob else {return XCTFail("Owned blob not opened")};defer {sqlite3_blob_close(blob)}
            var byte:UInt8=0x21;XCTAssertEqual(sqlite3_blob_write(blob,&byte,1,0),SQLITE_OK)
        }
        XCTAssertThrowsError(try cache.record(ref,admit:{_ in}));XCTAssertEqual(try rows(.source).map {try $0.encoded()},before)
    }
    func testReopenRefusesForgedLogicalAccountingWithoutReplacingBodies()throws {
        try seed();try install();let record=try source();_=try prepare(record)
        try store.withRoutineDatabase {try $0.execute("UPDATE personal_sync_version_state SET used_bytes=0")}
        XCTAssertThrowsError(try SyncVersionStore.install(catalog:catalog,journal:journal));XCTAssertEqual(try count("personal_sync_versions"),1)
    }

    func testHistoricalRecipeDefinitionsAndUnavailablePreEnrollmentHistoryStayDistinctAfterRestart()throws {
        var recipe=RoutineDefinition();recipe.id="owned-definitions";recipe.title="Owned definitions";recipe.prompt="Original authored definition"
        let first=try store.saveRoutine(recipe,now:now);try install();let original=try make(.routine,XCTUnwrap(rows(.routine).first)),one=try prepare(original)
        recipe.prompt="New authored definition";_=try store.saveRoutine(recipe,expectedRevision:first.revision,now:now);try drain()
        let current=try make(.routine,XCTUnwrap(rows(.routine).first)),two=try prepare(current)
        try store.close();store=try MemoryStore(root:root);try install()
        XCTAssertEqual(try cache.recipeVersion(localID:recipe.id,ordinal:1,admit:{_ in}).definition,one.content)
        XCTAssertEqual(try cache.recipeVersion(localID:recipe.id,ordinal:2,admit:{_ in}).definition,two.content)
        XCTAssertThrowsError(try cache.recipeVersion(localID:recipe.id,ordinal:3,admit:{_ in}))
        try store.withRoutineDatabase {db in let row=try db.statement("DELETE FROM personal_sync_versions WHERE content_sha=?");defer {sqlite3_finalize(row)};db.bind(row,1,one.content.sha256);try db.done(row)}
        XCTAssertEqual(try cache.recipeVersion(localID:recipe.id,ordinal:1,admit:{_ in}).definition,one.content,"A known immutable reference must survive a missing cached body")
        XCTAssertThrowsError(try cache.resolve(original.identity,content:one.content,admit:{_ in}))
    }
    func testPeerRunRecipeOriginAndOrdinalSurviveStatusChangeAndRestart()throws {
        var recipe=RoutineDefinition();recipe.id="owned-run-recipe";recipe.title="Owned run recipe";_=try store.saveRoutine(recipe,now:now)
        let claimed=try XCTUnwrap(store.claimRoutine(id:recipe.id,now:now));try install()
        let definition=try make(.routine,XCTUnwrap(rows(.routine).first)),ref=try prepare(definition)
        let original=SyncRoutineRevision(routine:definition.identity,editorOrigin:"00000000-0000-0000-0000-000000000777",ordinal:42,definition:ref.content)
        var explicit=references;explicit.runRecipe={_,_,_ in original}
        let snapshot=try XCTUnwrap(rows(.routineRun).first),identity=try self.identity(.routineRun,claimed.run.id),record=try SyncPortableExporter(references:explicit).record(identity:identity,row:snapshot)
        _=try journal.put(key:identity.key,content:record.reference.content) {_ in _=try self.cache.retain(record,admit:{_ in});try self.cache.bindProjection(record.reference,references:explicit,admit:{_ in})}
        _=try store.finishRoutine(claimed.run.id,status:.failed,message:"Owned changed status");try drain()
        XCTAssertEqual(try count("personal_sync_version_runs"),1)
        try store.close();store=try MemoryStore(root:root);try install()
        XCTAssertEqual(try cache.runRecipe(localRunID:claimed.run.id,recipeID:recipe.id,ordinal:1,admit:{_ in}),original)
        let exported=try make(.routineRun,XCTUnwrap(rows(.routineRun).first));guard case .routineRun(let body)=exported.body else {return XCTFail("Run missing")};XCTAssertEqual(body.recipe,original)
        XCTAssertThrowsError(try cache.runRecipe(localRunID:claimed.run.id,recipeID:recipe.id,ordinal:42,admit:{_ in}))
    }
    func testPeerSessionBindingSurvivesSensitiveUpdateWithoutAnyCachedSourceBody()throws {
        let token=try SyncSessionToken(origin:"00000000-0000-0000-0000-000000000778",localID:"owned-peer-session")
        var memory=Memory(id:"owned-audio",timestamp:now,kind:.audio,text:"Owned audio before");memory.audioSessionID=token.localProjection;try store.insert(memory);try install()
        let base=references,explicit=SyncPortableReferences(identity:base.identity,source:base.source,media:base.media,recipe:base.recipe,session:{_ in token},runRecipe:base.runRecipe)
        let identity=try self.identity(.source,memory.id),record=try SyncPortableExporter(references:explicit).record(identity:identity,row:XCTUnwrap(rows(.source).first))
        _=try journal.put(key:identity.key,content:record.reference.content) {_ in _=try self.cache.retain(record,admit:{_ in});try self.cache.bindProjection(record.reference,references:explicit,admit:{_ in})}
        memory.text="Owned audio after"
        try store.withRoutineDatabase {db in let row=try db.statement("UPDATE memories SET text=?,payload=? WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,memory.text);let data=try JSONEncoder().encode(memory);data.withUnsafeBytes {_ = sqlite3_bind_blob(row,2,$0.baseAddress,Int32(data.count),db.transient)};db.bind(row,3,memory.id);try db.done(row)}
        XCTAssertEqual(try count("personal_sync_versions"),0);XCTAssertEqual(try count("personal_sync_version_sessions"),1);try drain()
        try store.close();store=try MemoryStore(root:root);try install()
        XCTAssertEqual(try cache.sessionBinding(localID:memory.id,admit:{_ in}),token)
        let next=try source(memory.id);guard case .source(let body)=next.body else {return XCTFail("Source missing")};XCTAssertEqual(body.audioSession,token);_=try prepare(next)
        _=try store.delete(memory.id);XCTAssertEqual(try count("personal_sync_version_sessions"),0)
    }
    func testMissingOriginalPeerSessionBindingRefusesRehashAndCurrentPolicyCanDenyMetadata()throws {
        let token=try SyncSessionToken(origin:replica,localID:"owned-session");var memory=Memory(id:"owned-audio",kind:.audio,text:"Owned audio");memory.audioSessionID=token.localProjection
        try store.insert(memory);try install();_=try identity(.source,memory.id)
        XCTAssertThrowsError(try cache.sessionBinding(localID:memory.id,admit:{_ in}))
        XCTAssertThrowsError(try cache.sessionBinding(localID:memory.id) {_ in throw OSwindError.invalid("Owned denied current source policy")})
    }

    func testPreEnrollmentRecipeDefinitionIsExplicitlyUnavailableWithoutLatestSubstitution()throws {
        var recipe=RoutineDefinition();recipe.id="owned-pre-enrollment";recipe.title="Owned before sync";recipe.prompt="Original before enrollment"
        let first=try store.saveRoutine(recipe,now:now);recipe.prompt="Current before enrollment";_=try store.saveRoutine(recipe,expectedRevision:first.revision,now:now)
        try install();_=try prepare(make(.routine,XCTUnwrap(rows(.routine).first)))
        XCTAssertNil(try cache.recipeVersion(localID:recipe.id,ordinal:1,admit:{_ in}).definition)
        XCTAssertNotNil(try cache.recipeVersion(localID:recipe.id,ordinal:2,admit:{_ in}).definition)
    }

    func testRecipeMetadataCannotGrowBeyondBudgetAndIdempotentBindStillWorksAtLimit()throws {
        var recipe=RoutineDefinition();recipe.id="owned-budget-recipe";recipe.title="Owned budget recipe";let saved=try store.saveRoutine(recipe,now:now)
        try install();let record=try make(.routine,XCTUnwrap(rows(.routine).first)),ref=try prepare(record)
        try store.withRoutineDatabase {try $0.execute("UPDATE personal_sync_version_state SET budget=used_bytes")}
        XCTAssertNoThrow(try cache.bindProjection(ref,references:references,admit:{_ in}))
        _=try store.saveRoutine(recipe,expectedRevision:saved.revision,now:now);try drain()
        let next=try make(.routine,XCTUnwrap(rows(.routine).first));XCTAssertEqual(try next.reference.content,ref.content)
        XCTAssertThrowsError(try prepare(next));XCTAssertEqual(try count("personal_sync_version_recipes"),1);XCTAssertEqual(try journal.outbox().count,1)
    }

    func testCanonicalSourceColumnOnlyChangeInvalidatesItsCachedSnapshot()throws {
        try seed();try install();let record=try source(),ref=try prepare(record)
        try store.withRoutineDatabase {try $0.execute("UPDATE memories SET title='Owned changed column' WHERE id='owned-source'")}
        XCTAssertEqual(try count("personal_sync_versions"),0);XCTAssertNil(try cache.record(ref,admit:{_ in}))
    }
    func testSecondConnectionCannotReuseCachedSchemaOrSourceAfterErasure()throws {
        try seed();try install();let record=try source(),ref=try prepare(record),other=try MemoryStore(root:root);defer {try? other.close()}
        let second=try other.withRoutineDatabase {db -> SyncVersionStore in
            let c=try SyncIdentityCatalog.install(db),j=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:c,journal:j)
        }
        XCTAssertEqual(try second.record(ref,admit:{_ in}),record)
        _=try store.delete("owned-source");XCTAssertThrowsError(try second.record(ref,admit:{_ in}))
    }

    private func overwriteBlob(table:String,column:String,rowID:Int64,data:Data)throws {
        try store.withRoutineDatabase {db in
            var blob:OpaquePointer?;XCTAssertEqual(sqlite3_blob_open(db.handle,"main",table,column,rowID,1,&blob),SQLITE_OK);guard let blob else {return XCTFail("Owned metadata blob not opened")};defer {sqlite3_blob_close(blob)}
            XCTAssertEqual(Int(sqlite3_blob_bytes(blob)),data.count);XCTAssertEqual(data.withUnsafeBytes {sqlite3_blob_write(blob,$0.baseAddress,Int32($0.count),0)},SQLITE_OK)
        }
    }
    func testSourceRevisionDomainMetadataCannotRetargetDifferentEvidence()throws {
        try seed();try install();let record=try source();_=try prepare(record)
        let other=Memory(id:"owned-other",timestamp:now,kind:.note,text:"Different owned evidence")
        try store.withRoutineDatabase {db in let row=try db.statement("UPDATE personal_sync_version_projection SET evidence=?,entity_revision=?");defer {sqlite3_finalize(row)};db.bind(row,1,other.evidenceHash);db.bind(row,2,other.entityRevision);try db.done(row)}
        XCTAssertThrowsError(try cache.sourceVersion(localID:"owned-source",revision:.evidence(other.evidenceHash),admit:{_ in}))
        XCTAssertThrowsError(try cache.sourceVersion(localID:"owned-source",revision:.entity(other.entityRevision),admit:{_ in}))
    }
    func testRecipeRevisionMetadataCannotPointAnOldOrdinalAtANewerBody()throws {
        var recipe=RoutineDefinition();recipe.id="owned-recipe-integrity";recipe.title="Owned recipe integrity";recipe.prompt="Owned recipe ALPHA"
        let saved=try store.saveRoutine(recipe,now:now);try install();let old=try make(.routine,XCTUnwrap(rows(.routine).first)),one=try prepare(old)
        recipe.prompt="Owned recipe BRAVO";_=try store.saveRoutine(recipe,expectedRevision:saved.revision,now:now);try drain();let new=try make(.routine,XCTUnwrap(rows(.routine).first)),two=try prepare(new)
        XCTAssertEqual(one.content.bytes,two.content.bytes)
        let rowID=try store.withRoutineDatabase {db -> Int64 in let row=try db.statement("SELECT rowid FROM personal_sync_version_recipes WHERE ordinal=1");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return sqlite3_column_int64(row,0)}
        try overwriteBlob(table:"personal_sync_version_recipes",column:"content_sha",rowID:rowID,data:Data(two.content.sha256.utf8))
        XCTAssertThrowsError(try cache.recipeVersion(localID:recipe.id,ordinal:1,admit:{_ in}))
    }
    func testRunRecipeMetadataCannotSilentlyChangeItsOriginalOrdinal()throws {
        try seedGraph();try install();_=try prepareGraph()
        let entry=try store.withRoutineDatabase {db -> (Int64,Data,String,String,Int64) in
            let row=try db.statement("SELECT b.rowid,b.recipe,r.id,r.routine_id,r.revision FROM personal_sync_version_runs b JOIN personal_sync_identities i ON i.object_digest=b.object_digest JOIN routine_runs r ON i.local_key=oswind_sync_key_v1(r.id) LIMIT 1");defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW,let p=sqlite3_column_blob(row,1) else {throw db.error()};return (sqlite3_column_int64(row,0),Data(bytes:p,count:Int(sqlite3_column_bytes(row,1))),db.text(row,2),db.text(row,3),sqlite3_column_int64(row,4))
        }
        let old=try JSONDecoder().decode(SyncRoutineRevision.self,from:entry.1),forged=SyncRoutineRevision(routine:old.routine,editorOrigin:old.editorOrigin,ordinal:old.ordinal+1,definition:old.definition)
        try overwriteBlob(table:"personal_sync_version_runs",column:"recipe",rowID:entry.0,data:SyncProtocolLimits.encode(forged))
        XCTAssertThrowsError(try cache.runRecipe(localRunID:entry.2,recipeID:entry.3,ordinal:entry.4,admit:{_ in}))
    }

    func testCompleteBackupRestoresCanonicalDataWithoutCloningSyncAuthorityOrCaches()throws {
        try seedGraph();try install();_=try prepareGraph()
        let nonce=UUID().uuidString,archive=root.deletingLastPathComponent().appendingPathComponent("owned-version-backup-"+nonce+".oswindbackup"),restored=root.deletingLastPathComponent().appendingPathComponent("owned-version-restored-"+nonce)
        defer {try? FileManager.default.removeItem(at:archive);try? FileManager.default.removeItem(at:restored)}
        let originalSources=try rows(.source).count,scope=catalog.scope
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:restored)
        let copy=try MemoryStore(root:restored);defer {try? copy.close()}
        XCTAssertEqual(try copy.stats().count,originalSources);XCTAssertEqual(try copy.get("owned-source")?.text,"Alice owns Orion.")
        try copy.withRoutineDatabase {db in
            let row=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'personal_sync_version%' OR name='personal_sync_local'");defer {sqlite3_finalize(row)};XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(row,0),0)
            XCTAssertEqual(try db.eraseCount("SELECT enabled FROM personal_sync_capture"),0);XCTAssertNotEqual(try SyncChangeCapture.scope(db),scope)
        }
    }

}
