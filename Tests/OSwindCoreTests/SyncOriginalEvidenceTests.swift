import XCTest
import CSQLite
@testable import OSwindCore

final class SyncOriginalEvidenceTests:XCTestCase {
    var root:URL!,store:MemoryStore!,catalog:SyncIdentityCatalog!,cache:SyncVersionStore!,evidence:SyncOriginalEvidenceStore!
    let replica="00000000-0000-0000-0000-000000000901",group="00000000-0000-0000-0000-000000000902",epoch="00000000-0000-0000-0000-000000000903"
    let now=Date(timeIntervalSince1970:1700000000)
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-original-evidence-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store.close();store=nil;try FileManager.default.removeItem(at:root)}
    func install(budget:Int64=SyncOriginalEvidenceStore.defaultBudget)throws {
        try store.withRoutineDatabase {db in _=try SyncChangeCapture.activate(db);catalog=try SyncIdentityCatalog.install(db);let j=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch);cache=try SyncVersionStore.install(catalog:catalog,journal:j);evidence=try SyncOriginalEvidenceStore.install(cache:cache,budget:budget)}
    }
    func seed(_ id:String="owned",_ text:String="Original Alice owns Orion.")throws {try store.insert(Memory(id:id,timestamp:now,kind:.note,app:"Owned",text:text))}
    func identity(_ id:String)throws->SyncObjectIdentity {try catalog.registerExisting(.source,primary:[.text(Data(id.utf8))])}
    func record(_ id:String="owned")throws->SyncPortableRecord {
        let memory=try XCTUnwrap(store.get(id));return try .init(identity:identity(id),body:.source(.init(memory:memory,origin:catalog.scope.origin,media:[]) {_,_ in throw OSwindError.invalid("Owned no recap") }))
    }
    @discardableResult func retain(_ record:SyncPortableRecord)throws->SyncVersionReference {
        let ref=try record.reference;_=try cache.journal.put(key:record.identity.key,content:ref.content) {_ in _=try self.cache.retain(record,admit:{_ in})};return ref
    }
    func prepare(_ reference:SyncVersionReference)throws->SyncOriginalEvidence {try evidence.prepare(reference,pathsFor:{_,_ in [:]},admit:{_ in},admitMedia:{_,_,_ in})}
    func read(_ handle:String)throws->SyncOriginalEvidence {try evidence.read(handle,admit:{_ in},admitMedia:{_,_,_ in})}
    func n(_ table:String)throws->Int {try store.withRoutineDatabase {db in let s=try db.statement("SELECT COUNT(*) FROM "+table);defer {sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_ROW else {throw db.error()};return Int(sqlite3_column_int(s,0))}}
    func sql(_ sql:String)throws {try store.withRoutineDatabase {try $0.execute(sql)}}
    func recap()throws->(SyncVersionReference,SyncVersionReference) {
        try seed();let answer=Answer(text:"Owned recap",sources:[SearchHit(memory:try XCTUnwrap(store.get("owned")),score:1,match:"owned")],provider:"owned",duration:0,warnings:[]),saved=try store.saveRecap(answer,title:"Original recap")
        try install();let original=try record(),source=try retain(original),memory=try XCTUnwrap(store.get(saved.id)),body=try SyncSourceBody(memory:memory,origin:catalog.scope.origin,media:[]) {id,_ in guard id=="owned" else {throw OSwindError.invalid("Owned parent mismatch")};return source},packet=try SyncPortableRecord(identity:identity(saved.id),body:.source(body));return(try retain(packet),source)
    }
    func testOrdinaryOpeningDoesNotInstallOriginalEvidenceOrChangeSchema()throws {
        try store.withRoutineDatabase {db in let s=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'personal_sync_evidence%'");defer {sqlite3_finalize(s)};XCTAssertEqual(sqlite3_step(s),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(s,0),0)}
        XCTAssertEqual(MemoryStore.schemaVersion,26)
    }
    func testOriginalVersionDoesNotRetargetNewerHeadOrCreateCanonicalRowsOrJournalEcho()throws {
        try seed();try install();let old=try record(),one=try retain(old),original=try prepare(one)
        let changed=try SyncPortableRecord(identity:old.identity,body:.source(.init(memory:Memory(id:"owned",timestamp:now,kind:.note,text:"Newer head"),origin:catalog.scope.origin,media:[]){_,_ in throw OSwindError.invalid("No recap")}));_=try retain(changed)
        let operations=try cache.journal.outbox();let loaded=try read(original.handle)
        XCTAssertEqual(loaded.memory.text,"Original Alice owns Orion.");XCTAssertEqual(loaded.reference,one);XCTAssertNotEqual(loaded.memory.id,"owned");XCTAssertNotNil(loaded.memory.originalEvidence)
        XCTAssertEqual(try n("memories"),1);XCTAssertEqual(try n("personal_sync_changes"),0);XCTAssertEqual(try cache.journal.outbox(),operations)
    }
    func testHandleAndNativeProjectionSurviveReopenWithOriginalFields()throws {
        try seed();try install();let ref=try retain(record()),original=try prepare(ref);try store.close();store=try MemoryStore(root:root);try install()
        let loaded=try read(original.handle);XCTAssertEqual(loaded.memory,original.memory);XCTAssertEqual(try prepare(ref).handle,original.handle)
        XCTAssertEqual(loaded.memory.timestamp,now);XCTAssertEqual(loaded.memory.originalEvidence?.contentSHA256,ref.content.sha256)
    }
    func testImmutableRecapPointsToOriginalProjectionHandleAndExactParentVersion()throws {
        let (ref,source)=try recap(),original=try prepare(ref),parent=try XCTUnwrap(original.memory.recap?.sources.first)
        XCTAssertTrue(parent.id.hasPrefix("original-"));let handle=String(parent.id.dropFirst("original-".count)),loaded=try read(handle)
        XCTAssertEqual(loaded.reference,source);XCTAssertEqual(parent.revision,loaded.memory.evidenceHash);XCTAssertEqual(try read(original.handle).memory,original.memory)
        XCTAssertEqual(try n("personal_sync_evidence"),2)
    }
    func testExactMissingSourceCannotFallBackToAnotherCachedVersion()throws {
        try seed();try install();let ref=try retain(record());_=try prepare(ref)
        let missing=try SyncVersionReference(identity:ref.identity,content:.init(data:Data("Owned unavailable version".utf8)))
        XCTAssertThrowsError(try prepare(missing));XCTAssertEqual(try n("personal_sync_evidence"),1)
    }
    func testCanonicalErasureImmediatelyPurgesProjectionAndRefusesOldHandle()throws {
        try seed();try install();let original=try prepare(retain(record()));_=try store.delete("owned")
        XCTAssertEqual(try n("personal_sync_evidence"),0);XCTAssertThrowsError(try read(original.handle));XCTAssertEqual(try n("personal_sync_changes"),1)
    }
    func testSensitiveCanonicalUpdatePurgesEvidenceWhileMetadataCanRetainIt()throws {
        try seed();try install();let original=try prepare(retain(record()));_=try store.setFavorite("owned",value:true)
        XCTAssertEqual(try read(original.handle).memory.favorite,false)
        try sql("UPDATE memories SET text='Changed original' WHERE id='owned'")
        XCTAssertEqual(try n("personal_sync_evidence"),0);XCTAssertThrowsError(try read(original.handle))
    }
    func testDeletionRecreationCannotResurrectPriorHandle()throws {
        try seed();try install();let original=try prepare(retain(record()));_=try store.delete("owned");try seed("owned","Replacement");_=try catalog.process {_ in}
        let replacement=try prepare(retain(record()));XCTAssertNotEqual(original.reference.identity,replacement.reference.identity);XCTAssertNotEqual(original.handle,replacement.handle);XCTAssertThrowsError(try read(original.handle))
    }
    func testReadPolicyAndMediaAdmissionCanRefuseWithoutReturningSnapshot()throws {
        try seed();try install();let original=try prepare(retain(record()))
        XCTAssertThrowsError(try evidence.read(original.handle,admit:{_ in throw OSwindError.invalid("Owned policy denial")},admitMedia:{_,_,_ in}))
        XCTAssertThrowsError(try evidence.read(original.handle,admit:{_ in},admitMedia:{_,_,_ in throw OSwindError.invalid("Owned media denial")}))
        XCTAssertEqual(try n("personal_sync_evidence"),1)
    }
    func testLateOwnSourceErasureRollsBackRatherThanReturningEvidence()throws {
        try seed();try install();let original=try prepare(retain(record()));var reached=false
        XCTAssertThrowsError(try evidence.read(original.handle,admit:{_ in if !reached {try self.sql("DELETE FROM memories WHERE id='owned'");reached=true}},admitMedia:{_,_,_ in}))
        XCTAssertTrue(reached);XCTAssertNotNil(try store.get("owned"));XCTAssertNotNil(try read(original.handle))
    }
    func testLateParentAdmissionCannotEraseRootAfterRootWasChecked()throws {
        let (ref,source)=try recap(),original=try prepare(ref),owner=try XCTUnwrap(catalog.object(ref.identity)?.primary),rootID:String
        guard case .text(let bytes)=owner[0],let id=String(data:bytes,encoding:.utf8) else {return XCTFail("Missing owned recap key")};rootID=id
        var rootCalls=0,reached=false
        XCTAssertThrowsError(try evidence.read(original.handle,admit:{record in
            if record.identity==ref.identity {rootCalls+=1}
            if record.identity==source.identity,rootCalls>=2,!reached {try self.store.withRoutineDatabase {db in let s=try db.statement("DELETE FROM memories WHERE id=?");defer {sqlite3_finalize(s)};db.bind(s,1,rootID);try db.done(s)};reached=true}
        },admitMedia:{_,_,_ in}))
        XCTAssertTrue(reached);XCTAssertNotNil(try store.get(rootID))
    }
    func testBudgetFailureRollsBackAllRecursivelyPreparedMetadata()throws {
        let (ref,_)=try recap();try sql("UPDATE personal_sync_evidence_state SET budget=196")
        XCTAssertThrowsError(try prepare(ref));XCTAssertEqual(try n("personal_sync_evidence"),0)
    }
    func testReadOnlyProjectionCannotBecomeCanonicalImportRecapOrOutgoingSource()throws {
        try seed();try install();let original=try prepare(retain(record())),memory=original.memory
        XCTAssertThrowsError(try store.insert(memory));XCTAssertThrowsError(try store.hydrate(memory))
        XCTAssertThrowsError(try SyncSourceBody(memory:memory,origin:catalog.scope.origin,media:[]){_,_ in throw OSwindError.invalid("No recap")})
        let answer=Answer(text:"Owned unauthorized derived evidence",sources:[SearchHit(memory:memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[])
        XCTAssertThrowsError(try store.saveRecap(answer));XCTAssertEqual(try n("memories"),1)
    }
    func testEpochChangeDuringMediaAdmissionRefusesAndRollsBack()throws {
        try seed();try install();let original=try prepare(retain(record()));var reached=false
        XCTAssertThrowsError(try evidence.read(original.handle,admit:{_ in},admitMedia:{_,_,_ in try self.sql("UPDATE personal_sync_local SET epoch='00000000-0000-0000-0000-000000000999'");reached=true}))
        XCTAssertTrue(reached);XCTAssertEqual(try read(original.handle).reference,original.reference)
    }
    func testMissingProtectionTriggerRefusesWithoutRepair()throws {
        try seed();try install();let original=try prepare(retain(record()));try sql("DROP TRIGGER sync_evidence_immutable")
        XCTAssertThrowsError(try read(original.handle));XCTAssertThrowsError(try SyncOriginalEvidenceStore.install(cache:cache));XCTAssertEqual(try n("personal_sync_evidence"),1)
    }
    func testOldExactEvidenceCanBeReauthorizedAfterCanonicalCurrentTextChanges()throws {
        try seed();try install();let old=try record(),ref=try retain(old),snapshot=try prepare(ref)
        try seed("owned","Changed canonical current text");_=try catalog.process {_ in}
        let current=try record();_=try retain(current);XCTAssertThrowsError(try read(snapshot.handle))
        let project=try store.createEntity(kind:.project,name:"Owned project");try store.unlinkEntity(project.id,from:"owned");_=try catalog.process {_ in}
        let requestIdentity=try catalog.registerExisting(.projectRejection,primary:[.text(Data("owned".utf8)),.text(Data(project.id.utf8))]),entity=try catalog.registerExisting(.entity,primary:[.text(Data(project.id.utf8))])
        let request=try SyncPortableRecord(identity:requestIdentity,body:.projectRejection(.init(source:ref,entity:entity)))
        _=try cache.journal.put(key:requestIdentity.key,content:request.reference.content) {_ in _=try self.cache.retain(old,requiredBy:request,admit:{_ in})}
        let loaded=try prepare(ref)
        XCTAssertEqual(loaded.memory.text,"Original Alice owns Orion.");XCTAssertEqual(try store.get("owned")?.text,"Changed canonical current text");XCTAssertEqual(loaded.reference,ref)
        XCTAssertNotEqual(loaded.handle,snapshot.handle,"Purged handles cannot become authority again")
    }
    func testAllMediaRolesRequireCallerVerificationAndRefuseChangedOrSymlinkedBytes()throws {
        let video=VisualRecording(duration:1,width:2,height:2,codec:"hevc",hardwareRequired:true,frames:[.init(time:0,text:"Owned media")])
        var memory=Memory(id:"owned-media",timestamp:now,kind:.screen,text:video.text,imagePath:"images/owned",audioPath:"audio/owned");memory.videoPath="video/owned";memory.visualRecording=video
        let paths:[SyncMediaRole:String]=[.image:memory.imagePath!,.audio:memory.audioPath!,.video:memory.videoPath!];var manifests=[SyncMediaManifest]()
        for role in SyncMediaRole.allCases {let data=Data(("Owned "+role.rawValue+" bytes").utf8),path=root.appendingPathComponent(paths[role]!);try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:path);let ref=try SyncContentReference(data:data);manifests.append(.init(role:role,sha256:ref.sha256,bytes:ref.bytes,chunks:[ref]))}
        try store.insert(memory);try install();let packet=try SyncPortableRecord(identity:identity(memory.id),body:.source(.init(memory:memory,origin:catalog.scope.origin,media:manifests){_,_ in throw OSwindError.invalid("No recap")})),ref=try retain(packet)
        func admit(_ ref:SyncVersionReference,_ media:[SyncMediaManifest],_ local:[SyncMediaRole:String])throws {
            guard Set(local.keys)==Set(media.map(\.role)) else {throw OSwindError.invalid("Missing media")}
            let files=try BackupFileTree(root:root)
            for asset in media {let digest=try files.digest(local[asset.role]!,limit:asset.bytes);guard digest.bytes==asset.bytes,digest.sha256==asset.sha256 else {throw OSwindError.invalid("Changed media")}}
        }
        let original=try evidence.prepare(ref,pathsFor:{_,_ in paths},admit:{_ in},admitMedia:admit)
        XCTAssertEqual(original.memory.imagePath,paths[.image]);XCTAssertEqual(original.memory.audioPath,paths[.audio]);XCTAssertEqual(original.memory.videoPath,paths[.video]);XCTAssertEqual(original.memory.visualRecording,video)
        try Data("Changed asset".utf8).write(to:root.appendingPathComponent(paths[.image]!))
        XCTAssertThrowsError(try evidence.read(original.handle,admit:{_ in},admitMedia:admit))
        let outside=root.appendingPathComponent("outside-owned"),image=root.appendingPathComponent(paths[.image]!);try Data("Owned image bytes".utf8).write(to:outside);try FileManager.default.removeItem(at:image);try FileManager.default.createSymbolicLink(at:image,withDestinationURL:outside)
        XCTAssertThrowsError(try evidence.read(original.handle,admit:{_ in},admitMedia:admit))
    }
    func testMissingMediaOrTraversalCannotBeAdmittedAsNativePaths()throws {
        var memory=Memory(id:"owned-image",timestamp:now,kind:.screen,text:"Owned image",imagePath:"images/owned");memory.audioSessionID=nil;try store.insert(memory);try install()
        let content=try SyncContentReference(data:Data("Owned image bytes".utf8)),packet=try SyncPortableRecord(identity:identity(memory.id),body:.source(.init(memory:memory,origin:catalog.scope.origin,media:[.init(role:.image,sha256:content.sha256,bytes:content.bytes,chunks:[content])]){_,_ in throw OSwindError.invalid("No recap")})),ref=try retain(packet)
        XCTAssertThrowsError(try prepare(ref));XCTAssertThrowsError(try evidence.prepare(ref,pathsFor:{_,_ in [.image:"images/../outside"]},admit:{_ in},admitMedia:{_,_,_ in}));XCTAssertEqual(try n("personal_sync_evidence"),0)
    }
    func testNativeAudioRetainsOriginalSessionAndTranscriptWithoutLocalInferenceAuthority()throws {
        var memory=Memory(id:"owned-audio",timestamp:now,kind:.audio,text:"Owned original speech");memory.audioSessionID="original-session";memory.transcript = .init(text:memory.text,duration:1,segments:[.init(start:0,end:1,text:memory.text)],model:"owned")
        try store.insert(memory);try install();let packet=try record(memory.id),ref=try retain(packet),snapshot=try prepare(ref)
        guard case .source(let body)=packet.body else {return XCTFail("Missing audio")}
        XCTAssertEqual(snapshot.memory.transcript,body.transcript);XCTAssertEqual(snapshot.memory.audioSessionID,body.audioSession?.localProjection);XCTAssertNotEqual(snapshot.memory.audioSessionID,memory.audioSessionID)
        XCTAssertNil(snapshot.memory.embedding);XCTAssertNil(snapshot.memory.embeddingModel)
    }
    func testSerializedOriginalProjectionCannotBeImportedAsCanonicalHistory()throws {
        try seed();try install();let snapshot=try prepare(retain(record())),before=try n("memories")
        XCTAssertThrowsError(try store.importJSONDetailed(data:JSONEncoder().encode([snapshot.memory])));XCTAssertEqual(try n("memories"),before)
        let chat=try store.createChat(title:"Owned");XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Owned",answer:.init(text:"Owned",sources:[.init(memory:snapshot.memory,score:1,match:"owned")],provider:"owned",duration:0,warnings:[])))
    }
    func testBlobPathMetadataCorruptionCannotRetargetAnOriginalProjection()throws {
        try seed();try install();let original=try prepare(retain(record()))
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT rowid FROM personal_sync_evidence WHERE handle=?");defer {sqlite3_finalize(row)};db.bind(row,1,original.handle);XCTAssertEqual(sqlite3_step(row),SQLITE_ROW)
            var blob:OpaquePointer?;XCTAssertEqual(sqlite3_blob_open(db.handle,"main","personal_sync_evidence","parents",sqlite3_column_int64(row,0),1,&blob),SQLITE_OK)
            guard let blob else {return XCTFail("No owned blob")};defer {sqlite3_blob_close(blob)};let data=Data("{}".utf8);data.withUnsafeBytes {XCTAssertEqual(sqlite3_blob_write(blob,$0.baseAddress,Int32(data.count),0),SQLITE_OK)}
        }
        XCTAssertThrowsError(try read(original.handle));XCTAssertEqual(try store.get("owned")?.text,"Original Alice owns Orion.")
    }
    func testQuietRestoreDoesNotCloneOriginalEvidenceAuthority()throws {
        try seed();try install();_=try prepare(retain(record()));let nonce=UUID().uuidString,archive=root.deletingLastPathComponent().appendingPathComponent("owned-original-"+nonce+".oswindbackup"),destination=root.deletingLastPathComponent().appendingPathComponent("owned-original-restored-"+nonce)
        defer {try? FileManager.default.removeItem(at:archive);try? FileManager.default.removeItem(at:destination)}
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:destination);let copy=try MemoryStore(root:destination);defer {try? copy.close()}
        XCTAssertEqual(try copy.get("owned")?.text,"Original Alice owns Orion.")
        try copy.withRoutineDatabase {db in let s=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'personal_sync_evidence%'");defer {sqlite3_finalize(s)};XCTAssertEqual(sqlite3_step(s),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(s,0),0)}
    }
    func testTwoOwnedLibrariesMaterializeConcurrentOriginalBeforeCitationApplication()throws {
        try seed();try install();let original=try record(),ref=try retain(original),initial=try XCTUnwrap(cache.journal.outbox().first)
        let receiver=try MemoryStore(root:root.appendingPathComponent("receiver"));defer {try? receiver.close()}
        let (remoteCache,remoteEvidence)=try receiver.withRoutineDatabase {db -> (SyncVersionStore,SyncOriginalEvidenceStore) in
            _=try SyncChangeCapture.activate(db);let c=try SyncIdentityCatalog.install(db),j=try SyncJournal.install(database:db,replica:"00000000-0000-0000-0000-000000000904",group:group,epoch:epoch),cache=try SyncVersionStore.install(catalog:c,journal:j);try j.allowPeer(replica)
            return(cache,try SyncOriginalEvidenceStore.install(cache:cache))
        }
        _=try remoteCache.journal.receive(initial,contentAvailable:{_ in true}) {_ in
            try remoteCache.catalog.applyPeer(original.identity,primary:[.text(Data("receiver-source".utf8))]) {
                guard case .source(let body)=original.body else {throw OSwindError.invalid("Missing owned source")};try receiver.insert(body.projectedMemory(id:"receiver-source",paths:[:]){_ in throw OSwindError.invalid("No recap")})
            };_=try remoteCache.retain(original,admit:{_ in})
        }
        // The receiver changes its canonical source offline; the producer keeps
        // citing its own original. Source and citation histories are concurrent.
        try receiver.insert(Memory(id:"receiver-source",timestamp:now,kind:.note,text:"Receiver current text"));_=try remoteCache.catalog.process {_ in}
        let newer=try SyncPortableRecord(identity:original.identity,body:.source(.init(memory:XCTUnwrap(receiver.get("receiver-source")),origin:original.identity.origin,media:[]){_,_ in throw OSwindError.invalid("No recap")}));_=try remoteCache.journal.put(key:newer.identity.key,content:newer.reference.content){_ in _=try remoteCache.retain(newer,admit:{_ in})}
        let chat=try store.createChat(title:"Concurrent owned citation"),answer=Answer(text:"Original answer",sources:[.init(memory:try XCTUnwrap(store.get("owned")),score:1,match:"owned")],provider:"owned",duration:0,warnings:[])
        _=try store.appendChatTurn(sessionID:chat.id,question:"Original question",answer:answer)
        let queue=try SyncOutgoingWorkQueue.install(catalog:catalog),processor=SyncOutgoingProcessor(queue:queue,cache:cache,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []})
        for _ in 0..<40 {if try processor.step() == .idle {break}}
        var materialized:SyncOriginalEvidence?
        for revision in try cache.journal.outbox().dropFirst() {
            // This fixture exercises authenticated request/cache projection;
            // applying the incoming canonical citation graph is separate work.
            guard let content=revision.content else {continue}
            let row=try cache.database.statement("SELECT body FROM personal_sync_versions WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(row)};cache.database.bind(row,1,revision.key.digest);cache.database.bind(row,2,content.sha256);guard sqlite3_step(row)==SQLITE_ROW,let bytes=sqlite3_column_blob(row,0) else {throw cache.database.error()}
            let request=try SyncPortableRecord.decode(Data(bytes:bytes,count:Int(sqlite3_column_bytes(row,0))))
            _=try remoteCache.journal.receive(revision,contentAvailable:{_ in true}) {_ in
                if request.identity.table == .conversationCitation {
                    _=try remoteCache.retain(original,requiredBy:request,admit:{_ in});materialized=try remoteEvidence.prepare(ref,pathsFor:{_,_ in [:]},admit:{_ in},admitMedia:{_,_,_ in})
                }
            }
        }
        XCTAssertEqual(try XCTUnwrap(materialized).memory.text,"Original Alice owns Orion.");XCTAssertEqual(materialized?.reference,ref);XCTAssertEqual(try receiver.get("receiver-source")?.text,"Receiver current text");XCTAssertEqual(try receiver.stats().count,1)
        XCTAssertEqual(try remoteCache.journal.outbox().count,1,"Materializing an incoming original must not echo a canonical source")
    }
    func testProjectionChecksumBindsOriginalIdentityEvenWhenNativePayloadsAreIdentical()throws {
        try seed("owned-one");try seed("owned-two");try install();let one=try retain(record("owned-one")),two=try retain(record("owned-two")),snapshot=try prepare(one)
        XCTAssertNotEqual(one.identity,two.identity)
        // Simulate a metadata repair/corruption retaining a previous checksum
        // while retargeting its handle to another valid, equal-content owner.
        try store.withRoutineDatabase {db in
            try db.execute("CREATE TEMP TABLE original_metadata_copy AS SELECT * FROM personal_sync_evidence; DELETE FROM personal_sync_evidence")
            let put=try db.statement("INSERT INTO personal_sync_evidence SELECT handle,?,?,paths,parents,projection_sha FROM temp.original_metadata_copy");defer {sqlite3_finalize(put)};db.bind(put,1,try two.identity.key.digest);db.bind(put,2,two.content.sha256);try db.done(put);try db.execute("DROP TABLE temp.original_metadata_copy")
        }
        XCTAssertThrowsError(try read(snapshot.handle));XCTAssertEqual(try n("memories"),2)
    }
}
