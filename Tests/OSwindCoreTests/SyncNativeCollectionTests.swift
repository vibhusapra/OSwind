import XCTest
import CSQLite
@testable import OSwindCore

extension SyncOutgoingTests {
    private var nativePeer:String {"00000000-0000-0000-0000-000000008101"}
    private func nativeControlProducer(_ name:String)throws->(MemoryStore,SyncVersionStore,SyncObjectFolder) {
        let a=try MemoryStore(root:root.appendingPathComponent(name+"-producer"))
        let ac=try a.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db)
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:nativePeer,group:group,epoch:epoch)
            return try SyncVersionStore.install(catalog:catalog,journal:journal)
        }
        let folder=try SyncObjectFolder.create(at:root.appendingPathComponent(name+"-transport"),secret:SyncGroupSecret(),group:group,epoch:epoch)
        try cache.journal.allowPeer(nativePeer)
        return(a,ac,folder)
    }
    @discardableResult private func publishNativeControl(_ a:MemoryStore,_ ac:SyncVersionStore,_ folder:SyncObjectFolder)throws->SyncCollectionControl {
        _=try a.wipeLibrary()
        let control=try a.withRoutineDatabase {db in
            let history=SyncCollectionHistory(database:db,replica:nativePeer)
            guard case .needsGroupReview(let proposal)=try history.reviewState(journal:ac.journal) else {throw OSwindError.invalid("Owned native fixture has no group proposal")}
            return try history.approveGroupErase(journal:ac.journal,counter:proposal.counter,expectedEra:proposal.era)
        }
        _=try SyncLibrarySender(library:a,cache:ac,inbox:folder,admit:{try $0.validate()},supplementalContent:{_ in throw OSwindError.invalid("Owned empty producer has no supplemental content")}).publish()
        XCTAssertEqual(try folder.collectionControl(creator:nativePeer,counter:control.counter),control)
        return control
    }
    private func writeNativeMedia(_ path:String)throws {
        let url=root.appendingPathComponent(path);try Paths.ensure(url.deletingLastPathComponent());try Data(path.utf8).write(to:url)
    }
    /// Optional consistent SQLite backups of authored fixtures, plus their
    /// quiescent media buckets. These are not process-death/WAL observations.
    private func captureNativeCollectionFixture(_ name:String)throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_COLLECTION_ROOT"] else {return}
        let destination=URL(fileURLWithPath:path,isDirectory:true).appendingPathComponent(name,isDirectory:true)
        guard !FileManager.default.fileExists(atPath:destination.path) else {throw OSwindError.invalid("Use fresh owned native fixture snapshots")}
        try Paths.ensure(destination)
        try store.withRoutineDatabase {db in
            guard sqlite3_get_autocommit(db.handle) != 0 else {throw OSwindError.invalid("Snapshot only the committed native fixture")}
            var output:OpaquePointer?
            guard sqlite3_open(destination.appendingPathComponent("memory.sqlite").path,&output)==SQLITE_OK,let output else {throw OSwindError.database("Cannot open owned fixture snapshot")}
            defer {sqlite3_close(output)}
            guard let backup=sqlite3_backup_init(output,"main",db.handle,"main") else {throw OSwindError.database("Cannot start owned fixture snapshot")}
            let step=sqlite3_backup_step(backup,-1),finish=sqlite3_backup_finish(backup)
            guard step==SQLITE_DONE,finish==SQLITE_OK else {throw OSwindError.database("Owned fixture snapshot did not finish")}
        }
        for bucket in ["images","audio","video"] {
            try FileManager.default.copyItem(at:root.appendingPathComponent(bucket),to:destination.appendingPathComponent(bucket))
        }
    }
    private func assertNativeCollectionEmpty(file:StaticString=#filePath,line:UInt=#line)throws {
        for table in SyncCanonicalTable.allCases {XCTAssertEqual(try n("SELECT COUNT(*) FROM "+table.rawValue),0,table.rawValue,file:file,line:line)}
        for table in ["personal_sync_changes","personal_sync_work","personal_sync_identity_current","personal_sync_versions","personal_sync_version_projection","personal_sync_version_sessions","personal_sync_version_recipes","personal_sync_version_runs","historical_evidence"] {
            XCTAssertEqual(try n("SELECT COUNT(*) FROM "+table),0,table,file:file,line:line)
        }
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_identities WHERE deleted=0 OR key_frame IS NOT NULL"),0,file:file,line:line)
        for table in ["personal_sync_capture","personal_sync_work_state","personal_sync_version_state"] {XCTAssertEqual(try n("SELECT used_bytes FROM "+table+" WHERE singleton=1"),0,table,file:file,line:line)}
    }
    func testNativeCollectionPrimitivesRefuseUnownedTransactionsAndLiveNativeKeyRetirement()throws {
        try install();try seedGraph();_=try finish()
        let before=try frames(),headers=try cache.journal.outbox(),versions=try n("SELECT COUNT(*) FROM personal_sync_versions")
        XCTAssertThrowsError(try cache.retireCollectionCaches())
        XCTAssertThrowsError(try cache.catalog.retireCollectionMappings())
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {try cache.catalog.retireCollectionMappings()}})
        XCTAssertEqual(try frames(),before);XCTAssertEqual(try cache.journal.outbox(),headers)
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_versions"),versions)
        try seed("staged");try stage();let work=try n("SELECT COUNT(*) FROM personal_sync_work")
        XCTAssertGreaterThan(work,0)
        XCTAssertThrowsError(try SyncOutgoingWorkQueue.discardForCollection(queue.database,scope:queue.catalog.scope))
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),work);XCTAssertNotNil(try store.get("staged"))
    }
    func testNativeCollectionRetiresThirteenKindsRawStagedOriginalsAndOrphansWithoutEcho()throws {
        try install();try seedGraph();_=try finish()
        let all=try records();XCTAssertEqual(Set(all.map(\.identity.table)),Set(SyncCanonicalTable.allCases))
        let originals=try SyncOriginalEvidenceStore.install(cache:cache)
        let source=try XCTUnwrap(all.first {if case .source(let body)=$0.body {return body.text=="Alice owns Orion."};return false})
        _=try originals.prepare(source.reference,pathsFor:{_,_ in [:]},admit:{_ in},admitMedia:{_,_,_ in})
        XCTAssertGreaterThan(try n("SELECT COUNT(*) FROM personal_sync_evidence"),0)
        let publications=try SyncPublicationQueue.install(cache:cache),turn=try XCTUnwrap(all.first {$0.identity.table == .turn})
        try publications.stage(turn.identity,reason:.policyDenied)
        XCTAssertGreaterThan(try n("SELECT COUNT(*) FROM personal_sync_publication_jobs"),0)
        try writeNativeMedia("images/owned-retained");try writeNativeMedia("audio/nested/owned-orphan")
        try store.insert(Memory(id:"unprepared-media",text:"Owned unprepared source",imagePath:"images/owned-retained"))
        try seed("staged","Owned staged source");try stage()
        XCTAssertGreaterThan(try n("SELECT COUNT(*) FROM personal_sync_work"),0)
        try seed("raw","Owned never assigned source");XCTAssertGreaterThan(try n("SELECT COUNT(*) FROM personal_sync_changes"),0)
        let headers=try cache.journal.outbox(),(a,ac,folder)=try nativeControlProducer("native-all")
        defer {try? a.close();folder.close()};let control=try publishNativeControl(a,ac,folder)
        try captureNativeCollectionFixture("all-before")
        let receiver=SyncNativeCollectionReceiver(library:store,cache:cache,inbox:folder)
        XCTAssertEqual(try receiver.receive(creator:nativePeer,counter:control.counter),.applied)
        try assertNativeCollectionEmpty()
        XCTAssertEqual(try cache.journal.outbox(),headers)
        for operation in headers {XCTAssertTrue(try cache.journal.state(for:operation.key).isDeleted)}
        XCTAssertEqual(try cache.journal.cursor(for:nativePeer),0)
        XCTAssertEqual(try n("SELECT counter FROM personal_sync_collection_local"),0)
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_collection_controls"),0)
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_evidence"),0);XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_evidence_state"),0)
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_publication_jobs"),0);XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_publication_dependencies"),0)
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_publication_bindings"),0);try publications.checkAccounting()
        XCTAssertThrowsError(try publications.context())
        XCTAssertTrue(try store.hasPendingLibraryWipeCleanup());XCTAssertEqual(try n("SELECT COUNT(*) FROM erasure_assets"),2)
        XCTAssertEqual(try store.resumePendingMediaCleanup().disposition,.libraryWipe)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("images/owned-retained")),Data("images/owned-retained".utf8))
        try captureNativeCollectionFixture("all-committed-pending")
        try store.close();store=try MemoryStore(root:root);try install()
        XCTAssertTrue(try store.hasPendingLibraryWipeCleanup());XCTAssertEqual(try n("SELECT COUNT(*) FROM erasure_assets"),2)
        try writeNativeMedia("video/later");try seed("owned","Owned later replacement");_=try finish()
        let fresh=try XCTUnwrap(records().first);XCTAssertEqual(try cache.journal.outbox().last?.creationEra?[nativePeer],control.counter)
        XCTAssertFalse(headers.contains {$0.key == (try? fresh.identity.key)})
        let reopened=SyncNativeCollectionReceiver(library:store,cache:cache,inbox:folder)
        XCTAssertEqual(try reopened.receive(creator:nativePeer,counter:control.counter),.unchanged)
        XCTAssertNotNil(try store.get("owned"))
        let cleaned=try store.retryLibraryWipeCleanup();XCTAssertTrue(cleaned.cleanupComplete);XCTAssertEqual(cleaned.erasure.removedMedia,2)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("video/later")),Data("video/later".utf8));XCTAssertFalse(try store.hasPendingLibraryWipeCleanup())
        XCTAssertEqual(try n("SELECT counter FROM personal_sync_collection_local"),0)
        try captureNativeCollectionFixture("all-later-cleaned")
    }
    func testNativeCollectionFailureRollsBackReceiptRegistersQueuesAndNativeMediaThenRetries()throws {
        try install();try seedGraph();_=try finish();try writeNativeMedia("images/keep")
        try seed("staged");try stage();try seed("raw")
        let before=try frames(),headers=try cache.journal.outbox(),raw=try n("SELECT COUNT(*) FROM personal_sync_changes"),work=try n("SELECT COUNT(*) FROM personal_sync_work"),versions=try n("SELECT COUNT(*) FROM personal_sync_versions")
        let(a,ac,folder)=try nativeControlProducer("native-rollback");defer {try? a.close();folder.close()}
        let control=try publishNativeControl(a,ac,folder),receiver=SyncNativeCollectionReceiver(library:store,cache:cache,inbox:folder)
        try sql("CREATE TRIGGER owned_native_abort BEFORE DELETE ON memories BEGIN SELECT RAISE(ABORT,'Owned injected native phase failure'); END")
        try captureNativeCollectionFixture("rollback-before")
        XCTAssertThrowsError(try receiver.receive(creator:nativePeer,counter:control.counter))
        XCTAssertEqual(try frames(),before);XCTAssertEqual(try cache.journal.outbox(),headers)
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_changes"),raw);XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),work)
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_versions"),versions)
        XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_collection_received_controls"),0);XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_collection_frontier"),0)
        XCTAssertEqual(try n("SELECT COUNT(*) FROM erasure_assets"),0);XCTAssertFalse(try store.hasPendingLibraryWipeCleanup())
        for operation in headers {XCTAssertFalse(try cache.journal.state(for:operation.key).isDeleted)}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("images/keep")),Data("images/keep".utf8))
        try captureNativeCollectionFixture("rollback-after-failure")
        try sql("DROP TRIGGER owned_native_abort")
        XCTAssertEqual(try receiver.receive(creator:nativePeer,counter:control.counter),.applied);try assertNativeCollectionEmpty()
        XCTAssertTrue(try store.retryLibraryWipeCleanup().cleanupComplete)
        try captureNativeCollectionFixture("rollback-retried-cleaned")
    }
    func testNativeCollectionOlderAndRepeatedControlsPreserveLaterLifetimesAndFreshMedia()throws {
        try install();try seed();_=try finish()
        let(a,ac,folder)=try nativeControlProducer("native-order");defer {try? a.close();folder.close()}
        let first=try publishNativeControl(a,ac,folder),latest=try publishNativeControl(a,ac,folder)
        let receiver=SyncNativeCollectionReceiver(library:store,cache:cache,inbox:folder)
        XCTAssertEqual(try receiver.receive(creator:nativePeer,counter:latest.counter),.applied)
        XCTAssertTrue(try store.retryLibraryWipeCleanup().cleanupComplete)
        try seed("owned","Owned after latest control");_=try finish();try writeNativeMedia("audio/later-orphan")
        let headers=try cache.journal.outbox()
        XCTAssertEqual(try receiver.receive(creator:nativePeer,counter:first.counter),.unchanged)
        XCTAssertEqual(try receiver.receive(creator:nativePeer,counter:latest.counter),.unchanged)
        XCTAssertEqual(try store.get("owned")?.text,"Owned after latest control");XCTAssertEqual(try cache.journal.outbox(),headers)
        XCTAssertFalse(try store.hasPendingLibraryWipeCleanup());XCTAssertEqual(try n("SELECT COUNT(*) FROM erasure_assets"),0)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("audio/later-orphan")),Data("audio/later-orphan".utf8))
        XCTAssertEqual(try n("SELECT counter FROM personal_sync_collection_local"),0)
        try captureNativeCollectionFixture("older-controls-later-retained")
    }
}
