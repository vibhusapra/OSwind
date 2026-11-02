import XCTest
import CSQLite
@testable import OSwindCore

func snapshotNativeCollectionBefore(_ store:MemoryStore,to url:URL)throws {
    try store.withRoutineDatabase {db in
        guard sqlite3_get_autocommit(db.handle) != 0 else {throw OSwindError.invalid("Snapshot committed authored collection data")}
        var output:OpaquePointer?
        guard !FileManager.default.fileExists(atPath:url.path),sqlite3_open(url.path,&output)==SQLITE_OK,let output else {throw OSwindError.database("Cannot open fresh owned snapshot")}
        defer {sqlite3_close(output)}
        guard let backup=sqlite3_backup_init(output,"main",db.handle,"main") else {throw OSwindError.database("Cannot start owned collection snapshot")}
        let step=sqlite3_backup_step(backup,-1),end=sqlite3_backup_finish(backup)
        guard step==SQLITE_DONE,end==SQLITE_OK else {throw OSwindError.database("Owned collection snapshot did not finish")}
    }
}

extension SyncIncomingSourceTests {
    func testNativeCollectionRetiresCompletedRealPublicationBindingAndPreservesPeerCursor()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            _=try queueRetry(f.ac,service)
            XCTAssertEqual(try count(f.b,"personal_sync_publication_bindings"),1);XCTAssertEqual(try count(f.b,"chat_turns"),1)
            let cursor=try f.bc.journal.cursor(for:producerID),headers=try f.bc.journal.outbox()
            try snapshotNativeCollectionBefore(f.b,to:root.appendingPathComponent("before-control.sqlite"))
            _=try f.a.wipeLibrary()
            let control=try f.a.withRoutineDatabase {db in
                let history=SyncCollectionHistory(database:db,replica:producerID)
                guard case .needsGroupReview(let proposal)=try history.reviewState(journal:f.ac.journal) else {throw OSwindError.invalid("Owned completed-publication fixture has no review")}
                return try history.approveGroupErase(journal:f.ac.journal,counter:proposal.counter,expectedEra:proposal.era)
            }
            try f.inbox.publishCollectionControl(control)
            let receiver=SyncNativeCollectionReceiver(library:f.b,cache:f.bc,inbox:f.inbox)
            XCTAssertEqual(try receiver.receive(creator:producerID,counter:control.counter),.applied)
            for table in ["personal_sync_publication_bindings","personal_sync_publication_jobs","personal_sync_publication_dependencies","memories","chat_turns","chat_sessions","personal_sync_versions"] {XCTAssertEqual(try count(f.b,table),0,table)}
            XCTAssertEqual(try f.bc.journal.cursor(for:producerID),cursor);XCTAssertEqual(try f.bc.journal.outbox(),headers)
            XCTAssertEqual(try f.b.withRoutineDatabase {try $0.eraseCount("SELECT counter FROM personal_sync_collection_local")},0)
            try f.queue.checkAccounting();XCTAssertThrowsError(try f.queue.context());XCTAssertThrowsError(try queueRetry(f.ac,service))
            XCTAssertTrue(try f.b.hasPendingLibraryWipeCleanup());XCTAssertTrue(try f.b.retryLibraryWipeCleanup().cleanupComplete)
        }
    }
}

extension SyncIncomingSourceTests {
    func testNativeCollectionAfterLocalWipeRetiresInvalidatedPublicationQueueWithoutApprovingOwnWipe()throws {
        try withQueueFixture {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            _=try queueRetry(f.ac,service)
            XCTAssertEqual(try count(f.b,"personal_sync_publication_bindings"),1)
            _=try f.b.wipeLibrary();XCTAssertThrowsError(try f.queue.context())
            try f.b.insert(Memory(id:"fresh-after-local",text:"Owned after local-only clear"))
            try snapshotNativeCollectionBefore(f.b,to:root.appendingPathComponent("before-control.sqlite"))
            _=try f.a.wipeLibrary()
            let control=try f.a.withRoutineDatabase {db in
                let history=SyncCollectionHistory(database:db,replica:producerID)
                guard case .needsGroupReview(let proposal)=try history.reviewState(journal:f.ac.journal) else {throw OSwindError.invalid("Owned local-clear fixture has no producer review")}
                return try history.approveGroupErase(journal:f.ac.journal,counter:proposal.counter,expectedEra:proposal.era)
            }
            try f.inbox.publishCollectionControl(control)
            XCTAssertEqual(try SyncNativeCollectionReceiver(library:f.b,cache:f.bc,inbox:f.inbox).receive(creator:producerID,counter:control.counter),.applied)
            XCTAssertNil(try f.b.get("fresh-after-local"));try f.queue.checkAccounting()
            XCTAssertEqual(try count(f.b,"personal_sync_publication_bindings"),0)
            XCTAssertEqual(try f.b.withRoutineDatabase {try $0.eraseCount("SELECT counter FROM personal_sync_collection_local")},1)
            XCTAssertEqual(try count(f.b,"personal_sync_collection_approvals"),0)
            try f.b.withRoutineDatabase {db in
                let history=SyncCollectionHistory(database:db,replica:receiverID)
                guard case .needsGroupReview(let proposal)=try history.reviewState(journal:f.bc.journal) else {return XCTFail("Received erasure must not approve this Mac's local wipe")}
                XCTAssertEqual(proposal.counter,1)
            }
            XCTAssertTrue(try f.b.retryLibraryWipeCleanup().cleanupComplete)
        }
    }
}

extension HistoricalErasureScopeTests {
    func testNativeCollectionErasesUnpreparedNativeArchivedOriginalAndItsDependents()throws {
        let f=try fixture("native-archive")
        let replica="00000000-0000-0000-0000-000000008201",peer="00000000-0000-0000-0000-000000008202",group="00000000-0000-0000-0000-000000008203",epoch="00000000-0000-0000-0000-000000008204"
        func cache(_ store:MemoryStore,_ replica:String)throws->SyncVersionStore {
            try store.withRoutineDatabase {db in
                _=try SyncChangeCapture.activate(db)
                let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch)
                return try SyncVersionStore.install(catalog:catalog,journal:journal)
            }
        }
        let bc=try cache(f.store,replica),a=try MemoryStore(root:root.appendingPathComponent("archive-control-producer"));stores.append(a)
        let ac=try cache(a,peer);try bc.journal.allowPeer(peer)
        XCTAssertEqual(try f.store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM historical_evidence")},1)
        XCTAssertEqual(try f.store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM personal_sync_identities")},0)
        try snapshotNativeCollectionBefore(f.store,to:root.appendingPathComponent("before-control.sqlite"))
        _=try a.wipeLibrary()
        let control=try a.withRoutineDatabase {db in
            let history=SyncCollectionHistory(database:db,replica:peer)
            guard case .needsGroupReview(let proposal)=try history.reviewState(journal:ac.journal) else {throw OSwindError.invalid("Owned archive fixture has no review")}
            return try history.approveGroupErase(journal:ac.journal,counter:proposal.counter,expectedEra:proposal.era)
        }
        let folder=try SyncObjectFolder.create(at:root.appendingPathComponent("archive-control-transport"),secret:SyncGroupSecret(),group:group,epoch:epoch);defer {folder.close()}
        try folder.publishCollectionControl(control)
        XCTAssertEqual(try SyncNativeCollectionReceiver(library:f.store,cache:bc,inbox:folder).receive(creator:peer,counter:control.counter),.applied)
        for table in ["historical_evidence","memories","recap_sources","chat_turns","chat_sources","chat_sessions"] {XCTAssertEqual(try f.store.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM "+table)},0,table)}
        XCTAssertEqual(try f.store.withRoutineDatabase {try $0.eraseCount("SELECT counter FROM personal_sync_collection_local")},0)
        XCTAssertTrue(try f.store.retryLibraryWipeCleanup().cleanupComplete)
    }
}
