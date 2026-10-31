import XCTest
import CSQLite
@testable import OSwindCore

/// Authored archival data through the trusted restore primitive. This does not
/// stand in for the unfinished incoming source/recap graph adapter or transport.
final class HistoricalRecapTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    let origin="00000000-0000-0000-0000-000000004001"
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-historical-recap-"+UUID().uuidString);store=try MemoryStore(root:root.appendingPathComponent("library"))}
    override func tearDownWithError() throws {try store.close();store=nil;try FileManager.default.removeItem(at:root)}
    func archived(_ id:String,_ text:String,parents:[HistoricalEvidence]=[]) throws -> HistoricalEvidence {
        var original=Memory(id:id,timestamp:Date(timeIntervalSince1970:1700000000),kind:parents.isEmpty ? .note:.summary,app:"Owned",title:id,text:text)
        if !parents.isEmpty {original.recap = .init(provider:"owned",sources:parents.map {.init(id:$0.sourceID,revision:$0.memory.evidenceHash,match:"owned",score:1,passage:.init(start:0,length:4))})}
        var current=Memory(id:id,timestamp:original.timestamp,kind:original.kind,app:"Owned",title:"Current "+id,text:"Current changed body for "+id)
        current.favorite=true;try store.insert(current)
        let body=try SyncSourceBody(memory:original,origin:origin,media:[]) {requested,_ in try XCTUnwrap(parents.first {$0.sourceID==requested}).reference}
        let record=try SyncPortableRecord(identity:.init(table:.source,origin:origin,lifetime:UUID().uuidString.lowercased()),body:.source(body))
        return try store.withRoutineDatabase {db in
            let history=HistoricalEvidenceStore(database:db),handle=UUID().uuidString.lowercased()
            try history.insert(handle:handle,source:id,record:record,paths:[:],parents:parents)
            return try history.read(handle,sourceID:id,verifyMedia:{_,_,_ in})
        }
    }
    func graph() throws -> (HistoricalEvidence,HistoricalEvidence,HistoricalEvidence) {
        let leaf=try archived("leaf","Original Alice owns Orion."),first=try archived("recap","Original first recap.",parents:[leaf]),second=try archived("nested","Original nested recap.",parents:[first,leaf])
        return(leaf,first,second)
    }
    func linked(_ parent:HistoricalEvidence) throws -> Memory {
        var memory=Memory(id:"canonical-linked",kind:.summary,app:"Owned",title:"Linked",text:"Independent canonical recap linked to an original.")
        var source=RecapSource(id:parent.sourceID,revision:parent.memory.evidenceHash,match:"owned",score:2,passage:.init(start:0,length:4));source.historicalHandle=parent.handle
        memory.recap = .init(provider:"owned",sources:[source])
        // Only an authenticated typed adapter or validated quiet restore may use
        // this internal path. Ordinary insert explicitly refuses these links.
        XCTAssertThrowsError(try store.insert(memory))
        try store.insertRestoringRecap(memory);try store.rebuildRecapLinks();return memory
    }
    func testNestedOriginalCardsOpenExactParentsAcrossRestartAndQuietRestore() throws {
        let (leaf,first,second)=try graph(),canonical=try linked(second)
        let cards=try store.recapSourceCards(second.memory)
        XCTAssertEqual(cards.map(\.id),[first.memory.id,leaf.memory.id]);XCTAssertEqual(cards.map(\.historicalHandle),[first.handle,leaf.handle])
        XCTAssertEqual(try store.recapSourceMemory(cards[0]),first.memory)
        XCTAssertEqual(try store.recapSourceMemory(cards[1]).text,leaf.memory.text)
        XCTAssertEqual(try store.recapEvidence(canonical.id).first?.memory,second.memory)
        try store.close();store=try MemoryStore(root:root.appendingPathComponent("library"))
        XCTAssertEqual(try store.recapSourceCards(second.memory).map(\.historicalHandle),[first.handle,leaf.handle])
        let archive=root.appendingPathComponent("copy.oswindbackup"),destination=root.appendingPathComponent("copy")
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:destination)
        let copy=try MemoryStore(root:destination);defer {try? copy.close()}
        XCTAssertEqual(try copy.recapSourceCards(second.memory).map(\.historicalHandle),cards.map(\.historicalHandle))
        XCTAssertEqual(try copy.recapSourceMemory(cards[0]),first.memory)
        XCTAssertEqual(try copy.recapEvidence(canonical.id).first?.memory,second.memory)
        XCTAssertEqual(try copy.get("leaf")?.text,"Current changed body for leaf")
        try copy.withRoutineDatabase {db in
            let row=try db.statement("SELECT source_id,owner_id,historical_handle FROM recap_sources WHERE recap_id='canonical-linked'");defer {sqlite3_finalize(row)}
            XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_type(row,0),SQLITE_NULL);XCTAssertEqual(db.text(row,1),second.sourceID);XCTAssertEqual(db.text(row,2),second.handle)
            let authorities=try db.statement("SELECT count(*) FROM sqlite_master WHERE name LIKE 'personal_sync_local'");defer {sqlite3_finalize(authorities)};XCTAssertEqual(sqlite3_step(authorities),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(authorities,0),0)
        }
    }
    func testAncestorErasureInvalidatesArchivedGraphCanonicalRecapAndStaleCards() throws {
        let (leaf,_,second)=try graph(),canonical=try linked(second),cards=try store.recapSourceCards(second.memory)
        let other=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? other.close()}
        _=try other.delete("leaf")
        XCTAssertThrowsError(try store.historicalMemory(leaf.handle));XCTAssertThrowsError(try store.historicalMemory(second.handle))
        XCTAssertThrowsError(try store.recapSourceCards(second.memory));XCTAssertThrowsError(try store.recapSourceMemory(cards[0]));XCTAssertNil(try store.get(canonical.id))
        XCTAssertNotNil(try store.get("recap"));XCTAssertNotNil(try store.get("nested"))
        try store.insert(Memory(id:"leaf",text:"Replacement with the same local ID"))
        XCTAssertThrowsError(try store.recapSourceMemory(cards[1]));XCTAssertThrowsError(try store.historicalMemory(leaf.handle))
    }
    func testFavoriteAndTagsKeepOriginalButSourceRevisionPurgesIt() throws {
        let (_,_,second)=try graph();try store.setFavorite("leaf",value:false);try store.setTags("leaf",tags:["Owned tag"])
        XCTAssertEqual(try store.historicalMemory(second.handle),second.memory)
        var leaf=try XCTUnwrap(store.get("leaf"));leaf.text="Revised current source";try store.insert(leaf)
        XCTAssertThrowsError(try store.recapSourceCards(second.memory))
    }
    func testForgedHistoricalHandleRevisionAndPassageCannotNavigateOrHydrate() throws {
        let (_,_,second)=try graph(),card=try XCTUnwrap(store.recapSourceCards(second.memory).first)
        var stale=second.memory;stale.recap!.sources[0].historicalHandle=UUID().uuidString.lowercased()
        XCTAssertThrowsError(try store.recapSourceCards(stale));XCTAssertThrowsError(try store.insert(second.memory))
        var bad=card;bad.historicalHandle=UUID().uuidString.lowercased();XCTAssertThrowsError(try store.recapSourceMemory(bad))
        bad=card;bad.historicalHandle=nil;XCTAssertThrowsError(try store.recapSourceMemory(bad))
        let wrong=RecapSourceCard(id:card.id,title:card.title,app:card.app,revision:"wrong",timestamp:card.timestamp,passage:card.passage,historicalHandle:card.historicalHandle)
        XCTAssertThrowsError(try store.recapSourceMemory(wrong))
        let outOfRange=RecapSourceCard(id:card.id,title:card.title,app:card.app,revision:card.revision,timestamp:card.timestamp,passage:.init(start:1_000_000,length:20),historicalHandle:card.historicalHandle)
        XCTAssertThrowsError(try store.recapSourceMemory(outOfRange))
    }
    func testOrdinaryMetadataDoesNotDecodeArchivalPayloadWhenNoOriginalExists() throws {
        let source=Memory(id:"ordinary",text:"Owned ordinary payload");try store.insert(source)
        try store.withRoutineDatabase {db in
            XCTAssertEqual(sqlite3_create_function_v2(db.handle,"oswind_sync_source_revision_v1",1,SQLITE_UTF8|SQLITE_INNOCUOUS,nil,{context,_,_ in sqlite3_result_error(context,"Owned decoder must not be called",-1)},nil,nil,nil),SQLITE_OK)
            // No archival row exists for this owner; the indexed existence gate
            // prevents parsing every ordinary source body on a metadata write.
            try store.setFavorite("ordinary",value:true)
        }
        XCTAssertEqual(try store.get("ordinary")?.favorite,true)
    }

    func testLateMediaAdmissionCannotEraseAnAlreadyCheckedAncestorOrRetargetItsEdges() throws {
        let (leaf,_,second)=try graph()
        for mode in ["erase-owner","remove-edge"] {
            var reached=false
            XCTAssertThrowsError(try store.withRoutineDatabase {db in
                try HistoricalEvidenceStore(database:db).read(second.handle,verifyMedia:{reference,_,_ in
                    if !reached,reference == (try leaf.reference) {
                        reached=true
                        if mode=="erase-owner" {try db.execute("DELETE FROM memories WHERE id='nested'")}
                        else {
                            let row=try db.statement("DELETE FROM historical_evidence_dependencies WHERE child=?");defer {sqlite3_finalize(row)};db.bind(row,1,second.handle);try db.done(row)
                        }
                    }
                })
            })
            XCTAssertTrue(reached);XCTAssertNotNil(try store.get("nested"))
            XCTAssertEqual(try store.historicalMemory(second.handle),second.memory)
        }
    }
    func testRecursiveAdoptionBudgetRollsBackPartiallyCopiedParentsAndRetainsCacheAuthority() throws {
        let (leaf,first,second)=try graph()
        let cache=try store.withRoutineDatabase {db -> SyncVersionStore in
            _=try SyncChangeCapture.activate(db);let catalog=try SyncIdentityCatalog.install(db)
            let journal=try SyncJournal.install(database:db,replica:"00000000-0000-0000-0000-000000004011",group:"00000000-0000-0000-0000-000000004012",epoch:"00000000-0000-0000-0000-000000004013")
            let cache=try SyncVersionStore.install(catalog:catalog,journal:journal)
            for value in [leaf,first,second] {
                try catalog.applyPeer(value.record.identity,primary:[.text(Data(value.sourceID.utf8))]) {}
                _=try journal.put(key:value.record.identity.key,content:value.reference.content) {_ in _=try cache.retain(value.record,admit:{_ in})}
            }
            try db.execute("DELETE FROM historical_evidence")
            let leafCost=256+(try leaf.record.encoded().count)+4
            try db.execute("UPDATE historical_evidence_state SET budget=\(leafCost) WHERE singleton=1")
            return cache
        }
        let operations=try cache.journal.outbox();var copiedParentObserved=false
        XCTAssertThrowsError(try store.withRoutineDatabase {db in
            try HistoricalEvidenceStore(database:db).adopt(second.reference,cache:cache,pathsFor:{reference,_ in
                if reference == (try first.reference) {XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM historical_evidence"),1);copiedParentObserved=true}
                return [:]
            },admit:{_ in},verifyMedia:{_,_,_ in})
        })
        XCTAssertTrue(copiedParentObserved)
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM historical_evidence"),0);XCTAssertEqual(try db.eraseCount("SELECT used_bytes FROM historical_evidence_state"),0)
            try HistoricalEvidenceStore(database:db).checkAccounting()
            try db.execute("UPDATE historical_evidence_state SET budget=268435456 WHERE singleton=1")
            let copy=try HistoricalEvidenceStore(database:db).adopt(second.reference,cache:cache,pathsFor:{_,_ in [:]},admit:{_ in},verifyMedia:{_,_,_ in})
            XCTAssertEqual(copy.memory.text,second.memory.text);XCTAssertNotEqual(copy.handle,second.handle);XCTAssertEqual(try copy.reference,try second.reference)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM historical_evidence"),3)
        }
        XCTAssertEqual(try cache.journal.outbox(),operations)
    }

}
