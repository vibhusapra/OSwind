import XCTest
import CSQLite
@testable import OSwindCore

extension SyncOutgoingTests {
    func serviceFixtureControl(_ service:SyncLibraryService)throws->SyncCollectionControl {
        _=try service.library.wipeLibrary()
        return try service.library.withRoutineDatabase {db in
            let history=SyncCollectionHistory(database:db,replica:service.cache.journal.replica)
            guard case .needsGroupReview(let proposal)=try history.reviewState(journal:service.cache.journal) else {throw OSwindError.invalid("Owned service fixture has no local wipe review")}
            return try history.approveGroupErase(journal:service.cache.journal,counter:proposal.counter,expectedEra:proposal.era)
        }
    }

    func testServiceRenewalRequiresActualNativeErasureInsteadOfGenericControlReceipt()throws {
        try seedGraph()
        try withServicePair {f in
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64)
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),3)
            XCTAssertEqual(try serviceCount(f.receiver,"personal_sync_publication_bindings"),1)
            try f.b.stop()
            let control=try serviceFixtureControl(f.a)
            try f.transport.publishCollectionControl(control)
            // This authenticated generic callback retires publication metadata
            // only. It deliberately leaves every native source/answer intact.
            let receiver=SyncCollectionReceiver(library:f.receiver,cache:f.b.cache,inbox:f.transport,retire:{_,_ in
                try SyncPublicationQueue.retireCollectionIfInstalled(cache:f.b.cache)
            })
            XCTAssertEqual(try receiver.receive(creator:replica,counter:control.counter),.applied)
            XCTAssertFalse(try f.receiver.hasPendingLibraryWipeCleanup())
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),3)
            XCTAssertEqual(try serviceCount(f.receiver,"chat_turns"),1)
            XCTAssertEqual(try serviceCount(f.receiver,"personal_sync_publication_bindings"),0)
            XCTAssertThrowsError(try SyncPublicationQueue.renewAfterReceivedCollection(cache:f.b.cache,library:f.receiver,control:control),"A generic receipt must not impersonate completed native group retirement")
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-publication-library-lifetime-v1'")},0)
        }
    }

    func testServiceRenewalInvalidatesNativeCompletionWhenAnotherPeerOnlyRecordsGenericRetirement()throws {
        try seed()
        try withServicePair {f in
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64);try f.b.stop()
            let control=try serviceFixtureControl(f.a);try f.transport.publishCollectionControl(control)
            XCTAssertEqual(try SyncNativeCollectionReceiver(library:f.receiver,cache:f.b.cache,inbox:f.transport).receive(creator:replica,counter:control.counter),.applied)
            XCTAssertTrue(try f.receiver.retryLibraryWipeCleanup().cleanupComplete)
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-native-collection-completion-v1'")},1)
            let third="00000000-0000-0000-0000-000000009604"
            let storeC=try MemoryStore(root:root.appendingPathComponent("owned-third-collection"));defer {try? storeC.close()}
            let journal=try storeC.withRoutineDatabase {db in
                _=try SyncChangeCapture.activate(db)
                return try SyncJournal.install(database:db,replica:third,group:group,epoch:epoch)
            }
            try f.receiver.withRoutineDatabase {_ in try f.b.cache.journal.allowPeer(third)}
            _=try storeC.wipeLibrary()
            let other=try storeC.withRoutineDatabase {db in
                let history=SyncCollectionHistory(database:db,replica:third)
                guard case .needsGroupReview(let proposal)=try history.reviewState(journal:journal) else {throw OSwindError.invalid("Owned third peer has no review")}
                return try history.approveGroupErase(journal:journal,counter:proposal.counter,expectedEra:proposal.era)
            }
            try f.transport.publishCollectionControl(other)
            let failing=SyncCollectionReceiver(library:f.receiver,cache:f.b.cache,inbox:f.transport,retire:{_,_ in throw OSwindError.invalid("Owned generic retirement rollback")})
            XCTAssertThrowsError(try failing.receive(creator:third,counter:other.counter))
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-native-collection-completion-v1'")},1,"Failed retirement must restore the prior completion with its frontier")
            let receiver=SyncCollectionReceiver(library:f.receiver,cache:f.b.cache,inbox:f.transport,retire:{_,_ in try SyncPublicationQueue.retireCollectionIfInstalled(cache:f.b.cache)})
            XCTAssertEqual(try receiver.receive(creator:third,counter:other.counter),.applied)
            // The old A control is still known on its own clock axis. It cannot
            // reuse its completion across this later, unretired C frontier.
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-native-collection-completion-v1'")},0)
            XCTAssertThrowsError(try SyncPublicationQueue.renewAfterReceivedCollection(cache:f.b.cache,library:f.receiver,control:control))
            XCTAssertThrowsError(try SyncPublicationQueue.renewAfterReceivedCollection(cache:f.b.cache,library:f.receiver,control:other))
        }
    }

    func testServiceNativeCompletionConsumptionAndPublicationRenewalRollBackTogether()throws {
        try seed()
        try withServicePair {f in
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64)
            let oldQueue=try f.receiver.withRoutineDatabase {_ in try SyncPublicationQueue.install(cache:f.b.cache)}
            try f.b.stop()
            let control=try serviceFixtureControl(f.a);try f.transport.publishCollectionControl(control)
            XCTAssertEqual(try SyncNativeCollectionReceiver(library:f.receiver,cache:f.b.cache,inbox:f.transport).receive(creator:replica,counter:control.counter),.applied)
            XCTAssertThrowsError(try SyncPublicationQueue.renewAfterReceivedCollection(cache:f.b.cache,library:f.receiver,control:control))
            XCTAssertTrue(try f.receiver.retryLibraryWipeCleanup().cleanupComplete)
            var reached=false
            XCTAssertThrowsError(try f.receiver.withRoutineDatabase {db in
                try SyncChangeCapture.transaction(db) {
                    try SyncPublicationQueue.renewAfterReceivedCollection(cache:f.b.cache,library:f.receiver,control:control)
                    XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-native-collection-completion-v1'"),0)
                    XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-publication-library-lifetime-v1'"),1)
                    reached=true;throw OSwindError.invalid("Owned rollback after renewal")
                }
            }) {XCTAssertEqual($0.localizedDescription,"Owned rollback after renewal")}
            XCTAssertTrue(reached)
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-native-collection-completion-v1'")},1)
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-publication-library-lifetime-v1'")},0)
            try SyncPublicationQueue.renewAfterReceivedCollection(cache:f.b.cache,library:f.receiver,control:control)
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-native-collection-completion-v1'")},0)
            XCTAssertThrowsError(try oldQueue.context())
            let fresh=try f.receiver.withRoutineDatabase {_ in try SyncPublicationQueue.install(cache:f.b.cache)}
            XCTAssertNoThrow(try fresh.context())
            // Even a later metadata-only invalidation cannot replay the consumed
            // completion. A new native retirement must create its own proof.
            try f.receiver.withRoutineDatabase {db in try SyncChangeCapture.transaction(db) {try SyncPublicationQueue.retireCollectionIfInstalled(cache:f.b.cache)}}
            XCTAssertThrowsError(try SyncPublicationQueue.renewAfterReceivedCollection(cache:f.b.cache,library:f.receiver,control:control))
        }
    }

    func testServiceLocalClearInvalidatesPriorReceivedNativeCompletion()throws {
        try seed()
        try withServicePair {f in
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64);try f.b.stop()
            let control=try serviceFixtureControl(f.a);try f.transport.publishCollectionControl(control)
            XCTAssertEqual(try SyncNativeCollectionReceiver(library:f.receiver,cache:f.b.cache,inbox:f.transport).receive(creator:replica,counter:control.counter),.applied)
            XCTAssertTrue(try f.receiver.retryLibraryWipeCleanup().cleanupComplete)
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-native-collection-completion-v1'")},1)
            _=try f.receiver.wipeLibrary()
            try f.receiver.withRoutineDatabase {db in
                let history=SyncCollectionHistory(database:db,replica:f.b.cache.journal.replica)
                guard case .needsGroupReview(let proposal)=try history.reviewState(journal:f.b.cache.journal) else {throw OSwindError.invalid("Owned receiver local clear has no review")}
                _=try history.approveGroupErase(journal:f.b.cache.journal,counter:proposal.counter,expectedEra:proposal.era)
                XCTAssertEqual(try history.reviewState(journal:f.b.cache.journal),.ready)
                XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-native-collection-completion-v1'"),0)
            }
            XCTAssertThrowsError(try SyncPublicationQueue.renewAfterReceivedCollection(cache:f.b.cache,library:f.receiver,control:control))
        }
    }

    func testServiceNativeCompletionSQLHooksInvalidateRawFrontierChangesAndRefuseMissingProtection()throws {
        try seed()
        try withServicePair {f in
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64);try f.b.stop()
            let control=try serviceFixtureControl(f.a);try f.transport.publishCollectionControl(control)
            XCTAssertEqual(try SyncNativeCollectionReceiver(library:f.receiver,cache:f.b.cache,inbox:f.transport).receive(creator:replica,counter:control.counter),.applied)
            XCTAssertTrue(try f.receiver.retryLibraryWipeCleanup().cleanupComplete)
            try f.receiver.withRoutineDatabase {db in
                XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-native-collection-completion-v1'"),1)
                // Bypass the Swift observer to exercise the installed boundary
                // used by an already-running older writer.
                let update=try db.statement("UPDATE personal_sync_collection_frontier SET counter=counter+1 WHERE replica=?");defer {sqlite3_finalize(update)};db.bind(update,1,replica);try db.done(update)
                XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM store_metadata WHERE key='sync-native-collection-completion-v1'"),0)
                try db.execute("DROP TRIGGER sync_collection_native_completion_update")
                XCTAssertThrowsError(try SyncCollectionHistory.requireNativeCompletionHooks(db))
            }
            XCTAssertThrowsError(try SyncPublicationQueue.renewAfterReceivedCollection(cache:f.b.cache,library:f.receiver,control:control))
        }
    }
}
