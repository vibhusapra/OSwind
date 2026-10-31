import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    private func identityLookupPlan(_ db:RoutineDatabase)throws->String {
        let row=try db.statement("EXPLAIN QUERY PLAN SELECT object_digest FROM personal_sync_identities WHERE table_name='routine_runs' AND local_key=?")
        defer {sqlite3_finalize(row)};sqlite3_bind_zeroblob(row,1,32);var lines=[String](),code=sqlite3_step(row)
        while code==SQLITE_ROW {lines.append(db.text(row,3));code=sqlite3_step(row)}
        guard code==SQLITE_DONE else {throw db.error()};return lines.joined(separator:"\n")
    }
    private func requireIdentityLookupIndex(_ db:RoutineDatabase)throws {
        let plan=try identityLookupPlan(db)
        XCTAssertTrue(plan.contains("SEARCH personal_sync_identities USING COVERING INDEX sync_identities_local"),plan)
        XCTAssertFalse(plan.contains("SCAN personal_sync_identities"),plan)
    }
    func testMutationCostNativeDeletionUsesIndexedIdentityLookup()throws {
        let (store,_)=try endpoint("owned",producerID);defer {try? store.close()}
        try store.withRoutineDatabase {try requireIdentityLookupIndex($0)}
    }
    func testMutationCostLegacyCatalogAddsIndexWithoutChangingLifetimesOrJournal()throws {
        let (store,cache)=try endpoint("owned",producerID);defer {try? store.close()}
        let chat=try store.createChat(title:"Preserve exact index migration state");try drain(store,cache)
        let identity=try cache.catalog.localIdentity(.conversation,primary:[.text(Data(chat.id.utf8))])
        let before=try cache.journal.outbox(),packet=try cache.resolve(identity,content:nil,admit:{_ in})
        try store.withRoutineDatabase {db in
            try db.execute("DROP INDEX IF EXISTS sync_identities_local")
            for _ in 0..<2 {let installed=try SyncIdentityCatalog.install(db);XCTAssertEqual(installed.scope,cache.catalog.scope);try requireIdentityLookupIndex(db)}
        }
        XCTAssertEqual(try cache.catalog.localIdentity(.conversation,primary:[.text(Data(chat.id.utf8))]),identity)
        XCTAssertEqual(try cache.journal.outbox(),before);XCTAssertEqual(try cache.resolve(identity,content:nil,admit:{_ in}),packet)
        XCTAssertEqual(try count(store,"personal_sync_changes"),0)
    }
    func testMutationCostAlteredIdentityIndexRefusesUntilExplicitRepair()throws {
        let (store,cache)=try endpoint("owned",producerID);defer {try? store.close()}
        let chat=try store.createChat(title:"Owned altered index");try drain(store,cache)
        let identity=try cache.catalog.localIdentity(.conversation,primary:[.text(Data(chat.id.utf8))]),before=try cache.journal.outbox()
        try store.withRoutineDatabase {db in
            try db.execute("DROP INDEX IF EXISTS sync_identities_local; CREATE INDEX sync_identities_local ON personal_sync_identities(origin)")
            XCTAssertThrowsError(try cache.catalog.object(identity))
            XCTAssertThrowsError(try SyncIdentityCatalog.install(db))
            XCTAssertThrowsError(try MemoryStore(root:store.root))
            try db.execute("DROP INDEX sync_identities_local");_=try SyncIdentityCatalog.install(db);try requireIdentityLookupIndex(db)
        }
        XCTAssertEqual(try cache.catalog.localIdentity(.conversation,primary:[.text(Data(chat.id.utf8))]),identity)
        XCTAssertEqual(try cache.journal.outbox(),before);XCTAssertEqual(try count(store,"personal_sync_changes"),0)
    }
    func testMutationCostReopenUpgradesInstalledCatalogWithoutChangingItsState()throws {
        let (store,cache)=try endpoint("owned",producerID)
        let chat=try store.createChat(title:"Owned legacy reopen");try drain(store,cache)
        let identity=try cache.catalog.localIdentity(.conversation,primary:[.text(Data(chat.id.utf8))]),before=try cache.journal.outbox(),scope=cache.catalog.scope,path=store.root
        try store.withRoutineDatabase {try $0.execute("DROP INDEX sync_identities_local")};try store.close()
        let reopened=try MemoryStore(root:path);defer {try? reopened.close()}
        try reopened.withRoutineDatabase {db in
            try requireIdentityLookupIndex(db)
            let catalog=SyncIdentityCatalog(database:db,scope:scope),journal=try SyncJournal(database:db,replica:producerID,group:group,epoch:epoch)
            XCTAssertEqual(try catalog.object(identity)?.identity,identity);XCTAssertEqual(try journal.outbox(),before)
            XCTAssertEqual(try db.eraseCount("SELECT enabled FROM personal_sync_capture"),1)
        }
        XCTAssertEqual(try count(reopened,"personal_sync_changes"),0)
    }
    func testMutationCostOrdinaryReopenDoesNotCreateOrEnableIdentityCatalog()throws {
        let path=root.appendingPathComponent("ordinary"),store=try MemoryStore(root:path);try store.close()
        let reopened=try MemoryStore(root:path);defer {try? reopened.close()}
        try reopened.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM sqlite_master WHERE name IN ('personal_sync_identities','sync_identities_local')"),0)
            XCTAssertEqual(try db.eraseCount("SELECT enabled FROM personal_sync_capture"),0)
        }
    }
}
