import XCTest
@testable import OSwindCore

final class EntityMemoryTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-entities-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {try? store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    private func source(_ id:String="source",text:String="Maya Chen owns Apollo Launch.")throws->Memory {let m=Memory(id:id,kind:.note,app:"Owned",text:text);try store.insert(m);return m}
    private func candidate(_ m:Memory,name:String="Maya Chen",kind:EntityKind = .person)throws->EntityCandidate {
        let range=(m.text as NSString).range(of:name);return .init(kind:kind,name:name,start:range.location,length:range.length)
    }
    private func indexed(_ m:Memory)throws {try store.saveEntityExtraction(memory:m,plan:store.entityIndexPlan(),result:.init(candidates:[candidate(m)]))}
    func testCreateCurateAliasesAndManualSourceGroupingPersist() throws {
        let m=try source(),project=try store.createEntity(kind:.project,name:"Apollo Launch",detail:"Owned project notes")
        try store.linkEntity(project.id,to:m.id);try store.editEntity(project.id,name:"Apollo",detail:"Edited",aliases:["Apollo Launch","Apollo"])
        try store.close();store=try MemoryStore(root:root)
        let found=try XCTUnwrap(store.entity(project.id));XCTAssertTrue(found.curated);XCTAssertEqual(found.sourceCount,1);XCTAssertEqual(found.detail,"Edited");XCTAssertEqual(Set(found.aliases),Set(["Apollo","Apollo Launch"]))
        let sources=try store.entitySources(project.id);XCTAssertEqual(sources.map(\.id),[m.id]);XCTAssertEqual(sources[0].origin,"manual");XCTAssertNil(sources[0].passage)
    }
    func testAutomaticSpanAndStableIdentityOnUnchangedReindex() throws {
        let m=try source();try indexed(m)
        let entity=try XCTUnwrap(store.entities(kind:.person).first),mention=try XCTUnwrap(store.entitySources(entity.id).first)
        XCTAssertFalse(entity.curated);XCTAssertEqual(mention.surface,"Maya Chen");XCTAssertEqual(mention.passage?.start,0)
        try indexed(m);XCTAssertEqual(try store.entities(kind:.person).first?.id,entity.id);XCTAssertEqual(try store.entity(entity.id)?.sourceCount,1)
    }
    func testErasurePrunesDerivedNamesButKeepsExplicitCuration() throws {
        let a=try source("a"),b=try source("b");try indexed(a);try indexed(b)
        let entity=try XCTUnwrap(store.entities(kind:.person).first)
        try store.delete(a.id);XCTAssertEqual(try store.entity(entity.id)?.sourceCount,1)
        try store.delete(b.id);XCTAssertNil(try store.entity(entity.id))
        let c=try source("c");try indexed(c);let saved=try XCTUnwrap(store.entities(kind:.person).first)
        try store.editEntity(saved.id,name:"Maya",detail:"User note",aliases:["Maya Chen"]);try store.delete(c.id)
        XCTAssertEqual(try store.entity(saved.id)?.sourceCount,0);XCTAssertEqual(try store.entity(saved.id)?.detail,"User note")
    }
    func testSourceRevisionRejectsDelayedExtractionAndInvalidatesLinks() throws {
        let old=try source();try indexed(old);let entity=try XCTUnwrap(store.entities().first)
        var changed=old;changed.text="Completely different source";try store.insert(changed)
        XCTAssertNil(try store.entity(entity.id));XCTAssertThrowsError(try indexed(old));XCTAssertTrue(try store.entities().isEmpty)
    }
    func testFavoriteAndTagMetadataPreserveEntityLinks() throws {
        let m=try source();try indexed(m);let id=try XCTUnwrap(store.entities().first?.id)
        try store.setTags(m.id,tags:["owned"]);try store.setFavorite(m.id,value:true)
        XCTAssertEqual(try store.entity(id)?.sourceCount,1)
    }
    func testUnknownSourceOrProjectCannotBeLinked() throws {
        let e=try store.createEntity(kind:.project,name:"Owned");XCTAssertThrowsError(try store.linkEntity(e.id,to:"missing"))
        let m=try source();XCTAssertThrowsError(try store.linkEntity("missing",to:m.id));XCTAssertTrue(try store.entitySources(e.id).isEmpty)
    }
    func testSuppressedAutomaticMentionDoesNotReappearOnReindex() throws {
        let m=try source();try indexed(m);let e=try XCTUnwrap(store.entities().first)
        try store.unlinkEntity(e.id,from:m.id);XCTAssertNil(try store.entity(e.id));try indexed(m);XCTAssertTrue(try store.entities().isEmpty)
        var changed=m;changed.text+=" New version";try store.insert(changed);try indexed(changed);XCTAssertEqual(try store.entities().count,1)
    }
    func testProjectRuleRevisionRejectsDelayedWorkAndAliasSpansAreVerified() throws {
        let m=try source(),plan=try store.entityIndexPlan(),project=try store.createEntity(kind:.project,name:"Apollo Launch")
        XCTAssertThrowsError(try store.saveEntityExtraction(memory:m,plan:plan,result:.init(candidates:[])))
        let fresh=try store.entityIndexPlan(),range=(m.text as NSString).range(of:"Apollo Launch")
        let good=EntityCandidate(kind:.project,name:project.name,start:range.location,length:range.length,method:"project-alias",projectID:project.id)
        try store.saveEntityExtraction(memory:m,plan:fresh,result:.init(candidates:[good]));XCTAssertEqual(try store.entity(project.id)?.sourceCount,1)
        var bad=good;bad.start=0;bad.length=9;XCTAssertThrowsError(try store.saveEntityExtraction(memory:m,plan:fresh,result:.init(candidates:[bad])))
        XCTAssertEqual(try store.entity(project.id)?.sourceCount,1)
    }
    func testInvalidSpansAndUnrecordedLabelsCannotEnterIndex() throws {
        let m=try source(),plan=try store.entityIndexPlan();var bad=try candidate(m);bad.name="Not recorded"
        XCTAssertThrowsError(try store.saveEntityExtraction(memory:m,plan:plan,result:.init(candidates:[bad])))
        bad=try candidate(m);bad.start=Int.max;XCTAssertThrowsError(try store.saveEntityExtraction(memory:m,plan:plan,result:.init(candidates:[bad])))
        XCTAssertTrue(try store.entities().isEmpty)
    }
    func testClosedOrReplacedRootCannotReceiveEntityMetadata() throws {
        let moved=root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-moved");defer {try? FileManager.default.removeItem(at:moved)}
        try FileManager.default.moveItem(at:root,to:moved);try Paths.ensure(root)
        XCTAssertThrowsError(try store.createEntity(kind:.project,name:"Must not write"));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
        try store.close();XCTAssertThrowsError(try store.createEntity(kind:.project,name:"Closed"))
    }
    func testProjectMatchingWorksLocallyAcrossUnicodeAndLaterChunks() throws {
        let m=try source(text:String(repeating:"Ordinary words. ",count:2000)+" Work on Café Launch with Maya Chen.")
        let p=try store.createEntity(kind:.project,name:"Café Launch")
        try store.indexEntities(m.id,plan:store.entityIndexPlan())
        let link=try XCTUnwrap(store.entitySources(p.id).first);XCTAssertEqual(link.surface,"Café Launch");XCTAssertNotNil(link.passage)
    }
    func testForgedProjectPlanCannotAuthorizeUnrecordedAlias() throws {
        let m=try source(),project=try store.createEntity(kind:.project,name:"Real project")
        var plan=try store.entityIndexPlan();plan.projects=[.init(id:project.id,name:project.name,aliases:["Maya Chen"])]
        var fake=try candidate(m);fake.kind = .project;fake.name=project.name;fake.projectID=project.id;fake.method="project-alias"
        XCTAssertThrowsError(try store.saveEntityExtraction(memory:m,plan:plan,result:.init(candidates:[fake])))
        XCTAssertEqual(try store.entity(project.id)?.sourceCount,0)
    }
    func testMethodAndKindCannotBeSubstituted() throws {
        let m=try source();var fake=try candidate(m);fake.method="project-alias"
        XCTAssertThrowsError(try store.saveEntityExtraction(memory:m,plan:store.entityIndexPlan(),result:.init(candidates:[fake])))
    }
    func testCuratorMergePreservesNotesAliasesAndDistinctSourceMembership() throws {
        let a=try source("a"),b=try source("b")
        let from=try store.createEntity(kind:.person,name:"M. Chen",detail:"First note"),to=try store.createEntity(kind:.person,name:"Maya Chen",detail:"Second note")
        try store.linkEntity(from.id,to:a.id);try store.linkEntity(from.id,to:b.id);try store.linkEntity(to.id,to:a.id)
        try store.mergeEntity(from.id,into:to.id)
        XCTAssertNil(try store.entity(from.id));let merged=try XCTUnwrap(store.entity(to.id))
        XCTAssertEqual(merged.sourceCount,2);XCTAssertEqual(Set(merged.aliases),["M. Chen","Maya Chen"]);XCTAssertTrue(merged.detail.contains("First note"));XCTAssertTrue(merged.detail.contains("Second note"))
        XCTAssertEqual(Set(try store.entitySources(to.id).map(\.id)),["a","b"])
        let project=try store.createEntity(kind:.project,name:"Other kind");XCTAssertThrowsError(try store.mergeEntity(project.id,into:to.id));XCTAssertNotNil(try store.entity(project.id))
    }
    func testAliasKeysDeduplicateCaseButPreserveAccentsAndRejectConflicts() throws {
        let p=try store.createEntity(kind:.project,name:"Café")
        try store.editEntity(p.id,name:"Café",detail:"",aliases:["CAFÉ","Cafe"])
        XCTAssertEqual(try store.entity(p.id)?.aliases.count,2)
        let other=try store.createEntity(kind:.project,name:"Other")
        XCTAssertThrowsError(try store.editEntity(other.id,name:"Other",detail:"",aliases:["café"]))
        XCTAssertEqual(try store.entity(other.id)?.aliases,["Other"])
    }
    func testResumeCursorAndLimitedStatusResetAfterSourceRevision() throws {
        for id in ["a","b","c"] {_ = try source(id)}
        let plan=try store.entityIndexPlan(),processor=EntityExtractor.processor(plan)
        XCTAssertEqual(try store.pendingEntitySourceIDs(processor:processor,limit:1),["a"])
        try store.saveEntityExtraction(memory:store.get("a")!,plan:plan,result:.init(candidates:[],limited:true))
        XCTAssertEqual(try store.pendingEntitySourceIDs(processor:processor,after:"a"),["b","c"])
        let progress=try store.entityIndexProgress(processor:processor);XCTAssertEqual(progress.eligible,3);XCTAssertEqual(progress.indexed,1);XCTAssertEqual(progress.limited,1)
        var changed=try XCTUnwrap(store.get("a"));changed.text="Changed";try store.insert(changed)
        XCTAssertEqual(try store.entityIndexProgress(processor:processor).indexed,0)
    }
    func testEntityFilterIntersectsKeywordSemanticAndDateScope() throws {
        let a=try source("a"),b=try source("b"),project=try store.createEntity(kind:.project,name:"Owned")
        try store.linkEntity(project.id,to:a.id)
        _=try store.saveVectors([a,b].map {VectorRecord(memory:$0,vector:[1,0])},modelID:"owned")
        let filter=SearchFilter(query:"Apollo",entityID:project.id)
        XCTAssertEqual(try store.search(filter,mode:.keyword).map(\.id),["a"])
        XCTAssertEqual(try store.search(filter,mode:.semantic,vector:[1,0],modelID:"owned").map(\.id),["a"])
        var excluded=filter;excluded.start=a.timestamp.addingTimeInterval(1);XCTAssertTrue(try store.search(excluded,mode:.keyword).isEmpty)
        XCTAssertEqual(try QueryScopeResolver.resolve(.init(query:"entity:\(project.id) Apollo")).filter,filter)
        XCTAssertThrowsError(try QueryScopeResolver.resolve(.init(query:"entity:other",entityID:project.id)))
        XCTAssertTrue(try store.search(.init(entityID:"missing"),mode:.keyword).isEmpty)
    }
    func testBackupRestorePreservesCuratedAndSuggestedLinksButResetsIndexCompletion() throws {
        let m=try source();try indexed(m);let person=try XCTUnwrap(store.entities(kind:.person).first)
        let project=try store.createEntity(kind:.project,name:"Owned",detail:"Explicit note");try store.linkEntity(project.id,to:m.id)
        // Backup destinations must be outside their source library.
        let parent=root.deletingLastPathComponent().appendingPathComponent("entity-transfer-"+UUID().uuidString);try Paths.ensure(parent);defer {try? FileManager.default.removeItem(at:parent)}
        let output=parent.appendingPathComponent("archive.oswindbackup"),destination=parent.appendingPathComponent("restored")
        var settings=AppSettings();settings.entityAutomaticIndex=true;try settings.save(root:root)
        _=try LibraryBackup.create(store:store,destination:output);_=try LibraryBackup.restore(output,to:destination)
        let copy=try MemoryStore(root:destination);defer {try? copy.close()}
        XCTAssertEqual(try copy.entity(project.id)?.detail,"Explicit note");XCTAssertEqual(try copy.entitySources(project.id).count,1);XCTAssertEqual(try copy.entitySources(person.id).first?.surface,"Maya Chen")
        XCTAssertEqual(try copy.entityIndexProgress(processor:EntityExtractor.processor(copy.entityIndexPlan())).indexed,0);XCTAssertFalse(AppSettings.load(root:destination).entityAutomaticIndex)
    }
    func testWholeLibraryWipeErasesCuratedDefinitionsAndRejectedLabels() throws {
        let m=try source();try indexed(m);let e=try XCTUnwrap(store.entities().first);try store.unlinkEntity(e.id,from:m.id)
        _=try store.createEntity(kind:.project,name:"Independent user note",detail:"Must be erased")
        XCTAssertTrue(try store.wipeLibrary().cleanupComplete);XCTAssertTrue(try store.entities().isEmpty)
        try store.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM entity_ignored"),0)}
    }
    func testReadOnlyIntegrationValidatesInputsAndExposesMembership() async throws {
        let m=try source(),project=try store.createEntity(kind:.project,name:"Owned");try store.linkEntity(project.id,to:m.id)
        let result=try await Integration.execute("memory_entities",args:["kind":"project"],store:store,embedder:LocalEmbedder())
        XCTAssertEqual((result as? [[String:Any]])?.first?["id"] as? String,project.id)
        let sources=try await Integration.execute("entity_sources",args:["id":project.id],store:store,embedder:LocalEmbedder())
        XCTAssertEqual((sources as? [[String:Any]])?.first?["id"] as? String,m.id)
        for args:[String:Any] in [["limit":true],["kind":"identity"],["write":true]] {do {_=try await Integration.execute("memory_entities",args:args,store:store,embedder:LocalEmbedder());XCTFail("Invalid input admitted")}catch {}}
        XCTAssertEqual(try Integration.filter(["entity":project.id]).entityID,project.id)
    }
    func testIndexedEntityScopeChangesFromAnotherConnectionInvalidateCachedMetalMembership() async throws {
        guard MetalFlatIndex.canFit(dimensions:32,count:2) else {throw XCTSkip("Metal unavailable")}
        let vector=Array(repeating:Float(1),count:32)
        let a=try source("a"),b=try source("b"),project=try store.createEntity(kind:.project,name:"Owned")
        _=try store.saveVectors([a,b].map {VectorRecord(memory:$0,vector:vector)},modelID:"owned")
        _=try await store.buildSearchIndex(modelID:"owned",dimensions:32)
        let filter=SearchFilter(query:"Apollo",entityID:project.id)
        func indexed()throws->[String] {try store.search(filter,mode:.semantic,vector:vector,modelID:"owned",indexPolicy:.indexed).map(\.id)}
        XCTAssertTrue(try indexed().isEmpty)
        let other=try MemoryStore(root:root);defer {try? other.close()}
        try other.linkEntity(project.id,to:a.id);XCTAssertEqual(try indexed(),["a"])
        try other.unlinkEntity(project.id,from:a.id);try other.linkEntity(project.id,to:b.id);XCTAssertEqual(try indexed(),["b"])
        try other.deleteEntity(project.id);XCTAssertTrue(try indexed().isEmpty)
    }
    func testCreateWithConflictingAliasIsAtomic() throws {
        _=try store.createEntity(kind:.project,name:"Existing",aliases:["Taken"])
        XCTAssertThrowsError(try store.createEntity(kind:.project,name:"Must roll back",aliases:["Taken"]))
        XCTAssertEqual(try store.entities().map(\.name),["Existing"])
    }
    func testOpeningEntitySourceRejectsChangedRevision() throws {
        var memory=try source();try indexed(memory);let e=try XCTUnwrap(store.entities().first),link=try XCTUnwrap(store.entitySources(e.id).first)
        XCTAssertEqual(try store.entitySourceMemory(link).id,memory.id)
        memory.text="Changed";try store.insert(memory);XCTAssertThrowsError(try store.entitySourceMemory(link))
    }
    func testExtractorSignalsEntityCapAndSupportsLongProjectAliases() throws {
        let names=(0..<260).map {"projectcode\($0)"},rules=names.map {ProjectEntityRule(id:$0,name:$0,aliases:[$0])}
        let result=try EntityExtractor.extract(names.joined(separator:" "),plan:.init(revision:"owned",projects:rules))
        XCTAssertTrue(result.limited);XCTAssertEqual(result.candidates.count,256)
        let long=(0..<20).map {"word\($0)"}.joined(separator:" ")
        let found=try EntityExtractor.extract(long,plan:.init(revision:"owned",projects:[.init(id:"long",name:long,aliases:[long])]))
        XCTAssertTrue(found.candidates.contains {$0.projectID=="long"})
    }
    func testUnicodeCaseExpansionCorrectionSurvivesBackupRestore() throws {
        let name=String(repeating:"İ",count:120),m=try source(text:name)
        XCTAssertEqual(name.utf8.count,240);XCTAssertEqual(EntityLabel.key(name).utf8.count,360)
        try store.saveEntityExtraction(memory:m,plan:store.entityIndexPlan(),result:.init(candidates:[candidate(m,name:name)]))
        let e=try XCTUnwrap(store.entities().first);try store.unlinkEntity(e.id,from:m.id)
        let parent=root.deletingLastPathComponent().appendingPathComponent("entity-unicode-"+UUID().uuidString);try Paths.ensure(parent);defer {try? FileManager.default.removeItem(at:parent)}
        let archive=parent.appendingPathComponent("archive.oswindbackup"),destination=parent.appendingPathComponent("restored")
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:destination)
        let copy=try MemoryStore(root:destination);defer {try? copy.close()}
        try copy.saveEntityExtraction(memory:m,plan:copy.entityIndexPlan(),result:.init(candidates:[candidate(m,name:name)]));XCTAssertTrue(try copy.entities().isEmpty)
    }
    func testNameBoundAppliesAfterCanonicalNormalization() throws {
        XCTAssertThrowsError(try EntityLabel.clean(String(repeating:"\u{0344}",count:120)))
        let clean=try EntityLabel.clean(" Cafe\u{301}\nLaunch ");XCTAssertEqual(clean,"Café Launch")
    }
}
