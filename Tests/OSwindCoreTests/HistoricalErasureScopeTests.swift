import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

/// Owned source versions installed through the trusted archival/restore
/// primitive. This does not stand in for an enrolled incoming sync service.
final class HistoricalErasureScopeTests:XCTestCase {
    var root:URL!,retained=false,stores=[MemoryStore]()
    let origin="00000000-0000-0000-0000-000000005101"
    override func setUpWithError() throws {
        if let path=ProcessInfo.processInfo.environment["OSWIND_TEST_HISTORICAL_ERASURE_SCOPE_ROOT"] {
            let base=URL(fileURLWithPath:path,isDirectory:true),fm=FileManager.default
            guard base.path==path,base.resolvingSymlinksInPath().path==path,base.standardizedFileURL.path==path,fm.fileExists(atPath:base.deletingLastPathComponent().path) else {throw OSwindError.invalid("Owned historical-erasure root must be absolute")}
            let marker=base.appendingPathComponent("owned-fixture")
            if !fm.fileExists(atPath:path) {try Paths.ensure(base);try Data("OSwind authored original-field erasure v1".utf8).write(to:marker,options:.withoutOverwriting)}
            guard try Data(contentsOf:marker)==Data("OSwind authored original-field erasure v1".utf8) else {throw OSwindError.invalid("Missing owned fixture marker")}
            let test=name.replacingOccurrences(of:"[^A-Za-z0-9_.-]",with:"_",options:.regularExpression)
            root=base.appendingPathComponent(test);guard !fm.fileExists(atPath:root.path) else {throw OSwindError.invalid("Owned test output must be fresh")}
            retained=true
        } else {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-historical-erasure-"+UUID().uuidString)}
        try Paths.ensure(root)
    }
    override func tearDownWithError() throws {for store in stores {try store.close()};stores=[];if !retained {try FileManager.default.removeItem(at:root)}}
    struct Fixture {let store:MemoryStore,original:HistoricalEvidence,current:Memory,recap:Memory,chat:String}
    func fixture(_ name:String,links:Bool=true) throws -> Fixture {
        let store=try MemoryStore(root:root.appendingPathComponent(name));stores.append(store)
        let current=Memory(id:"source",timestamp:Date(timeIntervalSince1970:900),kind:.note,app:"Notes",bundleID:"com.owned.Notes",title:"New current source",url:"https://keep.example.test/new",text:"Newer independent current body")
        try store.insert(current)
        let old=Memory(id:"source",timestamp:Date(timeIntervalSince1970:100),kind:.screen,app:"Safari",bundleID:"com.owned.Safari",title:"Old original source",url:"https://private.example.test/old",text:"Original private source body")
        let body=try SyncSourceBody(memory:old,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("Owned original has no recap")}
        let packet=try SyncPortableRecord(identity:.init(table:.source,origin:origin,lifetime:UUID().uuidString.lowercased()),body:.source(body))
        let original=try store.withRoutineDatabase {db -> HistoricalEvidence in
            let history=HistoricalEvidenceStore(database:db),handle=UUID().uuidString.lowercased()
            try history.insert(handle:handle,source:current.id,record:packet,paths:[:],parents:[])
            return try history.read(handle,verifyMedia:{_,_,_ in})
        }
        var recap=Memory(id:"linked-recap",timestamp:Date(timeIntervalSince1970:1000),kind:.summary,app:"OSwind",title:"Derived recap",text:"A recap of the old original")
        let chat=try store.createChat(title:"Original-dependent conversation")
        if links {
            var parent=RecapSource(id:current.id,revision:original.memory.evidenceHash,match:"owned",score:1);parent.historicalHandle=original.handle
            recap.recap = .init(provider:"owned",sources:[parent]);try store.insertRestoringRecap(recap);try store.rebuildRecapLinks()
            let turn=try store.appendChatTurn(sessionID:chat.id,question:"What did the old source say?",answer:.init(text:"Old evidence [1]",sources:[.init(memory:current,score:1,match:"owned")],provider:"owned",duration:0))
            try store.withRoutineDatabase {db in
                let row=try db.statement("UPDATE chat_sources SET memory_id=NULL,owner_id=?,historical_handle=? WHERE turn_id=?");defer {sqlite3_finalize(row)}
                db.bind(row,1,current.id);db.bind(row,2,original.handle);db.bind(row,3,turn.id);try db.done(row)
            }
        }
        return .init(store:store,original:original,current:current,recap:recap,chat:chat.id)
    }
    func testOriginalFieldScopesEraseHistoricalVersionAndDependentsWithoutDeletingNewerOwner() throws {
        let scopes:[(String,HistoryErasureScope)]=[
            ("app",.init(app:"Safari")),("bundle",.init(bundleID:"com.owned.Safari")),("domain",.init(domain:"private.example.test")),("kind",.init(kind:.screen)),("time",.init(start:Date(timeIntervalSince1970:90),end:Date(timeIntervalSince1970:110))),
            ("intersection",.init(start:Date(timeIntervalSince1970:90),end:Date(timeIntervalSince1970:110),app:"Safari",bundleID:"com.owned.Safari",domain:"private.example.test",kind:.screen))]
        for (name,scope) in scopes {
            let f=try fixture(name),p=try f.store.previewErasure(scope)
            XCTAssertEqual(p.matchedSources,0,name);XCTAssertEqual(p.sources,1,"The dependent canonical recap must be included: "+name)
            XCTAssertEqual(p.conversationTurns,1,name);XCTAssertEqual(p.historicalVersions,1,name);XCTAssertEqual(p.matchedHistoricalVersions,1,name);XCTAssertEqual(p.historicalSamples.first?.app,"Safari",name)
            let result=try f.store.eraseHistory(scope,expectedToken:p.token)
            XCTAssertEqual(result.sources,1,name);XCTAssertEqual(result.conversationTurns,1,name);XCTAssertEqual(result.historicalVersions,1,name)
            XCTAssertThrowsError(try f.store.historicalMemory(f.original.handle),name)
            XCTAssertNil(try f.store.get(f.recap.id),name);XCTAssertTrue(try f.store.chatTurns(f.chat).isEmpty,name)
            XCTAssertEqual(try f.store.get(f.current.id),f.current,"Out-of-scope current owner must remain: "+name)
        }
    }
    func archive(_ f:Fixture,memory:Memory,paths:[SyncMediaRole:String]=[:],parents:[HistoricalEvidence]=[],owner:String?=nil,identity:SyncObjectIdentity?=nil) throws -> HistoricalEvidence {
        let media=try paths.map {role,path -> SyncMediaManifest in
            let data=try Data(contentsOf:f.store.root.appendingPathComponent(path)),ref=try SyncContentReference(data:data)
            return .init(role:role,sha256:ref.sha256,bytes:Int64(data.count),chunks:[ref])
        }.sorted {$0.role.rawValue<$1.role.rawValue}
        let body=try SyncSourceBody(memory:memory,origin:origin,media:media) {id,_ in try XCTUnwrap(parents.first {$0.memory.id==id}).reference}
        let packet=try SyncPortableRecord(identity:identity ?? f.original.record.identity,body:.source(body))
        return try f.store.withRoutineDatabase {db in
            let archive=HistoricalEvidenceStore(database:db),handle=UUID().uuidString.lowercased();try archive.insert(handle:handle,source:owner ?? f.current.id,record:packet,paths:paths,parents:parents)
            return try archive.read(handle,verifyMedia:{_,_,_ in})
        }
    }
    func testHistoricalOnlyPreviewIsActionableAndDoesNotBorrowCurrentOwnerMetadata() throws {
        let f=try fixture("only",links:false),p=try f.store.previewErasure(.init(app:"Safari"))
        XCTAssertEqual(p.sources,0);XCTAssertEqual(p.matchedSources,0);XCTAssertEqual(p.historicalVersions,1);XCTAssertEqual(p.matchedHistoricalVersions,1);XCTAssertTrue(p.canErase)
        XCTAssertTrue(p.samples.isEmpty);XCTAssertEqual(p.historicalSamples.first?.title,"Old original source");XCTAssertEqual(p.historicalSamples.first?.timestamp,Date(timeIntervalSince1970:100))
        let result=try f.store.eraseHistory(p.scope,expectedToken:p.token);XCTAssertEqual(result.historicalVersions,1);XCTAssertEqual(result.sources,0)
        XCTAssertEqual(try f.store.get(f.current.id),f.current)
        let next=try f.store.previewErasure(p.scope);XCTAssertFalse(next.canErase);XCTAssertEqual(next.historicalVersions,0)
    }
    func testSiblingVersionsOfOneOwnerStaySeparateAndFiltersDoNotMixTheirFields() throws {
        let f=try fixture("siblings",links:false),old=Memory(id:"old",timestamp:Date(timeIntervalSince1970:400),kind:.note,app:"Calendar",bundleID:"com.owned.Calendar",title:"Other original",url:"https://other.example.test",text:"Other original body")
        let sibling=try archive(f,memory:old)
        let mixed=try f.store.previewErasure(.init(app:"Safari",domain:"other.example.test"));XCTAssertFalse(mixed.canErase)
        let p=try f.store.previewErasure(.init(app:"Safari"));XCTAssertEqual(p.historicalVersions,1)
        _=try f.store.eraseHistory(p.scope,expectedToken:p.token)
        XCTAssertThrowsError(try f.store.historicalMemory(f.original.handle));XCTAssertEqual(try f.store.historicalMemory(sibling.handle),sibling.memory);XCTAssertEqual(try f.store.get(f.current.id),f.current)
    }
    func testHalfOpenTimesRespectContinuousEndsAndClosedSampleEndpoints() throws {
        let f=try fixture("times",links:false)
        var continuous=Memory(id:"continuous",timestamp:Date(timeIntervalSince1970:10),endTimestamp:Date(timeIntervalSince1970:20),kind:.audio,app:"Continuous",text:"Owned continuous span")
        let clip=try archive(f,memory:continuous)
        continuous=Memory(id:"sampled",timestamp:Date(timeIntervalSince1970:10),endTimestamp:Date(timeIntervalSince1970:20),kind:.screen,app:"Sampled",text:"Owned sampled span",display:AccessibilityCaptureRecord.display)
        continuous.textObservation = .init(samples:2,largestGapSeconds:10)
        let sampled=try archive(f,memory:continuous)
        XCTAssertEqual(try f.store.previewErasure(.init(start:Date(timeIntervalSince1970:20),end:Date(timeIntervalSince1970:21),app:"Continuous")).historicalVersions,0)
        let p=try f.store.previewErasure(.init(start:Date(timeIntervalSince1970:20),end:Date(timeIntervalSince1970:21),app:"Sampled"));XCTAssertEqual(p.historicalVersions,1)
        _=try f.store.eraseHistory(p.scope,expectedToken:p.token);XCTAssertThrowsError(try f.store.historicalMemory(sampled.handle));XCTAssertEqual(try f.store.historicalMemory(clip.handle),clip.memory)
        XCTAssertEqual(try f.store.previewErasure(.init(end:Date(timeIntervalSince1970:10),app:"Continuous")).historicalVersions,0)
    }
    func testOriginalDomainRulesNormalizeIDNAAndKeepLookalikeHosts() throws {
        let f=try fixture("hosts",links:false)
        for (index,url) in ["https://EXAMPLE.com./private","https://www.example.com:443/a","https://notexample.com","https://example.com.evil.test","https://example.com@evil.test","file://example.com/a","https://bücher.de/a"].enumerated() {
            _=try archive(f,memory:Memory(id:"host-\(index)",timestamp:Date(timeIntervalSince1970:200+Double(index)),kind:.note,app:"Hosts",title:"Host",url:url,text:"Owned domain variant \(index)"))
        }
        XCTAssertEqual(try f.store.previewErasure(.init(app:"Hosts",domain:"example.com")).historicalVersions,2)
        XCTAssertEqual(try f.store.previewErasure(.init(app:"Hosts",domain:"example.com",includeSubdomains:false)).historicalVersions,1)
        XCTAssertEqual(try f.store.previewErasure(.init(app:"Hosts",domain:"bücher.de")).historicalVersions,1)
    }
    func testRetentionAndOldestSelectionRemoveOldOriginalBeforeNewerCurrentOwner() throws {
        let f=try fixture("retention")
        try f.store.withRoutineDatabase {db in
            try db.prepareOldestErasure(limit:16)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM temp.erasure_historical_ids"),1)
            XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM temp.erasure_ids WHERE id='source'"),0)
            try db.clearErasureSelection()
        }
        let result=try f.store.pruneHistory(before:Date(timeIntervalSince1970:150))
        XCTAssertEqual(result.erasure.historicalVersions,1);XCTAssertEqual(result.erasure.sources,1);XCTAssertEqual(result.erasure.conversationTurns,1)
        XCTAssertThrowsError(try f.store.historicalMemory(f.original.handle));XCTAssertEqual(try f.store.get(f.current.id),f.current)
    }
    func testPhysicalMediaCleanupKeepsSharedPathsAndRefusesSymlinkTargets() throws {
        for mode in ["only","shared","symlink"] {
            let f=try fixture(mode,links:false),path="images/owned-original.bin",url=f.store.root.appendingPathComponent(path),bytes=Data("Owned retained image bytes".utf8)
            try bytes.write(to:url)
            let original=try archive(f,memory:Memory(id:"media",timestamp:Date(timeIntervalSince1970:150),kind:.screen,app:"Original image",title:"Image original",text:"Owned old image",imagePath:path),paths:[.image:path])
            var target:URL?
            if mode=="shared" {try f.store.insert(Memory(id:"other",kind:.screen,app:"Other",text:"Keep shared image",imagePath:path))}
            if mode=="symlink" {let outside=root.appendingPathComponent("target");try bytes.write(to:outside);try FileManager.default.removeItem(at:url);try FileManager.default.createSymbolicLink(at:url,withDestinationURL:outside);target=outside}
            let p=try f.store.previewErasure(.init(app:"Original image"));XCTAssertEqual(p.historicalVersions,1);XCTAssertEqual(p.mediaReferences,1)
            let result=try f.store.eraseHistory(p.scope,expectedToken:p.token);XCTAssertEqual(result.historicalVersions,1);XCTAssertThrowsError(try f.store.historicalMemory(original.handle))
            if mode=="only" {XCTAssertEqual(result.removedMedia,1);XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))}
            if mode=="shared" {XCTAssertEqual(result.sharedMedia,1);XCTAssertEqual(try Data(contentsOf:url),bytes)}
            if let target {XCTAssertEqual(result.pendingMedia,1);XCTAssertFalse(result.warnings.isEmpty);XCTAssertEqual(try Data(contentsOf:target),bytes)}
            XCTAssertEqual(try f.store.get(f.current.id),f.current)
        }
    }
    func testMetadataQueryPlansUseIndexesAndDomainScanDoesNotReadSourceBodies() throws {
        let f=try fixture("plans",links:false)
        try f.store.withRoutineDatabase {db in
            for scope in [HistoryErasureScope(app:"Safari"),.init(bundleID:"com.owned.Safari"),.init(kind:.screen),.init(start:Date(timeIntervalSince1970:90)),.init(end:Date(timeIntervalSince1970:110)),.init(domain:"private.example.test")] {
                let query=HistoricalErasureSchema.query(scope,db:db),plan=try db.statement("EXPLAIN QUERY PLAN "+query.sql);defer {sqlite3_finalize(plan)};try query.bind(plan);var detail="",code=sqlite3_step(plan)
                while code==SQLITE_ROW {detail+=db.text(plan,3);code=sqlite3_step(plan)};XCTAssertEqual(code,SQLITE_DONE);XCTAssertTrue(detail.contains("historical_scope_"),"\(scope): "+detail)
                if scope.domain != nil {
                    let op=try db.statement("EXPLAIN "+query.sql);defer {sqlite3_finalize(op)};try query.bind(op);var reads=[(Int32,Int32)]();code=sqlite3_step(op)
                    while code==SQLITE_ROW {if db.text(op,1)=="Column" {reads.append((sqlite3_column_int(op,2),sqlite3_column_int(op,3)))};code=sqlite3_step(op)}
                    // Cursor0 is the source table; its body is column4. The URL
                    // expression, handle and owner are read from the index.
                    XCTAssertFalse(reads.contains {$0.0==0 && $0.1==4})
                }
            }
        }
    }

    func testErasurePreviewDoesNotNeedResolvableHistoricalRecapParents() throws {
        let f=try fixture("damaged-parent",links:false)
        var memory=Memory(id:"summary",timestamp:Date(timeIntervalSince1970:200),kind:.summary,app:"Original recap",title:"Recap with unavailable parent",text:"Owned original recap")
        memory.recap = .init(provider:"owned",sources:[.init(id:f.original.memory.id,revision:f.original.memory.evidenceHash,match:"owned",score:1)])
        try f.store.insert(Memory(id:"recap-owner",kind:.summary,app:"New current recap",text:"New independent current recap"))
        let recap=try archive(f,memory:memory,parents:[f.original],owner:"recap-owner",identity:.init(table:.source,origin:origin,lifetime:UUID().uuidString.lowercased()))
        try f.store.withRoutineDatabase {db in let row=try db.statement("DELETE FROM historical_evidence_dependencies WHERE child=?");defer {sqlite3_finalize(row)};db.bind(row,1,recap.handle);try db.done(row)}
        XCTAssertThrowsError(try f.store.historicalMemory(recap.handle))
        let p=try f.store.previewErasure(.init(app:"Original recap"));XCTAssertEqual(p.historicalVersions,1);XCTAssertEqual(p.historicalSamples.first?.title,memory.title)
        _=try f.store.eraseHistory(p.scope,expectedToken:p.token)
        XCTAssertThrowsError(try f.store.historicalMemory(recap.handle));XCTAssertEqual(try f.store.historicalMemory(f.original.handle),f.original.memory)
    }
    func testWholeWipeAndDirectOwnerDeleteReportAllOriginalVersions() throws {
        for mode in ["delete","wipe"] {
            let f=try fixture(mode,links:false)
            let sibling=try archive(f,memory:Memory(id:"older",timestamp:Date(timeIntervalSince1970:200),kind:.note,app:"Other old",text:"Owned sibling"))
            let result=try mode=="wipe" ? f.store.wipeLibrary().erasure:f.store.delete(f.current.id)
            XCTAssertEqual(result.sources,1);XCTAssertEqual(result.historicalVersions,2)
            XCTAssertThrowsError(try f.store.historicalMemory(sibling.handle));XCTAssertThrowsError(try f.store.historicalMemory(f.original.handle));XCTAssertNil(try f.store.get(f.current.id))
        }
    }
    func testAddingAnOriginalAfterPreviewInvalidatesTokenWithoutErasingAnything() throws {
        let f=try fixture("token",links:false),p=try f.store.previewErasure(.init(app:"Safari"))
        _=try archive(f,memory:Memory(id:"new-original",timestamp:Date(timeIntervalSince1970:200),kind:.note,app:"Other old",text:"Owned original admitted later"))
        XCTAssertThrowsError(try f.store.eraseHistory(p.scope,expectedToken:p.token))
        XCTAssertEqual(try f.store.historicalMemory(f.original.handle),f.original.memory);XCTAssertEqual(try f.store.get(f.current.id),f.current)
    }

    func testClosureCrossesHistoricalAndCanonicalRecapsTransitively() throws {
        let f=try fixture("mixed-closure",links:false)
        let owner=Memory(id:"historical-recap-owner",kind:.summary,app:"Keep current recap",text:"Independent newer recap owner")
        try f.store.insert(owner)
        var old=Memory(id:"old-recap",timestamp:Date(timeIntervalSince1970:200),kind:.summary,app:"Historical dependent",text:"Old recap of the Safari original")
        old.recap = .init(provider:"owned",sources:[.init(id:f.original.memory.id,revision:f.original.memory.evidenceHash,match:"owned",score:1)])
        let history=try archive(f,memory:old,parents:[f.original],owner:owner.id,identity:.init(table:.source,origin:origin,lifetime:UUID().uuidString.lowercased()))
        let keep=try archive(f,memory:Memory(id:"independent",kind:.note,app:"Keep sibling",text:"Independent archived sibling"),owner:owner.id,identity:history.record.identity)
        var parent=RecapSource(id:owner.id,revision:history.memory.evidenceHash,match:"owned",score:1);parent.historicalHandle=history.handle
        var current=Memory(id:"current-dependent",kind:.summary,app:"Canonical dependent",text:"Current recap of historical recap")
        current.recap = .init(provider:"owned",sources:[parent]);try f.store.insertRestoringRecap(current);try f.store.rebuildRecapLinks()
        var archived=current;archived.recap!.sources=[.init(id:history.memory.id,revision:history.memory.evidenceHash,match:"owned",score:1)]
        let tail=try archive(f,memory:archived,parents:[history],owner:current.id,identity:.init(table:.source,origin:origin,lifetime:UUID().uuidString.lowercased()))
        var link=RecapSource(id:current.id,revision:tail.memory.evidenceHash,match:"owned",score:1);link.historicalHandle=tail.handle
        var final=Memory(id:"final-dependent",kind:.summary,app:"Final current recap",text:"Tail of mixed dependency chain")
        final.recap = .init(provider:"owned",sources:[link]);try f.store.insertRestoringRecap(final);try f.store.rebuildRecapLinks()
        let p=try f.store.previewErasure(.init(app:"Safari"));XCTAssertEqual(p.sources,2);XCTAssertEqual(p.historicalVersions,3);XCTAssertEqual(p.matchedHistoricalVersions,1)
        let result=try f.store.eraseHistory(p.scope,expectedToken:p.token);XCTAssertEqual(result.sources,2);XCTAssertEqual(result.historicalVersions,3)
        for handle in [f.original.handle,history.handle,tail.handle] {XCTAssertThrowsError(try f.store.historicalMemory(handle))}
        XCTAssertNil(try f.store.get(current.id));XCTAssertNil(try f.store.get(final.id));XCTAssertEqual(try f.store.get(owner.id),owner);XCTAssertEqual(try f.store.get(f.current.id),f.current)
        XCTAssertEqual(try f.store.historicalMemory(keep.handle),keep.memory)
    }

    func testOriginalErasurePurgesExactSyncCacheAndPreventsLocalReadmission() throws {
        let f=try fixture("cached-original",links:false)
        let owner=Memory(id:"cached-dependent",kind:.summary,app:"Keep current cached owner",text:"Independent newer cached owner");try f.store.insert(owner)
        let (cache,evidence,old,current,dependent,oldHandle)=try f.store.withRoutineDatabase {db -> (SyncVersionStore,SyncOriginalEvidenceStore,SyncPortableRecord,SyncPortableRecord,SyncPortableRecord,String) in
            _=try SyncChangeCapture.activate(db)
            let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:"00000000-0000-0000-0000-000000005301",group:"00000000-0000-0000-0000-000000005302",epoch:"00000000-0000-0000-0000-000000005303"),cache=try SyncVersionStore.install(catalog:catalog,journal:journal),evidence=try SyncOriginalEvidenceStore.install(cache:cache)
            let identity=try catalog.registerExisting(.source,primary:[.text(Data(f.current.id.utf8))])
            var original=f.current;original.timestamp=Date(timeIntervalSince1970:150);original.app="Safari";original.text="Erased cached original body"
            let old=try SyncPortableRecord(identity:identity,body:.source(.init(memory:original,origin:identity.origin,media:[]) {_,_ in throw OSwindError.invalid("No recap")}))
            _=try journal.put(key:identity.key,content:old.reference.content) {_ in _=try cache.retain(old,admit:{_ in})}
            let projection=try evidence.prepare(old.reference,pathsFor:{_,_ in [:]},admit:{_ in},admitMedia:{_,_,_ in})
            let archive=HistoricalEvidenceStore(database:db);try archive.insert(handle:UUID().uuidString.lowercased(),source:f.current.id,record:old,paths:[:],parents:[])
            let current=try SyncPortableRecord(identity:identity,body:.source(.init(memory:f.current,origin:identity.origin,media:[]) {_,_ in throw OSwindError.invalid("No recap")}))
            _=try journal.put(key:identity.key,content:current.reference.content) {_ in _=try cache.retain(current,admit:{_ in})}
            let other=try catalog.registerExisting(.source,primary:[.text(Data(owner.id.utf8))])
            var summary=owner;summary.text="Derived old cached recap";summary.recap = .init(provider:"owned",sources:[.init(id:original.id,revision:original.evidenceHash,match:"owned",score:1)])
            let dependent=try SyncPortableRecord(identity:other,body:.source(.init(memory:summary,origin:other.origin,media:[]) {_,_ in try old.reference}))
            _=try journal.put(key:other.key,content:dependent.reference.content) {_ in _=try cache.retain(dependent,admit:{_ in})}
            return(cache,evidence,old,current,dependent,projection.handle)
        }
        let p=try f.store.previewErasure(.init(app:"Safari"));XCTAssertEqual(p.historicalVersions,2)
        _=try f.store.eraseHistory(p.scope,expectedToken:p.token)
        XCTAssertNil(try cache.record(old.reference,admit:{_ in}))
        XCTAssertNil(try cache.record(dependent.reference,admit:{_ in}))
        XCTAssertEqual(try cache.record(current.reference,admit:{_ in}),current)
        XCTAssertThrowsError(try evidence.read(oldHandle,admit:{_ in},admitMedia:{_,_,_ in}))
        XCTAssertThrowsError(try cache.retain(old,admit:{_ in}))
        XCTAssertThrowsError(try cache.retain(dependent,admit:{_ in}))
        var newSummary=Memory(id:"cached-dependent",kind:.summary,app:"Keep current cached owner",text:"New cached recap that still cites the erased original")
        newSummary.recap = .init(provider:"owned",sources:[.init(id:f.current.id,revision:try old.reference.content.sha256,match:"owned",score:1)])
        let changed=try SyncPortableRecord(identity:dependent.identity,body:.source(.init(memory:newSummary,origin:dependent.identity.origin,media:[]) {_,_ in try old.reference}))
        XCTAssertThrowsError(try cache.journal.put(key:changed.identity.key,content:changed.reference.content) {_ in _=try cache.retain(changed,admit:{_ in})})
        let reopened=try MemoryStore(root:f.store.root);defer {try? reopened.close()}
        try reopened.withRoutineDatabase {db in XCTAssertTrue(try HistoricalErasureSchema.isRevoked(db,old.reference));XCTAssertTrue(try HistoricalErasureSchema.isRevoked(db,dependent.reference));XCTAssertFalse(try HistoricalErasureSchema.isRevoked(db,current.reference))}
        XCTAssertThrowsError(try f.store.withRoutineDatabase {db in try HistoricalEvidenceStore(database:db).adopt(old.reference,cache:cache,pathsFor:{_,_ in [:]},admit:{_ in},verifyMedia:{_,_,_ in})})
        XCTAssertEqual(try f.store.get(f.current.id),f.current);XCTAssertEqual(try f.store.get("cached-dependent")?.text,"Independent newer cached owner")
        try f.store.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM personal_sync_versions"),1)}
    }

}
